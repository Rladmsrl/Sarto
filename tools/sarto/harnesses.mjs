// @ts-check
// Sarto's harness compatibility manifest, built from the harness checks' results (the
// `harness-checks` artifact of .github/workflows/harness-checks.yml, tools/harness-checks/README.md)
// and signed with Sarto's harnesses key, the only one the daemon trusts
// (src/agent-host/harness-manifest.ts). Per harness it recommends the newest version that passed
// and marks broken each one that failed twice in a row. Its sequence is the checks' time, so a
// manifest from newer checks always replaces an older one.
//
//   SARTO_HARNESSES_SIGNING_KEY="$(cat harnesses-current.pem)" \
//     node tools/sarto/harnesses.mjs --checks harness-checks.json --out harnesses.json
//   ... node tools/sarto/harnesses.mjs --checks harness-checks.json --bundle
//   ... node tools/sarto/harnesses.mjs --checks harness-checks.json --publish user@host:/srv/sarto/releases
//
// --bundle writes it into src/agent-host/harness-versions.json, which every build carries; --publish
// puts it in the latest release's folder, where running daemons read it.

import { execFile as execFileCb } from 'node:child_process'
import { existsSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { mkdtemp, rm } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseArgs, promisify } from 'node:util'
import rcompare from 'semver/functions/rcompare.js'
import valid from 'semver/functions/valid.js'
import { signerFrom } from './signing.mjs'

const execFile = promisify(execFileCb)
const BUNDLED = new URL('../../src/agent-host/harness-versions.json', import.meta.url)
// A version that failed this many checks in a row is broken, as the checks themselves count it.
const BROKEN_AFTER = 2

/**
 * @typedef {{ harness: string, version: string, status: 'pass' | 'fail', failures: number }} CheckResult
 * @typedef {{ generatedAt: string, results: CheckResult[] }} HarnessChecks
 * @typedef {{ sarto: string, recommended?: string, broken: string[], sha256: Record<string, string> }} Rule
 * @typedef {{ sequence: number, updatedAt: string, harnesses: Record<string, Rule[]> }} ManifestDocument
 */

/**
 * The manifest document the checks' results give: one rule per harness, for every Sarto version.
 *
 * @param {HarnessChecks} checks
 * @returns {ManifestDocument}
 */
export function buildHarnessManifest(checks) {
  const at = Date.parse(checks.generatedAt)
  if (!Number.isFinite(at)) throw new Error('The checks have no generatedAt time')
  /** @type {Map<string, CheckResult[]>} */
  const byHarness = new Map()
  for (const result of checks.results ?? []) {
    if (typeof result?.harness !== 'string' || valid(result.version) !== result.version) continue
    byHarness.set(result.harness, [...(byHarness.get(result.harness) ?? []), result])
  }
  /** @type {Record<string, Rule[]>} */
  const harnesses = {}
  for (const [harness, results] of [...byHarness].sort(([a], [b]) => (a < b ? -1 : 1))) {
    const newestFirst = results.sort((a, b) => rcompare(a.version, b.version))
    const broken = newestFirst
      .filter((result) => result.status === 'fail' && result.failures >= BROKEN_AFTER)
      .map((result) => result.version)
    const recommended = newestFirst.find((result) => result.status === 'pass')?.version
    harnesses[harness] = [
      { sarto: '*', ...(recommended ? { recommended } : {}), broken, sha256: {} },
    ]
  }
  return {
    sequence: Math.floor(at / 1000),
    updatedAt: new Date(at).toISOString(),
    harnesses,
  }
}

/**
 * The document in its signed envelope, as the body of harnesses.json.
 *
 * @param {ManifestDocument} document
 */
export function signHarnessManifest(document) {
  const sign = signerFrom('harnesses', 'SARTO_HARNESSES_SIGNING_KEY')
  const bytes = Buffer.from(JSON.stringify(document), 'utf8')
  const envelope = {
    payload: bytes.toString('base64url'),
    signature: sign(bytes).toString('base64url'),
  }
  return { envelope, body: `${JSON.stringify(envelope)}\n` }
}

