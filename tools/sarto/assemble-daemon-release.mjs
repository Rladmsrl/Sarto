// @ts-check
// Assembles one or more platform standalone daemon tarballs into a release directory with
// combined `sarto-daemon-sha256sums.txt`, `install.sh` (+ `.sig`), signed multi-platform
// `latest-daemon.json` / `beta-daemon.json` (+ `.sig`), and optional signed `harnesses.json`.
//
//   node tools/sarto/assemble-daemon-release.mjs \
//     --in <dir> [--in <dir2> ...] --out <dir> \
//     --version <daemonVersion> --tag <daemonTag> --channel <stable|beta> \
//     --build <12-digits> [--built-at <iso>] \
//     [--require-platforms darwin-arm64,linux-x64,linux-arm64] \
//     [--harness-checks <file>] [--allow-unsigned]

import { createHash } from 'node:crypto'
import { createReadStream } from 'node:fs'
import { copyFile, mkdir, readdir, readFile, stat, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseArgs } from 'node:util'
import { isValidBuildNumber, isValidTag } from './build-version.mjs'
import { buildHarnessManifest, signHarnessManifest } from './harnesses.mjs'
import { signerFrom, updateFileMessage } from './signing.mjs'

const ROOT = fileURLToPath(new URL('../..', import.meta.url))
const DAEMON_MANIFEST = { stable: 'latest-daemon.json', beta: 'beta-daemon.json' }
const ARCHIVE_RE = /^sarto-daemon-(darwin|linux)-(x64|arm64)\.tar\.gz$/

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
 * Parses a daemon archive filename into its platform and arch, or null.
 *
 * @param {string} name
 * @returns {{ platform: 'darwin' | 'linux', arch: 'x64' | 'arm64' } | null}
 */
export function parseDaemonArchiveName(name) {
  const match = ARCHIVE_RE.exec(name)
  if (!match) return null
  return {
    platform: /** @type {'darwin' | 'linux'} */ (match[1]),
    arch: /** @type {'x64' | 'arm64'} */ (match[2]),
  }
}

/**
 * Assembles standalone daemon packages from `inputDirs` into `outDir` and signs the release files.
 *
 * @param {{
 *   inputDirs: string[],
 *   outDir: string,
 *   daemonVersion: string,
 *   daemonTag: string,
 *   channel: 'stable' | 'beta',
 *   build: string,
 *   builtAt?: string,
 *   requirePlatforms?: string[],
 *   signUpdateFile?: ((message: Buffer) => Buffer) | null,
 *   harnessChecks?: string | null,
 *   installScriptPath?: string,
 * }} options
 */
