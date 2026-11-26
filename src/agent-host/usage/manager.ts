// Usage in the host: writes Sarto's record, schedules the log scans while Usage on this
// computer is on, picks the source each agent counts from, and answers the page.

import type { PlanLimit } from '@shared/agent-host'
import { harnessOf } from '@shared/agents'
import type { Platform } from '@shared/platform'
import type {
  SyncedAgentPlanReading,
  SyncedHostUsageSection,
  SyncedUsageSelf,
} from '@shared/sync/protocol'
import { sortAgentIds, type AgentId } from '@shared/thread'
import {
  partsTotal,
  type ClockRequest,
  type ScanProgress,
  type UsageLogStatus,
  type UsageOverview,
  type UsageScope,
  type UsageStatus,
  type UsageSummary,
  type ProjectUsage,
  type UsageTotal,
} from '@shared/usage'
import type { LogFn } from '../storage'
import { isForgotten, type ForgottenAccount } from './accounts'
import type { SourceMap, SourceStats, UsageDbStatus } from './db'
import { forget, type ForgottenStore } from './forgotten'
import { windowLabel } from './labels'
import type { LogReader, UsageRow } from './model'
import { assembleOverview, hourStarts, localDayStarts, type UsageAgentInfo } from './overview'
import bundledPrices from './prices.json'
import type { QuotaAnswer, ScanResult } from './protocol'
import { limitsReading } from './quota'
import type { UsageStore } from './store'
import { mergeRemoteUsage, syncedQuotas } from './synced'

export interface UsageTimings {
  /** After launch, how long the first scan waits for startup to settle. */
  firstScanMs: number
  intervalMs: number
  /** How often the agents' quota files are looked at between scans. */
  quotaMs: number
  /**
   * How often the live plan limits of agents whose quota no file holds (Antigravity's `agy
   * /usage`) are read, unless another computer read the same account more recently.
   */
  planMs: number
}

const TIMINGS: UsageTimings = {
  firstScanMs: 8_000,
  intervalMs: 10 * 60_000,
  quotaMs: 45_000,
  planMs: 5 * 60_000,
}

/** An agent's live plan, as the agents report it. */
export interface AgentPlan {
  tier?: string
  limits: PlanLimit[]
  /** The agent is signed out, so its limits are not read. */
  signedOut?: boolean
  /** The account's fingerprint, as `accountFingerprint` makes it; absent when none is known. */
  account?: string | null
  /**
   * Whether its limits are read without the agent running (a stored sign-in, agy's print mode),
   * so they are read again on the plan timer; the others' come with the agent's own reads.
   */
  idle?: boolean
}

const unusable = (status: UsageDbStatus) => status === 'unavailable' || status === 'newer'

export interface UsageManagerDeps {
  store: UsageStore | null
  readers: readonly LogReader[]
  fromComputer: boolean
  platform: Platform
  home: string
  /** The agent's own resolved environment, once it is ready. */
  env(agentId: AgentId): Promise<Record<string, string | undefined>>
  /** Whether a folder is one of Sarto's No project folders. */
  isScratch(path: string): boolean
  /** The project a session's worktree belongs to, so its usage counts there; null for others. */
  worktreeProject?(path: string): string | null
  /**
   * The agents' live plan limits and plan, which the quota of every agent whose files hold none
   * comes from (Antigravity's, Cursor's): they join the readings from the agents' files, and the
   * fresher measurement of a window wins.
   */
  plans?(): Promise<Partial<Record<AgentId, AgentPlan>>>
  /** Reads an agent's live plan limits again, as `plans` lists them; it starts no browser. */
  refreshPlan?(agentId: AgentId): Promise<void>
  /** The agents this host knows, installed or not. */
  agents?(): Promise<UsageAgentInfo[]>
  log: LogFn
  changed(source?: 'local' | 'remote'): void
  status(status: UsageStatus): void
  /** Where the accounts removed from the usage views are kept; none keeps them in memory. */
  forgotten?: ForgottenStore | null
  now?: () => number
  timings?: Partial<UsageTimings>
}

interface LogState {
  found: boolean | null
  syncedAt: number | null
  error: string | null
}

