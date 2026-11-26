import { generateKeyPairSync, sign } from 'node:crypto'
import { describe, expect, it, vi } from 'vitest'
import KEYS from '../../tools/sarto/update-keys.json'
import {
  DAEMON_MANIFEST_NAME,
  RELEASE_KEYS,
  update,
  UpdateError,
  updateFileMessage,
  type UpdateDeps,
} from './update'

function keyPair(): { raw: string; sign(message: Uint8Array): string } {
  const { privateKey, publicKey } = generateKeyPairSync('ed25519')
  const x = publicKey.export({ format: 'jwk' }).x!
  return {
    raw: Buffer.from(x, 'base64url').toString('base64'),
    sign: (message) => sign(null, message, privateKey).toString('base64'),
  }
}

const ORIGIN = 'https://sarto.example/releases'
const SCRIPT = '#!/bin/sh\necho ok\n'
const SCRIPT_BYTES = Buffer.from(SCRIPT, 'utf8')

function makeDeps(
  fetchImpl: typeof fetch,
  install = vi.fn(async () => 0),
  overrides: Partial<UpdateDeps> = {},
): UpdateDeps {
  return {
    version: '1.0.0',
    bundleDir: '/home/user/.local/share/sarto/versions/1.0.0/daemon',
    releases: [ORIGIN],
    userAgent: 'Sarto-daemon/1.0.0 (darwin; arm64)',
    fetch: fetchImpl,
    service: true,
    foreground: false,
    install,
    write: () => {},
    ...overrides,
  }
}

