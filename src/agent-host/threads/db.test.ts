import { createHash } from 'node:crypto'
import { mkdtempSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { DatabaseSync } from 'node:sqlite'
import { afterEach, describe, expect, it } from 'vitest'
import type { ContextBreakdown } from '@shared/context'
import type { ContentRef, SessionView, ThreadEntry } from '@shared/thread'
import { SCHEMA_VERSION, ThreadDb, ThreadDbError } from './db'
import {
  changesStored,
  EMPTY_SESSION,
  INLINE_MEDIA_LIMIT,
  PAGE_ENTRIES,
  PAGE_LIMIT,
  storedSession,
  type PositionedEntry,
  type StoredSession,
  type ThreadHead,
} from './model'

const head: ThreadHead = { agentId: 'claude-code', acpSessionId: 'acp-1' }
const dirs: string[] = []
const logs: { level: string; message: string }[] = []

function tempFile(): string {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'sarto-threads-'))
  dirs.push(dir)
  return path.join(dir, 'state', 'threads.db')
}

function open(file = tempFile()): ThreadDb {
  return ThreadDb.open(
    file,
    (level, message) => logs.push({ level, message }),
    () => 0,
  )
}

afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true })
  logs.length = 0
})

const user = (id: string, steered?: boolean): ThreadEntry => ({
  kind: 'user',
  id,
  content: [{ type: 'text', text: id }],
  ...(steered ? { steered } : {}),
})
const agent = (id: string): ThreadEntry => ({
  kind: 'agent',
  id,
  markdown: id,
  attachments: [],
  streaming: false,
})
const tool = (id: string): ThreadEntry => ({
  kind: 'tool',
  id,
  title: id,
  toolKind: 'read',
  status: 'completed',
  content: [],
  locations: [],
  permission: null,
  permissionResult: null,
})
const turnEnd = (id: string): ThreadEntry => ({
  kind: 'turn_end',
  id,
  stopReason: 'end_turn',
  durationMs: 1,
})

/** Turns of a prompt, `tools` tool calls, an answer and a turn end, positioned from 0. */
function turns(count: number, tools: number): PositionedEntry[] {
  const out: PositionedEntry[] = []
  for (let t = 0; t < count; t++) {
    out.push({ pos: out.length, entry: user(`u${t}`) })
    for (let i = 0; i < tools; i++) out.push({ pos: out.length, entry: tool(`t${t}.${i}`) })
    out.push({ pos: out.length, entry: agent(`a${t}`) })
    out.push({ pos: out.length, entry: turnEnd(`end${t}`) })
  }
  return out
}

const ids = (entries: readonly ThreadEntry[]): string[] => entries.map((e) => e.id)

const breakdown: ContextBreakdown = {
  model: 'claude-opus-4-5',
  used: 42_000,
  size: 200_000,
  categories: [
    { name: 'Messages', tokens: 30_000, share: 0.15 },
    { name: 'Free space', tokens: 158_000, share: 0.79 },
  ],
  lists: [{ name: 'Memory Files', items: [{ name: 'CLAUDE.md', detail: null, tokens: '1.2k' }] }],
  observedAt: 1_700_000_000_000,
}

const view = (changes: Partial<SessionView>): SessionView => ({
  id: 's1',
  agentId: 'claude-code',
  projectPath: '/p',
  acpSessionId: 'acp-1',
  status: 'closed',
  title: null,
  config: [],
  commands: [],
  usage: null,
  error: null,
  turnStartedAt: null,
  turnStartUsed: null,
  createdAt: 0,
  updatedAt: 0,
  parentId: null,
  origin: 'user',
  subagent: null,
  queue: [],
  queuePaused: false,
  ...changes,
})

