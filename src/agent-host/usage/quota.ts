// Plan quota readings: what the agents' own files say of their windows, the account they belong
// to, and the measurements kept for burn-rate forecasts. The rules follow Sarto's Mac app
// (UsageIslandKit's Records.swift and Forecast.swift), so either side reads the other's data.

import { createHash } from 'node:crypto'
import type { PlanLimit } from '@shared/agent-host'
import type { AgentId } from '@shared/thread'
import type { QuotaReading, QuotaSample, QuotaWindow, QuotaWindowKind } from '@shared/usage'

/** How long a window's measurements are kept. */
export const HISTORY_MS = 48 * 3_600_000
/** The most measurements kept per window. */
const HISTORY_SAMPLES = 48
/** Reset times this close apart belong to one cycle of a window. */
const CYCLE_SLACK_MS = 600_000

export const SESSION_MINUTES = 300
export const WEEK_MINUTES = 7 * 24 * 60
const DAY_MINUTES = 24 * 60
const MONTH_MINUTES = 30 * DAY_MINUTES

/** Where a stored reading came from: an agent's own files, or the agent's live plan limits. */
export type QuotaOrigin = 'files' | 'agent'

/** A reading as a reader stores it, with what the reader keeps to merge the next one. */
export interface StoredQuota {
  reading: QuotaReading
  /** A reader's own state, such as Codex's latest snapshot per pool. */
  state: string | null
}

/**
 * A short digest of an account id that never gives the id away: the first 8 bytes of
 * SHA-256("<provider>:<id>") in hex, as the Mac app's `ProviderAccount.fingerprint`.
 */
export function accountFingerprint(provider: string, id: string): string {
  return createHash('sha256').update(`${provider}:${id}`).digest().subarray(0, 8).toString('hex')
}

export function slug(text: string): string {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_|_$/g, '')
}

/** A window's id and kind by its length, as Codex's own `/status` and Sarto's limits name it. */
export function windowByMinutes(minutes: number): { id: string; kind: QuotaWindowKind } | null {
  if (!Number.isFinite(minutes) || minutes <= 0) return null
  if (minutes === SESSION_MINUTES) return { id: 'five_hour', kind: 'session' }
  if (minutes === WEEK_MINUTES) return { id: 'seven_day', kind: 'weekly' }
  // The Mac app takes a day or more as weekly, anything shorter as a session.
  const kind: QuotaWindowKind = minutes >= DAY_MINUTES ? 'weekly' : 'session'
  if (minutes < 60) return { id: `${minutes}_minute`, kind }
  if (minutes < DAY_MINUTES) return { id: `${Math.round(minutes / 60)}_hour`, kind }
  if (minutes < WEEK_MINUTES) return { id: `${Math.round(minutes / DAY_MINUTES)}_day`, kind }
  return { id: minutes <= 31 * DAY_MINUTES ? 'monthly' : 'annual', kind }
}

/** 0 to 100. */
export function percent(value: number): number {
  return Math.max(0, Math.min(100, value))
}

/** The newest measurement among the windows. */
export function newest(windows: readonly QuotaWindow[]): number | null {
  let at: number | null = null
  for (const window of windows) {
    if (window.observedAt !== null && (at === null || window.observedAt > at))
      at = window.observedAt
  }
  return at
}

/** Whether two reset times belong to one cycle of a window, as the Mac app's `sameResetCycle`. */
export function sameCycle(a: number | null, b: number | null): boolean {
  if (a === null || b === null) return a === b
  return Math.abs(a - b) <= CYCLE_SLACK_MS
}

/**
 * Adds a measurement to a window's list, as the Mac app's `QuotaForecaster.record`: measurements
 * older than 48 hours go, an older one than the last is ignored, a new reset cycle (or a drop of
 * more than 15 points) starts the list over, and one that barely moved within ten minutes adds
 * nothing.
 */
