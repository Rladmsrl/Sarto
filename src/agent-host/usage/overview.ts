// The usage overview, assembled from what the usage worker answers: every figure the Mac app's
// usage views show, so a computer without the app (a daemon on Linux) has them all, and the app
// computes nothing.

import type { SyncedUsageSelf } from '@shared/sync/protocol'
import { sortAgentIds, type AgentId, type HarnessId } from '@shared/thread'
import {
  ELIGIBLE_DAYS,
  partsTotal,
  type AgentActivity,
  type DayUsage,
  type ModelUsage,
  type OverviewActivity,
  type OverviewAgent,
  type OverviewModel,
  type QuotaWindow,
  type UsageDevice,
  type UsageOverview,
  type UsageScope,
  type UsageSeries,
} from '@shared/usage'
import { overviewQuota } from './accounts'
import type { OverviewAnswer } from './db'

const HOUR_MS = 3_600_000

/** n + 1 local midnights in the host's time zone: the last n days, today last, then tomorrow's. */
export function localDayStarts(now: number, days: number): number[] {
  const today = new Date(now)
  today.setHours(0, 0, 0, 0)
  const out: number[] = []
  for (let back = days - 1; back >= -1; back--) {
    const day = new Date(today)
    day.setDate(day.getDate() - back)
    out.push(day.getTime())
  }
  return out
}

/** n + 1 hour boundaries: the last n hours, the current one last, then the next's start. */
export function hourStarts(now: number, hours: number): number[] {
  const current = Math.floor(now / HOUR_MS) * HOUR_MS
  return Array.from({ length: hours + 1 }, (_, i) => current - (hours - 1 - i) * HOUR_MS)
}

export interface OverviewInput {
  answer: OverviewAnswer
  scope: UsageScope
  now: number
  dayStarts: readonly number[]
  hourStarts: readonly number[]
  /** This computer in the sync; null while the sync is off. */
  self: SyncedUsageSelf | null
  /** Agents whose logs or record this computer has, whatever the scope counts. */
  local: ReadonlySet<AgentId>
  /** Agents signed out on this computer. */
  signedOut: ReadonlySet<AgentId>
  /** The agents this host knows; null when they could not be listed, so none counts as missing. */
  agents?: readonly UsageAgentInfo[] | null
  label(window: QuotaWindow): string
}

/** An agent as the agents list it, for the overview's names and which quotas it shows. */
export interface UsageAgentInfo {
  id: AgentId
  name: string
  harnessId: HarnessId
  /** Its program or adapter is on this computer. */
  installed: boolean
}

const DAY_MS = 24 * HOUR_MS

function series(rows: readonly DayUsage[], starts: readonly number[]): UsageSeries {
  const periods = Math.max(0, starts.length - 1)
  const agents = new Map<AgentId, { agentId: AgentId; tokens: number[]; cost: number[] }>()
  for (const row of rows) {
    if (row.day < 0 || row.day >= periods) continue
    let line = agents.get(row.agentId)
    if (!line) {
      line = {
        agentId: row.agentId,
        tokens: new Array<number>(periods).fill(0),
        cost: new Array<number>(periods).fill(0),
      }
      agents.set(row.agentId, line)
    }
    line.tokens[row.day]! += partsTotal(row)
    line.cost[row.day]! += row.cost ?? 0
  }
  const order = sortAgentIds(agents.keys())
  return { starts: starts.slice(0, periods), agents: order.map((id) => agents.get(id)!) }
}

function rankedModels(models: readonly ModelUsage[]): OverviewModel[] {
  return models
    .map((m) => ({
      agentId: m.agentId,
      model: m.model,
      tokens: partsTotal(m),
      cost: m.cost ?? 0,
      requests: m.requests,
      price: m.price ?? { kind: 'unpriced' as const, model: null, origin: null },
    }))
    .sort((a, b) => b.cost - a.cost || b.tokens - a.tokens)
}

const activityOf = (activity: AgentActivity | undefined): OverviewActivity | null =>
  activity ? { at: activity.at, model: activity.model } : null

