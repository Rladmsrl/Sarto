import { describe, expect, it } from 'vitest'
import {
  approvalCode,
  approvalCommitment,
  approveWrap,
  computeKeybagAuthVerifier,
  createKeybagV2,
  deriveKeybagAuthToken,
  deriveSyncDevicePublicKey,
  generateMasterKey,
  generateRecoveryKey,
  generateSyncDeviceKeyPair,
  openItemJson,
  openMasterKeyForDevice,
  openScopeJson,
  openSyncBlob,
  parseRecoveryKey,
  sealItemJson,
  sealMasterKeyForDevice,
  sealScopeJson,
  sealSyncBlob,
  syncBase64UrlEncode,
  unwrapMasterKeyWithRecoveryKey,
  verifyWrapApproval,
} from './crypto'
import {
  deleteLwwItem,
  emptyLwwMap,
  isEncryptedSyncEnvelope,
  isSyncDeviceKeyWrap,
  isSyncRecoveryKeyWrap,
  mergeLwwMaps,
  putLwwItem,
} from './protocol'

describe('Sarto E2EE Sync Crypto & LWW CRDT Merge', () => {
  it('generates and checksum-verifies 128-bit recovery keys and wraps/unwraps SMK', async () => {
    const smk = generateMasterKey()
    const recoveryKey = await generateRecoveryKey()
    expect(recoveryKey).toMatch(/^[0-9A-HJKMNP-TV-Z]{4}(-[0-9A-HJKMNP-TV-Z]{4}){6}$/)

    // Normalization: lowercase, spaces, optional prefix, O->0, I/L->1 all parse identically.
    const raw = await parseRecoveryKey(recoveryKey)
    expect(raw?.length).toBe(16)
    const messy = `sarto-${recoveryKey.toLowerCase().replace(/-/g, ' ').replace(/0/g, 'o').replace(/1/g, 'l')}`
    expect(await parseRecoveryKey(messy)).toEqual(raw)

    // Flipping a single character fails the 12-bit checksum.
    const flipped = (recoveryKey[0] === 'A' ? 'B' : 'A') + recoveryKey.slice(1)
    expect(await parseRecoveryKey(flipped)).toBeNull()

    const { keybag, recoveryKey: rk2 } = await createKeybagV2(
      smk,
      syncBase64UrlEncode((await generateSyncDeviceKeyPair()).publicKey),
    )
    expect(keybag.v).toBe(2)
    expect(keybag.keyEpoch).toBe(1)
    expect(await unwrapMasterKeyWithRecoveryKey(keybag.recovery, rk2)).toEqual(smk)
    await expect(unwrapMasterKeyWithRecoveryKey(keybag.recovery, recoveryKey)).rejects.toThrow()
  })

  it('seals and opens SMK for a specific X25519 device key and rejects wrong keys or tampered epochs', async () => {
    const smk = generateMasterKey()
    const macA = await generateSyncDeviceKeyPair()
    const macB = await generateSyncDeviceKeyPair()
    const derivedA = await deriveSyncDevicePublicKey(macA.privateKey)
    expect(derivedA.publicKey).toEqual(macA.publicKey)
    expect(derivedA.deviceId).toBe(macA.deviceId)

    const wrapA = await sealMasterKeyForDevice(smk, syncBase64UrlEncode(macA.publicKey), {
      keyEpoch: 1,
      deviceName: 'Mac A',
    })
    expect(await openMasterKeyForDevice(wrapA, macA.privateKey)).toEqual(smk)
    await expect(openMasterKeyForDevice(wrapA, macB.privateKey)).rejects.toThrow()
    await expect(
      openMasterKeyForDevice({ ...wrapA, keyEpoch: 2 }, macA.privateKey),
    ).rejects.toThrow()
  })

  it('shows one code on both devices, which any other key or nonce changes', async () => {
    const newMac = syncBase64UrlEncode((await generateSyncDeviceKeyPair()).publicKey)
    const approver = syncBase64UrlEncode((await generateSyncDeviceKeyPair()).publicKey)
    const other = syncBase64UrlEncode((await generateSyncDeviceKeyPair()).publicKey)
    const nN = syncBase64UrlEncode(new Uint8Array(32).fill(1))
    const nA = syncBase64UrlEncode(new Uint8Array(32).fill(2))
    const code = await approvalCode({
      accountId: 'acct_1',
      devicePublicKey: newMac,
      approverPublicKey: approver,
      deviceNonce: nN,
      approverNonce: nA,
    })
    expect(code).toMatch(/^[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$/)
    const input = {
      accountId: 'acct_1',
      devicePublicKey: newMac,
      approverPublicKey: approver,
      deviceNonce: nN,
      approverNonce: nA,
    }
    for (const change of [
      { accountId: 'acct_2' },
      { devicePublicKey: other },
      { approverPublicKey: other },
      { deviceNonce: nA },
      { approverNonce: nN },
    ]) {
      expect(await approvalCode({ ...input, ...change })).not.toBe(code)
    }
    // The commitment binds the nonce to the requesting key, so neither can change after it.
    const commitment = await approvalCommitment(newMac, nN)
    expect(commitment).toHaveLength(43)
    expect(await approvalCommitment(other, nN)).not.toBe(commitment)
    expect(await approvalCommitment(newMac, nA)).not.toBe(commitment)
  })

  it('takes a wrap only from a device it trusts, never one the server sealed', async () => {
    const smk = generateMasterKey()
    const newMac = await generateSyncDeviceKeyPair()
    const approver = await generateSyncDeviceKeyPair()
    const server = await generateSyncDeviceKeyPair()
    const newMacKey = syncBase64UrlEncode(newMac.publicKey)
    const approverKey = syncBase64UrlEncode(approver.publicKey)
    const serverKey = syncBase64UrlEncode(server.publicKey)

    const sealed = await sealMasterKeyForDevice(smk, newMacKey, { accountId: 'acct_1' })
    const approved = await approveWrap(sealed, approver.privateKey, approverKey, 'acct_1')
    const trust = (keys: string[]) =>
      verifyWrapApproval(approved, newMac.privateKey, keys, 'acct_1')
    expect(await trust([approverKey])).toBe(true)
    // A key the user did not confirm vouches for nothing.
    expect(await trust([serverKey])).toBe(false)
    expect(await verifyWrapApproval(sealed, newMac.privateKey, [approverKey], 'acct_1')).toBe(false)
    // The server may seal a key of its own and sign as itself, which no trusted key accepts.
    const forged = await approveWrap(
      await sealMasterKeyForDevice(generateMasterKey(), newMacKey, { accountId: 'acct_1' }),
      server.privateKey,
      serverKey,
      'acct_1',
    )
    expect(await verifyWrapApproval(forged, newMac.privateKey, [approverKey], 'acct_1')).toBe(false)
    // Nor can it carry a trusted approver's name over to a wrap of its own.
    const relabelled = { ...forged, approval: { ...forged.approval!, ...approved.approval! } }
    expect(await verifyWrapApproval(relabelled, newMac.privateKey, [approverKey], 'acct_1')).toBe(
      false,
    )
    expect(await verifyWrapApproval(approved, newMac.privateKey, [approverKey], 'acct_2')).toBe(
      false,
    )
    // A device sealing the key to itself vouches for that wrap with its own key.
    const own = await approveWrap(sealed, newMac.privateKey, newMacKey, 'acct_1')
    expect(await verifyWrapApproval(own, newMac.privateKey, [newMacKey], 'acct_1')).toBe(true)
  })

  it('seals and opens scope JSON envelopes and blocks cross-scope or cross-revision replay', async () => {
    const smk = generateMasterKey()
    const payload = { palette: 'obsidian', accent: 'cobalt', mcp: ['github', 'linear'] }
    const env = await sealScopeJson(smk, 'ui-prefs', 3, payload, { keyEpoch: 1 })

    const opened = await openScopeJson<typeof payload>(smk, 'ui-prefs', 3, env)
    expect(opened).toEqual(payload)

    // Replay at another revision, scope, epoch or altered encoding must fail GCM AAD authentication.
    await expect(openScopeJson(smk, 'ui-prefs', 4, env)).rejects.toThrow()
    await expect(openScopeJson(smk, 'mcp-vault', 3, env)).rejects.toThrow()
    await expect(openScopeJson(smk, 'ui-prefs', 3, { ...env, keyEpoch: 2 })).rejects.toThrow()
    await expect(openScopeJson(smk, 'ui-prefs', 3, { ...env, encoding: 'gzip' })).rejects.toThrow()
  })

  it('binds Keybag v2 wraps to accountId in AAD and derives matching SMK auth verifier', async () => {
    const smk = generateMasterKey()
    const dev = await generateSyncDeviceKeyPair()
    const pubB64 = syncBase64UrlEncode(dev.publicKey)
    const { keybag, recoveryKey } = await createKeybagV2(smk, pubB64, {
      accountId: 'acct_owner_1',
      deviceName: 'Mac A',
    })
    expect(keybag.authVerifier).toMatch(/^[0-9a-f]{64}$/)
    const token = await deriveKeybagAuthToken(smk, 'acct_owner_1')
    expect(await computeKeybagAuthVerifier(smk, 'acct_owner_1')).toBe(keybag.authVerifier)
    expect(await deriveKeybagAuthToken(smk, 'acct_other')).not.toBe(token)

    expect(
      await openMasterKeyForDevice(keybag.devices[0]!, dev.privateKey, 'acct_owner_1'),
    ).toEqual(smk)
    await expect(
      openMasterKeyForDevice(keybag.devices[0]!, dev.privateKey, 'acct_other'),
    ).rejects.toThrow()

    expect(
      await unwrapMasterKeyWithRecoveryKey(keybag.recovery, recoveryKey, 'acct_owner_1'),
    ).toEqual(smk)
    await expect(
      unwrapMasterKeyWithRecoveryKey(keybag.recovery, recoveryKey, 'acct_other'),
    ).rejects.toThrow()
  })

  it('gzip-compresses and encrypts keyed usage records and blocks cross-key replay', async () => {
    const smk = generateMasterKey()
    const payload = {
      v: 1,
      deviceId: 'a1b2c3d4e5f60708',
      deviceName: 'Mac Studio',
      updatedAt: 1_700_000_000_000,
      host: {
        buckets: Array.from({ length: 50 }, (_, i) => ({
          quarter: 1_900_000 + i,
          source: 'sarto',
          agentId: 'claude-code',
          model: 'claude-sonnet-4-5',
          project: '/Users/alice/project',
          rows: 3,
          input: 1200,
          output: 400,
          reasoning: 0,
          cacheRead: 800,
          cacheWrite: 100,
          cacheWrite1h: 0,
          turns: 1,
        })),
      },
    }
    const env = await sealItemJson(smk, 'usage', 'a1b2c3d4e5f60708', 2, payload, {
      compress: true,
      keyEpoch: 1,
    })
    expect(env.encoding).toBe('gzip')
    expect(env.keyEpoch).toBe(1)
    // Repetitive JSON compresses far smaller than its raw byte length.
    expect(env.ciphertext.length).toBeLessThan(JSON.stringify(payload).length / 2)

    const opened = await openItemJson<typeof payload>(smk, 'usage', 'a1b2c3d4e5f60708', 2, env)
    expect(opened).toEqual(payload)

    // Cross-device-key or cross-revision replay fails GCM AAD check.
    await expect(openItemJson(smk, 'usage', 'ffffffffffffffff', 2, env)).rejects.toThrow()
    await expect(openItemJson(smk, 'usage', 'a1b2c3d4e5f60708', 3, env)).rejects.toThrow()
  })

  it('seals and opens CAS binary blobs with SHA-256 integrity checks', async () => {
    const smk = generateMasterKey()
    const archive = new TextEncoder().encode('# SKILL.md\nCustom skill content')
    const sealed = await sealSyncBlob(smk, archive)

    const opened = await openSyncBlob(smk, sealed.iv, sealed.ciphertext, sealed.blobSha256)
    expect(opened).toEqual(archive)

    await expect(openSyncBlob(smk, sealed.iv, sealed.ciphertext, '0'.repeat(64))).rejects.toThrow(
      /mismatch/,
    )
  })

  it('converges commutatively and idempotently across concurrent edits and tombstones', () => {
    let macA = emptyLwwMap<string>()
    macA = putLwwItem(macA, 'palette', 'obsidian', 100, 'mac-a')
    macA = putLwwItem(macA, 'mcp:linear', 'enabled', 110, 'mac-a')
    macA = putLwwItem(macA, 'mcp:old', 'v1', 90, 'mac-a')

    let macB = emptyLwwMap<string>()
    // Brand-new Mac B has default timestamp 0, so Mac A's palette wins!
    macB = putLwwItem(macB, 'palette', 'crystal', 0, 'mac-b')
    // Mac B adds a new skill concurrently and deletes mcp:old at t=120.
    macB = putLwwItem(macB, 'skill:custom', 'on', 115, 'mac-b')
    macB = deleteLwwItem(macB, 'mcp:old', 120, 'mac-b')

    const ab = mergeLwwMaps(macA, macB, 200)
    const ba = mergeLwwMaps(macB, macA, 200)
    const idemp = mergeLwwMaps(ab, macB, 200)

    expect(ab).toEqual(ba)
    expect(idemp).toEqual(ab)
    expect(ab.items.palette?.value).toBe('obsidian')
    expect(ab.items['mcp:linear']?.value).toBe('enabled')
    expect(ab.items['skill:custom']?.value).toBe('on')
    expect(ab.items['mcp:old']).toBeUndefined()
    expect(ab.tombstones['mcp:old']?.deletedAt).toBe(120)

    // JSON round-trip dropping `value: undefined` on an item must still survive mergeLwwMaps.
    const roundTripped = JSON.parse(
      JSON.stringify({
        items: { flag: { value: undefined, updatedAt: 300, updatedBy: 'mac-a' } },
        tombstones: {},
      }),
    ) as ReturnType<typeof emptyLwwMap<string | undefined>>
    const mergedUndefined = mergeLwwMaps(roundTripped, emptyLwwMap<string | undefined>(), 305)
    expect('flag' in mergedUndefined.items).toBe(true)
    expect(mergedUndefined.items.flag?.updatedAt).toBe(300)
  })

  it('ignores prototype-polluting keys in LWW maps and enforces exact 16-char base64url IVs', async () => {
    let map = emptyLwwMap<string>()
    for (const bad of ['__proto__', 'constructor', 'prototype']) {
      map = putLwwItem(map, bad, 'polluted', 100, 'mac-a')
      map = deleteLwwItem(map, bad, 200, 'mac-a')
    }
    expect(Object.keys(map.items)).toEqual([])
    expect(Object.keys(map.tombstones)).toEqual([])
    const parsedBad = JSON.parse(
      '{"items":{"__proto__":{"value":"evil","updatedAt":1,"by":"a"},"ok":{"value":"yes","updatedAt":2,"by":"a"}},"tombstones":{"constructor":{"deletedAt":3,"by":"a"}}}',
    ) as ReturnType<typeof emptyLwwMap<string>>
    const merged = mergeLwwMaps(emptyLwwMap<string>(), parsedBad, 10)
    expect(Object.keys(merged.items)).toEqual(['ok'])
    expect(Object.keys(merged.tombstones)).toEqual([])
    expect(({} as Record<string, unknown>).polluted).toBeUndefined()

    const smk = generateMasterKey()
    const env = await sealScopeJson(smk, 'ui-prefs', 1, { a: 1 })
    expect(isEncryptedSyncEnvelope(env)).toBe(true)
    expect(isEncryptedSyncEnvelope({ ...env, iv: 'a'.repeat(12) })).toBe(false)
    expect(isEncryptedSyncEnvelope({ ...env, iv: 'a'.repeat(24) })).toBe(false)

    const dev = await generateSyncDeviceKeyPair()
    const { keybag } = await createKeybagV2(smk, syncBase64UrlEncode(dev.publicKey))
    expect(isSyncDeviceKeyWrap(keybag.devices[0])).toBe(true)
    expect(isSyncDeviceKeyWrap({ ...keybag.devices[0], iv: 'a'.repeat(15) })).toBe(false)
    expect(isSyncRecoveryKeyWrap(keybag.recovery)).toBe(true)
    expect(isSyncRecoveryKeyWrap({ ...keybag.recovery, iv: 'a'.repeat(17) })).toBe(false)
  })
})
