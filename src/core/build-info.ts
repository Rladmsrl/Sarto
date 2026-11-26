// Daemon build metadata: stamped by Vite during builds (or by runtime-fingerprint.mjs during
// packaging so runtime fingerprints remain stable across version bumps) and derived from running
// paths for origin identification.

import path from 'node:path'
import { version as packageVersion } from '../../package.json'

export type BuildChannel = 'stable' | 'beta' | 'dev'
export type DaemonOrigin = 'bundled' | 'standalone' | 'checkout'

export interface DaemonBuildInfo {
  version: string
  build: string | null
  channel: BuildChannel
  commit: string | null
  builtAt: string | null
}

// Vite replaces these raw string constants at build time (vite.daemon.config.mts). Keeping them as
// plain strings allows runtime-fingerprint.mjs to stamp packaged bundles without re-bundling.
const RAW_BUILD = ''
const RAW_CHANNEL = 'dev'
const RAW_COMMIT = ''
const RAW_BUILT_AT = ''

function parseChannel(raw: string): BuildChannel {
  if (raw === 'stable' || raw === 'beta' || raw === 'dev') return raw
  return 'dev'
}

function optionalField(raw: string): string | null {
  const trimmed = raw.trim()
  if (!trimmed || (trimmed.startsWith('__SARTO_RUNTIME_') && trimmed.endsWith('__'))) return null
  return trimmed
}

export const DAEMON_BUILD_INFO: DaemonBuildInfo = {
  version: packageVersion,
  build: optionalField(RAW_BUILD),
  channel: parseChannel(RAW_CHANNEL),
  commit: optionalField(RAW_COMMIT),
  builtAt: optionalField(RAW_BUILT_AT),
}

/**
 * How this daemon bundle is installed:
 * - `bundled`: unpacked by Sarto.app (`.../runtimes/<16-hex>/daemon` or inside `Sarto.app`)
 * - `standalone`: installed by `install.sh` (`.../versions/<version>/daemon`)
 * - `checkout`: run from a source checkout (`out/daemon`) or custom location
 */
export function detectDaemonOrigin(bundleDir: string): DaemonOrigin {
  const normalized = path.resolve(bundleDir).replaceAll('\\', '/')
  if (
    /\/runtimes\/[0-9a-f]{16}\/daemon$/i.test(normalized) ||
    normalized.includes('.app/Contents/Resources/runtime/')
  ) {
    return 'bundled'
  }
  const versions = path.dirname(path.dirname(bundleDir))
  if (path.basename(bundleDir) === 'daemon' && path.basename(versions) === 'versions') {
    return 'standalone'
  }
  return 'checkout'
}

/** Short diagnostic suffix for logs and CLI status, e.g. `build 261125143512, beta, a1b2c3d, bundled`. */
export function formatDaemonBuildDetails(info: {
  build?: string | null
  channel?: BuildChannel | null
  commit?: string | null
  origin?: DaemonOrigin | null
}): string | null {
  const parts: string[] = []
  if (info.build) parts.push(`build ${info.build}`)
  if (info.channel) parts.push(info.channel)
  if (info.commit) parts.push(info.commit)
  if (info.origin) parts.push(info.origin)
  return parts.length > 0 ? parts.join(', ') : null
}
