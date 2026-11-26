// Zero-knowledge E2EE primitives for Sarto Workspace Sync.
// Uses WebCrypto (AES-256-GCM, HKDF-SHA256, X25519, SHA-256) and standard
// CompressionStream/DecompressionStream so Node.js, Electron, browsers, and Apple CryptoKit
// interoperate byte-for-byte with zero external dependencies.

import {
  isEncryptedSyncEnvelope,
  isSyncDeviceKeyWrap,
  isSyncItemKey,
  isSyncRecoveryKeyWrap,
  type EncryptedSyncEnvelope,
  type KeyedSyncScope,
  type SyncDeviceKeyWrap,
  type SyncKeybagV2,
  type SyncRecoveryKeyWrap,
  type SyncScope,
} from './protocol'
import { isSyncWrapApproval } from './wire'

const IV_BYTES = 12
const KEY_BYTES = 32
const SALT_BYTES = 16
const RECOVERY_KEY_BYTES = 16
const MAX_GUNZIP_BYTES = 32 * 1024 * 1024

// Crockford Base32 alphabet: 32 unambiguous symbols (no I, L, O, U).
const CROCKFORD = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'
const CROCKFORD_INDEX = new Map<string, number>([...CROCKFORD].map((ch, idx) => [ch, idx]))

// An X25519 private key in PKCS #8 is this 16-byte prefix followed by the 32 raw key bytes (RFC 8410).
const X25519_PKCS8_PREFIX = new Uint8Array([
  0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x04, 0x22, 0x04, 0x20,
])
// The X25519 base point (u = 9), used to derive a public key from a raw private key.
const X25519_BASE_POINT = new Uint8Array(32)
X25519_BASE_POINT[0] = 9

type WebCryptoKey = InstanceType<typeof CryptoKey>

const encoder = new TextEncoder()
const decoder = new TextDecoder('utf-8', { fatal: true })

const asBufferView = (bytes: Uint8Array): Uint8Array<ArrayBuffer> =>
  bytes as Uint8Array<ArrayBuffer>

function concatBytes(...parts: Uint8Array[]): Uint8Array<ArrayBuffer> {
  const total = parts.reduce((sum, part) => sum + part.length, 0)
  const out = new Uint8Array(total)
  let offset = 0
  for (const part of parts) {
    out.set(part, offset)
    offset += part.length
  }
  return out
}

function isAllZero(bytes: Uint8Array): boolean {
  let acc = 0
  for (let i = 0; i < bytes.length; i++) acc |= bytes[i]!
  return acc === 0
}

export function syncBase64UrlEncode(bytes: Uint8Array): string {
  const chunk = 0x8000
  const parts: string[] = []
  for (let i = 0; i < bytes.length; i += chunk) {
    parts.push(String.fromCharCode(...bytes.subarray(i, i + chunk)))
  }
  return btoa(parts.join('')).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

export function syncBase64UrlDecode(text: string): Uint8Array | null {
  if (!/^[A-Za-z0-9_-]*$/.test(text) || text.length % 4 === 1) return null
  try {
    const padded = text.replace(/-/g, '+').replace(/_/g, '/')
    const binary = atob(padded)
    const out = new Uint8Array(binary.length)
    for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i)
    return out
  } catch {
    return null
  }
}

export async function sha256Bytes(bytes: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest('SHA-256', asBufferView(bytes)))
}

export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await sha256Bytes(bytes)
  let hex = ''
  for (let i = 0; i < digest.length; i++) {
    hex += digest[i]!.toString(16).padStart(2, '0')
  }
  return hex
}

export function generateMasterKey(): Uint8Array {
  return crypto.getRandomValues(new Uint8Array(KEY_BYTES))
}

/** Derives a 256-bit subkey via RFC 5869 HKDF-SHA256. */
export async function hkdfSha256(
  ikm: Uint8Array,
  salt: Uint8Array,
  info: string,
): Promise<Uint8Array> {
  const baseKey = await crypto.subtle.importKey('raw', asBufferView(ikm), 'HKDF', false, [
    'deriveBits',
  ])
  const bits = await crypto.subtle.deriveBits(
    {
      name: 'HKDF',
      hash: 'SHA-256',
      salt: asBufferView(salt),
      info: encoder.encode(info),
    },
    baseKey,
    KEY_BYTES * 8,
  )
  return new Uint8Array(bits)
}

// --- Keybag v2: Sync Device X25519 Keys, Sealed-Box Device Wraps & 128-bit Recovery Key ---

