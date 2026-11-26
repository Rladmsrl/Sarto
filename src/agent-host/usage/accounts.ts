// An agent's quota readings from every computer of the sync, by account, as Sarto's Mac app's
// `accountReadings` (UsageEngine.swift): readings of one account stand in for each other, the
// freshest leading; different accounts stay apart, as do readings whose account the agent does
// not name, whatever their numbers. This computer's account comes first.

import type { AgentId } from '@shared/thread'
import type { QuotaReading, QuotaWindow, QuotaWindowKind } from '@shared/usage'
import type {
  OverviewQuota,
  OverviewWindow,
  QuotaHistory,
  QuotaSample,
  WindowForecast,
} from '@shared/usage'
import { hasReset } from './quota'

/** How long another account still shows after the last reading of it. */
export const OTHER_ACCOUNT_MS = 7 * 24 * 3_600_000

/**
 * An account the user removed from the usage views: its readings measured up to `before` are
 * neither shown nor shared, and a later one, once the account is used again, shows as before.
 */
export interface ForgottenAccount {
  agentId: AgentId
  account: string
  before: number
}

/** Whether a reading is of a removed account and measured before it was removed. */
export function isForgotten(
  reading: QuotaReading,
  forgotten: readonly ForgottenAccount[],
): boolean {
  if (reading.account === null) return false
  const at = reading.observedAt ?? 0
  return forgotten.some(
    (f) => f.agentId === reading.agentId && f.account === reading.account && at <= f.before,
  )
}

/** A computer that shares its usage, as the sync names it. */
export interface UsageDeviceRef {
  id: string
  name: string
}

/** One computer's reading; `device` is null for this computer's own. */
export interface DeviceReading {
  device: UsageDeviceRef | null
  reading: QuotaReading
}

/** The readings of one account, freshest first. */
export type AccountGroup = DeviceReading[]

const observed = (item: DeviceReading): number => item.reading.observedAt ?? -Infinity

/**
 * The account groups of one agent's readings: this computer's first, else the freshest; another
 * account read last more than a week ago is left out.
 */
export function accountGroups(
  local: QuotaReading | null,
  remotes: readonly DeviceReading[],
  now: number,
): AccountGroup[] {
  const readings: DeviceReading[] = [
    ...(local ? [{ device: null, reading: local }] : []),
    ...remotes,
  ]
  const groups = new Map<string, DeviceReading[]>()
  for (const item of readings) {
    const key =
      item.reading.account !== null
        ? `account:${item.reading.account}`
        : `device:${item.device?.id ?? ''}`
    const group = groups.get(key)
    if (group) group.push(item)
    else groups.set(key, [item])
  }
  const sorted = [...groups.values()]
    .map((group) => [...group].sort((a, b) => observed(b) - observed(a)))
    .sort((a, b) => {
      const aHere = a.some((item) => item.device === null)
      const bHere = b.some((item) => item.device === null)
      if (aHere !== bHere) return aHere ? -1 : 1
      return observed(b[0]!) - observed(a[0]!)
    })
  const cutoff = now - OTHER_ACCOUNT_MS
  return sorted.filter((group, i) => i === 0 || observed(group[0]!) >= cutoff)
}

/** A group as one reading: the freshest one's windows, with the newest plan any reading names. */
export function mergedReading(group: AccountGroup): QuotaReading {
  const freshest = group[0]!.reading
  return {
    ...freshest,
    plan: group.find((item) => item.reading.plan !== null)?.reading.plan ?? null,
  }
}

/** A window's measurements in a computer's history; none when it has kept none. */
export function samplesOf(
  history: readonly QuotaHistory[],
  agentId: string,
  window: string,
): QuotaSample[] {
  return history.find((h) => h.agentId === agentId && h.window === window)?.samples ?? []
}

const ORDER: Record<QuotaWindowKind, number> = { session: 0, weekly: 1, other: 2, scoped: 3 }

/**
 * A group's reading ready to show: windows past their reset time at 0% with no reset time, sorted
 * session, weekly, other, scoped; the tube's window is the plan-wide one with the least left.
 */
export function overviewQuota(
  reading: QuotaReading,
  device: UsageDeviceRef | null,
  forecasts: Readonly<Record<string, WindowForecast>>,
  label: (window: QuotaWindow) => string,
  now: number,
): OverviewQuota {
  const windows: OverviewWindow[] = reading.windows
    .map((window, index) => ({ window, index }))
    .sort((a, b) => ORDER[a.window.kind] - ORDER[b.window.kind] || a.index - b.index)
    .map(({ window }) => {
      const reset = hasReset(window, now)
      const usedPercent = reset ? 0 : window.usedPercent
      return {
        id: window.id,
        kind: window.kind,
        scope: window.scope,
        label: label(window),
        minutes: window.minutes,
        usedPercent,
        remaining: Math.max(0, Math.min(1, 1 - usedPercent / 100)),
        resetsAt: reset ? null : window.resetsAt,
        reset,
        observedAt: window.observedAt,
        forecast: forecasts[window.id] ?? {
          status: { kind: reset ? 'reset' : 'insufficient' },
          estimatedRemainingTokens: null,
          windowTokens: 0,
        },
        ...(window.amount && !reset ? { amount: window.amount } : {}),
      }
    })
  const general = windows.filter((window) => window.kind !== 'scoped')
  const primary = general.reduce<OverviewWindow | null>(
    (least, window) => (least === null || window.remaining < least.remaining ? window : least),
    null,
  )
  const secondary = general.find((window) => window !== primary) ?? null
  return {
    account: reading.account,
    plan: reading.plan,
    observedAt: reading.observedAt,
    device,
    windows,
    primary: primary?.id ?? null,
    secondary: secondary?.id ?? null,
  }
}
