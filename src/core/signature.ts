// Ed25519 signatures over the documents Sarto's release source signs, such as the harness
// compatibility manifest, checked against raw public keys in standard base64.

import { createPublicKey, verify, type KeyObject } from 'node:crypto'

const publicKeys = new Map<string, KeyObject>()

function publicKey(raw: string): KeyObject {
  let key = publicKeys.get(raw)
  if (!key) {
    const x = Buffer.from(raw, 'base64').toString('base64url')
    key = createPublicKey({ key: { kty: 'OKP', crv: 'Ed25519', x }, format: 'jwk' })
    publicKeys.set(raw, key)
  }
  return key
}

/** Whether `signature` is an Ed25519 signature of `message` under one of `keys` (raw, base64). */
export function verifySignature(
  message: Uint8Array,
  signature: Uint8Array,
  keys: readonly string[],
): boolean {
  if (signature.length !== 64) return false
  return keys.some((raw) => {
    try {
      return verify(null, message, publicKey(raw), signature)
    } catch {
      return false
    }
  })
}
