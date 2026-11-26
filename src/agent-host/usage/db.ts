// The usage database: Sarto's record and the imported log rows, summed per quarter hour.
// node:sqlite is synchronous, so this runs in the usage worker, never on the host's event loop.

import { existsSync, mkdirSync, renameSync } from 'node:fs'
import path from 'node:path'
import { DatabaseSync, type SQLOutputValue, type StatementSync } from 'node:sqlite'
import type { AgentId } from '@shared/thread'
import type { SyncedHostUsageSection, SyncedUsageBucket } from '@shared/sync/protocol'
import type {
  AgentActivity,
  ClockRequest,
  DayUsage,
  HourUsage,
  ModelUsage,
  PriceMatch,
  PriceOrigin,
  QuotaHistory,
  QuotaReading,
  QuotaSample,
  TokenParts,
  UsageSource,
  UsageSummary,
  WindowForecast,
} from '@shared/usage'
import { transaction } from '../sqlite'
import {
  accountGroups,
  isForgotten,
  mergedReading,
  samplesOf,
  type DeviceReading,
  type ForgottenAccount,
  type UsageDeviceRef,
} from './accounts'
import { ACTIVITY_ROWS, latestActivity } from './activity'
import { forecastWindow, mergeSamples, windowLength, type LedgerBucket } from './forecast'
import { ACCOUNT_LOGS, type FileCursor, type UsageRow } from './model'
import { Pricing } from './pricing'
import { syncedQuotas, type RemoteQuotas } from './synced'
import {
  hasReset,
  HISTORY_MS,
  mergeOrigins,
  recordSample,
  type QuotaOrigin,
  type StoredQuota,
} from './quota'
import { keepsNewer } from './rows'

export const SCHEMA_VERSION = 7

/** Every time zone's offset is a multiple of 15 minutes, so a local day is a range of these. */
export const QUARTER_MS = 900_000

// One plan quota reading per agent and origin, as JSON, and the measurements of its windows.
const QUOTA_TABLES = `
  CREATE TABLE quotas (
    agent_id    TEXT NOT NULL,
    origin      TEXT NOT NULL,
    reading     TEXT NOT NULL,
    state       TEXT,
    PRIMARY KEY (agent_id, origin)
  ) STRICT;
  CREATE TABLE quota_samples (
    agent_id     TEXT NOT NULL,
    window_id    TEXT NOT NULL,
    at           INTEGER NOT NULL,
    used_percent REAL NOT NULL,
    resets_at    INTEGER,
    PRIMARY KEY (agent_id, window_id, at)
  ) STRICT, WITHOUT ROWID;
`

const SCHEMA = `
  CREATE TABLE usage (
    key         TEXT PRIMARY KEY,
    source      TEXT NOT NULL,
    agent_id    TEXT NOT NULL,
    session_id  TEXT,
    project     TEXT,
    model       TEXT NOT NULL,
    at          INTEGER NOT NULL,
    input       INTEGER NOT NULL,
    output      INTEGER NOT NULL,
    reasoning   INTEGER,
    cache_read  INTEGER NOT NULL,
    cache_write INTEGER NOT NULL,
    cache_write_1h INTEGER NOT NULL,
    turn        INTEGER NOT NULL
  ) STRICT, WITHOUT ROWID;
  CREATE INDEX usage_by_time ON usage (source, agent_id, at);
  CREATE TABLE buckets (
    quarter     INTEGER NOT NULL,
    source      TEXT NOT NULL,
    agent_id    TEXT NOT NULL,
    model       TEXT NOT NULL,
    project     TEXT NOT NULL,
    rows        INTEGER NOT NULL,
    input       INTEGER NOT NULL,
    output      INTEGER NOT NULL,
    reasoning   INTEGER NOT NULL,
    cache_read  INTEGER NOT NULL,
    cache_write INTEGER NOT NULL,
    cache_write_1h INTEGER NOT NULL,
    turns       INTEGER NOT NULL,
    PRIMARY KEY (quarter, source, agent_id, model, project)
  ) STRICT, WITHOUT ROWID;
  CREATE TABLE cursors (
    id        TEXT PRIMARY KEY,
    agent_id  TEXT NOT NULL,
    size      INTEGER NOT NULL,
    mtime_ns  INTEGER NOT NULL,
    offset    INTEGER NOT NULL,
    tail      INTEGER,
    state     TEXT,
    seen_at   INTEGER NOT NULL
  ) STRICT;
  CREATE INDEX cursors_by_agent ON cursors (agent_id);
  CREATE TABLE remote_buckets (
    quarter        INTEGER NOT NULL,
    device_id      TEXT NOT NULL,
    source         TEXT NOT NULL,
    agent_id       TEXT NOT NULL,
    model          TEXT NOT NULL,
    project        TEXT NOT NULL,
    rows           INTEGER NOT NULL,
    input          INTEGER NOT NULL,
    output         INTEGER NOT NULL,
    reasoning      INTEGER NOT NULL,
    cache_read     INTEGER NOT NULL,
    cache_write    INTEGER NOT NULL,
    cache_write_1h INTEGER NOT NULL,
    turns          INTEGER NOT NULL,
    PRIMARY KEY (quarter, device_id, source, agent_id, model, project)
  ) STRICT, WITHOUT ROWID;
  ${QUOTA_TABLES}
`

/**
 * The price of each model the buckets name, as `Pricing` resolves it, in a temporary table of
 * this connection that the queries join; a model with no price has no row.
 */
const PRICE_TABLE = `
  CREATE TEMP TABLE IF NOT EXISTS prices (
    model          TEXT PRIMARY KEY,
    input          REAL NOT NULL,
    output         REAL NOT NULL,
    cache_read     REAL NOT NULL,
    cache_write    REAL NOT NULL,
    cache_write_1h REAL,
    match          TEXT NOT NULL,
    priced_as      TEXT NOT NULL,
    origin         TEXT NOT NULL
  )`

/**
 * Other computers' logs of an `ACCOUNT_LOGS` agent that hold the same account's requests as one
 * counted already, here or on another computer, which the remote sums leave out.
 */
const COPIES_TABLE = `
  CREATE TEMP TABLE IF NOT EXISTS copies (
    device_id TEXT NOT NULL,
    agent_id  TEXT NOT NULL,
    PRIMARY KEY (device_id, agent_id)
  )`
const NOT_COPY =
  'NOT EXISTS (SELECT 1 FROM temp.copies c WHERE c.device_id = b.device_id AND c.agent_id = b.agent_id)'

// SQLite's primary result codes, the low byte of node:sqlite's `errcode`.
const SQLITE_CORRUPT = 11
const SQLITE_NOTADB = 26

