// Sarto multi-device E2EE workspace sync wire contract and deterministic LWW CRDT merge engine.
// Runs across Node.js, Electron, and browsers with zero Node-specific globals.

import type { PlanLimit, ProviderBalance } from '../agent-host'
import type { MarketServer, MarketSkill } from '../marketplace'
import type { AddedAgent, LightModel, SettingsFile } from '../settings'
import type { AgentId, HarnessId } from '../thread'
import type { AgentActivity, QuotaHistory, QuotaReading, UsageSource } from '../usage'
import type { SyncConnectionMode, SyncScope } from './wire'

export {
  SARTO_SYNC_FEATURE,
  SARTO_CLOUD_URL,
  SYNC_SCOPES,
  KEYED_SYNC_SCOPES,
  isSyncScope,
  isKeyedSyncScope,
  isSyncDeviceId,
  isSyncItemKey,
  isEncryptedSyncEnvelope,
  isSyncKeybagV2,
  isSyncKeybag,
  isSyncDeviceKeyWrap,
  isSyncRecoveryKeyWrap,
  isSyncApprovalRequest,
  isSyncApprovalAnswer,
  isSyncWrapApproval,
  isSha256Hex,
} from './wire'
export type {
  SyncScope,
  KeyedSyncScope,
  SyncConnectionMode,
  EncryptedSyncEnvelope,
  SyncKeybagV2,
  SyncKeybag,
  SyncDeviceKeyWrap,
  SyncRecoveryKeyWrap,
  SyncApprovalRequest,
  SyncApprovalAnswer,
  SyncWrapApproval,
  SyncScopeMeta,
  SyncManifest,
  SyncScopeRecord,
  SyncItemRecord,
} from './wire'

/** Tombstones older than 90 days are compacted during merges. */
export const TOMBSTONE_TTL_MS = 90 * 24 * 60 * 60 * 1000

export interface LwwEntry<T> {
  value: T
  updatedAt: number
  by: string
}

export interface LwwTombstone {
  deletedAt: number
  by: string
}

export interface LwwMap<T> {
  items: Record<string, LwwEntry<T>>
  tombstones: Record<string, LwwTombstone>
}

export function emptyLwwMap<T>(): LwwMap<T> {
  return { items: {}, tombstones: {} }
}

const FORBIDDEN_MAP_KEYS = new Set(['__proto__', 'constructor', 'prototype'])

function isSafeMapKey(key: string): boolean {
  return key.length > 0 && !FORBIDDEN_MAP_KEYS.has(key)
}

function safeCloneRecord<V>(record: Record<string, V>): Record<string, V> {
  const out: Record<string, V> = {}
  for (const key of Object.keys(record)) {
    if (isSafeMapKey(key)) out[key] = record[key]!
  }
  return out
}

function compareStamp(aTime: number, aBy: string, bTime: number, bBy: string): number {
  if (aTime !== bTime) return aTime > bTime ? 1 : -1
  if (aBy === bBy) return 0
  return aBy > bBy ? 1 : -1
}

/** Sets or updates `key` in `map` when `(updatedAt, by)` wins over any existing value or tombstone. */
export function putLwwItem<T>(
  map: LwwMap<T>,
  key: string,
  value: T,
  updatedAt: number,
  by: string,
): LwwMap<T> {
  if (!isSafeMapKey(key)) return map
  const cur = Object.hasOwn(map.items, key) ? map.items[key] : undefined
  if (cur && compareStamp(updatedAt, by, cur.updatedAt, cur.by) <= 0) return map
  const tomb = Object.hasOwn(map.tombstones, key) ? map.tombstones[key] : undefined
  if (tomb && compareStamp(updatedAt, by, tomb.deletedAt, tomb.by) <= 0) return map
  const nextItems = safeCloneRecord(map.items)
  nextItems[key] = { value, updatedAt, by }
  const nextTombs = safeCloneRecord(map.tombstones)
  delete nextTombs[key]
  return { items: nextItems, tombstones: nextTombs }
}

/** Records a deletion tombstone for `key` when `(deletedAt, by)` wins. */
export function deleteLwwItem<T>(
  map: LwwMap<T>,
  key: string,
  deletedAt: number,
  by: string,
): LwwMap<T> {
  if (!isSafeMapKey(key)) return map
  const tomb = Object.hasOwn(map.tombstones, key) ? map.tombstones[key] : undefined
  if (tomb && compareStamp(deletedAt, by, tomb.deletedAt, tomb.by) <= 0) return map
  const cur = Object.hasOwn(map.items, key) ? map.items[key] : undefined
  if (cur && compareStamp(deletedAt, by, cur.updatedAt, cur.by) < 0) return map
  const nextItems = safeCloneRecord(map.items)
  delete nextItems[key]
  const nextTombs = safeCloneRecord(map.tombstones)
  nextTombs[key] = { deletedAt, by }
  return { items: nextItems, tombstones: nextTombs }
}

