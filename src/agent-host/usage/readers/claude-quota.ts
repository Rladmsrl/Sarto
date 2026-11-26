// Claude Code's plan quota from the cache it keeps itself in `.claude.json`: the windows of its
// last usage fetch (`cachedUsageUtilization`) and the plan and account of its sign-in
// (`oauthAccount`). Nothing is fetched; the numbers are as fresh as Claude Code's own cache.
// The rules follow Sarto's Mac app (UsageIslandKit's ClaudeCodeReader.swift), which read them
// off Claude Code 2.1's own code.

import { readFile, stat } from 'node:fs/promises'
import type { QuotaReading, QuotaWindow, QuotaWindowKind } from '@shared/usage'
import { configLocations } from '../../agent-details'
import { claudeJsonPath } from '../../plan-tier'
import { number, object, time } from '../../vendor-usage/common'
import type { QuotaContext, ScanContext } from '../model'
import { accountFingerprint, newest, percent, SESSION_MINUTES, slug, WEEK_MINUTES } from '../quota'

const AGENT_ID = 'claude-code'

type Json = Record<string, unknown>

function text(value: unknown): string | null {
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : null
}

/** Seat kinds, the same table as Claude Code's own (`team_tier_1` is the premium seat). */
function seat(seatTier: string | null): string {
  switch (seatTier) {
    case 'team_tier_1':
    case 'team_bendep_nonprofit_premium':
    case 'team_labs_premium':
    case 'enterprise_tier_1':
    case 'enterprise_bendep_premium':
      return ' Premium'
    case 'team_standard':
    case 'team_bendep_nonprofit_standard':
    case 'team_labs_standard':
    case 'enterprise_standard':
    case 'enterprise_nonprofit':
    case 'enterprise_higher_ed':
      return ' Standard'
    case 'enterprise_usage_based':
    case 'enterprise_usage_based_chat':
    case 'enterprise_hipaa_chat':
    case 'enterprise_hipaa_chat_and_code':
      return ' · Usage-based'
    default:
      return ''
  }
}

/**
 * The plan as Claude Code names it: its stored display name, else the organization type. The
 * rate-limit tier is not the plan (a Team premium seat has Max 5x limits); it only tells Max 5x
 * from Max 20x, and stands in when an older Claude Code wrote no organization type.
 */
export function claudePlan(account: Json | null): string | null {
  if (!account) return null
  const name = text(account.planDisplayName)
  if (name) return name
  const tier = (text(account.userRateLimitTier) ?? '').toLowerCase()
  switch (text(account.organizationType)) {
    case 'claude_max':
      return tier.includes('max_20x') ? 'Max 20×' : tier.includes('max_5x') ? 'Max 5×' : 'Max'
    case 'claude_pro':
      return 'Pro'
    case 'claude_team':
      return `Team${seat(text(account.seatTier))}`
    case 'claude_enterprise':
      return `Enterprise${seat(text(account.seatTier))}`
  }
  if (tier.includes('max_20x')) return 'Max 20×'
  if (tier.includes('max_5x')) return 'Max 5×'
  if (tier.includes('max')) return 'Max'
  if (tier.includes('pro')) return 'Pro'
  if (tier.includes('team')) return 'Team'
  if (tier.includes('enterprise')) return 'Enterprise'
  return null
}

function windowOf(
  kind: QuotaWindowKind,
  id: string,
  scope: string | null,
  used: number,
  resetsAt: number | null,
  observedAt: number | null,
): QuotaWindow {
  const weekly = kind === 'weekly' || (kind === 'scoped' && id.startsWith('seven_day'))
  return {
    id,
    kind,
    scope,
    minutes: kind === 'session' ? SESSION_MINUTES : weekly ? WEEK_MINUTES : null,
    usedPercent: percent(used),
    resetsAt,
    observedAt,
  }
}

