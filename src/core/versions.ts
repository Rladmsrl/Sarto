// Versions as semver orders them, shared by theme catalogs, daemon updates and release channels.

export type UpdateChannel = 'stable' | 'beta'

const BASE_VERSION_RE = /^(0|[1-9]\d{0,8})\.(0|[1-9]\d{0,8})\.(0|[1-9]\d{0,8})$/
const BETA_VERSION_RE = /^(0|[1-9]\d{0,8})\.(0|[1-9]\d{0,8})\.(0|[1-9]\d{0,8})-beta\.(0|[1-9]\d*)$/
const DEV_VERSION_RE = /^(0|[1-9]\d{0,8})\.(0|[1-9]\d{0,8})\.(0|[1-9]\d{0,8})-dev\.(0|[1-9]\d*)$/

function parseVersion(version: string): { core: number[]; pre: string[] } | null {
  const match =
    /^v?(\d{1,9})\.(\d{1,9})\.(\d{1,9})(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$/.exec(version)
  if (!match) return null
  const pre = match[4] ? match[4].split('.') : []
  if (pre.some((part) => part.length === 0)) return null
  return { core: match.slice(1, 4).map(Number), pre }
}

/** Whether `version` is a stable release version, strictly `X.Y.Z` without leading zeros. */
export function isReleaseVersion(version: string): boolean {
  return BASE_VERSION_RE.test(version)
}

/** Whether `version` is a beta prerelease version, `X.Y.Z-beta.<number>`. */
export function isBetaVersion(version: string): boolean {
  return BETA_VERSION_RE.test(version)
}

/** Whether `version` is a local development version, `X.Y.Z-dev.<number>`. */
export function isDevVersion(version: string): boolean {
  return DEV_VERSION_RE.test(version)
}

/** Whether `version` is valid for an update channel (`stable` accepts only X.Y.Z; `beta` also accepts beta prereleases). */
export function isChannelVersion(version: string, channel: UpdateChannel): boolean {
  return channel === 'beta'
    ? isReleaseVersion(version) || isBetaVersion(version)
    : isReleaseVersion(version)
}

/** SemVer 2.0.0 precedence: negative when `a` is older than `b`; NaN when either is not a version. */
export function compareVersions(a: string, b: string): number {
  const left = parseVersion(a)
  const right = parseVersion(b)
  if (!left || !right) return Number.NaN
  for (let i = 0; i < 3; i++) {
    if (left.core[i] !== right.core[i]) return left.core[i]! - right.core[i]!
  }
  if (left.pre.length === 0 || right.pre.length === 0) return right.pre.length - left.pre.length
  for (let i = 0; i < Math.max(left.pre.length, right.pre.length); i++) {
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
      // SemVer 2.0.0 section 11.4.3: numeric identifiers always have lower precedence.
      return xNum ? -1 : 1
    } else if (x !== y) {
      return x < y ? -1 : 1
    }
  }
  return 0
}
