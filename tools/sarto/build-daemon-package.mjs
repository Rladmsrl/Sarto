// @ts-check
// Builds, stamps, and verifies a single-platform standalone Sarto daemon archive
// (`sarto-daemon-<platform>-<arch>.tar.gz`) on macOS (arm64) or Linux (x64, arm64).
//
//   node tools/sarto/build-daemon-package.mjs \
//     --version <daemonVersion> --build <12-digits> --channel <stable|beta> \
//     --out <dir> [--commit <sha>] [--built-at <iso>] [--build-dir <out>] \
//     [--node <node-dir>] [--skip-build] [--skip-smoke] [--max-glibc 2.28]

import { execFile as execFileCb, spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import { createReadStream, existsSync, realpathSync } from 'node:fs'
import { mkdir, mkdtemp, readdir, rm, stat, writeFile } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseArgs, promisify } from 'node:util'
import { stageDaemonPackage } from '../daemon/package.mjs'
import { isValidBuildNumber, readGitCommit } from './build-version.mjs'
import { stampBuildInfo } from './runtime-fingerprint.mjs'

const execFile = promisify(execFileCb)
const ROOT = fileURLToPath(new URL('../..', import.meta.url))
const DEFAULT_MAX_GLIBC = '2.28'
const DEFAULT_MAX_GLIBCXX = '3.4.25'
const DEFAULT_MAX_CXXABI = '1.3.11'
const DEFAULT_MAX_GCC = '7.0.0'

/** @param {string} file */
function sha256Of(file) {
  return new Promise((resolve, reject) => {
    const hash = createHash('sha256')
    createReadStream(file)
      .on('error', reject)
      .on('data', (chunk) => hash.update(chunk))
      .on('end', () => resolve(hash.digest('hex')))
  })
}

/**
 * Compares two dotted numeric version strings such as `2.28` and `2.34`.
 *
 * @param {string} a
 * @param {string} b
 */
export function compareDottedVersion(a, b) {
  const pa = a.split('.').map((part) => Number.parseInt(part, 10))
  const pb = b.split('.').map((part) => Number.parseInt(part, 10))
  const len = Math.max(pa.length, pb.length)
  for (let i = 0; i < len; i++) {
    const na = pa[i] ?? 0
    const nb = pb[i] ?? 0
    if (na !== nb) return na - nb
  }
  return 0
}

/**
 * Extracts the highest `<prefix>_X.Y[.Z]` symbol version from `objdump -T` or `readelf -V` output,
 * or null when no matching versioned symbols appear.
 *
 * @param {string} text
 * @param {'GLIBC' | 'GLIBCXX' | 'CXXABI' | 'GCC'} prefix
 */
export function parseMaxSymbolVersion(text, prefix) {
  let max = null
  const pattern = new RegExp(`\\b${prefix}_(\\d+\\.\\d+(?:\\.\\d+)?)\\b`, 'g')
  let match
  while ((match = pattern.exec(text)) !== null) {
    const ver = match[1]
    if (!ver) continue
    if (max === null || compareDottedVersion(ver, max) > 0) {
      max = ver
    }
  }
  return max
}

/**
 * Extracts the highest `GLIBC_X.Y[.Z]` symbol version from `objdump -T` or `readelf -V` output,
 * or null when no versioned GLIBC symbols appear.
 *
 * @param {string} text
 */
export function parseMaxGlibcVersion(text) {
  return parseMaxSymbolVersion(text, 'GLIBC')
}

/**
 * Extracts the highest `GLIBCXX_X.Y[.Z]` symbol version from `objdump -T` or `readelf -V` output,
 * or null when no versioned GLIBCXX symbols appear.
 *
 * @param {string} text
 */
export function parseMaxGlibcxxVersion(text) {
  return parseMaxSymbolVersion(text, 'GLIBCXX')
}

/**
 * Extracts the highest `CXXABI_X.Y[.Z]` symbol version from `objdump -T` or `readelf -V` output,
 * or null when no versioned CXXABI symbols appear.
 *
 * @param {string} text
 */