export type UsageDbStatus = 'ok' | 'created' | 'recovered' | 'newer' | 'unavailable'
export type UsageDbLog = (level: 'info' | 'warn' | 'error', message: string) => void

/** Which source counts for each agent; an agent left out counts nothing. */
export type SourceMap = Partial<Record<AgentId, UsageSource>>

export type DbSummary = Omit<UsageSummary, 'sources' | 'first' | 'agents' | 'projects'> & {
  projects: Omit<UsageSummary['projects'][number], 'scratch'>[]
}

/** What the usage overview asks of the database. */
export interface OverviewRequest {
  /** The scope's source per agent, for the sums and this computer's activity. */
  sources: SourceMap
  /** This computer's own source per agent, whose usage the forecasts count. */
  computers: SourceMap
  includeRemote: boolean
  /** 91 local day boundaries: the last 90 days, today last. */
  dayStarts: number[]
  /** 25 hour boundaries: the last 24 hours, the current one last. */
  hourStarts: number[]
  now: number
  /** Accounts the user removed, whose readings before then are left out. */
  forgotten?: readonly ForgottenAccount[]
}

/** One account's reading, from the computer that read it last, with its windows' forecasts. */
export interface QuotaGroup {
  device: UsageDeviceRef | null
  reading: QuotaReading
  /** Whether this computer's own reading is one of the account's. */
  here: boolean
  forecasts: Record<string, WindowForecast>
}

export interface OverviewAnswer {
  /** Today's sums per agent. */
  today: (TokenParts & { agentId: AgentId })[]
  models: { days: number; models: ModelUsage[] }[]
  /** `day` indexes the day boundaries. */
  daily: DayUsage[]
  /** `day` indexes the hour boundaries. */
  hourly: DayUsage[]
  /** This computer's latest request per agent, under the scope's sources. */
  localActivity: AgentActivity[]
  /** Other computers' latest request per agent, the newest of them. */
  remoteActivity: AgentActivity[]
  /** Each agent's account groups, this computer's first. */
  quotas: { agentId: AgentId; groups: QuotaGroup[] }[]
  /** The other computers that share usage. */
  devices: { id: string; name: string; updatedAt: number }[]
  pricesAsOf: string
}

/** What one agent's rows from one source hold, for Settings and the page's first day. */
export interface SourceStats {
  agentId: AgentId
  source: UsageSource
  rows: number
  first: number
  last: number
}

function resultCode(error: unknown): number | null {
  const errcode = (error as { errcode?: unknown } | null)?.errcode
  return typeof errcode === 'number' ? errcode & 0xff : null
}

const isCorrupt = (error: unknown): boolean => {
  const code = resultCode(error)
  return code === SQLITE_CORRUPT || code === SQLITE_NOTADB
}

type Row = Record<string, SQLOutputValue>

const num = (value: SQLOutputValue | undefined): number => Number(value ?? 0)
const quarterOf = (at: number): number => Math.floor(at / QUARTER_MS)
const QUARTERS_A_DAY = 96

function parts(row: Row): TokenParts {
  return {
    input: num(row.input),
    output: num(row.output),
    reasoning: num(row.reasoning),
    cacheRead: num(row.cache_read),
    cacheWrite: num(row.cache_write),
    requests: num(row.requests),
    turns: num(row.turns),
    // A sum over unpriced rows only is NULL: no model in it had a price.
    cost: row.cost === null || row.cost === undefined ? null : num(row.cost),
    unpricedTokens: num(row.unpriced_tokens),
    cacheSaved: num(row.cache_saved),
  }
}

const PRICE_JOIN = 'LEFT JOIN temp.prices AS p ON p.model = b.model'
const INPUT_PRICE = 'p.input'
const OUTPUT_PRICE = 'p.output'
const READ_PRICE = 'p.cache_read'
const WRITE_PRICE = 'p.cache_write'
const HOUR_PRICE = `COALESCE(p.cache_write_1h, ${WRITE_PRICE})`
const PRICED = 'p.model IS NOT NULL'
/** How a model row was priced; constant per model, so it may stand beside the sums. */
const PRICE_COLUMNS = 'p.match AS price_match, p.priced_as AS priced_as, p.origin AS price_origin'
/** A bucket's tokens, as the forecasts count them. */
const TOTAL = 'b.input + b.output + b.reasoning + b.cache_read + b.cache_write'

const SUMS = `
  SUM(b.rows) AS requests,
  SUM(b.turns) AS turns,
  SUM(b.input) AS input,
  SUM(b.output) AS output,
  SUM(b.reasoning) AS reasoning,
  SUM(b.cache_read) AS cache_read,
  SUM(b.cache_write) AS cache_write,
  SUM(CASE WHEN ${PRICED} THEN
    b.input * ${INPUT_PRICE}
    + (b.output + b.reasoning) * ${OUTPUT_PRICE}
    + b.cache_read * ${READ_PRICE}
    + (b.cache_write - b.cache_write_1h) * ${WRITE_PRICE}
    + b.cache_write_1h * ${HOUR_PRICE}
    ELSE NULL END) AS cost,
  SUM(CASE WHEN ${PRICED} THEN 0
    ELSE b.input + b.output + b.reasoning + b.cache_read + b.cache_write END) AS unpriced_tokens,
  SUM(CASE WHEN ${PRICED} THEN b.cache_read * (${INPUT_PRICE} - ${READ_PRICE}) ELSE 0 END)
    AS cache_saved`