export class UsageManager {
  private fromComputer: boolean
  private readonly timings: UsageTimings
  private readonly now: () => number
  private progress: ScanProgress | null = null
  private readonly logs = new Map<AgentId, LogState>()
  private stats: SourceStats[] = []
  private remoteStatsCache: Array<{ agentId: AgentId; rows: number; first: number; last: number }> =
    []
  private unavailable = false
  private firstTimer: ReturnType<typeof setTimeout> | null = null
  private interval: ReturnType<typeof setInterval> | null = null
  private quotaTimer: ReturnType<typeof setInterval> | null = null
  private planTimer: ReturnType<typeof setInterval> | null = null
  /** The quick quota read or the plan read running, which a timer firing meanwhile joins. */
  private quotaRun: Promise<void> | null = null
  private planRun: Promise<void> | null = null
  /** Other computers' usage sections, by usage device id, and this computer in the sync. */
  private remote: Record<string, SyncedHostUsageSection> = {}
  private self: SyncedUsageSelf | null = null
  /** The scan that runs or is queued last; it resolves with its error, if it failed. */
  private scanning: Promise<Error | null> | null = null
  /** Turning the setting off cancelled `scanning`, so a full scan follows it instead of joining. */
  private scanCancelled = false
  private stopped = false
  /** The environments the locations are shown with, by agent; the readers see the same ones. */
  private envs: Partial<Record<AgentId, Record<string, string | undefined>>> = {}
  /** The accounts removed from the usage views, once read from their file. */
  private forgotten: ForgottenAccount[] = []
  private forgottenRead: Promise<void> | null = null

  constructor(private readonly deps: UsageManagerDeps) {
    this.fromComputer = deps.fromComputer
    this.timings = { ...TIMINGS, ...deps.timings }
    this.now = deps.now ?? Date.now
    for (const reader of deps.readers) {
      this.logs.set(reader.agentId, { found: null, syncedAt: null, error: null })
    }
  }

  /** Reads the stored figures, then scans once startup has settled and every interval after. */
  start(): void {
    const { store } = this.deps
    if (!store) {
      this.unavailable = true
      return
    }
    void store.ready.then((status) => {
      this.unavailable = unusable(status)
      void this.refreshStats()
    })
    void this.readEnvs(this.deps.readers.map((r) => r.agentId)).then(() => this.publish())
    this.firstTimer = setTimeout(() => {
      this.firstTimer = null
      void this.scan()
      void this.refreshPlans()
    }, this.timings.firstScanMs)
    this.interval = setInterval(() => void this.scan(), this.timings.intervalMs)
    this.interval.unref?.()
    this.quotaTimer = setInterval(() => void this.refreshQuotas(), this.timings.quotaMs)
    this.quotaTimer.unref?.()
    this.planTimer = setInterval(() => void this.refreshPlans(), this.timings.planMs)
    this.planTimer.unref?.()
  }

  /** Stops the timers and any scan, and closes the database. */
  async close(): Promise<void> {
    this.stop()
    await this.deps.forgotten?.flush()
    await this.deps.store?.close()
  }

  /** The removed accounts, read from their file the first time they are needed. */
  private readForgotten(): Promise<void> {
    this.forgottenRead ??= (async () => {
      try {
        const file = await this.deps.forgotten?.load()
        if (file) this.forgotten = file.accounts
      } catch (error) {
        this.deps.log('warn', `Could not read the removed accounts: ${(error as Error).message}`)
      }
    })()
    return this.forgottenRead
  }

  /**
   * Removes an account from the usage views and from what this computer shares: its readings
   * measured until now no longer show, here or on the other computers, until it is used again.
   */
  async forgetAccount(agentId: AgentId, account: string): Promise<void> {
    await this.readForgotten()
    this.forgotten = forget(this.forgotten, agentId, account, this.now())
    this.deps.forgotten?.save({ accounts: this.forgotten })
    this.deps.changed()
  }

  stop(): void {
    this.stopped = true
    if (this.firstTimer) clearTimeout(this.firstTimer)
    if (this.interval) clearInterval(this.interval)
    if (this.quotaTimer) clearInterval(this.quotaTimer)
    if (this.planTimer) clearInterval(this.planTimer)
    this.firstTimer = null
    this.interval = null
    this.quotaTimer = null
    this.planTimer = null
  }

  /**
   * Reads the agents' quota files alone, between the scans: what changed of `.claude.json`, the
   * ends of Codex's newest rollouts. Nothing while Usage on this computer is off.
   */
  refreshQuotas(): Promise<void> {
    const { store } = this.deps
    if (!store || !this.fromComputer || this.stopped || this.unavailable) return Promise.resolve()
    this.quotaRun ??= (async () => {
      const agents = this.deps.readers.filter((r) => r.quota).map((r) => r.agentId)
      const envs = await this.readEnvs(agents)
      await store.refreshQuotas({
        agents,
        envs,
        home: this.deps.home,
        platform: this.deps.platform,
      })
    })()
      .catch((error: unknown) => {
        this.deps.log('warn', `The quick quota read failed: ${(error as Error).message}`)
      })
      .finally(() => {
        this.quotaRun = null
      })
    return this.quotaRun
  }