export function parseMaxCxxabiVersion(text) {
  return parseMaxSymbolVersion(text, 'CXXABI')
}

/**
 * Extracts the highest `GCC_X.Y[.Z]` symbol version from `objdump -T` or `readelf -V` output,
 * or null when no versioned GCC symbols appear.
 *
 * @param {string} text
 */
export function parseMaxGccVersion(text) {
  return parseMaxSymbolVersion(text, 'GCC')
}

/**
 * Returns whether `objdump -T` or `readelf -V` output references `GLIBC_PRIVATE` internal symbols.
 *
 * @param {string} text
 */
export function hasPrivateGlibcSymbols(text) {
  return /\bGLIBC_PRIVATE\b/.test(text)
}

/**
 * Verifies that `binary` does not require `GLIBC_PRIVATE` or glibc/libstdc++/libgcc symbols newer
 * than the glibc 2.28 / GCC 8 baseline.
 *
 * @param {string} binary
 * @param {string} maxGlibc
 * @param {string} maxGlibcxx
 * @param {string} maxCxxabi
 * @param {string} maxGcc
 */
export async function verifyGlibcCeiling(
  binary,
  maxGlibc = DEFAULT_MAX_GLIBC,
  maxGlibcxx = DEFAULT_MAX_GLIBCXX,
  maxCxxabi = DEFAULT_MAX_CXXABI,
  maxGcc = DEFAULT_MAX_GCC,
) {
  let output
  try {
    const res = await execFile('objdump', ['-T', binary], { maxBuffer: 16 * 1024 * 1024 })
    output = res.stdout
  } catch {
    const res = await execFile('readelf', ['--version-info', '--wide', binary], {
      maxBuffer: 16 * 1024 * 1024,
    })
    output = res.stdout
  }
  if (hasPrivateGlibcSymbols(output)) {
    throw new Error(`${binary} links GLIBC_PRIVATE internal symbols`)
  }
  const highest = parseMaxGlibcVersion(output)
  if (highest && compareDottedVersion(highest, maxGlibc) > 0) {
    throw new Error(
      `${binary} links GLIBC_${highest}, exceeding the ${maxGlibc} ABI floor; ` +
        'build inside a glibc 2.28 container (e.g. quay.io/pypa/manylinux_2_28_*)',
    )
  }
  const highestCxx = parseMaxGlibcxxVersion(output)
  if (highestCxx && compareDottedVersion(highestCxx, maxGlibcxx) > 0) {
    throw new Error(
      `${binary} links GLIBCXX_${highestCxx}, exceeding the ${maxGlibcxx} libstdc++ floor; ` +
        'build inside a manylinux_2_28 container with libstdc++_nonshared',
    )
  }
  const highestCxxabi = parseMaxCxxabiVersion(output)
  if (highestCxxabi && compareDottedVersion(highestCxxabi, maxCxxabi) > 0) {
    throw new Error(
      `${binary} links CXXABI_${highestCxxabi}, exceeding the ${maxCxxabi} libstdc++ ABI floor`,
    )
  }
  const highestGcc = parseMaxGccVersion(output)
  if (highestGcc && compareDottedVersion(highestGcc, maxGcc) > 0) {
    throw new Error(`${binary} links GCC_${highestGcc}, exceeding the ${maxGcc} libgcc floor`)
  }
  return highest
}

/**
 * Recursively collects all `.node` native addon binaries under `dir`.
 *
 * @param {string} dir
 * @returns {Promise<string[]>}
 */
async function findNativeAddons(dir) {
  /** @type {string[]} */
  const out = []
  if (!existsSync(dir)) return out
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name)
    if (entry.isDirectory()) {
      out.push(...(await findNativeAddons(full)))
    } else if (entry.name.endsWith('.node')) {
      if (entry.isFile()) {
        out.push(full)
      } else if (entry.isSymbolicLink()) {
        const target = await stat(full).catch(() => null)
        if (target?.isFile()) out.push(full)
      }
    }
  }
  return out
}