function prepareAll(db: DatabaseSync) {
  const sql = (text: string): StatementSync => db.prepare(text)
  const cursor = sql('SELECT * FROM cursors WHERE id = ?')
  // mtime_ns is past 2^53.
  cursor.setReadBigInts(true)
  return {
    cursor,
    row: sql('SELECT * FROM usage WHERE key = ?'),
    insertRow: sql(`
      INSERT INTO usage (key, source, agent_id, session_id, project, model, at, input, output,
        reasoning, cache_read, cache_write, cache_write_1h, turn)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`),
    updateRow: sql(`
      UPDATE usage SET session_id = ?, project = ?, model = ?, at = ?, input = ?, output = ?,
        reasoning = ?, cache_read = ?, cache_write = ?, cache_write_1h = ?, turn = ?
      WHERE key = ?`),
    addBucket: sql(`
      INSERT INTO buckets (quarter, source, agent_id, model, project, rows, input, output,
        reasoning, cache_read, cache_write, cache_write_1h, turns)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT (quarter, source, agent_id, model, project) DO UPDATE SET
        rows = rows + excluded.rows,
        input = input + excluded.input,
        output = output + excluded.output,
        reasoning = reasoning + excluded.reasoning,
        cache_read = cache_read + excluded.cache_read,
        cache_write = cache_write + excluded.cache_write,
        cache_write_1h = cache_write_1h + excluded.cache_write_1h,
        turns = turns + excluded.turns`),
    dropEmptyBucket: sql(
      `DELETE FROM buckets
      WHERE quarter = ? AND source = ? AND agent_id = ? AND model = ? AND project = ? AND rows <= 0`,
    ),
    putCursor: sql(`
      INSERT INTO cursors (id, agent_id, size, mtime_ns, offset, tail, state, seen_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT (id) DO UPDATE SET
        agent_id = excluded.agent_id,
        size = excluded.size,
        mtime_ns = excluded.mtime_ns,
        offset = excluded.offset,
        tail = excluded.tail,
        state = excluded.state,
        seen_at = excluded.seen_at`),
    dayBuckets: sql(`
      SELECT b.quarter, b.agent_id, b.source, b.model, ${SUMS} FROM buckets b ${PRICE_JOIN}
      WHERE b.quarter >= ? AND b.quarter < ?
      GROUP BY b.quarter, b.agent_id, b.source, b.model`),
    // The local hour each bucket began in: its quarter moved by the offset, in quarters.
    clockBuckets: sql(`
      SELECT ((b.quarter + CAST(? AS INTEGER)) % ${QUARTERS_A_DAY}) / 4 AS hour, b.agent_id, b.source, ${SUMS}
      FROM buckets b ${PRICE_JOIN}
      WHERE b.quarter >= ? AND b.quarter < ?
      GROUP BY hour, b.agent_id, b.source`),
    modelBuckets: sql(`
      SELECT b.agent_id, b.source, b.model, ${PRICE_COLUMNS}, ${SUMS} FROM buckets b ${PRICE_JOIN}
      WHERE b.quarter >= ? AND b.quarter < ?
      GROUP BY b.agent_id, b.source, b.model`),
    projectBuckets: sql(`
      SELECT b.agent_id, b.source, b.project, b.model, ${SUMS} FROM buckets b ${PRICE_JOIN}
      WHERE b.quarter >= ? AND b.quarter < ?
      GROUP BY b.agent_id, b.source, b.project, b.model`),
    totals: sql(`
      SELECT b.agent_id, b.source, b.model, ${SUMS} FROM buckets b ${PRICE_JOIN}
      WHERE b.quarter >= ? AND b.quarter < ?
      GROUP BY b.agent_id, b.source, b.model`),
    stats: sql(`
      SELECT agent_id, source, SUM(rows) AS rows, MIN(quarter) AS first, MAX(quarter) AS last
      FROM buckets GROUP BY agent_id, source`),
    exportBuckets: sql(`
      SELECT quarter, source, agent_id, model, project, rows, input, output, reasoning,
        cache_read, cache_write, cache_write_1h, turns
      FROM buckets
      WHERE quarter >= ?
      ORDER BY quarter, source, agent_id, model, project`),
    clearRemoteBuckets: sql('DELETE FROM remote_buckets'),
    clearRemoteDevice: sql('DELETE FROM remote_buckets WHERE device_id = ?'),
    remoteDevices: sql('SELECT DISTINCT device_id FROM remote_buckets'),
    putRemoteBucket: sql(`
      INSERT INTO remote_buckets (quarter, device_id, source, agent_id, model, project, rows,
        input, output, reasoning, cache_read, cache_write, cache_write_1h, turns)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT (quarter, device_id, source, agent_id, model, project) DO UPDATE SET
        rows = excluded.rows,
        input = excluded.input,
        output = excluded.output,
        reasoning = excluded.reasoning,
        cache_read = excluded.cache_read,
        cache_write = excluded.cache_write,
        cache_write_1h = excluded.cache_write_1h,
        turns = excluded.turns`),
    remoteDayBuckets: sql(`
      SELECT b.quarter, b.agent_id, b.model, ${SUMS} FROM remote_buckets b ${PRICE_JOIN}
      WHERE b.quarter >= ? AND b.quarter < ? AND ${NOT_COPY}
      GROUP BY b.quarter, b.agent_id, b.model`),
    remoteClockBuckets: sql(`
      SELECT ((b.quarter + CAST(? AS INTEGER)) % ${QUARTERS_A_DAY}) / 4 AS hour, b.agent_id, ${SUMS}
      FROM remote_buckets b ${PRICE_JOIN}
      WHERE b.quarter >= ? AND b.quarter < ? AND ${NOT_COPY}
      GROUP BY hour, b.agent_id`),
    remoteModelBuckets: sql(`
      SELECT b.agent_id, b.model, ${PRICE_COLUMNS}, ${SUMS} FROM remote_buckets b ${PRICE_JOIN}
      WHERE b.quarter >= ? AND b.quarter < ? AND ${NOT_COPY}
      GROUP BY b.agent_id, b.model`),
    remoteProjectBuckets: sql(`
      SELECT b.agent_id, b.project, b.model, ${SUMS} FROM remote_buckets b ${PRICE_JOIN}
      WHERE b.quarter >= ? AND b.quarter < ? AND ${NOT_COPY}
      GROUP BY b.agent_id, b.project, b.model`),
    remoteTotals: sql(`
      SELECT b.agent_id, b.model, ${SUMS} FROM remote_buckets b ${PRICE_JOIN}
      WHERE b.quarter >= ? AND b.quarter < ? AND ${NOT_COPY}
      GROUP BY b.agent_id, b.model`),
    remoteStats: sql(`
      SELECT b.agent_id, SUM(b.rows) AS rows, MIN(b.quarter) AS first, MAX(b.quarter) AS last
      FROM remote_buckets b WHERE ${NOT_COPY} GROUP BY b.agent_id`),
    deleteRows: sql('DELETE FROM usage WHERE source = ? AND agent_id = ?'),
    deleteBuckets: sql('DELETE FROM buckets WHERE source = ? AND agent_id = ?'),
    deleteCursors: sql('DELETE FROM cursors WHERE agent_id = ?'),
    deleteSourceRows: sql('DELETE FROM usage WHERE source = ?'),
    deleteSourceBuckets: sql('DELETE FROM buckets WHERE source = ?'),
    storedQuota: sql('SELECT reading, state FROM quotas WHERE agent_id = ? AND origin = ?'),
    putQuota: sql(`
      INSERT INTO quotas (agent_id, origin, reading, state) VALUES (?, ?, ?, ?)
      ON CONFLICT (agent_id, origin) DO UPDATE SET
        reading = excluded.reading,
        state = excluded.state`),
    allQuotas: sql('SELECT agent_id, origin, reading FROM quotas'),
    samples: sql(`
      SELECT at, used_percent, resets_at FROM quota_samples
      WHERE agent_id = ? AND window_id = ? ORDER BY at`),
    dropSamples: sql('DELETE FROM quota_samples WHERE agent_id = ? AND window_id = ?'),
    putSample: sql(`
      INSERT OR REPLACE INTO quota_samples (agent_id, window_id, at, used_percent, resets_at)
      VALUES (?, ?, ?, ?, ?)`),
    pruneSamples: sql('DELETE FROM quota_samples WHERE at < ?'),
    allSamples: sql(`
      SELECT agent_id, window_id, at, used_percent, resets_at FROM quota_samples
      WHERE at >= ? ORDER BY agent_id, window_id, at`),
    knownModels: sql(
      'SELECT DISTINCT model FROM buckets UNION SELECT DISTINCT model FROM remote_buckets',
    ),
    clearCopies: sql('DELETE FROM temp.copies'),
    putCopy: sql('INSERT OR IGNORE INTO temp.copies (device_id, agent_id) VALUES (?, ?)'),
    hasLogs: sql(`SELECT 1 FROM buckets WHERE agent_id = ? AND source = 'log' LIMIT 1`),
    remoteHasLogs: sql(`
      SELECT 1 FROM remote_buckets WHERE device_id = ? AND agent_id = ? AND source = 'log' LIMIT 1`),
    clearPrices: sql('DELETE FROM temp.prices'),
    putPrice: sql(`
      INSERT OR REPLACE INTO temp.prices (model, input, output, cache_read, cache_write,
        cache_write_1h, match, priced_as, origin)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`),
    ledger: sql(`
      SELECT b.quarter, b.model, SUM(${TOTAL}) AS total FROM buckets b
      WHERE b.agent_id = ? AND b.source = ? AND b.quarter >= ?
      GROUP BY b.quarter, b.model`),
    remoteLedger: sql(`
      SELECT b.quarter, b.model, SUM(${TOTAL}) AS total FROM remote_buckets b
      WHERE b.device_id = ? AND b.agent_id = ? AND b.quarter >= ?
      GROUP BY b.quarter, b.model`),
    latestRows: sql(`
      SELECT at, model, output,
        input + output + COALESCE(reasoning, 0) + cache_read + cache_write AS total
      FROM usage WHERE source = ? AND agent_id = ? ORDER BY at DESC LIMIT ${ACTIVITY_ROWS}`),
  }
}

