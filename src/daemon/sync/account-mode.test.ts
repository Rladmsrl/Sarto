// The sync's `account` mode, where the daemon's Sarto Cloud account owns the sign-in: its tokens
// are never written to the sync's files nor handed out by `sync.status`, and signing out of the
// account forgets the sync's keys and replica.

import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { createLogger } from '../../core/log'
import { MarketKeys, marketKeysFile } from '../../core/market-keys'
import { SettingsStore } from '../../core/settings'
import { ThemeStore, readThemeFolder } from '../../core/themes'
import { NO_SYSTEM_ENCRYPTION } from '../key'
import { SartoSyncService, type SyncAccountLink } from './service'

const ORIGIN = 'https://cloud.example'

interface FakeAccount extends SyncAccountLink {
  signedIn: { id: string; email: string; name: string | null } | null
  signOuts: number
}

function fakeAccount(): FakeAccount {
  const account: FakeAccount = {
    signedIn: null,
    signOuts: 0,
    origin: () => ORIGIN,
    profile: () => account.signedIn,
    token: async () => (account.signedIn ? 'access-token-never-stored' : null),
    signOut: async () => {
      account.signOuts++
      account.signedIn = null
    },
  }
  return account
}

async function startService(
  account: FakeAccount,
  usageRecords?: Record<string, unknown>,
  fetchImpl?: (url: string, init: RequestInit) => Promise<Response>,
) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'sarto-account-mode-'))
  const dataPath = path.join(root, 'data')
  await mkdir(dataPath, { recursive: true })
  if (fetchImpl) {
    account.signedIn = { id: 'acct_1', email: 'me@example.com', name: 'Me' }
    await writeFile(
      path.join(dataPath, 'sarto-sync.json'),
      JSON.stringify({
        version: 1,
        nodeId: 'self',
        mode: 'account',
        serverUrl: ORIGIN,
        account: account.signedIn,
        masterKeyBase64: Buffer.alloc(32, 1).toString('base64url'),
      }),
    )
  }
  if (usageRecords) {
    const state = path.join(dataPath, 'state')
    await mkdir(state)
    await writeFile(
      path.join(state, 'sarto-sync-replica.json'),
      JSON.stringify({ version: 1, usageRecords }),
    )
  }
  const settings = await SettingsStore.load(dataPath)
  const marketKeys = await MarketKeys.load({
    file: marketKeysFile(dataPath),
    cipher: NO_SYSTEM_ENCRYPTION,
    plainTextAllowed: true,
    servers: () => settings.get().marketplace.mcp,
    changed: () => {},
    log: createLogger('test-keys'),
  })
  const themesDir = path.join(dataPath, 'themes')
  const themes = new ThemeStore(await readThemeFolder(themesDir), 'sarto', {
    dir: themesDir,
    select: () => {},
    changed: () => {},
  })
  const relayConfigs: unknown[] = []
  const service = await SartoSyncService.start({
    dataPath,
    homeDir: path.join(root, 'home'),
    settings,
    marketKeys,
    themes,
    relaySeedBase64: null,
    account,
    hostPublicKey: () => null,
    hostName: () => 'Mac A',
    configureRelay: (config) => relayConfigs.push(config),
    addTrustedDevice: async () => {},
    knownDeviceIds: () => new Set(),
    reloadMemory: () => {},
    fetchImpl: fetchImpl ?? (() => Promise.reject(new Error('no network in this test'))),
    openSocket: () => {
      throw new Error('no stream in this test')
    },
    log: createLogger('test-sync'),
  })
  return { root, dataPath, service, relayConfigs }
}

