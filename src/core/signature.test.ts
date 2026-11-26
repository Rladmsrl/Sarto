import { generateKeyPairSync, sign } from 'node:crypto'
import { describe, expect, it } from 'vitest'
import { verifySignature } from './signature'

function keyPair(): { raw: string; sign(message: Uint8Array): Uint8Array } {
  const { privateKey, publicKey } = generateKeyPairSync('ed25519')
  const x = publicKey.export({ format: 'jwk' }).x!
  return {
    raw: Buffer.from(x, 'base64url').toString('base64'),
    sign: (message) => new Uint8Array(sign(null, message, privateKey)),
  }
}

describe('verifySignature', () => {
  const message = new TextEncoder().encode('harnesses.json')

  it('accepts a signature under either of the keys', () => {
    const current = keyPair()
    const next = keyPair()
    expect(verifySignature(message, current.sign(message), [current.raw, next.raw])).toBe(true)
    expect(verifySignature(message, next.sign(message), [current.raw, next.raw])).toBe(true)
  })

  it('refuses another key, a changed message and a signature of the wrong length', () => {
    const signer = keyPair()
    const other = keyPair()
    const signature = signer.sign(message)
    expect(verifySignature(message, signature, [other.raw])).toBe(false)
    expect(
      verifySignature(new TextEncoder().encode('harnesses.jsoN'), signature, [signer.raw]),
    ).toBe(false)
    expect(verifySignature(message, signature.subarray(0, 63), [signer.raw])).toBe(false)
    expect(verifySignature(message, signature, ['not a key'])).toBe(false)
  })
})