type Statements = ReturnType<typeof prepareAll>

export class UsageDb {
  private db: DatabaseSync | null = null
  private sql: Statements | null = null
  status: UsageDbStatus = 'ok'
  /** Every model the buckets name, and those of them the price table does not hold yet. */
  private models = new Set<string>()
  private unpriced: string[] = []
  /** The pricing version the price table was filled for. */
  private pricedFor = -1
  /** Other computers' quotas, measurements and activity, by their usage device id. */
  private remote = new Map<string, RemoteQuotas>()

  private constructor(
    private readonly file: string,
    private readonly log: UsageDbLog,
    private readonly now: () => number,
    readonly pricing: Pricing,
  ) {}

  /** Opens the file, creating it, or moving a damaged one aside and starting empty. */
  static open(
    file: string,
    log: UsageDbLog,
    now: () => number = Date.now,
    pricing: Pricing = new Pricing(),
  ): UsageDb {
    const store = new UsageDb(file, log, now, pricing)
    mkdirSync(path.dirname(file), { recursive: true })
    try {
      store.connect()
    } catch (error) {
      if (!isCorrupt(error)) throw error
      store.recover(error)
    }
    return store
  }

  get open(): boolean {
    return this.db !== null
  }

  private connect(): void {
    const db = new DatabaseSync(this.file)
    try {
      const version = Number(db.prepare('PRAGMA user_version').get()?.user_version ?? 0)
      if (version > SCHEMA_VERSION) {
        db.close()
        this.status = 'newer'
        this.log(
          'warn',
          `${path.basename(this.file)} has schema version ${version}, newer than this app understands (${SCHEMA_VERSION}); usage is neither read nor written this run`,
        )
        return
      }
      if (version === 0) {
        // auto_vacuum takes effect only before the first table exists.
        db.exec('PRAGMA auto_vacuum = INCREMENTAL')
        db.exec('PRAGMA journal_mode = WAL')
        db.exec(`BEGIN; ${SCHEMA} PRAGMA user_version = ${SCHEMA_VERSION}; COMMIT;`)
        if (this.status === 'ok') this.status = 'created'
      } else if (version < SCHEMA_VERSION) {
        throw new Error(
          `${path.basename(this.file)} is at unsupported schema version ${version} (expected ${SCHEMA_VERSION})`,
        )
      }
      db.exec('PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;')
      db.exec(PRICE_TABLE)
      db.exec(COPIES_TABLE)
      this.sql = prepareAll(db)
      this.models = new Set(this.sql.knownModels.all().map((row) => String(row.model)))
      this.unpriced = []
      this.pricedFor = -1
      this.db = db
    } catch (error) {
      try {
        db.close()
      } catch {
        // Closing a handle that failed to read anything can fail too; the first error matters.
      }
      throw error
    }
  }

  /** Moves the damaged file and its WAL aside, keeping them together, and starts empty. */
  private recover(error: unknown): void {
    try {
      this.close(false)
    } catch {
      // A damaged file may refuse to close cleanly; it is moved aside either way.
    }
    const stamp = new Date(this.now()).toISOString().replace(/[:.]/g, '-')
    const target = `${this.file}.corrupt-${stamp}`
    for (const suffix of ['', '-wal', '-shm']) {
      if (existsSync(this.file + suffix)) renameSync(this.file + suffix, target + suffix)
    }
    this.log(
      'error',
      `${path.basename(this.file)} is damaged (${(error as Error).message}); it was moved to ${path.basename(target)} and usage starts empty`,
    )
    this.status = 'recovered'
    this.connect()
  }

  /** Runs `run`, turning damage into a fresh database; null while the database is not open. */
  private guard<T>(run: (sql: Statements, db: DatabaseSync) => T, fallback: T): T {
    const { sql, db } = this
    if (!sql || !db) return fallback
    try {
      return run(sql, db)
    } catch (error) {
      if (isCorrupt(error)) this.recover(error)
      throw error
    }
  }

  private transaction(db: DatabaseSync, run: () => void): void {
    transaction(db, run)
  }

  /** A model the buckets name now, priced at the next query. */
  private noteModel(model: string): void {
    if (this.models.has(model)) return
    this.models.add(model)
    this.unpriced.push(model)
  }

