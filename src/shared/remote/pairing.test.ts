import { describe, expect, it } from 'vitest'
import {
  decodePairing,
  encodePairing,
  MAX_PAIRING_ADDRESSES,
  DIRECT_PAIRING_VERSION,
  PAIRING_VERSION,
  type PairingPayload,
} from './pairing'

const payload: PairingPayload = {
  version: DIRECT_PAIRING_VERSION,
  hostKey: Uint8Array.from({ length: 32 }, (_, i) => i),
  secret: Uint8Array.from({ length: 32 }, (_, i) => 255 - i),
  addresses: [
    { host: '192.168.1.8', port: 47821 },
    { host: 'fd3c:9a1e:5b20::8', port: 47821 },
    { host: 'frp.example.com', port: 60021 },
  ],
}

describe('pairing codes', () => {
  it('carry the version, key, secret and addresses in base64url', () => {
    const text = encodePairing(payload)
    expect(text).toMatch(/^[A-Za-z0-9_-]+$/)
    expect(decodePairing(text)).toEqual(payload)
  })

  it('takes a code without addresses', () => {
    const bare = { ...payload, addresses: [] }
    const text = encodePairing(bare)
    // The version, the key and the secret: 65 bytes.
    expect(text).toHaveLength(87)
    expect(decodePairing(text)).toEqual(bare)
  })

  it('carries at most 16 addresses', () => {
    const many = Array.from({ length: 20 }, (_, i) => ({ host: `10.0.0.${i}`, port: 1000 + i }))
    const decoded = decodePairing(encodePairing({ ...payload, addresses: many }))!
    expect(decoded.addresses).toEqual(many.slice(0, MAX_PAIRING_ADDRESSES))
  })

  it('refuses what is not a code of this version', () => {
    const text = encodePairing(payload)
    const bytes = Uint8Array.from(atob(text.replace(/-/g, '+').replace(/_/g, '/')), (c) =>
      c.charCodeAt(0),
    )
    const encode = (b: Uint8Array) =>
      btoa(String.fromCharCode(...b))
        .replace(/\+/g, '-')
        .replace(/\//g, '_')
        .replace(/=+$/, '')
    expect(decodePairing(encode(Uint8Array.of(3, ...bytes.subarray(1))))).toBeNull()
    expect(decodePairing(encode(bytes.subarray(0, 64)))).toBeNull()
    expect(decodePairing(encode(bytes.subarray(0, bytes.length - 1)))).toBeNull()
    expect(decodePairing('not base64!')).toBeNull()
  })

  it('make a code without the relay as version 1, which devices that know only it read', () => {
    const text = encodePairing({ ...payload, version: PAIRING_VERSION })
    expect(atob(text.slice(0, 2) + '==').charCodeAt(0)).toBe(1)
    expect(decodePairing(text)).toEqual(payload)
  })

  it('carry the relay id and the relays from version 2, before the addresses', () => {
    const relayed: PairingPayload = {
      ...payload,
      version: PAIRING_VERSION,
      relay: {
        id: 'aeiscmkbkfqxdamrugy4dupb6e',
        urls: ['https://relay.sarto.dev', 'https://hk.relay.sarto.dev'],
      },
    }
    const text = encodePairing(relayed)
    expect(decodePairing(text)).toEqual(relayed)
    expect(decodePairing(encodePairing({ ...relayed, addresses: [] }))).toEqual({
      ...relayed,
      addresses: [],
    })
    // The version, the key, the secret, the id, the count and both origins.
    const bare = encodePairing({ ...relayed, addresses: [] })
    expect(bare.length).toBe(Math.ceil(((65 + 16 + 1 + 24 + 27) * 4) / 3))
  })

  it('refuse a relay part that is cut short or names no origin', () => {
    const relayed = encodePairing({
      ...payload,
      version: PAIRING_VERSION,
      addresses: [],
      relay: { id: 'aeiscmkbkfqxdamrugy4dupb6e', urls: ['https://relay.sarto.dev'] },
    })
    const bytes = Uint8Array.from(atob(relayed.replace(/-/g, '+').replace(/_/g, '/')), (c) =>
      c.charCodeAt(0),
    )
    const encode = (b: Uint8Array) =>
      btoa(String.fromCharCode(...b))
        .replace(/\+/g, '-')
        .replace(/\//g, '_')
        .replace(/=+$/, '')
    expect(decodePairing(encode(bytes.subarray(0, bytes.length - 3)))).toBeNull()
    const path = Uint8Array.from(bytes)
    path.set(new TextEncoder().encode('https://relay.sarto.d/'), 65 + 16 + 2)
    expect(decodePairing(encode(path))).toBeNull()
    expect(() =>
      encodePairing({
        ...payload,
        relay: { id: 'aeiscmkbkfqxdamrugy4dupb6e', urls: ['https://relay.sarto.dev/v1'] },
      }),
    ).toThrow()
    expect(() => encodePairing({ ...payload, relay: { id: 'NOT-AN-ID', urls: [] } })).toThrow()
  })

  it('refuses to carry a host that is not one', () => {
    expect(() =>
      encodePairing({ ...payload, addresses: [{ host: 'https://x', port: 1 }] }),
    ).toThrow()
    expect(() => encodePairing({ ...payload, addresses: [{ host: 'x', port: 0 }] })).toThrow()
  })
})