describe('sarto update signature verification', () => {
  it('uses Sarto release keys and matches tools/sarto/signing.mjs message framing', () => {
    expect(RELEASE_KEYS).toEqual([KEYS.release.current, KEYS.release.next])
    expect(updateFileMessage('install.sh', SCRIPT_BYTES)).toEqual(
      Buffer.concat([Buffer.from('install.sh\n', 'utf8'), SCRIPT_BYTES]),
    )
  })

  it('verifies a valid Ed25519 signature via legacy /latest fallback', async () => {
    const signer = keyPair()
    const signature = `${signer.sign(updateFileMessage('install.sh', SCRIPT_BYTES))}\n`
    const calls: Array<{ url: string; redirect?: RequestInit['redirect'] }> = []
    const install = vi.fn(async () => 0)

    const fetchImpl: typeof fetch = async (input, init) => {
      const url = String(input)
      calls.push({ url, redirect: init?.redirect })
      if (url === `${ORIGIN}/latest`) {
        return new Response(null, {
          status: 302,
          headers: { location: `${ORIGIN}/tag/v1.1.0` },
        })
      }
      if (url === `${ORIGIN}/download/v1.1.0/install.sh`) {
        return new Response(SCRIPT, { status: 200 })
      }
      if (url === `${ORIGIN}/download/v1.1.0/install.sh.sig`) {
        return new Response(signature, { status: 200 })
      }
      return new Response('not found', { status: 404 })
    }

    const code = await update(makeDeps(fetchImpl, install), [signer.raw])
    expect(code).toBe(0)
    expect(install).toHaveBeenCalledWith(SCRIPT, ['--version', '1.1.0'])
    expect(calls).toEqual([
      { url: `${ORIGIN}/latest/download/${DAEMON_MANIFEST_NAME.stable}`, redirect: 'follow' },
      { url: `${ORIGIN}/latest`, redirect: 'manual' },
      { url: `${ORIGIN}/download/v1.1.0/install.sh`, redirect: 'follow' },
      { url: `${ORIGIN}/download/v1.1.0/install.sh.sig`, redirect: 'follow' },
    ])
  })

  it('verifies signed latest-daemon.json and passes --tag for decoupled daemon releases', async () => {
    const signer = keyPair()
    const manifestBody = JSON.stringify({
      version: '1.2.0',
      channel: 'stable',
      build: '261125143512',
      tag: 'daemon-v1.2.0',
    })
    const manifestSig = `${signer.sign(updateFileMessage('latest-daemon.json', Buffer.from(manifestBody)))}\n`
    const scriptSig = `${signer.sign(updateFileMessage('install.sh', SCRIPT_BYTES))}\n`
    const install = vi.fn(async () => 0)

    const fetchImpl: typeof fetch = async (input) => {
      const url = String(input)
      if (url === `${ORIGIN}/latest/download/latest-daemon.json`) {
        return new Response(manifestBody, { status: 200 })
      }
      if (url === `${ORIGIN}/latest/download/latest-daemon.json.sig`) {
        return new Response(manifestSig, { status: 200 })
      }
      if (url === `${ORIGIN}/download/daemon-v1.2.0/install.sh`) {
        return new Response(SCRIPT, { status: 200 })
      }
      if (url === `${ORIGIN}/download/daemon-v1.2.0/install.sh.sig`) {
        return new Response(scriptSig, { status: 200 })
      }
      return new Response('not found', { status: 404 })
    }

    const code = await update(makeDeps(fetchImpl, install), [signer.raw])
    expect(code).toBe(0)
    expect(install).toHaveBeenCalledWith(SCRIPT, ['--version', '1.2.0', '--tag', 'daemon-v1.2.0'])
  })

  it('hands the install script the package checksums of the signed manifest', async () => {
    const signer = keyPair()
    const darwin = 'a'.repeat(64)
    const linux = 'b'.repeat(64)
    const manifestBody = JSON.stringify({
      version: '1.2.0',
      channel: 'stable',
      tag: 'daemon-v1.2.0',
      files: [
        {
          platform: 'darwin',
          arch: 'arm64',
          name: 'sarto-daemon-darwin-arm64.tar.gz',
          sha256: darwin,
        },
        { platform: 'linux', arch: 'x64', name: 'sarto-daemon-linux-x64.tar.gz', sha256: linux },
        {
          platform: 'linux',
          arch: 'x64',
          name: 'sarto-daemon-linux-x64-copy.tar.gz',
          sha256: linux,
        },
      ],
    })
    const manifestSig = `${signer.sign(updateFileMessage('latest-daemon.json', Buffer.from(manifestBody)))}\n`
    const scriptSig = `${signer.sign(updateFileMessage('install.sh', SCRIPT_BYTES))}\n`
    const install = vi.fn(async () => 0)
    const fetchImpl: typeof fetch = async (input) => {
      const url = String(input)
      if (url === `${ORIGIN}/latest/download/latest-daemon.json`) return new Response(manifestBody)
      if (url === `${ORIGIN}/latest/download/latest-daemon.json.sig`)
        return new Response(manifestSig)
      if (url === `${ORIGIN}/download/daemon-v1.2.0/install.sh`) return new Response(SCRIPT)
      if (url === `${ORIGIN}/download/daemon-v1.2.0/install.sh.sig`) return new Response(scriptSig)
      return new Response('not found', { status: 404 })
    }

    const code = await update(makeDeps(fetchImpl, install, { service: false }), [signer.raw])
    expect(code).toBe(0)
    // The unsigned checksums beside the package no longer decide what is installed.
    expect(install).toHaveBeenCalledWith(SCRIPT, [
      '--version',
      '1.2.0',
      '--tag',
      'daemon-v1.2.0',
      '--sha256',
      darwin,
      '--sha256',
      linux,
      '--no-service',
    ])
  })

  it('rejects a signed manifest whose package checksums are not checksums', async () => {
    const signer = keyPair()
    const scriptSig = `${signer.sign(updateFileMessage('install.sh', SCRIPT_BYTES))}\n`
    for (const files of [
      [{ name: 'sarto-daemon-darwin-arm64.tar.gz', sha256: 'A'.repeat(64) }],
      [{ name: 'sarto-daemon-darwin-arm64.tar.gz', sha256: 'abc --no-service' }],
      [{ name: '../install.sh', sha256: 'a'.repeat(64) }],
      [{ name: 'sarto-daemon-darwin-arm64.tar.gz' }],
      'a'.repeat(64),
    ]) {
      const manifestBody = JSON.stringify({ version: '1.2.0', channel: 'stable', files })
      const manifestSig = `${signer.sign(updateFileMessage('latest-daemon.json', Buffer.from(manifestBody)))}\n`
      const install = vi.fn(async () => 0)
      const fetchImpl: typeof fetch = async (input) => {
        const url = String(input)
        if (url === `${ORIGIN}/latest/download/latest-daemon.json`)
          return new Response(manifestBody)
        if (url === `${ORIGIN}/latest/download/latest-daemon.json.sig`) {
          return new Response(manifestSig)
        }
        if (url === `${ORIGIN}/download/v1.2.0/install.sh`) return new Response(SCRIPT)
        if (url === `${ORIGIN}/download/v1.2.0/install.sh.sig`) return new Response(scriptSig)
        return new Response('not found', { status: 404 })
      }
      await expect(update(makeDeps(fetchImpl, install), [signer.raw])).rejects.toThrow(
        'Daemon manifest files are not valid',
      )
      expect(install).not.toHaveBeenCalled()
    }
  })

  it('follows redirects of a source laid out as GitHub to its signed daemon manifest and install script', async () => {
    const signer = keyPair()
    const manifestBody = JSON.stringify({
      version: '1.2.0',
      channel: 'stable',
      tag: 'daemon-v1.2.0',
    })
    const manifestSig = `${signer.sign(updateFileMessage('latest-daemon.json', Buffer.from(manifestBody)))}\n`
    const scriptSig = `${signer.sign(updateFileMessage('install.sh', SCRIPT_BYTES))}\n`
    const install = vi.fn(async () => 0)
    const redirected: Record<string, string> = {
      [`${ORIGIN}/latest/download/latest-daemon.json`]: manifestBody,
      [`${ORIGIN}/latest/download/latest-daemon.json.sig`]: manifestSig,
      [`${ORIGIN}/download/daemon-v1.2.0/install.sh`]: SCRIPT,
      [`${ORIGIN}/download/daemon-v1.2.0/install.sh.sig`]: scriptSig,
    }

    const fetchImpl: typeof fetch = async (input, init) => {
      const url = String(input)
      const body = redirected[url]
      if (body !== undefined) {
        if (init?.redirect === 'error') throw new TypeError('unexpected redirect')
        if (init?.redirect === 'manual') return new Response(null, { status: 302 })
        return new Response(body, { status: 200 })
      }
      return new Response('not found', { status: 404 })
    }

    const code = await update(makeDeps(fetchImpl, install), [signer.raw])
    expect(code).toBe(0)
    expect(install).toHaveBeenCalledWith(SCRIPT, ['--version', '1.2.0', '--tag', 'daemon-v1.2.0'])
  })

  it('rejects a beta-signed daemon manifest replayed on the stable channel', async () => {
    const signer = keyPair()
    const manifestBody = JSON.stringify({
      version: '1.2.0-beta.261125143512',
      channel: 'beta',
      tag: 'daemon-v1.2.0-beta.261125143512',
    })
    const betaSig = `${signer.sign(updateFileMessage('beta-daemon.json', Buffer.from(manifestBody)))}\n`
    const install = vi.fn(async () => 0)

    const fetchImpl: typeof fetch = async (input) => {
      const url = String(input)
      if (url === `${ORIGIN}/latest/download/latest-daemon.json`) {
        return new Response(manifestBody, { status: 200 })
      }
      if (url === `${ORIGIN}/latest/download/latest-daemon.json.sig`) {
        return new Response(betaSig, { status: 200 })
      }
      return new Response('not found', { status: 404 })
    }

    await expect(update(makeDeps(fetchImpl, install), [signer.raw])).rejects.toThrow(UpdateError)
    expect(install).not.toHaveBeenCalled()
  })

  it('graduates a beta daemon to a newer stable release when checking the beta channel', async () => {
    const signer = keyPair()
    const betaManifest = JSON.stringify({
      version: '1.2.0-beta.261125143512',
      channel: 'beta',
      build: '261125143512',
      tag: 'daemon-v1.2.0-beta.261125143512',
    })
    const stableManifest = JSON.stringify({
      version: '1.2.0',
      channel: 'stable',
      build: '261125160000',
      tag: 'daemon-v1.2.0',
    })
    const betaSig = `${signer.sign(updateFileMessage('beta-daemon.json', Buffer.from(betaManifest)))}\n`
    const stableSig = `${signer.sign(updateFileMessage('latest-daemon.json', Buffer.from(stableManifest)))}\n`
    const scriptSig = `${signer.sign(updateFileMessage('install.sh', SCRIPT_BYTES))}\n`
    const install = vi.fn(async () => 0)

    const fetchImpl: typeof fetch = async (input) => {
      const url = String(input)
      if (url === `${ORIGIN}/latest/download/beta-daemon.json`) {
        return new Response(betaManifest, { status: 200 })
      }
      if (url === `${ORIGIN}/latest/download/beta-daemon.json.sig`) {
        return new Response(betaSig, { status: 200 })
      }
      if (url === `${ORIGIN}/latest/download/latest-daemon.json`) {
        return new Response(stableManifest, { status: 200 })
      }
      if (url === `${ORIGIN}/latest/download/latest-daemon.json.sig`) {
        return new Response(stableSig, { status: 200 })
      }
      if (url === `${ORIGIN}/download/daemon-v1.2.0/install.sh`) {
        return new Response(SCRIPT, { status: 200 })
      }
      if (url === `${ORIGIN}/download/daemon-v1.2.0/install.sh.sig`) {
        return new Response(scriptSig, { status: 200 })
      }
      return new Response('not found', { status: 404 })
    }

    const code = await update(
      makeDeps(fetchImpl, install, {
        version: '1.2.0-beta.261125140000',
        channel: 'beta',
      }),
      [signer.raw],
    )
    expect(code).toBe(0)
    expect(install).toHaveBeenCalledWith(SCRIPT, ['--version', '1.2.0', '--tag', 'daemon-v1.2.0'])
  })

  it('rejects a daemon manifest whose tag attempts path traversal', async () => {
    const signer = keyPair()
    const manifestBody = JSON.stringify({
      version: '1.2.0',
      channel: 'stable',
      tag: '../evil',
    })
    const manifestSig = `${signer.sign(updateFileMessage('latest-daemon.json', Buffer.from(manifestBody)))}\n`
    const install = vi.fn(async () => 0)

    const fetchImpl: typeof fetch = async (input) => {
      const url = String(input)
      if (url === `${ORIGIN}/latest/download/latest-daemon.json`) {
        return new Response(manifestBody, { status: 200 })
      }
      if (url === `${ORIGIN}/latest/download/latest-daemon.json.sig`) {
        return new Response(manifestSig, { status: 200 })
      }
      return new Response('not found', { status: 404 })
    }

    await expect(update(makeDeps(fetchImpl, install), [signer.raw])).rejects.toThrow(UpdateError)
    expect(install).not.toHaveBeenCalled()
  })

  it('rejects a tampered install script without executing it', async () => {
    const signer = keyPair()
    const signature = `${signer.sign(updateFileMessage('install.sh', SCRIPT_BYTES))}\n`
    const install = vi.fn(async () => 0)

    const fetchImpl: typeof fetch = async (input) => {
      const url = String(input)
      if (url === `${ORIGIN}/latest`) {
        return new Response(null, { status: 302, headers: { location: `${ORIGIN}/tag/v1.1.0` } })
      }
      if (url === `${ORIGIN}/download/v1.1.0/install.sh`) {
        return new Response(`${SCRIPT}# tampered\n`, { status: 200 })
      }
      if (url === `${ORIGIN}/download/v1.1.0/install.sh.sig`) {
        return new Response(signature, { status: 200 })
      }
      return new Response('not found', { status: 404 })
    }

    await expect(update(makeDeps(fetchImpl, install), [signer.raw])).rejects.toThrow(UpdateError)
    expect(install).not.toHaveBeenCalled()
  })

  it('rejects when install.sh.sig is missing', async () => {
    const signer = keyPair()
    const install = vi.fn(async () => 0)

    const fetchImpl: typeof fetch = async (input) => {
      const url = String(input)
      if (url === `${ORIGIN}/latest`) {
        return new Response(null, { status: 302, headers: { location: `${ORIGIN}/tag/v1.1.0` } })
      }
      if (url === `${ORIGIN}/download/v1.1.0/install.sh`) {
        return new Response(SCRIPT, { status: 200 })
      }
      return new Response('not found', { status: 404 })
    }

    await expect(update(makeDeps(fetchImpl, install), [signer.raw])).rejects.toThrow(UpdateError)
    expect(install).not.toHaveBeenCalled()
  })

  it('refuses redirects when downloading install.sh or install.sh.sig', async () => {
    const signer = keyPair()
    const install = vi.fn(async () => 0)

    const fetchImpl: typeof fetch = async (input, init) => {
      const url = String(input)
      if (url === `${ORIGIN}/latest`) {
        return new Response(null, { status: 302, headers: { location: `${ORIGIN}/tag/v1.1.0` } })
      }
      if (init?.redirect === 'error') {
        throw new TypeError('unexpected redirect')
      }
      return new Response(SCRIPT, { status: 200 })
    }

    await expect(update(makeDeps(fetchImpl, install), [signer.raw])).rejects.toThrow(UpdateError)
    expect(install).not.toHaveBeenCalled()
  })
})