export function recordSample(
  list: readonly QuotaSample[],
  sample: QuotaSample,
  now: number,
): QuotaSample[] {
  const kept = list.filter((item) => now - item.at <= HISTORY_MS)
  const last = kept.at(-1)
  if (last) {
    if (sample.at < last.at) return kept
    if (!sameCycle(last.resetsAt, sample.resetsAt) || sample.usedPercent + 15 < last.usedPercent) {
      return [sample]
    }
    if (Math.abs(sample.usedPercent - last.usedPercent) < 0.05 && sample.at - last.at < 600_000) {
      return kept
    }
  }
  kept.push(sample)
  return kept.length > HISTORY_SAMPLES ? kept.slice(-HISTORY_SAMPLES) : kept
}

/** Whether a window's reset time has passed, so its usage no longer counts. */
export function hasReset(window: QuotaWindow, now: number): boolean {
  return window.resetsAt !== null && window.resetsAt <= now
}

/**
 * One reading per agent from both origins: each window as last measured by either, the account
 * from the files (the live limits name none), and the plan from the files, else the agent's.
 */
export function mergeOrigins(files: QuotaReading | null, agent: QuotaReading | null): QuotaReading {
  if (!files || !agent) return (files ?? agent)!
  const windows = new Map<string, QuotaWindow>()
  for (const window of [...files.windows, ...agent.windows]) {
    const known = windows.get(window.id)
    if (!known || (window.observedAt ?? 0) > (known.observedAt ?? 0)) windows.set(window.id, window)
  }
  const merged = [...windows.values()]
  return {
    agentId: files.agentId,
    account: files.account,
    plan: files.plan ?? agent.plan,
    windows: merged,
    observedAt: newest(merged),
  }
}

/** The length a live plan limit's window id names; null when it names none. */
function minutesOf(window: string): number | null {
  if (window.includes('five_hour')) return SESSION_MINUTES
  if (window.includes('seven_day') || window === 'weekly') return WEEK_MINUTES
  if (window === 'monthly') return MONTH_MINUTES
  if (window === 'daily') return DAY_MINUTES
  const counted = /(?:^|_)(\d+)_(minute|hour|day)(?:_|$)/.exec(window)
  if (counted) {
    const n = Number(counted[1])
    return counted[2] === 'minute' ? n : counted[2] === 'hour' ? n * 60 : n * DAY_MINUTES
  }
  return null
}

/**
 * The agent's live plan limits as a reading of the agent origin. A label `Weekly · Opus` scopes
 * the window to its models, except Antigravity's Gemini group, which is its main allowance, as
 * in the Mac app. Beside a window of a known length, one of none is a pool of that plan period
 * (Cursor's Auto and other models), scoped by its label. A window with no used share is left out.
 */
export function limitsReading(
  agentId: AgentId,
  plan: { tier?: string; account?: string | null; limits: readonly PlanLimit[] },
): QuotaReading | null {
  const counted = plan.limits.filter(
    (limit) => limit.usedPercent !== null && limit.window !== 'overage',
  )
  const period = counted.map((limit) => minutesOf(limit.window)).find((m) => m !== null) ?? null
  const windows: QuotaWindow[] = []
  for (const limit of counted) {
    const length = minutesOf(limit.window)
    const pool = length === null && period !== null
    const minutes = pool ? period : length
    const named = pool ? limit.label : limit.label.split(' · ')[1]?.trim() || null
    const main =
      named === null ||
      (agentId.startsWith('antigravity') && /gemini/i.test(named) && !/argon/i.test(named))
    const kind: QuotaWindowKind = !main
      ? 'scoped'
      : minutes === null
        ? 'other'
        : minutes >= DAY_MINUTES
          ? 'weekly'
          : 'session'
    windows.push({
      id: limit.window,
      kind,
      scope: main ? null : named,
      minutes,
      usedPercent: percent(limit.usedPercent!),
      resetsAt: limit.resetsAt,
      observedAt: limit.observedAt,
      ...(limit.amount ? { amount: limit.amount } : {}),
    })
  }
  if (windows.length === 0 && !plan.tier) return null
  return {
    agentId,
    account: plan.account ?? null,
    plan: plan.tier ?? null,
    windows,
    observedAt: newest(windows),
  }
}
