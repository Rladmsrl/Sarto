// macOS Keychain IdentityCipher tests: verifies wrapping/unwrapping, tampered-ciphertext rejection,
// locked-keychain fallback (`plainText: true`), and real `/usr/bin/security` round-trips against
// an isolated temporary `.keychain-db` file (never touching the user's login keychain).

import { execFile } from 'node:child_process'
import { mkdtemp, rm } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { promisify } from 'node:util'
import { afterEach, describe, expect, it } from 'vitest'
import { createKeychainCipher, macKeychainBackend, type KeychainBackend } from './keychain'

const execFileAsync = promisify(execFile)

function memoryBackend(): KeychainBackend & { map: Map<string, string>; locked: boolean } {
  const map = new Map<string, string>()
  const backend = {
    map,
    locked: false,
    async read(service: string, account: string) {
      if (backend.locked) return { kind: 'refused' as const, reason: 'keychain locked' }
      const val = map.get(`${service}\0${account}`)
      return val ? { kind: 'found' as const, secret: val } : { kind: 'missing' as const }
    },
    async write(service: string, account: string, secret: string) {
      if (backend.locked) return false
      map.set(`${service}\0${account}`, secret)
      return true
    },
  }
  return backend
}

describe('daemon Keychain IdentityCipher', () => {
  const dirs: string[] = []
  afterEach(async () => {
    for (const dir of dirs.splice(0)) await rm(dir, { recursive: true, force: true })
  })

  it('creates one wrapping key per data folder, seals secrets, and rejects tampered ciphertext', async () => {
    const dir = await mkdtemp(path.join(os.tmpdir(), 'sarto-kc-'))
    dirs.push(dir)
    const backend = memoryBackend()

    const cipher = await createKeychainCipher(dir, {
      platform: 'darwin',
      env: {},
      backend,
    })
    expect(await cipher.available()).toBe(true)
    expect(cipher.plainText()).toBe(false)
    expect(backend.map.size).toBe(1)

    const sealed = await cipher.encrypt('srt_super_secret_refresh_token')
    expect(sealed.toString('utf8')).not.toContain('srt_super_secret_refresh_token')

    // A second daemon start on the same data folder reuses the same Keychain key.
    const cipher2 = await createKeychainCipher(dir, {
      platform: 'darwin',
      env: {},
      backend,
    })
    expect(backend.map.size).toBe(1)
    expect((await cipher2.decrypt(sealed)).result).toBe('srt_super_secret_refresh_token')

    // Flipping a byte in ciphertext fails GCM authentication.
    const tampered = Buffer.from(sealed)
    tampered[tampered.length - 1] = tampered[tampered.length - 1]! ^ 0xff
    await expect(cipher2.decrypt(tampered)).rejects.toThrow()
  })

  it('falls back to plainText while locked and recovers live once Keychain unlocks', async () => {
    const dir = await mkdtemp(path.join(os.tmpdir(), 'sarto-kc-locked-'))
    dirs.push(dir)
    const backend = memoryBackend()
    backend.locked = true

    const cipher = await createKeychainCipher(dir, {
      platform: 'darwin',
      env: {},
      backend,
    })
    expect(await cipher.available()).toBe(false)
    expect(cipher.plainText()).toBe(true)

    // Unlocking the Keychain later in the same daemon process upgrades live without restart!
    backend.locked = false
    expect(await cipher.available()).toBe(true)
    expect(cipher.plainText()).toBe(false)
    const sealed = await cipher.encrypt('recovered_secret_after_unlock')
    expect((await cipher.decrypt(sealed)).result).toBe('recovered_secret_after_unlock')
  })

  it.runIf(process.platform === 'darwin')(
    'round-trips via real /usr/bin/security against an isolated temporary keychain',
    async () => {
      const dir = await mkdtemp(path.join(os.tmpdir(), 'sarto-kc-real-'))
      dirs.push(dir)
      const kcPath = path.join(dir, 'isolated.keychain-db')
      await execFileAsync('/usr/bin/security', ['create-keychain', '-p', 'ephemeral-pass', kcPath])
      try {
        await execFileAsync('/usr/bin/security', [
          'unlock-keychain',
          '-p',
          'ephemeral-pass',
          kcPath,
        ])
        const backend = macKeychainBackend(kcPath)

        const c1 = await createKeychainCipher(dir, { platform: 'darwin', env: {}, backend })
        expect(await c1.available()).toBe(true)
        expect(c1.plainText()).toBe(false)

        const sealed = await c1.encrypt('smk_32_byte_secret_value')
        const c2 = await createKeychainCipher(dir, { platform: 'darwin', env: {}, backend })
        expect(await c2.available()).toBe(true)
        expect(c2.plainText()).toBe(false)
        expect((await c2.decrypt(sealed)).result).toBe('smk_32_byte_secret_value')
      } finally {
        await execFileAsync('/usr/bin/security', ['delete-keychain', kcPath]).catch(() => {})
      }
    },
  )

  it('falls back to plainText when SARTO_NO_KEYCHAIN=1 or on non-macOS platforms', async () => {
    const dir = await mkdtemp(path.join(os.tmpdir(), 'sarto-kc-env-'))
    dirs.push(dir)
    const backend = memoryBackend()

    const disabled = await createKeychainCipher(dir, {
      platform: 'darwin',
      env: { SARTO_NO_KEYCHAIN: '1' },
      backend,
    })
    expect(await disabled.available()).toBe(false)
    expect(disabled.plainText()).toBe(true)

    const linux = await createKeychainCipher(dir, {
      platform: 'linux',
      env: {},
    })
    expect(await linux.available()).toBe(false)
    expect(linux.plainText()).toBe(true)
  })
})