  /**
   * Fills the copies table: of the computers whose logs of an `ACCOUNT_LOGS` agent hold the same
   * account, this one counts if it reads that log, else the first by device id.
   */
  private markCopies(sql: Statements): void {
    sql.clearCopies.run()
    for (const agentId of ACCOUNT_LOGS) {
      const counted = new Set<string>()
      if (sql.hasLogs.get(agentId)) {
        const own = this.storedQuota(agentId, 'agent') ?? this.storedQuota(agentId, 'files')
        if (own?.reading.account) counted.add(own.reading.account)
      }
      for (const deviceId of [...this.remote.keys()].sort()) {
        const account = this.remote
          .get(deviceId)
          ?.quotas.find((r) => r.agentId === agentId)?.account
        if (!account || !sql.remoteHasLogs.get(deviceId, agentId)) continue
        if (counted.has(account)) sql.putCopy.run(deviceId, agentId)
        else counted.add(account)
      }
    }
  }

  /** Fills the price table for the models it lacks, or all again once the prices changed. */
  private syncPrices(sql: Statements): void {
    const all = this.pricedFor !== this.pricing.version
    if (!all && this.unpriced.length === 0) return
    if (all) sql.clearPrices.run()
    for (const model of all ? this.models : this.unpriced) {
      const resolved = this.pricing.resolve(model)
      if (!resolved) continue
      const { prices, match } = resolved
      sql.putPrice.run(
        model,
        prices.input,
        prices.output,
        prices.cacheRead,
        prices.cacheWrite,
        prices.cacheWrite1h ?? null,
        match.kind,
        match.model,
        match.origin,
      )
    }
    this.unpriced = []
    this.pricedFor = this.pricing.version
  }

  private bucket(sql: Statements, row: UsageRow, sign: 1 | -1): void {
    this.noteModel(row.model)
    const quarter = quarterOf(row.at)
    // A key column cannot be null; '' stands for no project.
    const project = row.project ?? ''
    sql.addBucket.run(
      quarter,
      row.source,
      row.agentId,
      row.model,
      project,
      sign,
      sign * row.input,
      sign * row.output,
      sign * (row.reasoning ?? 0),
      sign * row.cacheRead,
      sign * row.cacheWrite,
      sign * row.cacheWrite1h,
      sign * row.turn,
    )
    if (sign < 0) sql.dropEmptyBucket.run(quarter, row.source, row.agentId, row.model, project)
  }

  /**
   * Stores rows, adding each new one to its bucket and moving a grown one by the difference,
   * and the cursor they were read up to, in one transaction. Returns how many rows changed.
   */
  write(rows: readonly UsageRow[], cursor: FileCursor | null = null): number {
    return this.guard((sql, db) => {
      let changed = 0
      this.transaction(db, () => {
        for (const row of rows) {
          const stored = sql.row.get(row.key)
          if (!stored) {
            sql.insertRow.run(
              row.key,
              row.source,
              row.agentId,
              row.sessionId,
              row.project,
              row.model,
              row.at,
              row.input,
              row.output,
              row.reasoning,
              row.cacheRead,
              row.cacheWrite,
              row.cacheWrite1h,
              row.turn,
            )
            this.bucket(sql, row, 1)
            changed++
            continue
          }
          const previous = fromRow(stored)
          if (!keepsNewer(previous, row)) continue
          sql.updateRow.run(
            row.sessionId,
            row.project,
            row.model,
            row.at,
            row.input,
            row.output,
            row.reasoning,
            row.cacheRead,
            row.cacheWrite,
            row.cacheWrite1h,
            row.turn,
            row.key,
          )
          this.bucket(sql, previous, -1)
          this.bucket(sql, { ...row, source: previous.source, agentId: previous.agentId }, 1)
          changed++
        }
        if (cursor) {
          sql.putCursor.run(
            cursor.id,
            cursor.agentId,
            cursor.size,
            cursor.mtimeNs,
            cursor.offset,
            cursor.tail,
            cursor.state,
            this.now(),
          )
        }
      })
      return changed
    }, 0)
  }

  cursor(id: string): FileCursor | null {
    return this.guard((sql) => {
      const row = sql.cursor.get(id)
      if (!row) return null
      return {
        id: String(row.id),
        agentId: String(row.agent_id) as AgentId,
        size: num(row.size),
        mtimeNs: BigInt(row.mtime_ns as bigint),
        offset: num(row.offset),
        tail: row.tail === null ? null : num(row.tail),
        state: row.state === null ? null : String(row.state),
      }
    }, null)
  }

  /**
   * Sums per period and agent over `dayStarts`, local days or a day's hours (n periods take n + 1
   * ascending boundaries, each on a quarter hour), per model and per project over [from, to), and
   * with `clock`, per local hour of the day and agent over its range.
   */
  summary(
    dayStarts: readonly number[],
    from: number,
    to: number,
    sources: SourceMap,
    clock?: ClockRequest,
    includeRemote = false,
  ): DbSummary {
    return this.guard(
      (sql) => {
        this.syncPrices(sql)
        this.markCopies(sql)
        const counts = (row: Row): boolean =>
          sources[String(row.agent_id) as AgentId] === String(row.source)
        const days = this.periods(sql, dayStarts, sources, includeRemote)
        const models = this.modelSums(sql, from, to, sources, includeRemote)

        const projects = new Map<string, Omit<DbSummary['projects'][number], 'scratch'>>()
        const addProjectRows = (rows: Row[], filterLocal: boolean): void => {
          for (const row of rows) {
            if (filterLocal && !counts(row)) continue
            const agentId = String(row.agent_id) as AgentId
            const project = row.project === '' ? null : String(row.project)
            const key = `${agentId}\n${project ?? ''}`
            const sum = projects.get(key)
            if (sum) addParts(sum, parts(row))
            else projects.set(key, { agentId, project, ...parts(row) })
          }
        }
        addProjectRows(sql.projectBuckets.all(quarterOf(from), quarterOf(to)), true)
        if (includeRemote) {
          addProjectRows(sql.remoteProjectBuckets.all(quarterOf(from), quarterOf(to)), false)
        }

        const hours = new Map<string, HourUsage>()
        if (clock) {
          const end = quarterOf(clock.to)
          clock.zones.forEach((zone, i) => {
            const next = clock.zones[i + 1]
            const a = Math.max(quarterOf(clock.from), quarterOf(zone.from))
            const b = Math.min(end, next ? quarterOf(next.from) : end)
            if (a >= b) return
            const addHourRows = (rows: Row[], filterLocal: boolean): void => {
              for (const row of rows) {
                if (filterLocal && !counts(row)) continue
                const hour = num(row.hour)
                const agentId = String(row.agent_id) as AgentId
                const key = `${hour}\n${agentId}`
                const sum = hours.get(key)
                if (sum) addParts(sum, parts(row))
                else hours.set(key, { hour, agentId, ...parts(row) })
              }
            }
            addHourRows(sql.clockBuckets.all(zone.offset / 15, a, b), true)
            if (includeRemote) {
              addHourRows(sql.remoteClockBuckets.all(zone.offset / 15, a, b), false)
            }
          })
        }
        return {
          days,
          clock: [...hours.values()],
          models,
          projects: [...projects.values()],
          pricesAsOf: this.pricing.asOf,
        }
      },
      { days: [], clock: [], models: [], projects: [], pricesAsOf: this.pricing.asOf },
    )
  }

