// End-to-end tests for Keybag v2 (device approval + recovery key), Keychain-sealed local secrets,
// per-Mac gzipped `usage` records (`island` + `host`), and `UsageDb`/`UsageManager` `'all'` scope
// multi-Mac aggregation without double-counting.

import { randomBytes } from 'node:crypto'
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'
import { duplexPair } from 'node:stream'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { AgentOptionsStore, type AgentOptionsFile } from '../../agent-host/agent-options'
import { skillFolder } from '../../agent-host/marketplace/skills'
import type { JsonFile } from '../../agent-host/storage'
import { formatEntry } from '../../agent-host/memory/entry-file'
import { QUARTER_MS, UsageDb } from '../../agent-host/usage/db'
import { UsageManager } from '../../agent-host/usage/manager'
import type { LogReader } from '../../agent-host/usage/model'
import { startUsageService } from '../../agent-host/usage/service'
import { UsageStore, type UsageWorker } from '../../agent-host/usage/store'
import type { HostEvent, HostParams } from '@shared/agent-host'
import { deviceId } from '@shared/remote/device'
import type { AgentId } from '@shared/thread'
import { createLogger } from '../../core/log'
import { MarketKeys, marketKeysFile } from '../../core/market-keys'
import type { IdentityCipher } from '../../core/remote-identity'
import { SettingsStore } from '../../core/settings'
import { ThemeStore, readThemeFolder } from '../../core/themes'
import { openItemJson, openScopeJson, sealScopeJson } from '@shared/sync/crypto'
import {
  SYNC_SCOPES,
  type SyncScope,
  type SyncedHostUsageSection,
  type SyncedUsageSelf,
} from '@shared/sync/protocol'
import { NO_SYSTEM_ENCRYPTION } from '../key'
import { createKeychainCipher, type KeychainBackend } from '../keychain'
import { loadSyncDeviceKey } from './device-key'
import {
  SartoSyncService,
  type SyncAccountLink,
  type SyncAgentHost,
  type SyncSocketLike,
} from './service'
import {
  CLOUD_SOURCE,
  loadCloud,
  type PrismRelayServer,
  type SartoSyncStore,
} from '../testing/cloud'
import { approveMac } from '../testing/sync-server'

const cloud = await loadCloud()

function createDuplexFetch(
  server: PrismRelayServer,
): (url: string, init?: RequestInit) => Promise<Response> {
  return async (url, init) => {
    const parsed = new URL(url)
    const [clientStream, serverStream] = duplexPair()
    server.httpServer.emit('connection', serverStream)

    return new Promise<Response>((resolve, reject) => {
      const req = http.request(
        {
          method: init?.method ?? 'GET',
          path: parsed.pathname + parsed.search,
          headers: {
            host: parsed.host,
            ...(init?.headers as Record<string, string> | undefined),
          },
          createConnection: () => clientStream as never,
        },
        (res) => {
          const chunks: Buffer[] = []
          res.on('data', (c: Buffer) => chunks.push(c))
          res.on('end', () => {
            const buf = Buffer.concat(chunks)
            const status = res.statusCode ?? 200
            const bodyAllowed = status !== 204 && status !== 304 && init?.method !== 'HEAD'
            resolve(
              new Response(bodyAllowed ? buf : null, {
                status,
                headers: res.headers as Record<string, string>,
              }),
            )
          })
          res.on('error', reject)
        },
      )
      req.on('error', reject)
      if (init?.body) {
        if (typeof init.body === 'string' || Buffer.isBuffer(init.body)) {
          req.write(init.body)
        } else if (init.body instanceof Uint8Array) {
          req.write(Buffer.from(init.body))
        }
      }
      req.end()
    })
  }
}

function noopSocket(): SyncSocketLike {
  return {
    send() {},
    close() {},
    addEventListener() {},
  }
}

/** A Mac's remote host as the sync sees it: its paired devices and when each was added. */
function fakeHost() {
  const paired = new Map<string, number>()
  return {
    paired,
    addTrustedDevice: async (device: { publicKey: string }) => {
      paired.set(await deviceId(Buffer.from(device.publicKey, 'base64')), Date.now())
    },
    knownDeviceIds: () => new Set(paired.keys()),
    pairedDevices: () => [...paired].map(([id, addedAt]) => ({ id, addedAt })),
    removeTrustedDevice: async (id: string) => {
      paired.delete(id)
    },
  }
}

/**
 * An agent host as the sync reaches it, its requests answered by the host's own stores, and their
 * errors as a port gives them.
 */
function fakeAgentHost() {
  const listeners = new Set<(event: HostEvent | null) => void>()
  const emit = (event: HostEvent): void => {
    for (const listener of listeners) listener(event)
  }
  const file = {
    load: async () => ({ version: 1, agents: {} }),
    save: () => {},
    flush: async () => {},
  } as unknown as JsonFile<AgentOptionsFile>
  const options = new AgentOptionsStore({
    file,
    changed: (changed) => emit({ type: 'agent.options', options: changed }),
  })
  const answer = async (method: string, params: unknown): Promise<unknown> => {
    switch (method) {
      case 'agents.options':
        return options.list()
      case 'agents.pinModel': {
        const { agentId, model, pinned } = params as HostParams<'agents.pinModel'>
        options.pin(agentId, model, pinned)
        return undefined
      }
    }
    throw new Error(`The fake host has no ${method}`)
  }
  const link: SyncAgentHost = {
    request: async (method, params) => (await answer(method, params)) as never,
    onEvent: (listener) => {
      listeners.add(listener)
      return () => listeners.delete(listener)
    },
  }
  /** The agent's first session reported its models, so it keeps options pins can go in. */
  const offers = (agentId: AgentId, models: string[]): void => {
    options.started(agentId, [
      {
        id: 'model',
        name: 'Model',
        category: 'model',
        type: 'select',
        value: models[0]!,
        choices: models.map((value) => ({ value, name: value })),
      },
    ])
  }
  return { link, options, offers }
}

/** The device key an app publishes for reaching the account's other hosts. */
async function appDevice(name: string) {
  const publicKey = randomBytes(32)
  return {
    id: await deviceId(publicKey),
    publicKey: publicKey.toString('base64'),
    name,
    kind: 'desktop',
    platform: 'macOS',
  }
}

/** A stream socket the test speaks for the server through `deliver`. */
function scriptedSocket(): SyncSocketLike & { deliver(message: unknown): void } {
  const listeners: Array<(event: { data?: unknown }) => void> = []
  return {
    send() {},
    close() {},
    addEventListener(type, listener) {
      if (type === 'message') listeners.push(listener)
    },
    deliver(message) {
      for (const listener of listeners) listener({ data: JSON.stringify(message) })
    },
  }
}

function memoryKeychain(): KeychainBackend {
  const map = new Map<string, string>()
  return {
    async read(s, a) {
      const v = map.get(`${s}\0${a}`)
      return v ? { kind: 'found', secret: v } : { kind: 'missing' }
    },
    async write(s, a, secret) {
      map.set(`${s}\0${a}`, secret)
      return true
    },
  }
}

function inlineUsageWorker(dbFile: string, readers: readonly LogReader[] = []): UsageWorker {
  const listeners: Array<(reply: unknown) => void> = []
  let handle: ((req: unknown) => void) | null = null
  const emit = (reply: unknown): void => {
    for (const listener of listeners) listener(reply)
  }
  queueMicrotask(() => {
    handle = startUsageService(dbFile, readers, emit) as (req: unknown) => void
  })
  return {
    postMessage(request) {
      queueMicrotask(() => handle?.(request))
    },
    onMessage(listener) {
      listeners.push(listener as (reply: unknown) => void)
    },
    onExit() {},
    async terminate() {},
  }
}

