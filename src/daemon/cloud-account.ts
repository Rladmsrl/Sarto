// The daemon's Sarto Cloud account: upstream's OAuth `Account` for Official Sarto Cloud, signing
// in through the system browser with a loopback redirect and PKCE, refreshing and revoking its
// tokens. The Official Cloud origin is fixed to `SARTO_CLOUD_URL` (overridable via the
// `SARTO_CLOUD_URL` environment variable for dev/tests).

import { execFile } from 'node:child_process'
import type { AccountStatus } from '@shared/account'
import { AccountApi, DESKTOP_CLIENT, type AccountFetch, type ClientInfo } from '@shared/account-api'
import type { Locale } from '@shared/locale'
import type { ReportListResponse, ReportStatus, SubmitReportResponse } from '@shared/report'
import { relayOrigin } from '@shared/remote/relay'
import { SARTO_CLOUD_URL } from '@shared/sync/wire'
import { Account } from '../core/account'
import type { LoopbackTexts } from '../core/account/loopback'
import { accountFile } from '../core/account/store'
import type { Logger } from '../core/log'
import type { IdentityCipher } from '../core/remote-identity'

/** Points the daemon at another Sarto Cloud, as a staging server. */
export const CLOUD_URL_ENV = 'SARTO_CLOUD_URL'

export interface CloudAccountStatus {
  origin: string
  /** The origin comes from the environment, so a sign-in cannot choose another. */
  fixedOrigin: boolean
  account: AccountStatus
  /** Browser sign-in URL returned when a caller asks to open the browser itself (`openBrowser: false`). */
  authUrl?: string
}

/** One of Sarto's four optical palettes synced to Sarto Cloud web surfaces. */
export const CLOUD_APP_THEMES = ['obsidian', 'warm', 'crystal', 'alabaster'] as const
export type CloudAppTheme = (typeof CLOUD_APP_THEMES)[number]

export function isCloudAppTheme(value: unknown): value is CloudAppTheme {
  return typeof value === 'string' && (CLOUD_APP_THEMES as readonly string[]).includes(value)
}

/** Account-level cloud preferences from `GET/PUT /api/v1/me/preferences`. */
export interface CloudAccountPreferences {
  appTheme: CloudAppTheme | null
  appThemeUpdatedAt: number | null
}

/** A client signed in to the account, as `GET /api/v1/devices` lists it. */
export interface CloudDevice {
  id: string
  kind: ClientInfo['kind']
  name: string
  os: string
  arch: string
  version: string | null
  user: string | null
  createdAt: number
  lastUsedAt: number
  current: boolean
}

export interface CloudAccountOptions {
  dataPath: string
  env: NodeJS.ProcessEnv
  fetch: AccountFetch
  cipher: IdentityCipher
  clientInfo: () => Promise<ClientInfo>
  locale: () => Locale
  log: Logger
  /** Opens a URL in the system browser; the platform's own opener by default. */
  openBrowser?: (url: string) => Promise<void>
  now?: () => number
}

/** The origin a setting names, or null for none that is one. */
function cloudOrigin(raw: string | undefined): string | null {
  const value = raw?.trim()
  if (!value) return null
  return relayOrigin(value)
}

/** Resolves the Sarto Cloud origin from environment overrides or the official cloud default. */
export function resolveCloudOrigin(env: NodeJS.ProcessEnv): string {
  return cloudOrigin(env[CLOUD_URL_ENV]) ?? SARTO_CLOUD_URL
}

export class CloudAccount {
  private current: Account
  private currentOrigin: string
  private readonly listeners = new Set<(status: CloudAccountStatus) => void>()
  /** Captures the sign-in URL for the active `signIn()` call; when `suppressBrowserOpen` is true, the caller opens it. */
  private captureAuthUrl: ((url: string) => void) | null = null
  private lastAuthUrl: string | undefined = undefined
  private suppressBrowserOpen = false

  private constructor(
    private readonly options: CloudAccountOptions,
    readonly fixedOrigin: boolean,
    private readonly fromEnv: boolean,
    origin: string,
    account: Account,
  ) {
    this.currentOrigin = origin
    this.current = account
  }

  static async load(options: CloudAccountOptions): Promise<CloudAccount> {
    const fromEnv = cloudOrigin(options.env[CLOUD_URL_ENV])
    const origin = fromEnv ?? SARTO_CLOUD_URL
    // Forward references: `changed` may run while the instance is being made.
    let instance: CloudAccount | null = null
    const open = (url: string): Promise<void> =>
      instance ? instance.handleOpenBrowser(url) : (options.openBrowser ?? openInBrowser)(url)
    const account = await Account.load(
      accountOptions(options, origin, () => instance?.emit(), open),
    )
    // Official Cloud origin is fixed; only the environment variable overrides it for dev/tests.
    instance = new CloudAccount(options, true, fromEnv !== null, origin, account)
    return instance
  }

