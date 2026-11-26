// A Sarto sync server in memory, for the sync service's tests that must run without the closed
// server: the keybag, scopes, approvals with their code exchange, and blobs, with no sign-in. It
// follows PROTOCOL.md section 4 only as far as those tests need, and lets a test act as the server.

import { mkdir, mkdtemp, rm } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import type { NewDevice } from '@shared/remote/device'
import type {
  SyncApprovalAnswer,
  SyncApprovalRequest,
  SyncDeviceKeyWrap,
  SyncKeybagV2,
  SyncScopeRecord,
} from '@shared/sync/wire'
import { createLogger } from '../../core/log'
import { MarketKeys, marketKeysFile } from '../../core/market-keys'
import { SettingsStore } from '../../core/settings'
import { ThemeStore, readThemeFolder } from '../../core/themes'
import { NO_SYSTEM_ENCRYPTION } from '../key'
import { SartoSyncService, type SyncAccountLink } from '../sync/service'

export const SYNC_ORIGIN = 'https://cloud.example'
export const SYNC_ACCOUNT = { id: 'acct_1', email: 'a@example.com', name: null }

export interface MemorySyncServer {
  keybag: SyncKeybagV2 | null
  records: Record<string, SyncScopeRecord>
  approvals: Map<string, SyncApprovalRequest>
  /** Every approval request posted, refreshes included. */
  approvalPosts: number
  scopeWrites: number
  failScopeWrites: boolean
  fetch: (url: string, init: RequestInit) => Promise<Response>
}

const json = (status: number, body: unknown): Response =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })

export function memorySyncServer(): MemorySyncServer {
  const server: MemorySyncServer = {
    keybag: null,
    records: {},
    approvals: new Map(),
    approvalPosts: 0,
    scopeWrites: 0,
    failScopeWrites: false,
    fetch: async (url, init) => {
      const { pathname } = new URL(url)
      const method = init.method ?? 'GET'
      const body: unknown = typeof init.body === 'string' ? JSON.parse(init.body) : null
      const fields = (body ?? {}) as Record<string, unknown>
      if (pathname === '/v1/sync/manifest') {
        return json(200, {
          workspaceId: 'w',
          keybag: server.keybag,
          scopes: Object.fromEntries(
            Object.entries(server.records).map(([scope, { rev, updatedAt, updatedBy }]) => [
              scope,
              { rev, updatedAt, updatedBy, sha256: '' },
            ]),
          ),
          items: {},
          pendingApprovals: [...server.approvals.values()],
        })
      }
      if (pathname === '/v1/sync/approvals' && method === 'POST') {
        server.approvalPosts++
        const request = fields as unknown as SyncApprovalRequest
        const current = server.approvals.get(request.deviceId)
        const kept = current && current.commitment === request.commitment ? current : undefined
        server.approvals.set(request.deviceId, {
          deviceId: request.deviceId,
          devicePublicKey: request.devicePublicKey,
          deviceName: request.deviceName,
          platform: request.platform,
          createdAt: 1,
          expiresAt: Number.MAX_SAFE_INTEGER,
          ...(request.commitment ? { commitment: request.commitment } : {}),
          ...(request.targetApproverDeviceId
            ? { targetApproverDeviceId: request.targetApproverDeviceId }
            : {}),
          ...(kept?.answer ? { answer: kept.answer } : {}),
          ...(kept?.reveal ? { reveal: kept.reveal } : {}),
        })
        return json(201, { approval: server.approvals.get(request.deviceId) })
      }
      if (pathname === '/v1/sync/approvals') {
        return json(200, { approvals: [...server.approvals.values()] })
      }
      const step = /^\/v1\/sync\/approvals\/([0-9a-f]{32})\/(answer|reveal)$/.exec(pathname)
      if (step && method === 'POST') {
        const request = server.approvals.get(step[1]!)
        if (!request) return json(404, { error: 'not_found' })
        if (step[2] === 'answer') {
          const answer = { ...fields, answeredAt: 1 } as unknown as SyncApprovalAnswer
          const replaced = request.answer?.nonce !== answer.nonce
          server.approvals.set(request.deviceId, {
            ...request,
            answer,
            ...(replaced ? { reveal: undefined } : {}),
          })
        } else {
          server.approvals.set(request.deviceId, { ...request, reveal: fields.nonce as string })
        }
        return json(200, { approval: server.approvals.get(request.deviceId) })
      }
      const removal = /^\/v1\/sync\/approvals\/([0-9a-f]{32})$/.exec(pathname)
      if (removal && method === 'DELETE') {
        server.approvals.delete(removal[1]!)
        return json(200, { ok: true })
      }
      if (pathname === '/v1/sync/keybag' && method === 'PUT') {
        if (server.keybag) return json(409, { error: 'keybag_exists', keybag: server.keybag })
        server.keybag = (fields as { keybag: SyncKeybagV2 }).keybag
        return json(200, { keybag: server.keybag })
      }
      if (pathname === '/v1/sync/keybag/devices' && method === 'POST') {
        const wrap = (fields as { wrap: SyncDeviceKeyWrap }).wrap
        plantWrap(server, wrap)
        server.approvals.delete(wrap.deviceId)
        return json(200, { keybag: server.keybag })
      }
      const scope = /^\/v1\/sync\/scopes\/([a-z-]+)$/.exec(pathname)?.[1]
      if (scope && method === 'GET') {
        return server.records[scope] ? json(200, server.records[scope]) : json(404, {})
      }
      if (scope && method === 'PUT') {
        if (server.failScopeWrites) return json(500, { error: 'unavailable' })
        const { baseRev, updatedBy, envelope } = fields as {
          baseRev: number
          updatedBy: string
          envelope: SyncScopeRecord['envelope']
        }
        const current = server.records[scope] ?? null
        if (baseRev !== (current?.rev ?? 0)) return json(409, { error: 'conflict', current })
        server.scopeWrites++
        const rev = baseRev + 1
        server.records[scope] = { scope: scope as never, rev, updatedAt: rev, updatedBy, envelope }
        return json(200, { rev })
      }
      if (pathname.startsWith('/v1/sync/scopes/') && method === 'PUT') {
        return json(200, { rev: ((fields.baseRev as number) ?? 0) + 1 })
      }
      if (pathname.startsWith('/v1/sync/blobs/')) return new Response(null, { status: 200 })
      return json(404, {})
    },
  }
  return server
}

