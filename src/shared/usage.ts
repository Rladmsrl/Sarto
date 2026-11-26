// The usage page's data, as the agent host serves it.

import type { AgentId, HarnessId } from './thread'

export type UsageSource = 'sarto' | 'log'

/** Which numbers the page counts: this computer's logs, Sarto's record alone, or all synced Macs. */
export type UsageScope = 'computer' | 'sarto' | 'all'

/** What a token sum carries beside the tokens: how many rows, turns, and what they cost. */
export interface UsageFigures {
  /** The rows summed: one per request in an agent's log, or Sarto's rows. */
  requests: number
  /** Sarto's turns, one per turn whatever its models; 0 for imported logs. */
  turns: number
  /** Dollars over the models with a price; null when none of them is priced. */
  cost: number | null
  /** Tokens of the models without a price, which no cost counts. */
  unpricedTokens: number
  /** Dollars the cache reads saved: cache reads times the input price less the cache read price. */
  cacheSaved: number
}

/** Token counts; `reasoning` is 0 for agents whose output already includes it. */
export interface TokenParts extends UsageFigures {
  input: number
  output: number
  reasoning: number
  cacheRead: number
  cacheWrite: number
}

export interface DayUsage extends TokenParts {
  /** Index into the request's days. */
  day: number
  agentId: AgentId
}

export interface ModelUsage extends TokenParts {
  agentId: AgentId
  model: string
  /** How its cost was priced; absent from older hosts. */
  price?: PriceMatch
}

/**
 * Where a model's price came from: the user's own prices file, the Sarto server's daily snapshot,
 * the snapshot bundled with the build, or the Mac app's bundled table.
 */
export type PriceOrigin = 'override' | 'server' | 'bundled' | 'registry'

/**
 * How a model is priced, as Sarto's Mac app's `PriceMatch`: under its own name (`exact`), at the
 * price of its nearest sibling version (`family`, the app shows it as `≈`), or not at all.
 */
export interface PriceMatch {
  kind: 'exact' | 'family' | 'unpriced'
  /** The name the price is listed under: the model itself, or the sibling; null when unpriced. */
  model: string | null
  origin: PriceOrigin | null
}

export interface ProjectUsage extends TokenParts {
  agentId: AgentId
  /** The working folder, or null when the agent recorded none. */
  project: string | null
  /** The folder is one of Sarto's No project folders. */
  scratch: boolean
}

/** A stretch of the asking page's clocks on one UTC offset, until the next zone starts. */
export interface ClockZone {
  from: number
  /** Minutes east of UTC, a multiple of 15. */
  offset: number
}

/**
 * The range to sum by hour of the day, and the page's zones over it, ascending, the first from
 * at or before `from`, so each quarter hour counts into the local hour it began in.
 */
export interface ClockRequest {
  from: number
  to: number
  zones: ClockZone[]
}

export interface HourUsage extends TokenParts {
  /** The local hour of the day, 0 to 23. */
  hour: number
  agentId: AgentId
}

/**
 * What a quota window covers: a short session window, the weekly one, a weekly one for some models
 * only, or another the agent names.
 */
export type QuotaWindowKind = 'session' | 'weekly' | 'scoped' | 'other'

/** A plan quota window, as the agent itself last measured it. */
export interface QuotaWindow {
  /**
   * Stable across readings, as the agents' own plan limits name them: `five_hour`, `seven_day`,
   * `seven_day_fable`, a Codex pool's `gpt_5_3_codex_spark_five_hour`.
   */
  id: string
  kind: QuotaWindowKind
  /** The models a scoped window counts, as the agent names them ("Fable"); null for the plan. */
  scope: string | null
  /** The window's length in minutes; null when neither the agent nor its kind says. */
  minutes: number | null
  /** 0 to 100. */
  usedPercent: number
  resetsAt: number | null
  /** When the agent measured it; null when it does not say. */
  observedAt: number | null
  /** What the share is of, when the agent tells an amount: Cursor's $27.06 of $400. */
  amount?: QuotaAmount
}

export interface QuotaAmount {
  used: number
  total: number
  /** `USD`, `credits`, `requests`. */
  unit: string
}

