import { createHash, generateKeyPairSync, sign } from 'node:crypto'
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { describe, expect, it, vi } from 'vitest'
import { assembleDaemonRelease } from '../../tools/sarto/assemble-daemon-release.mjs'
import {
  hasPrivateGlibcSymbols,
  parseMaxCxxabiVersion,
  parseMaxGccVersion,
  parseMaxGlibcxxVersion,
  parseMaxGlibcVersion,
} from '../../tools/sarto/build-daemon-package.mjs'
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

/** Writes a daemon archive and the meta file build-daemon-package.mjs writes beside it. */
async function writeDaemonArchive(
  folder: string,
  platform: string,
  arch: string,
  body: string,
  meta: Record<string, unknown> = {},
): Promise<void> {
  const name = `sarto-daemon-${platform}-${arch}`
  await mkdir(folder, { recursive: true })
  await writeFile(path.join(folder, `${name}.tar.gz`), body)
  const described = {
    platform,
    arch,
    name: `${name}.tar.gz`,
    size: Buffer.byteLength(body),
    sha256: createHash('sha256').update(body).digest('hex'),
    version: '1.3.0',
    build: '261127153000',
    channel: 'stable',
    ...meta,
  }
  await writeFile(path.join(folder, `${name}.meta.json`), `${JSON.stringify(described)}\n`)
}

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

  it('pins only the matching platform package checksum when platform and arch are provided', async () => {
    const signer = keyPair()
    const darwin = 'a'.repeat(64)
    const linuxX64 = 'b'.repeat(64)
    const linuxArm64 = 'c'.repeat(64)
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
        {
          platform: 'linux',
          arch: 'arm64',
          name: 'sarto-daemon-linux-arm64.tar.gz',
          sha256: linuxArm64,
        },
        { platform: 'linux', arch: 'x64', name: 'sarto-daemon-linux-x64.tar.gz', sha256: linuxX64 },
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

    const code = await update(
      makeDeps(fetchImpl, install, { platform: 'linux', arch: 'x64', service: false }),
      [signer.raw],
    )
    expect(code).toBe(0)
    expect(install).toHaveBeenCalledWith(SCRIPT, [
      '--version',
      '1.2.0',
      '--tag',
      'daemon-v1.2.0',
      '--sha256',
      linuxX64,
      '--no-service',
    ])
  })

  it('verifies a multi-platform daemon release assembled by assemble-daemon-release.mjs', async () => {
    const { privateKey, publicKey } = generateKeyPairSync('ed25519')
    const rawPub = Buffer.from(publicKey.export({ format: 'jwk' }).x!, 'base64url').toString(
      'base64',
    )
    const dir = await mkdtemp(path.join(os.tmpdir(), 'sarto-assemble-test-'))
    try {
      const inMac = path.join(dir, 'in-mac')
      const inLinux = path.join(dir, 'in-linux')
      const outDir = path.join(dir, 'out')
      await writeFile(path.join(dir, 'install.sh'), SCRIPT)
      await writeDaemonArchive(inMac, 'darwin', 'arm64', 'mac-tar')
      await writeDaemonArchive(inLinux, 'linux', 'x64', 'linux-x64-tar')
      await writeDaemonArchive(inLinux, 'linux', 'arm64', 'linux-arm64-tar')

      await expect(
        assembleDaemonRelease({
          inputDirs: [inMac],
          outDir,
          daemonVersion: '1.3.0',
          daemonTag: 'daemon-v1.3.0',
          channel: 'stable',
          build: '261127153000',
          requirePlatforms: ['darwin-arm64', 'linux-x64', 'linux-arm64'],
          signUpdateFile: (msg) => sign(null, msg, privateKey),
          installScriptPath: path.join(dir, 'install.sh'),
        }),
      ).rejects.toThrow('Missing required daemon platform archives: linux-x64, linux-arm64')

      const assembled = await assembleDaemonRelease({
        inputDirs: [inMac, inLinux],
        outDir,
        daemonVersion: '1.3.0',
        daemonTag: 'daemon-v1.3.0',
        channel: 'stable',
        build: '261127153000',
        requirePlatforms: ['darwin-arm64', 'linux-x64', 'linux-arm64'],
        signUpdateFile: (msg) => sign(null, msg, privateKey),
        installScriptPath: path.join(dir, 'install.sh'),
      })

      expect(assembled.files.map((f) => f.name)).toEqual([
        'sarto-daemon-darwin-arm64.tar.gz',
        'sarto-daemon-linux-arm64.tar.gz',
        'sarto-daemon-linux-x64.tar.gz',
      ])
      const sums = await readFile(path.join(outDir, 'sarto-daemon-sha256sums.txt'), 'utf8')
      expect(sums.trim().split('\n')).toHaveLength(3)

      const manifestBody = await readFile(path.join(outDir, 'latest-daemon.json'), 'utf8')
      const manifestSig = await readFile(path.join(outDir, 'latest-daemon.json.sig'), 'utf8')
      const scriptBody = await readFile(path.join(outDir, 'install.sh'), 'utf8')
      const scriptSig = await readFile(path.join(outDir, 'install.sh.sig'), 'utf8')
      const install = vi.fn(async () => 0)
      const fetchImpl: typeof fetch = async (input) => {
        const url = String(input)
        if (url === `${ORIGIN}/latest/download/latest-daemon.json`)
          return new Response(manifestBody)
        if (url === `${ORIGIN}/latest/download/latest-daemon.json.sig`)
          return new Response(manifestSig)
        if (url === `${ORIGIN}/download/daemon-v1.3.0/install.sh`) return new Response(scriptBody)
        if (url === `${ORIGIN}/download/daemon-v1.3.0/install.sh.sig`)
          return new Response(scriptSig)
        return new Response('not found', { status: 404 })
      }

      const linuxArmHash = assembled.files.find(
        (f) => f.name === 'sarto-daemon-linux-arm64.tar.gz',
      )!.sha256
      const code = await update(
        makeDeps(fetchImpl, install, { platform: 'linux', arch: 'arm64', service: false }),
        [rawPub],
      )
      expect(code).toBe(0)
      expect(install).toHaveBeenCalledWith(scriptBody, [
        '--version',
        '1.3.0',
        '--tag',
        'daemon-v1.3.0',
        '--sha256',
        linuxArmHash,
        '--no-service',
      ])
    } finally {
      await rm(dir, { recursive: true, force: true })
    }
  })

  it('refuses to sign a daemon release around an archive of another build', async () => {
    const dir = await mkdtemp(path.join(os.tmpdir(), 'sarto-assemble-test-'))
    try {
      await writeFile(path.join(dir, 'install.sh'), SCRIPT)
      const assemble = (input: string) =>
        assembleDaemonRelease({
          inputDirs: [input],
          outDir: path.join(dir, 'out'),
          daemonVersion: '1.3.0',
          daemonTag: 'daemon-v1.3.0',
          channel: 'stable',
          build: '261127153000',
          signUpdateFile: () => Buffer.from('sig'),
          installScriptPath: path.join(dir, 'install.sh'),
        })

      const stale = path.join(dir, 'stale')
      await writeDaemonArchive(stale, 'linux', 'x64', 'old-tar', { version: '1.2.0' })
      await expect(assemble(stale)).rejects.toThrow(
        'sarto-daemon-linux-x64.tar.gz is daemon 1.2.0, not 1.3.0',
      )

      const otherBuild = path.join(dir, 'other-build')
      await writeDaemonArchive(otherBuild, 'linux', 'x64', 'tar', { build: '261126000000' })
      await expect(assemble(otherBuild)).rejects.toThrow('build 261126000000, not 261127153000')

      const otherChannel = path.join(dir, 'other-channel')
      await writeDaemonArchive(otherChannel, 'linux', 'x64', 'tar', { channel: 'beta' })
      await expect(assemble(otherChannel)).rejects.toThrow('channel beta, not stable')

      const replaced = path.join(dir, 'replaced')
      await writeDaemonArchive(replaced, 'linux', 'x64', 'tar', { sha256: 'f'.repeat(64) })
      await expect(assemble(replaced)).rejects.toThrow('does not match its meta file')

      const bare = path.join(dir, 'bare')
      await mkdir(bare, { recursive: true })
      await writeFile(path.join(bare, 'sarto-daemon-linux-x64.tar.gz'), 'tar')
      await expect(assemble(bare)).rejects.toThrow('has no sarto-daemon-linux-x64.meta.json')
    } finally {
      await rm(dir, { recursive: true, force: true })
    }
  })

  it('rejects a signed manifest whose files list omits the current platform and arch', async () => {
    const signer = keyPair()
    const manifestBody = JSON.stringify({
      version: '1.2.0',
      channel: 'stable',
      tag: 'daemon-v1.2.0',
      files: [
        {
          platform: 'darwin',
          arch: 'arm64',
          name: 'sarto-daemon-darwin-arm64.tar.gz',
          sha256: 'a'.repeat(64),
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

    await expect(
      update(makeDeps(fetchImpl, install, { platform: 'linux', arch: 'x64', service: false }), [
        signer.raw,
      ]),
    ).rejects.toThrow('Release 1.2.0 includes no daemon package for linux-x64')
    expect(install).not.toHaveBeenCalled()
  })

  it('extracts maximum GLIBC/GLIBCXX/CXXABI/GCC versions and detects GLIBC_PRIVATE from objdump output', () => {
    const sample = [
      '0000000000000000      DF *UND* 0000000000000000  GLIBC_2.2.5 openpty',
      '0000000000000000      DF *UND* 0000000000000000  GLIBC_2.28  fcntl64',
      '0000000000000000      DF *UND* 0000000000000000  GLIBC_2.17  clock_gettime',
      '0000000000000000      DF *UND* 0000000000000000  GLIBCXX_3.4.25 std::__throw_out_of_range',
      '0000000000000000      DF *UND* 0000000000000000  GLIBCXX_3.4.21 std::__cxx11::basic_string',
      '0000000000000000      DF *UND* 0000000000000000  CXXABI_1.3.11 __cxa_init_primary_exception',
      '0000000000000000      DF *UND* 0000000000000000  GCC_7.0.0 __divti3',
    ].join('\n')
    expect(parseMaxGlibcVersion(sample)).toBe('2.28')
    expect(parseMaxGlibcxxVersion(sample)).toBe('3.4.25')
    expect(parseMaxCxxabiVersion(sample)).toBe('1.3.11')
    expect(parseMaxGccVersion(sample)).toBe('7.0.0')
    expect(hasPrivateGlibcSymbols(sample)).toBe(false)
    expect(parseMaxGlibcVersion('00000000 DF *UND* GLIBC_2.34 pthread_create')).toBe('2.34')
    expect(parseMaxGlibcxxVersion('00000000 DF *UND* GLIBCXX_3.4.30 std::string')).toBe('3.4.30')
    expect(parseMaxCxxabiVersion('00000000 DF *UND* CXXABI_1.3.13 __cxa_call_terminate')).toBe(
      '1.3.13',
    )
    expect(parseMaxGccVersion('00000000 DF *UND* GCC_12.0.0 __unordtf2')).toBe('12.0.0')
    expect(hasPrivateGlibcSymbols('00000000 DF *UND* GLIBC_PRIVATE __libc_start')).toBe(true)
    expect(parseMaxGlibcVersion('no glibc symbols here')).toBeNull()
    expect(parseMaxGlibcxxVersion('no glibc symbols here')).toBeNull()
    expect(parseMaxCxxabiVersion('no glibc symbols here')).toBeNull()
    expect(parseMaxGccVersion('no glibc symbols here')).toBeNull()
  })
})
