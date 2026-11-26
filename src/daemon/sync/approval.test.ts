// Approving a Mac for the account's sync key (PROTOCOL.md section 4.1): both Macs show one code,
// and the waiting Mac takes a key only from the Mac whose code the user confirmed on it, never one
// the server sealed or a Mac the user did not confirm.

import { afterEach, describe, expect, it } from 'vitest'
import {
  approveWrap,
  generateMasterKey,
  generateSyncDeviceKeyPair,
  sealMasterKeyForDevice,
  syncBase64UrlEncode,
} from '@shared/sync/crypto'
import {
  approveMac,
  memorySyncServer,
  plantWrap,
  SYNC_ACCOUNT,
  syncTestMacs,
  type MemorySyncServer,
  type SyncTestMacs,
} from '../testing/sync-server'

let macs: SyncTestMacs | null = null

afterEach(async () => {
  await macs?.stop()
  macs = null
})

async function accountWithVault(server: MemorySyncServer) {
  macs = syncTestMacs(server)
  const approver = await macs.start('Mac A')
  await approver.accountChanged()
  const { recoveryKey } = await approver.setupVault()
  expect(recoveryKey).toEqual(expect.any(String))
  const waiting = await macs.start('Mac B')
  await waiting.accountChanged()
  return { approver, waiting }
}

/** A wrap of a key the server made, sealed to `deviceKey` and signed by a key of the server's. */
async function forgedWrap(server: MemorySyncServer, devicePublicKey: string) {
  const own = await generateSyncDeviceKeyPair()
  const ownKey = syncBase64UrlEncode(own.publicKey)
  const sealed = await sealMasterKeyForDevice(generateMasterKey(), devicePublicKey, {
    keyEpoch: server.keybag!.keyEpoch,
    accountId: SYNC_ACCOUNT.id,
  })
  return {
    key: ownKey,
    wrap: await approveWrap(sealed, own.privateKey, ownKey, SYNC_ACCOUNT.id),
  }
}

