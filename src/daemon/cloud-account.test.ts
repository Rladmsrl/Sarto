// Upstream's account client against Sarto's server: the daemon signs in through the browser
// with PKCE and its loopback port, reads the account, gets relay tokens, lists and removes its
// devices, and signs out at the server. The browser is played by plain HTTP requests.

import { mkdtemp, rm } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { createLogger } from '../core/log'
import { accountFile, readAccount, writeAccount } from '../core/account/store'
import { CloudAccount } from './cloud-account'
import { CloudThemeSync } from './cloud-theme'
import { NO_SYSTEM_ENCRYPTION } from './key'
import { CLOUD_SOURCE, loadCloud, type AuthService, type PrismRelayServer } from './testing/cloud'

const cloud = await loadCloud()

const EMAIL = 'mac@example.com'
const PASSWORD = 'password-1234'

describe.skipIf(!CLOUD_SOURCE)('CloudAccount against the Sarto server', () => {
  let server: PrismRelayServer
  let origin: string
  let auth: AuthService
  let root: string

  beforeAll(async () => {
    auth = new cloud.AuthService({ secret: 'cloud-account-test-secret-32-bytes!!', dataFile: null })
    await auth.createPasswordAccount(EMAIL, PASSWORD, 'Mac User')
    const probe = new cloud.PrismRelayServer({
      publicOrigin: 'http://127.0.0.1:0',
      regionId: 't',
      auth,
    })
    const bound = await probe.listen(0, '127.0.0.1')
    await probe.close()
    origin = `http://127.0.0.1:${bound.port}`
    const oauth = new cloud.OAuthService({
      auth,
      store: new cloud.OAuthStore(null),
      publicOrigin: origin,
      allowRegistration: false,
    })
    server = new cloud.PrismRelayServer({ publicOrigin: origin, regionId: 't', auth, oauth })
    await server.listen(bound.port, '127.0.0.1')
    root = await mkdtemp(path.join(os.tmpdir(), 'sarto-cloud-account-'))
  })

  afterAll(async () => {
    await server.close()
    await rm(root, { recursive: true, force: true })
  })

  /** Signs in on the page the daemon opened, as a person in the browser would. */
  async function browser(url: string): Promise<void> {
    const page = await fetch(url)
    const html = await page.text()
    const req = /name="req" value="([^"]+)"/.exec(html)?.[1]
    if (!req) throw new Error(`no sign-in form at ${url}`)
    const signed = await fetch(`${origin}/signin/app/`, {
      method: 'POST',
      redirect: 'manual',
      headers: { 'content-type': 'application/x-www-form-urlencoded', origin },
      body: new URLSearchParams({ req, action: 'signin', email: EMAIL, password: PASSWORD }),
    })
    const back = signed.headers.get('location')
    if (signed.status !== 303 || !back) throw new Error(`sign-in answered ${signed.status}`)
    // The loopback port the daemon listens on.
    await fetch(back, { redirect: 'manual' })
  }

  it('signs in, gets tokens and devices, and signs out at the server', async () => {
    let now = Date.now()
    let appVersion = '0.2.4'
    const opened: string[] = []
    const cloud = await CloudAccount.load({
      dataPath: root,
      env: { SARTO_CLOUD_URL: origin },
      fetch: (url, init) => fetch(url, init),
      cipher: NO_SYSTEM_ENCRYPTION,
      clientInfo: async () => ({
        kind: 'daemon',
        name: 'Mac A',
        os: 'macOS',
        arch: 'arm64',
        version: appVersion,
      }),
      locale: () => 'en',
      log: createLogger('test-account'),
      now: () => now,
      openBrowser: async (url) => {
        opened.push(url)
        void browser(url)
      },
    })
    expect(cloud.status()).toMatchObject({
      origin,
      fixedOrigin: true,
      account: { state: 'signed-out' },
    })

    const signedIn = new Promise<void>((resolve) => {
      const stop = cloud.onChange((status) => {
        if (status.account.state === 'signed-in') {
          stop()
          resolve()
        }
      })
    })
    await cloud.signIn()
    expect(new URL(opened[0]!).pathname).toBe('/signin/app/')
    await signedIn

    const status = cloud.status().account
    expect(status.state).toBe('signed-in')
    if (status.state !== 'signed-in') return
    expect(status.account.email).toBe(EMAIL)
    // Sarto has no plans, usage meters or points.
    expect(status).not.toHaveProperty('plan')
    expect(status).not.toHaveProperty('points')

    const access = await cloud.account().currentToken()
    expect(access).not.toBeNull()
    const relay = await cloud.relayToken()
    expect(auth.verifyToken(relay.token)?.scope).toBe('relay')

    expect((await cloud.devices())[0]).toMatchObject({ name: 'Mac A', version: '0.2.4' })

    // Past the access token's 15 minutes the client refreshes and updates its reported version.
    appVersion = '0.3.0'
    now += 20 * 60_000
    const refreshed = await cloud.account().currentToken()
    expect(refreshed?.token).toBeTruthy()
    expect(refreshed?.token).not.toBe(access?.token)
    expect(cloud.status().account.state).toBe('signed-in')

    const devices = await cloud.devices()
    expect(devices).toHaveLength(1)
    expect(devices[0]).toMatchObject({
      name: 'Mac A',
      current: true,
      kind: 'desktop',
      version: '0.3.0',
    })
    // The environment fixes the server, so a sign-in cannot choose another.
    await expect(cloud.signIn('https://other.example')).rejects.toThrow(
      /SARTO_CLOUD_URL sets the server/,
    )

    await cloud.signOut()
    expect(cloud.status().account.state).toBe('signed-out')
    // Signed out at the server too: the tokens it had are refused at once.
    expect(auth.verifyToken(refreshed!.token)).toBeNull()
    expect(auth.verifyToken(relay.token)).toBeNull()
    cloud.stop()
  })

  it('returns authUrl without spawning a browser when openBrowser is false, and supports cancelSignIn', async () => {
    const tmp = await mkdtemp(path.join(os.tmpdir(), 'sarto-cloud-cancel-'))
    let openerCalled = false
    const cloud = await CloudAccount.load({
      dataPath: tmp,
      env: { SARTO_CLOUD_URL: origin },
      fetch: (url, init) => fetch(url, init),
      cipher: NO_SYSTEM_ENCRYPTION,
      clientInfo: async () => ({
        kind: 'daemon',
        name: 'Mac Cancel',
        os: 'macOS',
        arch: 'arm64',
        version: '1.0.0',
      }),
      locale: () => 'en',
      log: createLogger('test-account-cancel'),
      openBrowser: async () => {
        openerCalled = true
      },
    })
    try {
      const started = await cloud.signIn(undefined, { openBrowser: false })
      expect(openerCalled).toBe(false)
      expect(started.account.state).toBe('signing-in')
      expect(started.authUrl).toBeTruthy()
      expect(new URL(started.authUrl!).pathname).toBe('/signin/app/')

      const cancelled = cloud.cancelSignIn()
      expect(cancelled.account.state).toBe('signed-out')
    } finally {
      cloud.stop()
      await rm(tmp, { recursive: true, force: true })
    }
  })

  it('hardcodes Official Sarto Cloud origin and rejects custom serverUrl when no env override is set', async () => {
    const tmp = await mkdtemp(path.join(os.tmpdir(), 'sarto-cloud-fixed-'))
    const cloud = await CloudAccount.load({
      dataPath: tmp,
      env: {},
      fetch: (url, init) => fetch(url, init),
      cipher: NO_SYSTEM_ENCRYPTION,
      clientInfo: async () => ({
        kind: 'daemon',
        name: 'Mac Fixed',
        os: 'macOS',
        arch: 'arm64',
        version: '1.0.0',
      }),
      locale: () => 'en',
      log: createLogger('test-account-fixed'),
    })
    try {
      expect(cloud.status()).toMatchObject({
        origin: 'https://sarto.1o.ink',
        fixedOrigin: true,
      })
      await expect(cloud.signIn('https://other.example')).rejects.toThrow(
        /Official Sarto Cloud address cannot be changed/,
      )
    } finally {
      cloud.stop()
      await rm(tmp, { recursive: true, force: true })
    }
  })

  it('syncs active App palette to /api/v1/me/preferences on sign-in and palette switches', async () => {
    const tmp = await mkdtemp(path.join(os.tmpdir(), 'sarto-cloud-theme-'))
    const cloud = await CloudAccount.load({
      dataPath: tmp,
      env: { SARTO_CLOUD_URL: origin },
      fetch: (url, init) => fetch(url, init),
      cipher: NO_SYSTEM_ENCRYPTION,
      clientInfo: async () => ({
        kind: 'daemon',
        name: 'Mac Theme',
        os: 'macOS',
        arch: 'arm64',
        version: '0.3.0',
      }),
      locale: () => 'en',
      log: createLogger('test-account-theme'),
      openBrowser: async (url) => {
        void browser(url)
      },
    })
    const themeSync = new CloudThemeSync({
      cloud,
      log: createLogger('test-cloud-theme'),
    })
    try {
      // Queue active palette before sign-in completes; sign-in pushes it automatically.
      themeSync.noteAppTheme('warm')
      const signedIn = new Promise<void>((resolve) => {
        const stop = cloud.onChange((status) => {
          themeSync.noteAccountChanged()
          if (status.account.state === 'signed-in') {
            stop()
            resolve()
          }
        })
      })
      await cloud.signIn()
      await signedIn
      await themeSync.pushIfNeeded()

      const afterSignIn = await cloud.preferences()
      expect(afterSignIn.appTheme).toBe('warm')
      expect(typeof afterSignIn.appThemeUpdatedAt).toBe('number')

      // Switching palette updates the server immediately.
      themeSync.noteAppTheme('alabaster')
      await themeSync.pushIfNeeded()
      const afterSwitch = await cloud.preferences()
      expect(afterSwitch.appTheme).toBe('alabaster')

      // Explicit setAppTheme (e.g. macOS system Light/Dark switch or startup sync) updates
      // immediately and stays sticky across subsequent no-op flushes.
      const explicit = await themeSync.setAppTheme('crystal')
      expect(explicit.appTheme).toBe('crystal')
      await themeSync.pushIfNeeded()
      expect((await cloud.preferences()).appTheme).toBe('crystal')

      // Invalid palette values are ignored without mutating server state.
      themeSync.noteAppTheme('invalid-palette')
      await themeSync.pushIfNeeded()
      expect((await cloud.preferences()).appTheme).toBe('crystal')
    } finally {
      themeSync.stop()
      cloud.stop()
      await rm(tmp, { recursive: true, force: true })
    }
  })
})