  /**
   * Reads again the live plan limits of the agents `plans` lists, such as Antigravity's, whose
   * quota no file holds; an agent whose account another computer read within `planMs` is left,
   * since the quota is the account's. Nothing while Usage on this computer is off.
   */
  refreshPlans(): Promise<void> {
    const { store, refreshPlan, plans } = this.deps
    if (!store || !refreshPlan || !plans || !this.fromComputer || this.stopped) {
      return Promise.resolve()
    }
    this.planRun ??= (async () => {
      const agents = (Object.entries(await plans()) as [AgentId, AgentPlan][])
        .filter(([, plan]) => plan.idle !== false)
        .map(([id]) => id)
      if (agents.length === 0) return
      const { readings } = await store.quotas({})
      const now = this.now()
      for (const agentId of agents) {
        const account = readings.find((r) => r.agentId === agentId)?.account ?? null
        if (account !== null && this.readElsewhere(agentId, account, now)) continue
        await refreshPlan(agentId).catch((error: unknown) => {
          this.deps.log(
            'warn',
            `Could not read ${agentId}'s plan limits: ${(error as Error).message}`,
          )
        })
      }
    })()
      .catch((error: unknown) => {
        this.deps.log('warn', `The plan limits read failed: ${(error as Error).message}`)
      })
      .finally(() => {
        this.planRun = null
      })
    return this.planRun
  }

  /** Whether another computer measured this account's quota of the agent within `planMs`. */
  private readElsewhere(agentId: AgentId, account: string, now: number): boolean {
    for (const [deviceId, section] of Object.entries(this.remote)) {
      const reading = syncedQuotas(deviceId, section, now).quotas.find(
        (r) => harnessOf(r.agentId) === harnessOf(agentId) && r.account === account,
      )
      if (reading?.observedAt != null && now - reading.observedAt < this.timings.planMs) {
        return true
      }
    }
    return false
  }

  /** The setting changed: turning it on starts the first import, off stops a scan. */
  setFromComputer(on: boolean): void {
    if (on === this.fromComputer) return
    this.fromComputer = on
    if (on) void this.scan()
    else {
      if (this.scanning) this.scanCancelled = true
      void this.deps.store?.cancel().catch(() => {})
    }
    this.publish()
    this.deps.changed()
  }

  /** Adds Sarto's rows for a turn; a failure is logged and the turn goes on. */
  record(rows: UsageRow[]): void {
    if (rows.length === 0 || !this.deps.store) return
    this.deps.store
      .write(rows)
      .catch((error: unknown) =>
        this.deps.log('warn', `Could not record a turn's usage: ${(error as Error).message}`),
      )
  }

  /** Reads what is new in the logs; one scan at a time, and nothing while the setting is off. */
  async sync(): Promise<void> {
    const error = await this.scan()
    if (error) throw error
  }

  /** Reads what is new in these agents' logs, after any scan that runs; a failure is logged. */
  async syncAgents(agentIds: AgentId[]): Promise<void> {
    const agents = agentIds.filter((id) => this.deps.readers.some((r) => r.agentId === id))
    if (agents.length > 0) await this.scan(agents)
  }

  /** A failure is logged, and the promise resolves with it for the callers that report it. */
  private scan(agents?: AgentId[]): Promise<Error | null> {
    const { store } = this.deps
    if (!store || !this.fromComputer || this.stopped || this.unavailable) {
      return this.scanning ?? Promise.resolve(null)
    }
    // A full scan asked for while one runs joins it; a scan of chosen agents follows it.
    if (this.scanning && !agents && !this.scanCancelled) return this.scanning
    this.scanCancelled = false
    const run = (this.scanning ?? Promise.resolve(null))
      .then(async () => {
        // The setting may have been turned off while this scan waited for the one before.
        if (!this.fromComputer || this.stopped) return null
        const scanned = agents ?? this.deps.readers.map((r) => r.agentId)
        const envs = await this.readEnvs(scanned)
        const outcome = await store.scan({
          agents: scanned,
          envs,
          home: this.deps.home,
          platform: this.deps.platform,
        })
        this.applyResults(outcome.results)
        await this.refreshStats()
        return null
      })
      .catch((error: unknown) => {
        this.deps.log('warn', `The usage scan failed: ${(error as Error).message}`)
        return error as Error
      })
    const tracked: Promise<Error | null> = run.finally(() => {
      if (this.scanning !== tracked) return
      this.scanning = null
      this.scanCancelled = false
    })
    this.scanning = tracked
    return tracked
  }

