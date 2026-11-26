// Cursor's plan usage, as the Cursor CLI's own client reads it from its Dashboard service (CLI
// 2026.10.22): with the access token the CLI keeps, in the macOS keychain by default, else in its
// auth.json. The keychain item is read in memory for the requests and dropped.

import { execFile } from 'node:child_process'
import path from 'node:path'
import type { AgentAccount, PlanLimit } from '@shared/agent-host'
import { t } from '../i18n'
import { amountLimit, number, object, percentLimit, time, type VendorUsage } from './common'
import {
  askVendor,
  parseSignIn,
  readSignInFile,
  UsageReadError,
  variable,
  type SignInPlace,
} from './stored-sign-in'

const VENDOR = 'Cursor'
const ORIGIN = 'https://api2.cursor.sh'
export const CURSOR_ORIGINS = [ORIGIN] as const

/** The keychain item the CLI keeps its access token in: `<app>-access-token` for `<app>-user`. */
const KEYCHAIN = { service: 'cursor-access-token', account: 'cursor-user' }

/** How long a refused keychain prompt is not shown again. */
export const KEYCHAIN_BACKOFF_MS = 10 * 60_000

/** A keychain read's outcome: the secret, no such item, or the user's refusal. */
export type KeychainAnswer = { secret: string } | { missing: true } | { refused: true }

export type KeychainRead = (service: string, account: string) => Promise<KeychainAnswer>

/** Where and how a Cursor read finds the sign-in, beyond what every stored sign-in read gets. */
export interface CursorPlace extends SignInPlace {
  keychain?: KeychainRead
}

/** The keychain refused this read, or did within the backoff. */
export class KeychainRefused extends UsageReadError {
  override name = 'KeychainRefused'
}

let refusedAt: number | null = null

/** Forgets a refusal, so the next read asks the keychain again. */
export function forgetKeychainRefusal(): void {
  refusedAt = null
}

// `security` exits with 44 when no item matches; any other failure is a refusal or a dismissed
// prompt, which it reports the same way.
const MISSING_ITEM = 44

const systemKeychain: KeychainRead = (service, account) =>
  new Promise((resolve) => {
    execFile(
      '/usr/bin/security',
      ['find-generic-password', '-s', service, '-a', account, '-w'],
      { timeout: 60_000, maxBuffer: 64 * 1024 },
      (error, stdout) => {
        if (!error) {
          const secret = stdout.trim()
          resolve(secret ? { secret } : { missing: true })
          return
        }
        const code = (error as { code?: unknown }).code
        resolve(code === MISSING_ITEM ? { missing: true } : { refused: true })
      },
    )
  })

/** The CLI's auth.json, where it keeps the token when it does not use the keychain. */
function authFile(place: SignInPlace): string {
  if (place.platform === 'win32') {
    const roaming = variable(place, 'APPDATA') ?? path.join(place.home, 'AppData', 'Roaming')
    return path.join(roaming, 'Cursor', 'auth.json')
  }
  if (place.platform === 'darwin') return path.join(place.home, '.cursor', 'auth.json')
  const config = variable(place, 'XDG_CONFIG_HOME') ?? path.join(place.home, '.config')
  return path.join(config, 'cursor', 'auth.json')
}

/** The access token the CLI keeps; null when it keeps none. */
async function accessToken(place: CursorPlace): Promise<string | null> {
  const store = variable(place, 'AGENT_CLI_CREDENTIAL_STORE')
  if (place.platform === 'darwin' && store !== 'file' && store !== 'memory') {
    if (refusedAt !== null && place.now - refusedAt < KEYCHAIN_BACKOFF_MS) {
      throw new KeychainRefused(`${VENDOR}'s sign-in in the keychain was not allowed`)
    }
    const answer = await (place.keychain ?? systemKeychain)(KEYCHAIN.service, KEYCHAIN.account)
    if ('refused' in answer) {
      refusedAt = place.now
      throw new KeychainRefused(`${VENDOR}'s sign-in in the keychain was not allowed`)
    }
    refusedAt = null
    if ('secret' in answer) return answer.secret
  }
  const text = await readSignInFile(authFile(place))
  if (text === null) return null
  const token = object(parseSignIn(text))?.accessToken
  return typeof token === 'string' && token.trim() ? token.trim() : null
}