describe('the thread database', () => {
  it('creates its schema once and keeps threads across a reopen', () => {
    const file = tempFile()
    const db = open(file)
    expect(db.status).toBe('created')
    db.write('s1', { head, session: { ...EMPTY_SESSION, title: 'Hi' }, entries: turns(1, 1) })
    db.close()

    const again = open(file)
    expect(again.status).toBe('ok')
    const page = again.page('s1', null)!
    expect(page.head).toEqual(head)
    expect(page.session.title).toBe('Hi')
    expect(ids(page.entries)).toEqual(['u0', 't0.0', 'a0', 'end0'])
    expect(page).toMatchObject({ from: 0, older: null, plan: null })
    again.close()
  })

  it('answers null for a session with no thread', () => {
    const db = open()
    expect(db.page('nope', null)).toBeNull()
    expect(db.tail('nope', 0)).toBeNull()
    expect(db.load('nope')).toBeNull()
    db.close()
  })

  it('reads the latest page back to the start of its turn, then the pages before it', () => {
    const db = open()
    const all = turns(40, 5) // 8 entries a turn, 320 in all
    db.write('s1', { head, entries: all })

    const latest = db.page('s1', null)!
    expect(latest.entries.length).toBeGreaterThanOrEqual(PAGE_ENTRIES)
    expect(latest.entries[0]!.kind).toBe('user')
    expect(latest.entries.at(-1)!.id).toBe('end39')
    expect(latest.from).toBe(all.length - latest.entries.length)
    expect(latest.older).toBe(latest.from)

    // Walking back covers every entry once, in order, and every page starts a turn.
    const seen: ThreadEntry[] = [...latest.entries]
    let cursor = latest.older
    while (cursor !== null) {
      const page = db.page('s1', cursor)!
      expect(page.entries[0]!.kind).toBe('user')
      expect(page.from + page.entries.length).toBe(cursor)
      seen.unshift(...page.entries)
      cursor = page.older
    }
    expect(ids(seen)).toEqual(ids(all.map((p) => p.entry)))
    db.close()
  })

  it('cuts a turn longer than the page limit', () => {
    const db = open()
    const all = turns(1, PAGE_LIMIT + 100)
    db.write('s1', { head, entries: all })
    const latest = db.page('s1', null)!
    expect(latest.entries).toHaveLength(PAGE_LIMIT)
    expect(latest.older).toBe(all.length - PAGE_LIMIT)
    expect(ids(db.page('s1', latest.older)!.entries)).toEqual(
      ids(all.slice(0, all.length - PAGE_LIMIT).map((p) => p.entry)),
    )
    db.close()
  })

  it('trims pages by byte budget with exact older cursor and plan, and stitches contiguously', () => {
    const db = open()
    const largeTool = (id: string): ThreadEntry => ({
      ...(tool(id) as Extract<ThreadEntry, { kind: 'tool' }>),
      content: [
        { type: 'diff', path: '/p/a.ts', oldText: 'a'.repeat(5000), newText: 'b'.repeat(5000) },
      ],
    })
    const planEntry: ThreadEntry = {
      kind: 'plan',
      id: 'p0',
      items: [{ content: 'Step 1', priority: 'medium', status: 'in_progress' }],
    }
    const all = [
      { pos: 0, entry: user('u0') },
      { pos: 1, entry: planEntry },
      { pos: 2, entry: largeTool('t0') },
      { pos: 3, entry: largeTool('t1') },
      { pos: 4, entry: largeTool('t2') },
      { pos: 5, entry: largeTool('t3') },
      { pos: 6, entry: largeTool('t4') },
    ]
    db.write('s1', { head, entries: all })

    // Raw budget fits ~2 large diffs (~17 KB total), so latest page trims older entries and surfaces plan.
    const rawBudget = { maxBytes: 20_000 }
    const latest = db.page('s1', null, null, 'refs', rawBudget)!
    expect(latest.entries.length).toBeGreaterThan(0)
    expect(latest.entries.length).toBeLessThan(all.length)
    expect(latest.entries.at(-1)!.id).toBe('t4')
    expect(latest.older).toBe(latest.from)
    expect(latest.plan).toEqual(planEntry)

    // Walking older pages with the same byte budget reconstructs every entry contiguously.
    const seen: ThreadEntry[] = [...latest.entries]
    let cursor = latest.older
    while (cursor !== null) {
      const olderPage = db.page('s1', cursor, null, 'refs', rawBudget)!
      expect(olderPage.entries.length).toBeGreaterThan(0)
      seen.unshift(...olderPage.entries)
      cursor = olderPage.older
    }
    expect(ids(seen)).toEqual(ids(all.map((p) => p.entry)))

    // With digest: true, the digested entries easily fit inside the same byte budget in one page.
    const digestedPage = db.page('s1', null, null, 'refs', { digest: true, maxBytes: 20_000 })!
    expect(ids(digestedPage.entries)).toEqual(ids(all.map((p) => p.entry)))
    expect(digestedPage.older).toBeNull()

    // tail() also honors maxBytes and sets older accurately.
    const trimmedTail = db.tail('s1', 0, 'refs', rawBudget)!
    expect(trimmedTail.entries.length).toBeLessThan(all.length)
    expect(trimmedTail.older).toBe(trimmedTail.from)
    db.close()
  })

  it('starts turns at prompts of their own and after a turn ends', () => {
    const db = open()
    const notice: ThreadEntry = { kind: 'notice', id: 'n', severity: 'info', title: 'n' }
    const entries: ThreadEntry[] = [
      notice, // 0: before any prompt, turn 0
      user('u0'), // 1: opens turn 1
      user('steer', true), // 2: steered into turn 1
      agent('a0'), // 3
      turnEnd('end0'), // 4
      { kind: 'session_message', id: 'sm', senderId: null, content: [] }, // 5: opens turn 5
      agent('a1'), // 6
    ]
    db.write('s1', { head, entries: entries.map((entry, pos) => ({ pos, entry })) })
    db.close()
    const raw = new DatabaseSync(path.join(dirs[0]!, 'state', 'threads.db'))
    const rows = raw.prepare('SELECT pos, turn FROM entries ORDER BY pos').all()
    raw.close()
    expect(rows.map((r) => Number(r.turn))).toEqual([0, 1, 1, 1, 1, 5, 5])
  })

  it('updates an entry in place and appends new ones after it', () => {
    const db = open()
    db.write('s1', { head, entries: turns(1, 1) })
    const changed = { ...agent('a0'), markdown: 'longer answer' } as ThreadEntry
    db.write('s1', {
      head,
      entries: [
        { pos: 2, entry: changed },
        { pos: 4, entry: user('u1') },
      ],
    })
    const thread = db.load('s1')!
    expect(thread.entries.map((p) => [p.pos, p.entry.id])).toEqual([
      [0, 'u0'],
      [1, 't0.0'],
      [2, 'a0'],
      [3, 'end0'],
      [4, 'u1'],
    ])
    expect(thread.entries[2]!.entry).toEqual(changed)
    db.close()
  })

  it('refuses a write that moves an entry, and keeps what was stored', () => {
    const db = open()
    db.write('s1', { head, entries: turns(1, 1) })
    const write = (): void =>
      db.write('s1', {
        head,
        session: { ...EMPTY_SESSION, title: 'changed' },
        entries: [{ pos: 7, entry: user('u0') }],
      })
    expect(write).toThrow(ThreadDbError)
    expect(write).toThrow(expect.objectContaining({ code: 'conflict' }))
    // A new entry on a taken position conflicts too.
    expect(() => db.write('s1', { head, entries: [{ pos: 1, entry: user('other') }] })).toThrow(
      expect.objectContaining({ code: 'conflict' }),
    )
    const page = db.page('s1', null)!
    expect(page.session.title).toBeNull()
    expect(ids(page.entries)).toEqual(['u0', 't0.0', 'a0', 'end0'])
    db.close()
  })

  it('replaces a whole thread, as after a replay', () => {
    const db = open()
    db.write('s1', { head, entries: turns(3, 2) })
    db.write('s1', {
      head: { ...head, acpSessionId: 'acp-2' },
      replace: true,
      entries: [{ pos: 0, entry: user('fresh') }],
    })
    const page = db.page('s1', null)!
    expect(page.head.acpSessionId).toBe('acp-2')
    expect(ids(page.entries)).toEqual(['fresh'])
    db.close()
  })

  it('keeps the session view until a write brings a new one', () => {
    const db = open()
    const session = { ...EMPTY_SESSION, title: 'T', commands: [{ name: 'x', description: 'y' }] }
    db.write('s1', { head, session, entries: [] })
    db.write('s1', { head, entries: [{ pos: 0, entry: user('u0') }] })
    expect(db.page('s1', null)!.session).toEqual(session)
    db.close()
  })

  it('keeps the last context breakdown with the session view across a reopen', () => {
    const file = tempFile()
    const db = open(file)
    db.write('s1', { head, session: { ...EMPTY_SESSION, context: breakdown }, entries: [] })
    db.close()
    const again = open(file)
    expect(again.page('s1', null)!.session.context).toEqual(breakdown)
    again.close()
  })

  it('reads a session view stored without a context, or with one that does not parse', () => {
    const db = open()
    const before = { title: 'Old', config: [], commands: [], usage: null, subagent: null }
    db.write('s1', { head, session: before as unknown as StoredSession, entries: [] })
    expect(db.page('s1', null)!.session).toEqual({ ...EMPTY_SESSION, title: 'Old' })
    const damaged = { ...EMPTY_SESSION, title: 'Damaged', context: { used: 'many' } }
    db.write('s2', { head, session: damaged as unknown as StoredSession, entries: [] })
    expect(db.page('s2', null)!.session).toEqual({ ...EMPTY_SESSION, title: 'Damaged' })
    expect(logs).toEqual([])
    db.close()
  })

  it('stores the breakdown a context read brings, not the state of a read', () => {
    const report = { key: '42000/200000', breakdown, loading: false, error: null }
    expect(changesStored({ context: report })).toBe(true)
    expect(changesStored({ context: { ...report, loading: true } })).toBe(false)
    expect(changesStored({ context: { ...report, error: 'failed' } })).toBe(false)
    expect(changesStored({ context: undefined })).toBe(true)
    expect(storedSession(view({ context: { ...report, error: 'failed' } })).context).toBe(breakdown)
    expect(storedSession(view({})).context).toBeNull()
  })

  it('strips transient pending config state when storing a session view', () => {
    const stored = storedSession(
      view({
        config: [
          {
            id: 'mode',
            name: 'Mode',
            category: 'mode',
            type: 'select',
            value: 'auto',
            choices: [{ value: 'auto', name: 'Auto' }],
            pending: { value: 'full-access', wait: 'turn' },
          },
        ],
      }),
    )
    expect(stored.config[0]).not.toHaveProperty('pending')
  })

  it('reads everything from a position with tail', () => {
    const db = open()
    db.write('s1', { head, entries: turns(3, 1) }) // 12 entries
    const tail = db.tail('s1', 4)!
    expect(ids(tail.entries)).toEqual(['u1', 't1.0', 'a1', 'end1', 'u2', 't2.0', 'a2', 'end2'])
    expect(tail).toMatchObject({ from: 4, older: 4 })
    expect(db.tail('s1', 0)!.older).toBeNull()
    db.close()
  })

  it('reads one entry by its id, its images by hash or with bytes', () => {
    const db = open()
    const bytes = Buffer.alloc(INLINE_MEDIA_LIMIT, 7)
    const data = bytes.toString('base64')
    const hash = createHash('sha256').update(bytes).digest('hex')
    const shot: ThreadEntry = {
      ...(tool('shot') as Extract<ThreadEntry, { kind: 'tool' }>),
      content: [{ type: 'ref', ref: { kind: 'image', mimeType: 'image/png', data } }],
    }
    db.write('s1', { head, entries: [...turns(2, 1), { pos: 8, entry: shot }] })
    expect(db.entry('s1', 't1.0')).toEqual({ head, entry: tool('t1.0') })
    expect(db.entry('s1', 'shot', 'inline')!.entry).toEqual(shot)
    expect(db.entry('s1', 'shot')!.entry).toEqual({
      ...shot,
      content: [{ type: 'ref', ref: { kind: 'image', mimeType: 'image/png', blob: hash } }],
    })
    expect(db.entry('s1', 'missing')).toBeNull()
    expect(db.entry('s2', 't1.0')).toBeNull()
    db.close()
  })

  it('reads what a session made from its stored thread', () => {
    const db = open()
    const reply = (id: string, markdown: string): ThreadEntry => ({
      kind: 'agent',
      id,
      markdown,
      attachments: [],
      streaming: false,
    })
    const artifact = (
      id: string,
      artifactId: string,
      title: string,
      action: 'create' | 'update' | 'delete',
    ): ThreadEntry => ({
      kind: 'artifact',
      id,
      artifactId,
      title,
      action,
      version: action === 'delete' ? null : 1,
      writes: 1,
      after: null,
    })
    const entries: ThreadEntry[] = [
      user('u0'),
      artifact('w0', 'art_a', 'Plan', 'create'),
      artifact('w1', 'art_b', 'Sketch', 'create'),
      reply(
        'a0',
        'Opened https://github.com/example/app/issues/12 and ' +
          '[the fix](https://github.com/example/cloud/pull/7/files#diff-1).',
      ),
      { kind: 'turn_end', id: 'end0', stopReason: 'end_turn', durationMs: 4000 },
      user('u1'),
      {
        kind: 'plan',
        id: 'p0',
        items: [{ content: 'Old', priority: 'medium', status: 'pending' }],
      },
      {
        kind: 'plan',
        id: 'p1',
        items: [
          { content: 'Read', priority: 'medium', status: 'completed' },
          { content: 'Write', priority: 'medium', status: 'in_progress' },
        ],
      },
      artifact('w2', 'art_a', 'Plan v2', 'update'),
      artifact('w3', 'art_b', 'Sketch', 'delete'),
      reply('a1', 'Merged https://github.com/example/cloud/pull/7 and https://example.com/x.'),
      reply('a2', 'Also see https://github.com/example/app/pull/30'),
      { kind: 'turn_end', id: 'end1', stopReason: 'end_turn', durationMs: 9000 },
      user('u2'),
    ]
    db.write('s1', { head, entries: entries.map((entry, pos) => ({ pos, entry })) })
    expect(db.outputs('s1')).toEqual({
      head,
      outputs: {
        artifacts: [{ id: 'art_a', title: 'Plan v2' }],
        references: [
          'https://github.com/example/app/pull/30',
          'https://github.com/example/cloud/pull/7',
          'https://github.com/example/app/issues/12',
        ],
        reply: 'Also see https://github.com/example/app/pull/30',
        turnMs: 9000,
        plan: [
          { content: 'Read', priority: 'medium', status: 'completed' },
          { content: 'Write', priority: 'medium', status: 'in_progress' },
        ],
      },
    })
    expect(db.outputs('missing')).toBeNull()
    db.close()
  })

  it('keeps only user input in the outline across a reopen', () => {
    const file = tempFile()
    const db = open(file)
    const entries: ThreadEntry[] = [
      user('u0'),
      agent('a0'),
      tool('t0'),
      {
        kind: 'user',
        id: 'from-agent',
        content: [{ type: 'text', text: 'Restart browser and check' }],
        from: { sessionId: 'sender', title: 'Review' },
      },
      user('steer', true),
      {
        kind: 'user',
        id: 'remote',
        content: [{ type: 'text', text: 'Check the result' }],
        device: { id: 'phone', name: 'Phone' },
      },
      {
        kind: 'user',
        id: 'approved',
        content: [{ type: 'text', text: 'Implement the plan.' }],
        approval: true,
      },
      {
        kind: 'user',
        id: 'reminder',
        content: [{ type: 'text', text: 'Your step is not reported yet.' }],
        sarto: true,
      },
      { kind: 'session_message', id: 'sm', senderId: 'sender', content: [] },
    ]
    db.write('s1', { head, entries: entries.map((entry, pos) => ({ pos, entry })) })
    db.setOutlineTitles('s1', [{ pos: 3, title: 'Restart browser' }])
    const expected = [
      { pos: 0, entryId: 'u0', text: 'u0', title: null },
      { pos: 4, entryId: 'steer', text: 'steer', title: null },
      { pos: 5, entryId: 'remote', text: 'Check the result', title: null },
    ]
    expect(db.outline('s1')!.entries).toEqual(expected)
    expect(db.load('s1')!.entries.map(({ entry }) => entry)).toEqual(entries)
    db.close()

    const again = open(file)
    expect(again.outline('s1')!.entries).toEqual(expected)
    again.close()
  })

  it('keeps who sent each marked message through a whole write, a reopen, until the session goes', () => {
    const file = tempFile()
    const db = open(file)
    const kept = [
      {
        text: 'Restart browser and check',
        origin: { from: { sessionId: 'sender', title: 'Review' } },
      },
      { text: 'Your step is not reported yet.', origin: { sarto: true as const } },
    ]
    for (const origin of kept) db.putOrigin('s1', origin)
    db.putOrigin('s2', {
      text: 'Check the result',
      origin: { device: { id: 'phone', name: 'Phone' } },
    })
    // A thread rebuilt from the agent's history is written whole, without the marks.
    db.write('s1', {
      head,
      entries: [user('u0'), user('u1')].map((entry, pos) => ({ pos, entry })),
    })
    db.write('s1', {
      head,
      entries: [user('v0'), agent('v1')].map((entry, pos) => ({ pos, entry })),
      replace: true,
    })
    expect(db.origins('s1')).toEqual(kept)
    db.close()

    const again = open(file)
    expect(again.origins('s1')).toEqual(kept)
    again.remove(['s1'])
    expect(again.origins('s1')).toEqual([])
    expect(again.origins('s2')).toHaveLength(1)
    again.close()
  })

  it('keeps large images apart, once per session, and reads them back by hash or with bytes', () => {
    const file = tempFile()
    const db = open(file)
    const bytes = Buffer.alloc(INLINE_MEDIA_LIMIT, 7)
    const big = bytes.toString('base64')
    const hash = createHash('sha256').update(bytes).digest('hex')
    const small = Buffer.from('tiny').toString('base64')
    const shot = (id: string, ref: ContentRef): ThreadEntry => ({
      ...(tool(id) as Extract<ThreadEntry, { kind: 'tool' }>),
      content: [{ type: 'ref', ref }],
    })
    const prompt = (ref: ContentRef): ThreadEntry => ({
      kind: 'user',
      id: 'u',
      content: [{ type: 'ref', ref }],
    })
    const image = (data: string): ContentRef => ({ kind: 'image', mimeType: 'image/png', data })
    const stored: ContentRef = { kind: 'image', mimeType: 'image/png', blob: hash }
    const entries = [prompt(image(big)), shot('t1', image(big)), shot('t2', image(small))]
    db.write('s1', { head, entries: entries.map((entry, pos) => ({ pos, entry })) })
    // A client that reads only bytes gets them back; the others, and a load, the hash.
    expect(db.page('s1', null, null, 'inline')!.entries).toEqual(entries)
    const byHash = [prompt(stored), shot('t1', stored), shot('t2', image(small))]
    expect(db.page('s1', null)!.entries).toEqual(byHash)
    expect(db.tail('s1', 0)!.entries).toEqual(byHash)
    expect(db.load('s1')!.entries.map(({ entry }) => entry)).toEqual(byHash)
    expect(db.blob('s1', hash)?.data).toEqual(new Uint8Array(bytes))
    db.close()

    const raw = new DatabaseSync(file)
    expect(raw.prepare('SELECT COUNT(*) AS n FROM blobs').get()!.n).toBe(1)
    const json = raw.prepare("SELECT json FROM entries WHERE entry_id = 't1'").get()!.json
    raw.close()
    expect(String(json)).not.toContain(big.slice(0, 64))
    expect(String(json)).toContain('"blob"')
  })

  it('keeps large sounds and clips apart as it does images, with their kind and size', () => {
    const file = tempFile()
    const db = open(file)
    const big = Buffer.alloc(INLINE_MEDIA_LIMIT, 3).toString('base64')
    const size = Buffer.byteLength(big, 'base64')
    const reply: ThreadEntry = {
      kind: 'agent',
      id: 'a',
      markdown: 'Here',
      attachments: [
        { kind: 'audio', mimeType: 'audio/wav', data: big, size, name: null },
        { kind: 'video', mimeType: 'video/mp4', data: 'AAAA', size: 3, name: 'clip.mp4' },
      ],
      streaming: false,
    }
    const call: ThreadEntry = {
      ...(tool('t1') as Extract<ThreadEntry, { kind: 'tool' }>),
      content: [
        {
          type: 'ref',
          ref: { kind: 'video', mimeType: 'video/webm', data: big, size, name: 'demo.webm' },
        },
      ],
    }
    db.write('s1', { head, entries: [reply, call].map((entry, pos) => ({ pos, entry })) })
    expect(db.page('s1', null)!.entries).toEqual([reply, call])
    db.close()

    const raw = new DatabaseSync(file)
    // The same bytes once, whatever kind each ref says they are.
    expect(raw.prepare('SELECT COUNT(*) AS n FROM blobs').get()!.n).toBe(1)
    const json = String(raw.prepare("SELECT json FROM entries WHERE entry_id = 'a'").get()!.json)
    raw.close()
    expect(json).not.toContain(big.slice(0, 64))
    expect(JSON.parse(json).attachments[0]).toEqual({
      kind: 'audio',
      mimeType: 'audio/wav',
      size,
      name: null,
      blob: expect.any(String),
    })
  })

  it('keeps the bytes of images read by hash through a whole write that still names them', () => {
    const db = open()
    const bytes = Buffer.alloc(INLINE_MEDIA_LIMIT + 1, 5)
    const hash = createHash('sha256').update(bytes).digest('hex')
    const shot: ThreadEntry = {
      ...(tool('t1') as Extract<ThreadEntry, { kind: 'tool' }>),
      content: [
        {
          type: 'ref',
          ref: { kind: 'image', mimeType: 'image/png', data: bytes.toString('base64') },
        },
      ],
    }
    db.write('s1', { head, entries: [{ pos: 0, entry: shot }] })
    // A session that came back from the store holds the image by its hash, and is written whole.
    const loaded = db.load('s1')!.entries
    expect(loaded[0]!.entry).toMatchObject({
      content: [{ type: 'ref', ref: { kind: 'image', mimeType: 'image/png', blob: hash } }],
    })
    db.write('s1', { head, entries: [...loaded, { pos: 1, entry: user('u1') }], replace: true })
    expect(db.page('s1', null, null, 'inline')!.entries).toEqual([shot, user('u1')])
    // A ref whose bytes are gone reads as one that cannot show.
    db.write('s1', { head, entries: [{ pos: 0, entry: user('u0') }], replace: true })
    db.write('s1', { head, entries: [{ pos: 1, entry: loaded[0]!.entry }] })
    expect(db.page('s1', null)!.entries[1]).toMatchObject({
      content: [{ type: 'ref', ref: { kind: 'unsupported', label: 'image/png' } }],
    })
    db.close()
  })

  it('keeps the bytes of sent attachments through a whole write that still names them', () => {
    const file = tempFile()
    const db = open(file)
    const hash = 'ab'.repeat(32)
    const data = new Uint8Array([1, 2, 3, 4])
    const sent: ThreadEntry = {
      kind: 'user',
      id: 'u',
      content: [
        { type: 'text', text: 'Look' },
        {
          type: 'ref',
          ref: {
            kind: 'attachment',
            attachment: {
              id: 'a1',
              type: 'image',
              name: 'Image 1',
              uri: null,
              mimeType: 'image/png',
              size: 4,
              sent: 'image',
              thumb: 'data:image/webp;base64,AAAA',
              blob: hash,
            },
          },
        },
      ],
    }
    // The bytes go in with the entry that names them, in the same write as the thread row.
    db.write('s1', {
      head,
      entries: [{ pos: 0, entry: sent }],
      blobs: [{ hash, mime: 'image/png', data }],
    })
    expect(db.blob('s1', hash)).toEqual({ hash, mime: 'image/png', data })
    expect(db.blob('s1', 'cd'.repeat(32))).toBeNull()
    expect(db.page('s1', null)!.entries).toEqual([sent])

    db.write('s1', {
      head,
      entries: [{ pos: 0, entry: sent }, ...turns(1, 0).map((e) => ({ ...e, pos: e.pos + 1 }))],
      replace: true,
    })
    expect(db.blob('s1', hash)?.data).toEqual(data)

    // A whole write without the entry drops its bytes, and so does removing the thread.
    db.write('s2', {
      head,
      entries: [{ pos: 0, entry: sent }],
      blobs: [{ hash, mime: 'image/png', data }],
    })
    db.write('s1', { head, entries: turns(1, 0), replace: true })
    expect(db.blob('s1', hash)).toBeNull()
    db.remove(['s2'])
    expect(db.blob('s2', hash)).toBeNull()
    db.close()
  })

  it('sets entries aside at a cut with their bytes and titles, and returns or drops them', () => {
    const file = tempFile()
    const db = open(file)
    const hash = 'ab'.repeat(32)
    const data = new Uint8Array([1, 2, 3, 4])
    const sent: ThreadEntry = {
      kind: 'user',
      id: 'u1',
      content: [
        { type: 'text', text: 'Look' },
        {
          type: 'ref',
          ref: {
            kind: 'attachment',
            attachment: {
              id: 'a',
              type: 'image',
              name: 'Image 1',
              uri: null,
              mimeType: 'image/png',
              size: 4,
              sent: 'image',
              thumb: null,
              blob: hash,
            },
          },
        },
      ],
    }
    const kept = turns(1, 0)
    const aside: PositionedEntry[] = [
      { pos: 3, entry: sent },
      { pos: 4, entry: agent('a1') },
      { pos: 5, entry: turnEnd('end1') },
    ]
    db.write('s1', {
      head,
      entries: [...kept, ...aside],
      blobs: [{ hash, mime: 'image/png', data }],
    })
    db.setOutlineTitles('s1', [{ pos: 3, title: 'Look at it' }])

    db.write('s1', { head, entries: [], cut: 3, setAside: aside })
    const check = (thread: ThreadDb) => {
      const stored = thread.load('s1')!
      expect(ids(stored.entries.map(({ entry }) => entry))).toEqual(['u0', 'a0', 'end0'])
      expect(stored.setAside).toEqual(aside)
      expect(thread.blob('s1', hash)?.data).toEqual(data)
      expect(thread.outline('s1')!.entries.map(({ entryId }) => entryId)).toEqual(['u0'])
    }
    check(db)
    db.close()
    const again = open(file)
    check(again)

    // Put back: the entries go in again where they were, with the title their message had.
    again.write('s1', { head, entries: aside, cut: 3, setAside: [] })
    expect(ids(again.load('s1')!.entries.map(({ entry }) => entry))).toEqual([
      'u0',
      'a0',
      'end0',
      'u1',
      'a1',
      'end1',
    ])
    expect(again.load('s1')!.setAside).toEqual([])
    expect(again.blob('s1', hash)?.data).toEqual(data)
    expect(again.outline('s1')!.entries.at(-1)).toMatchObject({ pos: 3, title: 'Look at it' })

    // Sent on from the cut: what only the set-aside entries named goes with them.
    again.write('s1', { head, entries: [], cut: 3, setAside: aside })
    again.write('s1', { head, entries: [{ pos: 6, entry: user('u2') }], setAside: [] })
    const stored = again.load('s1')!
    expect(ids(stored.entries.map(({ entry }) => entry))).toEqual(['u0', 'a0', 'end0', 'u2'])
    expect(stored.setAside).toEqual([])
    expect(again.blob('s1', hash)).toBeNull()
    again.close()
    const sql = new DatabaseSync(file)
    expect(sql.prepare('SELECT COUNT(*) AS n FROM outline_titles').get()).toEqual({ n: 0 })
    sql.close()
  })

  it('tells a write that finds no room apart, and keeps what was stored', () => {
    const db = open()
    db.write('s1', { head, entries: turns(1, 0) })
    // The pages it has are all it gets, as on a full disk.
    const connection = (db as unknown as { db: DatabaseSync }).db
    const pages = Number(connection.prepare('PRAGMA page_count').get()!.page_count)
    connection.exec(`PRAGMA max_page_count = ${pages}`)
    const long: ThreadEntry = {
      kind: 'agent',
      id: 'a1',
      markdown: 'x'.repeat(1_000_000),
      attachments: [],
      streaming: false,
    }
    let failure: unknown = null
    try {
      db.write('s1', { head, entries: [{ pos: 3, entry: long }] })
    } catch (error) {
      failure = error
    }
    expect(failure).toBeInstanceOf(ThreadDbError)
    expect((failure as ThreadDbError).code).toBe('full')
    expect(ids(db.page('s1', null)!.entries)).toEqual(['u0', 'a0', 'end0'])
    db.close()
  })

  it('tells whether an agent or user entry holds a text, as written', () => {
    const db = open()
    const shot = 'C:\\Users\\me\\Application Support\\"shot".png'
    const reply: ThreadEntry = {
      kind: 'agent',
      id: 'a',
      markdown: `Saved:\n\n![shot](${shot})`,
      attachments: [{ kind: 'link', uri: 'file:///tmp/linked.png', name: 'linked.png' }],
      streaming: false,
    }
    db.write('s1', {
      head,
      entries: [
        { pos: 0, entry: user('look at ~/a b.png') },
        { pos: 1, entry: reply },
      ],
    })
    db.write('s2', { head, entries: [{ pos: 0, entry: tool('/tmp/x.png') }] })
    expect(db.mentions('s1', shot)).toBe(true)
    expect(db.mentions('s1', '~/a b.png')).toBe(true)
    expect(db.mentions('s1', '/tmp/y.png')).toBe(false)
    // Only the text of a reply or a message, as the live thread looks.
    expect(db.mentions('s1', '/tmp/linked.png')).toBe(false)
    expect(db.mentions('s1', '"kind"')).toBe(false)
    // A tool call's text is not where a reply names its files.
    expect(db.mentions('s2', '/tmp/x.png')).toBe(false)
    expect(db.mentions('missing', shot)).toBe(false)
    db.close()
  })

  it('removes threads with their images', () => {
    const file = tempFile()
    const db = open(file)
    const big = Buffer.alloc(INLINE_MEDIA_LIMIT, 1).toString('base64')
    const image: ThreadEntry = {
      kind: 'agent',
      id: 'a',
      markdown: '',
      attachments: [{ kind: 'image', mimeType: 'image/png', data: big }],
      streaming: false,
    }
    db.write('s1', { head, entries: [{ pos: 0, entry: image }] })
    db.write('s2', { head, entries: turns(1, 1) })
    db.remove(['s1', 'missing'])
    expect(db.page('s1', null)).toBeNull()
    expect(db.page('s2', null)).not.toBeNull()
    db.close()
    const raw = new DatabaseSync(file)
    expect(raw.prepare('SELECT COUNT(*) AS n FROM blobs').get()!.n).toBe(0)
    expect(raw.prepare("SELECT COUNT(*) AS n FROM entries WHERE session_id = 's1'").get()!.n).toBe(
      0,
    )
    raw.close()
  })

  it('treats a thread with an entry that does not parse as not stored, and says so', () => {
    const file = tempFile()
    const db = open(file)
    db.write('s1', { head, entries: turns(1, 1) })
    db.close()
    const raw = new DatabaseSync(file)
    raw.prepare('UPDATE entries SET json = \'{"kind":"tool"}\' WHERE entry_id = \'t0.0\'').run()
    raw.close()
    const again = open(file)
    expect(again.page('s1', null)).toBeNull()
    expect(again.load('s1')).toBeNull()
    expect(logs.some((l) => l.level === 'error' && l.message.includes('s1'))).toBe(true)
    again.close()
  })

  it("reads back Sarto's settings changes and a folder's held servers and hooks", () => {
    const file = tempFile()
    const db = open(file)
    const row = {
      id: 'appearance.color-mode',
      place: 'Appearance › Theme',
      name: 'Color mode',
      from: { value: 'system', text: 'System' },
      to: { value: 'dark', text: 'Dark' },
      section: 'appearance',
      item: null,
      row: 'color-mode',
    } as const
    const own: ThreadEntry[] = [
      {
        kind: 'settings_change',
        id: 'k1',
        items: [row],
        asked: true,
        expiresAt: 1_700_000_000_000,
        outcome: null,
        after: 't0.0',
      },
      {
        kind: 'settings_change',
        id: 'k2',
        items: [{ ...row, warning: 'Opens it up.' }],
        asked: false,
        expiresAt: null,
        outcome: { kind: 'changed' },
        after: 't0.0',
      },
      {
        kind: 'project_mcp',
        id: 'k3',
        servers: [{ name: 'db', target: 'npx db-mcp' }],
        decision: 'use',
        after: null,
      },
      {
        kind: 'project_hooks',
        id: 'k4',
        hooks: [{ event: 'PreToolUse', target: './check.sh' }],
        decision: null,
        after: null,
      },
    ]
    const entries = [
      ...turns(1, 1),
      ...own.map((entry, i) => ({ pos: 4 + i, entry })),
    ] satisfies PositionedEntry[]
    db.write('s1', { head, entries })
    db.close()

    const again = open(file)
    expect(again.page('s1', null)!.entries.slice(4)).toEqual(own)
    expect(again.load('s1')!.entries.map(({ entry }) => entry)).toEqual(
      entries.map(({ entry }) => entry),
    )
    expect(logs.filter((l) => l.level === 'error')).toEqual([])
    again.close()
  })

  it('moves a damaged file aside and starts empty', () => {
    const file = tempFile()
    open(file).close()
    writeFileSync(file, 'this is not a database, only text long enough to look like one'.repeat(80))
    const db = open(file)
    expect(db.status).toBe('recovered')
    expect(db.page('s1', null)).toBeNull()
    db.write('s1', { head, entries: turns(1, 0) })
    expect(db.page('s1', null)!.entries).toHaveLength(3)
    db.close()
    const files = readdirSync(path.dirname(file))
    expect(files).toContain('threads.db.corrupt-1970-01-01T00-00-00-000Z')
    expect(logs.some((l) => l.level === 'error' && l.message.includes('damaged'))).toBe(true)
  })

  it('leaves a database from a newer app alone', () => {
    const file = tempFile()
    open(file).close()
    const raw = new DatabaseSync(file)
    raw.exec(`PRAGMA user_version = ${SCHEMA_VERSION + 1}`)
    raw.close()
    const db = open(file)
    expect(db.status).toBe('newer')
    db.write('s1', { head, entries: turns(1, 0) })
    expect(db.page('s1', null)).toBeNull()
    db.close()
    const check = new DatabaseSync(file)
    expect(check.prepare('SELECT COUNT(*) AS n FROM threads').get()!.n).toBe(0)
    check.close()
  })
})