export function assembleOverview(input: OverviewInput): UsageOverview {
  const { answer, scope, now } = input
  const all = scope === 'all'
  const today = new Map(answer.today.map((row) => [row.agentId, row]))
  const local = new Map(answer.localActivity.map((a) => [a.agentId, a]))
  const remote = new Map(answer.remoteActivity.map((a) => [a.agentId, a]))
  const quotas = new Map(answer.quotas.map((q) => [q.agentId, q.groups]))
  const models = answer.models.map(({ days, models: list }) => ({
    days,
    models: rankedModels(list),
  }))

  const ids = new Set<AgentId>([...today.keys(), ...local.keys(), ...input.local])
  for (const range of answer.models) for (const m of range.models) ids.add(m.agentId)
  for (const row of answer.daily) ids.add(row.agentId)
  for (const [agentId, groups] of quotas) {
    if (all || groups[0]?.here) ids.add(agentId)
  }
  if (all) for (const agentId of remote.keys()) ids.add(agentId)

  const known = new Map((input.agents ?? []).map((agent) => [agent.id, agent]))
  const since = now - ELIGIBLE_DAYS * DAY_MS
  const firstRecent = Math.max(0, input.dayStarts.length - 1 - ELIGIBLE_DAYS)
  const usedRecently = new Set<AgentId>()
  for (const row of answer.daily) {
    if (row.day >= firstRecent && (partsTotal(row) > 0 || (row.cost ?? 0) > 0)) {
      usedRecently.add(row.agentId)
    }
  }

  const agents: OverviewAgent[] = sortAgentIds(ids).map((agentId) => {
    const sums = today.get(agentId)
    const mine = local.get(agentId)
    const theirs = all ? remote.get(agentId) : undefined
    const newest = theirs && (!mine || theirs.at > mine.at) ? theirs : mine
    const groups = quotas.get(agentId) ?? []
    const primary = all ? groups[0] : groups[0]?.here ? groups[0] : undefined
    const others = all ? groups.slice(1) : []
    const quota = (group: (typeof groups)[number]) =>
      overviewQuota(group.reading, group.device, group.forecasts, input.label, now)
    const shown = primary ? quota(primary) : null
    const signedOut = input.signedOut.has(agentId)
    const info = known.get(agentId)
    const installed =
      (input.agents ? info?.installed === true : true) || (all && shown?.device != null)
    const used =
      usedRecently.has(agentId) ||
      (newest?.at ?? 0) >= since ||
      (shown?.windows.some((w) => w.usedPercent > 0) ?? false)
    const measured =
      shown !== null && shown.windows.length > 0 && !(signedOut && shown.device === null)
    return {
      agentId,
      available: input.local.has(agentId) || quotas.has(agentId) || remote.has(agentId),
      today: {
        tokens: sums ? partsTotal(sums) : 0,
        cost: sums?.cost ?? 0,
        requests: sums?.requests ?? 0,
        unpricedTokens: sums?.unpricedTokens ?? 0,
      },
      activity: activityOf(newest),
      localActivity: activityOf(mine),
      quota: shown,
      otherAccounts: others.map(quota),
      signedOut,
      ...(info ? { name: info.name, harnessId: info.harnessId } : {}),
      eligible: installed && used && measured,
    }
  })

  const devices: UsageDevice[] = input.self
    ? [
        {
          id: input.self.deviceId,
          name: input.self.deviceName,
          updatedAt: input.self.updatedAt,
          thisComputer: true,
        },
        ...answer.devices
          .map((d) => ({ id: d.id, name: d.name, updatedAt: d.updatedAt, thisComputer: false }))
          .sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true })),
      ]
    : []

  const quarter = models.find((range) => range.days === 90)?.models ?? []
  const unpriced = new Set<string>()
  const family = new Map<string, string>()
  for (const m of quarter) {
    if (m.price.kind === 'unpriced') unpriced.add(m.model)
    else if (m.price.kind === 'family' && m.price.model) family.set(m.model, m.price.model)
  }

  return {
    generatedAt: now,
    scope,
    agents,
    models,
    hourly: series(answer.hourly, input.hourStarts),
    daily: series(answer.daily, input.dayStarts),
    devices,
    unpricedModels: [...unpriced].sort(),
    familyPriced: [...family]
      .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
      .map(([model, standIn]) => ({ model, standIn })),
    pricesAsOf: answer.pricesAsOf,
  }
}