/**
 * Runs a program with inherited stdio in the repository root.
 *
 * @param {string} command
 * @param {string[]} args
 * @param {Record<string, string>} [env]
 */
function run(command, args, env = {}) {
  /** @type {NodeJS.ProcessEnv} */
  const childEnv = { ...process.env, ...env }
  delete childEnv.ELECTRON_RUN_AS_NODE
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd: ROOT, stdio: 'inherit', env: childEnv })
    child.on('error', reject)
    child.on('exit', (code) =>
      code === 0
        ? resolve(undefined)
        : reject(new Error(`${command} ${args.join(' ')} exited with ${code}`)),
    )
  })
}

/** Xcode itself, when xcode-select points at the Command Line Tools on macOS. */
async function developerDir() {
  if (process.platform !== 'darwin') return undefined
  if (process.env.DEVELOPER_DIR) return process.env.DEVELOPER_DIR
  const xcode = '/Applications/Xcode.app/Contents/Developer'
  const { stdout } = await execFile('xcode-select', ['-p']).catch(() => ({ stdout: '' }))
  if (stdout.trim().includes('CommandLineTools') && existsSync(xcode)) return xcode
  return undefined
}

/**
 * Verifies the bundled Node.js can load `node-pty` and spawn a real PTY process.
 *
 * @param {string} pkgDir
 */
async function smokeTestPty(pkgDir) {
  const nodeBin = path.join(pkgDir, 'node', 'bin', 'node')
  const ptyDir = path.join(pkgDir, 'daemon', 'node_modules', 'node-pty')
  const script = `
    const pty = require(${JSON.stringify(ptyDir)});
    const proc = pty.spawn('/bin/sh', ['-c', 'printf sarto-pty-ok'], {
      name: 'xterm-256color',
      cols: 80,
      rows: 24,
      cwd: process.cwd(),
      env: process.env,
    });
    let out = '';
    proc.onData((chunk) => { out += chunk; });
    const timer = setTimeout(() => {
      console.error('PTY smoke test timed out; output=' + JSON.stringify(out));
      process.exit(1);
    }, 10000);
    proc.onExit(({ exitCode }) => {
      clearTimeout(timer);
      if (exitCode !== 0 || !out.includes('sarto-pty-ok')) {
        console.error('PTY smoke test failed: code=' + exitCode + ' out=' + JSON.stringify(out));
        process.exit(1);
      }
      process.exit(0);
    });
  `
  await execFile(nodeBin, ['-e', script], { timeout: 15_000 })
}

/**
 * Verifies the packaged daemon starts headlessly and reports ready hosts via `sarto status`.
 *
 * @param {string} pkgDir
 */
