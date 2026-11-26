// Type declarations for build-version.mjs, imported by vite.daemon.config.mts and tests.

export type BuildChannel = 'stable' | 'beta' | 'dev'
export type UpdateChannel = 'stable' | 'beta'

export function generateBuildNumber(date?: Date): string
export function isBaseVersion(version: string): boolean
export function isReleaseVersion(version: string): boolean
export function isBetaVersion(version: string): boolean
export function isDevVersion(version: string): boolean
export function isValidBuildNumber(build: string): boolean
export function isValidTag(tag: string): boolean
export function marketingVersion(version: string): string
export function resolveBuildChannel(
  version: string,
  explicit: string | undefined,
  fallback: BuildChannel,
): BuildChannel
export function formatChannelVersion(
  rawVersion: string,
  channel: BuildChannel,
  build: string,
): string
export function readAppBaseVersion(root: string): string
export function readDaemonBaseVersion(root: string): string
export function readGitCommit(cwd: string): string | null
export function compareVersions(a: string, b: string): number
export function nextPatchVersion(stable: string): string
export function findLatestPublishedStable(
  kind: 'app' | 'daemon',
  root: string,
  options?: { releasesRoot?: string; ignoreTag?: string },
): string | null
export function checkReleaseVersionOrder(opts: {
  kind: 'app' | 'daemon'
  channel: UpdateChannel
  version: string
  root: string
  releasesRoot?: string
  ignoreTag?: string
}): string | null