export async function assembleDaemonRelease(options) {
  const {
    inputDirs,
    outDir,
    daemonVersion,
    daemonTag,
    channel,
    build,
    builtAt = new Date().toISOString(),
    requirePlatforms = [],
    signUpdateFile = null,
    harnessChecks = null,
    installScriptPath = path.join(ROOT, 'tools', 'sarto', 'install.sh'),
  } = options

  if (channel !== 'stable' && channel !== 'beta') {
    throw new Error(`channel must be stable or beta, not ${channel}`)
  }
  if (!isValidBuildNumber(build)) {
    throw new Error(`build ${build} must be 1 to 18 digits with no leading zero`)
  }
  if (!isValidTag(daemonTag)) {
    throw new Error(`tag ${daemonTag} is not valid`)
  }

  /** @type {Map<string, { platform: 'darwin' | 'linux', arch: 'x64' | 'arm64', name: string, source: string }>} */
  const found = new Map()
  for (const dir of inputDirs) {
    const entries = await readdir(dir, { withFileTypes: true })
    for (const entry of entries) {
      if (!entry.isFile()) continue
      const parsed = parseDaemonArchiveName(entry.name)
      if (!parsed) continue
      const key = `${parsed.platform}-${parsed.arch}`
      const source = path.resolve(dir, entry.name)
      const existing = found.get(key)
      if (existing && existing.source !== source) {
        throw new Error(`Duplicate daemon archive for ${key}: ${existing.source} and ${source}`)
      }
      found.set(key, { ...parsed, name: entry.name, source })
    }
  }

  if (found.size === 0) {
    throw new Error(
      `No sarto-daemon-<platform>-<arch>.tar.gz archives found in ${inputDirs.join(', ')}`,
    )
  }

  const missing = requirePlatforms.filter((target) => !found.has(target))
  if (missing.length > 0) {
    throw new Error(`Missing required daemon platform archives: ${missing.join(', ')}`)
  }

  await mkdir(outDir, { recursive: true })
  const ordered = [...found.values()].sort((a, b) =>
    `${a.platform}-${a.arch}`.localeCompare(`${b.platform}-${b.arch}`),
  )

  /** @type {Array<{ platform: string, arch: string, name: string, size: number, sha256: string }>} */
  const files = []
  /** @type {string[]} */
  const sumLines = []

  for (const item of ordered) {
    const dest = path.resolve(outDir, item.name)
    if (item.source !== dest) {
      await copyFile(item.source, dest)
    }
    const sha256 = await sha256Of(dest)
    const size = (await stat(dest)).size
    files.push({
      platform: item.platform,
      arch: item.arch,
      name: item.name,
      size,
      sha256,
    })
    sumLines.push(`${sha256}  ${item.name}`)
  }

  await writeFile(path.join(outDir, 'sarto-daemon-sha256sums.txt'), `${sumLines.join('\n')}\n`)

  const installBody = await readFile(installScriptPath)
  await writeFile(path.join(outDir, 'install.sh'), installBody)
  if (signUpdateFile) {
    const installSignature = signUpdateFile(updateFileMessage('install.sh', installBody))
    await writeFile(path.join(outDir, 'install.sh.sig'), `${installSignature.toString('base64')}\n`)
  }

  const manifestName = DAEMON_MANIFEST[channel]
  const manifest = {
    version: daemonVersion,
    channel,
    build,
    tag: daemonTag,
    releaseDate: builtAt,
    files,
  }
  const manifestBody = Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`, 'utf8')
  await writeFile(path.join(outDir, manifestName), manifestBody)
  if (signUpdateFile) {
    const manifestSignature = signUpdateFile(updateFileMessage(manifestName, manifestBody))
    await writeFile(
      path.join(outDir, `${manifestName}.sig`),
      `${manifestSignature.toString('base64')}\n`,
    )
  }

  if (harnessChecks) {
    const document = buildHarnessManifest(
      JSON.parse(await readFile(path.resolve(harnessChecks), 'utf8')),
    )
    await writeFile(path.join(outDir, 'harnesses.json'), signHarnessManifest(document).body)
  }

  return { manifestName, manifest, files }
}

if (import.meta.main) {
  const { values } = parseArgs({
    options: {
      in: { type: 'string', multiple: true },
      out: { type: 'string' },
      version: { type: 'string' },
      tag: { type: 'string' },
      channel: { type: 'string' },
      build: { type: 'string' },
      'built-at': { type: 'string' },
      'require-platforms': { type: 'string' },
      'harness-checks': { type: 'string' },
      'allow-unsigned': { type: 'boolean' },
    },
  })
  const inputDirs = (values.in ?? []).map((dir) => path.resolve(dir))
  if (inputDirs.length === 0 || !values.out || !values.version || !values.tag || !values.build) {
    console.error(
      'Usage: node tools/sarto/assemble-daemon-release.mjs --in <dir> [--in <dir2>] --out <dir> ' +
        '--version <ver> --tag <tag> --build <12-digits> [--channel stable|beta] ' +
        '[--built-at <iso>] [--require-platforms darwin-arm64,linux-x64,linux-arm64] ' +
        '[--harness-checks <file>] [--allow-unsigned]',
    )
    process.exit(2)
  }
  const channel = values.channel?.trim() || 'stable'
  if (channel !== 'stable' && channel !== 'beta') {
    console.error(`--channel must be stable or beta, not ${channel}`)
    process.exit(2)
  }
  const requirePlatforms = (values['require-platforms'] ?? '')
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean)
  const signUpdateFile = values['allow-unsigned']
    ? null
    : signerFrom('release', 'SARTO_UPDATE_SIGNING_KEY')

  const result = await assembleDaemonRelease({
    inputDirs,
    outDir: path.resolve(values.out),
    daemonVersion: values.version.trim(),
    daemonTag: values.tag.trim(),
    channel,
    build: values.build.trim(),
    builtAt: values['built-at']?.trim() || undefined,
    requirePlatforms,
    signUpdateFile,
    harnessChecks: values['harness-checks'] ? path.resolve(values['harness-checks']) : null,
  })
  console.log(
    `Assembled ${result.manifestName} (${result.files.map((f) => f.name).join(', ')})` +
      `${signUpdateFile ? ' [signed]' : ' [unsigned]'}`,
  )
}
