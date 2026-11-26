// What the usage database stores and what the log readers hand it: one row per request (a log
// message) or per turn and model (Sarto's record), and a cursor per log file read.

import type { Platform } from '@shared/platform'
import type { AgentId } from '@shared/thread'
import type { QuotaReading, UsageSource } from '@shared/usage'
import type { StoredQuota } from './quota'

export type { UsageSource }

export interface UsageRow {
  /** Unique across sources; importing the same request again changes nothing. */
  key: string
  source: UsageSource
  agentId: AgentId
  /** The agent's own session id. */
  sessionId: string | null
  /** The working folder, when known. */
  project: string | null
  /** Normalized with `normalizeModel`; '' when unknown. */
  model: string
  /** ms since the epoch: the request's time, or the turn's end. */
  at: number
  /** Input tokens without the cached part. */
  input: number
  output: number
  /** Only where the agent reports it apart from output. */
  reasoning: number | null
  cacheRead: number
  /** All cache writes; the hour's part is also counted in `cacheWrite1h`. */
  cacheWrite: number
  cacheWrite1h: number
  /** 1 on one row of each of Sarto's turns, else 0. */
  turn: number
}

/** How far a log file, or a reader's database, has been read. */
export interface FileCursor {
  /** The file's path, or a name that survives the file moving (Codex rollouts). */
  id: string
  agentId: AgentId
  size: number
  mtimeNs: bigint
  /** Bytes of complete lines read. */
  offset: number
  /** 32 bits of a hash of the 4 KB before `offset`; null at offset 0. */
  tail: number | null
  /** A reader's own state, such as Codex's running totals. */
  state: string | null
}

/** What a reader is given to read an agent's plan quota alone. */
export interface QuotaContext {
  /** The environment the agents run with, so CLAUDE_CONFIG_DIR and the like are honored. */
  readonly env: Readonly<Record<string, string | undefined>>
  readonly home: string
  readonly platform: Platform
  readonly signal: AbortSignal
  log(level: 'info' | 'warn' | 'error', message: string): void
  /** The plan quota this agent's reader stored last, to merge what a scan reads into it. */
  storedQuota(agentId: AgentId): StoredQuota | null
  /** Stores the agent's plan quota as its files say now, and measurements of its windows. */
  quota(reading: QuotaReading, state?: string | null): void
}

/** What a reader is given for one scan. Everything it writes goes through `commit`. */
export interface ScanContext extends QuotaContext {
  cursor(id: string): FileCursor | null
  /** Stores a file's new rows and its cursor in one transaction. */
  commit(rows: UsageRow[], cursor: FileCursor): void
  /** Announces how much this scan will read, once the files are listed. */
  plan(files: number, bytes: number): void
  /** Reports a file done, with the bytes it accounted for in `plan`. */
  done(bytes: number): void
}

export interface LogReader {
  readonly agentId: AgentId
  /** The folders or files it reads, for Settings. */
  locations(env: ScanContext['env'], home: string): string[]
  /** Reads what changed since the cursors; resolves false when the agent's logs were not found. */
  scan(context: ScanContext): Promise<boolean>
  /**
   * Reads the agent's plan quota alone, cheaply, between scans: a file only when it changed, the
   * end of the newest log only. Absent for an agent whose files hold no quota.
   */
  quota?(context: QuotaContext): Promise<void>
}

/**
 * Agents whose log is the account's rather than the computer's: every computer signed in to the
 * account reads the same requests, so the computers' copies count once.
 */
export const ACCOUNT_LOGS: ReadonlySet<AgentId> = new Set<AgentId>(['cursor'])

/** A row's total, counting reasoning only where it is reported apart from output. */
export function rowTotal(
  row: Pick<UsageRow, 'input' | 'output' | 'reasoning' | 'cacheRead' | 'cacheWrite'>,
): number {
  return row.input + row.output + (row.reasoning ?? 0) + row.cacheRead + row.cacheWrite
}

const EFFORTS = new Set(['minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'none'])

/**
 * One name per model across agents: lower-cased, without a provider prefix (`openai/`), a
 * reasoning effort (`/high`), a context tag (`[1m]`) or a date suffix (`-20250929`, `-2026-03-05`).
 */
export function normalizeModel(name: string | null | undefined): string {
  let model = (name ?? '').trim().toLowerCase()
  model = model.replace(/\[[^\]]*\]$/, '')
  const parts = model.split('/').filter(Boolean)
  if (parts.length > 1 && EFFORTS.has(parts[parts.length - 1]!)) parts.pop()
  model = parts[parts.length - 1] ?? ''
  return model.replace(/-\d{8}$/, '').replace(/-\d{4}-\d{2}-\d{2}$/, '')
}