async function importX25519Private(rawPrivateKey: Uint8Array): Promise<WebCryptoKey> {
  if (rawPrivateKey.length !== KEY_BYTES)
    throw new RangeError('X25519 private key must be 32 bytes')
  const pkcs8 = concatBytes(X25519_PKCS8_PREFIX, rawPrivateKey)
  return crypto.subtle.importKey('pkcs8', pkcs8, 'X25519', false, ['deriveBits'])
}

async function x25519Dh(
  privateKey: WebCryptoKey,
  remotePublicKey: Uint8Array,
): Promise<Uint8Array> {
  if (remotePublicKey.length !== KEY_BYTES) {
    throw new RangeError('X25519 public key must be 32 bytes')
  }
  const pub = await crypto.subtle.importKey(
    'raw',
    asBufferView(remotePublicKey),
    'X25519',
    true,
    [],
  )
  const shared = new Uint8Array(
    await crypto.subtle.deriveBits({ name: 'X25519', public: pub }, privateKey, 256),
  )
  if (isAllZero(shared)) throw new Error('X25519 key agreement produced all-zero secret')
  return shared
}

/** The 32-hex device key id derived from a 32-byte X25519 sync device public key. */
export async function syncDeviceIdFromPublicKey(publicKey: Uint8Array): Promise<string> {
  if (publicKey.length !== KEY_BYTES)
    throw new RangeError('Sync device public key must be 32 bytes')
  return (await sha256Hex(publicKey)).slice(0, 32)
}

/** Generates a fresh X25519 sync device key pair (32-byte raw keys + 32-hex device id). */
export async function generateSyncDeviceKeyPair(): Promise<{
  privateKey: Uint8Array
  publicKey: Uint8Array
  deviceId: string
}> {
  const pair = await crypto.subtle.generateKey('X25519', true, ['deriveBits'])
  if (!('privateKey' in pair)) throw new Error('X25519 gave no key pair')
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey('pkcs8', pair.privateKey))
  const hasPrefix =
    pkcs8.length >= X25519_PKCS8_PREFIX.length + KEY_BYTES &&
    X25519_PKCS8_PREFIX.every((b, idx) => pkcs8[idx] === b)
  const privateKey = hasPrefix
    ? pkcs8.slice(X25519_PKCS8_PREFIX.length, X25519_PKCS8_PREFIX.length + KEY_BYTES)
    : pkcs8.slice(pkcs8.length - KEY_BYTES)
  const publicKey = new Uint8Array(await crypto.subtle.exportKey('raw', pair.publicKey))
  const deviceId = await syncDeviceIdFromPublicKey(publicKey)
  return { privateKey, publicKey, deviceId }
}

/** Derives the 32-byte X25519 public key and 32-hex device id from a 32-byte raw private key. */
export async function deriveSyncDevicePublicKey(privateKey: Uint8Array): Promise<{
  publicKey: Uint8Array
  deviceId: string
}> {
  const key = await importX25519Private(privateKey)
  const publicKey = await x25519Dh(key, X25519_BASE_POINT)
  const deviceId = await syncDeviceIdFromPublicKey(publicKey)
  return { publicKey, deviceId }
}

/** The first 40 bits of a digest as 8 Crockford base32 characters, `XXXX-XXXX`. */
function shortCode(digest: Uint8Array): string {
  let bits = 0
  let bitCount = 0
  let chars = ''
  for (let i = 0; i < 5; i++) {
    bits = (bits << 8) | digest[i]!
    bitCount += 8
    while (bitCount >= 5) {
      bitCount -= 5
      chars += CROCKFORD[(bits >>> bitCount) & 31]!
    }
  }
  return `${chars.slice(0, 4)}-${chars.slice(4, 8)}`
}

/**
 * What a device asking for approval commits to before any device answers it (PROTOCOL.md section
 * 4.1): its key and the nonce it reveals once answered, in base64url.
 */
export async function approvalCommitment(
  devicePublicKey: string,
  deviceNonce: string,
): Promise<string> {
  const digest = await sha256Bytes(
    encoder.encode(`sarto-approval-v2/commit\n${devicePublicKey}\n${deviceNonce}`),
  )
  return syncBase64UrlEncode(digest)
}

/**
 * The code both devices show while one approves the other (PROTOCOL.md section 4.1). Each nonce
 * was fixed before its device saw the other's, so no one placed between them can choose a key or
 * a nonce that gives the code the other device shows.
 */