  /**
   * Sums per period and agent over n + 1 ascending boundaries, each on a quarter hour; `day`
   * indexes the periods.
   */
  private periods(
    sql: Statements,
    starts: readonly number[],
    sources: SourceMap,
    includeRemote: boolean,
  ): DayUsage[] {
    if (starts.length <= 1) return []
    const quarters = starts.map(quarterOf)
    const days = new Map<string, DayUsage>()
    const add = (rows: Row[], filterLocal: boolean): void => {
      let day = 0
      // Rows come grouped, not ordered; sorting keeps the walk over the days forward only.
      rows.sort((a, b) => num(a.quarter) - num(b.quarter))
      for (const row of rows) {
        if (filterLocal && sources[String(row.agent_id) as AgentId] !== String(row.source)) {
          continue
        }
        const quarter = num(row.quarter)
        while (day < quarters.length - 2 && quarter >= quarters[day + 1]!) day++
        const agentId = String(row.agent_id) as AgentId
        const key = `${day}\n${agentId}`
        const sum = days.get(key)
        if (sum) addParts(sum, parts(row))
        else days.set(key, { day, agentId, ...parts(row) })
      }
    }
    const first = quarters[0]!
    const end = quarters[quarters.length - 1]!
    add(sql.dayBuckets.all(first, end), true)
    if (includeRemote) add(sql.remoteDayBuckets.all(first, end), false)
    return [...days.values()]
  }

  /** Sums per agent and model over [from, to), each with how its model is priced. */
  private modelSums(
    sql: Statements,
    from: number,
    to: number,
    sources: SourceMap,
    includeRemote: boolean,
  ): ModelUsage[] {
    const models = new Map<string, ModelUsage>()
    const add = (rows: Row[], filterLocal: boolean): void => {
      for (const row of rows) {
        if (filterLocal && sources[String(row.agent_id) as AgentId] !== String(row.source)) {
          continue
        }
        const agentId = String(row.agent_id) as AgentId
        const model = String(row.model)
        const key = `${agentId}\n${model}`
        const sum = models.get(key)
        if (sum) addParts(sum, parts(row))
        else models.set(key, { agentId, model, ...parts(row), price: priceOf(row) })
      }
    }
    add(sql.modelBuckets.all(quarterOf(from), quarterOf(to)), true)
    if (includeRemote) add(sql.remoteModelBuckets.all(quarterOf(from), quarterOf(to)), false)
    return [...models.values()]
  }

  /** Each agent's sums over [from, to), for the counted sources. */
  totals(
    from: number,
    to: number,
    sources: SourceMap,
    includeRemote = false,
  ): (TokenParts & { agentId: AgentId })[] {
    return this.guard((sql) => {
      this.syncPrices(sql)
      this.markCopies(sql)
      const agents = new Map<AgentId, TokenParts & { agentId: AgentId }>()
      const addRows = (rows: Row[], filterLocal: boolean): void => {
        for (const row of rows) {
          if (filterLocal && sources[String(row.agent_id) as AgentId] !== String(row.source)) {
            continue
          }
          const agentId = String(row.agent_id) as AgentId
          const sum = agents.get(agentId)
          if (sum) addParts(sum, parts(row))
          else agents.set(agentId, { agentId, ...parts(row) })
        }
      }
      addRows(sql.totals.all(quarterOf(from), quarterOf(to)), true)
      if (includeRemote) addRows(sql.remoteTotals.all(quarterOf(from), quarterOf(to)), false)
      return [...agents.values()]
    }, [])
  }

  stats(): SourceStats[] {
    return this.guard(
      (sql) =>
        sql.stats.all().map((row) => ({
          agentId: String(row.agent_id) as AgentId,
          source: String(row.source) as UsageSource,
          rows: num(row.rows),
          first: num(row.first) * QUARTER_MS,
          last: (num(row.last) + 1) * QUARTER_MS,
        })),
      [],
    )
  }

  /** Exports recent local quarter-hour buckets (last 365 days by default) for E2EE `usage` sync. */
  exportBuckets(sinceQuarter?: number): SyncedUsageBucket[] {
    const cutoff =
      sinceQuarter ?? Math.max(0, Math.floor((this.now() - 365 * 86_400_000) / QUARTER_MS))
    return this.guard(
      (sql) =>
        sql.exportBuckets.all(cutoff).map((row) => ({
          quarter: num(row.quarter),
          source: String(row.source) as UsageSource,
          agentId: String(row.agent_id) as AgentId,
          model: String(row.model),
          project: String(row.project),
          rows: num(row.rows),
          input: num(row.input),
          output: num(row.output),
          reasoning: num(row.reasoning),
          cacheRead: num(row.cache_read),
          cacheWrite: num(row.cache_write),
          cacheWrite1h: num(row.cache_write_1h),
          turns: num(row.turns),
        })),
      [],
    )
  }

  /**
   * Replaces synced remote Macs' buckets in one transaction, storing only each remote Mac's
   * selected source per agent (`computerSources`) so multi-Mac summaries never double-count.
   * With `present`, `devices` holds only the Macs whose usage changed: the others keep their
   * buckets, and a Mac not in `present` loses its own.
   */
  setRemoteUsage(
    devices: Record<string, SyncedHostUsageSection>,
    present?: readonly string[],
  ): void {
    const safeNonNegInt = (v: unknown): number =>
      typeof v === 'number' && Number.isFinite(v) && v > 0 ? Math.trunc(v) : 0
    this.guard((sql, db) => {
      const now = this.now()
      const kept = present ? new Set(present) : null
      const remote = new Map(kept ? [...this.remote].filter(([id]) => kept.has(id)) : [])
      for (const [deviceId, section] of Object.entries(devices)) {
        if (deviceId && section) remote.set(deviceId, syncedQuotas(deviceId, section, now))
      }
      this.remote = remote
      this.transaction(db, () => {
        if (kept) {
          for (const row of sql.remoteDevices.all()) {
            const deviceId = String(row.device_id)
            if (!kept.has(deviceId)) sql.clearRemoteDevice.run(deviceId)
          }
          for (const deviceId of Object.keys(devices)) sql.clearRemoteDevice.run(deviceId)
        } else {
          sql.clearRemoteBuckets.run()
        }
        for (const [deviceId, section] of Object.entries(devices)) {
          if (!deviceId || !Array.isArray(section?.buckets)) continue
          const sources = section.computerSources ?? {}
          for (const bucket of section.buckets) {
            if (
              !bucket ||
              typeof bucket.quarter !== 'number' ||
              !Number.isFinite(bucket.quarter) ||
              typeof bucket.agentId !== 'string' ||
              typeof bucket.model !== 'string'
            ) {
              continue
            }
            const expected = sources[bucket.agentId] ?? 'sarto'
            if (bucket.source !== expected) continue
            this.noteModel(bucket.model)
            sql.putRemoteBucket.run(
              Math.trunc(bucket.quarter),
              deviceId,
              bucket.source,
              bucket.agentId,
              bucket.model,
              typeof bucket.project === 'string' ? bucket.project : '',
              safeNonNegInt(bucket.rows),
              safeNonNegInt(bucket.input),
              safeNonNegInt(bucket.output),
              safeNonNegInt(bucket.reasoning),
              safeNonNegInt(bucket.cacheRead),
              safeNonNegInt(bucket.cacheWrite),
              safeNonNegInt(bucket.cacheWrite1h),
              safeNonNegInt(bucket.turns),
            )
          }
        }
      })
    }, undefined)
  }

