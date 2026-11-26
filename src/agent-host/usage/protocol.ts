// Messages between the usage manager in the host and the usage worker that owns the database
// and reads the agents' logs.

import type { Platform } from '@shared/platform'
import type { SyncedHostUsageSection } from '@shared/sync/protocol'
import type { AgentId } from '@shared/thread'
import type {
  AgentActivity,
  ClockRequest,
  QuotaHistory,
  QuotaReading,
  ScanProgress,
} from '@shared/usage'
import type { OverviewRequest, SourceMap, UsageDbStatus } from './db'
import type { UsageRow } from './model'

export interface ScanRequest {
  agents: AgentId[]
  // Each agent's own environment, which carries the configuration folder picked for it.
  envs: Partial<Record<AgentId, Record<string, string | undefined>>>
  home: string
  platform: Platform
}

/** Where the worker reads the prices that come before the bundled ones; absent for none. */
export interface PriceFiles {
  /** The user's own prices, in the Mac app's shape. */
  override?: string
  /** The Sarto server's daily snapshot. */
  server?: string
  /** How often they are looked at for a change; `PRICE_POLL_MS` when absent. */
  pollMs?: number
}

/** What the `quotas` request answers. */
export interface QuotaAnswer {
  readings: QuotaReading[]
  history: QuotaHistory[]
  activity: AgentActivity[]
}

/** How one agent's part of a scan went; `found` is false when its logs are not there. */
export interface ScanResult {
  agentId: AgentId
  found: boolean
  error: string | null
}

export type UsageRequest =
  | { id: number; op: 'write'; rows: UsageRow[] }
  | {
      id: number
      op: 'summary'
      dayStarts: number[]
      from: number
      to: number
      sources: SourceMap
      clock?: ClockRequest
      includeRemote?: boolean
    }
  | {
      id: number
      op: 'totals'
      from: number
      to: number
      sources: SourceMap
      includeRemote?: boolean
    }
  | { id: number; op: 'stats' }
  /** Each agent's quota reading and history, and the latest request of each counted agent. */
  | { id: number; op: 'quotas'; sources: SourceMap }
  /** The agents' live plan limits, as readings of the agent origin. */
  | { id: number; op: 'putQuotas'; readings: QuotaReading[] }
  | { id: number; op: 'remoteStats' }
  | { id: number; op: 'exportBuckets' }
  | {
      id: number
      op: 'setRemoteUsage'
      devices: Record<string, SyncedHostUsageSection>
      /** With it, `devices` holds only the changed Macs; see `UsageDb.setRemoteUsage`. */
      present?: string[]
    }
  | ({ id: number; op: 'scan' } & ScanRequest)
  /** Reads the agents' plan quotas alone, as their readers' `quota` does, beside any scan. */
  | ({ id: number; op: 'refreshQuotas' } & ScanRequest)
  | ({ id: number; op: 'overview' } & OverviewRequest)
  | { id: number; op: 'cancel' }
  | { id: number; op: 'removeLogs'; agentId: AgentId }
  | { id: number; op: 'clearRecord' }
  | { id: number; op: 'close' }

export type UsageReply =
  | { type: 'ready'; status: UsageDbStatus }
  | { type: 'log'; level: 'info' | 'warn' | 'error'; message: string }
  /** The scan's progress, at most every 200 ms; null once it ends. */
  | { type: 'progress'; progress: ScanProgress | null }
  /** Rows were added or changed, at most every 200 ms. */
  | { type: 'changed' }
  | { type: 'result'; id: number; value: unknown }
  | { type: 'error'; id: number; message: string }