export async function approvalCode(input: {
  accountId: string
  devicePublicKey: string
  approverPublicKey: string
  deviceNonce: string
  approverNonce: string
}): Promise<string> {
  const text = [
    'sarto-approval-v2/code',
    input.accountId,
    input.devicePublicKey,
    input.approverPublicKey,
    input.deviceNonce,
    input.approverNonce,
  ].join('\n')
  return shortCode(await sha256Bytes(encoder.encode(text)))
}

/** The MAC key two devices share for a wrap one seals to the other (PROTOCOL.md section 4.2). */
async function wrapApprovalKey(
  ownPrivateKey: Uint8Array,
  otherPublicKey: string,
  approverPublicKey: string,
  devicePublicKey: string,
): Promise<WebCryptoKey> {
  const other = syncBase64UrlDecode(otherPublicKey)
  if (!other || other.length !== KEY_BYTES) throw new Error('Invalid X25519 public key')
  const shared = await x25519Dh(await importX25519Private(ownPrivateKey), other)
  const raw = await hkdfSha256(
    shared,
    encoder.encode('sarto-keybag-v2/approval-salt'),
    `sarto-keybag-v2/approval\n${approverPublicKey}\n${devicePublicKey}`,
  )
  return crypto.subtle.importKey(
    'raw',
    asBufferView(raw),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign', 'verify'],
  )
}

function wrapApprovalText(wrap: SyncDeviceKeyWrap, accountId: string): Uint8Array {
  return encoder.encode(
    [
      'sarto-keybag-v2/approval',
      accountId,
      wrap.deviceId,
      String(wrap.keyEpoch),
      wrap.ephemeralPublicKey,
      wrap.iv,
      wrap.wrappedKey,
    ].join('\n'),
  )
}

/** `wrap` with the approval of the device holding `approverPrivateKey`, which sealed it. */
export async function approveWrap(
  wrap: SyncDeviceKeyWrap,
  approverPrivateKey: Uint8Array,
  approverPublicKey: string,
  accountId: string,
): Promise<SyncDeviceKeyWrap> {
  const own = await deriveSyncDevicePublicKey(approverPrivateKey)
  if (syncBase64UrlEncode(own.publicKey) !== approverPublicKey) {
    throw new Error('The approving key is not this device key')
  }
  const key = await wrapApprovalKey(
    approverPrivateKey,
    wrap.devicePublicKey,
    approverPublicKey,
    wrap.devicePublicKey,
  )
  const mac = new Uint8Array(
    await crypto.subtle.sign('HMAC', key, asBufferView(wrapApprovalText(wrap, accountId))),
  )
  return {
    ...wrap,
    approval: {
      approverDeviceId: own.deviceId,
      approverPublicKey,
      mac: syncBase64UrlEncode(mac),
    },
  }
}

/**
 * Whether `wrap`, sealed to the device holding `ownPrivateKey`, carries the approval of one of
 * `trustedApprovers`: this device's own key, or the key of a device the user confirmed a code with.
 */
export async function verifyWrapApproval(
  wrap: SyncDeviceKeyWrap,
  ownPrivateKey: Uint8Array,
  trustedApprovers: readonly string[],
  accountId: string,
): Promise<boolean> {
  const approval = wrap.approval
  if (!isSyncWrapApproval(approval) || !trustedApprovers.includes(approval.approverPublicKey)) {
    return false
  }
  const mac = syncBase64UrlDecode(approval.mac)
  if (!mac) return false
  try {
    const key = await wrapApprovalKey(
      ownPrivateKey,
      approval.approverPublicKey,
      approval.approverPublicKey,
      wrap.devicePublicKey,
    )
    return await crypto.subtle.verify(
      'HMAC',
      key,
      asBufferView(mac),
      asBufferView(wrapApprovalText(wrap, accountId)),
    )
  } catch {
    return false
  }
}

async function recoveryChecksum12(raw: Uint8Array): Promise<number> {
  const digest = await sha256Bytes(concatBytes(encoder.encode('sarto-recovery-check-v1:'), raw))
  return ((digest[0]! << 4) | (digest[1]! >>> 4)) & 0xfff
}

/**
 * Generates a 128-bit random recovery key formatted as 7 groups of 4 Crockford Base32 characters
 * (128 bits of entropy + 12-bit SHA-256 checksum = 140 bits = 28 symbols).
 */
