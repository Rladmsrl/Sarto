import { mkdirSync, mkdtempSync, readdirSync, rmSync, utimesSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { DatabaseSync } from 'node:sqlite'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { memoryContext } from '../testing'
import {
  antigravityReader,
  conversationCalls,
  decodeFields,
  listConversations,
} from './antigravity'

// Protobuf's wire format, enough to write the fields the reader takes.
const varint = (value: number): number[] => {
  const out: number[] = []
  let rest = BigInt(value)
  do {
    let byte = Number(rest & 0x7fn)
    rest >>= 7n
    if (rest) byte |= 0x80
    out.push(byte)
  } while (rest)
  return out
}
const int = (field: number, value: number): number[] => [...varint(field << 3), ...varint(value)]
const bytes = (field: number, data: number[]): number[] => [
  ...varint((field << 3) | 2),
  ...varint(data.length),
  ...data,
]
const str = (field: number, text: string): number[] => bytes(field, [...Buffer.from(text)])
const fixed64 = (field: number): number[] => [...varint((field << 3) | 1), 1, 2, 3, 4, 5, 6, 7, 8]
const fixed32 = (field: number): number[] => [...varint((field << 3) | 5), 1, 2, 3, 4]

interface Gen {
  call?: string
  model?: string
  input: number
  output: number
  cache?: number
  thinking?: number
}

function gen({ call, model, input, output, cache = 0, thinking = 0 }: Gen): Uint8Array {
  const usage = [
    ...int(2, input),
    ...int(3, output),
    ...fixed64(4),
    ...int(5, cache),
    ...int(9, thinking),
    ...(call ? str(11, call) : []),
  ]
  return Uint8Array.from(
    bytes(1, [...fixed32(3), ...bytes(4, usage), ...(model ? str(19, model) : [])]),
  )
}

const step = (call: string, seconds: number): Uint8Array =>
  Uint8Array.from([...bytes(1, int(1, seconds)), ...bytes(9, str(11, call))])

describe("Antigravity's conversation records", () => {
  it('decodes fields by number and stops at a malformed one', () => {
    const fields = decodeFields(Uint8Array.from([...int(1, 300), ...str(2, 'ok'), 0x1a, 0x7f, 1]))
    expect(fields.int(1)).toBe(300)
    expect(fields.string(2)).toBe('ok')
    // Field 3 claims 127 bytes where 1 is left.
    expect(fields.bytes(3)).toBeNull()
    expect(decodeFields(Uint8Array.from([0xff, 0xff])).int(1)).toBeNull()
  })

  it("takes each call's tokens and model, timed by its step", () => {
    const calls = conversationCalls(
      [step('call-1', 1795200000), Uint8Array.from([0x0a, 0x05])],
      [
        {
          idx: 0,
          data: gen({
            call: 'call-1',
            model: 'Gemini-4-Neon',
            input: 34937,
            output: 2557,
            cache: 127912,
            thinking: 1593,
          }),
        },
        { idx: 1, data: gen({ model: 'gemini-4-carbon', input: 10, output: 5 }) },
        // A call that used nothing is no request.
        { idx: 2, data: gen({ call: 'call-3', input: 0, output: 0 }) },
        { idx: 3, data: Uint8Array.from([0x0a, 0x10, 0x22]) },
      ],
    )
    expect(calls).toEqual([
      {
        id: 'call-1',
        model: 'gemini-4-neon',
        at: 1795200000000,
        input: 34937,
        output: 2557,
        cacheRead: 127912,
      },
      { id: '#1', model: 'gemini-4-carbon', at: null, input: 10, output: 5, cacheRead: 0 },
    ])
  })
})

describe("Antigravity's conversation list", () => {
  it('lists every conversation of a heavy user, in both folders', async () => {
    const base = mkdtempSync(path.join(tmpdir(), 'sarto-antigravity-many-'))
    try {
      const desktop = path.join(base, 'desktop')
      const cli = path.join(base, 'cli')
      mkdirSync(desktop)
      mkdirSync(cli)
      for (let i = 0; i < 2_100; i++) {
        writeFileSync(path.join(desktop, `c${i}.db`), '')
        writeFileSync(path.join(desktop, `c${i}.db-wal`), '')
      }
      writeFileSync(path.join(cli, 'last.db'), '')
      const files = await listConversations([desktop, cli])
      expect(files).toHaveLength(2_101)
      expect(files).toContain(path.join(cli, 'last.db'))
    } finally {
      rmSync(base, { recursive: true, force: true })
    }
  })
})

describe("Antigravity's reader", () => {
  let home: string
  let folder: string
  beforeEach(() => {
    home = mkdtempSync(path.join(tmpdir(), 'usage-agy-'))
    folder = path.join(home, '.gemini', 'antigravity-cli', 'conversations')
    mkdirSync(folder, { recursive: true })
  })
  afterEach(() => rmSync(home, { recursive: true, force: true }))

  function conversation(id: string, gens: Uint8Array[], steps: Uint8Array[]): string {
    const file = path.join(folder, `${id}.db`)
    const db = new DatabaseSync(file)
    db.exec(`PRAGMA journal_mode = WAL;
      CREATE TABLE IF NOT EXISTS steps (idx integer, step_type integer NOT NULL DEFAULT 0, metadata blob);
      CREATE TABLE IF NOT EXISTS gen_metadata (idx integer PRIMARY KEY, data blob, size integer NOT NULL DEFAULT 0);
      DELETE FROM steps; DELETE FROM gen_metadata;`)
    steps.forEach((blob, idx) =>
      db.prepare('INSERT INTO steps (idx, metadata) VALUES (?, ?)').run(idx, blob),
    )
    gens.forEach((blob, idx) =>
      db.prepare('INSERT INTO gen_metadata (idx, data) VALUES (?, ?)').run(idx, blob),
    )
    db.close()
    return file
  }

  it('reads each conversation into one row per call, leaving no WAL files behind', async () => {
    conversation(
      'eda2d279-5f00-4000-8000-000000000001',
      [gen({ call: 'c1', model: 'gemini-4-neon', input: 100, output: 20, cache: 300 })],
      [step('c1', 1795200000)],
    )
    const context = memoryContext({ home })
    expect(await antigravityReader.scan(context)).toBe(true)
    expect([...context.rows.values()]).toEqual([
      {
        key: 'antigravity:eda2d279-5f00-4000-8000-000000000001:c1',
        source: 'log',
        agentId: 'antigravity',
        sessionId: 'eda2d279-5f00-4000-8000-000000000001',
        project: null,
        model: 'gemini-4-neon',
        at: 1795200000000,
        input: 100,
        output: 20,
        reasoning: null,
        cacheRead: 300,
        cacheWrite: 0,
        cacheWrite1h: 0,
        turn: 0,
      },
    ])
    expect(readdirSync(folder)).toEqual(['eda2d279-5f00-4000-8000-000000000001.db'])
  })

  it('reads a conversation again once it changed, keeping its calls under their keys', async () => {
    const id = 'eda2d279-5f00-4000-8000-000000000002'
    const file = conversation(
      id,
      [gen({ call: 'c1', input: 100, output: 20 })],
      [step('c1', 1795200000)],
    )
    const context = memoryContext({ home })
    await antigravityReader.scan(context)
    conversation(
      id,
      [gen({ call: 'c1', input: 100, output: 25 }), gen({ call: 'c2', input: 7, output: 3 })],
      [step('c1', 1795200000), step('c2', 1795200060)],
    )
    const later = new Date(Date.now() + 60_000)
    utimesSync(file, later, later)
    await antigravityReader.scan(context)
    expect(
      [...context.rows.values()].map((row) => [row.key.split(':').at(-1), row.output]),
    ).toEqual([
      ['c1', 25],
      ['c2', 3],
    ])
  })

  it('names the account only for a personal Google sign-in, by its managed project', async () => {
    const cache = path.join(home, '.gemini', 'antigravity-cli', 'cache')
    mkdirSync(cache, { recursive: true })
    writeFileSync(path.join(cache, 'default_project_id.txt'), 'brave-fox-1234567\n')
    writeFileSync(path.join(cache, 'acp-auth-state.json'), '{"methodId":"oauth-personal"}')
    const context = memoryContext({ home })
    await antigravityReader.scan(context)
    // SHA-256("antigravity:brave-fox-1234567"), its first 8 bytes, as the Mac app's.
    expect(context.quotas.get('antigravity')?.reading.account).toBe('b74d6c21e7e33bf0')

    writeFileSync(path.join(cache, 'acp-auth-state.json'), '{"methodId":"oauth-business"}')
    await antigravityReader.scan(context)
    expect(context.quotas.get('antigravity')?.reading.account).toBeNull()
  })

  it('finds no logs where neither conversations folder exists', async () => {
    rmSync(path.join(home, '.gemini'), { recursive: true })
    expect(await antigravityReader.scan(memoryContext({ home }))).toBe(false)
  })
})
