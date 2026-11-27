// @ts-check
// Builds Sarto releases on a Mac with Apple silicon into <out>/<tag>/, laid out for the Sarto
// server's releases folder:
//
//   node tools/sarto/release.mjs [--target all|app|daemon] [--channel stable|beta]
//     [--app-version <ver> | --version <ver>] [--daemon-version <ver>] [--build <12-digits>]
//     [--notes notes.md] [--out dist/release] [--node <folder>] [--skip-notarize]
//     [--delta-from v1,v2] [--harness-checks <file>]
//
// App and daemon versions are decoupled:
// - `--app-version` (or legacy `--version`) defaults to MARKETING_VERSION in apps/apple/project.yml.
// - `--daemon-version` defaults to `version` in package.json.
// - `--build` defaults to a 12-digit UTC timestamp (`YYMMDDHHmmss`).
// - On `--channel beta`, base `X.Y.Z` versions are formatted as `X.Y.Z-beta.<build>`, written into
//   `app-v<appVer>/` (`beta-mac.json`) and/or `daemon-v<daemonVer>/` (`beta-daemon.json`).
// - On `--channel stable`, an `all` release whose app and daemon share one version keeps the
//   single legacy `v<ver>/` folder (writing both `latest-mac.json` and `latest-daemon.json`);
//   decoupled app/daemon releases write `v<appVer>/` and `daemon-v<daemonVer>/` separately.
//
// SARTO_SIGN_IDENTITY names the Developer ID identity. Notarization takes SARTO_NOTARY_PROFILE, a
// notarytool keychain profile, or an App Store Connect API key in SARTO_NOTARY_KEY (the .p8 file),
// SARTO_NOTARY_KEY_ID and SARTO_NOTARY_ISSUER. SARTO_UPDATE_SIGNING_KEY holds the release key, and
// SARTO_HARNESSES_SIGNING_KEY the key the harness manifest it carries is signed with.
// Without an identity the release is ad hoc and in Link mode, for testing only; --skip-notarize
// leaves a signed one unnotarized, as with an Apple Development identity.

import { execFile as execFileCb, spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import { createReadStream, existsSync } from 'node:fs'
import { mkdir, mkdtemp, readdir, readFile, rm, stat, symlink, writeFile } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseArgs, promisify } from 'node:util'
import { assembleDaemonRelease } from './assemble-daemon-release.mjs'
import { buildDaemonPackage } from './build-daemon-package.mjs'
import {
  checkReleaseVersionOrder,
  compareVersions,
  formatChannelVersion,
  generateBuildNumber,
  isBetaVersion,
  isReleaseVersion,
  isValidBuildNumber,
  readAppBaseVersion,
  readDaemonBaseVersion,
  readGitCommit,
} from './build-version.mjs'
import { makeDelta } from './delta.mjs'
import { buildHarnessManifest, signHarnessManifest } from './harnesses.mjs'
import { releaseHighlights } from './release-notes.mjs'
import { RUNTIME_FILE } from './runtime-fingerprint.mjs'
import { signerFrom, updateFileMessage } from './signing.mjs'

const execFile = promisify(execFileCb)
const ROOT = fileURLToPath(new URL('../..', import.meta.url))
const ARCH = 'arm64'
const MAC_MANIFEST = { stable: 'latest-mac.json', beta: 'beta-mac.json' }
const GITHUB_RELEASE_SOURCE = 'https://github.com/Rladmsrl/Sarto/releases'
const RELEASE_SOURCE = 'https://sarto.1o.ink/releases'
const PREVIOUS_RELEASE_SOURCES = [GITHUB_RELEASE_SOURCE, RELEASE_SOURCE]

/** @param {string} message @returns {never} */
function fail(message) {
  console.error(`sarto release: ${message}`)
  process.exit(1)
}

