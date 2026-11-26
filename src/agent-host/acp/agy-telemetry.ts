// Real-time per-request telemetry for Google Antigravity (`agy`).
//
// Over ACP, agy reports cumulative context size (`usage_update`) during a turn and turn-level
// token totals at the end, without per-request speed or cache-hit breakdowns. At the same time,
// agy flushes each model call's `gen_metadata` protobuf row to its conversation SQLite WAL file
// under `~/.gemini/antigravity-cli/conversations/<sessionId>.db` right as each request completes.
//
// This module reads only new rows (`WHERE idx > lastIdx`) in read-only mode when `usage_update`
// signals a completed request or when a turn ends, never per streamed token and never blocking
// writers (`timeout: 0`). If a future agy version reports native speed or `lastRequest` directly
// over ACP, Sarto prefers the official stream and skips local derivation.

import { stat } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { DatabaseSync } from 'node:sqlite'
import { pathToFileURL } from 'node:url'
import type { LastRequest } from '@shared/model-requests'
import {
  addSpeedSample,
  SPEED_MIN_MS,
  SPEED_MIN_TOKENS,
  type OutputSpeed,
  type SpeedSample,
} from '@shared/output-speed'
import type { SessionTarget } from '../connection'
import { decodeFields, type Fields } from '../usage/readers/antigravity'
import { normalizeModel } from '../usage/model'
import { compareVersions } from '../versions'
import { agyReadGenLatest, agyReadGenSince } from './agy-sqlite-worker'

export const AGY_TELEMETRY_VERSION = '1.5.9'

const SESSION_SEGMENT = /^[A-Za-z0-9._-]+$/
const MAX_DURATION_MS = 60 * 60_000
const NANOS_PER_MS = 1_000_000

/** Whether Sarto reads per-request telemetry from agy's conversation database. */
export function readsAgyTelemetry(version: string | null): boolean {
  return version !== null && compareVersions(version, AGY_TELEMETRY_VERSION) >= 0
}

/** One decoded `gen_metadata` row from an agy conversation database. */
export interface AgyGeneration {
  idx: number
  callId: string | null
  model: string | null
  modelLabel: string | null
  /** Uncached input tokens. */
  input: number
  /** Total output tokens (thinking + response). */
  output: number
  cacheRead: number
  thinking: number | null
  response: number | null
  /** Time to first token, in milliseconds. */
  ttftMs: number | null
  /** Streaming/generation duration after first token, in milliseconds. */
  genMs: number | null
}

/** Reads `gen_metadata` rows for one agy session. */
export interface AgyGenerationReader {
  /** Rows with `idx > afterIdx`, ordered ascending by `idx`. */
  readSince(sessionId: string, afterIdx: number): Promise<AgyGeneration[]>
  /** The newest row's `idx` and decoded record, or null when the database has none yet. */
  latest(sessionId: string): Promise<AgyGeneration | null>
}

/** Where agy stores its per-conversation SQLite databases. */
export function agyConversationsFolder(home = os.homedir()): string {
  return path.join(home, '.gemini', 'antigravity-cli', 'conversations')
}

/** Absolute path to one session's conversation database, or null if the id is unsafe. */
export function agyConversationFile(
  sessionId: string,
  folder = agyConversationsFolder(),
): string | null {
  if (!SESSION_SEGMENT.test(sessionId) || sessionId === '.' || sessionId === '..') return null
  return path.join(folder, `${sessionId}.db`)
}

/** Decodes a `google.protobuf.Duration` (`{ 1: seconds, 2: nanos }`) into milliseconds. */
export function decodeDurationMs(message: Fields | null): number | null {
  if (!message) return null
  const seconds = message.int(1)
  const nanos = message.int(2)
  if (seconds === null && nanos === null) return null
  const ms = (seconds ?? 0) * 1000 + (nanos ?? 0) / NANOS_PER_MS
  if (!Number.isFinite(ms) || ms < 0 || ms > MAX_DURATION_MS) return null
  return ms
}

/**
 * Decodes one `gen_metadata.data` blob.
 * Observed layout on agy 1.5.9-1.5.16:
 *   1 {
 *     4 { 2 input, 3 output, 5 cacheRead, 7/11 callId, 9 thinking, 10 response }
 *     11 { 1 seconds, 2 nanos }  // TTFT
 *     12 { 1 seconds, 2 nanos }  // generation duration
 *     19 model
 *     21 modelLabel
 *   }
 */
