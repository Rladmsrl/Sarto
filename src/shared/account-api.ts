// The HTTP interface of the Sarto account service that Sarto's clients speak: the OAuth 2.0
// endpoints of its public clients (RFC 6749, 7009, 8252, 8628) and the account. Imports nothing of
// Node.js, since clients outside Node.js speak it too.

import type { SignedOutReason, SignInFailure } from '@shared/account'
import {
  parseSubmitReportResponse,
  type ReportListResponse,
  type ReportStatus,
  type SubmitReportResponse,
} from '@shared/report'

export const DESKTOP_CLIENT = 'sarto-mac'
export const DAEMON_CLIENT = 'sarto-daemon'
export const WEB_CLIENT = 'sarto-web'

const DEVICE_GRANT = 'urn:ietf:params:oauth:grant-type:device_code'
const TIMEOUT_MS = 15_000
const REPORT_UPLOAD_TIMEOUT_MS = 300_000
// An access token is treated as expired this long before the service says, for clock drift.
const EXPIRY_MARGIN_MS = 60_000
const MAX_NAME = 100
const MAX_FIELD = 40

export type AccountFetch = (url: string, init: RequestInit) => Promise<Response>

/** How the account page lists this client. */
export interface ClientInfo {
  kind: 'desktop' | 'daemon' | 'web'
  name: string
  os: string
  arch: string
  version: string | null
  /** The system user signing in, which the daemon's confirm page names. */
  user?: string
}

/** Cuts each field to what the service takes. */
export function clientInfo(info: ClientInfo): ClientInfo {
  const cut = (text: string, max: number): string => text.trim().slice(0, max) || 'unknown'
  return {
    kind: info.kind,
    name: cut(info.name, MAX_NAME),
    os: cut(info.os, MAX_FIELD),
    arch: cut(info.arch, MAX_FIELD),
    version: info.version ? info.version.slice(0, MAX_FIELD) : null,
    ...(info.user?.trim() ? { user: cut(info.user, MAX_FIELD) } : {}),
  }
}

export interface TokenSet {
  accessToken: string
  refreshToken: string
  /** When to stop using the access token, in Unix milliseconds. */
  accessExpiresAt: number
}

export interface Me {
  account: { id: string; email: string; name: string | null; avatarUrl: string | null }
}

export interface DeviceCode {
  deviceCode: string
  userCode: string
  verificationUri: string
  verificationUriComplete: string | null
  /** Seconds the code is valid. */
  expiresIn: number
  /** Seconds to wait between polls. */
  interval: number
}

/** An answer the service gave, by its stable code. */
export class AccountServiceError extends Error {
  constructor(
    readonly code: string,
    message: string,
    readonly status: number,
    /** Why `invalid_grant` signed the client out, when the service says. */
    readonly reason: string | null = null,
    /** The interval `slow_down` asks for, in seconds. */
    readonly interval: number | null = null,
    /** Seconds before a rate-limited request may retry. */
    readonly retryAfter: number | null = null,
  ) {
    super(message)
    this.name = 'AccountServiceError'
  }
}

/** The service could not be reached, or did not answer in time. */
export class AccountNetworkError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'AccountNetworkError'
  }
}

const isText = (value: unknown): value is string => typeof value === 'string' && value.length > 0

/** The longest relay token taken, as long as a relay message carries. */
const MAX_RELAY_TOKEN = 4096

const isCount = (value: unknown): value is number =>
  typeof value === 'number' && Number.isSafeInteger(value) && value >= 0

function record(value: unknown): Record<string, unknown> | null {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null
}

function parseJson(text: string): Record<string, unknown> | null {
  try {
    return text ? record(JSON.parse(text)) : null
  } catch {
    return null
  }
}

export class AccountApi {
  constructor(
    readonly base: string,
    private readonly fetch: AccountFetch,
    private readonly now: () => number = Date.now,
  ) {}

  exchangeCode(input: {
    code: string
    redirectUri: string
    verifier: string
    clientId?: string
  }): Promise<TokenSet> {
    return this.token({
      grant_type: 'authorization_code',
      client_id: input.clientId ?? DESKTOP_CLIENT,
      code: input.code,
      redirect_uri: input.redirectUri,
      code_verifier: input.verifier,
    })
  }

  refresh(clientId: string, refreshToken: string, info?: ClientInfo): Promise<TokenSet> {
    return this.token({
      grant_type: 'refresh_token',
      client_id: clientId,
      refresh_token: refreshToken,
      ...(info ? { client_info: JSON.stringify(clientInfo(info)) } : {}),
    })
  }