function dashboard(
  method: string,
  token: string,
  place: SignInPlace,
  body: object = {},
  bounds: { timeoutMs?: number; maxBytes?: number } = {},
): Promise<unknown> {
  return askVendor(
    {
      vendor: VENDOR,
      origins: CURSOR_ORIGINS,
      url: `${ORIGIN}/aiserver.v1.DashboardService/${method}`,
      method: 'POST',
      headers: {
        authorization: `Bearer ${token}`,
        'content-type': 'application/json',
        'connect-protocol-version': '1',
      },
      body: JSON.stringify(body),
      ...bounds,
    },
    place,
  )
}

/** A percent proto3 JSON leaves out when it is zero. */
function percent(value: unknown): number | null {
  return value === undefined ? 0 : number(value)
}

/**
 * The current period's usage and the plan: a merged plan has one included pool, the others an
 * Auto pool and a pool for the other models beside the total. The total is the included spend
 * over the included limit, in cents, as Cursor's own "You've used 7% of your included usage";
 * `totalPercentUsed` weighs the pools otherwise and reads far lower.
 */
export function parseCursorUsage(usage: unknown, plan: unknown, now: number): VendorUsage | null {
  const body = object(usage)
  const pools = object(body?.planUsage)
  if (!body || !pools) return null
  const planBody = object(plan)
  const info = object(planBody?.planInfo)
  const period = typeof info?.includedUsagePeriod === 'string' ? info.includedUsagePeriod : ''
  const [window, label] = period.toLowerCase().includes('week')
    ? ['seven_day', 'Weekly']
    : ['monthly', 'Monthly']
  const resetsAt = time(info?.includedUsageResetsAt) ?? time(body.billingCycleEnd)
  const included = number(pools.limit)
  let main: PlanLimit
  if (included !== null && included > 0) {
    // proto3 JSON leaves out a spend of zero.
    const spent = pools.includedSpend === undefined ? 0 : number(pools.includedSpend)
    if (spent === null) return null
    main = amountLimit(window, label, spent / 100, included / 100, 'USD', now, resetsAt)
  } else {
    const total = percent(pools.totalPercentUsed)
    if (total === null) return null
    main = percentLimit(window, label, total, now, resetsAt)
  }
  const limits: PlanLimit[] = [main]
  if (planBody?.isMerged !== true) {
    const auto = percent(pools.autoPercentUsed)
    const other = percent(pools.apiPercentUsed)
    if (auto !== null) limits.push(percentLimit('auto', 'Auto', auto, now, resetsAt))
    if (other !== null) {
      limits.push(percentLimit('other_models', 'Other models', other, now, resetsAt))
    }
  }
  const tier = typeof info?.planName === 'string' && info.planName ? info.planName : undefined
  return { ...(tier ? { tier } : {}), limits, balances: [] }
}

/**
 * Reads the plan usage with the CLI's own access token. A token Cursor refuses is renewed once by
 * the CLI itself, then read again.
 */
export async function readCursorUsage(place: CursorPlace): Promise<VendorUsage> {
  let token = await accessToken(place)
  if (!token && variable(place, 'CURSOR_API_KEY')) {
    // Exchanging a key for a token is not read here until it is checked against a real key.
    throw new UsageReadError(t('usageRead.noApiKeyUsage', { vendor: VENDOR }))
  }
  if (!token) throw new UsageReadError(t('usageRead.notSignedIn', { vendor: VENDOR }))
  const read = async (access: string) => {
    const [usage, plan] = await Promise.all([
      dashboard('GetCurrentPeriodUsage', access, place),
      dashboard('GetPlanInfo', access, place),
    ])
    return parseCursorUsage(usage, plan, place.now)
  }
  let usage: VendorUsage | null
  try {
    usage = await read(token)
  } catch (error) {
    if (!(error instanceof UsageReadError) || error.status !== 401 || !place.renew) throw error
    await place.renew()
    token = await accessToken(place)
    if (!token) throw new UsageReadError(t('usageRead.notSignedIn', { vendor: VENDOR }))
    usage = await read(token)
  }
  if (!usage) throw new UsageReadError(t('usageRead.noPlanUsage', { vendor: VENDOR }))
  return usage
}

/** One request on the account, as Cursor's dashboard lists it. */
export interface CursorUsageEvent {
  id: string
  at: number
  model: string
  /** The conversation, which is the session id of an ACP session. */
  conversationId: string | null
  input: number
  output: number
  cacheRead: number
  cacheWrite: number
}