  remoteStats(): Array<{ agentId: AgentId; rows: number; first: number; last: number }> {
    return this.guard((sql) => {
      this.markCopies(sql)
      return sql.remoteStats.all().map((row) => ({
        agentId: String(row.agent_id) as AgentId,
        rows: num(row.rows),
        first: num(row.first) * QUARTER_MS,
        last: (num(row.last) + 1) * QUARTER_MS,
      }))
    }, [])
  }

  /** Forgets an agent's imported rows and cursors, so the next scan reads its logs afresh. */
  removeLogs(agentId: AgentId): void {
    this.guard((sql, db) => {
      this.transaction(db, () => {
        sql.deleteRows.run('log', agentId)
        sql.deleteBuckets.run('log', agentId)
        sql.deleteCursors.run(agentId)
      })
    }, undefined)
  }

  /** The quota reading an origin stored last for the agent, with its reader's state. */
  storedQuota(agentId: AgentId, origin: QuotaOrigin = 'files'): StoredQuota | null {
    return this.guard((sql) => {
      const row = sql.storedQuota.get(agentId, origin)
      const reading = row ? parseReading(row.reading) : null
      return reading ? { reading, state: row?.state == null ? null : String(row.state) } : null
    }, null)
  }

  /**
   * Stores an agent's quota reading from one origin, and a measurement of each of its windows
   * that has not reset yet; returns whether anything changed.
   */
  putQuota(reading: QuotaReading, origin: QuotaOrigin, state: string | null = null): boolean {
    return this.guard((sql, db) => {
      const text = JSON.stringify(reading)
      const stored = sql.storedQuota.get(reading.agentId, origin)
      if (stored && stored.reading === text && (stored.state ?? null) === state) return false
      const now = this.now()
      this.transaction(db, () => {
        sql.putQuota.run(reading.agentId, origin, text, state)
        sql.pruneSamples.run(now - HISTORY_MS)
        for (const window of reading.windows) {
          if (window.observedAt === null || hasReset(window, now)) continue
          const before = sql.samples.all(reading.agentId, window.id).map(sampleOf)
          const after = recordSample(
            before,
            { at: window.observedAt, usedPercent: window.usedPercent, resetsAt: window.resetsAt },
            now,
          )
          if (after.length === before.length && after.every((s, i) => s.at === before[i]!.at)) {
            continue
          }
          sql.dropSamples.run(reading.agentId, window.id)
          for (const sample of after) {
            sql.putSample.run(
              reading.agentId,
              window.id,
              sample.at,
              sample.usedPercent,
              sample.resetsAt,
            )
          }
        }
      })
      return true
    }, false)
  }

  /** Each agent's quota, both origins merged, and its windows' measurements of the last 48 hours. */
  quotas(): { readings: QuotaReading[]; history: QuotaHistory[] } {
    return this.guard(
      (sql) => {
        const byAgent = new Map<AgentId, Partial<Record<QuotaOrigin, QuotaReading>>>()
        for (const row of sql.allQuotas.all()) {
          const reading = parseReading(row.reading)
          if (!reading) continue
          const agentId = String(row.agent_id) as AgentId
          const origins = byAgent.get(agentId) ?? {}
          origins[String(row.origin) as QuotaOrigin] = reading
          byAgent.set(agentId, origins)
        }
        // A reading that names nothing, as a reader leaves for a signed-out agent, is none.
        const readings = [...byAgent.values()]
          .map((o) => mergeOrigins(o.files ?? null, o.agent ?? null))
          .filter((r) => r.account !== null || r.plan !== null || r.windows.length > 0)
        const history = new Map<string, QuotaHistory>()
        for (const row of sql.allSamples.all(this.now() - HISTORY_MS)) {
          const agentId = String(row.agent_id) as AgentId
          const window = String(row.window_id)
          const key = `${agentId}\n${window}`
          const list = history.get(key) ?? { agentId, window, samples: [] }
          list.samples.push(sampleOf(row))
          history.set(key, list)
        }
        return { readings, history: [...history.values()] }
      },
      { readings: [], history: [] },
    )
  }

  /**
   * The usage overview's figures: today's sums, the models of the last 1, 7, 30 and 90 days, the
   * daily and hourly series, the latest requests, and each agent's account groups with their
   * windows' forecasts.
   */
  overview(request: OverviewRequest): OverviewAnswer {
    const { sources, includeRemote, dayStarts, hourStarts, now } = request
    const empty: OverviewAnswer = {
      today: [],
      models: [],
      daily: [],
      hourly: [],
      localActivity: [],
      remoteActivity: [],
      quotas: [],
      devices: [],
      pricesAsOf: this.pricing.asOf,
    }
    return this.guard((sql) => {
      this.syncPrices(sql)
      this.markCopies(sql)
      const end = dayStarts.at(-1)
      const todayStart = dayStarts.at(-2)
      if (end === undefined || todayStart === undefined) return empty
      const remoteActivity = new Map<AgentId, AgentActivity>()
      for (const remote of this.remote.values()) {
        for (const activity of remote.activity) {
          const known = remoteActivity.get(activity.agentId)
          if (!known || activity.at > known.at) remoteActivity.set(activity.agentId, activity)
        }
      }
      const { readings, history } = this.quotas()
      return {
        today: this.totals(todayStart, end, sources, includeRemote),
        models: [1, 7, 30, 90].map((days) => ({
          days,
          models: this.modelSums(
            sql,
            dayStarts[Math.max(0, dayStarts.length - 1 - days)]!,
            end,
            sources,
            includeRemote,
          ),
        })),
        daily: this.periods(sql, dayStarts, sources, includeRemote),
        hourly: this.periods(sql, hourStarts, sources, includeRemote),
        localActivity: this.activity(sources),
        remoteActivity: [...remoteActivity.values()],
        quotas: this.quotaGroups(
          sql,
          readings,
          history,
          request.computers,
          now,
          request.forgotten ?? [],
        ),
        devices: [...this.remote].map(([id, remote]) => ({
          id,
          name: remote.name,
          updatedAt: remote.updatedAt,
        })),
        pricesAsOf: this.pricing.asOf,
      }
    }, empty)
  }