/**
 * Runs a program with its output on this terminal.
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

/** Xcode itself, when xcode-select points at the Command Line Tools, as package-mac.mjs picks it. */
async function developerDir() {
  if (process.env.DEVELOPER_DIR) return process.env.DEVELOPER_DIR
  const xcode = '/Applications/Xcode.app/Contents/Developer'
  const { stdout } = await execFile('xcode-select', ['-p']).catch(() => ({ stdout: '' }))
  if (stdout.trim().includes('CommandLineTools') && existsSync(xcode)) return xcode
  return undefined
}

/** @param {string} file @param {'sha512' | 'sha256'} algorithm @param {'base64' | 'hex'} encoding */
function digest(file, algorithm, encoding) {
  return new Promise((resolve, reject) => {
    const hash = createHash(algorithm)
    createReadStream(file)
      .on('error', reject)
      .on('data', (chunk) => hash.update(chunk))
      .on('end', () => resolve(hash.digest(encoding)))
  })
}

/** notarytool's credentials from the environment, or null when none are set. */
function notaryCredentials() {
  const profile = process.env.SARTO_NOTARY_PROFILE?.trim()
  if (profile) return ['--keychain-profile', profile]
  const key = process.env.SARTO_NOTARY_KEY?.trim()
  const id = process.env.SARTO_NOTARY_KEY_ID?.trim()
  const issuer = process.env.SARTO_NOTARY_ISSUER?.trim()
  if (key && id && issuer) return ['--key', key, '--key-id', id, '--issuer', issuer]
  if (key || id || issuer) {
    fail('SARTO_NOTARY_KEY, SARTO_NOTARY_KEY_ID and SARTO_NOTARY_ISSUER go together')
  }
  return null
}

/** @param {string} file @param {string[]} credentials */
async function notarize(file, credentials) {
  console.log(`Notarizing ${path.basename(file)}`)
  await run('xcrun', ['notarytool', 'submit', file, '--wait', ...credentials])
}

/** @param {string} target */
async function staple(target) {
  await run('xcrun', ['stapler', 'staple', target])
}

/** Gatekeeper's verdict on the app, which must be a notarized Developer ID app. @param {string} app */
async function checkGatekeeper(app) {
  const { stderr } = await execFile('spctl', [
    '--assess',
    '--type',
    'execute',
    '--verbose=2',
    app,
  ]).catch((error) => fail(`Gatekeeper does not accept ${app}: ${error.stderr ?? error.message}`))
  if (!/source=Notarized Developer ID/.test(stderr)) {
    fail(`Gatekeeper does not take ${app} as a notarized Developer ID app: ${stderr.trim()}`)
  }
}

/** @param {string} app @param {string} zip */
async function zipApp(app, zip) {
  await rm(zip, { force: true })
  await execFile('ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', app, zip])
}

/** @param {string} app @param {string} dmg @param {string} version */
async function buildDiskImage(app, dmg, version) {
  const stage = await mkdtemp(path.join(os.tmpdir(), 'sarto-dmg-'))
  try {
    await execFile('ditto', [app, path.join(stage, path.basename(app))])
    await symlink('/Applications', path.join(stage, 'Applications'))
    await rm(dmg, { force: true })
    await execFile('hdiutil', [
      'create',
      '-volname',
      `Sarto ${version}`,
      '-srcfolder',
      stage,
      '-fs',
      'APFS',
      '-format',
      'UDZO',
      '-ov',
      dmg,
    ])
  } finally {
    await rm(stage, { recursive: true, force: true })
  }
}

/**
 * The versions a release carries deltas from: those --delta-from names, or else the two newest
 * eligible releases before it in the releases folder.
 *
 * @param {string | undefined} named
 * @param {string} releases
 * @param {string} version
 * @param {'stable' | 'beta'} channel
 */