describe('approving a Mac for the sync key', () => {
  it('shows one code on both Macs and hands the key over once both sides agree', async () => {
    const server = memorySyncServer()
    const { approver, waiting } = await accountWithVault(server)
    expect(waiting.status().keyState).toBe('awaiting-approval')
    expect(waiting.status().approvalStage).toBe('waiting')
    expect(waiting.status().approvalCode).toBeNull()

    await approver.syncNow()
    await waiting.syncNow()
    expect(waiting.status().approvalStage).toBe('confirm')
    expect(waiting.status().approverName).toBe('Mac A')
    await approver.syncNow()
    const code = waiting.status().approvalCode
    expect(code).toMatch(/^[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$/)
    expect(approver.status().pendingApprovals.map((entry) => entry.code)).toEqual([code])

    // Approved on the other Mac before it was confirmed here, the key is not taken yet.
    await approver.approveDevice(waiting.status().syncDeviceId!)
    await waiting.syncNow()
    expect(waiting.status().keyState).toBe('awaiting-approval')
    expect(waiting.status().approvalCode).toBe(code)
    expect(waiting.status().error).toBeNull()

    await waiting.confirmApproval(true)
    expect(waiting.status().keyState).toBe('ready')
    expect(waiting.status().error).toBeNull()
  })

  it('never takes a key the server sealed, before or after the user confirmed a Mac', async () => {
    const server = memorySyncServer()
    const { approver, waiting } = await accountWithVault(server)
    const forged = await forgedWrap(server, [...server.approvals.values()][0]!.devicePublicKey)
    plantWrap(server, forged.wrap)
    await waiting.syncNow()
    expect(waiting.status().keyState).toBe('awaiting-approval')
    expect(waiting.status().error).toMatch(/not confirmed/)

    // The server answers in a Mac's name with a key of its own; the code it gets is not the one
    // any Mac shows, and while no one confirmed it, a wrap it signs is still refused.
    const request = [...server.approvals.values()][0]!
    server.approvals.set(request.deviceId, {
      ...request,
      answer: {
        approverDeviceId: forged.wrap.approval!.approverDeviceId,
        approverPublicKey: forged.key,
        approverName: 'Mac A',
        nonce: syncBase64UrlEncode(new Uint8Array(32).fill(9)),
        answeredAt: 1,
      },
    })
    await waiting.syncNow()
    expect(waiting.status().approvalStage).toBe('confirm')
    plantWrap(server, forged.wrap)
    await waiting.syncNow()
    expect(waiting.status().keyState).toBe('awaiting-approval')

    // The user sees the codes differ: the request starts over, and the real Mac approves it.
    await waiting.confirmApproval(false)
    expect(server.approvals.get(request.deviceId)?.answer).toBeUndefined()
    await approveMac(approver, waiting)
    expect(waiting.status().keyState).toBe('ready')
    plantWrap(server, forged.wrap)
    await waiting.syncNow()
    expect(waiting.status().keyState).toBe('ready')
  })

  it('reveals its nonce for one answer only, and starts over when the answer changes', async () => {
    const server = memorySyncServer()
    const { approver, waiting } = await accountWithVault(server)
    await approver.syncNow()
    await waiting.syncNow()
    const first = [...server.approvals.values()][0]!
    expect(first.reveal).toEqual(expect.any(String))

    // An answer chosen once the nonce is known would let the code be chosen too.
    server.approvals.set(first.deviceId, {
      ...first,
      answer: { ...first.answer!, nonce: syncBase64UrlEncode(new Uint8Array(32).fill(3)) },
    })
    await waiting.syncNow()
    const second = server.approvals.get(first.deviceId)!
    expect(second.commitment).not.toBe(first.commitment)
    expect(second.answer).toBeUndefined()
    expect(waiting.status().approvalCode).toBeNull()
  })

  it('does not approve a Mac whose request carries no commitment', async () => {
    const server = memorySyncServer()
    const { approver } = await accountWithVault(server)
    const earlier = await generateSyncDeviceKeyPair()
    server.approvals.set(earlier.deviceId, {
      deviceId: earlier.deviceId,
      devicePublicKey: syncBase64UrlEncode(earlier.publicKey),
      deviceName: 'Old Mac',
      platform: 'darwin',
      createdAt: 1,
      expiresAt: Number.MAX_SAFE_INTEGER,
    })
    await approver.syncNow()
    expect(approver.status().pendingApprovals).toEqual([])
    await expect(approver.approveDevice(earlier.deviceId)).rejects.toThrow(/earlier version/)
    expect(server.keybag!.devices.map((wrap) => wrap.deviceId)).not.toContain(earlier.deviceId)
  })

  it('emits status when pendingApprovals change and respects targetApproverDeviceId', async () => {
    const server = memorySyncServer()
    const { approver, waiting } = await accountWithVault(server)
    await approveMac(approver, waiting)
    expect(waiting.status().keyState).toBe('ready')

    // A third device targets `waiting` specifically; `approver` must stay out of the way.
    const requester = await macs!.start('iPhone Duo')
    await requester.accountChanged()
    const req = server.approvals.get(requester.status().syncDeviceId!)!
    server.approvals.set(req.deviceId, {
      ...req,
      targetApproverDeviceId: waiting.status().syncDeviceId!,
    })

    const emitted: string[][] = []
    const unsub = waiting.onChange((status) => {
      emitted.push(status.pendingApprovals.map((p) => p.code))
    })
    try {
      // Non-target Mac ignores the targeted request.
      await approver.syncNow()
      expect(server.approvals.get(req.deviceId)?.answer).toBeUndefined()
      expect(approver.status().pendingApprovals).toEqual([])

      // Target Mac answers; requester reveals; target Mac emits status with the code.
      await waiting.syncNow()
      expect(server.approvals.get(req.deviceId)?.answer?.approverDeviceId).toBe(
        waiting.status().syncDeviceId,
      )
      await requester.syncNow()
      const code = requester.status().approvalCode!
      expect(code).toMatch(/^[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$/)

      await waiting.syncNow()
      expect(emitted).toContainEqual([code])
    } finally {
      unsub()
    }
  })
})