/** Commutative, associative, idempotent merge of two LWW element dictionaries. */
export function mergeLwwMaps<T>(a: LwwMap<T>, b: LwwMap<T>, now = Date.now()): LwwMap<T> {
  const keys = new Set<string>([
    ...Object.keys(a.items),
    ...Object.keys(b.items),
    ...Object.keys(a.tombstones),
    ...Object.keys(b.tombstones),
  ])
  const items: Record<string, LwwEntry<T>> = {}
  const tombstones: Record<string, LwwTombstone> = {}

  for (const key of keys) {
    if (!isSafeMapKey(key)) continue
    let bestKind: 'item' | 'tomb' | null = null
    let bestTime = -1
    let bestBy = ''
    let bestVal: T | undefined

    const candidates: Array<
      | { kind: 'item'; time: number; by: string; val: T }
      | { kind: 'tomb'; time: number; by: string }
    > = []
    const ai = Object.hasOwn(a.items, key) ? a.items[key] : undefined
    if (ai) candidates.push({ kind: 'item', time: ai.updatedAt, by: ai.by, val: ai.value })
    const bi = Object.hasOwn(b.items, key) ? b.items[key] : undefined
    if (bi) candidates.push({ kind: 'item', time: bi.updatedAt, by: bi.by, val: bi.value })
    const at = Object.hasOwn(a.tombstones, key) ? a.tombstones[key] : undefined
    if (at) candidates.push({ kind: 'tomb', time: at.deletedAt, by: at.by })
    const bt = Object.hasOwn(b.tombstones, key) ? b.tombstones[key] : undefined
    if (bt) candidates.push({ kind: 'tomb', time: bt.deletedAt, by: bt.by })

    for (const c of candidates) {
      const cmp =
        bestKind === null
          ? 1
          : compareStamp(c.time, c.by, bestTime, bestBy) ||
            (c.kind === 'tomb' && bestKind === 'item' ? 1 : 0)
      if (cmp > 0) {
        bestKind = c.kind
        bestTime = c.time
        bestBy = c.by
        bestVal = c.kind === 'item' ? c.val : undefined
      }
    }

    if (bestKind === 'item') {
      items[key] = { value: bestVal as T, updatedAt: bestTime, by: bestBy }
    } else if (bestKind === 'tomb' && now - bestTime <= TOMBSTONE_TTL_MS) {
      tombstones[key] = { deletedAt: bestTime, by: bestBy }
    }
  }

  return { items, tombstones }
}

// --- Scope Payloads ---

/** Portable client UI preferences shared across macOS Sarto.app, iOS, and Web/Desktop. */
export interface SyncedUiPrefsMap {
  language?: string
  palette?: string
  darkPalette?: string
  lightPalette?: string
  colorMode?: string
  accentMode?: string
  motionTier?: string
  sendKeyMode?: string
  defaultAgentID?: string | null
  restoreLastSession?: boolean
  confirmQuitWhileRunning?: boolean
  textSize?: string
  threadWideWidth?: boolean
  uiFontFamily?: string
  proseFontFamily?: string
  codeFontFamily?: string
  terminalFontSize?: number
  terminalFontFamily?: string
  notifications?: Record<string, boolean>
  islandEnabled?: boolean
  islandSessionStack?: boolean
  islandMaxRows?: number
  islandShowQuota?: boolean
  islandMotion?: string
  runningRailEnabled?: boolean
  browserAllowedOrigins?: Record<string, string[]> | string[]
  subtleReminders?: boolean
  menubarEnabled?: boolean
  statusText?: string
  providerOrder?: string[]
  providerHidden?: string[]
  usageScope?: string
  lowAlert?: boolean
  lowThreshold?: number
  usagePrivacy?: boolean
}

export type UiPrefsScopeDoc = LwwMap<unknown>

/** Portable harness flags (machine-local binaryPath & configDir excluded). */
export interface PortableHarnessSetting {
  hidden?: true
  enabled?: boolean
  uninstalled?: true
  autoUpdate?: false
}

/** Portable added agent persona (local config folder is materialized per machine). */
export interface PortableAddedAgent {
  id: AgentId
  name: string
  color?: AddedAgent['color']
}

