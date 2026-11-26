// What another computer's usage record carries beside its buckets: its quota readings, their
// measurements and its latest requests. They come from the account's other computers through the
// encrypted sync, and are checked field by field all the same, so a damaged or newer record
// leaves out what does not fit instead of failing the overview.

import type { SyncedHostUsageSection } from '@shared/sync/protocol'
import type { AgentId } from '@shared/thread'
import type {
  AgentActivity,
  QuotaAmount,
  QuotaHistory,
  QuotaReading,
  QuotaSample,
  QuotaWindow,
  QuotaWindowKind,
} from '@shared/usage'
import { HISTORY_MS } from './quota'

/** What another computer shares beside its buckets, kept in memory while the host runs. */
export interface RemoteQuotas {
  name: string
  updatedAt: number
  quotas: QuotaReading[]
  history: QuotaHistory[]
  activity: AgentActivity[]
}

const MAX_READINGS = 64
const MAX_WINDOWS = 32
const MAX_LISTS = 256
const MAX_SAMPLES = 48
const KINDS: ReadonlySet<string> = new Set(['session', 'weekly', 'scoped', 'other'])

type Json = Record<string, unknown>

const object = (value: unknown): Json | null =>
  typeof value === 'object' && value !== null && !Array.isArray(value) ? (value as Json) : null

const text = (value: unknown, max: number): string | null =>
  typeof value === 'string' && value.length > 0 && value.length <= max ? value : null

const time = (value: unknown): number | null =>
  typeof value === 'number' && Number.isFinite(value) && value >= 0 ? value : null

const list = (value: unknown, max: number): unknown[] =>
  Array.isArray(value) ? value.slice(0, max) : []

const percent = (value: unknown): number | null =>
  typeof value === 'number' && Number.isFinite(value) ? Math.max(0, Math.min(100, value)) : null

function windowOf(value: unknown): QuotaWindow | null {
  const o = object(value)
  const id = text(o?.id, 200)
  const used = percent(o?.usedPercent)
  if (!o || !id || used === null || typeof o.kind !== 'string' || !KINDS.has(o.kind)) return null
  const minutes = time(o.minutes)
  const amount = amountOf(o.amount)
  return {
    id,
    kind: o.kind as QuotaWindowKind,
    scope: text(o.scope, 200),
    minutes: minutes !== null && minutes > 0 ? minutes : null,
    usedPercent: used,
    resetsAt: time(o.resetsAt),
    observedAt: time(o.observedAt),
    ...(amount ? { amount } : {}),
  }
}

function amountOf(value: unknown): QuotaAmount | null {
  const o = object(value)
  const used = time(o?.used)
  const total = time(o?.total)
  const unit = text(o?.unit, 20)
  return used !== null && total !== null && total > 0 && unit ? { used, total, unit } : null
}

export function readingOf(value: unknown): QuotaReading | null {
  const o = object(value)
  const agentId = text(o?.agentId, 100)
  if (!o || !agentId) return null
  const windows = list(o.windows, MAX_WINDOWS)
    .map(windowOf)
    .filter((window) => window !== null)
  return {
    agentId: agentId as AgentId,
    account: text(o.account, 64),
    plan: text(o.plan, 100),
    windows,
    observedAt: time(o.observedAt),
  }
}

function historyOf(value: unknown, now: number): QuotaHistory | null {
  const o = object(value)
  const agentId = text(o?.agentId, 100)
  const window = text(o?.window, 200)
  if (!o || !agentId || !window) return null
  const samples: QuotaSample[] = []
  for (const item of list(o.samples, MAX_SAMPLES)) {
    const s = object(item)
    const at = time(s?.at)
    const used = percent(s?.usedPercent)
    if (!s || at === null || used === null || now - at > HISTORY_MS) continue
    samples.push({ at, usedPercent: used, resetsAt: time(s.resetsAt) })
  }
  return samples.length > 0 ? { agentId: agentId as AgentId, window, samples } : null
}

function activityOf(value: unknown): AgentActivity | null {
  const o = object(value)
  const agentId = text(o?.agentId, 100)
  const at = time(o?.at)
  if (!o || !agentId || at === null) return null
  return { agentId: agentId as AgentId, at, model: text(o.model, 200) }
}

/** The quota part of another computer's usage section, what of it fits. */
export function syncedQuotas(
  deviceId: string,
  section: SyncedHostUsageSection,
  now: number,
): RemoteQuotas {
  const o = object(section) ?? {}
  return {
    name: text(o.deviceName, 200) ?? deviceId,
    updatedAt: time(o.updatedAt) ?? 0,
    quotas: list(o.quotas, MAX_READINGS)
      .map(readingOf)
      .filter((reading) => reading !== null),
    history: list(o.quotaHistory, MAX_LISTS)
      .map((item) => historyOf(item, now))
      .filter((history) => history !== null),
    activity: list(o.activity, MAX_READINGS)
      .map(activityOf)
      .filter((activity) => activity !== null),
  }
}

/** Other Macs' usage after an update that names them all in `present` and carries the changed. */
export function mergeRemoteUsage(
  current: Record<string, SyncedHostUsageSection>,
  changed: Record<string, SyncedHostUsageSection>,
  present: readonly string[],
): Record<string, SyncedHostUsageSection> {
  const next: Record<string, SyncedHostUsageSection> = {}
  for (const deviceId of present) {
    const section = changed[deviceId] ?? current[deviceId]
    if (section) next[deviceId] = section
  }
  return next
}
