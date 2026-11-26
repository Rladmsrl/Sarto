// @ts-check
// Packages Sarto for macOS on Apple silicon: the SwiftUI app with the daemon, the Node.js release
// it is pinned to, node-pty, the device host's tools and helpers in Contents/Resources/runtime, so
// the app runs on a Mac without Node.js and outside this checkout.
//
//   node apps/apple/scripts/package-mac.mjs [--version <appVer>] [--daemon-version <daemonVer>]
//     [--channel stable|beta|dev] [--daemon-channel stable|beta|dev] [--build <digits>]
//     [--out <folder>] [--skip-js]
//     [--skip-helpers] [--node <folder>] [--debug] [--clean]
//
// Local packaging caches Xcode's DerivedData and the SHA-256-verified Node.js runtime under
// `.cache/sarto-package/` (override with SARTO_PACKAGE_CACHE) so repeat local builds take seconds
// instead of full cold compiles. Pass `--clean` for a fresh temporary DerivedData and a Node.js
// downloaded again (as release.mjs does), and `--debug` for fast local Debug-configuration test
// bundles.
//
// The app and daemon versions are decoupled:
// - App version defaults to MARKETING_VERSION in apps/apple/project.yml (or --version).
// - Daemon version defaults to `version` in package.json (or --daemon-version).
// - Build number defaults to a monotonic 12-digit UTC timestamp (YYMMDDHHmmss) written to
//   CFBundleVersion and the daemon's build metadata.
// - Channel defaults to `stable` when SARTO_SIGN_IDENTITY is set and neither version carries a
//   prerelease suffix, or `dev` for ad-hoc local builds. Passing `--channel beta` formats base
//   X.Y.Z versions as `X.Y.Z-beta.<build>`; for publishable beta builds always pass the next
//   upcoming X.Y.Z above the latest shipped stable tag (in SemVer `X.Y.Z-beta.* < X.Y.Z`).
// - `--daemon-channel` defaults to the channel; an app-only release passes `stable` to bundle the
//   published daemon X.Y.Z as it is.
//
// --skip-js reuses out/ as it is, which must then hold a placeholder daemon build; --skip-helpers
// leaves out/helpers alone; --node takes an unpacked Node.js release instead of downloading the
// pinned one. SARTO_SIGN_IDENTITY names the signing identity, ad hoc by default; a real identity
// turns on the hardened runtime and a secure timestamp, which notarization requires, and builds
// the app to update itself in place (Install mode) rather than link to the download (Link).
// SARTO_BUNDLE_ID builds it under another bundle identifier, to test a release beside the
// installed app without sharing its preferences.

import { execFile as execFileCb, spawn } from 'node:child_process'
import { existsSync } from 'node:fs'
import { mkdir, mkdtemp, readdir, rm, stat, writeFile } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseArgs, promisify } from 'node:util'
import { packageDaemon } from '../../../tools/daemon/package.mjs'
import {
  checkReleaseVersionOrder,
  formatChannelVersion,
  generateBuildNumber,
  isValidBuildNumber,
  marketingVersion,
  readAppBaseVersion,
  readDaemonBaseVersion,
  readGitCommit,
  resolveBuildChannel,
} from '../../../tools/sarto/build-version.mjs'
import {
  RUNTIME_FILE,
  runtimeFingerprint,
  stampBuildInfo,
} from '../../../tools/sarto/runtime-fingerprint.mjs'

const execFile = promisify(execFileCb)
const ROOT = fileURLToPath(new URL('../../..', import.meta.url))
const APPLE = path.join(ROOT, 'apps', 'apple')
const NODE_ENTITLEMENTS = path.join(APPLE, 'scripts', 'node.entitlements')
const XCODE = '/Applications/Xcode.app/Contents/Developer'

/**
 * Runs a program with inherited output.
 *
 * @param {string} command
 * @param {string[]} args
 * @param {{ env?: Record<string, string | undefined> }} [options]
 */
function run(command, args, options = {}) {
  const env = { ...process.env, ...options.env }
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd: ROOT, stdio: 'inherit', env })
    child.on('error', reject)
    child.on('exit', (code) =>
      code === 0
        ? resolve(undefined)
        : reject(new Error(`${command} ${args.join(' ')} exited with ${code}`)),
    )
  })
}

/** Xcode itself, when xcode-select points at the Command Line Tools, which cannot build the app. */
async function developerDir() {
  if (process.env.DEVELOPER_DIR) return process.env.DEVELOPER_DIR
  const { stdout } = await execFile('xcode-select', ['-p']).catch(() => ({ stdout: '' }))
  if (stdout.trim().includes('CommandLineTools') && existsSync(XCODE)) return XCODE
  return undefined
}

/**
 * Every file under `dir`, deepest first, so nested code is signed before what contains it.
 *
 * @param {string} dir
 * @returns {Promise<string[]>}
 */
async function walk(dir) {
  /** @type {string[]} */
  const files = []
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name)
    if (entry.isSymbolicLink()) continue
    if (entry.isDirectory()) files.push(...(await walk(full)))
    else files.push(full)
  }
  return files
}

