export interface BuildDaemonPackageOptions {
  out: string
  version: string
  build: string
  channel: 'stable' | 'beta'
  commit?: string
  builtAt?: string
  buildDir?: string
  node?: string | null
  skipBuild?: boolean
  skipSmoke?: boolean
  maxGlibc?: string
}

export interface BuildDaemonPackageResult {
  archive: string
  platform: NodeJS.Platform
  arch: string
  name: string
  size: number
  sha256: string
}

export function compareDottedVersion(a: string, b: string): number
export function parseMaxGlibcVersion(text: string): string | null
export function verifyGlibcCeiling(binary: string, maxGlibc?: string): Promise<string | null>
export function buildDaemonPackage(
  options: BuildDaemonPackageOptions,
): Promise<BuildDaemonPackageResult>