describe('sync account mode', () => {
  const roots: string[] = []
  afterEach(async () => {
    for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true })
  })

  it('follows the account sign-in without storing or handing out its tokens', async () => {
    const account = fakeAccount()
    const { root, dataPath, service, relayConfigs } = await startService(account)
    roots.push(root)

    account.signedIn = { id: 'acct_1', email: 'me@example.com', name: 'Me' }
    await service.accountChanged()
    const status = service.status()
    expect(status.mode).toBe('account')
    expect(status.serverUrl).toBe(ORIGIN)
    expect(status.account).toEqual({ id: 'acct_1', email: 'me@example.com', name: 'Me' })
    expect(status.relayToken).toBeNull()
    // Signed in, but nothing syncs until this Mac has the sync key.
    expect(status.needsKey).toBe(true)
    expect(service.isConfigured()).toBe(false)
    // The account hands the relay its tokens; the sync does not.
    expect(relayConfigs).toEqual([])

    const stored = await readFile(path.join(dataPath, 'sarto-sync.json'), 'utf8')
    expect(stored).not.toContain('access-token-never-stored')
    expect(JSON.parse(stored)).toMatchObject({
      mode: 'account',
      accessToken: null,
      relayToken: null,
    })
  })

  it('forgets the sync when the account signs out, and signs the account out on disconnect', async () => {
    const account = fakeAccount()
    const { root, dataPath, service } = await startService(account)
    roots.push(root)
    account.signedIn = { id: 'acct_1', email: 'me@example.com', name: null }
    await service.accountChanged()

    await service.disconnect()
    expect(account.signOuts).toBe(1)
    const status = service.status()
    expect(status.mode).toBe('off')
    expect(status.account).toBeNull()
    expect(
      JSON.parse(await readFile(path.join(dataPath, 'sarto-sync.json'), 'utf8')),
    ).toMatchObject({
      mode: 'off',
      account: null,
      masterKeyBase64: null,
    })
  })

  it('starts over for another account, so one account never sees another one’s replica', async () => {
    const account = fakeAccount()
    const { root, service } = await startService(account)
    roots.push(root)
    account.signedIn = { id: 'acct_1', email: 'a@example.com', name: null }
    await service.accountChanged()
    account.signedIn = { id: 'acct_2', email: 'b@example.com', name: null }
    await service.accountChanged()
    expect(service.status().account?.id).toBe('acct_2')
    expect(service.status().revisions).toEqual({})
  })
})

const oldId = '1111111111111111'
const newId = '2222222222222222'
const otherId = '3333333333333333'
const usageRecords = Object.fromEntries(
  [oldId, newId, otherId].map((id) => [
    id,
    {
      v: 1,
      deviceId: id,
      deviceName: 'Mac',
      updatedAt: 2,
      host: {
        updatedAt: 2,
        computerSources: {},
        fromComputer: true,
        buckets: [],
        ...(id === newId ? { previousDeviceId: oldId } : {}),
      },
      ...(id === oldId ? { island: { updatedAt: 1, payload: {} } } : {}),
    },
  ]),
)

it('counts one device per computer and keeps sections stored under the earlier key', async () => {
  const { root, service } = await startService(fakeAccount(), usageRecords)
  try {
    expect(service.status().usageDevices.map((d) => d.deviceId)).toEqual([newId, otherId])
    expect(service.clientUsageSnapshot().records[0]).toMatchObject({
      deviceId: newId,
      island: { updatedAt: 1 },
    })
  } finally {
    await service.stop()
    await rm(root, { recursive: true, force: true })
  }
})

it.each([oldId, newId])('removes both records when removing device %s', async (id) => {
  const { root, service, dataPath } = await startService(fakeAccount(), usageRecords)
  try {
    await service.removeUsage(id)
    const replica = JSON.parse(
      await readFile(path.join(dataPath, 'state', 'sarto-sync-replica.json'), 'utf8'),
    )
    expect(Object.keys(replica.usageRecords)).toEqual([otherId])
  } finally {
    await service.stop()
    await rm(root, { recursive: true, force: true })
  }
})

it('retries a partial server deletion before removing local records', async () => {
  const requests: string[] = []
  const serverRecords = new Set(Object.keys(usageRecords))
  const { root, service } = await startService(fakeAccount(), usageRecords, async (url, init) => {
    if (init.method !== 'DELETE') return new Response(null, { status: 503 })
    const key = new URL(url).pathname.split('/').pop()!
    requests.push(key)
    if (requests.length === 2) return new Response(null, { status: 503 })
    return new Response(null, { status: serverRecords.delete(key) ? 204 : 404 })
  })
  try {
    await expect(service.removeUsage(newId)).rejects.toThrow('503')
    expect(service.status().usageDevices.map((d) => d.deviceId)).toContain(newId)
    await service.removeUsage(newId)
    expect(requests).toEqual([oldId, newId, oldId, newId])
    expect([...serverRecords]).toEqual([otherId])
    expect(service.status().usageDevices.map((d) => d.deviceId)).toEqual([otherId])
  } finally {
    await service.stop()
    await rm(root, { recursive: true, force: true })
  }
})
