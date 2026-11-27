// @ts-check
// Signing for Sarto's releases: Ed25519 with
// a PKCS#8 PEM key from the environment, checked against the public keys the app has built in
// (tools/sarto/update-keys.json) before anything is written, so a release never ships a signature
// the app would refuse.

import { createPrivateKey, createPublicKey, sign, verify } from 'node:crypto'
import { readFileSync, realpathSync } from 'node:fs'
import { readFile, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseArgs } from 'node:util'

/** @typedef {'release' | 'sources' | 'harnesses'} Purpose */

/** @returns {Record<Purpose, { current: string, next: string }>} */
export function publicKeys() {
  return JSON.parse(readFileSync(new URL('./update-keys.json', import.meta.url), 'utf8'))
}

/** @param {string} raw */
function publicKey(raw) {
  return createPublicKey({
    key: { kty: 'OKP', crv: 'Ed25519', x: Buffer.from(raw, 'base64').toString('base64url') },
    format: 'jwk',
  })
}

/**
 * A signer for `purpose` from the PEM in environment variable `variable`; it refuses a key whose
 * signatures neither the app's current nor its next key of that purpose accepts.
 *
 * @param {Purpose} purpose
 * @param {string} variable
 */
export function signerFrom(purpose, variable) {
  const pem = process.env[variable] ?? ''
  if (!pem.trim()) throw new Error(`${variable} is not set, and nothing ships unsigned`)
  let key
  try {
    key = createPrivateKey(pem)
  } catch {
    throw new Error(`${variable} is not a PEM private key`)
  }
  if (key.asymmetricKeyType !== 'ed25519') throw new Error(`${variable} is not an Ed25519 key`)
  const keys = publicKeys()[purpose]
  const accepted = [keys.current, keys.next].map(publicKey)
  /** @param {Buffer} message */
  return (message) => {
    const signature = sign(null, message, key)
    if (!accepted.some((pub) => verify(null, message, pub, signature))) {
      throw new Error(`The app's ${purpose} keys do not accept signatures of ${variable}`)
    }
    return signature
  }
}

/**
 * What the release key signs for an update file: its name, a newline and its bytes, so one
 * channel's file cannot pass as another's.
 *
 * @param {string} name
 * @param {Buffer} file
 */
export function updateFileMessage(name, file) {
  return Buffer.concat([Buffer.from(`${name}\n`, 'utf8'), file])
}

function isMainModule() {
  if (import.meta.main !== undefined) return import.meta.main
  if (!process.argv[1]) return false
  try {
    return realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))
  } catch {
    return false
  }
}

if (isMainModule()) {
  const { values, positionals } = parseArgs({
    allowPositionals: true,
    options: {
      purpose: { type: 'string' },
      env: { type: 'string' },
    },
  })
  const purpose = /** @type {Purpose} */ (values.purpose?.trim() || 'release')
  const envVar = values.env?.trim() || 'SARTO_UPDATE_SIGNING_KEY'
  if (positionals.length === 0) {
    console.error(
      'Usage: node tools/sarto/signing.mjs [--purpose release] [--env SARTO_UPDATE_SIGNING_KEY] <file> [...]',
    )
    process.exit(2)
  }
  const signer = signerFrom(purpose, envVar)
  for (const target of positionals) {
    const resolved = path.resolve(target)
    const body = await readFile(resolved)
    const name = path.basename(resolved)
    const signature = signer(updateFileMessage(name, body))
    await writeFile(`${resolved}.sig`, `${signature.toString('base64')}\n`)
    console.log(`Signed ${name} -> ${name}.sig`)
  }
}
