// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Zhengru
//
// The part of the Sarto sync contract a sync server needs: scopes, keyed records, sealed
// envelopes, keybags (v2), device approval mailbox and their guards. It imports nothing, so
// the server's program carries no app settings types and runs under Node's type-stripping runtime.

/** Advertised in `GET /v1` `features` by Sarto Cloud and Self-Hosted Sarto Server. */
export const SARTO_SYNC_FEATURE = 'sarto-sync'

/**
 * Sent on the account's sync stream when its owner resets sync (PROTOCOL.md section 4.4): the
 * keybag, scopes, items, approvals and blobs are gone, and every device forgets its key.
 */
export const SYNC_RESET_EVENT = 'sync.reset'

/** Default Sarto Official Cloud origin (hardcoded for official cloud; env-overridable for dev/tests). */
export const SARTO_CLOUD_URL = 'https://sarto.1o.ink'

export const SYNC_SCOPES = [
  'ui-prefs',
  'host-config',
  'mcp-servers',
  'mcp-vault',
  'skills',
  'themes',
  'memory-and-mesh',
] as const

export type SyncScope = (typeof SYNC_SCOPES)[number]

/** Scopes stored as independent per-key records (each with its own revision), such as per-Mac usage. */
export const KEYED_SYNC_SCOPES = ['usage'] as const

export type KeyedSyncScope = (typeof KEYED_SYNC_SCOPES)[number]

export function isSyncScope(value: unknown): value is SyncScope {
  return typeof value === 'string' && (SYNC_SCOPES as readonly string[]).includes(value)
}

export function isKeyedSyncScope(value: unknown): value is KeyedSyncScope {
  return typeof value === 'string' && (KEYED_SYNC_SCOPES as readonly string[]).includes(value)
}

/**
 * `account`: signed in to Sarto Cloud through the daemon's OAuth account, which owns the tokens.
 */
export type SyncConnectionMode = 'off' | 'account'

/** AES-256-GCM sealed payload stored opaquely on the Sarto Server. */
export interface EncryptedSyncEnvelope {
  v: 1
  alg: 'AES-256-GCM'
  /** 12-byte random IV in base64url. */
  iv: string
  /** Ciphertext + 16-byte GCM authentication tag in base64url. */
  ciphertext: string
  /** Key epoch that sealed this envelope (1 in phase 1; leaves room for future SMK rotation). */
  keyEpoch?: number
  /** Plaintext encoding applied before encryption (`gzip` for keyed usage records). */
  encoding?: 'gzip'
}

/** One X25519 sealed-box wrap of the 32-byte SMK for a single approved device. */
export interface SyncDeviceKeyWrap {
  /** 32-hex device key id derived from SHA-256(devicePublicKey)[0..16]. */
  deviceId: string
  /** Device's 32-byte X25519 public key in base64url. */
  devicePublicKey: string
  /** Ephemeral 32-byte X25519 public key used for this wrap, in base64url. */
  ephemeralPublicKey: string
  /** 12-byte random IV in base64url. */
  iv: string
  /** Wrapped 32-byte SMK + 16-byte GCM tag in base64url. */
  wrappedKey: string
  /** Key epoch this wrap seals. */
  keyEpoch: number
  /** Human-readable device label. */
  deviceName?: string
  /** OAuth token family id (`fam_...`) so removing a device revokes its wrap as well. */
  oauthDeviceId?: string
  addedAt: number
  /**
   * The device that sealed this wrap and its proof of it (PROTOCOL.md section 4.2). A device
   * takes the key from a wrap only when this names itself or the device it confirmed a code with.
   */
  approval?: SyncWrapApproval
}

/** Who sealed a device wrap, and a MAC over the wrap only that device and the recipient compute. */
export interface SyncWrapApproval {
  approverDeviceId: string
  /** The sealing device's 32-byte X25519 sync public key in base64url. */
  approverPublicKey: string
  /** HMAC-SHA256 over the wrap, 32 bytes in base64url. */
  mac: string
}

/** Recovery wrap of the 32-byte SMK sealed with a key derived from the 128-bit recovery key. */
export interface SyncRecoveryKeyWrap {
  kdf: 'HKDF-SHA256'
  /** 16-byte random salt in base64url. */
  salt: string
  /** 12-byte random IV in base64url. */
  iv: string
  /** Wrapped 32-byte SMK + 16-byte GCM tag in base64url. */
  wrappedKey: string
  keyEpoch: number
  createdAt: number
}

/** Keybag v2: independent SMK wrapped per approved device (X25519) plus one recovery wrap. */
export interface SyncKeybagV2 {
  v: 2
  keyEpoch: number
  /** SHA-256 hex of HMAC/HKDF-derived SMK proof token, letting recovery-key self-enrollment prove SMK possession. */
  authVerifier?: string
  recovery: SyncRecoveryKeyWrap
  devices: SyncDeviceKeyWrap[]
}

