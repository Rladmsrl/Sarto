// Type declarations for runtime-fingerprint.mjs, imported by vite.daemon.config.mts.

export const RUNTIME_FILE: string
export const VERSION_PLACEHOLDER: string
export const BUILD_PLACEHOLDER: string
export const CHANNEL_PLACEHOLDER: string
export const COMMIT_PLACEHOLDER: string
export const BUILT_AT_PLACEHOLDER: string

export function runtimeFingerprint(dir: string): Promise<string>
export function stampBuildInfo(
  runtime: string,
  info: {
    version: string
    build?: string | null
    channel?: 'stable' | 'beta' | 'dev'
    commit?: string | null
    builtAt?: string | null
  },
): Promise<number>
export function stampVersion(runtime: string, version: string): Promise<number>