async function smokeTestDaemon(pkgDir) {
  const sartoBin = path.join(pkgDir, 'bin', 'sarto')
  // Keep data path short so control.sock fits within the 103-byte Unix socket sun_path limit.
  const tmpRoot = os.tmpdir().length > 60 ? '/tmp' : os.tmpdir()
  const dataDir = await mkdtemp(path.join(tmpRoot, 'sd-'))
  /** @type {NodeJS.ProcessEnv} */
  const env = {
    ...process.env,
    SARTO_DAEMON_DATA: dataDir,
    SARTO_NO_KEYCHAIN: '1',
  }
  delete env.ELECTRON_RUN_AS_NODE
  const child = spawn(sartoBin, ['run'], { env, stdio: ['ignore', 'pipe', 'pipe'] })
  let logs = ''
  child.stdout?.on('data', (chunk) => {
    logs = (logs + chunk.toString('utf8')).slice(-8192)
  })
  child.stderr?.on('data', (chunk) => {
    logs = (logs + chunk.toString('utf8')).slice(-8192)
  })

  try {
    const deadline = Date.now() + 20_000
    let ready = false
    let lastStatus = ''
    while (Date.now() < deadline) {
      if (child.exitCode !== null) {
        throw new Error(`sarto run exited prematurely (${child.exitCode}):\n${logs}`)
      }
      const status = await execFile(sartoBin, ['status'], { env, timeout: 5_000 }).catch(() => null)
      if (status) {
        lastStatus = status.stdout
        // Terminal host starts lazily when a client opens a terminal; Agent and Remote start eagerly.
        if (
          /Agent host:\s+ready/.test(status.stdout) &&
          /Remote host:\s+ready/.test(status.stdout) &&
          /Terminal host:\s+(?:ready|not started)/.test(status.stdout)
        ) {
          ready = true
          break
        }
      }
      await new Promise((resolve) => setTimeout(resolve, 250))
    }
    if (!ready) {
      throw new Error(
        `sarto daemon did not report ready hosts within 20s:\nstatus:\n${lastStatus}\nlogs:\n${logs}`,
      )
    }
  } finally {
    if (child.exitCode === null) {
      child.kill('SIGTERM')
      await new Promise((resolve) => {
        const killTimer = setTimeout(() => {
          child.kill('SIGKILL')
          resolve(undefined)
        }, 8_000)
        child.once('exit', () => {
          clearTimeout(killTimer)
          resolve(undefined)
        })
      })
    }
    await rm(dataDir, { recursive: true, force: true })
  }
}

/**
 * Builds, stamps, and verifies a single-platform standalone daemon archive.
 *
 * @param {{
 *   out: string,
 *   version: string,
 *   build: string,
 *   channel: 'stable' | 'beta',
 *   commit?: string,
 *   builtAt?: string,
 *   buildDir?: string,
 *   node?: string | null,
 *   skipBuild?: boolean,
 *   skipSmoke?: boolean,
 *   maxGlibc?: string,
 * }} options
 */
export async function buildDaemonPackage(options) {
  const {
    out,
    version,
    build,
    channel,
    commit = readGitCommit(ROOT) || '',
    builtAt = new Date().toISOString(),
    buildDir = path.join(ROOT, 'out'),
    node = null,
    skipBuild = false,
    skipSmoke = false,
    maxGlibc = DEFAULT_MAX_GLIBC,
  } = options

  if (!isValidBuildNumber(build)) {
    throw new Error(`build ${build} must be 1 to 18 digits with no leading zero`)
  }
  if (channel !== 'stable' && channel !== 'beta') {
    throw new Error(`channel must be stable or beta, not ${channel}`)
  }

  if (!skipBuild) {
    const vite = path.join(ROOT, 'node_modules', '.bin', 'vite')
    await run(vite, ['build', '-c', 'vite.daemon.config.mts'], {
      SARTO_BUILD_PLACEHOLDER: '1',
    })
    const xcode = await developerDir()
    await run(process.execPath, ['tools/install/device-helpers.mjs'], {
      ...(xcode ? { DEVELOPER_DIR: xcode } : {}),
    })
  }

  const stage = await mkdtemp(path.join(os.tmpdir(), 'sarto-daemon-release-'))
  try {
    // Stage directly into `unpacked` (single compression pass) and always checksum-verify Node.js
    // from nodejs.org for release artifacts (cacheDir: null).
    const unpacked = path.join(stage, 'unpacked')
    const staged = await stageDaemonPackage({
      dest: unpacked,
      build: buildDir,
      node,
      cacheDir: null,
    })
    const pkgName = staged.name
    const archiveName = `${pkgName}.tar.gz`
    const pkgDir = staged.dir
    const stamped = await stampBuildInfo(pkgDir, {
      version,
      build,
      channel,
      commit,
      builtAt,
    })
    if (stamped === 0) {
      throw new Error(
        'The daemon in out/ was not built with placeholders (SARTO_BUILD_PLACEHOLDER=1)',
      )
    }

    const { stdout: reported } = await execFile(path.join(pkgDir, 'bin', 'sarto'), ['--version'])
    if (reported.trim() !== version) {
      throw new Error(`The standalone daemon reports ${reported.trim()}, expected ${version}`)
    }

    if (process.platform === 'linux') {
      const addons = await findNativeAddons(path.join(pkgDir, 'daemon', 'node_modules'))
      if (!addons.some((file) => path.basename(file) === 'pty.node')) {
        throw new Error('Packaged Linux daemon is missing node-pty pty.node binary')
      }
      const binariesToVerify = [path.join(pkgDir, 'node', 'bin', 'node'), ...addons]
      for (const bin of binariesToVerify) {
        const maxSym = await verifyGlibcCeiling(bin, maxGlibc)
        console.log(
          `Verified ${path.relative(pkgDir, bin)} max GLIBC symbol: ${maxSym ?? 'none'} (<= ${maxGlibc})`,
        )
      }
    }

    if (!skipSmoke) {
      await smokeTestPty(pkgDir)
      console.log('PTY smoke test passed')
      await smokeTestDaemon(pkgDir)
      console.log('Headless daemon startup smoke test passed')
    }

    await mkdir(out, { recursive: true })
    const archive = path.join(out, archiveName)
    await execFile('tar', ['-czf', archive, '-C', unpacked, pkgName], {
      env: { ...process.env, COPYFILE_DISABLE: '1' },
    })
    const sha256 = await sha256Of(archive)
    const size = (await stat(archive)).size
    // assemble-daemon-release.mjs takes the archive into a release only when these match it.
    const meta = {
      platform: process.platform,
      arch: process.arch,
      name: archiveName,
      size,
      sha256,
      version,
      build,
      channel,
    }
    await writeFile(path.join(out, `${pkgName}.meta.json`), `${JSON.stringify(meta, null, 2)}\n`)
    return { archive, ...meta }
  } finally {
    await rm(stage, { recursive: true, force: true })
  }
}