export interface HostConfigFields {
  sessionTitles: boolean
  lightModel: LightModel
  defaultAgent: AgentId | null
  agents: Partial<Record<HarnessId, PortableHarnessSetting>>
  addedAgents: PortableAddedAgent[]
  disabledAgents: AgentId[]
  gitBackgroundFetch: boolean
  mcpSartoOff: AgentId[]
  startModes: Partial<Record<AgentId, string>>
  idleSessions: SettingsFile['idleSessions']
  usageFromComputer: boolean
}

/**
 * Host-config also holds what the agent host keeps, one LWW entry per item under these keys, each
 * optional, so a daemon that does not know them keeps them as it merges: `pinnedModels:<agentId>`
 * (`string[]`, the pinned models in order), whose deletions are tombstones.
 */
export type HostConfigScopeDoc = LwwMap<unknown>

export type McpServersScopeDoc = LwwMap<MarketServer>

export interface McpVaultScopeDoc {
  /** Keyed by `${serverId}\u0000${inputName}`. */
  values: LwwMap<string>
  /** Keyed by `serverId`. */
  oauth: LwwMap<string>
  /** Keyed by `${agentId}\u0000${variable}`. */
  agentEnv: LwwMap<string>
}

/** Encrypted CAS archive reference for an unpacked skill folder. */
export interface SyncedSkillArchive {
  /** SHA-256 hex of the encrypted blob stored at `/v1/sync/blobs/:blobSha256`. */
  blobSha256: string
  /** 12-byte AES-256-GCM IV in base64url used to seal this archive. */
  iv: string
  /** SHA-256 hex of the canonical plaintext archive, avoiding redundant re-uploads. */
  contentHash: string
  byteLength: number
}

export interface SyncedSkillItem {
  skill: MarketSkill
  archive: SyncedSkillArchive | null
}

export type SkillsScopeDoc = LwwMap<SyncedSkillItem>

export interface SyncedThemeItem {
  id: string
  text: string
}

export type ThemesScopeDoc = LwwMap<SyncedThemeItem>

export interface SyncedMemoryItem {
  id: string
  title: string
  description: string
  body: string
  createdAt: number
  updatedAt: number
  agentId: AgentId | null
  sessionId: string | null
}

export interface TrustedWorkspaceHost {
  /** 32-hex device/host ID derived from Noise X25519 public key, or relayId. */
  id: string
  name: string
  platform: string
  /** Host Noise X25519 static public key in base64. */
  publicKey: string
  /** 26-char base32 Ed25519 relay host ID. */
  relayId: string | null
  relayUrl: string | null
  /**
   * The sync device (keybag wrap) of the Mac whose daemon published it. Once that wrap leaves the
   * keybag, every Mac forgets the host.
   */
  syncDeviceId?: string
}

export interface TrustedWorkspaceDevice {
  /** 32-hex device ID derived from SHA-256(publicKey)[0..16]. */
  id: string
  /** Device Noise X25519 public key in base64. */
  publicKey: string
  name: string
  kind: string
  platform: string
  model?: string
  /**
   * The sync device (keybag wrap) of the install that published it, which its daemon fills in.
   * Once that wrap leaves the keybag, the device leaves every host it was paired with.
   */
  syncDeviceId?: string
}

export interface MemoryAndMeshScopeDoc {
  memoryEnabled: LwwMap<boolean>
  memories: LwwMap<SyncedMemoryItem>
  trustedHosts: LwwMap<TrustedWorkspaceHost>
  trustedDevices: LwwMap<TrustedWorkspaceDevice>
}

// --- Per-Mac `usage` keyed scope payload (`island` + `host` sections) ---

/** One quarter-hour bucket exported from a Mac's daemon usage database. */
export interface SyncedUsageBucket {
  quarter: number
  source: UsageSource
  agentId: AgentId
  model: string
  /** Project path or '' for no project. */
  project: string
  rows: number
  input: number
  output: number
  reasoning: number
  cacheRead: number
  cacheWrite: number
  cacheWrite1h: number
  turns: number
}

/** One agent's latest plan limits and provider balances on a Mac. */
export interface SyncedAgentPlanReading {
  tier?: string
  limits: PlanLimit[]
  balances: ProviderBalance[]
  observedAt: number
}

/**
 * Daemon-owned usage section (`host`): quarter-hour buckets and agent plan readings. It travels
 * inside the encrypted per-Mac record, so fields added later reach the server as ciphertext; an
 * older daemon keeps another Mac's section whole and reads only the fields it knows.
 */
