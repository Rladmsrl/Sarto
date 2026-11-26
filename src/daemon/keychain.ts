// macOS Keychain-backed IdentityCipher for the Sarto daemon.
// Stores a single 32-byte local master wrapping key per data folder in the user's login keychain
// via `/usr/bin/security` (asynchronously, with secrets piped over stdin to `security -i` so they
// never appear in process argv), then seals local secrets (refresh token, SMK, sync device private
// key, MCP vault replica) with AES-256-GCM in memory. When the keychain is unavailable or locked
// (such as on a headless Mac or non-macOS host), falls back cleanly to NO_SYSTEM_ENCRYPTION and
// reports `plainText() === true`.

import { execFile, spawn } from 'node:child_process'
import { createCipheriv, createDecipheriv, createHash, randomBytes } from 'node:crypto'
import { realpath } from 'node:fs/promises'
import path from 'node:path'
import type { Logger } from '../core/log'
import type { IdentityCipher } from '../core/remote-identity'
import { NO_SYSTEM_ENCRYPTION } from './key'

const SERVICE_NAME = 'dev.sarto.daemon'
/** The Keychain service the daemon keeps its data folders' wrapping keys under. */
export const KEYCHAIN_SERVICE = SERVICE_NAME
const KEY_BYTES = 32
const IV_BYTES = 12
const TAG_BYTES = 16
const MAGIC = Buffer.from('SKC1', 'ascii')
const AAD = Buffer.from('sarto-keychain-cipher-v1', 'ascii')
const SAFE_IDENT = /^[A-Za-z0-9._:-]{1,128}$/
const HEX_KEY_RE = /^[0-9a-f]{64}$/i
const SECURITY_TIMEOUT_MS = 15_000
// `/usr/bin/security find-generic-password` exits with 44 (`errSecItemNotFound`) when absent.
const ERR_SEC_ITEM_NOT_FOUND = 44

export type KeychainReadResult =
  { kind: 'found'; secret: string } | { kind: 'missing' } | { kind: 'refused'; reason: string }

export interface KeychainBackend {
  read(service: string, account: string): Promise<KeychainReadResult>
  write(service: string, account: string, secret: string, update?: boolean): Promise<boolean>
}

export class KeychainUnavailableError extends Error {
  constructor(message = 'macOS Keychain is locked or unavailable') {
    super(message)
    this.name = 'KeychainUnavailableError'
  }
}

export interface KeychainCipherOptions {
  env?: NodeJS.ProcessEnv
  platform?: NodeJS.Platform
  backend?: KeychainBackend
  log?: Logger
}

/**
 * macOS `/usr/bin/security` backend. `keychainPath` may name a specific `.keychain-db` file
 * (used by tests to stay isolated from the user's login keychain); omitted uses the default.
 */
export function macKeychainBackend(keychainPath?: string): KeychainBackend {
  const targetArgs = keychainPath ? [keychainPath] : []

  const read = (service: string, account: string): Promise<KeychainReadResult> => {
    if (!SAFE_IDENT.test(service) || !SAFE_IDENT.test(account)) {
      return Promise.resolve({ kind: 'refused', reason: 'invalid keychain identifier' })
    }
    return new Promise((resolve) => {
      execFile(
        '/usr/bin/security',
        ['find-generic-password', '-s', service, '-a', account, '-w', ...targetArgs],
        { timeout: SECURITY_TIMEOUT_MS, maxBuffer: 64 * 1024 },
        (error, stdout, stderr) => {
          if (!error) {
            const secret = stdout.trim()
            resolve(secret ? { kind: 'found', secret } : { kind: 'missing' })
            return
          }
          const code = (error as { code?: unknown }).code
          if (code === ERR_SEC_ITEM_NOT_FOUND) {
            resolve({ kind: 'missing' })
            return
          }
          const msg = stderr?.trim() || error.message || `exit ${String(code)}`
          resolve({ kind: 'refused', reason: msg })
        },
      )
    })
  }

  const write = (
    service: string,
    account: string,
    secret: string,
    update = true,
  ): Promise<boolean> => {
    if (!SAFE_IDENT.test(service) || !SAFE_IDENT.test(account) || !HEX_KEY_RE.test(secret)) {
      return Promise.resolve(false)
    }
    return new Promise((resolve) => {
      const child = spawn('/usr/bin/security', ['-i'], {
        stdio: ['pipe', 'pipe', 'pipe'],
      })
      child.stdout.resume()
      let stderr = ''
      let settled = false
      const done = (ok: boolean): void => {
        if (settled) return
        settled = true
        clearTimeout(timer)
        resolve(ok)
      }
      const timer = setTimeout(() => {
        child.kill('SIGKILL')
        done(false)
      }, SECURITY_TIMEOUT_MS)
      timer.unref?.()

      child.stderr.on('data', (chunk: Buffer) => {
        stderr += chunk.toString('utf8')
      })
      child.on('error', () => done(false))
      child.on('close', (code) => {
        // `security -i` may exit 0 even when a command fails, reporting the error on stderr; ignore
        // harmless warnings because the caller immediately verifies via `read()`.
        done(code === 0 && !/\b(?:error|failed|denied|SecKeychain)\b/i.test(stderr))
      })

      const quotedPath = keychainPath
        ? ` "${keychainPath.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`
        : ''
      const updateFlag = update ? '-U ' : ''
      // Secrets go over stdin only, never in argv.
      const command = `add-generic-password ${updateFlag}-s "${service}" -a "${account}" -w "${secret}"${quotedPath}\n`
      child.stdin.on('error', () => done(false))
      child.stdin.end(command, 'utf8')
    })
  }

  return { read, write }
}

