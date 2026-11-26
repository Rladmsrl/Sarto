// @ts-check
// Shared version, channel and 12-digit UTC build-number helpers for daemon builds, Mac packaging
// and release scripts. Kept dependency-free so both build tools and release scripts can import it.

import { execFileSync } from 'node:child_process'
import { existsSync, readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'

/** @typedef {'stable' | 'beta' | 'dev'} BuildChannel */
/** @typedef {'stable' | 'beta'} UpdateChannel */

const BASE_VERSION_RE = /^(0|[1-9]\d{0,8})\.(0|[1-9]\d{0,8})\.(0|[1-9]\d{0,8})$/
const BETA_VERSION_RE = /^(0|[1-9]\d{0,8})\.(0|[1-9]\d{0,8})\.(0|[1-9]\d{0,8})-beta\.(0|[1-9]\d*)$/
const DEV_VERSION_RE = /^(0|[1-9]\d{0,8})\.(0|[1-9]\d{0,8})\.(0|[1-9]\d{0,8})-dev\.(0|[1-9]\d*)$/
const BUILD_NUMBER_RE = /^[1-9]\d{0,17}$/
const TAG_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/

/**
 * Generates a monotonically increasing 12-digit UTC build number (`YYMMDDHHmmss`), e.g.
 * `261125143512`. Always starts with a non-zero digit and stays well within Apple's 18-digit
 * CFBundleVersion limit.
 *
 * @param {Date} [date]
 */
export function generateBuildNumber(date = new Date()) {
  const pad = (/** @type {number} */ n) => String(n).padStart(2, '0')
  const yy = pad(date.getUTCFullYear() % 100)
  const mm = pad(date.getUTCMonth() + 1)
  const dd = pad(date.getUTCDate())
  const hh = pad(date.getUTCHours())
  const min = pad(date.getUTCMinutes())
  const ss = pad(date.getUTCSeconds())
  return `${yy}${mm}${dd}${hh}${min}${ss}`
}

/** @param {string} version */
export function isBaseVersion(version) {
  return BASE_VERSION_RE.test(version)
}

/** @param {string} version */
export function isReleaseVersion(version) {
  return BASE_VERSION_RE.test(version)
}

/** @param {string} version */
export function isBetaVersion(version) {
  return BETA_VERSION_RE.test(version)
}

/** @param {string} version */
export function isDevVersion(version) {
  return DEV_VERSION_RE.test(version)
}

/** @param {string} build */
export function isValidBuildNumber(build) {
  return BUILD_NUMBER_RE.test(build)
}

/** @param {string} tag */
export function isValidTag(tag) {
  return TAG_RE.test(tag) && !tag.includes('..')
}

/**
 * Extracts the `X.Y.Z` core version for CFBundleShortVersionString (Apple notarization expects
 * pure numeric X.Y.Z without prerelease suffixes).
 *
 * @param {string} version
 */
export function marketingVersion(version) {
  const core = version.split(/[-+]/, 1)[0] ?? ''
  if (!isBaseVersion(core)) throw new Error(`Version ${version} does not start with X.Y.Z`)
  return core
}

/**
 * Infers the build channel from an explicit channel flag or from the version string itself.
 *
 * @param {string} version
 * @param {string | undefined} explicit
 * @param {BuildChannel} fallback
 * @returns {BuildChannel}
 */
export function resolveBuildChannel(version, explicit, fallback) {
  const raw = explicit?.trim()
  if (raw) {
    if (raw === 'stable' || raw === 'beta' || raw === 'dev') return raw
    throw new Error(`Unknown build channel ${raw}; expected stable, beta or dev`)
  }
  if (isBetaVersion(version)) return 'beta'
  if (isDevVersion(version)) return 'dev'
  return fallback
}

/**
 * Formats a component version for `channel`. If `rawVersion` already includes the matching
 * prerelease tag (`-beta.N` / `-dev.N`), it is preserved; if it is a base `X.Y.Z` and the channel
 * is `beta` or `dev`, `-<channel>.<build>` is appended.
 *
 * @param {string} rawVersion
 * @param {BuildChannel} channel
 * @param {string} build
 */
export function formatChannelVersion(rawVersion, channel, build) {
  const version = rawVersion.trim()
  if (!isValidBuildNumber(build)) {
    throw new Error(`Build number ${build} must be 1 to 18 digits with no leading zero`)
  }
  if (channel === 'stable') {
    if (!isReleaseVersion(version)) {
      throw new Error(`Stable version ${version} must be X.Y.Z`)
    }
    return version
  }
  if (channel === 'beta') {
    if (isBetaVersion(version)) return version
    if (isBaseVersion(version)) return `${version}-beta.${build}`
    throw new Error(`Beta version ${version} must be X.Y.Z or X.Y.Z-beta.<number>`)
  }
  if (isDevVersion(version)) return version
  if (isBaseVersion(version)) return `${version}-dev.${build}`
  throw new Error(`Dev version ${version} must be X.Y.Z or X.Y.Z-dev.<number>`)
}

/**
 * Reads `MARKETING_VERSION` from `apps/apple/project.yml`, the single source of truth for the
 * Apple client's base version.
 *
 * @param {string} root
 */
export function readAppBaseVersion(root) {
  const yml = readFileSync(path.join(root, 'apps', 'apple', 'project.yml'), 'utf8')
  const match = /^\s*MARKETING_VERSION:\s*"?([^"\s]+)"?\s*$/m.exec(yml)
  if (!match?.[1] || !isBaseVersion(match[1])) {
    throw new Error('apps/apple/project.yml names no valid MARKETING_VERSION (X.Y.Z)')
  }
  return match[1]
}