async function createMacNode(
  label: string,
  options: {
    origin: string
    fetchImpl: (url: string, init?: RequestInit) => Promise<Response>
    account?: SyncAccountLink
    cipher?: IdentityCipher
    usageDeviceId?: string
    exportHostUsage?: () => Promise<SyncedHostUsageSection | null>
    onRemoteUsageChanged?: (
      remote: Record<string, SyncedHostUsageSection>,
      self?: SyncedUsageSelf,
    ) => void
    openSocket?: (url: string) => SyncSocketLike
    setupPollMs?: number
    host?: ReturnType<typeof fakeHost>
    /** The settings file the Mac starts with, for what no settings call sets. */
    settingsFile?: Record<string, unknown>
    watchDebounceMs?: number
    agentHost?: SyncAgentHost
  },
) {
  const root = await mkdtemp(path.join(os.tmpdir(), `sarto-v2-${label}-`))
  const dataPath = path.join(root, 'data')
  const homeDir = path.join(root, 'home')
  await mkdir(dataPath, { recursive: true })
  await mkdir(homeDir, { recursive: true })
  if (options.settingsFile) {
    await writeFile(path.join(dataPath, 'settings.json'), JSON.stringify(options.settingsFile))
  }

  const cipher =
    options.cipher ??
    (await createKeychainCipher(dataPath, {
      platform: 'darwin',
      env: {},
      backend: memoryKeychain(),
    }))
  const settings = await SettingsStore.load(dataPath)
  const marketKeys = await MarketKeys.load({
    file: marketKeysFile(dataPath),
    cipher,
    plainTextAllowed: true,
    servers: () => settings.get().marketplace.mcp,
    changed: () => {},
    log: createLogger(`keys-${label}`),
  })
  const themesDir = path.join(dataPath, 'themes')
  const themes = new ThemeStore(await readThemeFolder(themesDir), 'sarto', {
    dir: themesDir,
    select: () => {},
    changed: () => {},
  })
  const hostPub = randomBytes(32).toString('base64')
  const relaySeedBase64 = randomBytes(32).toString('base64')
  const service = await SartoSyncService.start({
    dataPath,
    homeDir,
    cipher,
    ...(options.account ? { account: options.account } : {}),
    ...(options.usageDeviceId ? { usageDeviceId: options.usageDeviceId } : {}),
    settings,
    marketKeys,
    themes,
    relaySeedBase64,
    hostPublicKey: () => hostPub,
    hostName: () => label,
    configureRelay: () => {},
    addTrustedDevice: options.host?.addTrustedDevice ?? (async () => {}),
    knownDeviceIds: options.host?.knownDeviceIds ?? (() => new Set()),
    ...(options.host
      ? {
          pairedDevices: options.host.pairedDevices,
          removeTrustedDevice: options.host.removeTrustedDevice,
        }
      : {}),
    reloadMemory: () => {},
    ...(options.exportHostUsage ? { exportHostUsage: options.exportHostUsage } : {}),
    ...(options.onRemoteUsageChanged ? { onRemoteUsageChanged: options.onRemoteUsageChanged } : {}),
    fetchImpl: options.fetchImpl,
    openSocket: options.openSocket ?? noopSocket,
    ...(options.setupPollMs ? { setupPollMs: options.setupPollMs } : {}),
    ...(options.watchDebounceMs ? { watchDebounceMs: options.watchDebounceMs } : {}),
    ...(options.agentHost ? { agentHost: options.agentHost } : {}),
    log: createLogger(`sync-${label}`),
  })

  return {
    root,
    dataPath,
    homeDir,
    cipher,
    settings,
    marketKeys,
    themes,
    service,
    relaySeedBase64,
    async cleanup() {
      await service.stop()
      await settings.flush()
      await marketKeys.flush()
      await rm(root, { recursive: true, force: true })
    },
  }
}

