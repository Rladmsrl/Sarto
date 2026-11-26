// @ts-check
// Sarto's signing keys: the release key signs every update file, the sources key the list of
// download sources, the harnesses key the harness compatibility manifest, each as a `current` and a
// `next` key the app and the daemon accept alike. The public keys live in
// tools/sarto/update-keys.json, which the app's SartoUpdateKeys and the agent host's MANIFEST_KEYS
// must match; the private keys never enter the repository.
//
//   node tools/sarto/update-keys.mjs generate --out <folder> [--purpose <name>]...
//   node tools/sarto/update-keys.mjs public <key.pem>          the raw public key of a private key
//
// `generate` writes <purpose>-current.pem and <purpose>-next.pem for each purpose named, or for all
// of them, refuses to overwrite any, and puts their public keys in update-keys.json beside the
// others. No dependencies.

import { createPrivateKey, createPublicKey, generateKeyPairSync } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseArgs } from 'node:util'

export const KEYS_FILE = new URL('./update-keys.json', import.meta.url)
const PURPOSES = ['release', 'sources', 'harnesses']
const SLOTS = /** @type {const} */ (['current', 'next'])

/** @param {string} message @returns {never} */
function fail(message) {
  console.error(message)
  process.exit(1)
}

/** The raw Ed25519 public key in standard base64, as update-keys.json and the app keep it. */
export function rawPublicKey(/** @type {import('node:crypto').KeyObject} */ key) {
  const jwk = (key.type === 'public' ? key : createPublicKey(key)).export({ format: 'jwk' })
  if (jwk.crv !== 'Ed25519' || typeof jwk.x !== 'string') throw new Error('Not an Ed25519 key')
  return Buffer.from(jwk.x, 'base64url').toString('base64')
}

function generate(/** @type {string} */ out, /** @type {string[]} */ purposes) {
  const unknown = purposes.filter((purpose) => !PURPOSES.includes(purpose))
  if (unknown.length > 0) fail(`No such purpose: ${unknown.join(', ')}`)
  const folder = path.resolve(out)
  mkdirSync(folder, { recursive: true, mode: 0o700 })
  /** @type {Record<string, Record<string, string>>} */
  const keys = existsSync(KEYS_FILE) ? JSON.parse(readFileSync(KEYS_FILE, 'utf8')) : {}
  const files = purposes.flatMap((purpose) =>
    SLOTS.map((slot) => ({ purpose, slot, file: path.join(folder, `${purpose}-${slot}.pem`) })),
  )
  const taken = files.filter(({ file }) => existsSync(file))
  if (taken.length > 0) fail(`${taken.map(({ file }) => file).join(', ')} already exist`)
  for (const { purpose, slot, file } of files) {
    const { privateKey, publicKey } = generateKeyPairSync('ed25519')
    writeFileSync(file, privateKey.export({ format: 'pem', type: 'pkcs8' }), { mode: 0o600 })
    ;(keys[purpose] = keys[purpose] ?? {})[slot] = rawPublicKey(publicKey)
  }
  writeFileSync(KEYS_FILE, `${JSON.stringify(keys, null, 2)}\n`)
  console.log(`Wrote ${files.length} private keys to ${folder}; keep them safe and out of git.`)
  console.log(`Updated ${path.relative(process.cwd(), fileURLToPath(KEYS_FILE))}.`)
}

function main() {
  const { positionals, values } = parseArgs({
    allowPositionals: true,
    options: { out: { type: 'string' }, purpose: { type: 'string', multiple: true } },
  })
  const [command, file] = positionals
  if (command === 'generate') {
    if (!values.out) fail('generate needs --out <folder>')
    generate(values.out, values.purpose ?? PURPOSES)
  } else if (command === 'public' && file) {
    console.log(rawPublicKey(createPrivateKey(readFileSync(file, 'utf8'))))
  } else {
    fail('Usage: update-keys.mjs generate --out <folder> [--purpose <name>]... | public <key.pem>')
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) main()