export function parseAgyGeneration(idx: number, data: Uint8Array): AgyGeneration | null {
  const gen = decodeFields(data).message(1)
  const usage = gen?.message(4)
  if (!gen || !usage) return null
  const input = usage.int(2) ?? 0
  const output = usage.int(3) ?? 0
  const cacheRead = usage.int(5) ?? 0
  if (input < 0 || output < 0 || cacheRead < 0) return null
  if (input + cacheRead + output <= 0) return null
  const thinking = usage.int(9)
  const response = usage.int(10)
  const rawModel = gen.string(19)
  return {
    idx,
    callId: usage.string(11) ?? usage.string(7) ?? null,
    model: rawModel ? normalizeModel(rawModel) : null,
    modelLabel: gen.string(21) ?? null,
    input,
    output,
    cacheRead,
    thinking: thinking !== null && thinking >= 0 ? thinking : null,
    response: response !== null && response >= 0 ? response : null,
    ttftMs: decodeDurationMs(gen.message(11)),
    genMs: decodeDurationMs(gen.message(12)),
  }
}

/** Converts a decoded generation into a host-timed `SpeedSample`, or null if too short. */
export function agySpeedSample(gen: AgyGeneration): SpeedSample | null {
  if (gen.output < SPEED_MIN_TOKENS) return null
  if (gen.genMs !== null && gen.genMs >= SPEED_MIN_MS) {
    return {
      tokens: gen.output,
      ms: Math.round(gen.genMs),
      approx: false,
      firstTokenMs: gen.ttftMs !== null && gen.ttftMs > 0 ? Math.round(gen.ttftMs) : null,
    }
  }
  if (gen.ttftMs !== null && gen.genMs !== null && gen.ttftMs + gen.genMs >= SPEED_MIN_MS) {
    return {
      tokens: gen.output,
      ms: Math.round(gen.ttftMs + gen.genMs),
      approx: true,
      firstTokenMs: null,
    }
  }
  return null
}

/** Converts a decoded generation into a `LastRequest` snapshot. */
export function agyLastRequest(gen: AgyGeneration, at: number): LastRequest {
  const totalMs =
    gen.ttftMs !== null || gen.genMs !== null
      ? Math.round((gen.ttftMs ?? 0) + (gen.genMs ?? 0))
      : null
  return {
    at,
    input: gen.input,
    cacheRead: gen.cacheRead,
    cacheWrite: 0,
    output: gen.output,
    ms: totalMs,
  }
}

async function exists(file: string): Promise<boolean> {
  try {
    return (await stat(file)).isFile()
  } catch {
    return false
  }
}

/**
 * Opens an agy conversation SQLite database strictly read-only without blocking writers.
 * Uses `immutable=1` when no `-wal` file is present so no `-wal`/`-shm` sidecars are created,
 * and re-opens without `immutable=1` if a `-wal` file appears concurrently.
 */
export async function openAgyConversationReadOnly(file: string): Promise<DatabaseSync | null> {
  if (!(await exists(file))) return null
  const walBefore = await exists(`${file}-wal`)
  const open = (immutable: boolean): DatabaseSync | null => {
    let target: string | URL = file
    if (immutable) {
      const url = pathToFileURL(file)
      url.searchParams.set('mode', 'ro')
      url.searchParams.set('immutable', '1')
      target = url
    }
    try {
      return new DatabaseSync(target, { readOnly: true, timeout: 0 })
    } catch {
      return null
    }
  }
  const db = open(!walBefore)
  if (!db) return null
  if (!walBefore && (await exists(`${file}-wal`))) {
    db.close()
    return open(false)
  }
  return db
}

/** Default read-only SQLite reader backed by agy's conversation folder on a worker thread. */
export function agyGenerationReader(folder = agyConversationsFolder()): AgyGenerationReader {
  return {
    async readSince(sessionId, afterIdx) {
      const file = agyConversationFile(sessionId, folder)
      if (!file) return []
      try {
        const rows = await agyReadGenSince(file, afterIdx)
        const out: AgyGeneration[] = []
        for (const row of rows) {
          const parsed = parseAgyGeneration(row.idx, row.data)
          if (parsed) out.push(parsed)
        }
        return out
      } catch {
        return []
      }
    },

    async latest(sessionId) {
      const file = agyConversationFile(sessionId, folder)
      if (!file) return null
      try {
        const row = await agyReadGenLatest(file)
        return row ? parseAgyGeneration(row.idx, row.data) : null
      } catch {
        return null
      }
    },
  }
}

interface SessionState {
  lastIdx: number
  seeded: boolean
  /** Whether pre-existing thread speed/lastRequest from before this connection was captured. */
  baselineCaptured: boolean
  /** Serializes reads per session so concurrent notifications never double-apply a row. */
  chain: Promise<void>
  /** References to the values this tracker last emitted, to detect native ACP telemetry. */
  lastSpeed: OutputSpeed | null
  lastRequest: LastRequest | null
}

/** Tracks per-request speed and `lastRequest` for one ACP connection's agy sessions. */
export class AgyTelemetry {
  private readonly sessions = new Map<string, SessionState>()

  constructor(
    private readonly reader: AgyGenerationReader,
    private readonly now: () => number = Date.now,
  ) {}