/** Derives a stable, data-folder-scoped Keychain account label so dev/test folders never collide. */
export async function keychainAccountFor(dataPath: string): Promise<string> {
  const resolved = await realpath(dataPath).catch(() => path.resolve(dataPath))
  const digest = createHash('sha256').update(resolved, 'utf8').digest('hex').slice(0, 16)
  return `local-cipher:${digest}`
}

function sealWithKey(key: Buffer, plainText: string): Buffer {
  const iv = randomBytes(IV_BYTES)
  const cipher = createCipheriv('aes-256-gcm', key, iv)
  cipher.setAAD(AAD)
  const encrypted = Buffer.concat([cipher.update(plainText, 'utf8'), cipher.final()])
  const tag = cipher.getAuthTag()
  return Buffer.concat([MAGIC, iv, encrypted, tag])
}

function openWithKey(key: Buffer, sealed: Buffer): string {
  const minBytes = MAGIC.length + IV_BYTES + TAG_BYTES
  if (sealed.length < minBytes || !sealed.subarray(0, MAGIC.length).equals(MAGIC)) {
    throw new Error('Malformed keychain-encrypted payload')
  }
  const ivStart = MAGIC.length
  const ivEnd = ivStart + IV_BYTES
  const tagStart = sealed.length - TAG_BYTES
  const iv = sealed.subarray(ivStart, ivEnd)
  const ciphertext = sealed.subarray(ivEnd, tagStart)
  const tag = sealed.subarray(tagStart)
  const decipher = createDecipheriv('aes-256-gcm', key, iv)
  decipher.setAAD(AAD)
  decipher.setAuthTag(tag)
  const plain = Buffer.concat([decipher.update(ciphertext), decipher.final()])
  return plain.toString('utf8')
}

/**
 * Loads (or creates once) the data folder's 32-byte wrapping key in the macOS Keychain and
 * returns an `IdentityCipher` backed by it. Falls back to `NO_SYSTEM_ENCRYPTION` when the
 * platform has no macOS Keychain, when `SARTO_NO_KEYCHAIN=1` is set, or when the Keychain refuses.
 */
export async function createKeychainCipher(
  dataPath: string,
  options: KeychainCipherOptions = {},
): Promise<IdentityCipher> {
  const env = options.env ?? process.env
  const platform = options.platform ?? process.platform
  if (
    env.SARTO_NO_KEYCHAIN === '1' ||
    (!options.backend && (env.VITEST || process.env.VITEST || platform !== 'darwin'))
  ) {
    return NO_SYSTEM_ENCRYPTION
  }

  const backend = options.backend ?? macKeychainBackend()
  const account = await keychainAccountFor(dataPath)
  let cachedKey: Buffer | null = null
  let loading: Promise<Buffer | null> | null = null
  let permanentFallback = false

  const loadOrInitKey = async (logUnavailable: boolean): Promise<Buffer | null> => {
    if (cachedKey) return cachedKey
    if (permanentFallback) return null
    const first = await backend.read(SERVICE_NAME, account)
    if (first.kind === 'found') {
      if (HEX_KEY_RE.test(first.secret)) {
        cachedKey = Buffer.from(first.secret, 'hex')
        return cachedKey
      }
      options.log?.warn('Keychain wrapping key had an unexpected format; falling back to file mode')
      permanentFallback = true
      return null
    }
    if (first.kind === 'missing') {
      const generated = randomBytes(KEY_BYTES)
      const hex = generated.toString('hex')
      // Omit `-U` on initial insert so concurrent CLI + daemon startups never overwrite each other.
      await backend.write(SERVICE_NAME, account, hex, false)
      const verified = await backend.read(SERVICE_NAME, account)
      if (verified.kind === 'found' && HEX_KEY_RE.test(verified.secret)) {
        cachedKey = Buffer.from(verified.secret, 'hex')
        return cachedKey
      }
      if (logUnavailable) {
        options.log?.warn(
          'macOS Keychain refused storing the daemon key; falling back to 0600 files until available',
        )
      }
      return null
    }
    if (logUnavailable) {
      options.log?.warn(`macOS Keychain unavailable (${first.reason}); will re-probe when unlocked`)
    }
    return null
  }

  const ensureKey = (logUnavailable = false): Promise<Buffer | null> => {
    if (cachedKey) return Promise.resolve(cachedKey)
    if (permanentFallback) return Promise.resolve(null)
    loading ??= loadOrInitKey(logUnavailable).finally(() => {
      loading = null
    })
    return loading
  }

  await ensureKey(true)
  if (permanentFallback) return NO_SYSTEM_ENCRYPTION

  return {
    available: async () => (await ensureKey()) !== null,
    encrypt: async (plainText: string) => {
      const wrappingKey = await ensureKey()
      if (!wrappingKey) throw new KeychainUnavailableError()
      return sealWithKey(wrappingKey, plainText)
    },
    decrypt: async (encrypted: Buffer) => {
      const wrappingKey = await ensureKey()
      if (!wrappingKey) throw new KeychainUnavailableError()
      return {
        result: openWithKey(wrappingKey, encrypted),
        shouldReEncrypt: false,
      }
    },
    plainText: () => cachedKey === null,
  }
}