async function deltaSources(named, releases, version, channel) {
  const allowed = (/** @type {string} */ v) =>
    channel === 'beta' ? isReleaseVersion(v) || isBetaVersion(v) : isReleaseVersion(v)
  const older = (/** @type {string} */ v) => allowed(v) && compareVersions(v, version) < 0
  if (named !== undefined)
    return named
      .split(',')
      .map((v) => v.trim().replace(/^(?:app-)?v/, ''))
      .filter(older)
  const found = (await readdir(releases).catch(() => []))
    .filter((name) => /^(?:app-)?v/.test(name))
    .map((name) => name.replace(/^(?:app-)?v/, ''))
    .filter(older)
  const unique = [...new Set(found)]
  return unique
    .sort((a, b) => compareVersions(a, b))
    .reverse()
    .slice(0, 2)
}

/**
 * Release `from`'s app as users have it, from its zip in the releases folder or else from Sarto's
 * release source, unpacked into `stage`.
 *
 * @param {string} from
 * @param {string} releases
 * @param {string} stage
 */
async function previousApp(from, releases, stage) {
  const name = `Sarto-${from}-${ARCH}.zip`
  const candidateTags = isBetaVersion(from)
    ? [`app-v${from}`, `v${from}`]
    : [`v${from}`, `app-v${from}`]
  let zip = candidateTags
    .map((tag) => path.join(releases, tag, name))
    .find((file) => existsSync(file))
  if (!zip) {
    zip = path.join(stage, name)
    let downloaded = false
    /** @type {string[]} */
    const errors = []
    outer: for (const source of PREVIOUS_RELEASE_SOURCES) {
      for (const tag of candidateTags) {
        try {
          const response = await fetch(`${source}/download/${tag}/${name}`)
          if (!response.ok) {
            errors.push(`${source}/${tag} answered ${response.status}`)
            continue
          }
          await writeFile(zip, Buffer.from(await response.arrayBuffer()))
          downloaded = true
          break outer
        } catch (error) {
          errors.push(`${source}/${tag}: ${/** @type {Error} */ (error).message}`)
        }
      }
    }
    if (!downloaded) throw new Error(`Could not fetch ${name} (${errors.join('; ')})`)
  }
  const folder = path.join(stage, `previous-${from}`)
  await rm(folder, { recursive: true, force: true })
  await mkdir(folder, { recursive: true })
  await execFile('ditto', ['-x', '-k', zip, folder])
  return path.join(folder, 'Sarto.app')
}

/** The lowest macOS the app runs on, from project.yml. */
async function minimumSystemVersion() {
  const yml = await readFile(path.join(ROOT, 'apps', 'apple', 'project.yml'), 'utf8')
  const match = /^\s*macOS:\s*"?([\d.]+)"?\s*$/m.exec(yml)
  if (!match) fail('project.yml names no macOS deployment target')
  return match[1]
}

/**
 * Packages the standalone daemon for this host and assembles checksums, install.sh (+ sig) and
 * signed daemon manifest into `outDir` (merging any extra platform archives from `extraDaemonDirs`).
 *
 * @param {{
 *   outDir: string,
 *   stage: string,
 *   daemonVersion: string,
 *   daemonTag: string,
 *   build: string,
 *   channel: 'stable' | 'beta',
 *   commit: string,
 *   builtAt: string,
 *   node: string | null,
 *   extraDaemonDirs: string[],
 *   skipSmoke: boolean,
 *   signUpdateFile: ((message: Buffer) => Buffer) | null,
 * }} opts
 */
async function buildStandaloneDaemon(opts) {
  const localOut = path.join(opts.stage, 'daemon-package')
  await buildDaemonPackage({
    out: localOut,
    version: opts.daemonVersion,
    build: opts.build,
    channel: opts.channel,
    commit: opts.commit,
    builtAt: opts.builtAt,
    node: opts.node,
    skipBuild: true,
    skipSmoke: opts.skipSmoke,
  })
  await assembleDaemonRelease({
    inputDirs: [localOut, ...opts.extraDaemonDirs],
    outDir: opts.outDir,
    daemonVersion: opts.daemonVersion,
    daemonTag: opts.daemonTag,
    channel: opts.channel,
    build: opts.build,
    builtAt: opts.builtAt,
    signUpdateFile: opts.signUpdateFile,
  })
}