  /** Marks a brand-new session so its very first generation row (`idx = 0`) is read. */
  initNew(sessionId: string): void {
    this.sessions.set(sessionId, {
      lastIdx: -1,
      seeded: true,
      baselineCaptured: true,
      chain: Promise.resolve(),
      lastSpeed: null,
      lastRequest: null,
    })
  }

  /**
   * Captures any pre-existing `speed`/`lastRequest` on `target` (for example after a reconnect)
   * so they are not mistaken for native ACP telemetry emitted on this connection.
   */
  attach(sessionId: string, target: SessionTarget): void {
    const state = this.stateFor(sessionId)
    this.captureBaseline(state, target)
  }

  /**
   * Seeds `lastIdx` on a loaded or resumed session so historical rows are not re-counted as
   * fresh turn speed, while optionally restoring the session's `lastRequest` if missing.
   */
  seed(sessionId: string, target?: SessionTarget): Promise<void> {
    const state = this.stateFor(sessionId)
    if (target) this.captureBaseline(state, target)
    return this.enqueue(state, async () => {
      const latest = await this.reader.latest(sessionId)
      state.lastIdx = latest ? Math.max(state.lastIdx, latest.idx) : state.lastIdx
      state.seeded = true
      if (!latest || !target) return
      this.captureBaseline(state, target)
      const session = target.context().thread.session
      if (session.lastRequest) return
      const lastRequest = agyLastRequest(latest, session.usage?.cache?.lastRequestAt ?? this.now())
      state.lastRequest = lastRequest
      target.apply({
        patches: [{ op: 'session.update', changes: { lastRequest } }],
        effects: [],
      })
    })
  }

  /**
   * Reads any newly flushed `gen_metadata` rows for `sessionId` and emits a `session.update`
   * patch with updated `speed` and `lastRequest`.
   */
  sync(sessionId: string, target: SessionTarget | undefined): Promise<void> {
    if (!target) return Promise.resolve()
    const state = this.stateFor(sessionId)
    return this.enqueue(state, async () => {
      if (target.context().replaying) return
      this.captureBaseline(state, target)
      if (!state.seeded) {
        const latest = await this.reader.latest(sessionId)
        state.lastIdx = latest ? latest.idx : -1
        state.seeded = true
        if (!latest) return
        this.applyGenerations(state, target, [latest])
        return
      }
      const rows = await this.reader.readSince(sessionId, state.lastIdx)
      if (rows.length === 0) return
      this.applyGenerations(state, target, rows)
    })
  }

  forget(sessionId: string): void {
    this.sessions.delete(sessionId)
  }

  private captureBaseline(state: SessionState, target: SessionTarget): void {
    if (state.baselineCaptured) return
    const session = target.context().thread.session
    state.lastSpeed = session.speed ?? null
    state.lastRequest = session.lastRequest ?? null
    state.baselineCaptured = true
  }

  private stateFor(sessionId: string): SessionState {
    let state = this.sessions.get(sessionId)
    if (!state) {
      state = {
        lastIdx: -1,
        seeded: false,
        baselineCaptured: false,
        chain: Promise.resolve(),
        lastSpeed: null,
        lastRequest: null,
      }
      this.sessions.set(sessionId, state)
    }
    return state
  }

  private enqueue(state: SessionState, work: () => Promise<void>): Promise<void> {
    const next = state.chain.then(work, work)
    state.chain = next.catch(() => {})
    return next
  }

  private applyGenerations(
    state: SessionState,
    target: SessionTarget,
    rows: readonly AgyGeneration[],
  ): void {
    const session = target.context().thread.session
    // Forward compatibility: if a future agy version populates `speed` or `lastRequest` natively
    // over ACP (different object reference from what this tracker last emitted), defer to it.
    const nativeSpeed = session.speed !== undefined && session.speed !== state.lastSpeed
    const nativeLastRequest =
      session.lastRequest !== undefined && session.lastRequest !== state.lastRequest

    let speed: OutputSpeed | undefined = session.speed
    let speedChanged = false
    let latestGen: AgyGeneration | null = null

    for (const row of rows) {
      if (row.idx > state.lastIdx) state.lastIdx = row.idx
      latestGen = row
      if (!nativeSpeed) {
        const sample = agySpeedSample(row)
        if (sample) {
          const next = addSpeedSample(speed, sample, session.turnStartedAt)
          if (next) {
            speed = next
            speedChanged = true
          }
        }
      }
    }

    const changes: { speed?: OutputSpeed; lastRequest?: LastRequest } = {}
    if (speedChanged && speed) {
      changes.speed = speed
      state.lastSpeed = speed
    }
    if (!nativeLastRequest && latestGen) {
      const lastRequest = agyLastRequest(latestGen, this.now())
      changes.lastRequest = lastRequest
      state.lastRequest = lastRequest
    }
    if (changes.speed || changes.lastRequest) {
      target.apply({
        patches: [{ op: 'session.update', changes }],
        effects: [],
      })
    }
  }
}