export async function generateRecoveryKey(): Promise<string> {
  const raw = crypto.getRandomValues(new Uint8Array(RECOVERY_KEY_BYTES))
  const check = await recoveryChecksum12(raw)
  let bitBuffer = 0
  let bitCount = 0
  let chars = ''
  for (let i = 0; i < raw.length; i++) {
    bitBuffer = (bitBuffer << 8) | raw[i]!
    bitCount += 8
    while (bitCount >= 5) {
      bitCount -= 5
      chars += CROCKFORD[(bitBuffer >>> bitCount) & 31]!
    }
  }
  // Remaining 3 bits + 12-bit checksum = 15 bits = 3 Base32 characters.
  bitBuffer = (bitBuffer << 12) | check
  bitCount += 12
  while (bitCount >= 5) {
    bitCount -= 5
    chars += CROCKFORD[(bitBuffer >>> bitCount) & 31]!
  }
  return [
    chars.slice(0, 4),
    chars.slice(4, 8),
    chars.slice(8, 12),
    chars.slice(12, 16),
    chars.slice(16, 20),
    chars.slice(20, 24),
    chars.slice(24, 28),
  ].join('-')
}

/** Parses and checksum-verifies a recovery key string; returns the 16 raw bytes or null. */
export async function parseRecoveryKey(input: string): Promise<Uint8Array | null> {
  const stripped = input
    .trim()
    .toUpperCase()
    .replace(/^SARTO-/, '')
    .replace(/[\s-]+/g, '')
    .replace(/O/g, '0')
    .replace(/[IL]/g, '1')
  if (stripped.length !== 28) return null
  const raw = new Uint8Array(RECOVERY_KEY_BYTES)
  let bitBuffer = 0
  let bitCount = 0
  let outIndex = 0
  for (let i = 0; i < stripped.length; i++) {
    const val = CROCKFORD_INDEX.get(stripped[i]!)
    if (val === undefined) return null
    bitBuffer = (bitBuffer << 5) | val
    bitCount += 5
    while (bitCount >= 8 && outIndex < RECOVERY_KEY_BYTES) {
      bitCount -= 8
      raw[outIndex++] = (bitBuffer >>> bitCount) & 0xff
    }
  }
  if (outIndex !== RECOVERY_KEY_BYTES || bitCount !== 12) return null
  const providedCheck = bitBuffer & 0xfff
  const expectedCheck = await recoveryChecksum12(raw)
  return providedCheck === expectedCheck ? raw : null
}

/**
 * Derives an irreversible proof token from the SMK for a given account so a device unlocking via
 * the recovery key can prove SMK possession to the relay when registering its own wrap.
 */
export async function deriveKeybagAuthToken(
  masterKey: Uint8Array,
  accountId: string,
): Promise<string> {
  if (masterKey.length !== KEY_BYTES) throw new RangeError('SMK must be 32 bytes')
  const raw = await hkdfSha256(
    masterKey,
    encoder.encode('sarto-keybag-v2-auth-salt'),
    `sarto-keybag-v2/auth/${accountId}`,
  )
  return syncBase64UrlEncode(raw)
}

/** One-way SHA-256 hex verifier stored on Keybag v2 (never reveals the proof token or SMK). */
export async function computeKeybagAuthVerifier(
  masterKey: Uint8Array,
  accountId: string,
): Promise<string> {
  const token = await deriveKeybagAuthToken(masterKey, accountId)
  return sha256Hex(encoder.encode(token))
}

/** Seals the 32-byte SMK with a key derived (HKDF-SHA256) from the 128-bit recovery key. */
export async function wrapMasterKeyWithRecoveryKey(
  masterKey: Uint8Array,
  recoveryKey: string,
  keyEpoch = 1,
  createdAt = Date.now(),
  accountId?: string,
): Promise<SyncRecoveryKeyWrap> {
  if (masterKey.length !== KEY_BYTES) throw new RangeError('SMK must be 32 bytes')
  const rawRecovery = await parseRecoveryKey(recoveryKey)
  if (!rawRecovery) throw new Error('Invalid recovery key')
  const salt = crypto.getRandomValues(new Uint8Array(SALT_BYTES))
  const iv = crypto.getRandomValues(new Uint8Array(IV_BYTES))
  const kekRaw = await hkdfSha256(rawRecovery, salt, 'sarto-keybag-v2/recovery')
  const kek = await crypto.subtle.importKey('raw', asBufferView(kekRaw), 'AES-GCM', false, [
    'encrypt',
  ])
  const aad = encoder.encode(
    accountId
      ? `sarto-keybag-v2:recovery:${keyEpoch}:${accountId}`
      : `sarto-keybag-v2:recovery:${keyEpoch}`,
  )
  const wrapped = new Uint8Array(
    await crypto.subtle.encrypt(
      { name: 'AES-GCM', iv: asBufferView(iv), additionalData: aad },
      kek,
      asBufferView(masterKey),
    ),
  )
  return {
    kdf: 'HKDF-SHA256',
    salt: syncBase64UrlEncode(salt),
    iv: syncBase64UrlEncode(iv),
    wrappedKey: syncBase64UrlEncode(wrapped),
    keyEpoch,
    createdAt,
  }
}