export interface SyncedHostUsageSection {
  /** The same computer's usage record under the earlier device-id namespace. */
  previousDeviceId?: string
  updatedAt: number
  fromComputer: boolean
  /** Effective source per agent on this Mac (for 'computer' scope) so multi-Mac sums never double-count. */
  computerSources: Partial<Record<AgentId, UsageSource>>
  buckets: SyncedUsageBucket[]
  plans?: Partial<Record<AgentId, SyncedAgentPlanReading>>
  /** This Mac's plan quota readings, one per agent, each naming its account's fingerprint. */
  quotas?: QuotaReading[]
  /** Their windows' measurements on this Mac over the last 48 hours, for burn-rate forecasts. */
  quotaHistory?: QuotaHistory[]
  /** Each agent's latest request on this Mac. */
  activity?: AgentActivity[]
  /**
   * The Mac's name, which the sync service adds from the record when it hands another Mac's
   * section to the agent host; not part of the stored section.
   */
  deviceName?: string
}

/** This Mac as the sync names it, for the usage overview's list of computers. */
export interface SyncedUsageSelf {
  deviceId: string
  deviceName: string
  /** When its own usage record last changed; null before it has one. */
  updatedAt: number | null
}

/** UsageIslandKit-owned usage section (`island`): the opaque DeviceFile JSON from Swift. */
export interface SyncedIslandUsageSection {
  updatedAt: number
  payload: Record<string, unknown>
}

/** One Mac's combined usage record stored at `/v1/sync/scopes/usage/items/:deviceId`. */
export interface SyncedUsageRecord {
  v: 1
  deviceId: string
  deviceName: string
  updatedAt: number
  island?: SyncedIslandUsageSection
  host?: SyncedHostUsageSection
}

/** Compact summary of one Mac's usage record shown in `sync.status`. */
export interface SyncedUsageDeviceSummary {
  deviceId: string
  deviceName: string
  updatedAt: number
  rev: number
  hasIsland: boolean
  hasHost: boolean
}

// --- Keybag v2 & Approval State ---

export type SyncKeyState = 'none' | 'ready' | 'needs-setup' | 'awaiting-approval'

/** A pending approval request shown on an already-approved Mac, with its locally computed SAS code. */
export interface SyncPendingApproval {
  deviceId: string
  devicePublicKey: string
  deviceName: string
  platform: string
  /** The code both Macs show (`XXXX-XXXX`), once the waiting Mac revealed its nonce. */
  code: string
  createdAt: number
  expiresAt: number
}

/** Public status summary exposed by the daemon over `control.sock` to Sarto.app. */
export interface SartoSyncStatus {
  mode: SyncConnectionMode
  serverUrl: string
  connected: boolean
  syncing: boolean
  lastSyncedAt: number | null
  error: string | null
  account: { id: string; email: string; name: string | null } | null
  relayId: string | null
  /** Null in `account` mode: the daemon's account hands relay tokens out instead. */
  relayToken: string | null
  /** In `account` mode, signed in but without the sync key yet, so nothing syncs. */
  needsKey: boolean
  /** Detailed key state in `account` mode (`none` when off or in legacy mode). */
  keyState: SyncKeyState
  /** True when local sync secrets are kept in a 0600 file rather than the macOS Keychain. */
  plainText: boolean
  /** This Mac's 32-hex sync device key id. */
  syncDeviceId: string | null
  /**
   * While `keyState === 'awaiting-approval'`, the code shown on both Macs (`XXXX-XXXX`), once a Mac
   * holding the key answered this Mac's request.
   */
  approvalCode: string | null
  /**
   * While `keyState === 'awaiting-approval'`: `waiting` for a Mac to answer, `confirm` that the
   * code matches the answering Mac's, `confirmed` by the user and waiting for that Mac to approve.
   */
  approvalStage: 'waiting' | 'confirm' | 'confirmed' | null
  /** The name the answering Mac gave, while awaiting approval. */
  approverName: string | null
  /** While `keyState === 'ready'`, other Macs waiting to be approved. */
  pendingApprovals: SyncPendingApproval[]
  /** This Mac's usage device id (16-hex SHA-256 of hardware UUID on macOS). */
  usageDeviceId: string | null
  /** Known Macs' usage records (metadata only; full `island` payloads are delivered separately). */
  usageDevices: SyncedUsageDeviceSummary[]
  hostPublicKey: string | null
  revisions: Partial<Record<SyncScope, number>>
  uiPrefs: Record<string, LwwEntry<unknown>>
  trustedHosts: TrustedWorkspaceHost[]
}
