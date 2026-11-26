// Persistent X25519 sync device key and per-computer usage identifiers.

import { execFile } from 'node:child_process'
import { createHash } from 'node:crypto'
import path from 'node:path'
import {
  deriveSyncDevicePublicKey,
  generateSyncDeviceKeyPair,
  syncBase64UrlDecode,
  syncBase64UrlEncode,
} from '@shared/sync/crypto'
import { quarantineFile, readJsonFile, writeFileAtomic } from '../../core/json-file'
import type { Logger } from '../../core/log'
import type { IdentityCipher } from '../../core/remote-identity'

const SYNC_DEVICE_KEY_FILE = 'sync-device-key.json'
const VERSION = 1
const FILE_MODE = 0o600
const MAX_STORED_CHARS = 4096

export class KeychainLockedError extends Error {
  constructor(message = 'Sync device key is encrypted by Keychain, which is unavailable now') {
    super(message)
    this.name = 'KeychainLockedError'
  }
}

export interface SyncDeviceKey {
  /** 32-hex device id derived from SHA-256(publicKey)[0..16]. */
  deviceId: string
  /** 32-byte X25519 private key. */
  privateKey: Uint8Array
  /** 32-byte X25519 public key in base64url. */
  publicKeyBase64Url: string
  /** True when stored without Keychain / system encryption. */
  plainText: boolean
}

interface StoredSyncDeviceKeyFile {
  version: 1
  privateKey: string
  encrypted: boolean
  plainText: boolean
}

function parseKeyFile(raw: unknown): StoredSyncDeviceKeyFile | null {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) return null
  const { version, privateKey, encrypted, plainText } = raw as Record<string, unknown>
  if (version !== VERSION || typeof encrypted !== 'boolean' || typeof plainText !== 'boolean') {
    return null
  }
  if (
    typeof privateKey !== 'string' ||
    privateKey.length === 0 ||
    privateKey.length > MAX_STORED_CHARS
  ) {
    return null
  }
  if (!encrypted) {
    const decoded = syncBase64UrlDecode(privateKey)
    if (!decoded || decoded.length !== 32) return null
  }
  return { version, privateKey, encrypted, plainText }
}

async function saveSyncDeviceKey(
  filePath: string,
  privateKey: Uint8Array,
  cipher: IdentityCipher,
): Promise<{ plainText: boolean }> {
  const b64 = syncBase64UrlEncode(privateKey)
  const encrypted = await cipher.available()
  const plainText = !encrypted || cipher.plainText()
  const stored = encrypted ? (await cipher.encrypt(b64)).toString('base64') : b64
  const file: StoredSyncDeviceKeyFile = {
    version: VERSION,
    privateKey: stored,
    encrypted,
    plainText,
  }
  await writeFileAtomic(filePath, `${JSON.stringify(file, null, 2)}\n`, FILE_MODE)
  return { plainText }
}

/**
 * Loads or generates this daemon's persistent X25519 sync device key pair.
 * Upgrades a plaintext key file to Keychain-encrypted automatically once `cipher` is available.
 */
export async function loadSyncDeviceKey(
  dataPath: string,
  cipher: IdentityCipher,
  log?: Logger,
): Promise<SyncDeviceKey> {
  const filePath = path.join(dataPath, 'remote', SYNC_DEVICE_KEY_FILE)
  const read = await readJsonFile(filePath)
  if (read.kind === 'ok') {
    const parsed = parseKeyFile(read.value)
    if (parsed) {
      let rawPrivate: Uint8Array | null
      let shouldResave = false
      let plainText = parsed.plainText
      if (!parsed.encrypted) {
        rawPrivate = syncBase64UrlDecode(parsed.privateKey)
        if (await cipher.available()) shouldResave = true
      } else {
        if (!(await cipher.available())) {
          throw new KeychainLockedError()
        }
        try {
          const { result, shouldReEncrypt } = await cipher.decrypt(
            Buffer.from(parsed.privateKey, 'base64'),
          )
          rawPrivate = syncBase64UrlDecode(result)
          shouldResave = shouldReEncrypt
          plainText = cipher.plainText()
        } catch (error) {
          if (!(await cipher.available())) {
            throw new KeychainLockedError()
          }
          log?.warn(`Could not decrypt remote/${SYNC_DEVICE_KEY_FILE}: ${(error as Error).message}`)
          rawPrivate = null
        }
      }
      if (rawPrivate && rawPrivate.length === 32) {
        if (shouldResave) {
          plainText = (await saveSyncDeviceKey(filePath, rawPrivate, cipher)).plainText
        }
        const { publicKey, deviceId } = await deriveSyncDevicePublicKey(rawPrivate)
        return {
          deviceId,
          privateKey: rawPrivate,
          publicKeyBase64Url: syncBase64UrlEncode(publicKey),
          plainText,
        }
      }
    }
    log?.warn(`remote/${SYNC_DEVICE_KEY_FILE} is invalid; generating a new sync device key`)
    await quarantineFile(filePath).catch(() => {})
  } else if (read.kind === 'unreadable') {
    log?.warn(`remote/${SYNC_DEVICE_KEY_FILE} is unreadable; generating a new sync device key`)
    await quarantineFile(filePath).catch(() => {})
  }

  const created = await generateSyncDeviceKeyPair()
  const { plainText } = await saveSyncDeviceKey(filePath, created.privateKey, cipher)
  return {
    deviceId: created.deviceId,
    privateKey: created.privateKey,
    publicKeyBase64Url: syncBase64UrlEncode(created.publicKey),
    plainText,
  }
}

/** Reads the macOS hardware UUID asynchronously without blocking the event loop. */
function readMacHardwareUuid(): Promise<string | null> {
  if (process.platform !== 'darwin') return Promise.resolve(null)
  return new Promise((resolve) => {
    execFile(
      '/usr/sbin/ioreg',
      ['-rd1', '-c', 'IOPlatformExpertDevice'],
      { timeout: 5_000, maxBuffer: 64 * 1024 },
      (error, stdout) => {
        if (error) {
          resolve(null)
          return
        }
        const match = /"IOPlatformUUID"\s*=\s*"([^"]+)"/.exec(stdout)
        resolve(match?.[1]?.trim() || null)
      },
    )
  })
}

export interface UsageDeviceIds {
  deviceId: string
  previousDeviceId?: string
}

export function usageDeviceIds(uuid: string | null, syncDeviceId: string): UsageDeviceIds {
  const identity = uuid ?? `sync:${syncDeviceId}`
  const hash = (namespace: string): string =>
    createHash('sha256').update(`${namespace}:${identity}`).digest('hex').slice(0, 16)
  return {
    deviceId: hash('sarto'),
    // Older daemons published the same computer's buckets under this namespace.
    previousDeviceId: hash('llm-usage-island'),
  }
}

export async function resolveUsageDeviceIds(syncDeviceId: string): Promise<UsageDeviceIds> {
  return usageDeviceIds(await readMacHardwareUuid(), syncDeviceId)
}