  private async handleOpenBrowser(url: string): Promise<void> {
    this.lastAuthUrl = url
    this.captureAuthUrl?.(url)
    // The account reported signing in before its URL was known; subscribers get it now, so the
    // app can open the page again whichever answer reaches it first.
    this.emit()
    if (this.suppressBrowserOpen) return
    await (this.options.openBrowser ?? openInBrowser)(url)
  }

  origin(): string {
    return this.currentOrigin
  }

  account(): Account {
    return this.current
  }

  status(): CloudAccountStatus {
    const account = this.current.status()
    if (account.state !== 'signing-in') {
      this.lastAuthUrl = undefined
    }
    return {
      origin: this.currentOrigin,
      fixedOrigin: this.fixedOrigin,
      account,
      ...(account.state === 'signing-in' && this.lastAuthUrl ? { authUrl: this.lastAuthUrl } : {}),
    }
  }

  onChange(listener: (status: CloudAccountStatus) => void): () => void {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  /**
   * Starts browser sign-in at the cloud's sign-in page. A different server takes effect only while
   * signed out and without an origin from the environment; it is kept for the next start.
   * Pass `openBrowser: false` so a foreground GUI client can open the returned `authUrl` itself.
   */
  async signIn(
    serverUrl?: string,
    options?: { openBrowser?: boolean },
  ): Promise<CloudAccountStatus> {
    if (serverUrl !== undefined && serverUrl.trim() !== '') {
      const origin = relayOrigin(serverUrl.trim())
      if (!origin) throw new Error('Enter an http or https address')
      if (origin !== this.currentOrigin) {
        if (this.fromEnv) throw new Error(`${CLOUD_URL_ENV} sets the server for this daemon`)
        throw new Error('Official Sarto Cloud address cannot be changed')
      }
    }
    if (this.current.status().state === 'signing-in') {
      this.current.cancelSignIn()
    }
    let authUrl: string | undefined
    this.captureAuthUrl = (url) => {
      authUrl = url
    }
    this.suppressBrowserOpen = options?.openBrowser === false
    try {
      await this.current.signIn()
    } finally {
      this.captureAuthUrl = null
      this.suppressBrowserOpen = false
    }
    return { ...this.status(), ...(authUrl ? { authUrl } : {}) }
  }

  /** Cancels an in-flight browser sign-in and releases its loopback callback port immediately. */
  cancelSignIn(): CloudAccountStatus {
    this.lastAuthUrl = undefined
    this.current.cancelSignIn()
    return this.status()
  }

  async signOut(): Promise<CloudAccountStatus> {
    await this.current.signOut()
    return this.status()
  }

  async check(): Promise<CloudAccountStatus> {
    await this.current.check()
    return this.status()
  }

  async devices(): Promise<CloudDevice[]> {
    const body = await this.call('/api/v1/devices', 'GET')
    const list = (body as { devices?: unknown } | null)?.devices
    return Array.isArray(list) ? list.filter(isDevice) : []
  }

  async removeDevice(id: string): Promise<void> {
    if (!/^fam_[0-9a-f]{24}$/.test(id)) throw new Error('Not a device of this account')
    await this.call(`/api/v1/devices/${id}`, 'DELETE')
  }

  async preferences(): Promise<CloudAccountPreferences> {
    const body = await this.call('/api/v1/me/preferences', 'GET')
    return parsePreferences(body)
  }

  async updatePreferences(patch: {
    appTheme?: CloudAppTheme | null
  }): Promise<CloudAccountPreferences> {
    const body = await this.call('/api/v1/me/preferences', 'PUT', patch)
    return parsePreferences(body)
  }

  /** A short-lived relay token for the Mac app to use as a device, never exposed in `sync.status`. */
  async relayToken(): Promise<{ token: string; expiresAt: number }> {
    return this.current.relayToken()
  }

  /**
   * Submits a problem report to Sarto Cloud. Uses the signed-in account's Bearer token (refreshing
   * once on 401), or submits anonymously when signed out and `allowAnonymous` is not false.
   */
  async submitReport(input: {
    title?: string | null
    description: string
    version?: string | null
    platform?: string | null
    deviceName?: string | null
    bundle?: { filename: string; bytes: Uint8Array } | null
    allowAnonymous?: boolean
  }): Promise<SubmitReportResponse> {
    const api = new AccountApi(this.currentOrigin, this.options.fetch, this.options.now)
    if (this.current.status().state === 'signed-in') {
      return this.current.withAccessToken(
        (token) => api.submitReport({ ...input, accessToken: token }),
        (error) => error instanceof Error && 'code' in error && error.code === 'unauthorized',
      )
    }
    if (input.allowAnonymous === false) {
      throw new Error('Sign in to Sarto Cloud to submit this report')
    }
    return api.submitReport({ ...input, accessToken: null })
  }

  /** Lists the signed-in account's submitted problem reports from Sarto Cloud. */
  async listReports(options?: {
    limit?: number
    offset?: number
    status?: ReportStatus
  }): Promise<ReportListResponse> {
    const api = new AccountApi(this.currentOrigin, this.options.fetch, this.options.now)
    return this.current.withAccessToken(
      (token) => api.listReports(token, options),
      (error) => error instanceof Error && 'code' in error && error.code === 'unauthorized',
    )
  }

  stop(): void {
    this.current.stop()
  }

  private async call(
    pathname: string,
    method: 'GET' | 'PUT' | 'DELETE',
    body?: unknown,
  ): Promise<unknown> {
    return this.current.withAccessToken(
      async (token) => {
        const headers: Record<string, string> = {
          accept: 'application/json',
          authorization: `Bearer ${token}`,
        }
        let encoded: string | undefined
        if (body !== undefined) {
          headers['content-type'] = 'application/json'
          encoded = JSON.stringify(body)
        }
        const response = await this.options.fetch(`${this.currentOrigin}${pathname}`, {
          method,
          headers,
          ...(encoded !== undefined ? { body: encoded } : {}),
          redirect: 'error',
          signal: AbortSignal.timeout(15_000),
        })
        if (response.status === 401) throw new Unauthorized()
        if (!response.ok) throw new Error(`${pathname} answered ${response.status}`)
        const text = await response.text()
        return text ? (JSON.parse(text) as unknown) : null
      },
      (error) => error instanceof Unauthorized,
    )
  }

  private emit(): void {
    const status = this.status()
    for (const listener of this.listeners) {
      try {
        listener(status)
      } catch (error) {
        this.options.log.warn(`An account listener failed: ${(error as Error).message}`)
      }
    }
  }
}

class Unauthorized extends Error {}

function accountOptions(
  options: CloudAccountOptions,
  origin: string,
  changed: () => void,
  openBrowser: (url: string) => Promise<void>,
) {
  return {
    file: accountFile(options.dataPath),
    api: new AccountApi(origin, options.fetch, options.now),
    // The Mac app's sign-in: upstream's browser sign-in is the desktop client's.
    client: DESKTOP_CLIENT,
    cipher: options.cipher,
    clientInfo: options.clientInfo,
    locale: options.locale,
    openBrowser,
    // The daemon has no window; the app comes to the front itself on `account.updated`.
    bringToFront: () => {},
    avatar: async () => null,
    failureText: () => sartoTexts(options.locale()).failure,
    loopbackTexts: () => sartoTexts(options.locale()),
    cloud: () => true,
    changed,
    log: options.log,
    ...(options.now ? { now: options.now } : {}),
  }
}

/** What the browser is told on the loopback port, in the app's language. */
function sartoTexts(locale: Locale): LoopbackTexts & { failure: string } {
  return locale === 'zh-CN'
    ? {
        failure: 'Sarto 没能完成登录。请回到 Sarto 重新登录。',
        over: '这次登录已经结束，可以关闭这个窗口回到 Sarto。',
        otherSignIn: '这不是 Sarto 正在等待的登录。请回到 Sarto 重新登录。',
        noCode: '登录没有带回授权码。请回到 Sarto 重新登录。',
        stopped: '已在 Sarto 中取消这次登录，可以关闭这个窗口。',
      }
    : {
        failure: 'Sarto could not finish signing in. Go back to Sarto and sign in again.',
        over: 'This sign-in is over. You can close this window and go back to Sarto.',
        otherSignIn:
          'This is not the sign-in Sarto is waiting for. Go back to Sarto and sign in again.',
        noCode: 'The sign-in came back without a code. Go back to Sarto and sign in again.',
        stopped: 'This sign-in was cancelled in Sarto. You can close this window.',
      }
}

function parsePreferences(value: unknown): CloudAccountPreferences {
  const v = typeof value === 'object' && value !== null ? (value as Record<string, unknown>) : {}
  return {
    appTheme: isCloudAppTheme(v.appTheme) ? v.appTheme : null,
    appThemeUpdatedAt:
      typeof v.appThemeUpdatedAt === 'number' && Number.isFinite(v.appThemeUpdatedAt)
        ? v.appThemeUpdatedAt
        : null,
  }
}

function isDevice(value: unknown): value is CloudDevice {
  if (typeof value !== 'object' || value === null) return false
  const v = value as Record<string, unknown>
  return (
    typeof v.id === 'string' &&
    typeof v.name === 'string' &&
    typeof v.os === 'string' &&
    typeof v.lastUsedAt === 'number' &&
    typeof v.current === 'boolean'
  )
}

/** Opens an http(s) URL with the platform's opener, without a shell. */
export function openInBrowser(url: string): Promise<void> {
  const parsed = URL.parse(url)
  if (!parsed || (parsed.protocol !== 'https:' && parsed.protocol !== 'http:')) {
    return Promise.reject(new Error('Only web addresses are opened'))
  }
  const [command, args] =
    process.platform === 'darwin'
      ? ['/usr/bin/open', [parsed.href]]
      : process.platform === 'win32'
        ? ['rundll32', ['url.dll,FileProtocolHandler', parsed.href]]
        : ['xdg-open', [parsed.href]]
  return new Promise((resolve, reject) => {
    execFile(command, args, { timeout: 15_000 }, (error) => (error ? reject(error) : resolve()))
  })
}