/** An agent's plan quota on this computer, from the files the agent writes itself. */
export interface QuotaReading {
  agentId: AgentId
  /**
   * The account the agent is signed in to, as a fingerprint: the first 8 bytes of
   * SHA-256("<provider>:<account id>") in hex, as Sarto's Mac app makes it, so readings of one
   * account merge across computers and the id never leaves this one. Null when the agent names
   * no account, as on an API key.
   */
  account: string | null
  /** The plan as the agent names it ("Max 20×", "Pro 200"); null when it does not say. */
  plan: string | null
  windows: QuotaWindow[]
  /** When the newest of its windows was measured; null when none says. */
  observedAt: number | null
}

/** One measurement of a quota window, for burn-rate forecasts. */
export interface QuotaSample {
  at: number
  usedPercent: number
  resetsAt: number | null
}

/** A window's measurements on this computer over the last 48 hours, oldest first. */
export interface QuotaHistory {
  agentId: AgentId
  window: string
  samples: QuotaSample[]
}

/** An agent's latest counted request. */
export interface AgentActivity {
  agentId: AgentId
  at: number
  /**
   * Its model, normalized; a small Haiku call Claude Code makes beside a main model within ten
   * minutes leaves the main model. Null when no recent request names one.
   */
  model: string | null
}

export interface UsageSummary {
  days: DayUsage[]
  /** The clock request's range by hour of the day; empty when none was asked. */
  clock: HourUsage[]
  models: ModelUsage[]
  projects: ProjectUsage[]
  /** The source each agent counted from; an agent left out has nothing to count. */
  sources: Partial<Record<AgentId, UsageSource>>
  /** The first quarter hour with usage under those sources, or null with none. */
  first: number | null
  /** The agents with usage under either scope, at any time, so both offer the same agent filter. */
  agents: AgentId[]
  /** The date of the price list the cost was computed with. */
  pricesAsOf: string
  /** This computer's plan quota readings, one per agent; absent from older hosts. */
  quotas?: QuotaReading[]
  /** Their windows' measurements on this computer. */
  quotaHistory?: QuotaHistory[]
  /** Each agent's latest request this computer counts, under the scope's sources. */
  activity?: AgentActivity[]
}

/** A forecast's verdict on a window, as the Mac app's `WindowForecast.Status`. */
export type ForecastStatus =
  /** Runs out `seconds` from now, before it resets. */
  | { kind: 'exhausts'; seconds: number }
  /** Lasts until it resets, with `remainingAtReset` (0 to 1) of it left then. */
  | { kind: 'survives'; remainingAtReset: number }
  /** So little is used that it holds until it resets. */
  | { kind: 'steady' }
  /** Its reset time has passed; the agent has not measured the new window yet. */
  | { kind: 'reset' }
  /** Not enough is known, such as when it resets. */
  | { kind: 'insufficient' }

/**
 * A window's burn-rate forecast, as the Mac app's `QuotaForecaster` makes it, from the usage and
 * measurements of the computers signed in to the window's account only.
 */
export interface WindowForecast {
  status: ForecastStatus
  /** Tokens left in the window, by the account's tokens per 1% used; null when too little is known. */
  estimatedRemainingTokens: number | null
  /** The account's tokens counted in the window so far. */
  windowTokens: number
}

/** A computer of the sync, as the usage overview lists it. */
export interface UsageDevice {
  /** The sync's id for the computer. */
  id: string
  name: string
  /** When it last shared its usage; for this computer, when the sync last took it. */
  updatedAt: number | null
  thisComputer: boolean
}

/** One quota window, ready to show: past its reset time it shows as reset, at 0% used. */
export interface OverviewWindow {
  id: string
  kind: QuotaWindowKind
  scope: string | null
  /** Its name in the host's language: "5-hour", "Weekly", "Weekly · Fable". */
  label: string
  minutes: number | null
  /** 0 to 100; 0 once reset. */
  usedPercent: number
  /** 0 to 1, what the tube fills to. */
  remaining: number
  /** Null once reset, until the agent measures the new window. */
  resetsAt: number | null
  reset: boolean
  observedAt: number | null
  forecast: WindowForecast
  amount?: QuotaAmount
}

/** One account's quota, as the computer that read it last saw it. */
export interface OverviewQuota {
  /** The account's fingerprint; null when the agent names none, which keeps it apart. */
  account: string | null
  /** The plan, from the newest reading of the account that names one. */
  plan: string | null
  observedAt: number | null
  /** The computer the reading came from; null for this computer's own. */
  device: { id: string; name: string } | null
  /** Session windows first, then weekly, other and scoped (model-specific) ones. */
  windows: OverviewWindow[]
  /** The id of the plan-wide window with the least left, which the tube shows; null with none. */
  primary: string | null
  /** The id of another plan-wide window, the tube's second line; null with none. */
  secondary: string | null
}

