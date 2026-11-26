// Codex's plan quota from its own files: the `rate_limits` its rollouts' token counts carry, as
// the server last reported them, with the plan, and the account of the ChatGPT sign-in in
// `auth.json`. The rules follow Sarto's Mac app (UsageIslandKit's CodexReader.swift), except that
// each limit pool keeps its own latest snapshot: the app let a snapshot of another pool, such as
// GPT-5.3-Codex-Spark's, replace Codex's own windows and plan.

import { open, readdir, readFile, stat } from 'node:fs/promises'
import path from 'node:path'
import type { QuotaReading, QuotaWindow } from '@shared/usage'
import { number, object, time } from '../../vendor-usage/common'
import type { QuotaContext } from '../model'
import { accountFingerprint, newest, percent, slug, windowByMinutes } from '../quota'

const AGENT_ID = 'codex'
/** The pool of Codex's own limits; others are named in their windows. */
const DEFAULT_POOL = 'codex'
const STATE_VERSION = 1

type Json = Record<string, unknown>

/** One pool's snapshot: its windows as read, at the time of the token count that carried it. */
interface PoolSnapshot {
  at: number
  name: string | null
  windows: QuotaWindow[]
}

/** What the reader keeps beside the reading: each pool's latest snapshot, and the latest plan. */
interface CodexQuotaState {
  v: typeof STATE_VERSION
  pools: Record<string, PoolSnapshot>
  plan: { at: number; raw: string } | null
}

/**
 * Plan names as Codex shows them in `/status` (read off the CLI's account display, 2026-11):
 * they do not follow the raw values ("team" is Business, "business" is Enterprise). A newer plan
 * shows as its raw name in title case.
 */
const PLANS: Readonly<Record<string, string>> = {
  free: 'Free',
  go: 'Go',
  plus: 'Plus',
  pro: 'Pro 200',
  prolite: 'Pro 100',
  promax: 'Pro 500',
  team: 'Business',
  self_serve_business_usage_based: 'Business',
  self_serve_business_prolite: 'Business Premium',
  business: 'Enterprise',
  ent26: 'Enterprise',
  enterprise: 'Enterprise',
  enterprise_cbp_usage_based: 'Enterprise',
  enterprise_cbp_automation: 'Enterprise (Automation)',
  edu: 'Edu',
  edu_plus: 'Edu Plus',
  edu_pro: 'Edu Pro',
  sci: 'Academic Researchers',
  sci_plus: 'Academic Researchers Plus',
}

export function codexPlan(raw: string | null | undefined): string | null {
  const plan = raw?.trim().toLowerCase()
  if (!plan) return null
  return (
    PLANS[plan] ??
    plan
      .split(/[_-]+/)
      .filter(Boolean)
      .map((word) => word.charAt(0).toUpperCase() + word.slice(1))
      .join(' ')
  )
}

function text(value: unknown): string | null {
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : null
}

/** A pool's windows, `primary` then `secondary`; a window of unknown length keeps its slot's name. */
function poolWindows(limits: Json, pool: string | null, at: number): QuotaWindow[] {
  const windows: QuotaWindow[] = []
  for (const slot of ['primary', 'secondary'] as const) {
    const window = object(limits[slot])
    if (!window) continue
    const minutes = number(window.window_minutes)
    const named = minutes === null ? null : windowByMinutes(minutes)
    const base = named?.id ?? slot
    windows.push({
      id: pool ? `${slug(pool)}_${base}` : base,
      kind: pool ? 'scoped' : (named?.kind ?? 'other'),
      scope: pool,
      minutes: named ? minutes : null,
      usedPercent: percent(number(window.used_percent) ?? 0),
      resetsAt: time(window.resets_at),
      observedAt: at,
    })
  }
  return windows
}

/** The latest snapshot of each pool and the latest plan the token counts of one scan carried. */
export class RateLimits {
  readonly pools = new Map<string, PoolSnapshot>()
  plan: { at: number; raw: string } | null = null