export type SyncKeybag = SyncKeybagV2

/** A newly signed-in device waiting for an existing device to wrap the SMK for its public key. */
export interface SyncApprovalRequest {
  deviceId: string
  /** 32-byte X25519 public key in base64url. */
  devicePublicKey: string
  deviceName: string
  platform: string
  oauthDeviceId?: string
  createdAt: number
  expiresAt: number
  /**
   * The requesting device's commitment to a nonce it reveals once answered (PROTOCOL.md section
   * 4.1): SHA-256 of the request's public key and that nonce, 32 bytes in base64url.
   */
  commitment?: string
  /** The approving device's answer, once one answered. */
  answer?: SyncApprovalAnswer
  /** The requesting device's nonce, 32 bytes in base64url, revealed once answered. */
  reveal?: string
  /** Optional 32-hex sync device ID of the specific Mac the user chose to approve this request. */
  targetApproverDeviceId?: string
}

/** An approving device's answer to a request: its key and a nonce of its own. */
export interface SyncApprovalAnswer {
  approverDeviceId: string
  /** The approving device's 32-byte X25519 sync public key in base64url. */
  approverPublicKey: string
  approverName?: string
  /** 32 random bytes in base64url. */
  nonce: string
  answeredAt: number
}

export interface SyncScopeMeta {
  rev: number
  updatedAt: number
  updatedBy: string
  sha256: string
}

export interface SyncManifest {
  workspaceId: string
  keybag: SyncKeybag | null
  scopes: Partial<Record<SyncScope, SyncScopeMeta>>
  /** Per-item revisions for keyed scopes (such as `usage`), keyed by scope then item key. */
  items?: Partial<Record<KeyedSyncScope, Record<string, SyncScopeMeta>>>
  /** Pending device-approval requests for this account. */
  pendingApprovals?: SyncApprovalRequest[]
}

export interface SyncScopeRecord {
  scope: SyncScope
  rev: number
  updatedAt: number
  updatedBy: string
  envelope: EncryptedSyncEnvelope
}

export interface SyncItemRecord {
  scope: KeyedSyncScope
  key: string
  rev: number
  updatedAt: number
  updatedBy: string
  envelope: EncryptedSyncEnvelope
}

const BASE64URL_RE = /^[A-Za-z0-9_-]+$/
const HEX_SHA256_RE = /^[0-9a-f]{64}$/
const SYNC_DEVICE_ID_RE = /^[0-9a-f]{32}$/
const SYNC_ITEM_KEY_RE = /^[A-Za-z0-9._-]{1,64}$/
const OAUTH_FAMILY_ID_RE = /^fam_[0-9a-f]{24}$/
const MAX_KEYBAG_DEVICES = 64

