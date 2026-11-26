import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { DatabaseSync } from 'node:sqlite'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { applyPatches, threadFromSnapshot, type ThreadState } from '@shared/thread'
import type { SessionTarget } from '../connection'
import { newTurnScope, type MapperOutput } from '../session-updates'
import {
  AgyTelemetry,
  agyConversationFile,
  agyGenerationReader,
  agyLastRequest,
  agySpeedSample,
  parseAgyGeneration,
  readsAgyTelemetry,
} from './agy-telemetry'

// Minimal protobuf wire encoder for test fixtures.
function encodeVarint(value: number): number[] {
  const bytes: number[] = []
  let v = BigInt(value)
  while (v >= 0x80n) {
    bytes.push(Number((v & 0x7fn) | 0x80n))
    v >>= 7n
  }
  bytes.push(Number(v))
  return bytes
}

function fieldVarint(field: number, value: number): Uint8Array {
  return Uint8Array.from([...encodeVarint((field << 3) | 0), ...encodeVarint(value)])
}

function fieldBytes(field: number, payload: Uint8Array): Uint8Array {
  return Uint8Array.from([
    ...encodeVarint((field << 3) | 2),
    ...encodeVarint(payload.length),
    ...payload,
  ])
}

function fieldString(field: number, text: string): Uint8Array {
  return fieldBytes(field, new TextEncoder().encode(text))
}

function concat(...parts: Uint8Array[]): Uint8Array {
  const total = parts.reduce((sum, p) => sum + p.length, 0)
  const out = new Uint8Array(total)
  let offset = 0
  for (const part of parts) {
    out.set(part, offset)
    offset += part.length
  }
  return out
}

function encodeDuration(seconds: number, nanos = 0): Uint8Array {
  return concat(
    ...(seconds > 0 ? [fieldVarint(1, seconds)] : []),
    ...(nanos > 0 ? [fieldVarint(2, nanos)] : []),
  )
}

function encodeGenMetadata(opts: {
  input: number
  output: number
  cacheRead?: number
  thinking?: number
  response?: number
  callId?: string
  model?: string
  modelLabel?: string
  ttft?: [number, number]
  gen?: [number, number]
}): Uint8Array {
  const usage = concat(
    fieldVarint(2, opts.input),
    fieldVarint(3, opts.output),
    ...(opts.cacheRead !== undefined ? [fieldVarint(5, opts.cacheRead)] : []),
    ...(opts.thinking !== undefined ? [fieldVarint(9, opts.thinking)] : []),
    ...(opts.response !== undefined ? [fieldVarint(10, opts.response)] : []),
    ...(opts.callId ? [fieldString(11, opts.callId)] : []),
  )
  const inner = concat(
    fieldBytes(4, usage),
    ...(opts.ttft ? [fieldBytes(11, encodeDuration(opts.ttft[0], opts.ttft[1]))] : []),
    ...(opts.gen ? [fieldBytes(12, encodeDuration(opts.gen[0], opts.gen[1]))] : []),
    ...(opts.model ? [fieldString(19, opts.model)] : []),
    ...(opts.modelLabel ? [fieldString(21, opts.modelLabel)] : []),
  )
  return fieldBytes(1, inner)
}

function makeTarget(turnStartedAt: number | null = 1_000_000): {
  target: SessionTarget
  thread: () => ThreadState
} {
  let thread = threadFromSnapshot({
    session: {
      id: 's-1',
      agentId: 'antigravity',
      projectPath: '/repo',
      acpSessionId: 's-1',
      status: 'running',
      title: null,
      config: [],
      commands: [],
      usage: { used: 100_000, size: 1_000_000, cost: null, tokens: null },
      error: null,
      turnStartedAt,
      turnStartUsed: null,
      createdAt: 1_000_000,
      updatedAt: 1_000_000,
      parentId: null,
      origin: 'user',
      subagent: null,
      queue: [],
      queuePaused: false,
    },
    entries: [],
    seq: 1,
  })
  const scope = newTurnScope()
  let seq = 1
  const target: SessionTarget = {
    context: () => ({
      thread,
      scope,
      replaying: false,
      cancelling: false,
      now: 1_000_500,
      nextId: () => `e:${seq++}`,
      sessionIdFor: (id) => id,
    }),
    apply: (output: MapperOutput) => {
      if (output.patches.length > 0) {
        thread = applyPatches(thread, output.patches)
      }
    },
    requestPermission: async () => 'cancelled',
    startMode: () => null,
    send: () => {},
  }
  return { target, thread: () => thread }
}