async function main() {
  if (process.platform !== 'darwin' || process.arch !== 'arm64') {
    fail('Sarto is released from macOS on Apple silicon, the only system it ships for')
  }
  const { values } = parseArgs({
    options: {
      target: { type: 'string' },
      channel: { type: 'string' },
      version: { type: 'string' },
      'app-version': { type: 'string' },
      'daemon-version': { type: 'string' },
      build: { type: 'string' },
      notes: { type: 'string' },
      out: { type: 'string' },
      node: { type: 'string' },
      'skip-notarize': { type: 'boolean' },
      'skip-update-sign': { type: 'boolean' },
      'skip-smoke': { type: 'boolean' },
      'allow-older': { type: 'boolean' },
      'delta-from': { type: 'string' },
      'harness-checks': { type: 'string' },
      'extra-daemon-dir': { type: 'string', multiple: true },
      'built-at': { type: 'string' },
    },
  })

  const target = values.target?.trim() || 'all'
  if (target !== 'all' && target !== 'app' && target !== 'daemon') {
    fail(`--target must be all, app or daemon, not ${target}`)
  }
  const channel = values.channel?.trim() || 'stable'
  if (channel !== 'stable' && channel !== 'beta') {
    fail(`--channel must be stable or beta, not ${channel}`)
  }
  const build = values.build?.trim() || generateBuildNumber()
  if (!isValidBuildNumber(build)) {
    fail(`--build ${build} must be 1 to 18 digits with no leading zero`)
  }

  const wantsApp = target === 'all' || target === 'app'
  const wantsDaemon = target === 'all' || target === 'daemon'

  const rawAppVersion =
    values['app-version']?.trim() || values.version?.trim() || readAppBaseVersion(ROOT)
  const rawDaemonVersion =
    values['daemon-version']?.trim() ||
    (target === 'all' && channel === 'stable' && values.version && !values['app-version']
      ? values.version.trim()
      : readDaemonBaseVersion(ROOT))

  const appVersion = formatChannelVersion(rawAppVersion, channel, build)
  // An app-only release bundles a daemon that is already published, so its version stays as given
  // (package.json's X.Y.Z by default) instead of a beta no daemon release carries, which SSH setups
  // of the same version could not download.
  const daemonChannel = target === 'app' && !isBetaVersion(rawDaemonVersion) ? 'stable' : channel
  const daemonVersion = formatChannelVersion(rawDaemonVersion, daemonChannel, build)
  const commit = process.env.SARTO_GIT_COMMIT?.trim() || readGitCommit(ROOT) || ''
  const builtAt = values['built-at']?.trim() || new Date().toISOString()

  const releasesRoot = path.resolve(values.out ?? path.join(ROOT, 'dist', 'release'))
  if (!values['allow-older']) {
    const ignoreTag =
      process.env.GITHUB_REF_TYPE === 'tag' ? process.env.GITHUB_REF_NAME?.trim() : undefined
    if (wantsApp) {
      const error = checkReleaseVersionOrder({
        kind: 'app',
        channel,
        version: appVersion,
        root: ROOT,
        releasesRoot,
        ignoreTag,
      })
      if (error) fail(error)
    }
    if (wantsDaemon) {
      const error = checkReleaseVersionOrder({
        kind: 'daemon',
        channel,
        version: daemonVersion,
        root: ROOT,
        releasesRoot,
        ignoreTag,
      })
      if (error) fail(error)
    }
  }

  /** @type {Record<string, string[]>} */
  let highlights = {}
  if (wantsApp) {
    if (!values.notes) fail('An app release needs its notes: --notes <file.md>')
    const notes = await readFile(path.resolve(values.notes), 'utf8')
    highlights = releaseHighlights(notes)
    if (!highlights.en?.length)
      fail(`${values.notes} has no bullets under a "What changed" heading`)
  }

  const identity = process.env.SARTO_SIGN_IDENTITY?.trim() || '-'
  const signed = identity !== '-'
  const credentials = wantsApp && signed && !values['skip-notarize'] ? notaryCredentials() : null
  if (wantsApp && signed && !values['skip-notarize'] && !credentials) {
    fail('A signed release is notarized: set SARTO_NOTARY_PROFILE, or the SARTO_NOTARY_KEY trio')
  }
  // Checked before the long build: a release never ships an update file the app would refuse,
  // unless --skip-update-sign defers Ed25519 signing to the CI publish job.
  const signUpdateFile = values['skip-update-sign']
    ? null
    : signerFrom('release', 'SARTO_UPDATE_SIGNING_KEY')
  const extraDaemonDirs = (values['extra-daemon-dir'] ?? []).map((dir) => path.resolve(dir))
  if (wantsApp && !signed)
    console.warn('No SARTO_SIGN_IDENTITY: an ad-hoc, Link mode release, for testing only')

  const shareFolder =
    wantsApp && wantsDaemon && channel === 'stable' && appVersion === daemonVersion
  const appTag = shareFolder ? `v${appVersion}` : `app-v${appVersion}`
  const daemonTag = shareFolder ? appTag : `daemon-v${daemonVersion}`

  const appOut = path.join(releasesRoot, appTag)
  const daemonOut = path.join(releasesRoot, daemonTag)
  if (wantsApp && existsSync(appOut)) fail(`${appOut} exists; move it away first`)
  if (wantsDaemon && (!wantsApp || !shareFolder) && existsSync(daemonOut)) {
    fail(`${daemonOut} exists; move it away first`)
  }

  const bin = (/** @type {string} */ name) => path.join(ROOT, 'node_modules', '.bin', name)
  const nodePath = values.node ? path.resolve(values.node) : null
  const stage = await mkdtemp(path.join(os.tmpdir(), 'sarto-release-'))
  try {
    /** @type {string[]} */
    const publishedDirs = []

    if (wantsApp) {
      await run(process.execPath, [
        'apps/apple/scripts/package-mac.mjs',
        '--version',
        appVersion,
        '--daemon-version',
        daemonVersion,
        '--daemon-channel',
        daemonChannel,
        '--channel',
        channel,
        '--build',
        build,
        '--clean',
        '--out',
        stage,
        ...(nodePath ? ['--node', nodePath] : []),
      ])
      const app = path.join(stage, 'Sarto.app')
      await mkdir(appOut, { recursive: true })

      if (credentials) {
        const upload = path.join(stage, 'notarize.zip')
        await zipApp(app, upload)
        await notarize(upload, credentials)
        await staple(app)
        await checkGatekeeper(app)
      }

      const zip = path.join(appOut, `Sarto-${appVersion}-${ARCH}.zip`)
      const dmg = path.join(appOut, `Sarto-${appVersion}-${ARCH}.dmg`)
      await zipApp(app, zip)
      await buildDiskImage(app, dmg, appVersion)
      if (signed) {
        await execFile('codesign', ['--force', '--sign', identity, '--timestamp', dmg])
      }
      if (credentials) {
        await notarize(dmg, credentials)
        await staple(dmg)
      }

      const files = []
      for (const file of [zip, dmg]) {
        files.push({
          name: path.basename(file),
          size: (await stat(file)).size,
          sha512: await digest(file, 'sha512', 'base64'),
        })
      }
      for (const from of await deltaSources(
        values['delta-from'],
        releasesRoot,
        appVersion,
        channel,
      )) {
        const delta = path.join(appOut, `Sarto-${from}-${appVersion}-${ARCH}.delta`)
        try {
          const oldApp = await previousApp(from, releasesRoot, stage)
          const made = makeDelta({ oldApp, newApp: app, from, to: appVersion, out: delta })
          console.log(`Delta from ${from}: ${(made.size / 1e6).toFixed(1)} MB`)
          files.push({
            name: path.basename(delta),
            size: made.size,
            sha512: await digest(delta, 'sha512', 'base64'),
            from,
          })
        } catch (error) {
          await rm(delta, { force: true })
          console.warn(`No delta from ${from}: ${/** @type {Error} */ (error).message}`)
        }
      }

      const runtime = JSON.parse(
        await readFile(path.join(app, 'Contents', 'Resources', 'runtime', RUNTIME_FILE), 'utf8'),
      )
      if (!/^[0-9a-f]{64}$/.test(runtime.fingerprint)) fail('The app holds no runtime fingerprint')

      const macManifestName = MAC_MANIFEST[channel]
      const update = {
        version: appVersion,
        channel,
        build,
        daemonVersion,
        daemonBuild: build,
        tag: appTag,
        releaseDate: builtAt,
        minimumSystemVersion: await minimumSystemVersion(),
        files,
        notes: highlights,
        runtime: runtime.fingerprint,
      }
      const body = Buffer.from(`${JSON.stringify(update, null, 2)}\n`, 'utf8')
      await writeFile(path.join(appOut, macManifestName), body)
      if (signUpdateFile) {
        const signature = signUpdateFile(updateFileMessage(macManifestName, body))
        await writeFile(
          path.join(appOut, `${macManifestName}.sig`),
          `${signature.toString('base64')}\n`,
        )
      }
      publishedDirs.push(appOut)
    }

    if (wantsDaemon) {
      if (!wantsApp) {
        // Standalone daemon release builds placeholder out/daemon directly, and the device host's
        // helpers into out/helpers, which package-mac.mjs fetches for a release with the app.
        await run(bin('vite'), ['build', '-c', 'vite.daemon.config.mts'], {
          SARTO_BUILD_PLACEHOLDER: '1',
        })
        const xcode = await developerDir()
        await run(process.execPath, ['tools/install/device-helpers.mjs'], {
          ...(xcode ? { DEVELOPER_DIR: xcode } : {}),
        })
      }
      await mkdir(daemonOut, { recursive: true })
      await buildStandaloneDaemon({
        outDir: daemonOut,
        stage,
        daemonVersion,
        daemonTag,
        build,
        channel,
        commit,
        builtAt,
        node: nodePath,
        extraDaemonDirs,
        skipSmoke: values['skip-smoke'] === true,
        signUpdateFile,
      })
      if (!publishedDirs.includes(daemonOut)) publishedDirs.push(daemonOut)
    }

    // The daemon reads the harness compatibility manifest from the latest release; without one it
    // keeps the copy it has.
    const checks = values['harness-checks']
    const harnessTarget = wantsDaemon ? daemonOut : appOut
    if (checks) {
      const document = buildHarnessManifest(
        JSON.parse(await readFile(path.resolve(checks), 'utf8')),
      )
      await writeFile(
        path.join(harnessTarget, 'harnesses.json'),
        signHarnessManifest(document).body,
      )
    } else if (wantsDaemon) {
      console.warn('No --harness-checks: no harness manifest in this release')
    }

    console.log(
      `\nBuilt Sarto (${target}, channel=${channel}, build=${build})` +
        `${wantsApp ? ` app=${appVersion}` : ''}` +
        `${wantsDaemon ? ` daemon=${daemonVersion}` : ''}` +
        `${wantsApp && !signed ? ' (ad hoc, Link mode: for testing only)' : ''}`,
    )
    for (const dir of publishedDirs) {
      console.log(
        `Publish it with: node tools/sarto/publish-release.mjs ${path.relative(ROOT, dir)} <host>:<releases folder>`,
      )
    }
  } finally {
    await rm(stage, { recursive: true, force: true })
  }
}

await main()