describe.skipIf(!CLOUD_SOURCE)(
  'Sarto Sync v2: Keybag v2, Keychain, Approval, Recovery, Migration & Usage',
  () => {
    const cleanups: Array<() => Promise<void>> = []

    afterEach(async () => {
      while (cleanups.length > 0) {
        await cleanups.pop()!()
      }
    })

    it('runs Keybag v2 setup, Keychain local encryption, SAS device approval, and recovery unlock', async () => {
      const auth = new cloud.AuthService({
        secret: 'sarto-v2-flows-secret-32-bytes-minimum!!',
        dataFile: null,
        allowRegistration: true,
      })
      const created = await auth.createPasswordAccount('alice@sarto.dev', 'password-1234', 'Alice')
      if (!created.ok) throw new Error(created.error)
      const account = created.account
      const oauthStore = new cloud.OAuthStore(null)
      const syncStore = new cloud.SartoSyncStore()
      const origin = 'http://127.0.0.1:18787'
      const oauth = new cloud.OAuthService({
        auth,
        store: oauthStore,
        publicOrigin: origin,
        allowRegistration: false,
      })
      const server = new cloud.PrismRelayServer({
        publicOrigin: origin,
        regionId: 't',
        auth,
        oauth,
        syncStore,
      })
      const fetchImpl = createDuplexFetch(server)
      cleanups.push(async () => {
        await server.close()
        syncStore.close()
      })

      const makeAccountLink = (name: string): SyncAccountLink => {
        const fam = oauthStore.createFamily({
          accountId: account.id,
          clientId: 'sarto-mac',
          clientInfo: JSON.stringify({
            kind: 'desktop',
            name,
            os: 'macOS',
            arch: 'arm64',
            version: '1',
          }),
          now: Date.now(),
        })
        const tok = auth.issueToken(account, 'access', { ttlMs: 15 * 60_000, family: fam.id }).token
        return {
          origin: () => origin,
          profile: () => ({ id: account.id, email: account.email, name: account.name }),
          token: async () => tok,
          signOut: async () => {},
        }
      }

      // 1. Mac A signs in -> needs-setup -> setupVault() returns 128-bit recoveryKey.
      const macA = await createMacNode('Mac Studio', {
        origin,
        fetchImpl,
        account: makeAccountLink('Mac Studio'),
        usageDeviceId: 'aaaa000011112222',
      })
      cleanups.push(() => macA.cleanup())

      const mcpId = 'manual:11111111-1111-4111-8111-111111111111'
      macA.settings.update({
        general: { sessionTitles: false },
        marketplace: {
          mcp: [
            {
              id: mcpId,
              name: 'linear',
              title: 'Linear',
              source: 'manual',
              version: null,
              on: true,
              agents: 'all',
              spec: {
                type: 'http',
                transport: 'streamable-http',
                url: 'https://mcp.linear.app/mcp',
                headers: [{ name: 'Authorization', input: true, secret: true, required: true }],
              },
            },
          ],
          skills: [],
        },
      })
      await macA.marketKeys.set({
        serverId: mcpId,
        values: { Authorization: 'lin_api_top_secret_42' },
      })

      await macA.service.accountChanged()
      expect(macA.service.status().keyState).toBe('needs-setup')
      expect(macA.service.status().needsKey).toBe(true)
      expect(macA.service.status().plainText).toBe(false)

      const { status: setupStatus, recoveryKey } = await macA.service.setupVault()
      expect(setupStatus.keyState).toBe('ready')
      expect(setupStatus.needsKey).toBe(false)
      expect(setupStatus.relayToken).toBeNull()
      expect(recoveryKey).toMatch(/^[0-9A-HJKMNP-TV-Z]{4}(-[0-9A-HJKMNP-TV-Z]{4}){6}$/)

      // Verify local disk files have NO plaintext SMK and NO plaintext MCP vault secret!
      const cfgOnDisk = await readFile(path.join(macA.dataPath, 'sarto-sync.json'), 'utf8')
      expect(JSON.parse(cfgOnDisk)).toMatchObject({
        mode: 'account',
        accessToken: null,
        relayToken: null,
        masterKeyBase64: null,
        plainText: false,
      })
      expect(JSON.parse(cfgOnDisk).masterKeyEncrypted).toBeTruthy()
      const replicaOnDisk = await readFile(
        path.join(macA.dataPath, 'state', 'sarto-sync-replica.json'),
        'utf8',
      )
      expect(replicaOnDisk).not.toContain('lin_api_top_secret_42')
      expect(JSON.parse(replicaOnDisk).mcpVaultEncrypted).toBeTruthy()
      // Server also stores ONLY ciphertext.
      expect(JSON.stringify(syncStore.getScope(account.id, 'mcp-vault'))).not.toContain(
        'lin_api_top_secret_42',
      )

      // Mac A publishes island usage.
      await macA.service.putUsage({
        updatedAt: 1_700_000_100_000,
        island: { schema: 1, quotas: { claude: { remaining: 82 } } },
      })
      await macA.service.syncNow()

      // 2. Mac B signs in -> awaiting-approval, waiting for a Mac to answer its request.
      const macB = await createMacNode('MacBook Air', {
        origin,
        fetchImpl,
        account: makeAccountLink('MacBook Air'),
        usageDeviceId: 'bbbb000033334444',
      })
      cleanups.push(() => macB.cleanup())
      await macB.service.accountChanged()
      const statusBWait = macB.service.status()
      expect(statusBWait.keyState).toBe('awaiting-approval')
      expect(statusBWait.needsKey).toBe(true)
      expect(statusBWait.approvalStage).toBe('waiting')

      // Mac A answers, Mac B reveals, and both show the same code.
      await macA.service.syncNow()
      await macB.service.syncNow()
      await macA.service.syncNow()
      const codeOnB = macB.service.status().approvalCode
      expect(codeOnB).toMatch(/^[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$/)
      const pendingOnA = macA.service.status().pendingApprovals
      expect(pendingOnA).toHaveLength(1)
      expect(pendingOnA[0]?.deviceId).toBe(statusBWait.syncDeviceId)
      expect(pendingOnA[0]?.code).toBe(codeOnB)

      // Mac A approves Mac B, the user confirms the code on Mac B, and Mac B receives the secrets.
      await macA.service.approveDevice(statusBWait.syncDeviceId!)
      expect(macA.service.status().pendingApprovals).toHaveLength(0)
      await macB.service.confirmApproval(true)

      await macB.service.syncNow()
      expect(macB.service.status().keyState).toBe('ready')
      expect(macB.settings.get().general.sessionTitles).toBe(false)
      expect(macB.marketKeys.contentsForHost().values[mcpId]?.Authorization).toBe(
        'lin_api_top_secret_42',
      )
      const usageOnB = macB.service.usageSnapshot()
      expect(
        usageOnB.records.find((r) => r.deviceId === 'aaaa000011112222')?.island?.payload,
      ).toEqual({
        schema: 1,
        quotas: { claude: { remaining: 82 } },
      })

      // 3. Lost-Mac recovery: brand-new Mac C unlocks with the 128-bit recoveryKey alone.
      const macC = await createMacNode('Mac Mini', {
        origin,
        fetchImpl,
        account: makeAccountLink('Mac Mini'),
        usageDeviceId: 'cccc000055556666',
      })
      cleanups.push(() => macC.cleanup())
      await macC.service.accountChanged()
      expect(macC.service.status().keyState).toBe('awaiting-approval')

      await expect(
        macC.service.unlockWithRecoveryKey('0000-0000-0000-0000-0000-0000-0000'),
      ).rejects.toThrow(/Invalid recovery key/)
      const recoveredStatus = await macC.service.unlockWithRecoveryKey(recoveryKey!)
      expect(recoveredStatus.keyState).toBe('ready')
      expect(macC.marketKeys.contentsForHost().values[mcpId]?.Authorization).toBe(
        'lin_api_top_secret_42',
      )
      // Mac C's device wrap is now persisted on the server keybag.
      const kb = syncStore.getKeybag(account.id)
      expect(kb?.v).toBe(2)
      if (kb?.v === 2) {
        expect(kb.devices.some((d) => d.deviceId === macC.service.status().syncDeviceId)).toBe(true)
      }
    })

    it('syncs per-Mac gzipped host & island usage and sums "all" scope without double-counting', async () => {
      const auth = new cloud.AuthService({
        secret: 'sarto-v2-usage-test-secret-32-bytes!!',
        dataFile: null,
        allowRegistration: true,
      })
      const created = await auth.createPasswordAccount('usage@sarto.dev', 'password-1234', 'Usage')
      if (!created.ok) throw new Error(created.error)
      const account = created.account
      const syncStore = new cloud.SartoSyncStore()
      const origin = 'http://127.0.0.1:18790'
      const server = new cloud.PrismRelayServer({
        publicOrigin: origin,
        regionId: 't',
        auth,
        syncStore,
      })
      const fetchImpl = createDuplexFetch(server)
      cleanups.push(async () => {
        await server.close()
        syncStore.close()
      })

      const tok = auth.issueToken(account, 'access').token
      const link: SyncAccountLink = {
        origin: () => origin,
        profile: () => ({ id: account.id, email: account.email, name: account.name }),
        token: async () => tok,
        signOut: async () => {},
      }

      // Create two real UsageDb + UsageManager instances (Mac A and Mac B).
      const tmpA = await mkdtemp(path.join(os.tmpdir(), 'sarto-usage-a-'))
      const tmpB = await mkdtemp(path.join(os.tmpdir(), 'sarto-usage-b-'))
      const recentBase = Date.now() - 2 * 24 * 60 * 60 * 1000
      const dayStart = recentBase - (recentBase % (24 * 60 * 60 * 1000))
      const q1At = dayStart + QUARTER_MS * 4
      const staleAt = dayStart - 400 * 24 * 60 * 60 * 1000

      const quotaAt = Date.now() - 60_000
      const readersA: LogReader[] = [
        {
          agentId: 'claude-code',
          locations: () => [],
          scan: async () => true,
          quota: async (context) => {
            context.quota({
              agentId: 'claude-code',
              account: 'efe658764602f1ff',
              plan: 'Max 20×',
              windows: [
                {
                  id: 'five_hour',
                  kind: 'session',
                  scope: null,
                  minutes: 300,
                  usedPercent: 42,
                  resetsAt: quotaAt + 3_600_000,
                  observedAt: quotaAt,
                },
              ],
              observedAt: quotaAt,
            })
          },
        },
      ]
      const storeA = new UsageStore({
        file: path.join(tmpA, 'usage.db'),
        createWorker: (file) => inlineUsageWorker(file, readersA),
        log: () => {},
        onChanged: () => {},
        onProgress: () => {},
        onStatus: () => {},
      })
      const mgrA = new UsageManager({
        store: storeA,
        readers: readersA,
        fromComputer: true,
        platform: 'darwin',
        home: tmpA,
        env: async () => ({}),
        isScratch: () => false,
        log: () => {},
        changed: () => {},
        status: () => {},
        timings: { firstScanMs: 60_000, intervalMs: 60_000 },
      })
      // Mac A has BOTH `log` (1000 input) and `sarto` (500 input) for claude-code (overlap!),
      // plus `sarto` (300 input) for codex. Because `fromComputer: true` and claude-code has `log`,
      // only `log` (1000) should count for Mac A's claude-code — NEVER 1500!
      await storeA.write([
        {
          key: 'log:a:1',
          source: 'log',
          agentId: 'claude-code',
          sessionId: 's1',
          project: '/Users/alice/app',
          model: 'claude-sonnet-4-5',
          at: q1At,
          input: 1000,
          output: 200,
          reasoning: null,
          cacheRead: 0,
          cacheWrite: 0,
          cacheWrite1h: 0,
          turn: 0,
        },
        {
          key: 'sarto:a:1',
          source: 'sarto',
          agentId: 'claude-code',
          sessionId: 's1',
          project: '/Users/alice/app',
          model: 'claude-sonnet-4-5',
          at: q1At,
          input: 500,
          output: 100,
          reasoning: null,
          cacheRead: 0,
          cacheWrite: 0,
          cacheWrite1h: 0,
          turn: 1,
        },
        {
          key: 'sarto:a:2',
          source: 'sarto',
          agentId: 'codex',
          sessionId: 's2',
          project: '/Users/alice/app',
          model: 'gpt-5',
          at: q1At,
          input: 300,
          output: 50,
          reasoning: 10,
          cacheRead: 0,
          cacheWrite: 0,
          cacheWrite1h: 0,
          turn: 1,
        },
        {
          key: 'sarto:a:old',
          source: 'sarto',
          agentId: 'codex',
          sessionId: 's-old',
          project: '/Users/alice/app',
          model: 'gpt-5',
          at: staleAt,
          input: 9999,
          output: 100,
          reasoning: 0,
          cacheRead: 0,
          cacheWrite: 0,
          cacheWrite1h: 0,
          turn: 1,
        },
      ])
      mgrA.start()
      await storeA.ready
      await mgrA.sync()
      await mgrA.refreshQuotas()

      const storeB = new UsageStore({
        file: path.join(tmpB, 'usage.db'),
        createWorker: inlineUsageWorker,
        log: () => {},
        onChanged: () => {},
        onProgress: () => {},
        onStatus: () => {},
      })
      const mgrB = new UsageManager({
        store: storeB,
        readers: [],
        fromComputer: false,
        platform: 'darwin',
        home: tmpB,
        env: async () => ({}),
        isScratch: () => false,
        log: () => {},
        changed: () => {},
        status: () => {},
        timings: { firstScanMs: 60_000, intervalMs: 60_000 },
      })
      // Mac B has `sarto` (400 input) for claude-code.
      await storeB.write([
        {
          key: 'sarto:b:1',
          source: 'sarto',
          agentId: 'claude-code',
          sessionId: 'sb1',
          project: '/Users/alice/app',
          model: 'claude-sonnet-4-5',
          at: q1At,
          input: 400,
          output: 80,
          reasoning: null,
          cacheRead: 0,
          cacheWrite: 0,
          cacheWrite1h: 0,
          turn: 1,
        },
      ])
      mgrB.start()
      await storeB.ready

      let remoteDeliveredToB: Promise<void> = Promise.resolve()
      let remoteOnB: Record<string, SyncedHostUsageSection> = {}
      const macA = await createMacNode('Mac A', {
        origin,
        fetchImpl,
        account: link,
        usageDeviceId: '1111222233334444',
        // A field a newer daemon may add, which every Mac must pass on as it is.
        exportHostUsage: async () => {
          const usage = await mgrA.exportHostUsage()
          return usage && ({ ...usage, futureField: 'kept' } as SyncedHostUsageSection)
        },
      })
      const macB = await createMacNode('Mac B', {
        origin,
        fetchImpl,
        account: link,
        usageDeviceId: '5555666677778888',
        exportHostUsage: () => mgrB.exportHostUsage(),
        onRemoteUsageChanged: (remote, self) => {
          remoteOnB = remote
          remoteDeliveredToB = mgrB.setRemoteUsage(remote, self)
        },
      })
      cleanups.push(async () => {
        await macA.service.stop()
        await macB.service.stop()
        await mgrA.close()
        await mgrB.close()
        await macA.settings.flush()
        await macA.marketKeys.flush()
        await macB.settings.flush()
        await macB.marketKeys.flush()
        await rm(macA.root, { recursive: true, force: true })
        await rm(macB.root, { recursive: true, force: true })
        await rm(tmpA, { recursive: true, force: true })
        await rm(tmpB, { recursive: true, force: true })
      })

      // Setup vault on Mac A, sync host + island usage.
      await macA.service.accountChanged()
      const { recoveryKey } = await macA.service.setupVault()
      await macA.service.putUsage({
        updatedAt: 1_760_000_050_000,
        island: { schema: 1, device: { id: '1111222233334444', name: 'Mac A' } },
      })
      await macA.service.syncNow()

      // Verify server stored gzip-compressed ciphertext and ZERO plaintext model names!
      const storedItem = syncStore.getScopeItem(account.id, 'usage', '1111222233334444')
      expect(storedItem?.envelope.encoding).toBe('gzip')
      expect(JSON.stringify(storedItem)).not.toContain('claude-sonnet-4-5')

      // Mac B joins via recoveryKey and receives Mac A's host usage into UsageDb.remote_buckets!
      await macB.service.accountChanged()
      await macB.service.unlockWithRecoveryKey(recoveryKey!)
      await remoteDeliveredToB

      const dayEnds = [dayStart, dayStart + 24 * 60 * 60 * 1000]
      const localSummary = await mgrB.summary(dayEnds, dayEnds[0]!, dayEnds[1]!, 'computer')
      expect(localSummary.models).toHaveLength(1)
      expect(localSummary.models[0]?.input).toBe(400)

      // `'all'` scope sums Mac B (400) + Mac A's effective claude-code log (1000, NOT +500 sarto!) + Mac A's codex (300).
      const allSummary = await mgrB.summary(dayEnds, dayEnds[0]!, dayEnds[1]!, 'all')
      const claudeModel = allSummary.models.find(
        (m) => m.agentId === 'claude-code' && m.model === 'claude-sonnet-4-5',
      )
      const codexModel = allSummary.models.find((m) => m.agentId === 'codex' && m.model === 'gpt-5')
      expect(claudeModel?.input).toBe(1400)
      expect(claudeModel?.output).toBe(280)
      expect(codexModel?.input).toBe(300)
      expect(allSummary.agents).toEqual(['claude-code', 'codex'])

      // Mac A's quotas, their measurements and its latest requests reach Mac B with its name, and
      // the record keeps a field Mac B does not know.
      const fromA = remoteOnB['1111222233334444']
      expect(fromA?.deviceName).toBe('Mac A')
      expect(fromA?.quotas?.map((q) => [q.agentId, q.account])).toEqual([
        ['claude-code', 'efe658764602f1ff'],
      ])
      expect(fromA?.quotaHistory?.[0]?.samples).toEqual([
        { at: quotaAt, usedPercent: 42, resetsAt: quotaAt + 3_600_000 },
      ])
      expect(fromA?.activity?.map((a) => a.agentId).sort()).toEqual(['claude-code', 'codex'])
      expect(
        (
          macB.service.usageSnapshot().records.find((r) => r.deviceId === '1111222233334444')
            ?.host as unknown as Record<string, unknown>
        ).futureField,
      ).toBe('kept')
      // Mac B, signed in to no Claude account of its own, shows Mac A's in the `all` scope.
      const overview = await mgrB.overview('all')
      const claude = overview.agents.find((a) => a.agentId === 'claude-code')
      expect(claude?.quota).toMatchObject({
        account: 'efe658764602f1ff',
        plan: 'Max 20×',
        device: { id: '1111222233334444', name: 'Mac A' },
      })
      expect(claude?.quota?.windows[0]?.forecast.status.kind).not.toBe('insufficient')
      expect(overview.devices.map((d) => [d.name, d.thisComputer])).toEqual([
        ['Mac B', true],
        ['Mac A', false],
      ])
      expect((await mgrB.overview('computer')).agents[0]?.quota).toBeNull()

      // Test `ifOlderOnly` import safety: older timestamp for Mac A does not overwrite newer island record.
      await macB.service.putUsage({
        deviceId: '1111222233334444',
        updatedAt: 1_760_000_010_000,
        island: { stale: true },
        ifOlderOnly: true,
      })
      expect(
        macB.service.usageSnapshot().records.find((r) => r.deviceId === '1111222233334444')?.island
          ?.payload,
      ).not.toEqual({ stale: true })

      // Verify UsageDb schema v2 -> v3 upgrade, 365-day export cap, and idempotent remote upsert.
      const exportedA = await mgrA.exportHostUsage()
      expect(
        exportedA?.buckets.every((b) => b.quarter * QUARTER_MS >= staleAt + 24 * 60 * 60 * 1000),
      ).toBe(true)

      const dbDir = await mkdtemp(path.join(os.tmpdir(), 'sarto-usage-upgrade-'))
      cleanups.push(() => rm(dbDir, { recursive: true, force: true }))
      const db = UsageDb.open(path.join(dbDir, 'usage.db'), () => {})
      expect(db.open).toBe(true)
      const dupBucket = {
        quarter: Math.floor(q1At / QUARTER_MS),
        source: 'sarto' as const,
        agentId: 'codex' as const,
        model: 'gpt-5',
        project: '/p',
        rows: 1,
        input: 123,
        output: 45,
        reasoning: 0,
        cacheRead: 0,
        cacheWrite: 0,
        cacheWrite1h: 0,
        turns: 1,
      }
      db.setRemoteUsage({
        mac_dup: {
          updatedAt: Date.now(),
          fromComputer: false,
          computerSources: { codex: 'sarto' },
          buckets: [dupBucket, dupBucket],
        },
      })
      const dupSummary = db.summary(
        dayEnds,
        dayEnds[0]!,
        dayEnds[1]!,
        { codex: 'sarto' },
        undefined,
        true,
      )
      expect(dupSummary.models.find((m) => m.agentId === 'codex')?.input).toBe(123)
      db.close()
    })

    it('survives locked Keychain startup without crashing and handles remote wrap removal', async () => {
      const auth = new cloud.AuthService({
        secret: 'v2-flows-lock-secret-32-bytes!!!!',
        dataFile: null,
        allowRegistration: true,
      })
      const created = await auth.createPasswordAccount('lock@sarto.dev', 'password-1234', 'Lock')
      expect(created.ok).toBe(true)
      const account = created.ok
        ? created.account
        : (() => {
            throw new Error('bad')
          })()
      const syncStore = new cloud.SartoSyncStore()
      const origin = 'http://127.0.0.1:19895'
      const server = new cloud.PrismRelayServer({
        publicOrigin: origin,
        regionId: 't',
        auth,
        syncStore,
      })
      const fetchImpl = createDuplexFetch(server)
      cleanups.push(async () => {
        await server.close()
        syncStore.close()
      })

      const tok = auth.issueToken(account, 'access').token
      const link: SyncAccountLink = {
        origin: () => origin,
        profile: () => ({ id: account.id, email: account.email, name: account.name }),
        token: async () => tok,
        signOut: async () => {},
      }

      // 1. Start Mac A with Keychain cipher available -> saves encrypted sync-device-key.json.
      const backend = memoryKeychain()
      const macA = await createMacNode('Mac A', {
        origin,
        fetchImpl,
        account: link,
        cipher: await createKeychainCipher(path.join(os.tmpdir(), 'sarto-lock-shared'), {
          platform: 'darwin',
          env: {},
          backend,
        }),
      })
      await macA.service.accountChanged()
      await macA.service.setupVault()
      expect(macA.service.status().keyState).toBe('ready')
      await macA.service.stop()

      // 2. Restart with the SAME data folder while Keychain is locked (cipher unavailable):
      //    SartoSyncService.start() must NOT throw and must surface a clear Keychain-locked error.
      const lockedSvc = await SartoSyncService.start({
        dataPath: macA.dataPath,
        cipher: NO_SYSTEM_ENCRYPTION,
        account: link,
        settings: macA.settings,
        marketKeys: macA.marketKeys,
        themes: macA.themes,
        relaySeedBase64: null,
        hostPublicKey: () => null,
        hostName: () => 'Mac A',
        configureRelay: () => {},
        addTrustedDevice: async () => {},
        knownDeviceIds: () => new Set(),
        reloadMemory: () => {},
        fetchImpl,
        openSocket: () => noopSocket(),
        log: createLogger('test-locked'),
      })
      cleanups.push(async () => {
        await lockedSvc.stop()
        await macA.settings.flush()
        await macA.marketKeys.flush()
        await rm(macA.root, { recursive: true, force: true })
      })
      expect(lockedSvc.status().error).toMatch(/Keychain/i)
      expect(lockedSvc.isConfigured()).toBe(false)

      // 3. Remote removal of Mac A's keybag wrap drops a ready Mac back to awaiting-approval on reconcile.
      const reopened = await SartoSyncService.start({
        dataPath: macA.dataPath,
        cipher: macA.cipher,
        account: link,
        settings: macA.settings,
        marketKeys: macA.marketKeys,
        themes: macA.themes,
        relaySeedBase64: null,
        hostPublicKey: () => null,
        hostName: () => 'Mac A',
        configureRelay: () => {},
        addTrustedDevice: async () => {},
        knownDeviceIds: () => new Set(),
        reloadMemory: () => {},
        fetchImpl,
        openSocket: () => noopSocket(),
        log: createLogger('test-reopen'),
      })
      cleanups.push(async () => {
        await reopened.stop()
      })
      expect(reopened.status().keyState).toBe('ready')
      const devId = reopened.status().syncDeviceId!
      syncStore.removeKeybagDevice(account.id, devId)
      await reopened.syncNow()
      expect(reopened.status().keyState).toBe('awaiting-approval')
      expect(reopened.isConfigured()).toBe(false)
    })

    it('refreshes oauthDeviceId seamlessly when a ready Mac signs out and signs back in with a new OAuth family', async () => {
      const auth = new cloud.AuthService({
        secret: 'v2-flows-relogin-secret-32-bytes!!',
        dataFile: null,
        allowRegistration: true,
      })
      const created = await auth.createPasswordAccount('relogin@sarto.dev', 'password-1234', 'Re')
      if (!created.ok) throw new Error(created.error)
      const account = created.account
      const oauthStore = new cloud.OAuthStore(null)
      const syncStore = new cloud.SartoSyncStore()
      const origin = 'http://127.0.0.1:19896'
      const oauth = new cloud.OAuthService({
        auth,
        store: oauthStore,
        publicOrigin: origin,
        allowRegistration: false,
      })
      const server = new cloud.PrismRelayServer({
        publicOrigin: origin,
        regionId: 't',
        auth,
        oauth,
        syncStore,
      })
      const fetchImpl = createDuplexFetch(server)
      cleanups.push(async () => {
        await server.close()
        syncStore.close()
        oauthStore.close()
      })

      const issueFamilyToken = () => {
        const fam = oauthStore.createFamily({
          accountId: account.id,
          clientId: 'sarto-daemon',
          clientInfo: JSON.stringify({
            kind: 'daemon',
            name: 'Mac Pro',
            os: 'macOS',
            arch: 'arm64',
          }),
          now: Date.now(),
        })
        return {
          familyId: fam.id,
          token: auth.issueToken(account, 'access', { ttlMs: 15 * 60_000, family: fam.id }).token,
        }
      }

      let currentSession: { familyId: string; token: string } | null = issueFamilyToken()
      const link: SyncAccountLink = {
        origin: () => origin,
        profile: () =>
          currentSession ? { id: account.id, email: account.email, name: account.name } : null,
        token: async () => currentSession?.token ?? null,
        signOut: async () => {
          currentSession = null
        },
      }

      const mac = await createMacNode('Mac Pro', { origin, fetchImpl, account: link })
      cleanups.push(() => mac.cleanup())

      await mac.service.accountChanged()
      await mac.service.setupVault()
      expect(mac.service.status().keyState).toBe('ready')

      // Simulate OAuth sign-out (which leaves the vault on the server, or even if old family changed)
      // followed by signing back in with a brand-new OAuth family on the SAME Mac (same X25519 key).
      currentSession = null
      await mac.service.accountChanged()
      expect(mac.service.status().mode).toBe('off')

      const secondFamily = issueFamilyToken()
      currentSession = secondFamily
      await mac.service.accountChanged()
      expect(mac.service.status().keyState).toBe('ready')

      // Pushing scope mutations under the new OAuth family succeeds without 403 device_not_approved!
      mac.settings.update({ general: { sessionTitles: false } })
      await mac.service.syncNow()
      expect(mac.service.status().error).toBeNull()
      expect(syncStore.getScope(account.id, 'host-config')?.rev).toBeGreaterThanOrEqual(1)
    })
    /** A server with one account and a way to sign Macs in to it, as the first test sets up. */
    async function signedInAccount(email: string) {
      const auth = new cloud.AuthService({
        secret: 'sarto-v2-flows-secret-32-bytes-minimum!!',
        dataFile: null,
        allowRegistration: true,
      })
      const created = await auth.createPasswordAccount(email, 'password-1234', 'Bo')
      if (!created.ok) throw new Error(created.error)
      const account = created.account
      const oauthStore = new cloud.OAuthStore(null)
      const syncStore = new cloud.SartoSyncStore()
      const origin = 'http://127.0.0.1:18788'
      const oauth = new cloud.OAuthService({
        auth,
        store: oauthStore,
        publicOrigin: origin,
        allowRegistration: false,
      })
      const server = new cloud.PrismRelayServer({
        publicOrigin: origin,
        regionId: 't',
        auth,
        oauth,
        syncStore,
      })
      const fetchImpl = createDuplexFetch(server)
      cleanups.push(async () => {
        await server.close()
        syncStore.close()
      })
      const mac = async (
        name: string,
        usageDeviceId: string,
        extra: {
          openSocket?: (url: string) => SyncSocketLike
          setupPollMs?: number
          host?: ReturnType<typeof fakeHost>
          settingsFile?: Record<string, unknown>
          watchDebounceMs?: number
          agentHost?: SyncAgentHost
        } = {},
      ) => {
        const fam = oauthStore.createFamily({
          accountId: account.id,
          clientId: 'sarto-mac',
          clientInfo: JSON.stringify({
            kind: 'desktop',
            name,
            os: 'macOS',
            arch: 'arm64',
            version: '1',
          }),
          now: Date.now(),
        })
        const tok = auth.issueToken(account, 'access', { ttlMs: 15 * 60_000, family: fam.id }).token
        const node = await createMacNode(name, {
          origin,
          fetchImpl,
          account: {
            origin: () => origin,
            profile: () => ({ id: account.id, email: account.email, name: account.name }),
            token: async () => tok,
            signOut: async () => {},
          },
          usageDeviceId,
          ...extra,
        })
        cleanups.push(() => node.cleanup())
        return node
      }
      return { mac, syncStore, accountId: account.id }
    }

    it('moves a Mac waiting for setup to approval when another Mac makes the keybag', async () => {
      const { mac } = await signedInAccount('bo@sarto.dev')
      const sockets: Array<ReturnType<typeof scriptedSocket>> = []
      const macB = await mac('MacBook Pro', 'bbbb000077778888', {
        openSocket: () => {
          const socket = scriptedSocket()
          sockets.push(socket)
          return socket
        },
      })
      await macB.service.accountChanged()
      expect(macB.service.status().keyState).toBe('needs-setup')
      // The stream stays open while the account has no keybag yet.
      expect(sockets).toHaveLength(1)

      const macA = await mac('Mac mini', 'aaaa000077778888')
      await macA.service.accountChanged()
      const { recoveryKey } = await macA.service.setupVault()
      expect(recoveryKey).toBeTruthy()

      sockets[0]!.deliver({ type: 'sync.keybag.updated', keyEpoch: 1 })
      await vi.waitFor(() => expect(macB.service.status().keyState).toBe('awaiting-approval'))
      await macA.service.syncNow()
      await macB.service.syncNow()
      const code = macB.service.status().approvalCode
      expect(code).toMatch(/^[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$/)

      await macA.service.syncNow()
      expect(macA.service.status().pendingApprovals.map((p) => p.code)).toEqual([code])
    })

    it("finds another Mac's keybag without the stream, and setting up again asks for approval", async () => {
      const { mac } = await signedInAccount('cy@sarto.dev')
      const polling = await mac('MacBook Air', 'bbbb000099990000', { setupPollMs: 20 })
      const idle = await mac('iMac', 'cccc000099990000')
      await polling.service.accountChanged()
      await idle.service.accountChanged()
      expect(polling.service.status().keyState).toBe('needs-setup')
      expect(idle.service.status().keyState).toBe('needs-setup')

      const first = await mac('Mac Studio', 'aaaa000099990000')
      await first.service.accountChanged()
      await first.service.setupVault()

      await vi.waitFor(() => expect(polling.service.status().keyState).toBe('awaiting-approval'), {
        timeout: 2_000,
      })
      // A Mac that has not looked again yet is sent to approval, not told the vault exists.
      const again = await idle.service.setupVault()
      expect(again.recoveryKey).toBeNull()
      expect(again.status.keyState).toBe('awaiting-approval')
      expect(again.status.approvalStage).toBe('waiting')
    })

    it('unpairs a device from every host once it leaves the keybag, not one paired again later', async () => {
      const { mac } = await signedInAccount('di@sarto.dev')
      const hostA = fakeHost()
      const hostC = fakeHost()
      const macA = await mac('Mac Studio', 'aaaa0000aaaa0000', { host: hostA })
      await macA.service.accountChanged()
      await macA.service.setupVault()

      const join = async (node: Awaited<ReturnType<typeof mac>>) => {
        await node.service.accountChanged()
        await approveMac(macA.service, node.service)
        expect(node.service.status().keyState).toBe('ready')
      }
      const macB = await mac('MacBook Air', 'bbbb0000bbbb0000')
      await join(macB)
      const macC = await mac('iMac', 'cccc0000cccc0000', { host: hostC })
      await join(macC)

      // Mac B's app publishes its key for reaching the other hosts, and they pair it.
      const bApp = await appDevice('MacBook Air')
      await macB.service.pushClientState({ device: bApp })
      await macB.service.syncNow()
      await macA.service.syncNow()
      await macC.service.syncNow()
      expect(hostA.paired.has(bApp.id)).toBe(true)
      expect(hostC.paired.has(bApp.id)).toBe(true)

      await new Promise((resolve) => setTimeout(resolve, 5))
      await macA.service.removeDeviceWrap(macB.service.status().syncDeviceId!)
      await macA.service.syncNow()
      expect(hostA.paired.has(bApp.id)).toBe(false)
      // Another Mac unpairs it on its next sync, whether or not it saw the removal live.
      await macC.service.syncNow()
      expect(hostC.paired.has(bApp.id)).toBe(false)

      // Paired again after the removal, as with a pairing code: the tombstone leaves it be.
      hostA.paired.set(bApp.id, Date.now() + 1_000)
      await macA.service.syncNow()
      expect(hostA.paired.has(bApp.id)).toBe(true)
    })

    it("unpairs an app's old key from every host once it publishes a new one", async () => {
      const { mac } = await signedInAccount('ke@sarto.dev')
      const hostA = fakeHost()
      const hostB = fakeHost()
      const macA = await mac('Mac Studio', 'aaaa2222aaaa2222', { host: hostA })
      await macA.service.accountChanged()
      await macA.service.setupVault()
      const macB = await mac('MacBook Air', 'bbbb2222bbbb2222', { host: hostB })
      await macB.service.accountChanged()
      await approveMac(macA.service, macB.service)

      const oldKey = await appDevice('MacBook Air')
      await macB.service.pushClientState({ device: oldKey })
      await macB.service.syncNow()
      await macA.service.syncNow()
      expect(hostA.paired.has(oldKey.id)).toBe(true)
      // Its own Mac pairs it once it next applies the account's copy.
      hostB.paired.set(oldKey.id, Date.now())

      // The app lost its key and made another: that install has one device, the new key.
      await new Promise((resolve) => setTimeout(resolve, 5))
      const newKey = await appDevice('MacBook Air')
      await macB.service.pushClientState({ device: newKey })
      expect(hostB.paired.has(oldKey.id)).toBe(false)
      await macB.service.syncNow()
      await macA.service.syncNow()
      expect(hostA.paired.has(newKey.id)).toBe(true)
      expect(hostA.paired.has(oldKey.id)).toBe(false)
    })

    it('merges the own servers, keys, skills, agents and memories of a joining Mac', async () => {
      const { mac } = await signedInAccount('jo@sarto.dev')
      const macA = await mac('Mac Studio', 'aaaa1111aaaa1111')
      const macB = await mac('MacBook Air', 'bbbb1111bbbb1111')
      await giveOwnSetup(macA, 'alpha')
      await giveOwnSetup(macB, 'bravo')
      // Both Macs have a server under the same id; the account's copy wins.
      const shared = httpServer('manual:00000000-0000-4000-8000-0000000000aa', 'shared')
      macA.settings.update({
        general: { sessionTitles: false },
        marketplace: {
          mcp: [...macA.settings.get().marketplace.mcp, { ...shared, title: 'From A' }],
          skills: macA.settings.get().marketplace.skills,
        },
      })
      macB.settings.update({
        general: { sessionTitles: true },
        marketplace: {
          mcp: [...macB.settings.get().marketplace.mcp, { ...shared, title: 'From B' }],
          skills: macB.settings.get().marketplace.skills,
        },
      })
      // A server the account deleted stays deleted on a Mac that still has it.
      const gone = httpServer('manual:00000000-0000-4000-8000-0000000000ff', 'gone')
      macA.settings.update({
        marketplace: {
          mcp: [...macA.settings.get().marketplace.mcp, gone],
          skills: macA.settings.get().marketplace.skills,
        },
      })

      await macA.service.accountChanged()
      await macA.service.setupVault()
      await new Promise((resolve) => setTimeout(resolve, 5))
      macA.settings.update({
        marketplace: {
          mcp: macA.settings.get().marketplace.mcp.filter((s) => s.id !== gone.id),
          skills: macA.settings.get().marketplace.skills,
        },
      })
      await macA.service.syncNow()
      macB.settings.update({
        marketplace: {
          mcp: [...macB.settings.get().marketplace.mcp, gone],
          skills: macB.settings.get().marketplace.skills,
        },
      })

      await macB.service.accountChanged()
      await approveMac(macA.service, macB.service)
      expect(macB.service.status().keyState).toBe('ready')
      await macA.service.syncNow()

      for (const node of [macA, macB]) {
        const s = node.settings.get()
        const servers = new Map(s.marketplace.mcp.map((server) => [server.id, server]))
        expect(servers.has(ownServerId('alpha'))).toBe(true)
        expect(servers.has(ownServerId('bravo'))).toBe(true)
        expect(servers.get(shared.id)?.title).toBe('From A')
        expect(servers.has(gone.id)).toBe(false)
        expect(s.general.sessionTitles).toBe(false)
        const keys = node.marketKeys.contentsForHost().values
        expect(keys[ownServerId('alpha')]?.Authorization).toBe('key-alpha')
        expect(keys[ownServerId('bravo')]?.Authorization).toBe('key-bravo')
        expect(s.marketplace.skills.map((skill) => skill.id).sort()).toEqual(
          [ownSkillId('alpha'), ownSkillId('bravo')].sort(),
        )
        for (const tag of ['alpha', 'bravo']) {
          const skillText = await readFile(
            path.join(
              node.dataPath,
              'marketplace',
              'skills',
              skillFolder(ownSkillId(tag)),
              `skill-${tag}`,
              'SKILL.md',
            ),
            'utf8',
          )
          expect(skillText).toContain(`Skill of ${tag}.`)
          const memory = await readFile(
            path.join(node.dataPath, 'memory', 'global', `memory-${tag}.md`),
            'utf8',
          )
          expect(memory).toContain(`Remember ${tag}.`)
        }
        expect(s.addedAgents.map((agent) => agent.id).sort()).toEqual([
          'claude-code~alpha',
          'claude-code~bravo',
        ])
      }
    })

    it('forgets the hosts of Macs that left the keybag and what older installs left behind', async () => {
      const { mac, syncStore, accountId } = await signedInAccount('el@sarto.dev')
      const macA = await mac('Mac Studio', 'aaaa3333aaaa3333')
      await macA.service.accountChanged()
      await macA.service.setupVault()
      const join = async (node: Awaited<ReturnType<typeof mac>>) => {
        await node.service.accountChanged()
        await approveMac(macA.service, node.service)
        expect(node.service.status().keyState).toBe('ready')
      }
      const macB = await mac('MacBook Air', 'bbbb3333bbbb3333')
      await join(macB)
      const macC = await mac('iMac', 'cccc3333cccc3333')
      await join(macC)
      for (const node of [macA, macB, macC]) await node.service.syncNow()
      const hostNames = (node: typeof macA) =>
        node.service
          .status()
          .trustedHosts.map((host) => host.name)
          .sort()
      expect(hostNames(macA)).toEqual(['MacBook Air', 'iMac'])
      expect(
        macA.service.status().trustedHosts.find((host) => host.name === 'MacBook Air')
          ?.syncDeviceId,
      ).toBe(macB.service.status().syncDeviceId)

      await new Promise((resolve) => setTimeout(resolve, 5))
      await macA.service.removeDeviceWrap(macB.service.status().syncDeviceId!)
      await macA.service.syncNow()
      expect(hostNames(macA)).toEqual(['iMac'])
      await macC.service.syncNow()
      expect(hostNames(macC)).toEqual(['Mac Studio'])

      // Entries no install names its sync device in: Mac A's own from an earlier host key, and
      // another install's, kept while it published within 30 days.
      const day = 24 * 60 * 60 * 1000
      const nodeA = JSON.parse(
        await readFile(path.join(macA.dataPath, 'sarto-sync.json'), 'utf8'),
      ).nodeId
      const staleDevice = await appDevice('Old iPhone')
      const recentDevice = await appDevice('New iPad')
      const ownDevice = await appDevice('Mac Studio')
      const legacyHost = (name: string) => ({
        id: randomBytes(16).toString('hex'),
        name,
        platform: 'darwin',
        publicKey: randomBytes(32).toString('base64'),
        relayId: null,
        relayUrl: null,
      })
      const staleHost = legacyHost('Old Mac')
      const recentHost = legacyHost('Other Mac')
      const ownOldHost = legacyHost('Mac Studio')
      await rewriteScope(macA, syncStore, accountId, 'memory-and-mesh', (doc) => {
        const mesh = doc as {
          trustedDevices: { items: Record<string, unknown> }
          trustedHosts: { items: Record<string, unknown> }
        }
        const entry = (value: unknown, age: number, by: string) => ({
          value,
          updatedAt: Date.now() - age,
          by,
        })
        mesh.trustedDevices.items[staleDevice.id] = entry(staleDevice, 31 * day, 'node_old')
        mesh.trustedDevices.items[recentDevice.id] = entry(recentDevice, 2 * day, 'node_old')
        mesh.trustedDevices.items[ownDevice.id] = entry(ownDevice, 40 * day, nodeA)
        mesh.trustedHosts.items[staleHost.id] = entry(staleHost, 31 * day, 'node_old')
        mesh.trustedHosts.items[recentHost.id] = entry(recentHost, 2 * day, 'node_old')
        mesh.trustedHosts.items[ownOldHost.id] = entry(ownOldHost, day, nodeA)
      })
      await macA.service.syncNow()

      const mesh = (await openAccount(macA, syncStore, accountId))['memory-and-mesh'] as {
        trustedDevices: { items: Record<string, { value: { syncDeviceId?: string } }> }
        trustedHosts: { items: Record<string, unknown> }
      }
      expect(Object.keys(mesh.trustedDevices.items)).not.toContain(staleDevice.id)
      expect(Object.keys(mesh.trustedDevices.items)).toContain(recentDevice.id)
      expect(mesh.trustedDevices.items[ownDevice.id]?.value.syncDeviceId).toBe(
        macA.service.status().syncDeviceId,
      )
      expect(Object.keys(mesh.trustedHosts.items)).not.toContain(staleHost.id)
      expect(Object.keys(mesh.trustedHosts.items)).not.toContain(ownOldHost.id)
      expect(Object.keys(mesh.trustedHosts.items)).toContain(recentHost.id)
    })

    it('syncs edits inside skill folders and to global memory as they happen', async () => {
      const { mac, syncStore, accountId } = await signedInAccount('fi@sarto.dev')
      const macA = await mac('Mac Studio', 'aaaa4444aaaa4444', { watchDebounceMs: 50 })
      const macB = await mac('MacBook Air', 'bbbb4444bbbb4444', { watchDebounceMs: 50 })
      await giveOwnSetup(macA, 'alpha')
      await macA.service.accountChanged()
      await macA.service.setupVault()
      // An account whose memory switch no daemon recorded yet.
      await rewriteScope(macA, syncStore, accountId, 'memory-and-mesh', (doc) => {
        ;(doc as { memoryEnabled: unknown }).memoryEnabled = { items: {}, tombstones: {} }
      })
      await macB.service.accountChanged()
      await approveMac(macA.service, macB.service)
      expect(macB.service.status().keyState).toBe('ready')
      const skillOn = (node: typeof macA) =>
        path.join(
          node.dataPath,
          'marketplace',
          'skills',
          skillFolder(ownSkillId('alpha')),
          'skill-alpha',
          'SKILL.md',
        )
      expect(await readFile(skillOn(macB), 'utf8')).toContain('Skill of alpha.')

      // Neither the settings nor a manual sync tell Mac A about these.
      await writeFile(skillOn(macA), '# Skill alpha\nEdited in place.\n')
      await writeFile(
        path.join(macA.dataPath, 'memory', 'global', 'memory-later.md'),
        formatEntry({
          id: 'memory-later',
          title: 'Later',
          description: '',
          body: 'Written after the join.',
          createdAt: 1_700_000_000_000,
          updatedAt: 1_700_000_000_000,
          source: { agentId: null, sessionId: null },
        }),
      )
      await vi.waitFor(
        async () => {
          await macB.service.syncNow()
          expect(await readFile(skillOn(macB), 'utf8')).toContain('Edited in place.')
          expect(
            await readFile(path.join(macB.dataPath, 'memory', 'global', 'memory-later.md'), 'utf8'),
          ).toContain('Written after the join.')
        },
        { timeout: 5_000, interval: 100 },
      )

      await writeFile(
        path.join(macB.dataPath, 'memory', 'settings.json'),
        `${JSON.stringify({ version: 1, enabled: false })}\n`,
      )
      await vi.waitFor(
        async () => {
          await macA.service.syncNow()
          const settings = JSON.parse(
            await readFile(path.join(macA.dataPath, 'memory', 'settings.json'), 'utf8'),
          )
          expect(settings.enabled).toBe(false)
        },
        { timeout: 5_000, interval: 100 },
      )
    }, 20_000)

    it('syncs pinned models per agent, never the recent ones, once the agent can take them', async () => {
      const { mac } = await signedInAccount('gu@sarto.dev')
      const hostA = fakeAgentHost()
      const hostB = fakeAgentHost()
      const macA = await mac('Mac Studio', 'aaaa5555aaaa5555', {
        agentHost: hostA.link,
        watchDebounceMs: 20,
      })
      const macB = await mac('MacBook Air', 'bbbb5555bbbb5555', {
        agentHost: hostB.link,
        watchDebounceMs: 20,
      })
      hostA.offers('claude-code', ['opus', 'sonnet', 'haiku'])
      hostA.offers('codex', ['gpt-5', 'gpt-5-mini'])
      hostA.options.pin('claude-code', 'sonnet', true)
      hostA.options.pin('claude-code', 'opus', true)
      hostA.options.pin('codex', 'gpt-5-mini', true)
      hostA.options.used('claude-code', [
        {
          id: 'model',
          name: 'Model',
          category: 'model',
          type: 'select',
          value: 'haiku',
          choices: [{ value: 'haiku', name: 'haiku' }],
        },
      ])
      hostB.offers('claude-code', ['opus', 'sonnet', 'haiku'])
      await macA.service.accountChanged()
      await macA.service.setupVault()

      await macB.service.accountChanged()
      await approveMac(macA.service, macB.service)
      expect(macB.service.status().keyState).toBe('ready')
      expect(hostB.options.get('claude-code')?.pinned).toEqual(['sonnet', 'opus'])
      expect(hostB.options.get('claude-code')?.recent).toBeUndefined()
      // Mac B has never used Codex, so it keeps no options to pin a model in yet.
      expect(hostB.options.get('codex')).toBeNull()

      hostB.options.pin('claude-code', 'sonnet', false)
      await vi.waitFor(
        async () => {
          await macA.service.syncNow()
          expect(hostA.options.get('claude-code')?.pinned).toEqual(['opus'])
        },
        { timeout: 3_000, interval: 50 },
      )
      expect(hostA.options.get('claude-code')?.recent).toEqual(['haiku'])

      // Its first Codex session gets Mac B the pins, rather than sending none back.
      hostB.offers('codex', ['gpt-5', 'gpt-5-mini'])
      await vi.waitFor(() => expect(hostB.options.get('codex')?.pinned).toEqual(['gpt-5-mini']), {
        timeout: 3_000,
        interval: 50,
      })
      await macB.service.syncNow()
      await macA.service.syncNow()
      expect(hostA.options.get('codex')?.pinned).toEqual(['gpt-5-mini'])
    })

    it('never syncs machine settings, threads, sign-ins, private keys or tokens', async () => {
      const canary = 'canary-7f3a9c'
      const { mac, syncStore, accountId } = await signedInAccount('ka@sarto.dev')
      const node = await mac('Mac Pro', 'aaaa2222aaaa2222', {
        settingsFile: {
          version: 1,
          agents: { codex: { configDir: `/${canary}/codex-home` } },
        },
      })
      node.settings.setAgentBinary('claude-code', `/${canary}/bin/claude`)
      node.settings.setShellPath(`/${canary}/bin/zsh`)
      node.settings.addAgent({
        id: 'claude-code~canary',
        name: 'Canary',
        configDir: path.join(node.homeDir, canary, 'agent-config'),
        created: true,
      })
      node.settings.update({
        proxy: { mode: 'custom', url: `http://${canary}.invalid:3128`, noProxy: `${canary}.local` },
        git: { worktreeRoot: `/${canary}/worktrees` },
        remote: { name: `${canary}-host` },
        diagnostics: { verboseUntil: Date.now() + 60_000 },
        computerUse: { enabled: true, pauseOnUse: false },
      })
      expect(node.settings.get().agents.codex?.configDir).toBe(`/${canary}/codex-home`)
      // What lies in the data and home folders beside what the sync reads.
      const secrets: Array<[string, string]> = [
        [path.join(node.dataPath, 'threads', 'threads.db'), `thread ${canary}-thread`],
        [path.join(node.dataPath, 'remote', 'account.json'), `{"refresh":"${canary}-refresh"}`],
        [path.join(node.homeDir, '.claude', '.credentials.json'), `{"t":"${canary}-claude"}`],
        [path.join(node.homeDir, '.codex', 'auth.json'), `{"t":"${canary}-codex"}`],
        [path.join(node.homeDir, canary, 'agent-config', '.credentials.json'), `${canary}-added`],
      ]
      for (const [file, text] of secrets) {
        await mkdir(path.dirname(file), { recursive: true })
        await writeFile(file, text)
      }

      await node.service.accountChanged()
      await node.service.setupVault()
      node.settings.update({ general: { sessionTitles: false } })
      await node.service.syncNow()

      const opened = await openAccount(node, syncStore, accountId)
      expect(Object.keys(opened)).toEqual(
        expect.arrayContaining(['host-config', 'mcp-servers', 'memory-and-mesh']),
      )
      const hostConfig = opened['host-config'] as { items: Record<string, unknown> }
      for (const key of Object.keys(hostConfig.items)) {
        expect(
          HOST_CONFIG_KEYS.includes(key) || HOST_CONFIG_PREFIXES.some((p) => key.startsWith(p)),
          `host-config carries "${key}"`,
        ).toBe(true)
      }
      const text = JSON.stringify(opened)
      expect(text).not.toContain(canary)
      for (const field of [
        'proxy',
        'binaryPath',
        'configDir',
        'shellPath',
        'worktreeRoot',
        'verboseUntil',
        'computerUse',
        'allowedApps',
        'discoverable',
        'automatic',
      ]) {
        expect(text, field).not.toContain(`"${field}"`)
      }
      const deviceKey = await loadSyncDeviceKey(node.dataPath, node.cipher)
      const privateKey = Buffer.from(deviceKey.privateKey)
      for (const encoded of [
        privateKey.toString('base64'),
        privateKey.toString('base64url'),
        privateKey.toString('hex'),
        node.relaySeedBase64,
        Buffer.from(node.relaySeedBase64, 'base64').toString('base64url'),
      ]) {
        expect(text).not.toContain(encoded)
      }
    })
  },
)

/** Each top-level key host-config may carry, and the prefixes of its per-item keys. */
const HOST_CONFIG_KEYS = [
  'sessionTitles',
  'lightModel',
  'defaultAgent',
  'agents',
  'addedAgents',
  'disabledAgents',
  'gitBackgroundFetch',
  'mcpSartoOff',
  'startModes',
  'idleSessions',
  'usageFromComputer',
]
const HOST_CONFIG_PREFIXES = ['pinnedModels:']

/** Every scope document and usage record the server holds for the account, opened. */
async function openAccount(
  node: { dataPath: string; cipher: IdentityCipher },
  syncStore: SartoSyncStore,
  accountId: string,
): Promise<Record<string, unknown>> {
  const config = JSON.parse(await readFile(path.join(node.dataPath, 'sarto-sync.json'), 'utf8'))
  const smk = Buffer.from(
    (await node.cipher.decrypt(Buffer.from(config.masterKeyEncrypted, 'base64'))).result,
    'base64url',
  )
  const opened: Record<string, unknown> = {}
  for (const scope of SYNC_SCOPES) {
    const record = syncStore.getScope(accountId, scope)
    if (record) opened[scope] = await openScopeJson(smk, scope, record.rev, record.envelope)
  }
  for (const key of Object.keys(syncStore.listScopeItems(accountId, 'usage') ?? {})) {
    const record = syncStore.getScopeItem(accountId, 'usage', key)
    if (record) {
      opened[`usage/${key}`] = await openItemJson(smk, 'usage', key, record.rev, record.envelope)
    }
  }
  return opened
}

/** Changes a scope's document on the server, as a daemon that does not know what it holds. */
async function rewriteScope(
  node: { dataPath: string; cipher: IdentityCipher },
  syncStore: SartoSyncStore,
  accountId: string,
  scope: SyncScope,
  change: (doc: Record<string, unknown>) => void,
): Promise<void> {
  const config = JSON.parse(await readFile(path.join(node.dataPath, 'sarto-sync.json'), 'utf8'))
  const smk = Buffer.from(
    (await node.cipher.decrypt(Buffer.from(config.masterKeyEncrypted, 'base64'))).result,
    'base64url',
  )
  const record = syncStore.getScope(accountId, scope)!
  const doc = await openScopeJson<Record<string, unknown>>(smk, scope, record.rev, record.envelope)
  change(doc)
  const envelope = await sealScopeJson(smk, scope, record.rev + 1, doc)
  const put = syncStore.putScope(accountId, scope, record.rev, 'node_old', envelope)
  expect(put.ok).toBe(true)
}

function ownServerId(tag: string): string {
  return `manual:00000000-0000-4000-8000-${Buffer.from(tag.padEnd(6, '_')).toString('hex').slice(0, 12)}`
}

function ownSkillId(tag: string): string {
  return `local:00000000-0000-4000-8000-${Buffer.from(tag.padEnd(6, '_')).toString('hex').slice(0, 12)}`
}

function httpServer(id: string, name: string) {
  return {
    id,
    name,
    title: name,
    source: 'manual' as const,
    version: null,
    on: true,
    agents: 'all' as const,
    spec: {
      type: 'http' as const,
      transport: 'streamable-http' as const,
      url: `https://${name}.example/mcp`,
      headers: [{ name: 'Authorization', input: true, secret: true, required: true }],
    },
  }
}

/** A Mac's own MCP server and its key, skill, added agent and global memory, all named `tag`. */
async function giveOwnSetup(
  node: { dataPath: string; homeDir: string; settings: SettingsStore; marketKeys: MarketKeys },
  tag: string,
): Promise<void> {
  const skillDir = path.join(
    node.dataPath,
    'marketplace',
    'skills',
    skillFolder(ownSkillId(tag)),
    `skill-${tag}`,
  )
  await mkdir(skillDir, { recursive: true })
  await writeFile(path.join(skillDir, 'SKILL.md'), `# Skill ${tag}\nSkill of ${tag}.\n`)
  node.settings.update({
    marketplace: {
      mcp: [httpServer(ownServerId(tag), `server-${tag}`)],
      skills: [
        {
          id: ownSkillId(tag),
          name: `skill-${tag}`,
          description: `Skill ${tag}`,
          source: 'local',
          origin: `/tmp/${tag}`,
          version: null,
          agents: 'all',
          on: true,
        },
      ],
    },
  })
  await node.marketKeys.set({ serverId: ownServerId(tag), values: { Authorization: `key-${tag}` } })
  node.settings.addAgent({
    id: `claude-code~${tag}`,
    name: `Agent ${tag}`,
    configDir: path.join(node.homeDir, '.sarto', 'agents', `claude-code~${tag}`),
    created: true,
  })
  const memoryDir = path.join(node.dataPath, 'memory', 'global')
  await mkdir(memoryDir, { recursive: true })
  await writeFile(
    path.join(memoryDir, `memory-${tag}.md`),
    formatEntry({
      id: `memory-${tag}`,
      title: `Memory ${tag}`,
      description: '',
      body: `Remember ${tag}.`,
      createdAt: 1_700_000_000_000,
      updatedAt: 1_700_000_000_000,
      source: { agentId: null, sessionId: null },
    }),
  )
}
