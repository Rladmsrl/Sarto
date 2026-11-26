// @ts-check
// Packages the daemon for this computer's system and architecture, after pnpm build, into
// <out>/sarto-daemon-<os>-<arch>.tar.gz with its checksum beside it, for a release to upload:
//
//   node tools/daemon/package.mjs --out <folder> [--node <folder>] [--build <folder>]
//
// The package holds the Node.js release pinned below, the daemon and the type viewers it serves,
// node-pty as this checkout built it, and bin/sarto, which runs the CLI on that Node.js. --node takes
// an unpacked Node.js release in place of downloading the pinned one; --build reads the builds from a
// folder other than out/.

import { execFile } from 'node:child_process'
import { createHash } from 'node:crypto'
import { createReadStream, existsSync, readFileSync, realpathSync } from 'node:fs'
import { chmod, copyFile, cp, mkdir, mkdtemp, rename, rm, writeFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseArgs, promisify } from 'node:util'

const exec = promisify(execFile)

export const NODE_VERSION = '24.22.2'

const ROOT = fileURLToPath(new URL('../..', import.meta.url))

/**
 * The package's name for a system and architecture, as the install script asks for it.
 *
 * @param {NodeJS.Platform} platform
 * @param {string} arch
 */
export function packageName(platform, arch) {
  const supported =
    (platform === 'linux' && (arch === 'x64' || arch === 'arm64')) ||
    (platform === 'darwin' && arch === 'arm64')
  if (!supported) throw new Error(`The daemon has no package for ${platform}-${arch}`)
  return `sarto-daemon-${platform}-${arch}`
}

/** @param {string} file */
export function sha256Of(file) {
  return new Promise((resolve, reject) => {
    const hash = createHash('sha256')
    createReadStream(file)
      .on('error', reject)
      .on('data', (chunk) => hash.update(chunk))
      .on('end', () => resolve(hash.digest('hex')))
  })
}

/**
 * The hash a SHASUMS256.txt or a release's checksums list for `name`, or null.
 *
 * @param {string} sums
 * @param {string} name
 */
export function listedSha256(sums, name) {
  for (const line of sums.split('\n')) {
    const [hash, file] = line.trim().split(/\s+/)
    if (hash && (file === name || file === `*${name}`)) return hash
  }
  return null
}

/**
 * Downloads the pinned Node.js release into `into` (or reuses a copy cached under `cacheRoot`),
 * checked against nodejs.org's checksums, and returns the folder it unpacks to. The cache's marker
 * keeps the SHA-256 of the archive and of `bin/node` as checked then, and a copy whose `bin/node`
 * no longer hashes to it is downloaded again.
 *
 * @param {NodeJS.Platform} platform
 * @param {string} arch
 * @param {string} into
 * @param {string | null} cacheRoot
 */