/** Unwraps the 32-byte SMK using the 128-bit recovery key; throws on typo or wrong key. */
export async function unwrapMasterKeyWithRecoveryKey(
  wrap: SyncRecoveryKeyWrap,
  recoveryKey: string,
  accountId?: string,
): Promise<Uint8Array> {
  if (!isSyncRecoveryKeyWrap(wrap)) throw new Error('Invalid recovery wrap')
  const rawRecovery = await parseRecoveryKey(recoveryKey)
  if (!rawRecovery) throw new Error('Invalid recovery key')
  const salt = syncBase64UrlDecode(wrap.salt)
  const iv = syncBase64UrlDecode(wrap.iv)
  const wrapped = syncBase64UrlDecode(wrap.wrappedKey)
  if (!salt || !iv || iv.length !== IV_BYTES || !wrapped) {
    throw new Error('Malformed recovery wrap encoding')
  }
  const kekRaw = await hkdfSha256(rawRecovery, salt, 'sarto-keybag-v2/recovery')
  const kek = await crypto.subtle.importKey('raw', asBufferView(kekRaw), 'AES-GCM', false, [
    'decrypt',
  ])
  const aad = encoder.encode(
    accountId
      ? `sarto-keybag-v2:recovery:${wrap.keyEpoch}:${accountId}`
      : `sarto-keybag-v2:recovery:${wrap.keyEpoch}`,
  )
  const raw = new Uint8Array(
    await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: asBufferView(iv), additionalData: aad },
      kek,
      asBufferView(wrapped),
    ),
  )
  if (raw.length !== KEY_BYTES) throw new Error('Unwrapped SMK is not 32 bytes')
  return raw
}

/** Seals the 32-byte SMK to a device's X25519 sync public key using an ephemeral sealed box. */
export async function sealMasterKeyForDevice(
  masterKey: Uint8Array,
  recipientPublicKeyBase64Url: string,
  options?: {
    keyEpoch?: number
    deviceName?: string
    oauthDeviceId?: string
    addedAt?: number
    accountId?: string
  },
): Promise<SyncDeviceKeyWrap> {
  if (masterKey.length !== KEY_BYTES) throw new RangeError('SMK must be 32 bytes')
  const recipientPub = syncBase64UrlDecode(recipientPublicKeyBase64Url)
  if (!recipientPub || recipientPub.length !== KEY_BYTES) {
    throw new Error('Invalid recipient X25519 public key')
  }
  const deviceId = await syncDeviceIdFromPublicKey(recipientPub)
  const keyEpoch = options?.keyEpoch ?? 1
  const eph = await crypto.subtle.generateKey('X25519', true, ['deriveBits'])
  if (!('privateKey' in eph)) throw new Error('X25519 gave no key pair')
  const ephPub = new Uint8Array(await crypto.subtle.exportKey('raw', eph.publicKey))
  const shared = await x25519Dh(eph.privateKey, recipientPub)
  const salt = concatBytes(ephPub, recipientPub)
  const kekRaw = await hkdfSha256(shared, salt, 'sarto-keybag-v2/device-wrap')
  const kek = await crypto.subtle.importKey('raw', asBufferView(kekRaw), 'AES-GCM', false, [
    'encrypt',
  ])
  const iv = crypto.getRandomValues(new Uint8Array(IV_BYTES))
  const aad = encoder.encode(
    options?.accountId
      ? `sarto-keybag-v2:device:${deviceId}:${keyEpoch}:${options.accountId}`
      : `sarto-keybag-v2:device:${deviceId}:${keyEpoch}`,
  )
  const wrapped = new Uint8Array(
    await crypto.subtle.encrypt(
      { name: 'AES-GCM', iv: asBufferView(iv), additionalData: aad },
      kek,
      asBufferView(masterKey),
    ),
  )
  return {
    deviceId,
    devicePublicKey: syncBase64UrlEncode(recipientPub),
    ephemeralPublicKey: syncBase64UrlEncode(ephPub),
    iv: syncBase64UrlEncode(iv),
    wrappedKey: syncBase64UrlEncode(wrapped),
    keyEpoch,
    ...(options?.deviceName ? { deviceName: options.deviceName.slice(0, 128) } : {}),
    ...(options?.oauthDeviceId ? { oauthDeviceId: options.oauthDeviceId } : {}),
    addedAt: options?.addedAt ?? Date.now(),
  }
}

