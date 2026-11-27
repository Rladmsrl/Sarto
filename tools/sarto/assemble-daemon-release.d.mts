export interface DaemonArchiveMeta {
  platform: 'darwin' | 'linux'
  arch: 'x64' | 'arm64'
  name: string
  size: number
  sha256: string
}

export interface AssembleDaemonReleaseOptions {
  inputDirs: string[]
  outDir: string
  daemonVersion: string
  daemonTag: string
  channel: 'stable' | 'beta'
  build: string
  builtAt?: string
  requirePlatforms?: string[]
  signUpdateFile?: ((message: Buffer) => Buffer) | null
  harnessChecks?: string | null
  installScriptPath?: string
}

export interface AssembleDaemonReleaseResult {
  manifestName: string
  manifest: {
    version: string
    channel: 'stable' | 'beta'
    build: string
    tag: string
    releaseDate: string
    files: DaemonArchiveMeta[]
  }
  files: DaemonArchiveMeta[]
}

export function parseDaemonArchiveName(
  name: string,
): { platform: 'darwin' | 'linux'; arch: 'x64' | 'arm64' } | null

export function assembleDaemonRelease(
  options: AssembleDaemonReleaseOptions,
): Promise<AssembleDaemonReleaseResult>