async function downloadNode(platform, arch, into, cacheRoot) {
  const dist = `https://nodejs.org/dist/v${NODE_VERSION}`
  const name = `node-v${NODE_VERSION}-${platform}-${arch}`
  const cachedDir = cacheRoot ? path.join(cacheRoot, 'node', name) : null
  const verifiedMarker = cachedDir ? path.join(cachedDir, '.verified') : null
  if (
    cachedDir &&
    verifiedMarker &&
    existsSync(verifiedMarker) &&
    existsSync(path.join(cachedDir, 'bin', 'node')) &&
    existsSync(path.join(cachedDir, 'LICENSE'))
  ) {
    const [, nodeHash] = readFileSync(verifiedMarker, 'utf8').trim().split(/\s+/)
    if (nodeHash && nodeHash === (await sha256Of(path.join(cachedDir, 'bin', 'node')))) {
      return cachedDir
    }
  }

  const sums = await fetch(`${dist}/SHASUMS256.txt`)
  if (!sums.ok) throw new Error(`${dist}/SHASUMS256.txt answered ${sums.status}`)
  const expected = listedSha256(await sums.text(), `${name}.tar.gz`)
  if (!expected) throw new Error(`nodejs.org lists no checksum for ${name}.tar.gz`)
  const response = await fetch(`${dist}/${name}.tar.gz`)
  if (!response.ok) throw new Error(`${dist}/${name}.tar.gz answered ${response.status}`)
  const archive = path.join(into, `${name}.tar.gz`)
  await writeFile(archive, Buffer.from(await response.arrayBuffer()))
  const actual = await sha256Of(archive)
  if (actual !== expected) {
    throw new Error(`${name}.tar.gz has the checksum ${actual}; nodejs.org lists ${expected}`)
  }
  await exec('tar', ['-xzf', archive, '-C', into])
  const unpacked = path.join(into, name)

  if (cachedDir && verifiedMarker) {
    const cacheParent = path.dirname(cachedDir)
    await mkdir(cacheParent, { recursive: true })
    const tmp = await mkdtemp(path.join(cacheParent, `.${name}-`))
    try {
      const staged = path.join(tmp, name)
      await cp(unpacked, staged, { recursive: true })
      const nodeHash = await sha256Of(path.join(unpacked, 'bin', 'node'))
      await writeFile(path.join(staged, '.verified'), `${actual} ${nodeHash}\n`)
      await rm(cachedDir, { recursive: true, force: true })
      await rename(staged, cachedDir)
      return cachedDir
    } catch {
      // Cache persistence is best-effort; fall back to the verified temp unpack.
      return unpacked
    } finally {
      await rm(tmp, { recursive: true, force: true })
    }
  }
  return unpacked
}

/**
 * @param {string} file
 * @param {string} what
 */
function must(file, what) {
  if (!existsSync(file)) throw new Error(`${what} is missing: ${file}`)
}

/**
 * Builds the package and returns its archive and checksum.
 *
 * @param {{
 *   out: string,
 *   build?: string,
 *   node?: string | null,
 *   cacheDir?: string | null,
 *   root?: string,
 *   platform?: NodeJS.Platform,
 *   arch?: string,
 * }} options
 */