/** Opens a device's X25519 sealed-box wrap of the SMK with the device's 32-byte private key. */
export async function openMasterKeyForDevice(
  wrap: SyncDeviceKeyWrap,
  recipientPrivateKey: Uint8Array,
  accountId?: string,
): Promise<Uint8Array> {
  if (!isSyncDeviceKeyWrap(wrap)) throw new Error('Invalid device key wrap')
  const own = await deriveSyncDevicePublicKey(recipientPrivateKey)
  if (
    wrap.deviceId !== own.deviceId ||
    wrap.devicePublicKey !== syncBase64UrlEncode(own.publicKey)
  ) {
    throw new Error('Device key wrap does not match this device key')
  }
  const ephPub = syncBase64UrlDecode(wrap.ephemeralPublicKey)
  const iv = syncBase64UrlDecode(wrap.iv)
  const wrapped = syncBase64UrlDecode(wrap.wrappedKey)
  if (!ephPub || ephPub.length !== KEY_BYTES || !iv || iv.length !== IV_BYTES || !wrapped) {
    throw new Error('Malformed device key wrap encoding')
  }
  const privKey = await importX25519Private(recipientPrivateKey)
  const shared = await x25519Dh(privKey, ephPub)
  const salt = concatBytes(ephPub, own.publicKey)
  const kekRaw = await hkdfSha256(shared, salt, 'sarto-keybag-v2/device-wrap')
  const kek = await crypto.subtle.importKey('raw', asBufferView(kekRaw), 'AES-GCM', false, [
    'decrypt',
  ])
  const aad = encoder.encode(
    accountId
      ? `sarto-keybag-v2:device:${wrap.deviceId}:${wrap.keyEpoch}:${accountId}`
      : `sarto-keybag-v2:device:${wrap.deviceId}:${wrap.keyEpoch}`,
  )
  const raw = new Uint8Array(
    await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: asBufferView(iv), additionalData: aad },
      kek,
      asBufferView(wrapped),
    ),
  )
  if (raw.length !== KEY_BYTES) throw new Error('Unwrapped SMK is not 32 bytes')
  return raw
}

/** Creates a fresh Keybag v2 (initial device wrap + 128-bit recovery wrap) for `masterKey`. */
export async function createKeybagV2(
  masterKey: Uint8Array,
  devicePublicKeyBase64Url: string,
  options?: {
    keyEpoch?: number
    deviceName?: string
    oauthDeviceId?: string
    accountId?: string
    now?: number
  },
): Promise<{ keybag: SyncKeybagV2; recoveryKey: string }> {
  const keyEpoch = options?.keyEpoch ?? 1
  const now = options?.now ?? Date.now()
  const recoveryKey = await generateRecoveryKey()
  const [recovery, deviceWrap, authVerifier] = await Promise.all([
    wrapMasterKeyWithRecoveryKey(masterKey, recoveryKey, keyEpoch, now, options?.accountId),
    sealMasterKeyForDevice(masterKey, devicePublicKeyBase64Url, {
      keyEpoch,
      ...(options?.deviceName ? { deviceName: options.deviceName } : {}),
      ...(options?.oauthDeviceId ? { oauthDeviceId: options.oauthDeviceId } : {}),
      ...(options?.accountId ? { accountId: options.accountId } : {}),
      addedAt: now,
    }),
    options?.accountId
      ? computeKeybagAuthVerifier(masterKey, options.accountId)
      : Promise.resolve(undefined),
  ])
  return {
    keybag: {
      v: 2,
      keyEpoch,
      ...(authVerifier ? { authVerifier } : {}),
      recovery,
      devices: [deviceWrap],
    },
    recoveryKey,
  }
}

// --- Scope, Keyed Item & CAS Blob Encryption ---

async function gzipBytes(data: Uint8Array): Promise<Uint8Array> {
  const stream = new Blob([asBufferView(data)]).stream().pipeThrough(new CompressionStream('gzip'))
  const reader = stream.getReader()
  const chunks: Uint8Array[] = []
  for (;;) {
    const { done, value } = await reader.read()
    if (done) break
    if (value) chunks.push(value)
  }
  return concatBytes(...chunks)
}