  pollDevice(deviceCode: string): Promise<TokenSet> {
    return this.token({
      grant_type: DEVICE_GRANT,
      client_id: DAEMON_CLIENT,
      device_code: deviceCode,
    })
  }

  async startDevice(info: ClientInfo): Promise<DeviceCode> {
    const body = await this.form('/api/oauth/device', {
      client_id: DAEMON_CLIENT,
      client_info: JSON.stringify(clientInfo(info)),
    })
    const { device_code, user_code, verification_uri, verification_uri_complete } = body
    const { expires_in, interval } = body
    if (
      !isText(device_code) ||
      !isText(user_code) ||
      !isText(verification_uri) ||
      typeof expires_in !== 'number' ||
      typeof interval !== 'number'
    ) {
      throw this.unexpected('/api/oauth/device')
    }
    return {
      deviceCode: device_code,
      userCode: user_code,
      verificationUri: verification_uri,
      verificationUriComplete: isText(verification_uri_complete) ? verification_uri_complete : null,
      expiresIn: expires_in,
      interval: Math.max(1, interval),
    }
  }

  /** Signs the client out at the service, revoking the token's whole family (RFC 7009). */
  async revoke(clientId: string, token: string): Promise<void> {
    await this.request('/api/oauth/revoke', {
      method: 'POST',
      body: new URLSearchParams({ token, token_type_hint: 'refresh_token', client_id: clientId }),
    })
  }

  async me(accessToken: string): Promise<Me> {
    const body = await this.request('/api/v1/me', {
      method: 'GET',
      headers: { authorization: `Bearer ${accessToken}` },
    })
    const account = record(body?.account)
    const name = account?.name
    const avatarUrl = account?.avatarUrl
    if (
      !account ||
      !isText(account.id) ||
      !isText(account.email) ||
      (name !== null && typeof name !== 'string') ||
      (avatarUrl !== null && typeof avatarUrl !== 'string')
    ) {
      throw this.unexpected('/api/v1/me')
    }
    return {
      account: {
        id: account.id,
        email: account.email,
        name: name || null,
        avatarUrl: avatarUrl || null,
      },
    }
  }

  /** Submits a problem report (signed-in or anonymous); answers with its id such as `SR-7F3K2Q`. */
  async submitReport(input: {
    accessToken: string | null
    title?: string | null
    description: string
    version?: string | null
    platform?: string | null
    deviceName?: string | null
    bundle?: { filename: string; bytes: Uint8Array } | null
  }): Promise<SubmitReportResponse> {
    const headers: Record<string, string> = {}
    if (input.accessToken) headers.authorization = `Bearer ${input.accessToken}`
    let bodyInit: FormData | string
    if (input.bundle) {
      const form = new FormData()
      form.append('description', input.description)
      if (input.title) form.append('title', input.title)
      if (input.version) form.append('version', input.version)
      if (input.platform) form.append('platform', input.platform)
      if (input.deviceName) form.append('deviceName', input.deviceName)
      const copy = new Uint8Array(input.bundle.bytes.byteLength)
      copy.set(input.bundle.bytes)
      form.append(
        'bundle',
        new Blob([copy], { type: 'application/zip' }),
        input.bundle.filename || 'sarto-report.zip',
      )
      bodyInit = form
    } else {
      headers['content-type'] = 'application/json; charset=utf-8'
      bodyInit = JSON.stringify({
        description: input.description,
        ...(input.title ? { title: input.title } : {}),
        ...(input.version ? { version: input.version } : {}),
        ...(input.platform ? { platform: input.platform } : {}),
        ...(input.deviceName ? { deviceName: input.deviceName } : {}),
      })
    }
    const body = await this.request(
      '/api/v1/reports',
      { method: 'POST', headers, body: bodyInit },
      REPORT_UPLOAD_TIMEOUT_MS,
    )
    const parsed = parseSubmitReportResponse(body)
    if (!parsed) throw this.unexpected('/api/v1/reports')
    return parsed
  }

  /** Lists the signed-in account's submitted problem reports. */
  async listReports(
    accessToken: string,
    options?: { limit?: number; offset?: number; status?: ReportStatus },
  ): Promise<ReportListResponse> {
    const qs = new URLSearchParams()
    if (options?.limit !== undefined) qs.set('limit', String(options.limit))
    if (options?.offset !== undefined) qs.set('offset', String(options.offset))
    if (options?.status) qs.set('status', options.status)
    const suffix = qs.toString() ? `?${qs.toString()}` : ''
    const body = await this.request(`/api/v1/reports${suffix}`, {
      method: 'GET',
      headers: { authorization: `Bearer ${accessToken}` },
    })
    if (!body || !Array.isArray(body.reports) || typeof body.total !== 'number') {
      throw this.unexpected('/api/v1/reports')
    }
    return body as unknown as ReportListResponse
  }