function isObj(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function isKeyEpoch(value: unknown): value is number {
  return typeof value === 'number' && Number.isInteger(value) && value >= 1 && value <= 1_000_000
}

function isTimestamp(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0
}

function isKey32Base64Url(value: unknown): value is string {
  // 32 bytes in base64url without padding is always 43 characters.
  return typeof value === 'string' && value.length === 43 && BASE64URL_RE.test(value)
}

export function isSyncDeviceId(value: unknown): value is string {
  return typeof value === 'string' && SYNC_DEVICE_ID_RE.test(value)
}

export function isSyncItemKey(value: unknown): value is string {
  return typeof value === 'string' && SYNC_ITEM_KEY_RE.test(value)
}

export function isEncryptedSyncEnvelope(value: unknown): value is EncryptedSyncEnvelope {
  if (!isObj(value)) return false
  if (value.keyEpoch !== undefined && !isKeyEpoch(value.keyEpoch)) return false
  if (value.encoding !== undefined && value.encoding !== 'gzip') return false
  return (
    value.v === 1 &&
    value.alg === 'AES-256-GCM' &&
    typeof value.iv === 'string' &&
    value.iv.length === 16 &&
    BASE64URL_RE.test(value.iv) &&
    typeof value.ciphertext === 'string' &&
    value.ciphertext.length >= 22 &&
    BASE64URL_RE.test(value.ciphertext)
  )
}

export function isSyncWrapApproval(value: unknown): value is SyncWrapApproval {
  return (
    isObj(value) &&
    isSyncDeviceId(value.approverDeviceId) &&
    isKey32Base64Url(value.approverPublicKey) &&
    isKey32Base64Url(value.mac)
  )
}

export function isSyncApprovalAnswer(value: unknown): value is SyncApprovalAnswer {
  if (!isObj(value)) return false
  if (
    value.approverName !== undefined &&
    (typeof value.approverName !== 'string' || value.approverName.length > 128)
  ) {
    return false
  }
  return (
    isSyncDeviceId(value.approverDeviceId) &&
    isKey32Base64Url(value.approverPublicKey) &&
    isKey32Base64Url(value.nonce) &&
    isTimestamp(value.answeredAt)
  )
}

export function isSyncDeviceKeyWrap(value: unknown): value is SyncDeviceKeyWrap {
  if (!isObj(value)) return false
  if (value.approval !== undefined && !isSyncWrapApproval(value.approval)) return false
  if (
    value.deviceName !== undefined &&
    (typeof value.deviceName !== 'string' || value.deviceName.length > 128)
  ) {
    return false
  }
  if (
    value.oauthDeviceId !== undefined &&
    (typeof value.oauthDeviceId !== 'string' || !OAUTH_FAMILY_ID_RE.test(value.oauthDeviceId))
  ) {
    return false
  }
  return (
    isSyncDeviceId(value.deviceId) &&
    isKey32Base64Url(value.devicePublicKey) &&
    isKey32Base64Url(value.ephemeralPublicKey) &&
    typeof value.iv === 'string' &&
    value.iv.length === 16 &&
    BASE64URL_RE.test(value.iv) &&
    typeof value.wrappedKey === 'string' &&
    value.wrappedKey.length >= 40 &&
    value.wrappedKey.length <= 256 &&
    BASE64URL_RE.test(value.wrappedKey) &&
    isKeyEpoch(value.keyEpoch) &&
    isTimestamp(value.addedAt)
  )
}

export function isSyncRecoveryKeyWrap(value: unknown): value is SyncRecoveryKeyWrap {
  if (!isObj(value)) return false
  return (
    value.kdf === 'HKDF-SHA256' &&
    typeof value.salt === 'string' &&
    value.salt.length >= 16 &&
    value.salt.length <= 64 &&
    BASE64URL_RE.test(value.salt) &&
    typeof value.iv === 'string' &&
    value.iv.length === 16 &&
    BASE64URL_RE.test(value.iv) &&
    typeof value.wrappedKey === 'string' &&
    value.wrappedKey.length >= 40 &&
    value.wrappedKey.length <= 256 &&
    BASE64URL_RE.test(value.wrappedKey) &&
    isKeyEpoch(value.keyEpoch) &&
    isTimestamp(value.createdAt)
  )
}

export function isSyncKeybagV2(value: unknown): value is SyncKeybagV2 {
  if (!isObj(value)) return false
  if (value.v !== 2 || !isKeyEpoch(value.keyEpoch)) return false
  if (value.authVerifier !== undefined && !isSha256Hex(value.authVerifier)) return false
  if (!isSyncRecoveryKeyWrap(value.recovery) || value.recovery.keyEpoch !== value.keyEpoch) {
    return false
  }
  if (!Array.isArray(value.devices) || value.devices.length > MAX_KEYBAG_DEVICES) return false
  const seen = new Set<string>()
  for (const wrap of value.devices) {
    if (!isSyncDeviceKeyWrap(wrap) || wrap.keyEpoch !== value.keyEpoch) return false
    if (seen.has(wrap.deviceId)) return false
    seen.add(wrap.deviceId)
  }
  return true
}

export function isSyncKeybag(value: unknown): value is SyncKeybag {
  return isSyncKeybagV2(value)
}

export function isSyncApprovalRequest(value: unknown): value is SyncApprovalRequest {
  if (!isObj(value)) return false
  if (value.commitment !== undefined && !isKey32Base64Url(value.commitment)) return false
  if (value.answer !== undefined && !isSyncApprovalAnswer(value.answer)) return false
  if (value.reveal !== undefined && !isKey32Base64Url(value.reveal)) return false
  if (value.targetApproverDeviceId !== undefined && !isSyncDeviceId(value.targetApproverDeviceId)) {
    return false
  }
  if (
    value.oauthDeviceId !== undefined &&
    (typeof value.oauthDeviceId !== 'string' || !OAUTH_FAMILY_ID_RE.test(value.oauthDeviceId))
  ) {
    return false
  }
  return (
    isSyncDeviceId(value.deviceId) &&
    isKey32Base64Url(value.devicePublicKey) &&
    typeof value.deviceName === 'string' &&
    value.deviceName.length > 0 &&
    value.deviceName.length <= 128 &&
    typeof value.platform === 'string' &&
    value.platform.length > 0 &&
    value.platform.length <= 32 &&
    isTimestamp(value.createdAt) &&
    isTimestamp(value.expiresAt)
  )
}

export function isSha256Hex(value: unknown): value is string {
  return typeof value === 'string' && HEX_SHA256_RE.test(value)
}