async function gunzipBytes(data: Uint8Array, maxBytes = MAX_GUNZIP_BYTES): Promise<Uint8Array> {
  const stream = new Blob([asBufferView(data)])
    .stream()
    .pipeThrough(new DecompressionStream('gzip'))
  const reader = stream.getReader()
  const chunks: Uint8Array[] = []
  let total = 0
  try {
    for (;;) {
      const { done, value } = await reader.read()
      if (done) break
      if (!value) continue
      total += value.byteLength
      if (total > maxBytes) {
        await reader.cancel().catch(() => {})
        throw new Error('Decompressed sync payload exceeds limit')
      }
      chunks.push(value)
    }
  } finally {
    await reader.cancel().catch(() => {})
  }
  return concatBytes(...chunks)
}

async function importScopeAesKey(masterKey: Uint8Array, purpose: string): Promise<WebCryptoKey> {
  if (masterKey.length !== KEY_BYTES) throw new RangeError('SMK must be 32 bytes')
  const subkey = await hkdfSha256(
    masterKey,
    encoder.encode('sarto-sync-subkey-salt-v1'),
    `sarto-sync-v1/${purpose}`,
  )
  return crypto.subtle.importKey('raw', asBufferView(subkey), 'AES-GCM', false, [
    'encrypt',
    'decrypt',
  ])
}

/** Encrypts a JSON document for `scope` at `rev` (bound via AES-GCM AAD to block cross-scope/epoch/encoding tampering). */
export async function sealScopeJson(
  masterKey: Uint8Array,
  scope: SyncScope,
  rev: number,
  payload: unknown,
  options?: { keyEpoch?: number },
): Promise<EncryptedSyncEnvelope> {
  const key = await importScopeAesKey(masterKey, `scope/${scope}`)
  const iv = crypto.getRandomValues(new Uint8Array(IV_BYTES))
  const keyEpoch = options?.keyEpoch ?? 1
  const aad = encoder.encode(`sarto-sync-v1:${scope}:${rev}:e${keyEpoch}:json`)
  const plaintext = encoder.encode(JSON.stringify(payload))
  const ciphertext = new Uint8Array(
    await crypto.subtle.encrypt(
      { name: 'AES-GCM', iv: asBufferView(iv), additionalData: aad },
      key,
      plaintext,
    ),
  )
  return {
    v: 1,
    alg: 'AES-256-GCM',
    iv: syncBase64UrlEncode(iv),
    ciphertext: syncBase64UrlEncode(ciphertext),
    ...(options?.keyEpoch !== undefined ? { keyEpoch: options.keyEpoch } : {}),
  }
}

/** Decrypts and parses a JSON document for `scope` at `rev`; throws if tampered or wrong key/rev/epoch/encoding. */
export async function openScopeJson<T>(
  masterKey: Uint8Array,
  scope: SyncScope,
  rev: number,
  envelope: EncryptedSyncEnvelope,
): Promise<T> {
  if (!isEncryptedSyncEnvelope(envelope)) throw new Error('Invalid encrypted sync envelope')
  const iv = syncBase64UrlDecode(envelope.iv)
  const ciphertext = syncBase64UrlDecode(envelope.ciphertext)
  if (!iv || iv.length !== IV_BYTES || !ciphertext) {
    throw new Error('Malformed encrypted sync envelope')
  }
  const key = await importScopeAesKey(masterKey, `scope/${scope}`)
  const keyEpoch = envelope.keyEpoch ?? 1
  const encoding = envelope.encoding ?? 'json'
  const aad = encoder.encode(`sarto-sync-v1:${scope}:${rev}:e${keyEpoch}:${encoding}`)
  const decrypted = new Uint8Array(
    await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: asBufferView(iv), additionalData: aad },
      key,
      asBufferView(ciphertext),
    ),
  )
  const plaintext = envelope.encoding === 'gzip' ? await gunzipBytes(decrypted) : decrypted
  return JSON.parse(decoder.decode(plaintext)) as T
}

/**
 * Encrypts a JSON document for a keyed scope record `(scope, itemKey)` at `rev`.
 * Gzip-compresses the JSON before encryption by default (used for per-Mac `usage` records).
 */
