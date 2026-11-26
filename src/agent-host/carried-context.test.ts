import { describe, expect, it } from 'vitest'
import type { ThreadEntry } from '@shared/thread'
import { carriedContext, compactedTurns, compactionPoint } from './carried-context'

const options = { firstAgent: 'claude-code' as const, agentName: () => 'Claude Code' }

let counter = 0
const user = (text: string): ThreadEntry => ({
  kind: 'user',
  id: `u${++counter}`,
  content: [{ type: 'text', text }],
})
const reply = (markdown: string): ThreadEntry => ({
  kind: 'agent',
  id: `m${++counter}`,
  markdown,
  attachments: [],
  streaming: false,
})
const compaction = (): ThreadEntry => ({
  kind: 'compaction',
  id: `c${++counter}`,
  status: 'completed',
  summary: '',
})
const takeover = (): ThreadEntry => ({
  kind: 'takeover',
  id: `k${++counter}`,
  agentId: 'codex',
  turns: 0,
  omitted: 0,
  carried: '',
  after: null,
})
const tool = (title: string, rawInput: string, result: string): ThreadEntry => ({
  kind: 'tool',
  id: `t${++counter}`,
  title,
  toolKind: 'read',
  status: 'completed',
  content: [{ type: 'markdown', markdown: result }],
  locations: [],
  permission: null,
  permissionResult: null,
  rawInput,
})

describe('the conversation an agent takeover gets', () => {
  it('cuts a long reply and omits tool call inputs', () => {
    const long = 'x'.repeat(20_000)
    const entries = [user('Fix it'), tool('Read file', 'rg --files src', 'one line'), reply(long)]
    const switched = carriedContext(entries, options)!
    expect(switched.text).not.toContain(long)
    expect(switched.text).not.toContain('input:')
  })

  it('has nothing to carry for a session with no turn', () => {
    expect(carriedContext([], options)).toBeNull()
  })
})

describe('the conversation after an agent compacted its context', () => {
  it('starts after a compaction the agent marked, which the next command turn leaves empty', () => {
    const entries = [
      user('Turn one'),
      reply('OLD-REPLY'),
      user('/compact'),
      compaction(),
      compaction(),
      user('Turn three'),
      reply('NEW-REPLY'),
    ]
    const point = compactionPoint(entries)
    expect(point).toEqual({ fromTurn: 3, after: null })
    expect(compactedTurns(entries)).toBe(2)
    const carried = carriedContext(entries, { ...options, fromTurn: point!.fromTurn })!
    expect(carried.before).toBe(2)
    expect(carried.text).toContain('NEW-REPLY')
    expect(carried.text).not.toContain('OLD-REPLY')
  })

  it('starts at the turn whose reply is the summary, for an agent that writes it as a reply', () => {
    const entries = [
      user('Turn one'),
      reply('OLD-REPLY'),
      user('/compact'),
      reply('SUMMARY-OF-IT-ALL'),
      user('Turn three'),
      reply('NEW-REPLY'),
    ]
    const point = compactionPoint(entries)
    expect(point).toEqual({ fromTurn: 2, after: null })
    const carried = carriedContext(entries, { ...options, fromTurn: point!.fromTurn })!
    expect(carried.text).toContain('SUMMARY-OF-IT-ALL')
    expect(carried.text).toContain('NEW-REPLY')
    expect(carried.text).not.toContain('OLD-REPLY')
  })

  it('does not take a command that got no reply or a failed compaction for one', () => {
    const failed: ThreadEntry = { kind: 'compaction', id: 'cf', status: 'failed', summary: 'boom' }
    expect(compactionPoint([user('One'), reply('Two'), user('/compact')])).toBeNull()
    expect(compactionPoint([user('One'), failed, user('Three')])).toBeNull()
    expect(compactedTurns([user('One'), reply('Two')])).toBe(0)
  })

  it('keeps a turn compacted in the middle from its request, with what came after the compaction', () => {
    const marker = compaction()
    const entries = [
      user('Turn one'),
      reply('OLD-REPLY'),
      user('The long task'),
      reply('BEFORE-COMPACTION'),
      marker,
      reply('AFTER-COMPACTION'),
    ]
    const point = compactionPoint(entries)
    expect(point).toEqual({ fromTurn: 2, after: marker.id })
    const carried = carriedContext(entries, {
      ...options,
      fromTurn: point!.fromTurn,
      after: point!.after ?? undefined,
    })!
    expect(carried.text).toContain('The long task')
    expect(carried.text).toContain('AFTER-COMPACTION')
    expect(carried.text).not.toContain('BEFORE-COMPACTION')
    expect(carried.text).not.toContain('OLD-REPLY')
  })

  it('goes by the latest compaction, and a takeover does not count as a turn', () => {
    const entries = [
      user('One'),
      user('/compact'),
      compaction(),
      user('Three'),
      takeover(),
      user('Four'),
      user('/compact'),
      compaction(),
      user('Six'),
      reply('LAST'),
    ]
    expect(compactionPoint(entries)).toEqual({ fromTurn: 6, after: null })
    expect(compactedTurns(entries)).toBe(5)
  })

  it('has nothing to carry when nothing came after the compaction', () => {
    const entries = [user('One'), reply('Two'), user('/compact'), compaction()]
    const point = compactionPoint(entries)
    expect(compactedTurns(entries)).toBe(2)
    expect(carriedContext(entries, { ...options, fromTurn: point!.fromTurn })).toBeNull()
  })
})