  private async readEnvs(
    agents: AgentId[],
  ): Promise<Partial<Record<AgentId, Record<string, string | undefined>>>> {
    const read = await Promise.all(agents.map(async (id) => [id, await this.deps.env(id)] as const))
    const envs = Object.fromEntries(read) as Partial<
      Record<AgentId, Record<string, string | undefined>>
    >
    Object.assign(this.envs, envs)
    return envs
  }

  private applyResults(results: ScanResult[]): void {
    const at = this.now()
    for (const result of results) {
      this.logs.set(result.agentId, { found: result.found, syncedAt: at, error: result.error })
    }
  }

  /** Forgets an agent's imported history and reads its logs again. */
  async reimport(agentId: AgentId): Promise<void> {
    const { store } = this.deps
    if (!store || !this.deps.readers.some((r) => r.agentId === agentId)) return
    await store.removeLogs(agentId)
    this.logs.set(agentId, { found: null, syncedAt: null, error: null })
    await this.refreshStats()
    this.deps.changed()
    const error = await this.scan([agentId])
    if (error) throw error
  }

  async clearRecord(): Promise<void> {
    await this.deps.store?.clearRecord()
    await this.refreshStats()
    this.deps.changed()
  }

  /** The store restarted its worker, or stopped trying; the page reads again either way. */
  storeStatus(status: UsageDbStatus): void {
    this.unavailable = unusable(status)
    void this.refreshStats().then(() => this.deps.changed())
  }

  /** The store wrote rows; the page reads again, once the first days and counts are current. */
  rowsChanged(): void {
    void this.refreshStats().then(() => this.deps.changed())
  }

  progressed(progress: ScanProgress | null): void {
    this.progress = progress
    this.publish()
  }

  private async refreshStats(): Promise<void> {
    const { store } = this.deps
    if (!store) return
    try {
      const [local, remote] = await Promise.all([store.stats(), store.remoteStats()])
      this.stats = local
      this.remoteStatsCache = remote
    } catch {
      // The database is not open; the status says so.
    }
    this.publish()
  }

  /**
   * Exports this Mac's quarter-hour usage buckets, agent plan readings, quota readings with their
   * measurements, and latest requests for E2EE sync.
   */
  async exportHostUsage(
    plans?: Partial<Record<AgentId, SyncedAgentPlanReading>>,
  ): Promise<SyncedHostUsageSection | null> {
    const { store } = this.deps
    if (!store || this.unavailable) return null
    const sources = this.sources('computer')
    const [buckets, quotas] = await Promise.all([
      store.exportBuckets(),
      this.quotas(store, sources),
    ])
    return {
      updatedAt: this.now(),
      fromComputer: this.fromComputer,
      computerSources: sources,
      buckets,
      ...(plans && Object.keys(plans).length > 0 ? { plans } : {}),
      ...(quotas
        ? { quotas: quotas.readings, quotaHistory: quotas.history, activity: quotas.activity }
        : {}),
    }
  }

  /**
   * Replaces remote Macs' synced usage, which `usage.summary` `'all'` scope and the overview
   * count, and this Mac as the sync names it (null while the sync is off).
   */
  async setRemoteUsage(
    devices: Record<string, SyncedHostUsageSection>,
    self: SyncedUsageSelf | null = null,
    present?: readonly string[],
  ): Promise<void> {
    this.remote = present ? mergeRemoteUsage(this.remote, devices, present) : devices
    this.self = self
    const { store } = this.deps
    if (!store || this.unavailable) return
    await store.setRemoteUsage(devices, present)
    await this.refreshStats()
    this.deps.changed('remote')
  }