/** Quotes a word for the remote shell. @param {string} word */
const quote = (word) => `'${word.replaceAll("'", "'\\''")}'`

/**
 * Atomically publishes harnesses.json to the root of `target` (host:dir or a local folder) so
 * decoupled daemon releases stay independent of app version folders, and mirrors it into
 * `v<latest>/harnesses.json` when a legacy `latest` pointer exists.
 */
async function publish(/** @type {string} */ body, /** @type {string} */ target) {
  const remote = /^([^/:]+):(\/.+)$/.exec(target)
  const stage = await mkdtemp(path.join(os.tmpdir(), 'sarto-harnesses-'))
  try {
    const file = path.join(stage, 'harnesses.json')
    writeFileSync(file, body)
    if (remote) {
      const [, host, dir] = remote
      await execFile('rsync', [file, `${host}:${dir}/harnesses.json.tmp`])
      const { stdout } = await execFile('ssh', [
        host,
        `mv -f ${quote(`${dir}/harnesses.json.tmp`)} ${quote(`${dir}/harnesses.json`)} && ` +
          `if [ -f ${quote(`${dir}/latest`)} ]; then cat ${quote(`${dir}/latest`)}; fi`,
      ])
      const version = stdout.trim()
      if (/^\d+\.\d+\.\d+$/.test(version)) {
        await execFile('ssh', [
          host,
          `if [ -d ${quote(`${dir}/v${version}`)} ]; then ` +
            `cp ${quote(`${dir}/harnesses.json`)} ${quote(`${dir}/v${version}/harnesses.json.tmp`)} && ` +
            `mv -f ${quote(`${dir}/v${version}/harnesses.json.tmp`)} ${quote(`${dir}/v${version}/harnesses.json`)}; fi`,
        ])
        return version
      }
      return 'root'
    }
    const rootTmp = path.join(target, 'harnesses.json.tmp')
    writeFileSync(rootTmp, body)
    renameSync(rootTmp, path.join(target, 'harnesses.json'))
    const latestFile = path.join(target, 'latest')
    if (existsSync(latestFile)) {
      const version = readFileSync(latestFile, 'utf8').trim()
      const legacyDir = path.join(target, `v${version}`)
      if (/^\d+\.\d+\.\d+$/.test(version) && existsSync(legacyDir)) {
        const legacyTmp = path.join(legacyDir, 'harnesses.json.tmp')
        writeFileSync(legacyTmp, body)
        renameSync(legacyTmp, path.join(legacyDir, 'harnesses.json'))
        return version
      }
    }
    return 'root'
  } finally {
    await rm(stage, { recursive: true, force: true })
  }
}

/** Puts the signed manifest into the harness versions every build carries. */
function bundle(/** @type {{ payload: string, signature: string }} */ envelope) {
  const file = JSON.parse(readFileSync(BUNDLED, 'utf8'))
  writeFileSync(BUNDLED, `${JSON.stringify({ ...file, manifest: envelope }, null, 2)}\n`)
}

async function main() {
  const { values } = parseArgs({
    options: {
      checks: { type: 'string' },
      out: { type: 'string' },
      publish: { type: 'string' },
      bundle: { type: 'boolean' },
    },
  })
  if (!values.checks || (!values.out && !values.publish && !values.bundle)) {
    console.error(
      'Usage: harnesses.mjs --checks <harness-checks.json> [--out <file>] [--bundle] ' +
        '[--publish <[user@host:]releases folder>]',
    )
    process.exit(2)
  }
  const document = buildHarnessManifest(JSON.parse(readFileSync(values.checks, 'utf8')))
  const { envelope, body } = signHarnessManifest(document)
  const sequence = document.sequence
  if (values.out) {
    writeFileSync(values.out, body)
    console.log(`Wrote the harness manifest, sequence ${sequence}, to ${values.out}`)
  }
  if (values.bundle) {
    bundle(envelope)
    console.log(`Bundled the harness manifest, sequence ${sequence}`)
  }
  if (values.publish) {
    const version = await publish(body, values.publish)
    console.log(`Published the harness manifest, sequence ${sequence}, with Sarto ${version}`)
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  await main()
}
