// Writes the harness versions a release bundles, src/agent-host/harness-versions.json: the ACP
// Registry's listing cut to what Sarto reads of it, each agent's version and distribution, beside
// `sarto`, the versions Sarto keeps itself for the harnesses the Registry does not list as Sarto
// installs them, and `manifest`, Sarto's signed harness compatibility manifest, both of which this
// tool leaves as they are (tools/sarto/harnesses.mjs --bundle writes the manifest). Run it before a
// release, so new installs start on the day's versions, and again when a harness is added. A failed
// fetch keeps the committed part and warns.

import { readFileSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

export const SOURCE = 'https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json'
export const TARGET = resolve(import.meta.dirname, '../../src/agent-host/harness-versions.json')

const isObject = (value) => typeof value === 'object' && value !== null && !Array.isArray(value)

/** The fields of a value that are present, in this order. */
function pick(value, keys) {
  return Object.fromEntries(
    keys.filter((key) => value[key] !== undefined).map((k) => [k, value[k]]),
  )
}

/**
 * One agent as Sarto reads it: its id, version and the packages or archives it ships as. The
 * Registry's own arguments and variables are left out, since each harness's launch has its own.
 *
 * @param {Record<string, any>} agent
 */
export function cutAgent(agent) {
  const source = isObject(agent.distribution) ? agent.distribution : {}
  const distribution = {}
  if (isObject(source.npx) && typeof source.npx.package === 'string') {
    distribution.npx = { package: source.npx.package }
  }
  if (isObject(source.uvx) && typeof source.uvx.package === 'string') {
    distribution.uvx = { package: source.uvx.package }
  }
  if (isObject(source.binary)) {
    distribution.binary = Object.fromEntries(
      Object.entries(source.binary)
        .filter(([, target]) => isObject(target))
        .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
        .map(([key, target]) => [key, pick(target, ['archive', 'cmd', 'args', 'sha256'])]),
    )
  }
  return { id: agent.id, version: agent.version, distribution }
}

/**
 * The bundled file from the Registry's listing, the versions Sarto keeps itself and the signed
 * manifest, when there is one.
 *
 * @param {{ agents: unknown[] }} listing
 * @param {Record<string, unknown>} sarto
 * @param {{ payload: string, signature: string } | null} [manifest]
 */
export function bundle(listing, sarto, manifest = null) {
  const agents = listing.agents
    .filter((agent) => isObject(agent) && typeof agent.id === 'string')
    .map(cutAgent)
    .sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))
  return { registry: { agents }, sarto, ...(manifest ? { manifest } : {}) }
}

/** Formats the file as the repository's Prettier settings do, so it passes the format check. */
async function format(text) {
  const prettier = await import('prettier')
  const options = (await prettier.resolveConfig(TARGET)) ?? {}
  return prettier.format(text, { ...options, filepath: TARGET })
}

async function main() {
  let current
  try {
    current = JSON.parse(readFileSync(TARGET, 'utf8'))
  } catch (error) {
    throw new Error(`Could not read ${TARGET}: ${error.message}`, { cause: error })
  }
  let listing =
    isObject(current.registry) && Array.isArray(current.registry.agents)
      ? current.registry
      : { agents: [] }
  try {
    const response = await fetch(SOURCE)
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    const read = await response.json()
    if (!isObject(read) || !Array.isArray(read.agents)) throw new Error('no agents list')
    listing = read
  } catch (error) {
    console.warn(
      `::warning::Could not read the ACP Registry, keeping the committed Registry versions: ${error.message}`,
    )
  }
  const manifest = isObject(current.manifest) ? current.manifest : null
  const next = bundle(listing, isObject(current.sarto) ? current.sarto : {}, manifest)
  writeFileSync(TARGET, await format(JSON.stringify(next, null, 2)))
  console.log(`Wrote the versions of ${next.registry.agents.length} Registry agents`)
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  await main()
}