  /**
   * Everything the Mac app's usage views show, under a scope: each agent's figures today, latest
   * requests, account quotas with their forecasts, the ranked models, the hourly and daily series
   * and the computers of the sync.
   */
  async overview(scope: UsageScope): Promise<UsageOverview> {
    const now = this.now()
    const dayStarts = localDayStarts(now, 90)
    const hours = hourStarts(now, 24)
    const { store } = this.deps
    const [plans, known] = await Promise.all([
      this.readPlans(),
      this.readAgents(),
      this.readForgotten(),
    ])
    const local = new Set<AgentId>(
      this.agentsWithUsage(false).concat(
        [...this.logs].filter(([, state]) => state.found === true).map(([id]) => id),
      ),
    )
    const signedOut = new Set(
      (Object.entries(plans) as [AgentId, AgentPlan][])
        .filter(([, plan]) => plan.signedOut === true)
        .map(([id]) => id),
    )
    const answer =
      store && !this.unavailable
        ? await this.storePlans(store, plans).then(() =>
            store.overview({
              sources: this.sources(scope),
              computers: this.sources('computer'),
              includeRemote: scope === 'all',
              dayStarts,
              hourStarts: hours,
              now,
              forgotten: this.forgotten,
            }),
          )
        : {
            today: [],
            models: [],
            daily: [],
            hourly: [],
            localActivity: [],
            remoteActivity: [],
            quotas: [],
            devices: [],
            pricesAsOf: bundledPrices.asOf,
          }
    return assembleOverview({
      answer,
      scope,
      now,
      dayStarts,
      hourStarts: hours,
      self: this.self,
      local,
      signedOut,
      agents: known,
      label: windowLabel,
    })
  }

  private async readAgents(): Promise<UsageAgentInfo[] | null> {
    if (!this.deps.agents) return null
    try {
      return await this.deps.agents()
    } catch (error) {
      this.deps.log('warn', `Could not list the agents: ${(error as Error).message}`)
      return null
    }
  }

  private publish(): void {
    if (!this.stopped) this.deps.status(this.status())
  }

  /** The source each agent counts from in a scope. */
  sources(scope: UsageScope): SourceMap {
    const map: SourceMap = {}
    // Every agent with usage, removed and added ones too, and those whose logs are read.
    const agentIds = new Set<AgentId>([...this.stats.map((s) => s.agentId), ...this.logs.keys()])
    for (const agentId of agentIds) {
      map[agentId] = scope !== 'sarto' && this.countsLogs(agentId) ? 'log' : 'sarto'
    }
    return map
  }

  private countsLogs(agentId: AgentId): boolean {
    if (!this.fromComputer) return false
    const state = this.logs.get(agentId)
    if (!state) return false
    // Before this run's first scan, logs imported earlier still count.
    if (state.found === null) {
      return this.stats.some((s) => s.agentId === agentId && s.source === 'log')
    }
    return state.found
  }

  async summary(
    dayStarts: number[],
    from: number,
    to: number,
    scope: UsageScope,
    clock?: ClockRequest,
  ): Promise<UsageSummary> {
    const includeRemote = scope === 'all'
    const sources = this.sources(scope)
    const { store } = this.deps
    let first = this.stats
      .filter((s) => sources[s.agentId] === s.source)
      .reduce<number | null>((min, s) => (min === null || s.first < min ? s.first : min), null)
    if (includeRemote) {
      for (const s of this.remoteStatsCache) {
        if (first === null || s.first < first) first = s.first
      }
    }
    const agents = this.agentsWithUsage(includeRemote)
    if (!store || this.unavailable) {
      return {
        days: [],
        clock: [],
        models: [],
        projects: [],
        sources,
        first,
        agents,
        pricesAsOf: bundledPrices.asOf,
      }
    }
    const [summary, quotas] = await Promise.all([
      store.summary(dayStarts, from, to, sources, clock, includeRemote),
      this.quotas(store, this.sources('computer')),
    ])
    const projects = mergeProjects(
      summary.projects.map((p) => ({
        ...p,
        project: (p.project !== null && this.deps.worktreeProject?.(p.project)) || p.project,
        scratch: p.project !== null && this.deps.isScratch(p.project),
      })),
    )
    return {
      ...summary,
      projects,
      sources,
      first,
      agents,
      ...(quotas
        ? { quotas: quotas.readings, quotaHistory: quotas.history, activity: quotas.activity }
        : {}),
    }
  }

  /**
   * This computer's quota readings, the agents' live limits stored with them first, and each
   * counted agent's latest request; null when they cannot be read, so the figures still show.
   */
  private async quotas(store: UsageStore, sources: SourceMap): Promise<QuotaAnswer | null> {
    try {
      const [plans] = await Promise.all([this.readPlans(), this.readForgotten()])
      await this.storePlans(store, plans)
      const answer = await store.quotas(sources)
      return {
        ...answer,
        readings: answer.readings.filter((reading) => !isForgotten(reading, this.forgotten)),
      }
    } catch (error) {
      this.deps.log('warn', `Could not read the plan quotas: ${(error as Error).message}`)
      return null
    }
  }