/** Puts a wrap in the keybag in place of the device's own, as the server may. */
export function plantWrap(server: MemorySyncServer, wrap: SyncDeviceKeyWrap): void {
  const keybag = server.keybag!
  const devices = keybag.devices.filter((entry) => entry.deviceId !== wrap.deviceId)
  server.keybag = { ...keybag, devices: [...devices, wrap] }
}

/** What a test follows of one Mac's remote host: the devices it holds, and each one added or removed. */
export interface PairedDevices {
  known: Set<string>
  added: string[]
  removed?: string[]
}

export interface SyncTestMacs {
  start(name: string, paired?: PairedDevices): Promise<SartoSyncService>
  stop(): Promise<void>
}

/** Starts sync services, each a Mac of `SYNC_ACCOUNT` in a folder of its own, on `server`. */
export function syncTestMacs(server: MemorySyncServer): SyncTestMacs {
  const nodes: Array<{
    root: string
    service: SartoSyncService
    settings: SettingsStore
    marketKeys: MarketKeys
  }> = []
  return {
    async start(name, paired) {
      const root = await mkdtemp(path.join(os.tmpdir(), 'sarto-sync-mac-'))
      const dataPath = path.join(root, 'data')
      await mkdir(dataPath, { recursive: true })
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
      const account: SyncAccountLink = {
        origin: () => SYNC_ORIGIN,
        profile: () => SYNC_ACCOUNT,
        token: async () => 'token',
        signOut: async () => {},
      }
      const service = await SartoSyncService.start({
        dataPath,
        homeDir: path.join(root, 'home'),
        settings,
        marketKeys,
        themes,
        relaySeedBase64: null,
        account,
        hostPublicKey: () => null,
        hostName: () => name,
        configureRelay: () => {},
        addTrustedDevice: async (device: NewDevice) => {
          paired?.added.push(device.publicKey)
        },
        knownDeviceIds: () => new Set(paired?.known),
        pairedDevices: () => [...(paired?.known ?? [])].map((id) => ({ id, addedAt: 0 })),
        removeTrustedDevice: async (id: string) => {
          paired?.removed?.push(id)
          paired?.known.delete(id)
        },
        reloadMemory: () => {},
        fetchImpl: server.fetch as never,
        openSocket: () => ({ send() {}, close() {}, addEventListener() {} }) as never,
        log: createLogger('test-sync'),
      })
      nodes.push({ root, service, settings, marketKeys })
      return service
    },
    async stop() {
      for (const node of nodes.splice(0)) {
        await node.service.stop()
        await node.settings.flush()
        await node.marketKeys.flush()
        await rm(node.root, { recursive: true, force: true })
      }
    },
  }
}

/**
 * Runs an approval of `waiting` by `approver` through the code exchange, as a user who compared
 * the codes would, and returns the code both showed.
 */
export async function approveMac(
  approver: SartoSyncService,
  waiting: SartoSyncService,
): Promise<string> {
  await waiting.syncNow()
  await approver.syncNow()
  await waiting.syncNow()
  await approver.syncNow()
  const code = waiting.status().approvalCode
  const deviceId = waiting.status().syncDeviceId
  const shown = approver.status().pendingApprovals.find((entry) => entry.deviceId === deviceId)
  if (!code || !deviceId || shown?.code !== code) {
    throw new Error(`The codes differ: ${code ?? 'none'} and ${shown?.code ?? 'none'}`)
  }
  await waiting.confirmApproval(true)
  await approver.approveDevice(deviceId)
  await waiting.syncNow()
  return code
}