it('keeps the replacement account when an earlier refresh is refused', async () => {
  const tmp = await mkdtemp(path.join(os.tmpdir(), 'sarto-account-reload-'))
  const file = accountFile(tmp)
  const save = (id: string) =>
    writeAccount(file, {
      profile: { id, email: `${id}@example.com`, name: null, avatarUrl: null },
      encrypted: false,
      plainText: true,
      token: id,
    })
  const started = Promise.withResolvers<void>()
  const response = Promise.withResolvers<Response>()
  try {
    await save('first')
    const cloud = await CloudAccount.load({
      dataPath: tmp,
      env: {},
      cipher: NO_SYSTEM_ENCRYPTION,
      fetch: async (_, init) => {
        if (new URLSearchParams(String(init.body)).get('refresh_token') === 'second') {
          return Response.json({
            access_token: 'access-b',
            refresh_token: 'rotated-b',
            expires_in: 3600,
          })
        }
        started.resolve()
        return response.promise
      },
      clientInfo: async () => ({
        kind: 'daemon',
        name: 'Mac',
        os: 'macOS',
        arch: 'arm64',
        version: null,
      }),
      locale: () => 'en',
      log: createLogger('test-account-reload'),
    })
    const pending = cloud.check()
    await started.promise
    await save('second')
    await cloud.account().reload()
    const replacement = cloud.account().currentToken()
    response.resolve(Response.json({ error: 'invalid_grant' }, { status: 400 }))
    await pending
    expect((await replacement)?.token).toBe('access-b')
    expect(cloud.account().signedIn()?.id).toBe('second')
    expect((await readAccount(file, () => {}))?.profile.id).toBe('second')
  } finally {
    await rm(tmp, { recursive: true, force: true })
  }
})