export interface OverviewActivity {
  at: number
  /** The model, normalized; Claude Code's small Haiku helpers leave the main model. */
  model: string | null
}

/** One agent's line of the usage overview. */
export interface OverviewAgent {
  agentId: AgentId
  /** Its logs or record are on this computer, or another computer shares its usage or quota. */
  available: boolean
  /** Today, in the host's time zone, under the overview's scope. */
  today: {
    tokens: number
    /** Dollars over the priced models; 0 when none is priced. */
    cost: number
    requests: number
    /** Tokens of models with no price, which `cost` leaves out. */
    unpricedTokens: number
  }
  /** The newest request counted under the scope: across computers in the `all` scope. */
  activity: OverviewActivity | null
  /** The newest request on this computer. */
  localActivity: OverviewActivity | null
  /**
   * This computer's account: its freshest reading from any computer signed in to it; with no
   * reading here, in the `all` scope, the account read most recently. Null with none.
   */
  quota: OverviewQuota | null
  /** In the `all` scope, the other accounts other computers use, freshest first; else empty. */
  otherAccounts: OverviewQuota[]
  /** The agent is signed out on this computer, so its quota is not read here. */
  signedOut: boolean
  /** Its name and harness, as the agents list them; absent for an agent this host does not know. */
  name?: string
  harnessId?: HarnessId
  /**
   * Whether the usage views show its quota: it is installed (in the `all` scope, here or on the
   * computer whose reading shows), used within `ELIGIBLE_DAYS`, and its quota has a window.
   */
  eligible: boolean
}

/** How recent an agent's use must be for the usage views to show its quota. */
export const ELIGIBLE_DAYS = 30

/** A model's figures over a range. */
export interface OverviewModel {
  agentId: AgentId
  model: string
  tokens: number
  /** Dollars; 0 when unpriced. */
  cost: number
  requests: number
  price: PriceMatch
}

/** Sums per period: `starts` oldest first, the current period last; each agent's arrays alike. */
export interface UsageSeries {
  starts: number[]
  agents: { agentId: AgentId; tokens: number[]; cost: number[] }[]
}

/**
 * Everything the Mac app's usage views show, computed by the host: each agent's line, the ranked
 * models, the series and the computers. The app maps it onto its views without computing.
 */
export interface UsageOverview {
  generatedAt: number
  scope: UsageScope
  /** Agents with usage, a quota or a reading under the scope, in the agents' order. */
  agents: OverviewAgent[]
  /** For each range of the last 1, 7, 30 and 90 days, its models by cost, then tokens. */
  models: { days: number; models: OverviewModel[] }[]
  /** The last 24 hours, by the hour (UTC hours), the current hour last. */
  hourly: UsageSeries
  /** The last 90 days, local days in the host's time zone, today last. */
  daily: UsageSeries
  /** This computer first, then the others by name; empty while the sync is off. */
  devices: UsageDevice[]
  /** Models of the last 90 days with no price. */
  unpricedModels: string[]
  /** Models of the last 90 days priced from a sibling version. */
  familyPriced: { model: string; standIn: string }[]
  /** The date of the LiteLLM snapshot in use. */
  pricesAsOf: string
}

export interface UsageTotal extends UsageFigures {
  total: number
  byAgent: Partial<Record<AgentId, number>>
}

export interface ScanProgress {
  files: number
  bytes: number
  doneFiles: number
  doneBytes: number
}

/** One agent's logs, as Settings shows them. */
export interface UsageLogStatus {
  agentId: AgentId
  /** The folders or files its reader looks at. */
  locations: string[]
  /** null until a scan this run has looked. */
  found: boolean | null
  /** Requests imported, and the first and last moments they cover. */
  rows: number
  first: number | null
  last: number | null
  syncedAt: number | null
  error: string | null
}

export interface UsageStatus {
  fromComputer: boolean
  /** The scan running now, or null. */
  scanning: ScanProgress | null
  /** When Sarto's own record starts, or null while it is empty. */
  recordSince: number | null
  logs: UsageLogStatus[]
  /** The database could not be opened, or a newer app wrote it. */
  unavailable: boolean
}

/** A row's total, counting reasoning only where it is reported apart from output. */
export function partsTotal(parts: TokenParts): number {
  return parts.input + parts.output + parts.reasoning + parts.cacheRead + parts.cacheWrite
}
