import { mkdir, mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { DatabaseSync } from 'node:sqlite'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { AcpMessages, acpModelRequests } from './acp-messages'
import { antigravityModelRequests } from './antigravity'
import type { RequestsTarget } from './reader'

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

const fieldVarint = (field: number, value: number): Uint8Array =>
  Uint8Array.from([...encodeVarint((field << 3) | 0), ...encodeVarint(value)])

const fieldBytes = (field: number, payload: Uint8Array): Uint8Array =>
  Uint8Array.from([...encodeVarint((field << 3) | 2), ...encodeVarint(payload.length), ...payload])

const fieldString = (field: number, text: string): Uint8Array =>
  fieldBytes(field, new TextEncoder().encode(text))

function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((s, p) => s + p.length, 0))
  let offset = 0
  for (const part of parts) {
    out.set(part, offset)
    offset += part.length
  }
  return out
}

function genBlob(opts: {
  input: number
  output: number
  cacheRead: number
  thinking?: number
  response?: number
  callId: string
  model: string
  ttftSec: number
  genSec: number
}): Uint8Array {
  const usage = concat(
    fieldVarint(2, opts.input),
    fieldVarint(3, opts.output),
    fieldVarint(5, opts.cacheRead),
    ...(opts.thinking !== undefined ? [fieldVarint(9, opts.thinking)] : []),
    ...(opts.response !== undefined ? [fieldVarint(10, opts.response)] : []),
    fieldString(11, opts.callId),
  )
  const inner = concat(
    fieldBytes(4, usage),
    fieldBytes(11, fieldVarint(1, opts.ttftSec)),
    fieldBytes(12, fieldVarint(1, opts.genSec)),
    fieldString(19, opts.model),
  )
  return fieldBytes(1, inner)
}

function stepBlob(opts: {
  createdSec: number
  completedSec?: number
  toolName?: string
  toolArgs?: string
  callId: string
  genIdx: number
}): Uint8Array {
  return concat(
    fieldBytes(1, fieldVarint(1, opts.createdSec)),
    ...(opts.toolName
      ? [
          fieldBytes(
            4,
            concat(
              fieldString(1, 'tc-1'),
              fieldString(2, opts.toolName),
              ...(opts.toolArgs ? [fieldString(3, opts.toolArgs)] : []),
            ),
          ),
        ]
      : []),
    ...(opts.completedSec ? [fieldBytes(8, fieldVarint(1, opts.completedSec))] : []),
    fieldBytes(9, fieldString(11, opts.callId)),
    fieldBytes(20, fieldVarint(3, opts.genIdx)),
  )
}

describe('antigravityModelRequests', () => {
  let home: string
  let convDir: string

  beforeEach(async () => {
    home = await mkdtemp(path.join(tmpdir(), 'sarto-agy-requests-'))
    convDir = path.join(home, '.gemini', 'antigravity-cli', 'conversations')
    await mkdir(convDir, { recursive: true })
  })

  afterEach(async () => {
    await rm(home, { recursive: true, force: true })
  })

  const target = (acpSessionId: string): RequestsTarget => ({
    agentId: 'antigravity',
    cwd: '/repo',
    acpSessionId,
    configDir: null,
    parentAcpSessionId: null,
  })

  it('reads persistent pages, summary, and raw records from agy SQLite DB', async () => {
    const db = new DatabaseSync(path.join(convDir, 'sess-1.db'))
    db.exec('CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB, size INTEGER)')
    db.exec('CREATE TABLE steps (idx INTEGER PRIMARY KEY, metadata BLOB)')

    const g0 = genBlob({
      input: 4_000,
      output: 600,
      cacheRead: 36_000,
      thinking: 200,
      response: 400,
      callId: 'call-0',
      model: 'gemini-4-neon',
      ttftSec: 3,
      genSec: 4,
    })
    const g1 = genBlob({
      input: 1_000,
      output: 900,
      cacheRead: 40_000,
      thinking: 300,
      response: 600,
      callId: 'call-1',
      model: 'gemini-4-neon',
      ttftSec: 2,
      genSec: 6,
    })
    db.prepare('INSERT INTO gen_metadata (idx, data, size) VALUES (?, ?, ?)').run(0, g0, g0.length)
    db.prepare('INSERT INTO gen_metadata (idx, data, size) VALUES (?, ?, ?)').run(1, g1, g1.length)

    const s0 = stepBlob({
      createdSec: 1_700_000_000,
      completedSec: 1_700_000_007,
      toolName: 'read_file',
      toolArgs: '{"Path":"/repo/a.ts"}',
      callId: 'call-0',
      genIdx: 0,
    })
    const s1 = stepBlob({
      createdSec: 1_700_000_008,
      completedSec: 1_700_000_016,
      callId: 'call-1',
      genIdx: 1,
    })
    db.prepare('INSERT INTO steps (idx, metadata) VALUES (?, ?)').run(0, s0)
    db.prepare('INSERT INTO steps (idx, metadata) VALUES (?, ?)').run(1, s1)
    db.close()

    const reader = antigravityModelRequests({ home })
    const page = await reader.page(target('sess-1'), null)
    expect(page?.source).toBe('antigravity')
    expect(page?.before).toBeNull()
    expect(page?.turns).toHaveLength(1)
    expect(page?.turns[0]!.requests).toHaveLength(2)

    const req0 = page!.turns[0]!.requests[0]!
    expect(req0.model).toBe('gemini-4-neon')
    expect(req0.tokens).toEqual({
      input: 4_000,
      cacheRead: 36_000,
      cacheWrite: 0,
      cacheWrite1h: null,
      output: 600,
      reasoning: 200,
    })
    expect(req0.actions.some((a) => a.kind === 'read' && a.label === 'read_file')).toBe(true)
    expect(req0.raw).toBe('gen:0')

    const summary = await reader.summary(target('sess-1'))
    expect(summary?.source).toBe('antigravity')
    expect(summary?.requests).toBe(2)
    expect(summary?.tokens).toEqual({
      input: 5_000,
      cacheRead: 76_000,
      cacheWrite: 0,
      cacheWrite1h: null,
      output: 1_500,
      reasoning: 500,
    })

    const raw = await reader.raw(target('sess-1'), 'gen:0', false)
    expect(raw.records).toHaveLength(2)
    expect((raw.records[0] as { callId: string }).callId).toBe('call-0')
  })

  it('falls back to in-memory ACP messages when no local conversation DB exists', async () => {
    const store = new AcpMessages(() => 1_000)
    store.add('antigravity', 'out', {
      jsonrpc: '2.0',
      id: 1,
      method: 'session/prompt',
      params: { sessionId: 'no-db', prompt: [{ type: 'text', text: 'hello' }] },
    })
    const reader = antigravityModelRequests({ home, fallback: acpModelRequests(store) })
    const page = await reader.page(target('no-db'), null)
    expect(page?.source).toBe('acp')
    expect(page?.turns).toHaveLength(1)
  })
})