  /** Each agent's readings from every computer by account, with their forecasts. */
  private quotaGroups(
    sql: Statements,
    local: readonly QuotaReading[],
    history: readonly QuotaHistory[],
    computers: SourceMap,
    now: number,
    forgotten: readonly ForgottenAccount[],
  ): OverviewAnswer['quotas'] {
    const agents = new Set<AgentId>(local.map((reading) => reading.agentId))
    for (const remote of this.remote.values()) {
      for (const reading of remote.quotas) agents.add(reading.agentId)
    }
    const kept = (reading: QuotaReading | undefined) =>
      reading && !isForgotten(reading, forgotten) ? reading : null
    return [...agents].map((agentId) => {
      const remotes: DeviceReading[] = []
      for (const [id, remote] of this.remote) {
        const reading = kept(remote.quotas.find((r) => r.agentId === agentId))
        if (reading) remotes.push({ device: { id, name: remote.name }, reading })
      }
      const mine = kept(local.find((reading) => reading.agentId === agentId))
      const groups = accountGroups(mine, remotes, now).map((group) => {
        const reading = mergedReading(group)
        return {
          device: group[0]!.device,
          reading,
          here: group.some((item) => item.device === null),
          forecasts: this.forecasts(sql, agentId, reading, group, history, computers, now),
        }
      })
      return { agentId, groups }
    })
  }

  /**
   * A group's windows' forecasts, from the usage and measurements of the group's computers only:
   * a quota is its account's, and another account's usage does not spend it.
   */
  private forecasts(
    sql: Statements,
    agentId: AgentId,
    reading: QuotaReading,
    group: readonly DeviceReading[],
    history: readonly QuotaHistory[],
    computers: SourceMap,
    now: number,
  ): Record<string, WindowForecast> {
    let since: number | null = null
    for (const window of reading.windows) {
      const length = windowLength(window)
      if (window.resetsAt === null || length === null) continue
      const start = window.resetsAt - length
      if (since === null || start < since) since = start
    }
    const buckets: LedgerBucket[] = []
    if (since !== null) {
      const from = quarterOf(since)
      const add = (rows: Row[]): void => {
        for (const row of rows) {
          buckets.push({
            start: num(row.quarter) * QUARTER_MS,
            duration: QUARTER_MS,
            total: num(row.total),
            model: String(row.model),
          })
        }
      }
      for (const item of group) {
        if (item.device) add(sql.remoteLedger.all(item.device.id, agentId, from))
        else if (computers[agentId]) add(sql.ledger.all(agentId, computers[agentId], from))
      }
    }
    const forecasts: Record<string, WindowForecast> = {}
    for (const window of reading.windows) {
      const lists = group.map((item) =>
        samplesOf(
          item.device ? (this.remote.get(item.device.id)?.history ?? []) : history,
          agentId,
          window.id,
        ),
      )
      forecasts[window.id] = forecastWindow({
        agentId,
        window,
        observedAt: reading.observedAt,
        samples: mergeSamples(lists, window.resetsAt, now),
        buckets,
        now,
      })
    }
    return forecasts
  }

  /** Each counted agent's latest request and model, from the rows of its source. */
  activity(sources: SourceMap): AgentActivity[] {
    return this.guard((sql) => {
      const out: AgentActivity[] = []
      for (const [agentId, source] of Object.entries(sources) as [AgentId, UsageSource][]) {
        const rows = sql.latestRows.all(source, agentId).map((row) => ({
          at: num(row.at),
          model: String(row.model),
          output: num(row.output),
          total: num(row.total),
        }))
        const activity = latestActivity(agentId, rows)
        if (activity) out.push(activity)
      }
      return out
    }, [])
  }

  /** Deletes Sarto's own record; the imported logs stay. */
  clearRecord(): void {
    this.guard((sql, db) => {
      this.transaction(db, () => {
        sql.deleteSourceRows.run('sarto')
        sql.deleteSourceBuckets.run('sarto')
      })
    }, undefined)
  }

  close(checkpoint = true): void {
    const db = this.db
    this.db = null
    this.sql = null
    if (!db) return
    try {
      if (checkpoint) db.exec('PRAGMA wal_checkpoint(TRUNCATE)')
    } finally {
      db.close()
    }
  }
}

function addParts(sum: TokenParts, add: TokenParts): void {
  sum.input += add.input
  sum.output += add.output
  sum.reasoning += add.reasoning
  sum.cacheRead += add.cacheRead
  sum.cacheWrite += add.cacheWrite
  sum.requests += add.requests
  sum.turns += add.turns
  sum.unpricedTokens += add.unpricedTokens
  sum.cacheSaved += add.cacheSaved
  // Priced groups add up; the sum stays null while every group it holds is unpriced.
  if (add.cost !== null) sum.cost = (sum.cost ?? 0) + add.cost
}

function priceOf(row: Row): PriceMatch {
  if (row.price_match !== 'exact' && row.price_match !== 'family') {
    return { kind: 'unpriced', model: null, origin: null }
  }
  return {
    kind: row.price_match,
    model: String(row.priced_as),
    origin: String(row.price_origin) as PriceOrigin,
  }
}

function sampleOf(row: Row): QuotaSample {
  return {
    at: num(row.at),
    usedPercent: num(row.used_percent),
    resetsAt: row.resets_at === null || row.resets_at === undefined ? null : num(row.resets_at),
  }
}

/** A stored reading; null for one this version cannot read. */
function parseReading(value: SQLOutputValue | undefined): QuotaReading | null {
  if (typeof value !== 'string') return null
  try {
    const reading = JSON.parse(value) as QuotaReading | null
    return reading && typeof reading.agentId === 'string' && Array.isArray(reading.windows)
      ? reading
      : null
  } catch {
    return null
  }
}

function fromRow(row: Row): UsageRow {
  return {
    key: String(row.key),
    source: String(row.source) as UsageSource,
    agentId: String(row.agent_id) as AgentId,
    sessionId: row.session_id === null ? null : String(row.session_id),
    project: row.project === null ? null : String(row.project),
    model: String(row.model),
    at: num(row.at),
    input: num(row.input),
    output: num(row.output),
    reasoning: row.reasoning === null ? null : num(row.reasoning),
    cacheRead: num(row.cache_read),
    cacheWrite: num(row.cache_write),
    cacheWrite1h: num(row.cache_write_1h),
    turn: num(row.turn),
  }
}
