// What a Mac holds once it has the account's sync key but its first sync fails: the key and, after
// setting the vault up, the recovery key, which is shown only once. And what it keeps of its
// owner's own choices against the account's: a device the owner removed stays removed.

import { mkdir, rename, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  approveMac,
  memorySyncServer,
  syncTestMacs,
  type PairedDevices,
  type SyncTestMacs,
} from '../testing/sync-server'

let macs: SyncTestMacs | null = null

afterEach(async () => {
  await macs?.stop()
  macs = null
})

describe('a first sync that fails', () => {
  it('keeps the key it was approved for, asks for no second approval, and syncs later', async () => {
    const server = memorySyncServer()
    macs = syncTestMacs(server)
    const approver = await macs.start('Mac A')
    await approver.accountChanged()
    await approver.setupVault()
    const service = await macs.start('Mac B')
    await service.accountChanged()

    await service.syncNow()
    await approver.syncNow()
    await service.syncNow()
    await approver.syncNow()
    await approver.approveDevice(service.status().syncDeviceId!)
    server.failScopeWrites = true
    await service.confirmApproval(true)

    let status = service.status()
    expect(status.needsKey).toBe(false)
    expect(status.keyState).toBe('ready')
    expect(status.error).toEqual(expect.any(String))
    const asked = server.approvalPosts

    server.failScopeWrites = false
    await service.syncNow()
    status = service.status()
    expect(status.keyState).toBe('ready')
    expect(status.error).toBeNull()
    expect(server.scopeWrites).toBeGreaterThan(0)
    expect(server.approvalPosts).toBe(asked)
  })

  it('hands over the recovery key of the vault it set up', async () => {
    const server = memorySyncServer()
    server.failScopeWrites = true
    macs = syncTestMacs(server)
    const service = await macs.start('Mac A')
    await service.accountChanged()

    const { recoveryKey, status } = await service.setupVault()
    expect(server.keybag).not.toBeNull()
    expect(recoveryKey).toEqual(expect.any(String))
    expect(status.keyState).toBe('ready')
    expect(status.error).toEqual(expect.any(String))
  })

  it('leaves a device its owner removed by hand unpaired when the account syncs again', async () => {
    const server = memorySyncServer()
    macs = syncTestMacs(server)
    const device = {
      id: 'd'.repeat(32),
      publicKey: Buffer.alloc(32, 7).toString('base64'),
      name: 'Other Mac',
      kind: 'desktop',
      platform: 'darwin',
    }
    const paired: PairedDevices = { known: new Set(), added: [] }
    const mac = await macs.start('Mac A', paired)
    await mac.accountChanged()
    await mac.setupVault()
    const other = await macs.start('Mac B')
    await other.accountChanged()
    await approveMac(mac, other)
    expect(other.status().keyState).toBe('ready')

    // The other Mac's app publishes its key, and this Mac pairs it without a code.
    await other.pushClientState({ device })
    await other.syncNow()
    await mac.syncNow()
    expect(paired.added).toEqual([device.publicKey])
    paired.known.add(device.id)

    paired.known.delete(device.id)
    await mac.deviceRemovedByHand(device.id)
    await other.pushClientState({ uiPrefs: { theme: { value: 'crystal', updatedAt: 5 } } })
    await other.syncNow()
    await mac.syncNow()
    expect(paired.added).toEqual([device.publicKey])

    // Pairing it again, as with a code, is the owner's word that it may be paired once more.
    paired.known.add(device.id)
    await other.pushClientState({ uiPrefs: { theme: { value: 'warm', updatedAt: 6 } } })
    await other.syncNow()
    await mac.syncNow()
    paired.known.delete(device.id)
    await other.pushClientState({ uiPrefs: { theme: { value: 'obsidian', updatedAt: 7 } } })
    await other.syncNow()
    await mac.syncNow()
    expect(paired.added).toEqual([device.publicKey, device.publicKey])
  })

  it('unpairs a device the account removed once the remote host reports it, after a restart', async () => {
    const server = memorySyncServer()
    macs = syncTestMacs(server)
    const paired: PairedDevices = { known: new Set(), added: [], removed: [] }
    const mac = await macs.start('Mac A', paired)
    await mac.accountChanged()
    await mac.setupVault()
    const other = await macs.start('Mac B')
    await other.accountChanged()
    await approveMac(mac, other)
    const app = (id: string, fill: number) => ({
      id,
      publicKey: Buffer.alloc(32, fill).toString('base64'),
      name: 'iPhone',
      kind: 'phone',
      platform: 'ios',
    })

    // The other Mac's app replaces its key, which deletes the old one for the account.
    await other.pushClientState({ device: app('e'.repeat(32), 1) })
    await other.syncNow()
    await other.pushClientState({ device: app('f'.repeat(32), 2) })
    await other.syncNow()

    // This Mac syncs before its remote host has said which devices it holds.
    await mac.syncNow()
    expect(paired.removed).toEqual([])

    // Then the remote host reports, and holds the deleted key from before the restart.
    paired.known.add('e'.repeat(32))
    await mac.pairedDevicesChanged()
    expect(paired.removed).toEqual(['e'.repeat(32)])
  })
})

it('preserves global memories when the scan cannot enumerate their directory', async () => {
  macs = syncTestMacs(memorySyncServer())
  const mac = await macs.start('Mac')
  const dir = path.join(mac['deps'].dataPath, 'memory', 'global')
  await mkdir(dir, { recursive: true })
  await writeFile(path.join(dir, 'keep.md'), 'Keep this memory')
  await mac['captureMemoryAndHostMesh']('change')
  await rename(dir, dir + '-saved')
  await writeFile(dir, 'temporarily unavailable')
  await mac['captureMemoryAndHostMesh']('change')
  expect(mac['replica'].memoryAndMesh.memories.items.keep).toBeDefined()
})

it('retries local application after a failed apply at the same server revision', async () => {
  macs = syncTestMacs(memorySyncServer())
  const source = await macs.start('Mac A')
  await source.accountChanged()
  await source.setupVault()
  const mac = await macs.start('Mac B')
  await mac.accountChanged()
  await approveMac(source, mac)
  await source.pushClientState({ uiPrefs: { theme: { value: 'warm', updatedAt: 8 } } })
  await source.syncNow()
  const refresh = vi.spyOn(mac['deps'].themes, 'refresh').mockRejectedValueOnce(new Error('busy'))
  await expect(mac.syncNow()).rejects.toThrow('busy')
  await mac.syncNow()
  expect(refresh).toHaveBeenCalledTimes(2)
})