  /** A token count's `rate_limits` at its time; a snapshot without windows says nothing. */
  note(value: unknown, at: number): void {
    const limits = object(value)
    if (!limits) return
    const id = text(limits.limit_id) ?? DEFAULT_POOL
    // Codex's own pool only: another, such as GPT-5.3-Codex-Spark's, is not shown, and its plan
    // and windows are that model's.
    if (id !== DEFAULT_POOL) return
    const name = id === DEFAULT_POOL ? null : (text(limits.limit_name) ?? id)
    const raw = text(limits.plan_type)
    if (raw && raw !== 'unknown' && (!this.plan || at >= this.plan.at)) this.plan = { at, raw }
    const windows = poolWindows(limits, name, at)
    const known = this.pools.get(id)
    if (windows.length > 0 && (!known || at >= known.at)) this.pools.set(id, { at, name, windows })
  }
}

function restoreState(text: string | null | undefined): CodexQuotaState {
  try {
    const value = text ? (JSON.parse(text) as CodexQuotaState | null) : null
    if (value?.v === STATE_VERSION && object(value.pools)) return value
  } catch {
    // An unreadable state starts over from what the rollouts carry.
  }
  return { v: STATE_VERSION, pools: {}, plan: null }
}

/** The stored state with what a scan met: each pool's and the plan's newer snapshot wins. */
export function mergeRateLimits(stored: string | null, seen: RateLimits): CodexQuotaState {
  const state = restoreState(stored)
  for (const [id, snapshot] of seen.pools) {
    const known = state.pools[id]
    if (!known || snapshot.at >= known.at) state.pools[id] = snapshot
  }
  if (seen.plan && (!state.plan || seen.plan.at >= state.plan.at)) state.plan = seen.plan
  return state
}

/** The reading of a state: Codex's own pool first, then the others by name. */
export function codexReading(state: CodexQuotaState, account: string | null): QuotaReading {
  const pools = Object.entries(state.pools).sort(([a], [b]) =>
    a === DEFAULT_POOL ? -1 : b === DEFAULT_POOL ? 1 : a < b ? -1 : a > b ? 1 : 0,
  )
  const windows = pools.flatMap(([, snapshot]) => snapshot.windows)
  return {
    agentId: AGENT_ID,
    account,
    plan: codexPlan(state.plan?.raw),
    windows,
    observedAt: newest(windows),
  }
}

/**
 * The account of the ChatGPT sign-in in `auth.json`, as a fingerprint of its `account_id`; null
 * on an API key or when the file cannot be read. Nothing else of the file is kept.
 */
export function parseCodexAccount(json: string): string | null {
  try {
    const id = text(object(object(JSON.parse(json))?.tokens)?.account_id)
    return id ? accountFingerprint('codex', id) : null
  } catch {
    return null
  }
}

async function readAccount(folder: string): Promise<string | null> {
  try {
    return parseCodexAccount(await readFile(path.join(folder, 'auth.json'), 'utf8'))
  } catch {
    return null
  }
}

/**
 * Stores Codex's quota: the stored pools with the scan's newer snapshots, and the account now. The
 * stored state is read and written in one step, so a quick read and a scan never undo each other.
 */
export async function storeCodexQuota(
  context: QuotaContext,
  folder: string,
  seen: RateLimits,
): Promise<void> {
  const account = await readAccount(folder)
  const stored = context.storedQuota(AGENT_ID)
  const state = mergeRateLimits(stored?.state ?? null, seen)
  context.quota(codexReading(state, account), JSON.stringify(state))
}

/** How many days of date folders a quick read looks in for the rollouts in use. */
const RECENT_DAYS = 7
/** How many of the most recently written rollouts a quick read takes the end of. */
const RECENT_ROLLOUTS = 3
/** The end of a rollout read for its latest rate limits. */
export const TAIL_BYTES = 256 * 1024

interface RecentRollout {
  file: string
  mark: string
  size: number
  mtimeMs: number
}

const names = async (dir: string): Promise<string[]> => {
  try {
    return await readdir(dir)
  } catch {
    return []
  }
}