describe('agy-telemetry', () => {
  let dir: string

  beforeEach(async () => {
    dir = await mkdtemp(path.join(tmpdir(), 'sarto-agy-telemetry-'))
  })

  afterEach(async () => {
    await rm(dir, { recursive: true, force: true })
  })

  it('decodes usage, TTFT, generation duration, and model fields from gen_metadata protobuf', () => {
    const blob = encodeGenMetadata({
      input: 9_967,
      output: 2_129,
      cacheRead: 400_668,
      thinking: 990,
      response: 1_139,
      callId: 'call-abc',
      model: 'gemini-4-neon',
      modelLabel: 'Gemini 4 Neon (XHigh)',
      ttft: [11, 420_000_000],
      gen: [15, 200_000_000],
    })
    const gen = parseAgyGeneration(43, blob)
    expect(gen).toEqual({
      idx: 43,
      callId: 'call-abc',
      model: 'gemini-4-neon',
      modelLabel: 'Gemini 4 Neon (XHigh)',
      input: 9_967,
      output: 2_129,
      cacheRead: 400_668,
      thinking: 990,
      response: 1_139,
      ttftMs: 11_420,
      genMs: 15_200,
    })

    expect(agySpeedSample(gen!)).toEqual({
      tokens: 2_129,
      ms: 15_200,
      approx: false,
      firstTokenMs: 11_420,
    })

    expect(agyLastRequest(gen!, 2_000_000)).toEqual({
      at: 2_000_000,
      input: 9_967,
      cacheRead: 400_668,
      cacheWrite: 0,
      output: 2_129,
      ms: 26_620,
    })
  })

  it('rejects malformed or empty payloads and unsafe session ids', () => {
    expect(parseAgyGeneration(0, new Uint8Array([0xff, 0xff, 0xff]))).toBeNull()
    expect(parseAgyGeneration(0, encodeGenMetadata({ input: 0, output: 0 }))).toBeNull()
    expect(agyConversationFile('../escape', dir)).toBeNull()
    expect(agyConversationFile('a/b', dir)).toBeNull()
    expect(agyConversationFile('valid-uuid_1.2', dir)).toBe(path.join(dir, 'valid-uuid_1.2.db'))
    expect(readsAgyTelemetry('1.5.16')).toBe(true)
    expect(readsAgyTelemetry('1.5.8')).toBe(false)
    expect(readsAgyTelemetry(null)).toBe(false)
  })

  it('reads new SQLite gen_metadata rows incrementally and emits speed + lastRequest', async () => {
    const sessionId = '4be162e1-test'
    const dbFile = path.join(dir, `${sessionId}.db`)
    const db = new DatabaseSync(dbFile)
    db.exec('CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB, size INTEGER)')
    const insert = db.prepare('INSERT INTO gen_metadata (idx, data, size) VALUES (?, ?, ?)')

    const row0 = encodeGenMetadata({
      input: 1_000,
      output: 500,
      cacheRead: 9_000,
      callId: 'c0',
      ttft: [2, 500_000_000],
      gen: [5, 0],
    })
    insert.run(0, row0, row0.length)
    db.close()

    const { target, thread } = makeTarget(1_000_000)
    const telemetry = new AgyTelemetry(agyGenerationReader(dir), () => 1_010_000)
    telemetry.initNew(sessionId)

    await telemetry.sync(sessionId, target)
    expect(thread().session.speed?.last).toEqual({
      tokens: 500,
      ms: 5_000,
      approx: false,
      firstTokenMs: 2_500,
    })
    expect(thread().session.lastRequest).toEqual({
      at: 1_010_000,
      input: 1_000,
      cacheRead: 9_000,
      cacheWrite: 0,
      output: 500,
      ms: 7_500,
    })

    // Appending row 1 only processes row 1 (not row 0 again).
    const db2 = new DatabaseSync(dbFile)
    const row1 = encodeGenMetadata({
      input: 500,
      output: 1_000,
      cacheRead: 19_500,
      callId: 'c1',
      ttft: [1, 200_000_000],
      gen: [10, 0],
    })
    db2
      .prepare('INSERT INTO gen_metadata (idx, data, size) VALUES (?, ?, ?)')
      .run(1, row1, row1.length)
    db2.close()

    await telemetry.sync(sessionId, target)
    expect(thread().session.speed?.session.requests).toBe(2)
    expect(thread().session.speed?.last.tokens).toBe(1_000)
    expect(thread().session.lastRequest?.cacheRead).toBe(19_500)
  })

  it('seeds lastIdx on load without re-emitting historical speed, and defers to native ACP telemetry', async () => {
    const sessionId = 'seeded-session'
    const dbFile = path.join(dir, `${sessionId}.db`)
    const db = new DatabaseSync(dbFile)
    db.exec('CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB, size INTEGER)')
    const row0 = encodeGenMetadata({
      input: 2_000,
      output: 600,
      cacheRead: 18_000,
      ttft: [1, 0],
      gen: [4, 0],
    })
    db.prepare('INSERT INTO gen_metadata (idx, data, size) VALUES (?, ?, ?)').run(
      5,
      row0,
      row0.length,
    )
    db.close()

    const { target, thread } = makeTarget(2_000_000)
    const telemetry = new AgyTelemetry(agyGenerationReader(dir), () => 2_005_000)
    await telemetry.seed(sessionId, target)

    // Restores lastRequest for cache popover, without fabricating turn speed for historical calls.
    expect(thread().session.speed).toBeUndefined()
    expect(thread().session.lastRequest?.cacheRead).toBe(18_000)

    // Subsequent sync with no new rows is a no-op.
    await telemetry.sync(sessionId, target)
    expect(thread().session.speed).toBeUndefined()

    // Simulate a future agy version sending native ACP speed directly on the thread.
    const nativeSpeed = {
      last: { tokens: 300, ms: 3_000, approx: false, firstTokenMs: 400 },
      recent: [{ rate: 100, approx: false }],
      turn: { tokens: 300, ms: 3_000, requests: 1, approx: 0, since: 2_000_000 },
      session: { tokens: 300, ms: 3_000, requests: 1, approx: 0 },
    }
    target.apply({
      patches: [{ op: 'session.update', changes: { speed: nativeSpeed } }],
      effects: [],
    })

    const db2 = new DatabaseSync(dbFile)
    const row6 = encodeGenMetadata({
      input: 100,
      output: 800,
      cacheRead: 19_000,
      ttft: [2, 0],
      gen: [8, 0],
    })
    db2
      .prepare('INSERT INTO gen_metadata (idx, data, size) VALUES (?, ?, ?)')
      .run(6, row6, row6.length)
    db2.close()

    await telemetry.sync(sessionId, target)
    // Native speed stays untouched!
    expect(thread().session.speed).toEqual(nativeSpeed)
  })

  it('continues updating speed and lastRequest across a reconnect on the same thread', async () => {
    const sessionId = 'reconnect-session'
    const dbFile = path.join(dir, `${sessionId}.db`)
    const db = new DatabaseSync(dbFile)
    db.exec('CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB, size INTEGER)')
    const insert = db.prepare('INSERT INTO gen_metadata (idx, data, size) VALUES (?, ?, ?)')
    const row0 = encodeGenMetadata({
      input: 1_000,
      output: 500,
      cacheRead: 8_000,
      ttft: [1, 0],
      gen: [5, 0],
    })
    insert.run(0, row0, row0.length)
    db.close()

    const { target, thread } = makeTarget(3_000_000)
    const first = new AgyTelemetry(agyGenerationReader(dir), () => 3_005_000)
    first.initNew(sessionId)
    await first.sync(sessionId, target)
    expect(thread().session.speed?.session.requests).toBe(1)
    expect(thread().session.lastRequest?.output).toBe(500)

    // Simulate reconnect: new AgyTelemetry attaches and seeds against the existing thread state.
    const second = new AgyTelemetry(agyGenerationReader(dir), () => 3_020_000)
    second.attach(sessionId, target)
    await second.seed(sessionId, target)

    const db2 = new DatabaseSync(dbFile)
    const row1 = encodeGenMetadata({
      input: 400,
      output: 1_200,
      cacheRead: 16_000,
      ttft: [1, 500_000_000],
      gen: [8, 0],
    })
    db2
      .prepare('INSERT INTO gen_metadata (idx, data, size) VALUES (?, ?, ?)')
      .run(1, row1, row1.length)
    db2.close()

    await second.sync(sessionId, target)
    expect(thread().session.speed?.session.requests).toBe(2)
    expect(thread().session.speed?.last.tokens).toBe(1_200)
    expect(thread().session.lastRequest?.output).toBe(1_200)
  })
})
