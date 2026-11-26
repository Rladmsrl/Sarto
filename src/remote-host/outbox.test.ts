import { afterEach, describe, expect, it, vi } from 'vitest'
import type { ChannelMessage } from '@shared/remote/channel'
import { Outbox } from './outbox'

function event(value: Record<string, unknown>): ChannelMessage {
  return { kind: 'json', value: { type: 'event', event: value } }
}

const summary = (id: string, n: number) => event({ type: 'session.summary', summary: { id, n } })
const patches = (sessionId: string, seq: number) =>
  event({
    type: 'session.patches',
    batch: { sessionId, seq, patches: [{ op: 'entry.appendText', id: 'e', text: `${seq}` }] },
  })
const facts = () => event({ type: 'work.facts', facts: [] })

/** What a sent message was, as `summary:<id>:<n>`, `patches:<id>:<from>-<seq>` or its type. */
function label(message: ChannelMessage): string {
  if (message.kind !== 'json') return 'bytes'
  const value = message.value as { type: string; event?: Record<string, unknown> }
  const { event: e } = value
  if (!e) return value.type
  if (e.type === 'session.summary') {
    const s = e.summary as { id: string; n: number }
    return `summary:${s.id}:${s.n}`
  }
  if (e.type === 'session.patches') {
    const b = e.batch as { sessionId: string; seq: number; from?: number }
    return `patches:${b.sessionId}:${b.from ?? b.seq}-${b.seq}`
  }
  return e.type as string
}

function setup() {
  vi.useFakeTimers()
  let now = 10_000
  const sent: string[] = []
  const outbox = new Outbox({
    acks: true,
    overflowed: () => {},
    dropped: () => {},
    now: () => now,
  })
  outbox.attach({
    channel: {
      send: (message) => {
        sent.push(label(message))
        return Promise.resolve()
      },
    },
    transport: { buffered: () => 0, drained: () => Promise.resolve() },
  })
  return {
    outbox,
    sent,
    advance(ms: number) {
      now += ms
      vi.advanceTimersByTime(ms)
    },
  }
}

describe('a paced device session', () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it('sends each session its latest summary with the patches, all that waits once a pace', () => {
    const { outbox, sent, advance } = setup()
    outbox.pace(1000)
    void outbox.push(summary('a', 1))
    expect(sent).toEqual(['summary:a:1'])

    void outbox.push(patches('a', 1))
    void outbox.push(summary('a', 2))
    void outbox.push(patches('b', 1))
    void outbox.push(facts())
    void outbox.push(patches('a', 2))
    void outbox.push(summary('a', 3))
    expect(sent).toEqual(['summary:a:1'])

    advance(999)
    expect(sent).toEqual(['summary:a:1'])
    advance(1)
    expect(sent).toEqual([
      'summary:a:1',
      'patches:a:1-1',
      'patches:b:1-1',
      'work.facts',
      'patches:a:2-2',
      'summary:a:3',
    ])
  })

  it('merges a session patches past other sessions summaries', () => {
    const { outbox, sent, advance } = setup()
    outbox.pace(1000)
    void outbox.push(summary('z', 1))
    void outbox.push(patches('a', 1))
    void outbox.push(summary('b', 1))
    void outbox.push(patches('a', 2))
    advance(1000)
    expect(sent).toEqual(['summary:z:1', 'patches:a:1-2', 'summary:b:1'])
  })

  it('sends what waits at once when a message that does not wait comes', () => {
    const { outbox, sent } = setup()
    outbox.pace(1000)
    void outbox.push(summary('a', 1))
    void outbox.push(patches('a', 1))
    void outbox.push(summary('a', 2))
    void outbox.push({ kind: 'json', value: { type: 'response', id: 1, result: null } })
    expect(sent).toEqual(['summary:a:1', 'patches:a:1-1', 'summary:a:2', 'response'])
  })

  it('keeps every summary of a device that asks for no pace', () => {
    const { outbox, sent } = setup()
    void outbox.push(summary('a', 1))
    void outbox.push(summary('a', 2))
    expect(sent).toEqual(['summary:a:1', 'summary:a:2'])
  })
})