export interface CursorUsagePage {
  events: CursorUsageEvent[]
  /** All the events between the dates, over every page. */
  total: number
  /** The time of the page's oldest event, those left out too; null for an empty page. */
  oldest: number | null
}

/** A token count proto3 JSON leaves out when it is zero, as a whole number. */
function tokens(value: unknown): number {
  const parsed = number(value)
  return parsed !== null && parsed > 0 ? Math.trunc(parsed) : 0
}

/**
 * A page of `GetFilteredUsageEvents`; an event with no time or no tokens, such as one billed per
 * request, is left out. Null when the reply is not that shape.
 */
export function parseCursorUsageEvents(body: unknown): CursorUsagePage | null {
  const reply = object(body)
  if (!reply) return null
  const list = reply.usageEventsDisplay ?? []
  if (!Array.isArray(list)) return null
  const events: CursorUsageEvent[] = []
  let oldest: number | null = null
  for (const item of list) {
    const event = object(item)
    const at = time(event?.timestamp)
    if (at !== null) oldest = oldest === null ? at : Math.min(oldest, at)
    const usage = object(event?.tokenUsage)
    if (!event || !usage || at === null) continue
    const model = typeof event.model === 'string' ? event.model : ''
    const conversation = typeof event.conversationId === 'string' ? event.conversationId : ''
    const counted = {
      input: tokens(usage.inputTokens),
      output: tokens(usage.outputTokens),
      cacheRead: tokens(usage.cacheReadTokens),
      cacheWrite: tokens(usage.cacheWriteTokens),
    }
    if (counted.input + counted.output + counted.cacheRead + counted.cacheWrite === 0) continue
    const id =
      typeof event.usageEventId === 'string' && event.usageEventId
        ? event.usageEventId
        : `${at}:${model}:${conversation}`
    events.push({ id, at, model, conversationId: conversation || null, ...counted })
  }
  return { events, total: tokens(reply.totalUsageEventsCount), oldest }
}

/** The CLI's access token, or null while it is signed out. */
export function cursorAccessToken(place: CursorPlace): Promise<string | null> {
  return accessToken(place)
}

/** A page of a thousand requests, the most Cursor sends, takes it some five seconds. */
const EVENTS_TIMEOUT_MS = 30_000
/** Such a page is some 700 KB. */
const EVENTS_MAX_BYTES = 4 * 1024 * 1024

/** A page, from 1, of the account's requests between two times in ms, newest first. */
export async function readCursorUsageEvents(
  token: string,
  place: SignInPlace,
  range: { start: number; end: number; page: number; pageSize: number },
): Promise<CursorUsagePage> {
  const body = await dashboard(
    'GetFilteredUsageEvents',
    token,
    place,
    {
      startDate: String(range.start),
      endDate: String(range.end),
      page: range.page,
      pageSize: range.pageSize,
    },
    { timeoutMs: EVENTS_TIMEOUT_MS, maxBytes: EVENTS_MAX_BYTES },
  )
  const page = parseCursorUsageEvents(body)
  if (!page) throw new UsageReadError(t('usageRead.unknownAnswer', { vendor: VENDOR }))
  return page
}

export interface CursorSignIn {
  state: 'authenticated' | 'unauthenticated'
  account: AgentAccount | null
}

/**
 * The sign-in from `about --format json`, which names the account and its plan. Signed out, it
 * errors when the CLI keeps its sign-in in the keychain and names no account when it keeps it in
 * a file. Null when neither can be read.
 */
export function parseCursorAbout(run: {
  code: number | null
  stdout: string
  stderr: string
}): CursorSignIn | null {
  if (/Authentication required|Not logged in/i.test(`${run.stdout}\n${run.stderr}`)) {
    return { state: 'unauthenticated', account: null }
  }
  if (run.code !== 0) return null
  let body: Record<string, unknown> | null
  try {
    body = object(JSON.parse(run.stdout))
  } catch {
    return null
  }
  if (!body || !('userEmail' in body)) return null
  if (body.userEmail === null) return { state: 'unauthenticated', account: null }
  const email = typeof body.userEmail === 'string' && body.userEmail ? body.userEmail : null
  if (!email) return null
  const tier = typeof body.subscriptionTier === 'string' ? body.subscriptionTier : ''
  return { state: 'authenticated', account: { kind: 'account', label: tier, email } }
}