  /**
   * A relay token for the access token: only the relays take it, and only for about an hour, so
   * the relays never hold anything that can act on the account.
   */
  async relayToken(accessToken: string): Promise<{ token: string; expiresAt: number }> {
    const body = await this.request('/api/v1/relay/token', {
      method: 'POST',
      headers: { authorization: `Bearer ${accessToken}` },
    })
    const token = body?.token
    const expiresAt = body?.expiresAt
    if (!isText(token) || token.length > MAX_RELAY_TOKEN || !isCount(expiresAt)) {
      throw this.unexpected('/api/v1/relay/token')
    }
    return { token, expiresAt }
  }

  private async token(fields: Record<string, string>): Promise<TokenSet> {
    const body = await this.form('/api/oauth/token', fields)
    const { access_token, refresh_token, expires_in } = body
    if (!isText(access_token) || !isText(refresh_token) || typeof expires_in !== 'number') {
      throw this.unexpected('/api/oauth/token')
    }
    return {
      accessToken: access_token,
      refreshToken: refresh_token,
      accessExpiresAt: this.now() + Math.max(0, expires_in * 1000 - EXPIRY_MARGIN_MS),
    }
  }

  private async form(path: string, fields: Record<string, string>) {
    const body = await this.request(path, { method: 'POST', body: new URLSearchParams(fields) })
    if (!body) throw this.unexpected(path)
    return body
  }

  /** The answer's JSON, null for an empty one; any error the service gives as `AccountServiceError`. */
  private async request(
    path: string,
    init: RequestInit,
    timeoutMs = TIMEOUT_MS,
  ): Promise<Record<string, unknown> | null> {
    let response: Response
    try {
      response = await this.fetch(`${this.base}${path}`, {
        ...init,
        headers: { accept: 'application/json', ...init.headers },
        redirect: 'error',
        signal: AbortSignal.timeout(timeoutMs),
      })
    } catch (error) {
      throw new AccountNetworkError(`Could not reach ${this.base}: ${(error as Error).message}`)
    }
    const text = await response.text().catch(() => '')
    const body = parseJson(text)
    if (response.ok) {
      if (text && !body) throw this.unexpected(path)
      return body
    }
    const code = body?.error
    if (!isText(code)) {
      throw new AccountServiceError(
        'server_error',
        `${path} answered ${response.status}`,
        response.status,
      )
    }
    const message = body?.error_description ?? body?.message
    const headerRetry = response.headers.get('retry-after')
    const parsedHeaderRetry = headerRetry ? Number.parseInt(headerRetry, 10) : Number.NaN
    const retryAfter =
      typeof body?.retry_after === 'number' && Number.isFinite(body.retry_after)
        ? body.retry_after
        : Number.isFinite(parsedHeaderRetry) && parsedHeaderRetry > 0
          ? parsedHeaderRetry
          : null
    throw new AccountServiceError(
      code,
      typeof message === 'string' ? message : code,
      response.status,
      isText(body?.reason) ? body.reason : null,
      typeof body?.interval === 'number' ? body.interval : null,
      retryAfter,
    )
  }

  private unexpected(path: string): AccountServiceError {
    return new AccountServiceError('server_error', `${path} gave an answer Sarto cannot read`, 200)
  }
}

/** Why the service signed this client out, from the `reason` of its `invalid_grant`. */
export function signedOutReason(reason: string | null): SignedOutReason {
  switch (reason) {
    case 'signed_out_from_account_page':
      return 'account-page'
    case 'signed_out_by_admin':
      return 'admin'
    case 'account_disabled':
      return 'disabled'
    case 'refresh_token_reused':
    case 'authorization_code_reused':
      return 'reused'
    case 'expired':
      return 'expired'
    default:
      return 'invalid'
  }
}

/** The service's answer when the account's plan allows no more signed-in clients. */
export const DEVICE_LIMIT = 'device_limit'

/** Why a sign-in did not finish, from the error the service or the network gave. */
export function signInFailure(error: unknown): SignInFailure {
  if (error instanceof AccountNetworkError) return 'network'
  if (error instanceof AccountServiceError) {
    if (error.code === DEVICE_LIMIT) return 'device-limit'
    return error.code === 'account_disabled' || error.reason === 'account_disabled'
      ? 'disabled'
      : 'service'
  }
  return 'local'
}
