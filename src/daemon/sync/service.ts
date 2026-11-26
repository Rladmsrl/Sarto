// Sarto Daemon Full-State E2EE Sync Engine (`SartoSyncService`).
// Synchronizes UI preferences, Host & Agent orchestration config, MCP servers, MCP secret vault,
// unpacked Skill folders (via encrypted CAS blobs), custom Themes, Global Memories, Trusted
// Workspace Host/Device Mesh, and Per-Mac Usage (`island` + `host` sections) with Sarto Cloud or
// a Self-Hosted Sarto Server. Local secrets (SMK, sync device key, MCP vault replica) are sealed
// via the macOS Keychain cipher when available, with 0600 file fallback (`plainText: true`).

import { createHash, randomBytes } from 'node:crypto'
import { watch, type FSWatcher } from 'node:fs'
import { mkdir, readdir, readFile, rm } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import {
  MAX_PINNED_MODELS,
  type AgentOptions,
  type HostEvent,
  type HostMethod,
  type HostParams,
  type HostResult,
} from '@shared/agent-host'
import { MEMORY_ID, type MemoryEntry } from '@shared/memory'
import { deviceId, type NewDevice } from '@shared/remote/device'
import { PING, PONG, importRelayKey, relayHostId, relaySocketUrl } from '@shared/remote/relay'
import type { MarketServer, MarketSkill } from '@shared/marketplace'
import type { AddedAgent, SettingsFile, SettingsPatch } from '@shared/settings'
import { AGENTS_FOLDER, SARTO_HOME_FOLDER } from '@shared/storage'
import { BUILTIN_THEME_ID, THEME_ID } from '@shared/themes'
import { HARNESS_IDS, isAgentId, type AgentId, type HarnessId } from '@shared/thread'
import {
  approvalCode,
  approvalCommitment,
  approveWrap,
  createKeybagV2,
  deriveKeybagAuthToken,
  generateMasterKey,
  openItemJson,
  openMasterKeyForDevice,
  openScopeJson,
  openSyncBlob,
  sealItemJson,
  sealMasterKeyForDevice,
  verifyWrapApproval,
  sealScopeJson,
  sealSyncBlob,
  syncBase64UrlDecode,
  syncBase64UrlEncode,
  syncDeviceIdFromPublicKey,
  unwrapMasterKeyWithRecoveryKey,
} from '@shared/sync/crypto'
import {
  SYNC_SCOPES,
  deleteLwwItem,
  emptyLwwMap,
  isEncryptedSyncEnvelope,
  isSha256Hex,
  isSyncApprovalRequest,
  isSyncDeviceId,
  isSyncItemKey,
  isSyncKeybagV2,
  isSyncScope,
  mergeLwwMaps,
  putLwwItem,
  type HostConfigScopeDoc,
  type LwwEntry,
  type McpServersScopeDoc,
  type McpVaultScopeDoc,
  type MemoryAndMeshScopeDoc,
  type PortableAddedAgent,
  type PortableHarnessSetting,
  type SartoSyncStatus,
  type SkillsScopeDoc,
  type SyncApprovalAnswer,
  type SyncApprovalRequest,
  type SyncConnectionMode,
  type SyncDeviceKeyWrap,
  type SyncItemRecord,
  type SyncKeyState,
  type SyncKeybag,
  type SyncManifest,
  type SyncPendingApproval,
  type SyncScope,
  type SyncScopeRecord,
  type SyncedHostUsageSection,
  type SyncedMemoryItem,
  type SyncedSkillArchive,
  type SyncedSkillItem,
  type SyncedThemeItem,
  type SyncedUsageDeviceSummary,
  type SyncedUsageSelf,
  type SyncedUsageRecord,
  type ThemesScopeDoc,
  type TrustedWorkspaceDevice,
  type TrustedWorkspaceHost,
  type UiPrefsScopeDoc,
} from '@shared/sync/protocol'
import { SYNC_RESET_EVENT } from '@shared/sync/wire'
import { formatEntry, oneLine, parseEntry } from '../../agent-host/memory/entry-file'
import { readJsonFile, writeFileAtomic } from '../../core/json-file'
import type { Logger } from '../../core/log'
import type { MarketKeys, MarketKeysPush } from '../../core/market-keys'
import type { IdentityCipher } from '../../core/remote-identity'
import type { SettingsStore } from '../../core/settings'
import { checkThemeText, type ThemeStore } from '../../core/themes'
import { openRelaySocket } from '../../remote-host/relay-net'
import { NO_SYSTEM_ENCRYPTION } from '../key'
import {
  KeychainLockedError,
  loadSyncDeviceKey,
  resolveUsageDeviceIds,
  type UsageDeviceIds,
  type SyncDeviceKey,
} from './device-key'
import {
  logicalUsageRecords,
  mergeUsageRecords,
  remoteUsageHosts,
  usageAliases,
} from './usage-devices'
import {
  hasUnpackedSkill,
  packSkillDirectory,
  skillsFolderFingerprint,
  unpackSkillDirectory,
} from './skill-archive'

const CONFIG_FILE = 'sarto-sync.json'
const REPLICA_FILE = 'sarto-sync-replica.json'
const PUSH_DEBOUNCE_MS = 350
const HOST_USAGE_DEBOUNCE_MS = 3_000
/**
 * The least time between two uploads of this Mac's usage that new usage asks for: each one sends
 * the whole record, and every other Mac fetches and imports it again.
 */
const HOST_USAGE_MIN_INTERVAL_MS = 60_000
/** The least time between uploads for a change of the quota readings or latest requests alone. */
const HOST_USAGE_AUX_INTERVAL_MS = 10 * 60_000
const RECONCILE_INTERVAL_MS = 45_000
/** How long a folder the sync watches stays quiet before what changed in it is read. */
const WATCH_DEBOUNCE_MS = 1_500
const APPROVAL_POLL_MS = 5_000
/** How often a Mac with no keybag yet looks again, should the stream miss another Mac's setup. */
const SETUP_POLL_MS = 30_000
const APPROVAL_REPUBLISH_MS = 10 * 60_000
const WS_RECONNECT_BASE_MS = 2_000
const WS_RECONNECT_MAX_MS = 60_000
const WS_PING_MS = 25_000
const HTTP_TIMEOUT_MS = 30_000
const FORBIDDEN_OBJECT_KEYS = new Set(['__proto__', 'constructor', 'prototype'])

function isSafeObjectKey(key: string): boolean {
  return key.length > 0 && !FORBIDDEN_OBJECT_KEYS.has(key)
}

function isValidRevision(rev: unknown): rev is number {
  return typeof rev === 'number' && Number.isSafeInteger(rev) && rev >= 0
}

function withRequestDefaults(init: RequestInit): RequestInit {
  const timeout = AbortSignal.timeout(HTTP_TIMEOUT_MS)
  return {
    ...init,
    redirect: 'error',
    signal: init.signal ? AbortSignal.any([init.signal, timeout]) : timeout,
  }
}

/**
 * How a capture stamps what it reads: `change` as an edit made now, `initial` as a new account's
 * first state, and `join` as older than anything the account holds, so that its copy wins.
 */
type CaptureMode = 'change' | 'initial' | 'join'
const JOIN_STAMP = 0

/** What changes on this Mac without the settings: folders' files, and the agent host. */
type LocalSource = 'skills' | 'memory' | 'agent-host'

/** How long a trusted host or device that names no sync device stays without being published. */
const UNNAMED_MESH_ENTRY_TTL_MS = 30 * 24 * 60 * 60 * 1000

/**
 * Host-config's keys for items the agent host keeps, one LWW entry each beside the settings:
 * an agent's pinned models.
 */
const PINNED_MODELS = 'pinnedModels:'

interface StoredSyncConfig {
  version: 1
  nodeId: string
  mode: SyncConnectionMode
  serverUrl: string
  accessToken: string | null
  /** Base64 of `cipher.encrypt(accessToken)` when Keychain is available. */
  accessTokenEncrypted?: string | null
  relayToken: string | null
  /** Base64 of `cipher.encrypt(relayToken)` when Keychain is available. */
  relayTokenEncrypted?: string | null
  account: { id: string; email: string; name: string | null } | null
  /** Plaintext SMK in base64url when Keychain is unavailable; null when `masterKeyEncrypted` is set. */
  masterKeyBase64: string | null
  /** Base64 of `cipher.encrypt(smkBase64Url)` when Keychain is available. */
  masterKeyEncrypted?: string | null
  keyEpoch?: number
  plainText?: boolean
  /**
   * The account's devices this Mac's owner removed by hand, which the sync does not pair again
   * here. Kept on this Mac only; pairing one again, as with a code, takes it off the list.
   */
  declinedDevices?: string[]
  /**
   * The sync key of the Mac whose code the user confirmed on this Mac while it waited for
   * approval: the only Mac besides this one whose wrap of the account's key this Mac takes.
   */
  confirmedApprover?: string | null
}

/** This Mac's request for approval while it waits (PROTOCOL.md section 4.1). */
interface ApprovalSession {
  /** The nonce this Mac committed to, in base64url; revealed once a Mac answered. */
  nonce: string
  commitment: string
  /** The one answer this Mac reveals its nonce for. */
  answer: SyncApprovalAnswer | null
  revealed: boolean
  code: string | null
}

/**
 * What this Mac and the account last agreed on for each item the agent host keeps, so a change is
 * known as this Mac's or the account's. Kept with the replica, never synced.
 */
interface LocalBase {
  /** Pinned models by agent. */
  pins: Record<string, string[]>
}

interface StoredSyncReplica {
  pendingApply?: boolean
  version: 1
  revisions: Partial<Record<SyncScope, number>>
  uiPrefs: UiPrefsScopeDoc
  hostConfig: HostConfigScopeDoc
  mcpServers: McpServersScopeDoc
  mcpVault: McpVaultScopeDoc
  skills: SkillsScopeDoc
  themes: ThemesScopeDoc
  memoryAndMesh: MemoryAndMeshScopeDoc
  blobCache: Record<string, SyncedSkillArchive>
  usageRevisions: Record<string, number>
  usageRecords: Record<string, SyncedUsageRecord>
  localBase: LocalBase
}

interface StoredSyncReplicaOnDisk extends Omit<StoredSyncReplica, 'mcpVault'> {
  mcpVault?: McpVaultScopeDoc
  /** Base64 of `cipher.encrypt(JSON.stringify(mcpVault))` when Keychain is available. */
  mcpVaultEncrypted?: string | null
  plainText?: boolean
  dirtyScopes?: SyncScope[]
  dirtyUsageKeys?: string[]
}

export interface SyncSocketLike {
  send(data: string | Uint8Array): void
  close(code?: number, reason?: string): void
  addEventListener(
    type: 'open' | 'message' | 'close' | 'error',
    listener: (event: { data?: unknown; code?: number; reason?: string }) => void,
    options?: { once?: boolean },
  ): void
}

/** The daemon's Sarto Cloud account, which `account` mode takes its tokens from. */
export interface SyncAccountLink {
  /** The cloud's origin the account is signed in to. */
  origin(): string
  profile(): { id: string; email: string; name: string | null } | null
  /** A fresh access token; null when signed out or the cloud cannot be reached now. */
  token(): Promise<string | null>
  /** Refreshes/verifies the sign-in when the server rejects a token (e.g. WS 4401). */
  check?(): Promise<void>
  signOut(): Promise<void>
}

/** The agent host as the sync reads and changes it: through its own requests, never its files. */
export interface SyncAgentHost {
  request<M extends HostMethod>(method: M, params: HostParams<M>): Promise<HostResult<M>>
  /** Calls `listener` with each event the host sends, and with null once a port to it opens. */
  onEvent(listener: (event: HostEvent | null) => void): () => void
}

export interface UsageRecordsSnapshot {
  ownDeviceId: string
  records: SyncedUsageRecord[]
}

export interface SartoSyncDeps {
  dataPath: string
  account?: SyncAccountLink
  /** Local secret cipher (macOS Keychain when available, else NO_SYSTEM_ENCRYPTION). */
  cipher?: IdentityCipher
  /** Overrides hardware-UUID-derived 16-hex usage device id (used by tests). */
  usageDeviceId?: string
  homeDir?: string
  settings: SettingsStore
  marketKeys: MarketKeys
  themes: ThemeStore
  relaySeedBase64: string | null
  hostPublicKey(): string | null
  hostName(): string
  configureRelay(config: {
    url: string
    pushUrl: string
    enabled: boolean
    token: string | null
    relayToken?: string | null
    discoverable?: boolean
  }): void
  addTrustedDevice(device: NewDevice): Promise<void>
  knownDeviceIds(): Set<string>
  /** Sarto: the account's other hosts, which this Mac's daemon connects to as a device. */
  meshHosts?(hosts: TrustedWorkspaceHost[]): void
  /** The devices paired with this Mac's remote host, with when each was added. */
  pairedDevices?(): readonly { id: string; addedAt: number }[]
  /** Unpairs a device from this Mac's remote host. */
  removeTrustedDevice?(id: string): Promise<void>
  reloadMemory(): void
  /** Exports this Mac's daemon usage buckets and plan readings for the `usage` scope's `host` section. */
  exportHostUsage?: () => Promise<SyncedHostUsageSection | null>
  /**
   * Pushes other Macs' `host` usage sections, each with its Mac's name, to the agent host, with
   * this Mac as the sync names it while the sync is on.
   */
  onRemoteUsageChanged?: (
    remoteHosts: Record<string, SyncedHostUsageSection>,
    self?: SyncedUsageSelf,
  ) => void
  fetchImpl?: (url: string, init: RequestInit) => Promise<Response>
  openSocket?: (url: string) => SyncSocketLike
  /** Overrides `SETUP_POLL_MS` (used by tests). */
  setupPollMs?: number
  /** Overrides `WATCH_DEBOUNCE_MS` (used by tests). */
  watchDebounceMs?: number
  /** The agent host, for the pinned models it keeps. */
  agentHost?: SyncAgentHost
  log: Logger
  now?: () => number
}

function emptyMcpVault(): McpVaultScopeDoc {
  return {
    values: emptyLwwMap(),
    oauth: emptyLwwMap(),
    agentEnv: emptyLwwMap(),
  }
}

function emptyReplica(): StoredSyncReplica {
  return {
    version: 1,
    revisions: {},
    uiPrefs: emptyLwwMap(),
    hostConfig: emptyLwwMap(),
    mcpServers: emptyLwwMap(),
    mcpVault: emptyMcpVault(),
    skills: emptyLwwMap(),
    themes: emptyLwwMap(),
    memoryAndMesh: {
      memoryEnabled: emptyLwwMap(),
      memories: emptyLwwMap(),
      trustedHosts: emptyLwwMap(),
      trustedDevices: emptyLwwMap(),
    },
    blobCache: {},
    usageRevisions: {},
    usageRecords: {},
    localBase: { pins: {} },
  }
}

function defaultConfig(): StoredSyncConfig {
  return {
    version: 1,
    nodeId: `node_${randomBytes(8).toString('hex')}`,
    mode: 'off',
    serverUrl: '',
    accessToken: null,
    accessTokenEncrypted: null,
    relayToken: null,
    relayTokenEncrypted: null,
    account: null,
    masterKeyBase64: null,
    masterKeyEncrypted: null,
    keyEpoch: 1,
    plainText: true,
  }
}

function portableHarnesses(
  agents: SettingsFile['agents'],
): Partial<Record<HarnessId, PortableHarnessSetting>> {
  const out: Partial<Record<HarnessId, PortableHarnessSetting>> = {}
  for (const id of HARNESS_IDS) {
    const entry = agents[id]
    if (!entry) continue
    const clean: PortableHarnessSetting = {}
    if (entry.enabled !== undefined) clean.enabled = entry.enabled
    if (entry.hidden !== undefined) clean.hidden = entry.hidden
    if (entry.uninstalled !== undefined) clean.uninstalled = entry.uninstalled
    if (entry.autoUpdate !== undefined) clean.autoUpdate = entry.autoUpdate
    if (Object.keys(clean).length > 0) out[id] = clean
  }
  return out
}

/**
 * Host-config keys no longer synced, dropped from what is read: the proxy belongs to the Mac's own
 * network. A daemon from before keeps sending it until it is updated; it is never applied here.
 */
const RETIRED_HOST_CONFIG_KEYS = ['proxy', 'workflow']

function withoutRetiredKeys(doc: HostConfigScopeDoc): HostConfigScopeDoc {
  if (!RETIRED_HOST_CONFIG_KEYS.some((key) => key in doc.items || key in doc.tombstones)) return doc
  const items = { ...doc.items }
  const tombstones = { ...doc.tombstones }
  for (const key of RETIRED_HOST_CONFIG_KEYS) {
    delete items[key]
    delete tombstones[key]
  }
  return { items, tombstones }
}

/**
 * Which side of an item kept both by this Mac and by the account changed since the two last
 * agreed on `base`. With no agreement yet the account's copy wins, as on joining; when both
 * changed, this Mac's does, being the change seen now.
 */
function settle<T>(
  mine: T | undefined,
  synced: T | undefined,
  base: T | undefined,
  same: (a: T | undefined, b: T | undefined) => boolean,
): 'agreed' | 'capture' | 'apply' {
  if (same(mine, synced)) return 'agreed'
  if (base === undefined) return synced === undefined ? 'capture' : 'apply'
  return same(mine, base) ? 'apply' : 'capture'
}

/** A pinned models list as host-config holds it; undefined for anything else. */
function modelList(value: unknown): string[] | undefined {
  if (!Array.isArray(value)) return undefined
  const models = value.filter((v): v is string => typeof v === 'string' && v.length > 0)
  return [...new Set(models)].slice(0, MAX_PINNED_MODELS)
}

const sameModels = (a: string[] | undefined, b: string[] | undefined): boolean =>
  JSON.stringify(a ?? []) === JSON.stringify(b ?? [])

function parseJwtFamily(token: string): string | undefined {
  const parts = token.split('.')
  if (parts.length !== 3 || !parts[1]) return undefined
  const raw = syncBase64UrlDecode(parts[1])
  if (!raw) return undefined
  try {
    const payload = JSON.parse(new TextDecoder().decode(raw)) as { fam?: unknown }
    return typeof payload.fam === 'string' && payload.fam.length > 0 ? payload.fam : undefined
  } catch {
    return undefined
  }
}

function portableAddedAgents(list: readonly AddedAgent[]): PortableAddedAgent[] {
  return list.map((a) => ({
    id: a.id,
    name: a.name,
    ...(a.color ? { color: a.color } : {}),
  }))
}