export async function packageDaemon({
  out,
  build = path.join(ROOT, 'out'),
  node = null,
  cacheDir = process.env.SARTO_PACKAGE_CACHE?.trim() || path.join(ROOT, '.cache', 'sarto-package'),
  root = ROOT,
  platform = process.platform,
  arch = process.arch,
}) {
  const name = packageName(platform, arch)
  must(path.join(build, 'daemon', 'main.cjs'), "The daemon's build; run pnpm build first. It")
  const stage = await mkdtemp(path.join(os.tmpdir(), 'sarto-daemon-package-'))
  try {
    const dir = path.join(stage, name)
    await cp(path.join(build, 'daemon'), path.join(dir, 'daemon'), { recursive: true })

    // node-pty's loader and its binaries: the ones this checkout built in build/Release, or else
    // the prebuilt ones node-pty ships for the target, which its loader also looks for.
    const require = createRequire(path.join(root, 'package.json'))
    const pty = path.dirname(require.resolve('node-pty/package.json'))
    const ptyOut = path.join(dir, 'daemon', 'node_modules', 'node-pty')
    const built = path.join(pty, 'build', 'Release')
    const binaries = existsSync(path.join(built, 'pty.node'))
      ? built
      : path.join(pty, 'prebuilds', `${platform}-${arch}`)
    must(path.join(binaries, 'pty.node'), "node-pty's binary")
    const binariesOut = path.join(ptyOut, path.relative(pty, binaries))
    await mkdir(binariesOut, { recursive: true })
    for (const file of ['package.json', 'LICENSE']) {
      await copyFile(path.join(pty, file), path.join(ptyOut, file))
    }
    await cp(path.join(pty, 'lib'), path.join(ptyOut, 'lib'), {
      recursive: true,
      filter: (source) => !/\.(test\.js|map)$/.test(source),
    })
    for (const file of ['pty.node', 'spawn-helper']) {
      const source = path.join(binaries, file)
      if (existsSync(source)) await cp(source, path.join(binariesOut, file))
    }
    // node-pty's prebuilt macOS spawn-helper ships without its execute bit (microsoft/node-pty#919).
    const helperOut = path.join(binariesOut, 'spawn-helper')
    if (existsSync(helperOut)) await chmod(helperOut, 0o755)

    // The device host runs agent-device and serve-sim as programs, so they ship with what they
    // load; serve-sim only where it runs, macOS on Apple silicon.
    const runtime = [
      'agent-device',
      ...(platform === 'darwin' && arch === 'arm64' ? ['@expo/serve-sim'] : []),
    ]
    const copied = new Set()
    /** @param {string} name @param {string} from */
    const copyPackage = async (name, from) => {
      if (copied.has(name)) return
      const resolve = createRequire(path.join(from, 'package.json'))
      const paths = resolve.resolve.paths(name) ?? []
      const source = paths
        .map((dir) => path.join(dir, name))
        .find((dir) => existsSync(path.join(dir, 'package.json')))
      if (!source) throw new Error(`${name} is not installed`)
      copied.add(name)
      await cp(realpathSync(source), path.join(dir, 'daemon', 'node_modules', name), {
        recursive: true,
        dereference: true,
      })
      const manifest = JSON.parse(readFileSync(path.join(source, 'package.json'), 'utf8'))
      for (const dependency of Object.keys(manifest.dependencies ?? {})) {
        await copyPackage(dependency, realpathSync(source))
      }
    }
    for (const name of runtime) await copyPackage(name, root)
    // The device host's helpers, which tools/install/device-helpers.mjs puts in out/helpers.
    if (existsSync(path.join(build, 'helpers'))) {
      await cp(path.join(build, 'helpers'), path.join(dir, 'helpers'), { recursive: true })
    }

    const nodeDir = node ?? (await downloadNode(platform, arch, stage, cacheDir))
    must(path.join(nodeDir, 'bin', 'node'), 'Node.js')
    must(path.join(nodeDir, 'LICENSE'), "Node.js's license")
    await mkdir(path.join(dir, 'node', 'bin'), { recursive: true })
    await cp(path.join(nodeDir, 'bin', 'node'), path.join(dir, 'node', 'bin', 'node'))
    await copyFile(path.join(nodeDir, 'LICENSE'), path.join(dir, 'node', 'LICENSE'))

    await mkdir(path.join(dir, 'bin'))
    await copyFile(path.join(ROOT, 'tools', 'daemon', 'sarto.sh'), path.join(dir, 'bin', 'sarto'))
    await chmod(path.join(dir, 'bin', 'sarto'), 0o755)
    await copyFile(path.join(root, 'LICENSE'), path.join(dir, 'LICENSE'))

    await mkdir(out, { recursive: true })
    const archive = path.join(out, `${name}.tar.gz`)
    // macOS tar would add AppleDouble files for extended attributes.
    await exec('tar', ['-czf', archive, '-C', stage, name], {
      env: { ...process.env, COPYFILE_DISABLE: '1' },
    })
    const sha256 = await sha256Of(archive)
    await writeFile(`${archive}.sha256`, `${sha256}  ${name}.tar.gz\n`)
    return { archive, sha256 }
  } finally {
    await rm(stage, { recursive: true, force: true })
  }
}

if (import.meta.main) {
  const { values } = parseArgs({
    options: { out: { type: 'string' }, node: { type: 'string' }, build: { type: 'string' } },
  })
  if (!values.out) {
    console.error('Usage: node tools/daemon/package.mjs --out <folder> [--node <folder>]')
    process.exit(2)
  }
  const { archive, sha256 } = await packageDaemon({
    out: path.resolve(values.out),
    build: values.build ? path.resolve(values.build) : undefined,
    node: values.node ? path.resolve(values.node) : null,
  })
  console.log(`Packaged ${archive}\nsha256 ${sha256}`)
}