/** @param {string} file */
async function isMachO(file) {
  const { stdout } = await execFile('file', ['-b', file])
  return stdout.startsWith('Mach-O')
}

/**
 * @param {string} target
 * @param {string} identity
 * @param {string} [entitlements]
 */
async function sign(target, identity, entitlements) {
  const args = ['--force', '--sign', identity, identity === '-' ? '--timestamp=none' : '--timestamp']
  if (identity !== '-') args.push('--options', 'runtime')
  if (entitlements && identity !== '-') args.push('--entitlements', entitlements)
  await execFile('codesign', [...args, target])
}

async function main() {
  if (process.platform !== 'darwin' || process.arch !== 'arm64') {
    throw new Error('Sarto is packaged on macOS on Apple silicon, the only system it ships for')
  }
  const { values } = parseArgs({
    options: {
      version: { type: 'string' },
      'daemon-version': { type: 'string' },
      channel: { type: 'string' },
      'daemon-channel': { type: 'string' },
      build: { type: 'string' },
      out: { type: 'string' },
      node: { type: 'string' },
      'skip-js': { type: 'boolean' },
      'skip-helpers': { type: 'boolean' },
      debug: { type: 'boolean' },
      clean: { type: 'boolean' },
    },
  })
  const startedAt = Date.now()
  const out = path.resolve(values.out ?? path.join(ROOT, 'dist'))
  const cacheRoot =
    process.env.SARTO_PACKAGE_CACHE?.trim() || path.join(ROOT, '.cache', 'sarto-package')
  const configuration = values.debug ? 'Debug' : 'Release'
  const clean = Boolean(values.clean)
  const identity = process.env.SARTO_SIGN_IDENTITY?.trim() || '-'
  const signed = identity !== '-'
  const build = values.build?.trim() || generateBuildNumber()
  if (!isValidBuildNumber(build)) {
    throw new Error(`--build ${build} must be 1 to 18 digits with no leading zero`)
  }
  const rawAppVersion = values.version?.trim() || readAppBaseVersion(ROOT)
  const rawDaemonVersion = values['daemon-version']?.trim() || readDaemonBaseVersion(ROOT)
  const channel = resolveBuildChannel(
    rawAppVersion,
    values.channel,
    signed ? 'stable' : 'dev',
  )
  const appVersion = formatChannelVersion(rawAppVersion, channel, build)
  const appMarketing = marketingVersion(appVersion)
  const daemonChannel = resolveBuildChannel(rawDaemonVersion, values['daemon-channel'], channel)
  const daemonVersion = formatChannelVersion(rawDaemonVersion, daemonChannel, build)
  if (channel === 'beta') {
    for (const check of [
      checkReleaseVersionOrder({ kind: 'app', channel, version: appVersion, root: ROOT }),
      ...(daemonChannel === 'beta'
        ? [
            checkReleaseVersionOrder({
              kind: 'daemon',
              channel: daemonChannel,
              version: daemonVersion,
              root: ROOT,
            }),
          ]
        : []),
    ]) {
      if (check) console.warn(`Warning: ${check}`)
    }
  }
  const commit = process.env.SARTO_GIT_COMMIT?.trim() || readGitCommit(ROOT) || ''
  const builtAt = new Date().toISOString()

  const updateMode = identity === '-' ? 'link' : 'install'
  const bundleId = process.env.SARTO_BUNDLE_ID?.trim()
  if (bundleId && !/^[A-Za-z0-9][A-Za-z0-9.-]{0,254}$/.test(bundleId)) {
    throw new Error(`SARTO_BUNDLE_ID ${bundleId} is not a bundle identifier`)
  }
  const bin = (/** @type {string} */ name) => path.join(ROOT, 'node_modules', '.bin', name)
  /** @type {Record<string, string | undefined>} */
  const xcodeEnv = { SARTO_PACKAGING: '1' }
  const xcode = await developerDir()
  if (xcode) xcodeEnv.DEVELOPER_DIR = xcode

  if (!values['skip-js']) {
    // The daemon's version and build metadata go in after the runtime's fingerprint is taken.
    await run(bin('vite'), ['build', '-c', 'vite.daemon.config.mts'], {
      env: { SARTO_BUILD_PLACEHOLDER: '1' },
    })
  }
  if (!values['skip-helpers']) {
    await run(process.execPath, ['tools/install/device-helpers.mjs'], { env: xcodeEnv })
  }

  const stage = await mkdtemp(path.join(os.tmpdir(), 'sarto-package-'))
  try {
    const { archive } = await packageDaemon({
      out: stage,
      node: values.node ? path.resolve(values.node) : null,
      cacheDir: clean ? null : cacheRoot,
    })
    await execFile('tar', ['-xzf', archive, '-C', stage])
    const runtime = path.join(stage, path.basename(archive, '.tar.gz'))
    // Taken before build metadata goes in and before signing, which changes every Mach-O file on
    // each build, so a release whose daemon did not change keeps it; the app compares it to the
    // running daemon's to tell whether an update restarts the daemon.
    const fingerprint = await runtimeFingerprint(runtime)
    const stamped = await stampBuildInfo(runtime, {
      version: daemonVersion,
      build,
      channel: daemonChannel,
      commit,
      builtAt,
    })
    if (stamped === 0) {
      throw new Error('out/daemon was not built with placeholders; build it without --skip-js')
    }
    const { stdout: reported } = await execFile(path.join(runtime, 'node', 'bin', 'node'), [
      path.join(runtime, 'daemon', 'main.cjs'),
      '--version',
    ])
    if (reported.trim() !== daemonVersion) {
      throw new Error(
        `The daemon reports ${reported.trim()}, not ${daemonVersion}; build it without --skip-js`,
      )
    }
    await writeFile(
      path.join(runtime, RUNTIME_FILE),
      `${JSON.stringify(
        {
          fingerprint,
          version: daemonVersion,
          build,
          channel: daemonChannel,
          ...(commit ? { commit } : {}),
          builtAt,
        },
        null,
        2,
      )}\n`,
    )

    const derived = clean
      ? path.join(stage, 'derived')
      : path.join(cacheRoot, `derived-${configuration.toLowerCase()}`)
    if (!clean) await mkdir(derived, { recursive: true })
    await run(
      'xcodebuild',
      [
        '-project',
        path.join(APPLE, 'Sarto.xcodeproj'),
        '-scheme',
        'SartoMac',
        '-configuration',
        configuration,
        '-destination',
        'platform=macOS,arch=arm64',
        '-derivedDataPath',
        derived,
        'ARCHS=arm64',
        // Built ad hoc and signed below, inside out: Xcode would want a team for the Swift
        // packages' resource bundles before it signs with a real identity.
        'CODE_SIGN_IDENTITY=-',
        `MARKETING_VERSION=${appMarketing}`,
        `CURRENT_PROJECT_VERSION=${build}`,
        `SARTO_VERSION=${appVersion}`,
        `SARTO_BUILD_CHANNEL=${channel}`,
        `SARTO_GIT_COMMIT=${commit}`,
        `SARTO_UPDATE_MODE=${updateMode}`,
        'SARTO_PACKAGING=1',
        ...(bundleId ? [`PRODUCT_BUNDLE_IDENTIFIER=${bundleId}`] : []),
        'build',
      ],
      { env: xcodeEnv },
    )

    const built = path.join(derived, 'Build', 'Products', configuration, 'Sarto.app')
    const app = path.join(out, 'Sarto.app')
    await rm(app, { recursive: true, force: true })
    await execFile('mkdir', ['-p', out])
    await execFile('ditto', [built, app])
    // Guarantee Info.plist carries the current build's metadata even on cached incremental builds.
    // plutil takes the value as one argument and adds a missing key, where PlistBuddy would parse
    // quotes in it.
    const appPlist = path.join(app, 'Contents', 'Info.plist')
    const setPlist = async (/** @type {string} */ key, /** @type {string} */ val) => {
      await execFile('/usr/bin/plutil', ['-replace', key, '-string', val, appPlist])
    }
    await setPlist('CFBundleShortVersionString', appMarketing)
    await setPlist('CFBundleVersion', build)
    await setPlist('SartoVersion', appVersion)
    await setPlist('SartoBuildChannel', channel)
    await setPlist('SartoGitCommit', commit)
    await setPlist('SartoUpdateMode', updateMode)
    const resources = path.join(app, 'Contents', 'Resources')
    await rm(path.join(resources, 'daemon'), { recursive: true, force: true })
    await execFile('ditto', [runtime, path.join(resources, 'runtime')])

    for (const file of await walk(path.join(resources, 'runtime'))) {
      if (!(await isMachO(file))) continue
      const isNode = file === path.join(resources, 'runtime', 'node', 'bin', 'node')
      await sign(file, identity, isNode ? NODE_ENTITLEMENTS : undefined)
    }
    await sign(app, identity)
    await execFile('codesign', ['--verify', '--deep', '--strict', app])

    const { stdout } = await execFile('du', ['-sh', app])
    const size = stdout.split('\t')[0]
    const node = (await stat(path.join(resources, 'runtime', 'node', 'bin', 'node'))).size
    const elapsedSec = ((Date.now() - startedAt) / 1000).toFixed(1)
    console.log(
      `Packaged ${app} app=${appVersion} daemon=${daemonVersion} build=${build} channel=${channel}${commit ? ` commit=${commit}` : ''} (${configuration}, ${clean ? 'clean' : 'cached'}, ${elapsedSec}s, ${size}, Node.js ${Math.round(node / 1e6)} MB), signed ${identity}, ${updateMode} mode`,
    )
    console.log(`Runtime fingerprint ${fingerprint}`)
  } finally {
    await rm(stage, { recursive: true, force: true })
  }
}

await main()