  private async readPlans(): Promise<Partial<Record<AgentId, AgentPlan>>> {
    try {
      return (await this.deps.plans?.()) ?? {}
    } catch (error) {
      this.deps.log('warn', `Could not read the agents' plans: ${(error as Error).message}`)
      return {}
    }
  }

  /** Stores the agents' live plan limits as readings of the agent origin. */
  private async storePlans(
    store: UsageStore,
    plans: Partial<Record<AgentId, AgentPlan>>,
  ): Promise<void> {
    const readings = (Object.entries(plans) as [AgentId, AgentPlan][])
      .map(([agentId, plan]) => limitsReading(agentId, plan))
      .filter((reading) => reading !== null)
    if (readings.length > 0) await store.putQuotas(readings)
  }

  private agentsWithUsage(includeRemote = false): AgentId[] {
    const scopes = [this.sources('computer'), this.sources('sarto')]
    const localIds = this.stats
      .filter((s) => scopes.some((sources) => sources[s.agentId] === s.source))
      .map((s) => s.agentId)
    const remoteIds = includeRemote ? this.remoteStatsCache.map((s) => s.agentId) : []
    return sortAgentIds([...localIds, ...remoteIds])
  }

  async total(from: number, to: number): Promise<UsageTotal> {
    const { store } = this.deps
    if (!store || this.unavailable) {
      return {
        total: 0,
        byAgent: {},
        requests: 0,
        turns: 0,
        cost: null,
        unpricedTokens: 0,
        cacheSaved: 0,
      }
    }
    const rows = await store.totals(from, to, this.sources('computer'))
    const byAgent: UsageTotal['byAgent'] = {}
    const sum: UsageTotal = {
      total: 0,
      byAgent,
      requests: 0,
      turns: 0,
      cost: null,
      unpricedTokens: 0,
      cacheSaved: 0,
    }
    for (const row of rows) {
      const tokens = partsTotal(row)
      byAgent[row.agentId] = (byAgent[row.agentId] ?? 0) + tokens
      sum.total += tokens
      sum.requests += row.requests
      sum.turns += row.turns
      sum.unpricedTokens += row.unpricedTokens
      sum.cacheSaved += row.cacheSaved
      // A priced agent adds up; the cost stays null while every agent it holds is unpriced.
      if (row.cost !== null) sum.cost = (sum.cost ?? 0) + row.cost
    }
    return sum
  }

  status(): UsageStatus {
    const record = this.stats.filter((s) => s.source === 'sarto')
    const logs: UsageLogStatus[] = this.deps.readers.map((reader) => {
      const state = this.logs.get(reader.agentId)
      const stats = this.stats.find((s) => s.agentId === reader.agentId && s.source === 'log')
      return {
        agentId: reader.agentId,
        locations: reader.locations(this.envs[reader.agentId] ?? {}, this.deps.home),
        found: state?.found ?? null,
        rows: stats?.rows ?? 0,
        first: stats?.first ?? null,
        last: stats?.last ?? null,
        syncedAt: state?.syncedAt ?? null,
        error: state?.error ?? null,
      }
    })
    return {
      fromComputer: this.fromComputer,
      scanning: this.progress,
      recordSince: record.length > 0 ? Math.min(...record.map((s) => s.first)) : null,
      logs,
      unavailable: this.unavailable,
    }
  }
}

/** Sums the rows of an agent that now name the same project, as a worktree's do its project's. */
function mergeProjects(rows: ProjectUsage[]): ProjectUsage[] {
  const merged = new Map<string, ProjectUsage>()
  for (const row of rows) {
    const key = `${row.agentId}\0${row.project ?? ''}`
    const known = merged.get(key)
    if (!known) {
      merged.set(key, { ...row })
      continue
    }
    known.requests += row.requests
    known.turns += row.turns
    known.cost =
      known.cost === null && row.cost === null ? null : (known.cost ?? 0) + (row.cost ?? 0)
    known.unpricedTokens += row.unpricedTokens
    known.input += row.input
    known.output += row.output
    known.reasoning += row.reasoning
    known.cacheRead += row.cacheRead
    known.cacheWrite += row.cacheWrite
    known.cacheSaved += row.cacheSaved
  }
  return [...merged.values()]
}