/**
 * Reads `version` from the root `package.json`, the single source of truth for the daemon's base
 * version.
 *
 * @param {string} root
 */
export function readDaemonBaseVersion(root) {
  const pkg = JSON.parse(readFileSync(path.join(root, 'package.json'), 'utf8'))
  const version = typeof pkg.version === 'string' ? pkg.version.trim() : ''
  if (!isBaseVersion(version)) {
    throw new Error(`package.json version '${version}' is not X.Y.Z`)
  }
  return version
}

/**
 * Short git commit SHA with `-dirty` suffix when the working tree has modifications, or null when
 * built outside a git repository.
 *
 * @param {string} cwd
 */
export function readGitCommit(cwd) {
  try {
    const sha = execFileSync('git', ['rev-parse', '--short=7', 'HEAD'], {
      cwd,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim()
    if (!sha) return null
    const status = execFileSync('git', ['status', '--porcelain', '--untracked-files=no'], {
      cwd,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim()
    return status ? `${sha}-dirty` : sha
  } catch {
    return null
  }
}

/**
 * Parses a SemVer string into numeric core parts and prerelease identifiers.
 *
 * @param {string} version
 */
function parseSemver(version) {
  const match =
    /^v?(0|[1-9]\d{0,8})\.(0|[1-9]\d{0,8})\.(0|[1-9]\d{0,8})(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$/.exec(
      version,
    )
  if (!match) return null
  const pre = match[4] ? match[4].split('.') : []
  if (pre.some((part) => part.length === 0)) return null
  return { core: match.slice(1, 4).map(Number), pre }
}

/**
 * SemVer 2.0.0 precedence matching SartoUpdate's `SartoVersion.compare`: negative when `a` is
 * older than `b`, 0 when equal, positive when newer, NaN when either is invalid.
 *
 * @param {string} a
 * @param {string} b
 */
export function compareVersions(a, b) {
  const left = parseSemver(a)
  const right = parseSemver(b)
  if (!left || !right) return Number.NaN
  for (let i = 0; i < 3; i++) {
    if (left.core[i] !== right.core[i]) return left.core[i] - right.core[i]
  }
  if (left.pre.length === 0 || right.pre.length === 0) return right.pre.length - left.pre.length
  const count = Math.max(left.pre.length, right.pre.length)
  for (let i = 0; i < count; i++) {
    const x = left.pre[i]
    const y = right.pre[i]
    if (x === undefined || y === undefined) return x === undefined ? -1 : 1
    const xNum = /^\d+$/.test(x)
    const yNum = /^\d+$/.test(y)
    if (xNum && yNum) {
      const nx = x.replace(/^0+/, '')
      const ny = y.replace(/^0+/, '')
      if (nx.length !== ny.length) return nx.length < ny.length ? -1 : 1
      if (nx !== ny) return nx < ny ? -1 : 1
    } else if (xNum !== yNum) {
      return xNum ? -1 : 1
    } else if (x !== y) {
      return x < y ? -1 : 1
    }
  }
  return 0
}

/**
 * Suggests the next patch version after a stable `X.Y.Z`, e.g. `0.3.1` -> `0.3.2`.
 *
 * @param {string} stable
 */
export function nextPatchVersion(stable) {
  const [major, minor, patch] = stable.split('.').map(Number)
  return `${major}.${minor}.${patch + 1}`
}

/**
 * Finds the highest published stable `X.Y.Z` version from local git tags and an optional releases
 * directory. When `ignoreTag` matches a git tag (such as the exact tag currently triggering a CI
 * stable release), that tag is skipped so prior stable tags still guard against regressions.
 *
 * A stable app-only release also lives in a `vX.Y.Z` folder and GitHub release, so for the daemon a
 * `vX.Y.Z` tag counts only without an `app-vX.Y.Z` tag beside it (the app-only trigger), and a
 * `vX.Y.Z` folder only when it carries the daemon's install script.
 *
 * @param {'app' | 'daemon'} kind
 * @param {string} root
 * @param {{ releasesRoot?: string, ignoreTag?: string }} [options]
 */
export function findLatestPublishedStable(kind, root, options = {}) {
  const own = kind === 'app' ? 'app-v' : 'daemon-v'
  const ignoreTag = options.ignoreTag?.trim() || undefined
  /** @type {string[]} */
  const candidates = []
  try {
    const stdout = execFileSync('git', ['tag', '-l', 'v*.*.*', 'app-v*.*.*', 'daemon-v*.*.*'], {
      cwd: root,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    })
    const tags = new Set(stdout.split(/\r?\n/).map((line) => line.trim()))
    for (const rawTag of tags) {
      if (!rawTag || (ignoreTag && rawTag === ignoreTag)) continue
      let version = null
      if (rawTag.startsWith(own)) version = rawTag.slice(own.length)
      else if (rawTag.startsWith('v')) {
        version = rawTag.slice(1)
        if (kind === 'daemon' && tags.has(`app-${rawTag}`)) version = null
      }
      if (version && isReleaseVersion(version)) candidates.push(version)
    }
  } catch {
    // Ignore git tag lookup failure when building outside a git checkout.
  }
  if (options.releasesRoot) {
    try {
      for (const entry of readdirSync(options.releasesRoot)) {
        let version = null
        if (entry.startsWith(own)) version = entry.slice(own.length)
        else if (entry.startsWith('v')) {
          version = entry.slice(1)
          if (
            kind === 'daemon' &&
            !existsSync(path.join(options.releasesRoot, entry, 'install.sh'))
          ) {
            version = null
          }
        }
        if (version && isReleaseVersion(version)) candidates.push(version)
      }
    } catch {
      // Ignore missing releases directory.
    }
  }
  if (candidates.length === 0) return null
  return candidates.sort((a, b) => compareVersions(a, b)).at(-1) ?? null
}

/**
 * Checks SemVer monotonicity against the latest published stable version so beta builds are never
 * cut against an already-shipped `X.Y.Z` (in SemVer `0.3.1-beta.* < 0.3.1`) and new stable builds
 * never reuse or regress an older `X.Y.Z`. Returns an error message when violated, or `null`.
 *
 * @param {{
 *   kind: 'app' | 'daemon',
 *   channel: UpdateChannel,
 *   version: string,
 *   root: string,
 *   releasesRoot?: string,
 *   ignoreTag?: string,
 * }} opts
 */
export function checkReleaseVersionOrder(opts) {
  const latest = findLatestPublishedStable(opts.kind, opts.root, {
    releasesRoot: opts.releasesRoot,
    ignoreTag: opts.ignoreTag,
  })
  if (!latest || compareVersions(opts.version, latest) > 0) return null
  const label = opts.kind === 'app' ? 'App' : 'Daemon'
  const flag = opts.kind === 'app' ? '--app-version' : '--daemon-version'
  const next = nextPatchVersion(latest)
  return opts.channel === 'beta'
    ? `${label} beta version ${opts.version} is older than published stable ${latest} (in SemVer X.Y.Z-beta.* < X.Y.Z). Bump ${flag} to the next upcoming version (e.g. ${next}), or pass --allow-older to override.`
    : `${label} stable version ${opts.version} is not newer than published stable ${latest}. Bump ${flag} (e.g. ${next}), or pass --allow-older to override.`
}
