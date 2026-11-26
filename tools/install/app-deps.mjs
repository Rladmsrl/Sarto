// @ts-check
// The postinstall step that readies node-pty, the daemon's only native module. node-pty's own
// install script uses its prebuilt binaries where it ships them (macOS and Windows) and builds from
// source elsewhere. Its prebuilt macOS spawn-helper lacks its execute bit, so no shell would start
// (microsoft/node-pty#919); this restores it. No dependencies.

import { chmodSync, existsSync, realpathSync } from 'node:fs'
import { createRequire } from 'node:module'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const require = createRequire(import.meta.url)

/**
 * The spawn-helper binaries node-pty may load on this platform and architecture.
 *
 * @param {string} nodePtyDir
 * @param {NodeJS.Platform} platform
 * @param {string} arch
 */
export function spawnHelpers(nodePtyDir, platform, arch) {
  return [
    join(nodePtyDir, 'build', 'Release', 'spawn-helper'),
    join(nodePtyDir, 'prebuilds', `${platform}-${arch}`, 'spawn-helper'),
  ]
}

// import.meta.main is missing before Node.js 22.18; the main module's URL is its real path.
const isMain =
  import.meta.main ?? realpathSync(process.argv[1] ?? '.') === fileURLToPath(import.meta.url)

if (isMain && process.platform !== 'win32') {
  const nodePtyDir = dirname(require.resolve('node-pty/package.json'))
  for (const helper of spawnHelpers(nodePtyDir, process.platform, process.arch)) {
    if (existsSync(helper)) chmodSync(helper, 0o755)
  }
}