export async function sealItemJson(
  masterKey: Uint8Array,
  scope: KeyedSyncScope,
  itemKey: string,
  rev: number,
  payload: unknown,
  options?: { compress?: boolean; keyEpoch?: number },
): Promise<EncryptedSyncEnvelope> {
  if (!isSyncItemKey(itemKey)) throw new Error('Invalid sync item key')
  const key = await importScopeAesKey(masterKey, `scope/${scope}`)
  const iv = crypto.getRandomValues(new Uint8Array(IV_BYTES))
  const keyEpoch = options?.keyEpoch ?? 1
  const compress = options?.compress ?? true
  const encoding = compress ? 'gzip' : 'json'
  const aad = encoder.encode(`sarto-sync-v1:${scope}:${itemKey}:${rev}:e${keyEpoch}:${encoding}`)
  const raw = encoder.encode(JSON.stringify(payload))
  const plaintext = compress ? await gzipBytes(raw) : raw
  const ciphertext = new Uint8Array(
    await crypto.subtle.encrypt(
      { name: 'AES-GCM', iv: asBufferView(iv), additionalData: aad },
      key,
      asBufferView(plaintext),
    ),
  )
  return {
    v: 1,
    alg: 'AES-256-GCM',
    iv: syncBase64UrlEncode(iv),
    ciphertext: syncBase64UrlEncode(ciphertext),
    ...(options?.keyEpoch !== undefined ? { keyEpoch: options.keyEpoch } : {}),
    ...(compress ? { encoding: 'gzip' as const } : {}),
  }
}

/** Decrypts and parses a keyed scope record `(scope, itemKey)` at `rev`. */
export async function openItemJson<T>(
  masterKey: Uint8Array,
  scope: KeyedSyncScope,
  itemKey: string,
  rev: number,
  envelope: EncryptedSyncEnvelope,
): Promise<T> {
  if (!isSyncItemKey(itemKey)) throw new Error('Invalid sync item key')
  if (!isEncryptedSyncEnvelope(envelope)) throw new Error('Invalid encrypted sync envelope')
  const iv = syncBase64UrlDecode(envelope.iv)
  const ciphertext = syncBase64UrlDecode(envelope.ciphertext)
  if (!iv || iv.length !== IV_BYTES || !ciphertext) {
    throw new Error('Malformed encrypted sync envelope')
  }
  const key = await importScopeAesKey(masterKey, `scope/${scope}`)
  const keyEpoch = envelope.keyEpoch ?? 1
  const encoding = envelope.encoding ?? 'json'
  const aad = encoder.encode(`sarto-sync-v1:${scope}:${itemKey}:${rev}:e${keyEpoch}:${encoding}`)
  const decrypted = new Uint8Array(
    await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: asBufferView(iv), additionalData: aad },
      key,
      asBufferView(ciphertext),
    ),
  )
  const plaintext = envelope.encoding === 'gzip' ? await gunzipBytes(decrypted) : decrypted
  return JSON.parse(decoder.decode(plaintext)) as T
}

/** Seals a binary CAS blob (such as a packed Skill archive) with AES-256-GCM. */
export async function sealSyncBlob(
  masterKey: Uint8Array,
  plaintext: Uint8Array,
): Promise<{ iv: string; ciphertext: Uint8Array; blobSha256: string }> {
  const key = await importScopeAesKey(masterKey, 'cas-blob')
  const ivBytes = crypto.getRandomValues(new Uint8Array(IV_BYTES))
  const aad = encoder.encode('sarto-sync-blob-v1')
  const ciphertext = new Uint8Array(
    await crypto.subtle.encrypt(
      { name: 'AES-GCM', iv: asBufferView(ivBytes), additionalData: aad },
      key,
      asBufferView(plaintext),
    ),
  )
  const blobSha256 = await sha256Hex(ciphertext)
  return { iv: syncBase64UrlEncode(ivBytes), ciphertext, blobSha256 }
}

/** Verifies SHA-256 and opens an encrypted CAS blob. */
export async function openSyncBlob(
  masterKey: Uint8Array,
  ivBase64Url: string,
  ciphertext: Uint8Array,
  expectedSha256: string,
): Promise<Uint8Array> {
  const actualHash = await sha256Hex(ciphertext)
  if (actualHash !== expectedSha256) {
    throw new Error(`Sync blob hash mismatch: expected ${expectedSha256}, got ${actualHash}`)
  }
  const iv = syncBase64UrlDecode(ivBase64Url)
  if (!iv || iv.length !== IV_BYTES) throw new Error('Invalid blob IV')
  const key = await importScopeAesKey(masterKey, 'cas-blob')
  const aad = encoder.encode('sarto-sync-blob-v1')
  return new Uint8Array(
    await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: asBufferView(iv), additionalData: aad },
      key,
      asBufferView(ciphertext),
    ),
  )
}