function isMainModule() {
  if (import.meta.main !== undefined) return import.meta.main
  if (!process.argv[1]) return false
  try {
    return realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))
  } catch {
    return false
  }
}

if (isMainModule()) {
  const { values } = parseArgs({
    options: {
      version: { type: 'string' },
      build: { type: 'string' },
      channel: { type: 'string' },
      commit: { type: 'string' },
      'built-at': { type: 'string' },
      out: { type: 'string' },
      'build-dir': { type: 'string' },
      node: { type: 'string' },
      'skip-build': { type: 'boolean' },
      'skip-smoke': { type: 'boolean' },
      'max-glibc': { type: 'string' },
    },
  })
  if (!values.version || !values.build || !values.out) {
    console.error(
      'Usage: node tools/sarto/build-daemon-package.mjs --version <ver> --build <12-digits> ' +
        '--out <dir> [--channel stable|beta] [--commit <sha>] [--built-at <iso>] ' +
        '[--build-dir <out>] [--node <folder>] [--skip-build] [--skip-smoke] [--max-glibc 2.28]',
    )
    process.exit(2)
  }
  const channel = values.channel?.trim() || 'stable'
  if (channel !== 'stable' && channel !== 'beta') {
    console.error(`--channel must be stable or beta, not ${channel}`)
    process.exit(2)
  }
  const result = await buildDaemonPackage({
    out: path.resolve(values.out),
    version: values.version.trim(),
    build: values.build.trim(),
    channel,
    commit: values.commit?.trim() || undefined,
    builtAt: values['built-at']?.trim() || undefined,
    buildDir: values['build-dir'] ? path.resolve(values['build-dir']) : undefined,
    node: values.node ? path.resolve(values.node) : null,
    skipBuild: values['skip-build'] === true,
    skipSmoke: values['skip-smoke'] === true,
    maxGlibc: values['max-glibc']?.trim() || DEFAULT_MAX_GLIBC,
  })
  console.log(`Built ${result.name} (${result.size} bytes, sha256=${result.sha256})`)
}