/** The plain rollouts of the newest `RECENT_DAYS` date folders, most recently written first. */
async function recentRollouts(root: string): Promise<RecentRollout[]> {
  const sessions = path.join(root, 'sessions')
  const days: string[] = []
  const desc = (list: string[], digits: number): string[] =>
    list
      .filter((name) => name.length === digits && /^\d+$/.test(name))
      .sort((a, b) => (a < b ? 1 : -1))
  for (const year of desc(await names(sessions), 4)) {
    for (const month of desc(await names(path.join(sessions, year)), 2)) {
      for (const day of desc(await names(path.join(sessions, year, month)), 2)) {
        days.push(path.join(sessions, year, month, day))
        if (days.length >= RECENT_DAYS) break
      }
      if (days.length >= RECENT_DAYS) break
    }
    if (days.length >= RECENT_DAYS) break
  }
  const files = (
    await Promise.all(
      days.map(async (dir) =>
        (await names(dir))
          .filter((name) => name.startsWith('rollout-') && name.endsWith('.jsonl'))
          .map((name) => path.join(dir, name)),
      ),
    )
  ).flat()
  const stats = await Promise.all(
    files.map((file) =>
      stat(file).then(
        (info) => (info.isFile() ? info : null),
        () => null,
      ),
    ),
  )
  const out: RecentRollout[] = []
  files.forEach((file, i) => {
    const info = stats[i]
    if (info) {
      out.push({
        file,
        mark: `${info.size}:${info.mtimeMs}`,
        size: info.size,
        mtimeMs: info.mtimeMs,
      })
    }
  })
  return out.sort((a, b) => b.mtimeMs - a.mtimeMs).slice(0, RECENT_ROLLOUTS)
}

/** The rate limits of the token counts in a rollout's last `TAIL_BYTES`. */
export async function noteTail(file: string, size: number, limits: RateLimits): Promise<void> {
  const length = Math.min(size, TAIL_BYTES)
  const handle = await open(file, 'r')
  let text: string
  try {
    const buffer = Buffer.alloc(length)
    const { bytesRead } = await handle.read(buffer, 0, length, size - length)
    text = buffer.subarray(0, bytesRead).toString('utf8')
  } finally {
    await handle.close()
  }
  const lines = text.split('\n')
  // The first line is cut short unless the tail is the whole file, and the last may be unfinished.
  if (length < size) lines.shift()
  for (const line of lines) {
    if (!line.includes('"token_count"') || !line.includes('"rate_limits"')) continue
    let value: Record<string, unknown> | null
    try {
      value = object(JSON.parse(line))
    } catch {
      continue
    }
    const payload = object(value?.payload)
    const at = typeof value?.timestamp === 'string' ? Date.parse(value.timestamp) : NaN
    if (value?.type !== 'event_msg' || payload?.type !== 'token_count' || !Number.isFinite(at)) {
      continue
    }
    limits.note(payload.rate_limits, at)
  }
}

/** Each Codex home's rollouts as they were when their ends were last read. */
const tails = new Map<string, Map<string, string>>()

/**
 * Stores Codex's quota from the ends of the rollouts written most recently, those that changed
 * since they were last read; the scan reads every rollout, this only what is in use.
 */
export async function refreshCodexQuota(context: QuotaContext, root: string): Promise<void> {
  const recent = await recentRollouts(root)
  const read = tails.get(root) ?? new Map<string, string>()
  const changed = recent.filter((rollout) => read.get(rollout.file) !== rollout.mark)
  if (changed.length === 0) return
  const limits = new RateLimits()
  for (const rollout of changed) {
    context.signal.throwIfAborted()
    try {
      await noteTail(rollout.file, rollout.size, limits)
    } catch (error) {
      context.log('warn', `Cannot read the end of ${rollout.file}: ${(error as Error).message}`)
    }
  }
  await storeCodexQuota(context, root, limits)
  tails.set(root, new Map(recent.map((rollout) => [rollout.file, rollout.mark])))
}