/** The windows of `cachedUsageUtilization`: its `limits`, else the older five_hour and seven_day. */
function windowsOf(utilization: Json, observedAt: number | null): QuotaWindow[] {
  const windows: QuotaWindow[] = []
  const limits = Array.isArray(utilization.limits) ? utilization.limits : []
  for (const value of limits) {
    const limit = object(value)
    if (!limit) continue
    const kind = text(limit.kind) ?? ''
    const scope = text(object(object(limit.scope)?.model)?.display_name)
    const window: QuotaWindowKind =
      kind === 'session'
        ? 'session'
        : scope !== null
          ? 'scoped'
          : kind.startsWith('weekly')
            ? 'weekly'
            : 'other'
    const id =
      window === 'session'
        ? 'five_hour'
        : window === 'weekly'
          ? 'seven_day'
          : window === 'scoped'
            ? `${kind === '' || kind.startsWith('weekly') ? 'seven_day' : slug(kind)}_${slug(scope!)}`
            : slug(kind) || 'other'
    if (windows.some((known) => known.id === id)) continue
    windows.push(
      windowOf(window, id, scope, number(limit.percent) ?? 0, time(limit.resets_at), observedAt),
    )
  }
  if (limits.length > 0) return windows
  const five = object(utilization.five_hour)
  if (five) {
    const used = number(five.utilization) ?? 0
    windows.push(windowOf('session', 'five_hour', null, used, time(five.resets_at), observedAt))
  }
  const week = object(utilization.seven_day)
  if (week) {
    const used = number(week.utilization) ?? 0
    windows.push(windowOf('weekly', 'seven_day', null, used, time(week.resets_at), observedAt))
  }
  return windows
}

/**
 * The quota a `.claude.json` holds; null when it is not JSON, as while Claude Code is writing it.
 * The account is a fingerprint of its `accountUuid`, else its address, never the id itself.
 */
export function parseClaudeQuota(json: string): QuotaReading | null {
  let config: Json | null
  try {
    config = object(JSON.parse(json))
  } catch {
    return null
  }
  if (!config) return null
  const account = object(config.oauthAccount)
  const id = text(account?.accountUuid) ?? text(account?.emailAddress)
  const cached = object(config.cachedUsageUtilization)
  const utilization = object(cached?.utilization)
  const fetched = number(cached?.fetchedAtMs)
  const observedAt = fetched !== null && fetched > 0 ? fetched : null
  const windows = utilization ? windowsOf(utilization, observedAt) : []
  return {
    agentId: AGENT_ID,
    account: id ? accountFingerprint('claude', id) : null,
    plan: claudePlan(account),
    windows,
    observedAt: newest(windows),
  }
}

/** Where Claude Code keeps `.claude.json` for this environment. */
export function claudeJsonFile(
  env: ScanContext['env'],
  home: string,
  platform: ScanContext['platform'],
): string {
  const folder = configLocations(AGENT_ID, (name) => env[name], home, platform).find(
    (item) => item.id === 'folder',
  )
  if (!folder) throw new Error('Claude Code has no configuration folder')
  return claudeJsonPath(folder, home, platform)
}

/** The quota in Claude Code's `.claude.json`; null when there is none or it cannot be read now. */
export async function readClaudeQuota(context: QuotaContext): Promise<QuotaReading | null> {
  const file = claudeJsonFile(context.env, context.home, context.platform)
  let json: string
  try {
    json = await readFile(file, 'utf8')
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code
    if (code !== 'ENOENT' && code !== 'ENOTDIR') {
      context.log('warn', `Could not read ${file}: ${(error as Error).message}`)
    }
    return null
  }
  return parseClaudeQuota(json)
}

/** Each `.claude.json`'s modification time and size when its quota was last stored. */
const stored = new Map<string, string>()

/**
 * Stores the quota of Claude Code's `.claude.json` again when the file changed since it was last
 * stored; the file holds Claude Code's whole state and can be large, so an unchanged one is not
 * read.
 */
export async function refreshClaudeQuota(context: QuotaContext): Promise<void> {
  const file = claudeJsonFile(context.env, context.home, context.platform)
  let mark: string
  try {
    const info = await stat(file)
    mark = `${info.mtimeMs}:${info.size}`
  } catch {
    return
  }
  if (stored.get(file) === mark) return
  const quota = await readClaudeQuota(context)
  if (!quota) return
  context.quota(quota)
  stored.set(file, mark)
}
