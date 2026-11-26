// @ts-check
// The fingerprint of a daemon runtime (SartoUpdate's RuntimeFingerprint): the SHA-256 of each
// file's path, whether it is executable, and its contents. Sarto's packaging builds the daemon
// with placeholders for its version and build metadata and takes the fingerprint before stamping
// the real values and signing the runtime, since signing changes every Mach-O file on each build.
// Two releases whose daemon did not change then share a fingerprint, and the app installs one
// without restarting the daemon.

import { createHash } from 'node:crypto'
import { readFile, readdir, stat, writeFile } from 'node:fs/promises'
import path from 'node:path'

/** The file the fingerprint and build metadata are written to, inside the runtime, left out of the hash. */
export const RUNTIME_FILE = 'runtime.json'

/** Placeholders the daemon is built with until `stampBuildInfo` writes the real metadata. */
export const VERSION_PLACEHOLDER = '__SARTO_RUNTIME_VERSION__'
export const BUILD_PLACEHOLDER = '__SARTO_RUNTIME_BUILD__'
export const CHANNEL_PLACEHOLDER = '__SARTO_RUNTIME_CHANNEL__'
export const COMMIT_PLACEHOLDER = '__SARTO_RUNTIME_COMMIT__'
export const BUILT_AT_PLACEHOLDER = '__SARTO_RUNTIME_BUILT_AT__'

/** @param {string} dir @returns {Promise<string[]>} */
async function files(dir, base = dir) {
  const out = []
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name)
    if (entry.isDirectory()) out.push(...(await files(full, base)))
    else if (entry.isFile() || entry.isSymbolicLink()) out.push(path.relative(base, full))
  }
  return out
}

/**
 * The runtime's fingerprint, in lowercase hex.
 *
 * @param {string} dir the runtime, unsigned and with placeholder build metadata
 */
export async function runtimeFingerprint(dir) {
  const hash = createHash('sha256')
  const names = (await files(dir)).filter((name) => name !== RUNTIME_FILE)
  names.sort((a, b) => (a < b ? -1 : a > b ? 1 : 0))
  for (const name of names) {
    const full = path.join(dir, name)
    const info = await stat(full)
    const fileHash = createHash('sha256')
      .update(await readFile(full))
      .digest('hex')
    hash.update(`${name}\u0000${info.mode & 0o111 ? 'x' : '-'}\u0000${fileHash}\n`)
  }
  return hash.digest('hex')
}

/**
 * Replaces the version and build-metadata placeholders in `runtime/daemon` and returns how many
 * files held `VERSION_PLACEHOLDER`.
 *
 * @param {string} runtime
 * @param {{
 *   version: string,
 *   build?: string | null,
 *   channel?: 'stable' | 'beta' | 'dev',
 *   commit?: string | null,
 *   builtAt?: string | null,
 * }} info
 */
export async function stampBuildInfo(runtime, info) {
  const daemon = path.join(runtime, 'daemon')
  const replacements = [
    [VERSION_PLACEHOLDER, info.version],
    [BUILD_PLACEHOLDER, info.build ?? ''],
    [CHANNEL_PLACEHOLDER, info.channel ?? 'stable'],
    [COMMIT_PLACEHOLDER, info.commit ?? ''],
    [BUILT_AT_PLACEHOLDER, info.builtAt ?? ''],
  ]
  // The values go inside string literals of the bundle, so none may hold a quote or a backslash.
  for (const [placeholder, value] of replacements) {
    if (!/^[\w.:+-]*$/.test(value)) {
      throw new Error(`${placeholder} cannot be stamped with ${JSON.stringify(value)}`)
    }
  }
  let stamped = 0
  for (const name of await files(daemon)) {
    if (name.split(path.sep).includes('node_modules') || !/\.c?js$/.test(name)) continue
    const full = path.join(daemon, name)
    let text = await readFile(full, 'utf8')
    const hadVersion = text.includes(VERSION_PLACEHOLDER)
    let changed = false
    for (const [placeholder, value] of replacements) {
      if (!text.includes(placeholder)) continue
      text = text.replaceAll(placeholder, value)
      changed = true
    }
    if (!changed) continue
    await writeFile(full, text)
    if (hadVersion) stamped++
  }
  return stamped
}

/**
 * Legacy helper that stamps only `version` (defaulting other metadata).
 *
 * @param {string} runtime
 * @param {string} version
 */
export async function stampVersion(runtime, version) {
  return stampBuildInfo(runtime, { version })
}