export class SartoSyncService {
  private config: StoredSyncConfig
  private replica: StoredSyncReplica
  private readonly cipher: IdentityCipher
  private syncDeviceKey: SyncDeviceKey | null
  private masterKey: Uint8Array | null = null
  private keyEpoch = 1
  private keyState: SyncKeyState = 'none'
  private approvalSession: ApprovalSession | null = null
  /** The nonces this Mac answered other Macs' requests with, by their device id. */
  private approvalAnswers = new Map<string, { commitment: string; nonce: string }>()
  private approvalPublishedAt = 0
  private pendingApprovals: SyncPendingApproval[] = []
  private plainTextStorage = true
  private computedRelayId: string | null = null
  private connected = false
  private syncing = false
  private lastSyncedAt: number | null = null
  private lastError: string | null = null
  /** The first sync with the key held now has not gone through yet. */
  private firstSyncOwed = false
  /** The devices the remote host last reported, as their sorted ids. */
  private reportedDevices: string | null = null
  private isApplyingRemote = false
  private readonly dirtyScopeGen = new Map<SyncScope, number>()
  private readonly dirtyUsageGen = new Map<string, number>()
  private preservedMcpVaultEncrypted: string | null = null
  private pushTimer: ReturnType<typeof setTimeout> | null = null
  private hostUsageTimer: ReturnType<typeof setTimeout> | null = null
  private reconcileTimer: ReturnType<typeof setInterval> | null = null
  private approvalPollTimer: ReturnType<typeof setInterval> | null = null
  /** The key state `approvalPollTimer` waits out. */
  private approvalPollFor: SyncKeyState | null = null
  private wsPingTimer: ReturnType<typeof setInterval> | null = null
  private wsReconnectTimer: ReturnType<typeof setTimeout> | null = null
  private wsReconnectAttempt = 0
  private streamSocket: SyncSocketLike | null = null
  private stopping = false
  private syncQueue: Promise<void> = Promise.resolve()
  private keyStateSyncQueue: Promise<void> = Promise.resolve()
  private replicaSaveQueue: Promise<void> = Promise.resolve()
  private readonly listeners = new Set<(status: SartoSyncStatus) => void>()
  private readonly usageListeners = new Set<(snapshot: UsageRecordsSnapshot) => void>()
  private readonly unsubscribes: Array<() => void> = []
  private lastMemoryFingerprint = ''
  private lastSkillsFingerprint = ''
  private readonly localTimers = new Map<LocalSource, ReturnType<typeof setTimeout>>()
  private lastHostUsageFingerprint = ''
  /** The fingerprint without the quota history and latest requests, which change most often. */
  private lastHostUsageCoreFingerprint = ''
  private lastHostUsageUploadAt = Number.NEGATIVE_INFINITY
  /** What the agent host was last told of the other Macs' usage. */
  private lastRemoteUsageKey: string | null = null
  private readonly now: () => number

  private constructor(
    private readonly deps: SartoSyncDeps,
    cipher: IdentityCipher,
    syncDeviceKey: SyncDeviceKey | null,
    private readonly usageIds: UsageDeviceIds,
    config: StoredSyncConfig,
    replica: StoredSyncReplica,
    masterKey: Uint8Array | null,
    plainTextStorage: boolean,
    initialError: string | null = null,
  ) {
    this.cipher = cipher
    this.syncDeviceKey = syncDeviceKey
    this.config = config
    this.replica = replica
    this.masterKey = masterKey
    this.keyEpoch = config.keyEpoch ?? 1
    this.plainTextStorage = plainTextStorage || (syncDeviceKey?.plainText ?? false)
    this.lastError = initialError
    this.now = deps.now ?? Date.now
    if (config.mode === 'account') {
      this.keyState = masterKey ? 'ready' : 'needs-setup'
    } else {
      this.keyState = 'none'
    }
  }

  private markScopeDirty(scope: SyncScope): void {
    this.dirtyScopeGen.set(scope, (this.dirtyScopeGen.get(scope) ?? 0) + 1)
  }

  private markUsageDirty(key: string): void {
    this.dirtyUsageGen.set(key, (this.dirtyUsageGen.get(key) ?? 0) + 1)
  }

  static async start(deps: SartoSyncDeps): Promise<SartoSyncService> {
    const cipher = deps.cipher ?? NO_SYSTEM_ENCRYPTION
    const cipherAvailable = await cipher.available()
    const plainTextStorage = !cipherAvailable || cipher.plainText()
    let syncDeviceKey: SyncDeviceKey | null = null
    let initialError: string | null = null
    try {
      syncDeviceKey = await loadSyncDeviceKey(deps.dataPath, cipher, deps.log)
    } catch (error) {
      if (error instanceof KeychainLockedError) {
        initialError = error.message
        deps.log.warn(`${error.message}; encrypted sync paused until Keychain is unlocked`)
      } else {
        throw error
      }
    }
    const usageIds = deps.usageDeviceId
      ? { deviceId: deps.usageDeviceId }
      : await resolveUsageDeviceIds(syncDeviceKey?.deviceId ?? 'locked')

    const configPath = path.join(deps.dataPath, CONFIG_FILE)
    const replicaPath = path.join(deps.dataPath, 'state', REPLICA_FILE)
    const [cfgRead, repRead] = await Promise.all([
      readJsonFile(configPath),
      readJsonFile(replicaPath),
    ])

    let cfg = defaultConfig()
    let masterKey: Uint8Array | null = null
    let upgradeConfigEncryption = false
    if (cfgRead.kind === 'ok' && typeof cfgRead.value === 'object' && cfgRead.value !== null) {
      const raw = cfgRead.value as Partial<StoredSyncConfig>
      if (raw.version === 1 && typeof raw.nodeId === 'string') {
        cfg = {
          version: 1,
          nodeId: raw.nodeId,
          mode: raw.mode === 'account' || raw.mode === 'off' ? raw.mode : 'off',
          serverUrl: typeof raw.serverUrl === 'string' ? raw.serverUrl : '',
          accessToken: typeof raw.accessToken === 'string' ? raw.accessToken : null,
          accessTokenEncrypted:
            typeof raw.accessTokenEncrypted === 'string' ? raw.accessTokenEncrypted : null,
          relayToken: typeof raw.relayToken === 'string' ? raw.relayToken : null,
          relayTokenEncrypted:
            typeof raw.relayTokenEncrypted === 'string' ? raw.relayTokenEncrypted : null,
          account: raw.account ?? null,
          masterKeyBase64: typeof raw.masterKeyBase64 === 'string' ? raw.masterKeyBase64 : null,
          masterKeyEncrypted:
            typeof raw.masterKeyEncrypted === 'string' ? raw.masterKeyEncrypted : null,
          keyEpoch: typeof raw.keyEpoch === 'number' && raw.keyEpoch >= 1 ? raw.keyEpoch : 1,
          plainText: typeof raw.plainText === 'boolean' ? raw.plainText : plainTextStorage,
          declinedDevices: Array.isArray(raw.declinedDevices)
            ? raw.declinedDevices.filter((id): id is string => typeof id === 'string')
            : [],
          confirmedApprover:
            typeof raw.confirmedApprover === 'string' ? raw.confirmedApprover : null,
        }
        if (cfg.accessTokenEncrypted) {
          if (cipherAvailable) {
            try {
              const { result } = await cipher.decrypt(
                Buffer.from(cfg.accessTokenEncrypted, 'base64'),
              )
              if (result) cfg.accessToken = result
            } catch (error) {
              deps.log.warn(
                `Could not decrypt stored sync access token: ${(error as Error).message}`,
              )
            }
          } else {
            initialError ??= 'Stored sync token is protected by Keychain, which is unavailable now'
            deps.log.warn(initialError)
          }
        } else if (cfg.accessToken && cipherAvailable) {
          upgradeConfigEncryption = true
        }
        if (cfg.relayTokenEncrypted) {
          if (cipherAvailable) {
            try {
              const { result } = await cipher.decrypt(
                Buffer.from(cfg.relayTokenEncrypted, 'base64'),
              )
              if (result) cfg.relayToken = result
            } catch (error) {
              deps.log.warn(
                `Could not decrypt stored sync relay token: ${(error as Error).message}`,
              )
            }
          } else {
            initialError ??= 'Stored sync token is protected by Keychain, which is unavailable now'
            deps.log.warn(initialError)
          }
        } else if (cfg.relayToken && cipherAvailable) {
          upgradeConfigEncryption = true
        }
        if (cfg.masterKeyEncrypted) {
          if (cipherAvailable) {
            try {
              const { result } = await cipher.decrypt(Buffer.from(cfg.masterKeyEncrypted, 'base64'))
              const decoded = syncBase64UrlDecode(result)
              if (decoded?.length === 32) masterKey = decoded
            } catch (error) {
              deps.log.warn(`Could not decrypt stored sync key: ${(error as Error).message}`)
            }
          } else {
            initialError ??= 'Stored sync key is protected by Keychain, which is unavailable now'
            deps.log.warn(initialError)
          }
        } else if (cfg.masterKeyBase64) {
          const decoded = syncBase64UrlDecode(cfg.masterKeyBase64)
          if (decoded?.length === 32) {
            masterKey = decoded
            if (cipherAvailable) upgradeConfigEncryption = true
          }
        }
      }
    }

    let rep = emptyReplica()
    let upgradeReplicaEncryption = false
    let preservedMcpVaultEncrypted: string | null = null
    let restoredDirtyScopes: SyncScope[] = []
    let restoredDirtyUsageKeys: string[] = []
    if (repRead.kind === 'ok' && typeof repRead.value === 'object' && repRead.value !== null) {
      const raw = repRead.value as Partial<StoredSyncReplicaOnDisk>
      if (raw.version === 1) {
        let mcpVault = emptyMcpVault()
        if (typeof raw.mcpVaultEncrypted === 'string' && raw.mcpVaultEncrypted.length > 0) {
          if (cipherAvailable) {
            try {
              const { result } = await cipher.decrypt(Buffer.from(raw.mcpVaultEncrypted, 'base64'))
              const parsedVault = JSON.parse(result) as Partial<McpVaultScopeDoc>
              mcpVault = { ...emptyMcpVault(), ...parsedVault }
            } catch (error) {
              if (!(await cipher.available())) {
                preservedMcpVaultEncrypted = raw.mcpVaultEncrypted
              }
              deps.log.warn(
                `Could not decrypt local MCP vault replica: ${(error as Error).message}`,
              )
            }
          } else {
            preservedMcpVaultEncrypted = raw.mcpVaultEncrypted
          }
        } else if (raw.mcpVault) {
          mcpVault = { ...emptyMcpVault(), ...raw.mcpVault }
          if (cipherAvailable) upgradeReplicaEncryption = true
        }
        if (Array.isArray(raw.dirtyScopes)) {
          restoredDirtyScopes = raw.dirtyScopes.filter(
            (s): s is SyncScope =>
              typeof s === 'string' && (SYNC_SCOPES as readonly string[]).includes(s),
          )
        }
        if (Array.isArray(raw.dirtyUsageKeys)) {
          restoredDirtyUsageKeys = raw.dirtyUsageKeys.filter(
            (k): k is string => typeof k === 'string' && isSyncItemKey(k),
          )
        }
        const rawMesh = raw.memoryAndMesh as Partial<MemoryAndMeshScopeDoc> | undefined
        rep = {
          ...emptyReplica(),
          revisions: raw.revisions ?? {},
          pendingApply: raw.pendingApply === true,
          uiPrefs: raw.uiPrefs ?? emptyLwwMap(),
          hostConfig: withoutRetiredKeys(raw.hostConfig ?? emptyLwwMap()),
          mcpServers: raw.mcpServers ?? emptyLwwMap(),
          mcpVault,
          skills: raw.skills ?? emptyLwwMap(),
          themes: raw.themes ?? emptyLwwMap(),
          memoryAndMesh: {
            memoryEnabled: rawMesh?.memoryEnabled ?? emptyLwwMap(),
            memories: rawMesh?.memories ?? emptyLwwMap(),
            trustedHosts: rawMesh?.trustedHosts ?? emptyLwwMap(),
            trustedDevices: rawMesh?.trustedDevices ?? emptyLwwMap(),
          },
          blobCache: raw.blobCache ?? {},
          usageRevisions: raw.usageRevisions ?? {},
          usageRecords: raw.usageRecords ?? {},
          localBase: {
            pins: { ...raw.localBase?.pins },
          },
        }
      }
    }

    const svc = new SartoSyncService(
      deps,
      cipher,
      syncDeviceKey,
      usageIds,
      cfg,
      rep,
      masterKey,
      plainTextStorage,
      initialError,
    )
    svc.preservedMcpVaultEncrypted = preservedMcpVaultEncrypted
    for (const s of restoredDirtyScopes) svc.markScopeDirty(s)
    for (const k of restoredDirtyUsageKeys) svc.markUsageDirty(k)
    if (upgradeConfigEncryption) await svc.saveConfig()
    if (upgradeReplicaEncryption) await svc.saveReplica()
    await svc.initRelayId()
    svc.attachLocalWatchers()
    await svc.watchLocalFolders()
    svc.followAgentHost()
    svc.notifyRemoteHostUsage()

    if (svc.isConfigured()) {
      void svc
        .enqueueSync(async () => {
          try {
            await svc.reconcileWithServer()
          } finally {
            // Even when booted offline, keep attempting live stream reconnection.
            svc.connectStream()
          }
        })
        .catch(() => {
          svc.scheduleStreamReconnect()
        })
      svc.startReconcileLoop()
    }
    return svc
  }

  /** Lazily loads the persistent X25519 sync device key if Keychain was locked at daemon startup. */
  private async ensureSyncDeviceKey(): Promise<SyncDeviceKey | null> {
    if (this.syncDeviceKey) return this.syncDeviceKey
    try {
      const loaded = await loadSyncDeviceKey(this.deps.dataPath, this.cipher, this.deps.log)
      this.syncDeviceKey = loaded
      this.plainTextStorage = this.plainTextStorage || loaded.plainText
      return loaded
    } catch (error) {
      if (error instanceof KeychainLockedError) {
        this.lastError = error.message
        return null
      }
      throw error
    }
  }

  private async initRelayId(): Promise<void> {
    if (!this.deps.relaySeedBase64) return
    try {
      const key = await importRelayKey(Buffer.from(this.deps.relaySeedBase64, 'base64'))
      this.computedRelayId = await relayHostId(key.publicKey)
    } catch {
      this.computedRelayId = null
    }
  }

  onChange(listener: (status: SartoSyncStatus) => void): () => void {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  onUsageUpdated(listener: (snapshot: UsageRecordsSnapshot) => void): () => void {
    this.usageListeners.add(listener)
    return () => this.usageListeners.delete(listener)
  }

  private emitStatus(): void {
    const snap = this.status()
    for (const listener of this.listeners) {
      try {
        listener(snap)
      } catch {
        // Ignore observer errors.
      }
    }
  }

  private emitUsageUpdated(): void {
    const snap = this.usageSnapshot()
    for (const listener of this.usageListeners) {
      try {
        listener(snap)
      } catch {
        // Ignore observer errors.
      }
    }
  }

  private logicalUsageRecords(): SyncedUsageRecord[] {
    return logicalUsageRecords(Object.values(this.replica.usageRecords), this.usageIds)
  }

  usageSnapshot(): UsageRecordsSnapshot {
    const records = this.logicalUsageRecords().sort((a, b) => a.deviceId.localeCompare(b.deviceId))
    return { ownDeviceId: this.usageIds.deviceId, records }
  }

  /** Usage snapshot without heavy `host` bucket arrays for UI clients over `control.sock`. */
  clientUsageSnapshot(): UsageRecordsSnapshot {
    const records = this.logicalUsageRecords()
      .map((r) => ({
        v: r.v,
        deviceId: r.deviceId,
        deviceName: r.deviceName,
        updatedAt: r.updatedAt,
        ...(r.island ? { island: r.island } : {}),
      }))
      .sort((a, b) => a.deviceId.localeCompare(b.deviceId))
    return { ownDeviceId: this.usageIds.deviceId, records }
  }

  private notifyRemoteHostUsage(): void {
    if (!this.deps.onRemoteUsageChanged) return
    const remoteHosts = remoteUsageHosts(Object.values(this.replica.usageRecords), this.usageIds)
    const own = this.replica.usageRecords[this.usageIds.deviceId]
    const self: SyncedUsageSelf | undefined = this.isConfigured()
      ? {
          deviceId: this.usageIds.deviceId,
          deviceName: this.deps.hostName(),
          updatedAt: own?.host?.updatedAt ?? null,
        }
      : undefined
    // Each notice hands every other Mac's year of buckets to the agent host, which imports them
    // all again; one that would change no Mac's record sends nothing.
    const key = JSON.stringify([
      Object.entries(remoteHosts)
        .map(([id, host]) => [
          id,
          host.deviceName ?? null,
          host.updatedAt,
          Array.isArray(host.buckets) ? host.buckets.length : 0,
        ])
        .sort((a, b) => String(a[0]).localeCompare(String(b[0]))),
      self ?? null,
    ])
    if (key === this.lastRemoteUsageKey) return
    this.lastRemoteUsageKey = key
    this.deps.onRemoteUsageChanged(remoteHosts, self)
  }

  isConfigured(): boolean {
    return (
      this.config.mode === 'account' &&
      Boolean(this.config.serverUrl) &&
      this.accountMatches() &&
      this.masterKey !== null
    )
  }

  /**
   * Whether the sync stream should stay open: active sync, waiting for device approval, or waiting
   * for the account's first keybag, so another Mac's setup is seen at once.
   */
  private shouldConnectStream(): boolean {
    if (this.isConfigured()) return true
    return (
      this.config.mode === 'account' &&
      this.accountMatches() &&
      (this.keyState === 'awaiting-approval' || this.keyState === 'needs-setup')
    )
  }

  /** Whether the daemon's account is the one `account` mode was set up for. */
  private accountMatches(): boolean {
    const link = this.deps.account
    const profile = link?.profile()
    return (
      !!link &&
      !!profile &&
      profile.id === this.config.account?.id &&
      link.origin() === this.config.serverUrl
    )
  }

  /**
   * Follows the daemon's account: signing in to Sarto Cloud turns `account` mode on for it
   * and inspects Keybag v2 state, and signing out forgets keys and local replica.
   */
  async accountChanged(): Promise<void> {
    const link = this.deps.account
    if (!link) return
    const profile = link.profile()
    if (profile && this.config.mode === 'account' && this.accountMatches()) {
      if (this.masterKey !== null) return
      await this.syncAccountKeyState()
      return
    }
    if (!profile && this.config.mode !== 'account') return
    await this.startOver(profile, link.origin(), null)
  }

  /**
   * Forgets the sync key, the replica and the approvals, keeping the account `profile` (or none),
   * and looks at the account's keybag again: after a change of account, or when the account's
   * sync was reset on the server. `reason` is shown as the status's error.
   */
  private async startOver(
    profile: ReturnType<SyncAccountLink['profile']>,
    origin: string,
    reason: string | null,
  ): Promise<void> {
    this.stopLoops()
    if (this.pushTimer) {
      clearTimeout(this.pushTimer)
      this.pushTimer = null
    }
    this.dirtyScopeGen.clear()
    this.dirtyUsageGen.clear()
    this.lastMemoryFingerprint = ''
    this.lastSkillsFingerprint = ''
    this.lastHostUsageFingerprint = ''
    this.lastHostUsageCoreFingerprint = ''
    this.lastHostUsageUploadAt = Number.NEGATIVE_INFINITY
    this.preservedMcpVaultEncrypted = null
    this.replica = emptyReplica()
    this.publishMeshHosts()
    this.masterKey = null
    this.keyEpoch = 1
    this.connected = false
    this.lastError = reason
    this.approvalSession = null
    this.approvalAnswers.clear()
    this.pendingApprovals = []
    this.keyState = profile ? 'needs-setup' : 'none'
    this.config = {
      ...this.config,
      mode: profile ? 'account' : 'off',
      serverUrl: profile ? origin : '',
      accessToken: null,
      accessTokenEncrypted: null,
      relayToken: null,
      relayTokenEncrypted: null,
      account: profile ? { id: profile.id, email: profile.email, name: profile.name } : null,
      masterKeyBase64: null,
      masterKeyEncrypted: null,
      confirmedApprover: null,
      keyEpoch: 1,
    }
    await this.saveConfig()
    await this.saveReplica()
    this.notifyRemoteHostUsage()
    this.emitUsageUpdated()
    this.emitStatus()

    if (profile) {
      await this.syncAccountKeyState()
    }
  }

  /**
   * Checks the server's keybag in `account` mode: unwraps our device wrap if already approved,
   * publishes an approval request if another Mac holds Keybag v2, or flags setup/migration.
   * Serialized via `keyStateSyncQueue` so WS events and fallback polls never race.
   */
  private syncAccountKeyState(options?: { pollOnly?: boolean }): Promise<void> {
    const next = this.keyStateSyncQueue
      .catch(() => {})
      .then(() => this.runSyncAccountKeyState(options))
    this.keyStateSyncQueue = next.catch(() => {})
    return next
  }

  private async runSyncAccountKeyState(options?: { pollOnly?: boolean }): Promise<void> {
    if (this.config.mode !== 'account' || !this.accountMatches() || this.stopping) return
    if (this.masterKey !== null) return
    const profile = this.deps.account?.profile()
    if (!profile) return

    const deviceKey = await this.ensureSyncDeviceKey()
    if (!deviceKey) {
      this.emitStatus()
      return
    }

    let token: string | null
    try {
      token = await this.deps.account!.token()
    } catch {
      return
    }
    if (!token) return
    this.config.accessToken = token

    let manifest: SyncManifest
    try {
      manifest = await this.fetchManifest(this.config.serverUrl, token)
    } catch {
      // Offline or unreachable right now: stay in current needsKey state cleanly.
      return
    }

    if (!manifest.keybag || !isSyncKeybagV2(manifest.keybag)) {
      const before = this.keyState
      this.keyState = 'needs-setup'
      this.approvalSession = null
      this.approvalPublishedAt = 0
      if (!options?.pollOnly || before !== this.keyState) {
        this.emitStatus()
      }
      if (!this.streamSocket && !this.wsReconnectTimer) this.connectStream()
      if (this.approvalPollFor !== 'needs-setup') this.startApprovalPollLoop()
      return
    }

    let kb = manifest.keybag
    const ownWrap = kb.devices.find((wrap) => wrap.deviceId === deviceKey.deviceId)
    if (ownWrap) {
      // The server can seal a key of its own to this Mac's public key, so a wrap counts only
      // with the approval of this Mac or of the Mac whose code the user confirmed here.
      const trusted = [deviceKey.publicKeyBase64Url]
      if (this.config.confirmedApprover) trusted.push(this.config.confirmedApprover)
      const vouched = await verifyWrapApproval(ownWrap, deviceKey.privateKey, trusted, profile.id)
      const awaitingConfirmation =
        ownWrap.approval !== undefined &&
        ownWrap.approval.approverPublicKey === this.approvalSession?.answer?.approverPublicKey
      if (!vouched && !awaitingConfirmation) {
        this.lastError = ownWrap.approval
          ? 'The sync key offered to this Mac comes from a Mac whose code was not confirmed here'
          : 'The sync key offered to this Mac carries no approval it can check: approve it from a Mac with this version of Sarto, or unlock with the recovery key'
        this.deps.log.warn(this.lastError)
      }
      // Only a wrap that does not open sends this Mac to ask for approval again. What follows the
      // key, the wrap's new sign-in and the first sync, may fail and leaves the key held.
      const smk = vouched
        ? await openMasterKeyForDevice(ownWrap, deviceKey.privateKey, profile.id).catch(
            (error: unknown) => {
              this.lastError = `Could not unwrap sync key for this Mac: ${(error as Error).message}`
              this.deps.log.warn(this.lastError)
              return null
            },
          )
        : null
      if (smk) {
        const tokenFamily = parseJwtFamily(token)
        if (tokenFamily && ownWrap.oauthDeviceId !== tokenFamily) {
          try {
            const [refreshedWrap, authToken] = await Promise.all([
              sealMasterKeyForDevice(smk, deviceKey.publicKeyBase64Url, {
                keyEpoch: kb.keyEpoch,
                deviceName: this.deps.hostName(),
                accountId: profile.id,
                addedAt: this.now(),
              }).then((wrap) => this.approveOwnWrap(wrap, deviceKey, profile.id)),
              deriveKeybagAuthToken(smk, profile.id),
            ])
            const regRes = await this.httpJson<{ keybag?: SyncKeybag }>(
              `${this.config.serverUrl}/v1/sync/keybag/devices`,
              {
                method: 'POST',
                headers: {
                  authorization: `Bearer ${token}`,
                  'content-type': 'application/json',
                },
                body: JSON.stringify({ wrap: refreshedWrap, self: true, authToken }),
              },
            )
            if (regRes.ok && regRes.body?.keybag && isSyncKeybagV2(regRes.body.keybag)) {
              kb = regRes.body.keybag
              manifest = { ...manifest, keybag: kb }
            }
          } catch (error) {
            this.deps.log.warn(
              `Could not renew this Mac's sync key wrap: ${(error as Error).message}`,
            )
          }
        }
        await this.activateAccountMasterKey(smk, kb.keyEpoch, manifest)
        return
      }
    }

    if (kb.devices.length === 0) {
      this.stopApprovalPollLoop()
      this.keyState = 'awaiting-approval'
      this.approvalSession = null
      this.approvalPublishedAt = 0
      this.lastError = 'No active devices hold the sync key; unlock with your recovery key'
      this.emitStatus()
      return
    }

    // Keybag v2 exists without this Mac: publish approval request once (or refresh before TTL),
    // keep a single live WebSocket open without tearing it down on every poll tick.
    const wasAwaiting = this.keyState === 'awaiting-approval'
    this.keyState = 'awaiting-approval'
    const before = this.approvalSession?.code ?? null
    const listed = (manifest.pendingApprovals ?? []).find(
      (request) => request.deviceId === deviceKey.deviceId,
    )
    const session = await this.followApprovalRequest(token, profile.id, deviceKey, listed)
    // The Mac that answered has sealed the key already, which leaves the request: it waits for
    // the user to confirm the code here, and asking again would start the exchange over.
    const sealedByAnswerer =
      ownWrap !== undefined &&
      session.answer !== null &&
      ownWrap.approval?.approverPublicKey === session.answer.approverPublicKey
    const needsPublish =
      !sealedByAnswerer &&
      (!options?.pollOnly ||
        !wasAwaiting ||
        listed?.commitment !== session.commitment ||
        this.approvalPublishedAt === 0 ||
        this.now() - this.approvalPublishedAt >= APPROVAL_REPUBLISH_MS)
    if (session.code !== before) this.emitStatus()
    if (needsPublish) {
      await this.publishApprovalRequest(token, deviceKey)
        .then(() => {
          this.approvalPublishedAt = this.now()
        })
        .catch((error: unknown) => {
          this.deps.log.warn(
            `Could not publish device approval request: ${(error as Error).message}`,
          )
        })
    }
    if (!wasAwaiting || needsPublish) {
      this.emitStatus()
    }
    if (!this.streamSocket && !this.wsReconnectTimer) {
      this.connectStream()
    }
    if (this.approvalPollFor !== 'awaiting-approval') {
      this.startApprovalPollLoop()
    }
  }

  /** Drops local SMK when this Mac's device wrap was removed remotely from Keybag v2. */
  private async revokeLocalMasterKey(reason: string): Promise<void> {
    if (this.config.mode !== 'account' || this.masterKey === null) return
    this.stopLoops()
    this.masterKey = null
    this.connected = false
    this.pendingApprovals = []
    this.approvalPublishedAt = 0
    this.lastError = reason
    this.keyState = 'awaiting-approval'
    this.config = {
      ...this.config,
      masterKeyBase64: null,
      masterKeyEncrypted: null,
    }
    await this.saveConfig()
    this.emitStatus()
    await this.syncAccountKeyState()
  }

  private async activateAccountMasterKey(
    smk: Uint8Array,
    keyEpoch: number,
    manifest?: SyncManifest,
  ): Promise<void> {
    this.stopApprovalPollLoop()
    this.masterKey = smk
    this.keyEpoch = keyEpoch
    this.keyState = 'ready'
    this.approvalSession = null
    this.approvalPublishedAt = 0
    this.lastError = null
    this.config.keyEpoch = keyEpoch
    this.config.confirmedApprover = null
    await this.saveConfig()
    this.enableRelayInSettings()

    // The key is held from here on, whatever the first sync does: a failure is the status's error
    // and the first sync is owed, so the next sync runs it before anything else.
    this.firstSyncOwed = true
    await this.enqueueSync(() => this.runFirstSync(manifest)).catch(() => {})
    this.startReconcileLoop()
    this.emitStatus()
  }

  /** The first sync with a key, which joins this Mac's setup to the account's. */
  private async runFirstSync(manifest?: SyncManifest): Promise<void> {
    if (!this.firstSyncOwed || !this.masterKey) return
    const m =
      manifest ?? (await this.fetchManifest(this.config.serverUrl, this.config.accessToken!))
    await this.bootstrapWorkspace(m)
    this.firstSyncOwed = false
    await this.refreshPendingApprovals(m.pendingApprovals)
    if (!this.streamSocket) this.connectStream()
  }

  /**
   * Follows this Mac's request for approval as the server lists it: takes the one answer it
   * reveals its nonce for, and starts the request over when that answer changes once revealed, so
   * no answer is ever chosen with the nonce known.
   */
  private async followApprovalRequest(
    token: string,
    accountId: string,
    deviceKey: SyncDeviceKey,
    listed: SyncApprovalRequest | undefined,
  ): Promise<ApprovalSession> {
    let session = this.approvalSession
    const answer = listed?.commitment === session?.commitment ? listed?.answer : undefined
    const sameAnswer =
      answer !== undefined &&
      session?.answer?.approverPublicKey === answer.approverPublicKey &&
      session.answer.nonce === answer.nonce
    // A request the server dropped holds no answer to take; only another answer starts over.
    if (session?.revealed && answer !== undefined && !sameAnswer) session = null
    if (!session) {
      const nonce = syncBase64UrlEncode(crypto.getRandomValues(new Uint8Array(32)))
      session = {
        nonce,
        commitment: await approvalCommitment(deviceKey.publicKeyBase64Url, nonce),
        answer: null,
        revealed: false,
        code: null,
      }
      this.approvalSession = session
      return session
    }
    if (!answer) return session
    if (!sameAnswer) {
      const key = syncBase64UrlDecode(answer.approverPublicKey)
      if (
        !key ||
        key.length !== 32 ||
        answer.approverPublicKey === deviceKey.publicKeyBase64Url ||
        (await syncDeviceIdFromPublicKey(key)) !== answer.approverDeviceId
      ) {
        return session
      }
      session.answer = answer
      session.code = await approvalCode({
        accountId,
        devicePublicKey: deviceKey.publicKeyBase64Url,
        approverPublicKey: answer.approverPublicKey,
        deviceNonce: session.nonce,
        approverNonce: answer.nonce,
      })
    }
    if (!session.revealed) {
      const res = await this.httpJson<{ error?: string }>(
        `${this.config.serverUrl}/v1/sync/approvals/${deviceKey.deviceId}/reveal`,
        {
          method: 'POST',
          headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
          body: JSON.stringify({ nonce: session.nonce }),
        },
      ).catch(() => null)
      if (res?.ok) session.revealed = true
    }
    return session
  }

  /**
   * The user compared the code on this Mac with the one on the Mac that answered: when they match,
   * that Mac's wrap of the account's key is the one this Mac takes; when not, the request starts
   * over with a new nonce.
   */
  async confirmApproval(matches: boolean): Promise<SartoSyncStatus> {
    const session = this.approvalSession
    if (this.keyState !== 'awaiting-approval' || !session?.answer || !session.code) {
      throw new Error('No approval code is waiting to be confirmed on this Mac')
    }
    if (matches) {
      this.config.confirmedApprover = session.answer.approverPublicKey
      await this.saveConfig()
    } else {
      this.approvalSession = null
      this.config.confirmedApprover = null
      await this.saveConfig()
    }
    this.emitStatus()
    await this.syncAccountKeyState()
    return this.status()
  }

  /** `wrap`, sealed by this Mac to itself, with its own approval (PROTOCOL.md section 4.2). */
  private approveOwnWrap(
    wrap: SyncDeviceKeyWrap,
    deviceKey: SyncDeviceKey,
    accountId: string,
  ): Promise<SyncDeviceKeyWrap> {
    return approveWrap(wrap, deviceKey.privateKey, deviceKey.publicKeyBase64Url, accountId)
  }

  private async publishApprovalRequest(token: string, deviceKey: SyncDeviceKey): Promise<void> {
    const res = await this.httpJson<{ approval?: unknown; error?: string }>(
      `${this.config.serverUrl}/v1/sync/approvals`,
      {
        method: 'POST',
        headers: {
          authorization: `Bearer ${token}`,
          'content-type': 'application/json',
        },
        body: JSON.stringify({
          deviceId: deviceKey.deviceId,
          devicePublicKey: deviceKey.publicKeyBase64Url,
          deviceName: this.deps.hostName(),
          platform: process.platform,
          ...(this.approvalSession ? { commitment: this.approvalSession.commitment } : {}),
        }),
      },
    )
    if (!res.ok) {
      throw new Error(`Approval request failed (${res.status}: ${res.body?.error ?? 'unknown'})`)
    }
  }

  /**
   * Initializes a brand-new Keybag v2 vault for the signed-in account, seals the first Mac's
   * device wrap + 128-bit recovery wrap, seeds remote scopes, and returns the one-time recovery key.
   * When another Mac made the account's keybag first, this Mac asks it for approval instead and
   * the recovery key is null.
   */
  async setupVault(): Promise<{ status: SartoSyncStatus; recoveryKey: string | null }> {
    if (this.config.mode !== 'account' || !this.accountMatches()) {
      throw new Error('Sign in to Sarto Cloud before setting up encrypted sync')
    }
    const profile = this.deps.account!.profile()!
    const deviceKey = await this.ensureSyncDeviceKey()
    if (!deviceKey) {
      throw new Error('Keychain is locked; unlock macOS Keychain before setting up encrypted sync')
    }
    await this.refreshAccountToken()
    const token = this.config.accessToken!
    const manifest = await this.fetchManifest(this.config.serverUrl, token)

    if (manifest.keybag && isSyncKeybagV2(manifest.keybag)) {
      await this.syncAccountKeyState()
      return { status: this.status(), recoveryKey: null }
    }

    const smk = generateMasterKey()
    const { keybag, recoveryKey } = await createKeybagV2(smk, deviceKey.publicKeyBase64Url, {
      keyEpoch: 1,
      deviceName: this.deps.hostName(),
      accountId: profile.id,
      now: this.now(),
    })
    keybag.devices = await Promise.all(
      keybag.devices.map((wrap) => this.approveOwnWrap(wrap, deviceKey, profile.id)),
    )

    const kbRes = await this.httpJson<{ keybag?: SyncKeybag; error?: string }>(
      `${this.config.serverUrl}/v1/sync/keybag`,
      {
        method: 'PUT',
        headers: {
          authorization: `Bearer ${token}`,
          'content-type': 'application/json',
        },
        body: JSON.stringify({ keybag }),
      },
    )
    if (kbRes.status === 409) {
      await this.syncAccountKeyState()
      return { status: this.status(), recoveryKey: null }
    }
    if (!kbRes.ok) {
      throw new Error(`Failed to create Keybag v2 (${kbRes.status})`)
    }

    await this.activateAccountMasterKey(smk, keybag.keyEpoch, {
      ...manifest,
      keybag: kbRes.body?.keybag ?? keybag,
    })
    return { status: this.status(), recoveryKey }
  }

  /**
   * Unlocks an existing Keybag v2 account using the user's 128-bit recovery key, registers a new
   * device wrap for this Mac on the server, and starts syncing.
   */
  async unlockWithRecoveryKey(recoveryKey: string): Promise<SartoSyncStatus> {
    if (this.config.mode !== 'account' || !this.accountMatches()) {
      throw new Error('Sign in to Sarto Cloud before unlocking with a recovery key')
    }
    const profile = this.deps.account!.profile()!
    const deviceKey = await this.ensureSyncDeviceKey()
    if (!deviceKey) {
      throw new Error('Keychain is locked; unlock macOS Keychain before unlocking encrypted sync')
    }
    await this.refreshAccountToken()
    const token = this.config.accessToken!
    const manifest = await this.fetchManifest(this.config.serverUrl, token)
    if (!manifest.keybag || !isSyncKeybagV2(manifest.keybag)) {
      throw new Error('This account has no Keybag v2 to unlock with a recovery key')
    }

    let smk: Uint8Array
    try {
      smk = await unwrapMasterKeyWithRecoveryKey(manifest.keybag.recovery, recoveryKey, profile.id)
    } catch {
      throw new Error('Invalid recovery key')
    }

    const [wrap, authToken] = await Promise.all([
      sealMasterKeyForDevice(smk, deviceKey.publicKeyBase64Url, {
        keyEpoch: manifest.keybag.keyEpoch,
        deviceName: this.deps.hostName(),
        accountId: profile.id,
        addedAt: this.now(),
      }).then((sealed) => this.approveOwnWrap(sealed, deviceKey, profile.id)),
      deriveKeybagAuthToken(smk, profile.id),
    ])

    const res = await this.httpJson<{ keybag?: SyncKeybag; error?: string }>(
      `${this.config.serverUrl}/v1/sync/keybag/devices`,
      {
        method: 'POST',
        headers: {
          authorization: `Bearer ${token}`,
          'content-type': 'application/json',
        },
        body: JSON.stringify({ wrap, self: true, authToken }),
      },
    )
    if (!res.ok) {
      throw new Error(`Could not register this Mac in the keybag (${res.status})`)
    }

    await this.activateAccountMasterKey(smk, manifest.keybag.keyEpoch, {
      ...manifest,
      keybag: res.body?.keybag ?? manifest.keybag,
    })
    return this.status()
  }

  /** Approves a pending Mac by wrapping our SMK to its X25519 sync public key. */
  async approveDevice(targetDeviceId: string): Promise<SartoSyncStatus> {
    if (!this.masterKey || this.config.mode !== 'account' || !this.accountMatches()) {
      throw new Error('This Mac must hold the sync key before approving another Mac')
    }
    const profile = this.deps.account!.profile()!
    if (!isSyncDeviceId(targetDeviceId)) {
      throw new Error('Invalid sync device id')
    }
    await this.refreshAccountToken()
    const token = this.config.accessToken!

    const listRes = await this.httpJson<{ approvals?: unknown }>(
      `${this.config.serverUrl}/v1/sync/approvals`,
      {
        method: 'GET',
        headers: { authorization: `Bearer ${token}` },
      },
    )
    if (!listRes.ok || !Array.isArray(listRes.body?.approvals)) {
      throw new Error(`Could not read pending approvals (${listRes.status})`)
    }
    const req = (listRes.body.approvals as unknown[])
      .filter(isSyncApprovalRequest)
      .find((entry) => entry.deviceId === targetDeviceId)
    if (!req) {
      await this.refreshPendingApprovals()
      throw new Error('That device is no longer waiting for approval')
    }

    const rawPub = syncBase64UrlDecode(req.devicePublicKey)
    if (
      !rawPub ||
      rawPub.length !== 32 ||
      (await syncDeviceIdFromPublicKey(rawPub)) !== req.deviceId
    ) {
      throw new Error('Pending approval request has a mismatched device key')
    }
    const deviceKey = await this.ensureSyncDeviceKey()
    if (!deviceKey) {
      throw new Error('Keychain is locked; unlock macOS Keychain before approving another Mac')
    }
    // The code shown here is what the user compared; without one, nothing is sealed.
    const code = await this.answerApproval(req, deviceKey, profile.id)
    if (!code) {
      throw new Error(
        req.commitment
          ? 'That Mac has not shown its code yet'
          : 'That Mac runs an earlier version of Sarto: update it, then approve it',
      )
    }

    const wrap = await approveWrap(
      await sealMasterKeyForDevice(this.masterKey, req.devicePublicKey, {
        keyEpoch: this.keyEpoch,
        deviceName: req.deviceName,
        ...(req.oauthDeviceId ? { oauthDeviceId: req.oauthDeviceId } : {}),
        accountId: profile.id,
        addedAt: this.now(),
      }),
      deviceKey.privateKey,
      deviceKey.publicKeyBase64Url,
      profile.id,
    )

    const postRes = await this.httpJson<{ keybag?: unknown; error?: string }>(
      `${this.config.serverUrl}/v1/sync/keybag/devices`,
      {
        method: 'POST',
        headers: {
          authorization: `Bearer ${token}`,
          'content-type': 'application/json',
        },
        body: JSON.stringify({ wrap }),
      },
    )
    if (!postRes.ok) {
      throw new Error(
        `Could not approve device (${postRes.status}: ${postRes.body?.error ?? 'error'})`,
      )
    }

    this.pendingApprovals = this.pendingApprovals.filter((a) => a.deviceId !== targetDeviceId)
    this.emitStatus()
    return this.status()
  }

  /** Rejects a waiting Mac's pending approval request. */
  async rejectDevice(targetDeviceId: string): Promise<SartoSyncStatus> {
    if (this.config.mode !== 'account' || !this.accountMatches()) {
      throw new Error('Not signed in to Sarto Cloud')
    }
    if (!isSyncDeviceId(targetDeviceId)) {
      throw new Error('Invalid sync device id')
    }
    await this.refreshAccountToken()
    const res = await this.httpJson<{ ok?: boolean; error?: string }>(
      `${this.config.serverUrl}/v1/sync/approvals/${targetDeviceId}`,
      {
        method: 'DELETE',
        headers: { authorization: `Bearer ${this.config.accessToken!}` },
      },
    )
    if (!res.ok && res.status !== 404) {
      throw new Error(`Could not reject approval (${res.status})`)
    }
    this.pendingApprovals = this.pendingApprovals.filter((a) => a.deviceId !== targetDeviceId)
    this.emitStatus()
    return this.status()
  }

  /** Removes a device's X25519 key wrap from Keybag v2. */
  async removeDeviceWrap(targetDeviceId: string): Promise<SartoSyncStatus> {
    if (this.config.mode !== 'account' || !this.accountMatches()) {
      throw new Error('Not signed in to Sarto Cloud')
    }
    if (!isSyncDeviceId(targetDeviceId)) {
      throw new Error('Invalid sync device id')
    }
    await this.refreshAccountToken()
    const res = await this.httpJson<{ removed?: boolean; error?: string }>(
      `${this.config.serverUrl}/v1/sync/keybag/devices/${targetDeviceId}`,
      {
        method: 'DELETE',
        headers: { authorization: `Bearer ${this.config.accessToken!}` },
      },
    )
    if (!res.ok) {
      throw new Error(`Could not remove device wrap (${res.status})`)
    }
    this.emitStatus()
    return this.status()
  }

  private async refreshPendingApprovals(known?: SyncApprovalRequest[]): Promise<void> {
    if (this.config.mode !== 'account' || this.keyState !== 'ready' || !this.config.account) {
      if (this.pendingApprovals.length > 0) {
        this.pendingApprovals = []
        this.emitStatus()
      }
      return
    }
    let rawList = known
    if (!rawList && this.config.accessToken) {
      const res = await this.httpJson<{ approvals?: unknown }>(
        `${this.config.serverUrl}/v1/sync/approvals`,
        {
          method: 'GET',
          headers: { authorization: `Bearer ${this.config.accessToken}` },
        },
      ).catch(() => null)
      if (res?.ok && Array.isArray(res.body?.approvals)) {
        rawList = (res.body.approvals as unknown[]).filter(isSyncApprovalRequest)
      }
    }
    if (!rawList) return
    const accountId = this.config.account.id
    const deviceKey = this.syncDeviceKey
    if (!deviceKey) return
    const next: SyncPendingApproval[] = []
    const waiting = new Set<string>()
    for (const req of rawList) {
      if (req.deviceId === deviceKey.deviceId) continue
      waiting.add(req.deviceId)
      const code = await this.answerApproval(req, deviceKey, accountId)
      if (!code) continue
      next.push({
        deviceId: req.deviceId,
        devicePublicKey: req.devicePublicKey,
        deviceName: req.deviceName,
        platform: req.platform,
        code,
        createdAt: req.createdAt,
        expiresAt: req.expiresAt,
      })
    }
    for (const id of this.approvalAnswers.keys()) {
      if (!waiting.has(id)) this.approvalAnswers.delete(id)
    }
    const changed = JSON.stringify(this.pendingApprovals) !== JSON.stringify(next)
    this.pendingApprovals = next
    if (changed) this.emitStatus()
  }

  /**
   * Answers another Mac's request for approval with a nonce of this Mac's, once per commitment,
   * and gives the code both Macs show once that Mac has revealed its nonce. Null while there is no
   * code to show here: before the reveal, when another Mac answered, or for a request from an
   * earlier version, which carries no commitment.
   */
  private async answerApproval(
    req: SyncApprovalRequest,
    deviceKey: SyncDeviceKey,
    accountId: string,
  ): Promise<string | null> {
    if (!req.commitment) return null
    if (req.targetApproverDeviceId && req.targetApproverDeviceId !== deviceKey.deviceId) return null
    if (req.answer && req.answer.approverDeviceId !== deviceKey.deviceId) return null
    let mine = this.approvalAnswers.get(req.deviceId)
    if (mine?.commitment !== req.commitment) mine = undefined
    if (!mine || req.answer?.nonce !== mine.nonce) {
      // A nonce lost with a restart is replaced; the requesting Mac then starts over.
      if (!mine) {
        mine = {
          commitment: req.commitment,
          nonce: syncBase64UrlEncode(crypto.getRandomValues(new Uint8Array(32))),
        }
        this.approvalAnswers.set(req.deviceId, mine)
      }
      await this.postApprovalAnswer(req.deviceId, deviceKey, mine.nonce).catch((error: unknown) => {
        this.deps.log.warn(`Could not answer a Mac's approval request: ${(error as Error).message}`)
      })
      return null
    }
    if (!req.reveal) return null
    if ((await approvalCommitment(req.devicePublicKey, req.reveal)) !== mine.commitment) {
      this.deps.log.warn('A Mac revealed a nonce that does not match its approval request')
      return null
    }
    return approvalCode({
      accountId,
      devicePublicKey: req.devicePublicKey,
      approverPublicKey: deviceKey.publicKeyBase64Url,
      deviceNonce: req.reveal,
      approverNonce: mine.nonce,
    })
  }

  private async postApprovalAnswer(
    deviceId: string,
    deviceKey: SyncDeviceKey,
    nonce: string,
  ): Promise<void> {
    const res = await this.httpJson<{ error?: string }>(
      `${this.config.serverUrl}/v1/sync/approvals/${deviceId}/answer`,
      {
        method: 'POST',
        headers: {
          authorization: `Bearer ${this.config.accessToken!}`,
          'content-type': 'application/json',
        },
        body: JSON.stringify({
          approverDeviceId: deviceKey.deviceId,
          approverPublicKey: deviceKey.publicKeyBase64Url,
          approverName: this.deps.hostName(),
          nonce,
        }),
      },
    )
    if (!res.ok) throw new Error(`${res.status}: ${res.body?.error ?? 'error'}`)
  }

  private stopLoops(): void {
    this.closeStream()
    this.stopApprovalPollLoop()
    if (this.reconcileTimer) {
      clearInterval(this.reconcileTimer)
      this.reconcileTimer = null
    }
    if (this.hostUsageTimer) {
      clearTimeout(this.hostUsageTimer)
      this.hostUsageTimer = null
    }
  }

  /**
   * Looks at the keybag again while this Mac waits: for its approval, or for the account's first
   * keybag, which another Mac may make. A change of state restarts the loop at its own pace.
   */
  private startApprovalPollLoop(): void {
    this.stopApprovalPollLoop()
    const waitingFor = this.keyState
    if (this.stopping || (waitingFor !== 'awaiting-approval' && waitingFor !== 'needs-setup')) {
      return
    }
    const everyMs =
      waitingFor === 'awaiting-approval'
        ? APPROVAL_POLL_MS
        : (this.deps.setupPollMs ?? SETUP_POLL_MS)
    this.approvalPollFor = waitingFor
    this.approvalPollTimer = setInterval(() => {
      if (this.stopping || this.keyState !== waitingFor) {
        this.stopApprovalPollLoop()
        return
      }
      void this.syncAccountKeyState({ pollOnly: true }).catch(() => {})
    }, everyMs)
    this.approvalPollTimer.unref()
  }

  private stopApprovalPollLoop(): void {
    if (this.approvalPollTimer) {
      clearInterval(this.approvalPollTimer)
      this.approvalPollTimer = null
    }
    this.approvalPollFor = null
  }

  /** In `account` mode, the access token every request of a sync run sends, fresh for it. */
  private async refreshAccountToken(): Promise<void> {
    if (this.config.mode !== 'account') return
    const prev = this.config.accessToken
    const token = this.accountMatches() ? await this.deps.account!.token() : null
    if (!token) throw new Error('Not signed in to Sarto Cloud, or it cannot be reached now')
    this.config.accessToken = token
    if (token !== prev && this.streamSocket) {
      try {
        this.streamSocket.send(JSON.stringify({ type: 'token', token }))
      } catch {
        // Closed before send.
      }
    }
  }

  status(): SartoSyncStatus {
    const ownPub = this.deps.hostPublicKey()
    const trustedHosts = Object.values(this.replica.memoryAndMesh.trustedHosts.items)
      .map((entry) => entry.value)
      .filter((host) => !ownPub || host.publicKey !== ownPub)
      .sort((a, b) => a.name.localeCompare(b.name))

    const usageDevices: SyncedUsageDeviceSummary[] = this.logicalUsageRecords()
      .map((rec) => ({
        deviceId: rec.deviceId,
        deviceName: rec.deviceName,
        updatedAt: rec.updatedAt,
        rev: this.replica.usageRevisions[rec.deviceId] ?? 0,
        hasIsland: Boolean(rec.island),
        hasHost: Boolean(rec.host),
      }))
      .sort((a, b) => b.updatedAt - a.updatedAt || a.deviceId.localeCompare(b.deviceId))

    return {
      mode: this.config.mode,
      serverUrl: this.config.serverUrl,
      connected: this.connected,
      syncing: this.syncing,
      lastSyncedAt: this.lastSyncedAt,
      error: this.lastError,
      account: this.config.account,
      relayId: this.computedRelayId,
      relayToken: null,
      needsKey: this.config.mode === 'account' && this.masterKey === null,
      keyState: this.keyState,
      plainText: this.plainTextStorage,
      syncDeviceId: this.syncDeviceKey?.deviceId ?? null,
      approvalCode:
        this.keyState === 'awaiting-approval' ? (this.approvalSession?.code ?? null) : null,
      approvalStage: this.approvalStage(),
      approverName:
        this.keyState === 'awaiting-approval'
          ? (this.approvalSession?.answer?.approverName ?? null)
          : null,
      pendingApprovals: this.keyState === 'ready' ? [...this.pendingApprovals] : [],
      usageDeviceId: this.usageIds.deviceId,
      usageDevices,
      hostPublicKey: ownPub,
      revisions: { ...this.replica.revisions },
      uiPrefs: { ...this.replica.uiPrefs.items },
      trustedHosts,
    }
  }

  async disconnect(): Promise<SartoSyncStatus> {
    if (this.config.mode === 'account') {
      // The account owns this sign-in; signing it out turns the sync off through accountChanged.
      await this.deps.account?.signOut()
      await this.accountChanged()
      return this.status()
    }
    this.stopLoops()
    if (this.pushTimer) {
      clearTimeout(this.pushTimer)
      this.pushTimer = null
    }
    this.dirtyScopeGen.clear()
    this.dirtyUsageGen.clear()
    this.lastMemoryFingerprint = ''
    this.lastSkillsFingerprint = ''
    this.lastHostUsageFingerprint = ''
    this.lastHostUsageCoreFingerprint = ''
    this.lastHostUsageUploadAt = Number.NEGATIVE_INFINITY
    this.preservedMcpVaultEncrypted = null
    this.replica = emptyReplica()
    this.publishMeshHosts()
    this.config = {
      ...this.config,
      mode: 'off',
      accessToken: null,
      accessTokenEncrypted: null,
      relayToken: null,
      relayTokenEncrypted: null,
      account: null,
      masterKeyBase64: null,
      masterKeyEncrypted: null,
    }
    this.masterKey = null
    this.keyState = 'none'
    this.connected = false
    this.lastError = null
    await this.saveConfig()
    await this.saveReplica()
    this.notifyRemoteHostUsage()
    this.emitUsageUpdated()
    this.deps.configureRelay({
      url: 'http://127.0.0.1:9',
      pushUrl: 'http://127.0.0.1:9',
      enabled: false,
      token: null,
      relayToken: null,
      discoverable: false,
    })
    this.emitStatus()
    return this.status()
  }

  async syncNow(): Promise<SartoSyncStatus> {
    if (this.config.mode === 'account' && this.masterKey === null) {
      await this.syncAccountKeyState()
      return this.status()
    }
    if (!this.isConfigured()) return this.status()
    await this.enqueueSync(async () => {
      await this.runFirstSync()
      if (!this.replica.pendingApply) await this.captureLocalMutations('change')
      await this.reconcileWithServer()
    })
    return this.status()
  }

  /**
   * The remote host reported the devices it holds, which it does after the sync's first pass at
   * a start: a device the account deleted meanwhile is unpaired now, not on the next change.
   */
  async pairedDevicesChanged(): Promise<void> {
    if (!this.isConfigured() || !this.masterKey) return
    const ids = (this.deps.pairedDevices?.() ?? [])
      .map((device) => device.id)
      .sort()
      .join(',')
    if (ids === this.reportedDevices) return
    this.reportedDevices = ids
    await this.unpairRemovedDevices()
  }

  private approvalStage(): SartoSyncStatus['approvalStage'] {
    if (this.keyState !== 'awaiting-approval') return null
    const answer = this.approvalSession?.answer
    if (!answer || !this.approvalSession?.code) return 'waiting'
    return this.config.confirmedApprover === answer.approverPublicKey ? 'confirmed' : 'confirm'
  }

  /**
   * The owner removed a device from this Mac's remote host by hand. One the account lists stays
   * removed here, whatever the other Macs keep.
   */
  async deviceRemovedByHand(id: string): Promise<void> {
    if (!(id in this.replica.memoryAndMesh.trustedDevices.items)) return
    const declined = this.config.declinedDevices ?? []
    if (declined.includes(id)) return
    this.config.declinedDevices = [...declined, id]
    await this.saveConfig()
  }

  /** Accepts client UI prefs and device identity from Sarto.app (`usageByMac` was replaced by `sync.putUsage`). */
  async pushClientState(input: {
    uiPrefs?: Record<string, { value: unknown; updatedAt: number }>
    device?: TrustedWorkspaceDevice
  }): Promise<SartoSyncStatus> {
    const by = this.config.nodeId
    const nowMs = this.now()
    let touchedUi = false
    let touchedMesh = false

    if (input.uiPrefs) {
      for (const [key, entry] of Object.entries(input.uiPrefs)) {
        if (!key || typeof entry?.updatedAt !== 'number' || entry.updatedAt < 0) continue
        const before = this.replica.uiPrefs
        this.replica.uiPrefs = putLwwItem(before, key, entry.value, entry.updatedAt, by)
        if (this.replica.uiPrefs !== before) touchedUi = true
      }
    }

    let replacedDevice = false
    if (input.device) {
      // Tied to this install's sync device, so removing that from the keybag unpairs it everywhere.
      const own = this.syncDeviceKey?.deviceId
      const device: TrustedWorkspaceDevice = own
        ? { ...input.device, syncDeviceId: own }
        : input.device
      const before = this.replica.memoryAndMesh.trustedDevices
      let devices = before
      const existing = devices.items[device.id]
      if (!existing || JSON.stringify(existing.value) !== JSON.stringify(device)) {
        devices = putLwwItem(devices, device.id, device, nowMs, by)
      }
      // The install's app has one key: one it published before, which it lost or replaced, is
      // deleted so every Mac unpairs it rather than keeping a device that can never connect.
      // An entry that names no sync device is this install's when this Mac wrote it, as tidyMesh has it.
      for (const [id, entry] of Object.entries(devices.items)) {
        const owner = entry.value.syncDeviceId
        const mine = owner ? owner === own : entry.by === by
        if (id === device.id || !mine) continue
        devices = deleteLwwItem(devices, id, nowMs, by)
        replacedDevice = true
      }
      if (devices !== before) {
        this.replica.memoryAndMesh.trustedDevices = devices
        touchedMesh = true
      }
    }

    if (touchedUi) this.markScopeDirty('ui-prefs')
    if (touchedMesh) this.markScopeDirty('memory-and-mesh')

    await this.saveReplica()
    // This Mac's host unpairs the old key now; the others do once they pull the deletion.
    if (replacedDevice) await this.unpairRemovedDevices()
    if (this.isConfigured() && (touchedUi || touchedMesh)) {
      this.schedulePush()
    }
    this.emitStatus()
    return this.status()
  }

  /**
   * Stores a Mac's `island` usage section into the per-device `usage` keyed scope (preserving any
   * `host` section on the same device record). Accepts another Mac's `deviceId` with `ifOlderOnly`
   * so iCloud Drive device-file import can safely seed historical records without clobbering newer ones.
   */
  async putUsage(input: {
    deviceId?: string
    deviceName?: string
    updatedAt: number
    island: Record<string, unknown>
    ifOlderOnly?: boolean
  }): Promise<SartoSyncStatus> {
    const key = input.deviceId?.trim() || this.usageIds.deviceId
    if (!isSyncItemKey(key)) throw new Error('Invalid usage device id')
    if (!Number.isFinite(input.updatedAt) || input.updatedAt < 0) {
      throw new Error('Invalid usage timestamp')
    }

    const existing = this.replica.usageRecords[key]
    if (input.ifOlderOnly && existing?.island && existing.island.updatedAt >= input.updatedAt) {
      return this.status()
    }

    const deviceName =
      input.deviceName?.trim() ||
      existing?.deviceName ||
      (key === this.usageIds.deviceId ? this.deps.hostName() : key)
    const next: SyncedUsageRecord = {
      v: 1,
      deviceId: key,
      deviceName,
      updatedAt: Math.max(existing?.updatedAt ?? 0, input.updatedAt),
      island: {
        updatedAt: input.updatedAt,
        payload: input.island,
      },
      ...(existing?.host ? { host: existing.host } : {}),
    }

    this.replica.usageRecords[key] = next
    this.markUsageDirty(key)
    await this.saveReplica()
    this.emitUsageUpdated()
    this.emitStatus()

    if (this.isConfigured()) {
      this.schedulePush()
    }
    return this.status()
  }

  /** Deletes another Mac's usage record from the local replica and the sync server. */
  async removeUsage(targetDeviceId: string): Promise<SartoSyncStatus> {
    if (!isSyncItemKey(targetDeviceId)) throw new Error('Invalid usage device id')
    const replica = this.replica
    const checkReplica = (): void => {
      if (replica !== this.replica) throw new Error('The sync account changed during removal')
    }
    const remove = async (): Promise<void> => {
      checkReplica()
      const aliases = usageAliases(Object.values(this.replica.usageRecords), this.usageIds)
      const current = aliases.get(targetDeviceId) ?? targetDeviceId
      if (current === this.usageIds.deviceId)
        throw new Error('Cannot remove this Mac’s own usage record')
      // Delete the record carrying the alias last, so a retry can still find the older key.
      const keys = [...aliases].filter(([, id]) => id === current).map(([key]) => key)
      keys.push(current)
      if (this.isConfigured()) {
        for (const key of keys) {
          checkReplica()
          const res = await this.httpJson<unknown>(
            `${this.config.serverUrl}/v1/sync/scopes/usage/items/${encodeURIComponent(key)}`,
            {
              method: 'DELETE',
              headers: { authorization: `Bearer ${this.config.accessToken}` },
            },
          )
          if (!res.ok && res.status !== 404)
            throw new Error(`Failed to remove usage record (${res.status})`)
        }
      }
      checkReplica()
      for (const key of keys) {
        delete this.replica.usageRecords[key]
        delete this.replica.usageRevisions[key]
        this.dirtyUsageGen.delete(key)
      }
      await this.saveReplica()
      this.notifyRemoteHostUsage()
      this.emitUsageUpdated()
      this.emitStatus()
    }
    if (this.isConfigured()) await this.enqueueSync(remove)
    else await remove()
    return this.status()
  }

  /** Notified when `MarketKeys` changes locally on this daemon. */
  noteMarketKeysChanged(): void {
    if (this.isApplyingRemote || !this.isConfigured()) return
    this.preservedMcpVaultEncrypted = null
    this.captureMcpVaultFromLocal(this.now())
    this.markScopeDirty('mcp-vault')
    this.schedulePush()
  }

  /** Notified when `ThemeStore` changes locally on this daemon. */
  noteThemesChanged(): void {
    if (this.isApplyingRemote || !this.isConfigured()) return
    void this.enqueueSync(async () => {
      await this.captureThemesFromLocal(this.now())
      this.markScopeDirty('themes')
      await this.pushDirtyScopes()
    })
  }

  /** Notified when the agent host records new usage rows or plan limits. */
  noteHostUsageChanged(): void {
    if (this.stopping || !this.isConfigured() || !this.deps.exportHostUsage) return
    if (this.hostUsageTimer) return
    const delay = Math.max(
      HOST_USAGE_DEBOUNCE_MS,
      this.lastHostUsageUploadAt + HOST_USAGE_MIN_INTERVAL_MS - this.now(),
    )
    this.hostUsageTimer = setTimeout(() => {
      this.hostUsageTimer = null
      void this.enqueueSync(async () => {
        const changed = await this.captureHostUsage()
        if (changed) {
          await this.pushDirtyUsageKeys()
          await this.saveReplica()
        }
      }).catch(() => {})
    }, delay)
    this.hostUsageTimer.unref()
  }

  async stop(): Promise<void> {
    this.stopping = true
    for (const unsub of this.unsubscribes.splice(0)) unsub()
    for (const timer of this.localTimers.values()) clearTimeout(timer)
    this.localTimers.clear()
    if (this.pushTimer) clearTimeout(this.pushTimer)
    if (this.hostUsageTimer) clearTimeout(this.hostUsageTimer)
    this.stopLoops()
    await this.syncQueue.catch(() => {})
  }

  // --- Watchers & Lifecycle ---

  private attachLocalWatchers(): void {
    this.unsubscribes.push(
      this.deps.settings.onChange((_, changed) => {
        if (this.isApplyingRemote || !this.isConfigured()) return
        const stamp = this.now()
        if (
          changed.has('general') ||
          changed.has('agents') ||
          changed.has('addedAgents') ||
          changed.has('disabledAgents') ||
          changed.has('git') ||
          changed.has('mcp') ||
          changed.has('startModes') ||
          changed.has('idleSessions') ||
          changed.has('usage')
        ) {
          this.captureHostConfigFromLocal(stamp)
          this.markScopeDirty('host-config')
        }
        if (changed.has('marketplace')) {
          this.captureMcpServersFromLocal(stamp)
          this.markScopeDirty('mcp-servers')
          this.markScopeDirty('skills')
        }
        this.schedulePush()
      }),
    )
  }

  /**
   * Watches the skills and memory folders, whose files change without the settings: an edit inside
   * a skill's folder, or a memory the agent host writes. The reconcile loop reads them as well,
   * should a watch miss a change or not start.
   */
  private async watchLocalFolders(): Promise<void> {
    const folders: Array<[LocalSource, string]> = [
      ['skills', path.join(this.deps.dataPath, 'marketplace', 'skills')],
      ['memory', path.join(this.deps.dataPath, 'memory')],
    ]
    for (const [folder, dir] of folders) {
      await mkdir(dir, { recursive: true }).catch(() => {})
      if (this.stopping) return
      const changed = (): void => this.localChanged(folder)
      let watcher: FSWatcher
      // Node.js runs a recursive watch on Linux in JavaScript, whose lstat of a folder replaced by a
      // file throws out of the event handler, past the 'error' listener, and ends the process. Linux
      // watches the top folder only; the reconcile loop finds the rest.
      const recursive = process.platform !== 'linux'
      try {
        watcher = watch(dir, { recursive, persistent: false }, changed)
      } catch {
        try {
          watcher = watch(dir, { persistent: false }, changed)
        } catch (error) {
          this.deps.log.warn(`Cannot watch ${dir}: ${(error as Error).message}`)
          continue
        }
      }
      watcher.on('error', () => watcher.close())
      this.unsubscribes.push(() => watcher.close())
    }
  }

  /** Follows the agent host's changes to what the sync keeps in it, and its restarts. */
  private followAgentHost(): void {
    const host = this.deps.agentHost
    if (!host) return
    this.unsubscribes.push(
      host.onEvent((event) => {
        if (event === null || this.agentHostEventMatters(event)) this.localChanged('agent-host')
      }),
    )
  }

  private agentHostEventMatters(event: HostEvent): boolean {
    if (event.type !== 'agent.options') return false
    // Most of these are about models offered and used; only a change of pins needs a look.
    const { agentId, pinned } = event.options
    const base = this.replica.localBase.pins[agentId]
    const synced = modelList(this.replica.hostConfig.items[`${PINNED_MODELS}${agentId}`]?.value)
    return !sameModels(pinned, base) || !sameModels(synced, base)
  }

  private localChanged(source: LocalSource): void {
    if (this.stopping || !this.isConfigured()) return
    const pending = this.localTimers.get(source)
    if (pending) clearTimeout(pending)
    const timer = setTimeout(() => {
      this.localTimers.delete(source)
      void this.enqueueSync(async () => {
        if (this.replica.pendingApply) await this.reconcileWithServer()
        if (source === 'skills') await this.captureSkillsIfChanged()
        else if (source === 'memory') await this.captureMemoryAndHostMesh('change')
        else await this.settleAgentHost()
        if (this.dirtyScopeGen.size > 0) await this.pushDirtyScopes()
        await this.saveReplica()
      }).catch(() => {})
    }, this.deps.watchDebounceMs ?? WATCH_DEBOUNCE_MS)
    timer.unref()
    this.localTimers.set(source, timer)
  }

  /** Packs the skills again only when their folder or their list changed since the last time. */
  private async captureSkillsIfChanged(): Promise<void> {
    const fingerprint = `${await skillsFolderFingerprint(this.deps.dataPath)}:${JSON.stringify(
      this.deps.settings.get().marketplace.skills,
    )}`
    if (fingerprint === this.lastSkillsFingerprint) return
    if (await this.captureSkillsFromLocal(this.now())) this.lastSkillsFingerprint = fingerprint
  }

  private enableRelayInSettings(): void {
    this.isApplyingRemote = true
    try {
      this.deps.settings.update({
        remote: {
          enabled: true,
          relay: true,
          discoverable: true,
          direct: { enabled: false },
        },
      })
    } finally {
      this.isApplyingRemote = false
    }
  }

  private startReconcileLoop(): void {
    if (this.reconcileTimer) clearInterval(this.reconcileTimer)
    this.reconcileTimer = setInterval(() => {
      if (!this.isConfigured() || this.stopping) return
      void this.enqueueSync(async () => {
        await this.runFirstSync()
        if (!this.replica.pendingApply) {
          await this.captureMemoryAndHostMesh('change')
          await this.captureSkillsIfChanged()
          await this.settleAgentHost()
        }
        await this.reconcileWithServer()
        if (!this.streamSocket && !this.wsReconnectTimer) {
          this.connectStream()
        }
      }).catch(() => {})
    }, RECONCILE_INTERVAL_MS)
    this.reconcileTimer.unref()
  }

  private schedulePush(): void {
    if (!this.isConfigured() || this.stopping) return
    if (this.pushTimer) clearTimeout(this.pushTimer)
    this.pushTimer = setTimeout(() => {
      this.pushTimer = null
      void this.enqueueSync(async () => {
        if (this.dirtyScopeGen.has('skills')) {
          await this.captureSkillsFromLocal(this.now())
        }
        if (this.dirtyScopeGen.size > 0) {
          await this.pushDirtyScopes()
        }
        if (this.dirtyUsageGen.size > 0) {
          await this.pushDirtyUsageKeys()
        }
        await this.saveReplica()
      }).catch(() => {})
    }, PUSH_DEBOUNCE_MS)
    this.pushTimer.unref()
  }

  private enqueueSync(task: () => Promise<void>): Promise<void> {
    const next = this.syncQueue
      .catch(() => {})
      .then(async () => {
        if (this.stopping) return
        this.syncing = true
        this.emitStatus()
        try {
          await this.refreshAccountToken()
          await task()
          this.connected = this.isConfigured()
          this.lastSyncedAt = this.now()
          this.lastError = null
        } catch (error) {
          this.lastError = (error as Error).message
          this.deps.log.warn(`Sarto sync error: ${this.lastError}`)
          throw error
        } finally {
          this.syncing = false
          this.emitStatus()
        }
      })
    this.syncQueue = next.catch(() => {})
    return next
  }

  // --- Bootstrap, Pull, Merge & Push ---

  private async bootstrapWorkspace(manifest: SyncManifest): Promise<void> {
    const hasRemoteScopes = Object.keys(manifest.scopes).length > 0
    if (hasRemoteScopes) {
      // Joining an account that has data: this Mac's own setup goes in as older than anything the
      // account holds, so the merge keeps what only this Mac has, while the account's copy of the
      // same item and its deletions win.
      const ownAgents = portableAddedAgents(this.deps.settings.get().addedAgents)
      if (!this.replica.pendingApply) await this.captureLocalMutations('join')
      await this.mergeChangedScopes(manifest)
      this.keepOwnAddedAgents(ownAgents)
      await this.applyReplicaToLocalRuntime()
      await this.pullChangedUsageItems(manifest)
      await this.captureMemoryAndHostMesh('change')
      await this.captureHostUsage()
      for (const scope of SYNC_SCOPES) this.markScopeDirty(scope)
      await this.pushDirtyScopes()
      await this.pushDirtyUsageKeys()
    } else {
      // Brand-new workspace: seed every scope and this Mac's usage from this Mac's current setup.
      await this.pullChangedUsageItems(manifest)
      await this.captureLocalMutations('initial')
      for (const scope of SYNC_SCOPES) this.markScopeDirty(scope)
      await this.pushDirtyScopes()
      await this.pushDirtyUsageKeys()
    }
    await this.saveReplica()
  }

  /**
   * The added agents are one list in host-config, so the account's list wins whole: the agents
   * only this Mac had join it, under a new stamp that carries them to the other Macs.
   */
  private keepOwnAddedAgents(own: readonly PortableAddedAgent[]): void {
    const synced = this.replica.hostConfig.items.addedAgents?.value
    const list = Array.isArray(synced) ? (synced as PortableAddedAgent[]) : []
    const missing = own.filter((agent) => !list.some((each) => each.id === agent.id))
    if (missing.length === 0) return
    this.replica.hostConfig = putLwwItem(
      this.replica.hostConfig,
      'addedAgents',
      [...list, ...missing],
      this.now(),
      this.config.nodeId,
    )
  }

  private async reconcileWithServer(): Promise<void> {
    if (!this.isConfigured()) return
    const manifest = await this.fetchManifest(this.config.serverUrl, this.config.accessToken!)
    if (this.config.mode === 'account' && this.masterKey !== null && manifest.keybag === null) {
      // The keybag this Mac's key came from is gone: the account's sync was reset while this Mac
      // did not hear of it. Nothing sealed with the old key may go back up.
      await this.syncWasReset()
      return
    }
    if (
      this.config.mode === 'account' &&
      this.syncDeviceKey &&
      isSyncKeybagV2(manifest.keybag) &&
      !manifest.keybag.devices.some((d) => d.deviceId === this.syncDeviceKey!.deviceId)
    ) {
      await this.revokeLocalMasterKey('This Mac was removed from encrypted sync')
      return
    }
    await this.pullChangedScopes(manifest)
    const tidied = this.tidyMesh(manifest.keybag)
    if (tidied.devicesChanged) await this.unpairRemovedDevices()
    if (tidied.hostsChanged) this.publishMeshHosts()
    await this.pullChangedUsageItems(manifest)
    await this.refreshPendingApprovals(manifest.pendingApprovals)
    await this.registerOwnHostInMesh()
    await this.captureHostUsage()
    await this.pushDirtyScopes()
    await this.pushDirtyUsageKeys()
    await this.removeUnreferencedBlobs()
    await this.saveReplica()
  }

  /** The account's sync was reset on the server (PROTOCOL.md section 4.4): start over. */
  private async syncWasReset(): Promise<void> {
    const link = this.deps.account
    const profile = link?.profile()
    if (!link || !profile || this.config.mode !== 'account' || !this.accountMatches()) return
    this.deps.log.info('Encrypted sync was reset on the server; forgetting the sync key')
    await this.startOver(profile, link.origin(), 'Encrypted sync was reset in Sarto Cloud')
  }

  /**
   * Removes the skill blobs this Mac knows of that no skill in the account refers to any more, once
   * the skills it changed are on the server (PROTOCOL.md section 4.3), so they stop counting
   * against the quota.
   */
  private async removeUnreferencedBlobs(): Promise<void> {
    if (!this.masterKey || !this.config.accessToken || this.dirtyScopeGen.has('skills')) return
    const referenced = new Set<string>()
    for (const entry of Object.values(this.replica.skills.items)) {
      const sha = entry.value.archive?.blobSha256
      if (sha) referenced.add(sha)
    }
    const f = this.deps.fetchImpl ?? fetch
    for (const [contentHash, archive] of Object.entries(this.replica.blobCache)) {
      if (referenced.has(archive.blobSha256) || !isSha256Hex(archive.blobSha256)) continue
      const res = await f(
        `${this.config.serverUrl}/v1/sync/blobs/${archive.blobSha256}`,
        withRequestDefaults({
          method: 'DELETE',
          headers: { authorization: `Bearer ${this.config.accessToken}` },
        }),
      ).catch(() => null)
      // 404: the server holds no blob by that hash, as after another Mac removed it.
      if (res && (res.status === 204 || res.status === 404)) {
        delete this.replica.blobCache[contentHash]
      }
    }
  }

  private async pullChangedScopes(manifest: SyncManifest): Promise<void> {
    await this.mergeChangedScopes(manifest)
    if (this.replica.pendingApply) {
      await this.applyReplicaToLocalRuntime()
      await this.saveReplica()
    }
  }

  /** Merges each newer server revision and marks the replica for local application. */
  private async mergeChangedScopes(manifest: SyncManifest): Promise<void> {
    if (!this.masterKey || !this.config.accessToken) return
    for (const scope of SYNC_SCOPES) {
      const remoteMeta = manifest.scopes[scope]
      const localRev = this.replica.revisions[scope] ?? 0
      if (!remoteMeta || remoteMeta.rev <= localRev) continue
      const pulled = await this.fetchScopeRecord(scope)
      if (!pulled) continue
      await this.mergeRemoteScopeRecord(pulled)
    }
  }

  private async pullChangedUsageItems(manifest: SyncManifest): Promise<void> {
    if (!this.masterKey || !this.config.accessToken) return
    const remoteItems = manifest.items?.usage ?? {}
    let changed = false

    for (const [key, meta] of Object.entries(remoteItems)) {
      const localRev = this.replica.usageRevisions[key] ?? 0
      if (meta.rev <= localRev) continue
      const pulled = await this.fetchUsageItem(key)
      if (!pulled) continue
      await this.mergeRemoteUsageItem(pulled)
      changed = true
    }

    // Drop remote usage records deleted on the server (keep our own dirty record if any).
    for (const localKey of Object.keys(this.replica.usageRecords)) {
      if (
        localKey !== this.usageIds.deviceId &&
        !this.dirtyUsageGen.has(localKey) &&
        !Object.hasOwn(remoteItems, localKey)
      ) {
        delete this.replica.usageRecords[localKey]
        delete this.replica.usageRevisions[localKey]
        changed = true
      }
    }

    if (changed) {
      this.notifyRemoteHostUsage()
      this.emitUsageUpdated()
      await this.saveReplica()
    }
  }

  private async mergeRemoteUsageItem(record: SyncItemRecord): Promise<void> {
    if (!this.masterKey) return
    const currentRev = this.replica.usageRevisions[record.key] ?? 0
    if (!isValidRevision(record.rev) || record.rev < currentRev) return
    const remote = await openItemJson<SyncedUsageRecord>(
      this.masterKey,
      'usage',
      record.key,
      record.rev,
      record.envelope,
    )
    const existing = this.replica.usageRecords[record.key]
    this.replica.usageRecords[record.key] = mergeUsageRecords(existing, {
      ...remote,
      deviceId: record.key,
    })
    this.replica.usageRevisions[record.key] = Math.max(currentRev, record.rev)
  }

  private async mergeRemoteScopeRecord(record: SyncScopeRecord): Promise<void> {
    if (!this.masterKey) return
    const currentRev = this.replica.revisions[record.scope] ?? 0
    if (!isValidRevision(record.rev) || record.rev < currentRev) return
    const nowMs = this.now()
    switch (record.scope) {
      case 'ui-prefs': {
        const remote = await openScopeJson<UiPrefsScopeDoc>(
          this.masterKey,
          'ui-prefs',
          record.rev,
          record.envelope,
        )
        this.replica.uiPrefs = mergeLwwMaps(this.replica.uiPrefs, remote, nowMs)
        break
      }
      case 'host-config': {
        const remote = await openScopeJson<HostConfigScopeDoc>(
          this.masterKey,
          'host-config',
          record.rev,
          record.envelope,
        )
        this.replica.hostConfig = withoutRetiredKeys(
          mergeLwwMaps(this.replica.hostConfig, remote, nowMs),
        )
        break
      }
      case 'mcp-servers': {
        const remote = await openScopeJson<McpServersScopeDoc>(
          this.masterKey,
          'mcp-servers',
          record.rev,
          record.envelope,
        )
        this.replica.mcpServers = mergeLwwMaps(this.replica.mcpServers, remote, nowMs)
        break
      }
      case 'mcp-vault': {
        const remote = await openScopeJson<McpVaultScopeDoc>(
          this.masterKey,
          'mcp-vault',
          record.rev,
          record.envelope,
        )
        this.preservedMcpVaultEncrypted = null
        this.replica.mcpVault = {
          values: mergeLwwMaps(this.replica.mcpVault.values, remote.values, nowMs),
          oauth: mergeLwwMaps(this.replica.mcpVault.oauth, remote.oauth, nowMs),
          agentEnv: mergeLwwMaps(this.replica.mcpVault.agentEnv, remote.agentEnv, nowMs),
        }
        break
      }
      case 'skills': {
        const remote = await openScopeJson<SkillsScopeDoc>(
          this.masterKey,
          'skills',
          record.rev,
          record.envelope,
        )
        this.replica.skills = mergeLwwMaps(this.replica.skills, remote, nowMs)
        break
      }
      case 'themes': {
        const remote = await openScopeJson<ThemesScopeDoc>(
          this.masterKey,
          'themes',
          record.rev,
          record.envelope,
        )
        this.replica.themes = mergeLwwMaps(this.replica.themes, remote, nowMs)
        break
      }
      case 'memory-and-mesh': {
        const remote = await openScopeJson<MemoryAndMeshScopeDoc>(
          this.masterKey,
          'memory-and-mesh',
          record.rev,
          record.envelope,
        )
        this.replica.memoryAndMesh = {
          memoryEnabled: mergeLwwMaps(
            this.replica.memoryAndMesh.memoryEnabled,
            remote.memoryEnabled ?? emptyLwwMap(),
            nowMs,
          ),
          memories: mergeLwwMaps(
            this.replica.memoryAndMesh.memories,
            remote.memories ?? emptyLwwMap(),
            nowMs,
          ),
          trustedHosts: mergeLwwMaps(
            this.replica.memoryAndMesh.trustedHosts,
            remote.trustedHosts ?? emptyLwwMap(),
            nowMs,
          ),
          trustedDevices: mergeLwwMaps(
            this.replica.memoryAndMesh.trustedDevices,
            remote.trustedDevices ?? emptyLwwMap(),
            nowMs,
          ),
        }
        break
      }
    }
    this.replica.revisions[record.scope] = Math.max(currentRev, record.rev)
    this.replica.pendingApply = true
  }

  private scopePayload(scope: SyncScope): unknown {
    switch (scope) {
      case 'ui-prefs':
        return this.replica.uiPrefs
      case 'host-config':
        return this.replica.hostConfig
      case 'mcp-servers':
        return this.replica.mcpServers
      case 'mcp-vault':
        return this.replica.mcpVault
      case 'skills':
        return this.replica.skills
      case 'themes':
        return this.replica.themes
      case 'memory-and-mesh':
        return this.replica.memoryAndMesh
    }
  }

  private async pushDirtyScopes(): Promise<void> {
    if (!this.isConfigured() || !this.masterKey || !this.config.accessToken) return
    const entries = [...this.dirtyScopeGen.entries()]
    for (const [scope, gen] of entries) {
      await this.pushSingleScopeWithRetry(scope)
      if (this.dirtyScopeGen.get(scope) === gen) {
        this.dirtyScopeGen.delete(scope)
      }
    }
  }

  private async pushSingleScopeWithRetry(scope: SyncScope): Promise<void> {
    if (!this.masterKey || !this.config.accessToken) return
    for (let attempt = 0; attempt < 4; attempt++) {
      const baseRev = this.replica.revisions[scope] ?? 0
      const nextRev = baseRev + 1
      const envelope = await sealScopeJson(
        this.masterKey,
        scope,
        nextRev,
        this.scopePayload(scope),
        {
          keyEpoch: this.keyEpoch,
        },
      )
      const res = await this.httpJson<{
        rev?: number
        error?: string
        current?: SyncScopeRecord | null
      }>(`${this.config.serverUrl}/v1/sync/scopes/${scope}`, {
        method: 'PUT',
        headers: {
          authorization: `Bearer ${this.config.accessToken}`,
          'content-type': 'application/json',
        },
        body: JSON.stringify({
          baseRev,
          updatedBy: this.config.nodeId,
          envelope,
        }),
      })

      if (res.ok && isValidRevision(res.body?.rev) && res.body.rev >= baseRev) {
        this.replica.revisions[scope] = res.body.rev
        return
      }

      if (
        res.status === 409 &&
        res.body?.current &&
        res.body.current.scope === scope &&
        isValidRevision(res.body.current.rev) &&
        res.body.current.rev >= (this.replica.revisions[scope] ?? 0) &&
        isEncryptedSyncEnvelope(res.body.current.envelope)
      ) {
        await this.mergeRemoteScopeRecord(res.body.current)
        await this.applyReplicaToLocalRuntime()
        continue
      }

      throw new Error(`Failed to push scope "${scope}" (${res.status})`)
    }
  }

  private async pushDirtyUsageKeys(): Promise<void> {
    if (!this.isConfigured() || !this.masterKey || !this.config.accessToken) return
    const entries = [...this.dirtyUsageGen.entries()]
    for (const [key, gen] of entries) {
      await this.pushSingleUsageItemWithRetry(key)
      if (this.dirtyUsageGen.get(key) === gen) {
        this.dirtyUsageGen.delete(key)
      }
    }
  }

  private async pushSingleUsageItemWithRetry(key: string): Promise<void> {
    if (!this.masterKey || !this.config.accessToken) return
    for (let attempt = 0; attempt < 4; attempt++) {
      const payload = this.replica.usageRecords[key]
      if (!payload) return
      const baseRev = this.replica.usageRevisions[key] ?? 0
      const nextRev = baseRev + 1
      const envelope = await sealItemJson(this.masterKey, 'usage', key, nextRev, payload, {
        compress: true,
        keyEpoch: this.keyEpoch,
      })
      const res = await this.httpJson<{
        rev?: number
        error?: string
        current?: SyncItemRecord | null
        currentRev?: number
      }>(`${this.config.serverUrl}/v1/sync/scopes/usage/items/${encodeURIComponent(key)}`, {
        method: 'PUT',
        headers: {
          authorization: `Bearer ${this.config.accessToken}`,
          'content-type': 'application/json',
        },
        body: JSON.stringify({
          baseRev,
          updatedBy: this.config.nodeId,
          envelope,
        }),
      })

      if (res.ok && isValidRevision(res.body?.rev) && res.body.rev >= baseRev) {
        this.replica.usageRevisions[key] = res.body.rev
        return
      }

      if (res.status === 409) {
        const current = res.body?.current
        if (
          current &&
          current.scope === 'usage' &&
          current.key === key &&
          isValidRevision(current.rev) &&
          current.rev >= (this.replica.usageRevisions[key] ?? 0) &&
          isEncryptedSyncEnvelope(current.envelope)
        ) {
          const remotePlain = await openItemJson<SyncedUsageRecord>(
            this.masterKey,
            'usage',
            key,
            current.rev,
            current.envelope,
          )
          const normalizedRemote: SyncedUsageRecord = { ...remotePlain, deviceId: key }
          const merged = mergeUsageRecords(this.replica.usageRecords[key], normalizedRemote)
          this.replica.usageRecords[key] = merged
          this.replica.usageRevisions[key] = Math.max(
            this.replica.usageRevisions[key] ?? 0,
            current.rev,
          )
          if (JSON.stringify(merged) === JSON.stringify(normalizedRemote)) {
            return
          }
          continue
        }
        if (res.body?.current === null && isValidRevision(res.body?.currentRev)) {
          if (key !== this.usageIds.deviceId) {
            delete this.replica.usageRecords[key]
            delete this.replica.usageRevisions[key]
            return
          }
          this.replica.usageRevisions[key] = res.body.currentRev
          continue
        }
      }

      throw new Error(`Failed to push usage item "${key}" (${res.status})`)
    }
  }

  // --- Local Capture (Host -> CRDT Replica) ---

  private async captureLocalMutations(mode: CaptureMode): Promise<void> {
    const stamp = mode === 'join' ? JOIN_STAMP : this.now()
    this.captureHostConfigFromLocal(stamp)
    this.captureMcpServersFromLocal(stamp)
    this.captureMcpVaultFromLocal(stamp)
    // Packing reads every skill's files; a change sync packs them only when the folder changed.
    if (mode === 'change') await this.captureSkillsIfChanged()
    else await this.captureSkillsFromLocal(stamp)
    await this.captureThemesFromLocal(stamp)
    await this.captureMemoryAndHostMesh(mode)
    // A joining Mac's own items in the agent host settle once the account's are merged.
    if (mode !== 'join') await this.settleAgentHost()
    if (mode === 'initial') await this.captureHostUsage()
  }

  /** Captures this Mac's daemon usage (`host` section) into its `usage` keyed record when changed. */
  private async captureHostUsage(): Promise<boolean> {
    if (!this.deps.exportHostUsage) return false
    const exported = await this.deps.exportHostUsage().catch((error: unknown) => {
      this.deps.log.warn(`Could not export host usage: ${(error as Error).message}`)
      return null
    })
    if (!exported) return false

    // Fingerprint without `updatedAt` so identical buckets/plans don't trigger redundant uploads.
    const coreFp = createHash('sha256')
      .update(
        JSON.stringify({
          fromComputer: exported.fromComputer,
          computerSources: exported.computerSources,
          buckets: exported.buckets,
          plans: exported.plans ?? null,
          quotas: exported.quotas ?? null,
        }),
      )
      .digest('hex')
    const fp = createHash('sha256')
      .update(coreFp)
      .update(
        JSON.stringify({
          quotaHistory: exported.quotaHistory ?? null,
          activity: exported.activity ?? null,
        }),
      )
      .digest('hex')
    const existing = this.replica.usageRecords[this.usageIds.deviceId]
    if (fp === this.lastHostUsageFingerprint && existing?.host) return false
    // A quota reading or a request alone changes these each few minutes, even on an idle Mac; they
    // go along with the next other change, or on their own once in a while.
    if (
      coreFp === this.lastHostUsageCoreFingerprint &&
      existing?.host &&
      this.now() - this.lastHostUsageUploadAt < HOST_USAGE_AUX_INTERVAL_MS
    ) {
      return false
    }
    this.lastHostUsageFingerprint = fp
    this.lastHostUsageCoreFingerprint = coreFp
    this.lastHostUsageUploadAt = this.now()

    const updatedAt = Math.max(this.now(), exported.updatedAt)
    const next: SyncedUsageRecord = {
      v: 1,
      deviceId: this.usageIds.deviceId,
      deviceName: this.deps.hostName(),
      updatedAt: Math.max(existing?.updatedAt ?? 0, updatedAt),
      ...(existing?.island ? { island: existing.island } : {}),
      host: { ...exported, updatedAt, previousDeviceId: this.usageIds.previousDeviceId },
    }
    this.replica.usageRecords[this.usageIds.deviceId] = next
    this.markUsageDirty(this.usageIds.deviceId)
    return true
  }

  private captureHostConfigFromLocal(stamp: number): void {
    const s = this.deps.settings.get()
    const by = this.config.nodeId
    const fields: Record<string, unknown> = {
      sessionTitles: s.general.sessionTitles,
      lightModel: s.general.lightModel,
      defaultAgent: s.general.defaultAgent,
      agents: portableHarnesses(s.agents),
      addedAgents: portableAddedAgents(s.addedAgents),
      disabledAgents: s.disabledAgents,
      gitBackgroundFetch: s.git.backgroundFetch,
      mcpSartoOff: s.mcp.sarto.off,
      startModes: s.startModes,
      idleSessions: s.idleSessions,
      usageFromComputer: s.usage.fromComputer,
    }
    for (const [k, val] of Object.entries(fields)) {
      const cur = this.replica.hostConfig.items[k]
      if (!cur || JSON.stringify(cur.value) !== JSON.stringify(val)) {
        this.replica.hostConfig = putLwwItem(this.replica.hostConfig, k, val, stamp, by)
      }
    }
  }

  private captureMcpServersFromLocal(stamp: number): void {
    const servers = this.deps.settings.get().marketplace.mcp
    const by = this.config.nodeId
    const presentIds = new Set(servers.map((s) => s.id))
    for (const server of servers) {
      const cur = this.replica.mcpServers.items[server.id]
      if (!cur || JSON.stringify(cur.value) !== JSON.stringify(server)) {
        this.replica.mcpServers = putLwwItem(this.replica.mcpServers, server.id, server, stamp, by)
      }
    }
    for (const existingId of Object.keys(this.replica.mcpServers.items)) {
      if (!presentIds.has(existingId)) {
        this.replica.mcpServers = deleteLwwItem(this.replica.mcpServers, existingId, stamp, by)
      }
    }
  }

  private captureMcpVaultFromLocal(stamp: number): void {
    const contents = this.deps.marketKeys.contentsForHost()
    const by = this.config.nodeId

    const seenValues = new Set<string>()
    for (const [serverId, inputs] of Object.entries(contents.values)) {
      for (const [inputName, secretVal] of Object.entries(inputs)) {
        const composite = `${serverId}\u0000${inputName}`
        seenValues.add(composite)
        const cur = this.replica.mcpVault.values.items[composite]
        if (!cur || cur.value !== secretVal) {
          this.replica.mcpVault.values = putLwwItem(
            this.replica.mcpVault.values,
            composite,
            secretVal,
            stamp,
            by,
          )
        }
      }
    }
    for (const key of Object.keys(this.replica.mcpVault.values.items)) {
      if (!seenValues.has(key)) {
        this.replica.mcpVault.values = deleteLwwItem(this.replica.mcpVault.values, key, stamp, by)
      }
    }

    const seenOAuth = new Set<string>()
    for (const [serverId, oauthJson] of Object.entries(contents.oauth)) {
      seenOAuth.add(serverId)
      const cur = this.replica.mcpVault.oauth.items[serverId]
      if (!cur || cur.value !== oauthJson) {
        this.replica.mcpVault.oauth = putLwwItem(
          this.replica.mcpVault.oauth,
          serverId,
          oauthJson,
          stamp,
          by,
        )
      }
    }
    for (const key of Object.keys(this.replica.mcpVault.oauth.items)) {
      if (!seenOAuth.has(key)) {
        this.replica.mcpVault.oauth = deleteLwwItem(this.replica.mcpVault.oauth, key, stamp, by)
      }
    }

    const seenEnv = new Set<string>()
    for (const [agentId, vars] of Object.entries(contents.agentEnv)) {
      for (const [varName, val] of Object.entries(vars)) {
        const composite = `${agentId}\u0000${varName}`
        seenEnv.add(composite)
        const cur = this.replica.mcpVault.agentEnv.items[composite]
        if (!cur || cur.value !== val) {
          this.replica.mcpVault.agentEnv = putLwwItem(
            this.replica.mcpVault.agentEnv,
            composite,
            val,
            stamp,
            by,
          )
        }
      }
    }
    for (const key of Object.keys(this.replica.mcpVault.agentEnv.items)) {
      if (!seenEnv.has(key)) {
        this.replica.mcpVault.agentEnv = deleteLwwItem(
          this.replica.mcpVault.agentEnv,
          key,
          stamp,
          by,
        )
      }
    }
  }

  /** False when it cannot read them now, without the key or a token. */
  private async captureSkillsFromLocal(stamp: number): Promise<boolean> {
    if (!this.masterKey || !this.config.accessToken) return false
    const skills = this.deps.settings.get().marketplace.skills
    const by = this.config.nodeId
    const presentIds = new Set(skills.map((s) => s.id))

    for (const skill of skills) {
      let archive: SyncedSkillArchive | null = null
      const packed = await packSkillDirectory(this.deps.dataPath, skill.id, skill.name).catch(
        () => null,
      )
      if (packed) {
        let cached: SyncedSkillArchive | undefined = this.replica.blobCache[packed.contentHash]
        // Another Mac removes a blob once no skill refers to it: one this skill comes back to may
        // be gone, and is sealed and uploaded again.
        if (
          cached &&
          this.replica.skills.items[skill.id]?.value.archive?.blobSha256 !== cached.blobSha256 &&
          !(await this.blobOnServer(cached.blobSha256))
        ) {
          delete this.replica.blobCache[packed.contentHash]
          cached = undefined
        }
        if (cached) {
          archive = cached
        } else {
          const sealed = await sealSyncBlob(this.masterKey, packed.compressed)
          await this.uploadBlobIfMissing(sealed.blobSha256, sealed.ciphertext)
          archive = {
            blobSha256: sealed.blobSha256,
            iv: sealed.iv,
            contentHash: packed.contentHash,
            byteLength: sealed.ciphertext.byteLength,
          }
          this.replica.blobCache[packed.contentHash] = archive
        }
      }

      const item: SyncedSkillItem = { skill, archive }
      const cur = this.replica.skills.items[skill.id]
      if (!cur || JSON.stringify(cur.value) !== JSON.stringify(item)) {
        this.replica.skills = putLwwItem(this.replica.skills, skill.id, item, stamp, by)
        this.markScopeDirty('skills')
      }
    }

    for (const existingId of Object.keys(this.replica.skills.items)) {
      if (!presentIds.has(existingId)) {
        this.replica.skills = deleteLwwItem(this.replica.skills, existingId, stamp, by)
        this.markScopeDirty('skills')
      }
    }
    return true
  }

  private async captureThemesFromLocal(stamp: number): Promise<void> {
    const themesDir = path.join(this.deps.dataPath, 'themes')
    const names = await readdir(themesDir).catch(() => [] as string[])
    const by = this.config.nodeId
    const seen = new Set<string>()

    for (const fileName of names) {
      if (!fileName.endsWith('.json')) continue
      const id = fileName.slice(0, -5)
      if (!THEME_ID.test(id) || id === BUILTIN_THEME_ID) continue
      const text = await readFile(path.join(themesDir, fileName), 'utf8').catch(() => null)
      if (!text || !checkThemeText(text).ok) continue
      seen.add(id)
      const item: SyncedThemeItem = { id, text }
      const cur = this.replica.themes.items[id]
      if (!cur || JSON.stringify(cur.value) !== JSON.stringify(item)) {
        this.replica.themes = putLwwItem(this.replica.themes, id, item, stamp, by)
      }
    }

    for (const existingId of Object.keys(this.replica.themes.items)) {
      if (!seen.has(existingId)) {
        this.replica.themes = deleteLwwItem(this.replica.themes, existingId, stamp, by)
      }
    }
  }

  private async captureMemoryAndHostMesh(mode: CaptureMode): Promise<void> {
    const by = this.config.nodeId
    const now = this.now()
    const stamp = mode === 'join' ? JOIN_STAMP : now
    const force = mode !== 'change'
    const memRoot = path.join(this.deps.dataPath, 'memory')
    const globalDir = path.join(memRoot, 'global')

    // 1. Memory enabled flag
    const memSettings = await readJsonFile(path.join(memRoot, 'settings.json'))
    // Memory is on until the file says otherwise, which is the user's choice.
    const chosen =
      memSettings.kind === 'ok' &&
      typeof (memSettings.value as { enabled?: unknown })?.enabled === 'boolean'
    const enabled = chosen ? Boolean((memSettings.value as { enabled: boolean }).enabled) : true
    const curEnabled = this.replica.memoryAndMesh.memoryEnabled.items.enabled
    if (force || (curEnabled ? curEnabled.value !== enabled : chosen)) {
      const before = this.replica.memoryAndMesh.memoryEnabled
      this.replica.memoryAndMesh.memoryEnabled = putLwwItem(before, 'enabled', enabled, stamp, by)
      if (this.replica.memoryAndMesh.memoryEnabled !== before)
        this.markScopeDirty('memory-and-mesh')
    }

    // 2. Global memory markdown entries
    const files = await readdir(globalDir).catch(() => null)
    if (!files) {
      await this.registerOwnHostInMesh()
      return
    }
    const entries: SyncedMemoryItem[] = []
    const seenIds = new Set<string>()
    for (const file of files) {
      if (file === 'MEMORY.md' || !file.endsWith('.md')) continue
      const id = file.slice(0, -3)
      if (!MEMORY_ID.test(id)) continue
      seenIds.add(id)
      const text = await readFile(path.join(globalDir, file), 'utf8').catch(() => null)
      if (!text) continue
      const parsed = parseEntry(id, text)
      const createdAt = parsed.created ?? now
      const updatedAt = parsed.updated ?? createdAt
      entries.push({
        id,
        title: parsed.entry.title,
        description: parsed.entry.description,
        body: parsed.entry.body,
        createdAt,
        updatedAt,
        agentId: parsed.entry.source.agentId,
        sessionId: parsed.entry.source.sessionId,
      })
    }

    const fp = JSON.stringify([entries, [...seenIds]])
    if (force || fp !== this.lastMemoryFingerprint) {
      this.lastMemoryFingerprint = fp
      for (const item of entries) {
        const cur = this.replica.memoryAndMesh.memories.items[item.id]
        if (!cur || JSON.stringify(cur.value) !== JSON.stringify(item)) {
          const before = this.replica.memoryAndMesh.memories
          this.replica.memoryAndMesh.memories = putLwwItem(
            before,
            item.id,
            item,
            mode === 'join' ? JOIN_STAMP : Math.max(item.updatedAt, stamp),
            by,
          )
          if (this.replica.memoryAndMesh.memories !== before) this.markScopeDirty('memory-and-mesh')
        }
      }
      if (!force) {
        for (const existingId of Object.keys(this.replica.memoryAndMesh.memories.items)) {
          if (!seenIds.has(existingId)) {
            this.replica.memoryAndMesh.memories = deleteLwwItem(
              this.replica.memoryAndMesh.memories,
              existingId,
              stamp,
              by,
            )
            this.markScopeDirty('memory-and-mesh')
          }
        }
      }
    }

    await this.registerOwnHostInMesh()
  }

  private async registerOwnHostInMesh(): Promise<void> {
    const pub = this.deps.hostPublicKey()
    if (!pub) return
    const id = await deviceId(Buffer.from(pub, 'base64'))
    const own = this.syncDeviceKey?.deviceId
    const by = this.config.nodeId
    const hostRecord: TrustedWorkspaceHost = {
      id,
      name: this.deps.hostName(),
      platform: process.platform,
      publicKey: pub,
      relayId: this.computedRelayId,
      relayUrl: this.config.serverUrl || null,
      ...(own ? { syncDeviceId: own } : {}),
    }
    const before = this.replica.memoryAndMesh.trustedHosts
    let hosts = before
    const cur = hosts.items[id]
    if (!cur || JSON.stringify(cur.value) !== JSON.stringify(hostRecord)) {
      hosts = putLwwItem(hosts, id, hostRecord, this.now(), by)
    }
    // This Mac's host under an earlier key, as before its remote access was reset, is gone.
    for (const [otherId, entry] of Object.entries(hosts.items)) {
      if (otherId !== id && (entry.by === by || (own && entry.value.syncDeviceId === own))) {
        hosts = deleteLwwItem(hosts, otherId, this.now(), by)
      }
    }
    if (hosts !== before) {
      this.replica.memoryAndMesh.trustedHosts = hosts
      this.markScopeDirty('memory-and-mesh')
    }
  }

  // --- Remote Apply (CRDT Replica -> Local Runtime) ---

  private async applyReplicaToLocalRuntime(): Promise<void> {
    if (this.replica.pendingApply) await this.saveReplica()
    this.isApplyingRemote = true
    try {
      await this.applySkillsToLocal()
      await this.applyHostConfigAndMcpToLocal()
      await this.applyMcpVaultToLocal()
      await this.applyThemesToLocal()
      await this.applyMemoriesAndTrustedMeshToLocal()
    } finally {
      this.isApplyingRemote = false
    }
    await this.settleAgentHost()
    delete this.replica.pendingApply
    this.emitStatus()
  }

  /**
   * Brings what the agent host keeps and the account's copy together, item by item: the side that
   * changed since they last agreed wins. The host is asked through its own requests, so its menus
   * follow at once.
   */
  private async settleAgentHost(): Promise<void> {
    const host = this.deps.agentHost
    if (!host || !this.isConfigured()) return
    const dirty = this.dirtyScopeGen.get('host-config')
    // What the host keeps is extra to the account's sync, which goes on whatever happens here.
    await this.settlePinnedModels(host).catch((error: unknown) => {
      this.deps.log.warn(`Could not settle with the agent host: ${(error as Error).message}`)
    })
    if (this.dirtyScopeGen.get('host-config') !== dirty) this.schedulePush()
  }

  private async settlePinnedModels(host: SyncAgentHost): Promise<void> {
    let listed: AgentOptions[]
    try {
      listed = await host.request('agents.options', undefined)
    } catch (error) {
      this.deps.log.warn(`Could not read the pinned models: ${(error as Error).message}`)
      return
    }
    const bases = this.replica.localBase.pins
    // An agent without options kept can hold no pins yet; its synced ones wait for its options.
    for (const { agentId, pinned } of listed) {
      const key = `${PINNED_MODELS}${agentId}`
      const mine = pinned ?? []
      const synced = modelList(this.replica.hostConfig.items[key]?.value)
      const outcome = settle(mine, synced, bases[agentId], sameModels)
      if (outcome === 'capture') {
        this.replica.hostConfig = putLwwItem(
          this.replica.hostConfig,
          key,
          mine,
          this.now(),
          this.config.nodeId,
        )
        this.markScopeDirty('host-config')
      }
      if (outcome === 'apply') {
        if (!(await this.pinModels(host, agentId, mine, synced ?? []))) continue
        bases[agentId] = synced ?? []
      } else {
        bases[agentId] = mine
      }
    }
  }

  /** Changes the agent's pins from `from` to `to`; false when the host cannot now. */
  private async pinModels(
    host: SyncAgentHost,
    agentId: AgentId,
    from: readonly string[],
    to: readonly string[],
  ): Promise<boolean> {
    let kept = 0
    while (kept < from.length && from[kept] === to[kept]) kept++
    try {
      for (const model of from.slice(kept)) {
        await host.request('agents.pinModel', { agentId, model, pinned: false })
      }
      for (const model of to.slice(kept)) {
        await host.request('agents.pinModel', { agentId, model, pinned: true })
      }
      return true
    } catch (error) {
      this.deps.log.warn(
        `Could not pin the synced models of ${agentId}: ${(error as Error).message}`,
      )
      return false
    }
  }

  private async applySkillsToLocal(): Promise<void> {
    if (!this.masterKey) return
    for (const entry of Object.values(this.replica.skills.items)) {
      const { skill, archive } = entry.value
      if (!archive || !isSha256Hex(archive.blobSha256)) continue
      const unpacked = await hasUnpackedSkill(this.deps.dataPath, skill.id, skill.name)
      const cached = this.replica.blobCache[archive.contentHash]
      if (unpacked && cached?.blobSha256 === archive.blobSha256) continue

      const encrypted = await this.downloadBlob(archive.blobSha256)
      if (!encrypted) throw new Error('Synced skill archive is unavailable')
      const compressed = await openSyncBlob(
        this.masterKey,
        archive.iv,
        encrypted,
        archive.blobSha256,
      )
      await unpackSkillDirectory(this.deps.dataPath, skill.id, skill.name, compressed)
      this.replica.blobCache[archive.contentHash] = archive
    }
  }

  private async applyHostConfigAndMcpToLocal(): Promise<void> {
    const hc = this.replica.hostConfig.items
    const current = this.deps.settings.get()
    const patch: SettingsPatch = {}

    // 1. General
    const generalPatch: Partial<SettingsFile['general']> = {}
    if (typeof hc.sessionTitles?.value === 'boolean') {
      generalPatch.sessionTitles = hc.sessionTitles.value
    }
    if (hc.lightModel?.value && typeof hc.lightModel.value === 'object') {
      generalPatch.lightModel = hc.lightModel.value as SettingsFile['general']['lightModel']
    }
    if (hc.defaultAgent !== undefined) {
      const da = hc.defaultAgent.value
      if (da === null || isAgentId(da)) generalPatch.defaultAgent = da
    }
    if (Object.keys(generalPatch).length > 0) patch.general = generalPatch

    // 2. Portable harness flags (never touches local binaryPath / configDir)
    if (hc.agents?.value && typeof hc.agents.value === 'object') {
      const syncedAgents = hc.agents.value as Partial<Record<HarnessId, PortableHarnessSetting>>
      const agentsPatch: NonNullable<SettingsPatch['agents']> = {}
      for (const id of HARNESS_IDS) {
        const remoteEntry = syncedAgents[id]
        if (!remoteEntry) continue
        agentsPatch[id] = {
          ...(remoteEntry.enabled !== undefined ? { enabled: remoteEntry.enabled } : {}),
          ...(remoteEntry.hidden !== undefined ? { hidden: remoteEntry.hidden } : {}),
          ...(remoteEntry.uninstalled !== undefined
            ? { uninstalled: remoteEntry.uninstalled }
            : {}),
          ...(remoteEntry.autoUpdate !== undefined ? { autoUpdate: remoteEntry.autoUpdate } : {}),
        }
      }
      if (Object.keys(agentsPatch).length > 0) patch.agents = agentsPatch
    }

    // 3. Added Agents (materialize local ~/.sarto/agents/<id> folder when missing)
    if (Array.isArray(hc.addedAgents?.value)) {
      const wanted = hc.addedAgents.value as PortableAddedAgent[]
      const homeBase = path.join(
        this.deps.homeDir ?? os.homedir(),
        SARTO_HOME_FOLDER,
        AGENTS_FOLDER,
      )
      const wantedIds = new Set(wanted.map((w) => w.id))

      for (const existing of [...current.addedAgents]) {
        if (!wantedIds.has(existing.id)) {
          this.deps.settings.removeAgent(existing.id)
        }
      }
      const afterRemove = this.deps.settings.get()
      for (const item of wanted) {
        if (!isAgentId(item.id) || typeof item.name !== 'string') continue
        const found = afterRemove.addedAgents.find((a) => a.id === item.id)
        if (!found) {
          const configDir = path.join(homeBase, item.id)
          await mkdir(configDir, { recursive: true, mode: 0o700 })
          this.deps.settings.addAgent({
            id: item.id,
            name: item.name,
            configDir,
            created: true,
            ...(item.color ? { color: item.color } : {}),
          })
        } else {
          if (found.name !== item.name) {
            try {
              this.deps.settings.renameAgent(item.id, item.name)
            } catch {
              // Keep existing name if invalid.
            }
          }
          if (item.color && found.color !== item.color) {
            try {
              this.deps.settings.colorAgent(item.id, item.color)
            } catch {
              // Keep existing color.
            }
          }
        }
      }
    }

    // 4. Disabled agents, git, mcp, startModes, idleSessions, usage
    if (Array.isArray(hc.disabledAgents?.value)) {
      patch.disabledAgents = (hc.disabledAgents.value as unknown[]).filter(isAgentId)
    }
    if (typeof hc.gitBackgroundFetch?.value === 'boolean') {
      patch.git = { backgroundFetch: hc.gitBackgroundFetch.value }
    }
    if (Array.isArray(hc.mcpSartoOff?.value)) {
      patch.mcp = { sarto: { off: (hc.mcpSartoOff.value as unknown[]).filter(isAgentId) } }
    }
    if (hc.startModes?.value && typeof hc.startModes.value === 'object') {
      patch.startModes = hc.startModes.value as Record<AgentId, string>
    }
    if (hc.idleSessions?.value && typeof hc.idleSessions.value === 'object') {
      patch.idleSessions = hc.idleSessions.value as SettingsFile['idleSessions']
    }
    if (typeof hc.usageFromComputer?.value === 'boolean') {
      patch.usage = { fromComputer: hc.usageFromComputer.value }
    }

    // 5. Marketplace MCP servers & Skills (apply only once the corresponding scope exists remotely)
    const hasMcpScope = (this.replica.revisions['mcp-servers'] ?? 0) > 0
    const hasSkillsScope = (this.replica.revisions.skills ?? 0) > 0
    if (hasMcpScope || hasSkillsScope) {
      const mcpList: MarketServer[] = hasMcpScope
        ? Object.values(this.replica.mcpServers.items).map((e) => e.value)
        : [...current.marketplace.mcp]
      const skillList: MarketSkill[] = hasSkillsScope
        ? Object.values(this.replica.skills.items).map((e) => e.value.skill)
        : [...current.marketplace.skills]
      patch.marketplace = { mcp: mcpList, skills: skillList }
    }

    try {
      this.deps.settings.update(patch)
    } catch (error) {
      this.deps.log.warn(`Skipped invalid synced settings patch: ${(error as Error).message}`)
    }
  }

  private async applyMcpVaultToLocal(): Promise<void> {
    if ((this.replica.revisions['mcp-vault'] ?? 0) === 0) return
    const values: Record<string, Record<string, string>> = Object.create(null)
    const oauth: Record<string, string> = Object.create(null)
    const agentEnv: Record<string, Record<string, string>> = Object.create(null)
    for (const [composite, entry] of Object.entries(this.replica.mcpVault.values.items)) {
      const sep = composite.indexOf('\u0000')
      if (sep <= 0) continue
      const serverId = composite.slice(0, sep)
      const inputName = composite.slice(sep + 1)
      if (!isSafeObjectKey(serverId) || !isSafeObjectKey(inputName)) continue
      if (!Object.hasOwn(values, serverId)) values[serverId] = Object.create(null)
      values[serverId]![inputName] = entry.value
    }
    for (const [serverId, entry] of Object.entries(this.replica.mcpVault.oauth.items)) {
      if (!isSafeObjectKey(serverId)) continue
      oauth[serverId] = entry.value
    }
    for (const [composite, entry] of Object.entries(this.replica.mcpVault.agentEnv.items)) {
      const sep = composite.indexOf('\u0000')
      if (sep <= 0) continue
      const agentId = composite.slice(0, sep)
      const varName = composite.slice(sep + 1)
      if (!isSafeObjectKey(agentId) || !isSafeObjectKey(varName)) continue
      if (!Object.hasOwn(agentEnv, agentId)) agentEnv[agentId] = Object.create(null)
      agentEnv[agentId]![varName] = entry.value
    }
    const push: MarketKeysPush = { values, oauth, agentEnv }
    await this.deps.marketKeys.importSynced(push)
  }

  private async applyThemesToLocal(): Promise<void> {
    const themesDir = path.join(this.deps.dataPath, 'themes')
    await mkdir(themesDir, { recursive: true })

    const wantedIds = new Set<string>()
    for (const entry of Object.values(this.replica.themes.items)) {
      const { id, text } = entry.value
      if (!THEME_ID.test(id) || id === BUILTIN_THEME_ID || !checkThemeText(text).ok) continue
      wantedIds.add(id)
      const file = path.join(themesDir, `${id}.json`)
      const current = await readFile(file, 'utf8').catch(() => null)
      if (current !== text) {
        await writeFileAtomic(file, text)
      }
    }

    for (const tombId of Object.keys(this.replica.themes.tombstones)) {
      if (THEME_ID.test(tombId) && !wantedIds.has(tombId)) {
        await rm(path.join(themesDir, `${tombId}.json`), { force: true })
      }
    }

    await this.deps.themes.refresh()
  }

  private async applyMemoriesAndTrustedMeshToLocal(): Promise<void> {
    const memRoot = path.join(this.deps.dataPath, 'memory')
    const globalDir = path.join(memRoot, 'global')
    await mkdir(globalDir, { recursive: true })

    let memTouched = false
    const enabledEntry = this.replica.memoryAndMesh.memoryEnabled.items.enabled
    if (enabledEntry !== undefined) {
      const settingsPath = path.join(memRoot, 'settings.json')
      const wantedJson = `${JSON.stringify({ version: 1, enabled: Boolean(enabledEntry.value) }, null, 2)}\n`
      const curJson = await readFile(settingsPath, 'utf8').catch(() => null)
      if (curJson !== wantedJson) {
        await writeFileAtomic(settingsPath, wantedJson)
        memTouched = true
      }
    }

    const entries: MemoryEntry[] = []
    const wantedIds = new Set<string>()
    for (const wrapped of Object.values(this.replica.memoryAndMesh.memories.items)) {
      const item = wrapped.value
      if (!MEMORY_ID.test(item.id)) continue
      wantedIds.add(item.id)
      const entry: MemoryEntry = {
        id: item.id,
        title: item.title,
        description: item.description,
        body: item.body,
        createdAt: item.createdAt,
        updatedAt: item.updatedAt,
        source: { agentId: item.agentId, sessionId: item.sessionId },
      }
      entries.push(entry)
      const formatted = formatEntry(entry)
      const filePath = path.join(globalDir, `${item.id}.md`)
      const curText = await readFile(filePath, 'utf8').catch(() => null)
      if (curText !== formatted) {
        await writeFileAtomic(filePath, formatted)
        memTouched = true
      }
    }

    for (const tombId of Object.keys(this.replica.memoryAndMesh.memories.tombstones)) {
      if (MEMORY_ID.test(tombId) && !wantedIds.has(tombId)) {
        await rm(path.join(globalDir, `${tombId}.md`), { force: true })
        memTouched = true
      }
    }

    if (memTouched) {
      entries.sort((a, b) => b.updatedAt - a.updatedAt || a.id.localeCompare(b.id))
      const indexLines = [
        '# Global memory',
        '',
        'Sarto writes this list from the entry files beside it; change those, not this file.',
        '',
        ...entries.map((entry) => {
          const label =
            entry.description === '' ? entry.title : `${entry.title}: ${entry.description}`
          return `- [${oneLine(label)}](${entry.id}.md)`
        }),
      ]
      await writeFileAtomic(path.join(globalDir, 'MEMORY.md'), `${indexLines.join('\n')}\n`)
      this.deps.reloadMemory()
    }

    // Auto-authorize trusted workspace devices on this Mac's remote-host.
    const known = this.deps.knownDeviceIds()
    // A declined device that is paired again was paired by the owner, so it is declined no more.
    const declined = (this.config.declinedDevices ?? []).filter((id) => !known.has(id))
    if (declined.length !== (this.config.declinedDevices ?? []).length) {
      this.config.declinedDevices = declined
      await this.saveConfig()
    }
    for (const wrapped of Object.values(this.replica.memoryAndMesh.trustedDevices.items)) {
      const dev = wrapped.value
      if (known.has(dev.id) || declined.includes(dev.id)) continue
      await this.deps
        .addTrustedDevice({
          publicKey: dev.publicKey,
          name: dev.name,
          kind: dev.kind,
          platform: dev.platform,
          model: dev.model ?? '',
        })
        .catch(() => {})
    }
    await this.unpairRemovedDevices()
    this.publishMeshHosts()
  }

  /** Hands the account's other hosts to this Mac's daemon, leaving this Mac's own out. */
  private publishMeshHosts(): void {
    const ownKey = this.deps.hostPublicKey()
    const ownRelay = this.computedRelayId
    const hosts = Object.values(this.replica.memoryAndMesh.trustedHosts.items)
      .map((entry) => entry.value)
      .filter((host) => host.publicKey !== ownKey && (!ownRelay || host.relayId !== ownRelay))
    this.deps.meshHosts?.(hosts)
  }

  /**
   * Tidies the trusted hosts and devices. Those of an install that left the keybag go, as by
   * removing it or signing it out, so every Mac forgets and unpairs them. An entry that names no
   * sync device comes from before entries did: this Mac's own devices are named now, and another
   * install's goes once it has published nothing for 30 days.
   */
  private tidyMesh(keybag: SyncKeybag | null): {
    devicesChanged: boolean
    hostsChanged: boolean
  } {
    const inKeybag = isSyncKeybagV2(keybag)
      ? new Set(keybag.devices.map((wrap) => wrap.deviceId))
      : null
    const own = this.syncDeviceKey?.deviceId
    const by = this.config.nodeId
    const now = this.now()
    const departed = (entry: LwwEntry<{ syncDeviceId?: string }>): boolean => {
      const owner = entry.value.syncDeviceId
      if (owner) return inKeybag !== null && !inKeybag.has(owner)
      return entry.by !== by && now - entry.updatedAt > UNNAMED_MESH_ENTRY_TTL_MS
    }
    const mesh = this.replica.memoryAndMesh
    let devices = mesh.trustedDevices
    for (const [id, entry] of Object.entries(devices.items)) {
      if (own && !entry.value.syncDeviceId && entry.by === by) {
        devices = putLwwItem(devices, id, { ...entry.value, syncDeviceId: own }, now, by)
      } else if (departed(entry)) {
        devices = deleteLwwItem(devices, id, now, by)
      }
    }
    let hosts = mesh.trustedHosts
    for (const [id, entry] of Object.entries(hosts.items)) {
      if (departed(entry)) hosts = deleteLwwItem(hosts, id, now, by)
    }
    const devicesChanged = devices !== mesh.trustedDevices
    const hostsChanged = hosts !== mesh.trustedHosts
    if (!devicesChanged && !hostsChanged) {
      return { devicesChanged: false, hostsChanged: false }
    }
    this.replica.memoryAndMesh = { ...mesh, trustedDevices: devices, trustedHosts: hosts }
    this.markScopeDirty('memory-and-mesh')
    return { devicesChanged, hostsChanged }
  }

  /**
   * Unpairs from this Mac's remote host each device the account deleted, unless the host paired it
   * again after the deletion, as by a pairing code: the tombstone stays in the replica.
   */
  private async unpairRemovedDevices(): Promise<void> {
    const remove = this.deps.removeTrustedDevice
    const paired = this.deps.pairedDevices?.()
    if (!remove || !paired) return
    const tombstones = this.replica.memoryAndMesh.trustedDevices.tombstones
    for (const device of paired) {
      const tomb = tombstones[device.id]
      if (!tomb || device.addedAt >= tomb.deletedAt) continue
      await remove(device.id).catch((error: unknown) => {
        this.deps.log.warn(`Could not unpair a removed device: ${(error as Error).message}`)
      })
    }
  }

  // --- Live Stream WebSocket & HTTP Transport ---

  private connectStream(): void {
    this.closeStream()
    if (!this.shouldConnectStream() || this.stopping || !this.config.accessToken) return
    const wsUrl = relaySocketUrl(this.config.serverUrl, '/v1/sync/stream')
    let socket: SyncSocketLike
    try {
      socket = this.deps.openSocket
        ? this.deps.openSocket(wsUrl)
        : (openRelaySocket(wsUrl) as unknown as SyncSocketLike)
    } catch {
      this.scheduleStreamReconnect()
      return
    }
    this.streamSocket = socket
    const token = this.config.accessToken

    const sendSubscribe = (): void => {
      try {
        socket.send(JSON.stringify({ type: 'subscribe', token }))
      } catch {
        // Closed before send.
      }
    }

    // In-memory test sockets resolve already OPEN; standard WebSockets fire `open`.
    const readyState = (socket as { readyState?: number }).readyState
    if (readyState === 1) {
      sendSubscribe()
    } else {
      socket.addEventListener('open', sendSubscribe, { once: true })
    }

    socket.addEventListener('message', (ev) => {
      if (ev.data === PONG || typeof ev.data !== 'string') return
      if (ev.data === PING) {
        try {
          socket.send(PONG)
        } catch {
          // Ignore.
        }
        return
      }
      try {
        const msg = JSON.parse(ev.data) as {
          type?: string
          scope?: string
          key?: string
          rev?: number
          updatedBy?: string
          deviceId?: string
          removedDeviceIds?: unknown
          approval?: unknown
        }
        if (msg.type === 'subscribed') {
          this.connected = true
          this.wsReconnectAttempt = 0
          this.emitStatus()
        } else if (
          msg.type === 'sync.changed' &&
          this.masterKey !== null &&
          isSyncScope(msg.scope) &&
          msg.updatedBy !== this.config.nodeId
        ) {
          const scope = msg.scope
          void this.enqueueSync(async () => {
            const pulled = await this.fetchScopeRecord(scope)
            if (pulled && pulled.rev > (this.replica.revisions[pulled.scope] ?? 0)) {
              await this.mergeRemoteScopeRecord(pulled)
              await this.applyReplicaToLocalRuntime()
              await this.saveReplica()
            }
          }).catch(() => {})
        } else if (
          msg.type === 'sync.item.changed' &&
          this.masterKey !== null &&
          msg.scope === 'usage' &&
          typeof msg.key === 'string' &&
          isSyncItemKey(msg.key) &&
          msg.updatedBy !== this.config.nodeId
        ) {
          const itemKey = msg.key
          void this.enqueueSync(async () => {
            const pulled = await this.fetchUsageItem(itemKey)
            if (pulled && pulled.rev > (this.replica.usageRevisions[itemKey] ?? 0)) {
              await this.mergeRemoteUsageItem(pulled)
              this.notifyRemoteHostUsage()
              this.emitUsageUpdated()
              await this.saveReplica()
            }
          }).catch(() => {})
        } else if (
          msg.type === 'sync.item.deleted' &&
          msg.scope === 'usage' &&
          typeof msg.key === 'string' &&
          isSyncItemKey(msg.key) &&
          msg.key !== this.usageIds.deviceId
        ) {
          const itemKey = msg.key
          void this.enqueueSync(async () => {
            delete this.replica.usageRecords[itemKey]
            delete this.replica.usageRevisions[itemKey]
            this.dirtyUsageGen.delete(itemKey)
            this.notifyRemoteHostUsage()
            this.emitUsageUpdated()
            this.emitStatus()
            await this.saveReplica()
          }).catch(() => {})
        } else if (msg.type === 'sync.approval.updated') {
          if (this.keyState === 'awaiting-approval') {
            void this.syncAccountKeyState({ pollOnly: true }).catch(() => {})
          } else if (this.keyState === 'ready') {
            void this.enqueueSync(async () => {
              await this.refreshPendingApprovals()
            }).catch(() => {})
          }
        } else if (msg.type === 'sync.approval.requested' && this.keyState === 'ready') {
          void this.enqueueSync(async () => {
            await this.refreshPendingApprovals()
          }).catch(() => {})
        } else if (msg.type === 'sync.approval.rejected') {
          if (
            this.keyState === 'awaiting-approval' &&
            this.syncDeviceKey &&
            msg.deviceId === this.syncDeviceKey.deviceId
          ) {
            this.stopApprovalPollLoop()
            this.approvalPublishedAt = 0
            this.lastError = 'Device approval request was rejected on another Mac'
            this.emitStatus()
          } else if (this.keyState === 'ready') {
            void this.enqueueSync(async () => {
              await this.refreshPendingApprovals()
            }).catch(() => {})
          }
        } else if (msg.type === SYNC_RESET_EVENT) {
          void this.syncWasReset().catch(() => {})
        } else if (msg.type === 'sync.keybag.updated') {
          if (this.keyState === 'awaiting-approval' || this.keyState === 'needs-setup') {
            void this.syncAccountKeyState({ pollOnly: true }).catch(() => {})
          } else if (this.keyState === 'ready') {
            const removed = Array.isArray(msg.removedDeviceIds) ? msg.removedDeviceIds : []
            if (this.syncDeviceKey && removed.includes(this.syncDeviceKey.deviceId)) {
              void this.revokeLocalMasterKey('This Mac was removed from encrypted sync').catch(
                () => {},
              )
            } else if (removed.length > 0) {
              // Another device left: forget it and unpair it here, along with the approvals.
              void this.enqueueSync(async () => {
                await this.reconcileWithServer()
              }).catch(() => {})
            } else {
              void this.enqueueSync(async () => {
                await this.refreshPendingApprovals()
              }).catch(() => {})
            }
          }
        }
      } catch {
        // Ignore malformed frame.
      }
    })

    socket.addEventListener('close', (ev) => {
      if (this.streamSocket === socket) {
        this.streamSocket = null
        this.connected = false
        this.emitStatus()
        if (ev.code === 4401 && this.config.mode === 'account') {
          void this.deps.account
            ?.check?.()
            .catch(() => {})
            .finally(() => {
              this.scheduleStreamReconnect()
            })
          return
        }
        this.scheduleStreamReconnect()
      }
    })

    this.wsPingTimer = setInterval(() => {
      if (this.streamSocket === socket) {
        try {
          socket.send(PING)
        } catch {
          // Ignore.
        }
      }
    }, WS_PING_MS)
    this.wsPingTimer.unref()
  }

  private scheduleStreamReconnect(): void {
    if (this.stopping || !this.shouldConnectStream() || this.wsReconnectTimer) return
    const attempt = Math.min(this.wsReconnectAttempt++, 6)
    const delay = Math.min(WS_RECONNECT_BASE_MS * 2 ** attempt, WS_RECONNECT_MAX_MS)
    this.wsReconnectTimer = setTimeout(() => {
      this.wsReconnectTimer = null
      // Through the queue, so `account` mode subscribes with a fresh token.
      void this.enqueueSync(async () => this.connectStream()).catch(() => {
        this.scheduleStreamReconnect()
      })
    }, delay)
    this.wsReconnectTimer.unref()
  }

  private closeStream(): void {
    if (this.wsPingTimer) {
      clearInterval(this.wsPingTimer)
      this.wsPingTimer = null
    }
    if (this.wsReconnectTimer) {
      clearTimeout(this.wsReconnectTimer)
      this.wsReconnectTimer = null
    }
    const cur = this.streamSocket
    this.streamSocket = null
    if (cur) {
      try {
        cur.close(1000, 'closing')
      } catch {
        // Ignore.
      }
    }
  }

  private async fetchManifest(origin: string, token: string): Promise<SyncManifest> {
    const res = await this.httpJson<SyncManifest>(`${origin}/v1/sync/manifest`, {
      method: 'GET',
      headers: { authorization: `Bearer ${token}` },
    })
    if (res.status === 401 || res.status === 403) {
      throw new Error('Server rejected authentication token (401 Unauthorized)')
    }
    if (!res.ok || !res.body || typeof res.body.scopes !== 'object') {
      throw new Error(
        `Server at ${origin} does not support Sarto Workspace Sync (HTTP ${res.status})`,
      )
    }
    return res.body
  }

  private async fetchScopeRecord(scope: SyncScope): Promise<SyncScopeRecord | null> {
    if (!this.config.accessToken) return null
    const res = await this.httpJson<SyncScopeRecord>(
      `${this.config.serverUrl}/v1/sync/scopes/${scope}`,
      {
        method: 'GET',
        headers: { authorization: `Bearer ${this.config.accessToken}` },
      },
    )
    if (res.status === 404) return null
    if (
      !res.ok ||
      !res.body ||
      res.body.scope !== scope ||
      !isValidRevision(res.body.rev) ||
      !isEncryptedSyncEnvelope(res.body.envelope)
    ) {
      throw new Error(`Failed to read scope "${scope}" (${res.status})`)
    }
    return res.body
  }

  private async fetchUsageItem(key: string): Promise<SyncItemRecord | null> {
    if (!this.config.accessToken) return null
    const res = await this.httpJson<SyncItemRecord>(
      `${this.config.serverUrl}/v1/sync/scopes/usage/items/${encodeURIComponent(key)}`,
      {
        method: 'GET',
        headers: { authorization: `Bearer ${this.config.accessToken}` },
      },
    )
    if (res.status === 404) return null
    if (
      !res.ok ||
      !res.body ||
      res.body.scope !== 'usage' ||
      res.body.key !== key ||
      !isValidRevision(res.body.rev) ||
      !isEncryptedSyncEnvelope(res.body.envelope)
    ) {
      throw new Error(`Failed to read usage item "${key}" (${res.status})`)
    }
    return res.body
  }

  private async uploadBlobIfMissing(sha256: string, ciphertext: Uint8Array): Promise<void> {
    if (!this.config.accessToken) return
    if (!isSha256Hex(sha256)) throw new Error('Invalid skill blob sha256')
    const f = this.deps.fetchImpl ?? fetch
    const url = `${this.config.serverUrl}/v1/sync/blobs/${sha256}`
    const authHeader = { authorization: `Bearer ${this.config.accessToken}` }

    const head = await f(url, withRequestDefaults({ method: 'HEAD', headers: authHeader }))
    if (head.status === 200) return

    const put = await f(
      url,
      withRequestDefaults({
        method: 'PUT',
        headers: { ...authHeader, 'content-type': 'application/octet-stream' },
        body: Buffer.from(ciphertext),
      }),
    )
    if (!put.ok) {
      throw new Error(`Failed to upload encrypted skill blob (${put.status})`)
    }
  }

  /** Whether the server holds the blob; true when it cannot tell, so nothing is sealed twice. */
  private async blobOnServer(sha256: string): Promise<boolean> {
    if (!this.config.accessToken || !isSha256Hex(sha256)) return true
    const f = this.deps.fetchImpl ?? fetch
    const head = await f(
      `${this.config.serverUrl}/v1/sync/blobs/${sha256}`,
      withRequestDefaults({
        method: 'HEAD',
        headers: { authorization: `Bearer ${this.config.accessToken}` },
      }),
    ).catch(() => null)
    return head?.status !== 404
  }

  private async downloadBlob(sha256: string): Promise<Uint8Array | null> {
    if (!this.config.accessToken || !isSha256Hex(sha256)) return null
    const f = this.deps.fetchImpl ?? fetch
    const res = await f(
      `${this.config.serverUrl}/v1/sync/blobs/${sha256}`,
      withRequestDefaults({
        method: 'GET',
        headers: { authorization: `Bearer ${this.config.accessToken}` },
      }),
    )
    if (res.status === 404) return null
    if (!res.ok) throw new Error(`Failed to download encrypted skill blob (${res.status})`)
    return new Uint8Array(await res.arrayBuffer())
  }

  private async httpJson<T>(
    url: string,
    init: RequestInit,
  ): Promise<{ ok: boolean; status: number; body: T | null }> {
    const f = this.deps.fetchImpl ?? fetch
    const res = await f(url, withRequestDefaults(init))
    const text = await res.text().catch(() => '')
    let body: T | null = null
    if (text) {
      try {
        body = JSON.parse(text) as T
      } catch {
        body = null
      }
    }
    return { ok: res.ok, status: res.status, body }
  }

  private async saveConfig(): Promise<void> {
    const file = path.join(this.deps.dataPath, CONFIG_FILE)
    const cipherAvailable = await this.cipher.available()
    const plainText = !cipherAvailable || this.cipher.plainText()
    this.plainTextStorage = plainText || (this.syncDeviceKey?.plainText ?? false)

    let masterKeyBase64: string | null = null
    let masterKeyEncrypted: string | null = null
    if (this.masterKey) {
      const encoded = syncBase64UrlEncode(this.masterKey)
      if (cipherAvailable) {
        masterKeyEncrypted = (await this.cipher.encrypt(encoded)).toString('base64')
      } else {
        masterKeyBase64 = encoded
      }
    }

    const rawAccessToken = this.config.mode === 'account' ? null : this.config.accessToken
    const rawRelayToken = this.config.mode === 'account' ? null : this.config.relayToken
    let accessToken: string | null = null
    let accessTokenEncrypted: string | null = null
    let relayToken: string | null = null
    let relayTokenEncrypted: string | null = null
    if (rawAccessToken) {
      if (cipherAvailable) {
        accessTokenEncrypted = (await this.cipher.encrypt(rawAccessToken)).toString('base64')
      } else {
        accessToken = rawAccessToken
      }
    } else if (
      !cipherAvailable &&
      this.config.mode !== 'account' &&
      this.config.accessTokenEncrypted
    ) {
      accessTokenEncrypted = this.config.accessTokenEncrypted
    }
    if (rawRelayToken) {
      if (cipherAvailable) {
        relayTokenEncrypted = (await this.cipher.encrypt(rawRelayToken)).toString('base64')
      } else {
        relayToken = rawRelayToken
      }
    } else if (
      !cipherAvailable &&
      this.config.mode !== 'account' &&
      this.config.relayTokenEncrypted
    ) {
      relayTokenEncrypted = this.config.relayTokenEncrypted
    }

    // The account's tokens live with the account, short-lived, and are never written here.
    const kept: StoredSyncConfig = {
      ...this.config,
      accessToken,
      accessTokenEncrypted,
      relayToken,
      relayTokenEncrypted,
      masterKeyBase64,
      masterKeyEncrypted,
      keyEpoch: this.keyEpoch,
      plainText,
    }
    await writeFileAtomic(file, `${JSON.stringify(kept, null, 2)}\n`, 0o600)
  }

  private saveReplica(): Promise<void> {
    const next = this.replicaSaveQueue
      .catch(() => {})
      .then(async () => {
        const dir = path.join(this.deps.dataPath, 'state')
        await mkdir(dir, { recursive: true })
        const file = path.join(dir, REPLICA_FILE)
        const cipherAvailable = await this.cipher.available()
        if (cipherAvailable && this.preservedMcpVaultEncrypted) {
          try {
            const { result } = await this.cipher.decrypt(
              Buffer.from(this.preservedMcpVaultEncrypted, 'base64'),
            )
            const recovered = JSON.parse(result) as Partial<McpVaultScopeDoc>
            const nowMs = this.now()
            this.replica.mcpVault = {
              values: mergeLwwMaps(
                recovered.values ?? emptyLwwMap(),
                this.replica.mcpVault.values,
                nowMs,
              ),
              oauth: mergeLwwMaps(
                recovered.oauth ?? emptyLwwMap(),
                this.replica.mcpVault.oauth,
                nowMs,
              ),
              agentEnv: mergeLwwMaps(
                recovered.agentEnv ?? emptyLwwMap(),
                this.replica.mcpVault.agentEnv,
                nowMs,
              ),
            }
            this.preservedMcpVaultEncrypted = null
          } catch {
            // Keep preserved ciphertext until readable or explicitly overwritten.
          }
        }
        const plainText = !cipherAvailable || this.cipher.plainText()
        const { mcpVault, ...rest } = this.replica
        const dirtyScopes = this.dirtyScopeGen.size > 0 ? [...this.dirtyScopeGen.keys()] : undefined
        const dirtyUsageKeys =
          this.dirtyUsageGen.size > 0 ? [...this.dirtyUsageGen.keys()] : undefined
        const pendingMeta = {
          ...(dirtyScopes ? { dirtyScopes } : {}),
          ...(dirtyUsageKeys ? { dirtyUsageKeys } : {}),
        }
        const onDisk: StoredSyncReplicaOnDisk = cipherAvailable
          ? {
              ...rest,
              ...pendingMeta,
              mcpVaultEncrypted: (await this.cipher.encrypt(JSON.stringify(mcpVault))).toString(
                'base64',
              ),
              plainText,
            }
          : this.preservedMcpVaultEncrypted
            ? {
                ...rest,
                ...pendingMeta,
                mcpVaultEncrypted: this.preservedMcpVaultEncrypted,
                plainText: false,
              }
            : {
                ...rest,
                ...pendingMeta,
                mcpVault,
                mcpVaultEncrypted: null,
                plainText,
              }
        await writeFileAtomic(file, `${JSON.stringify(onDisk)}\n`, 0o600)
      })
    this.replicaSaveQueue = next.catch(() => {})
    return next
  }
}
