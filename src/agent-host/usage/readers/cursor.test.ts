import { describe, expect, it, vi } from 'vitest'
import type { CursorUsageEvent } from '../../vendor-usage/cursor'
import { memoryContext } from '../testing'
import {
  createCursorReader,
  CURSOR_HISTORY_MS,
  CURSOR_PAGE_SIZE,
  CURSOR_PAGES,
  type CursorReaderDeps,
} from './cursor'

const NOW = 1_795_669_400_000
const MINUTE = 60_000
const HOUR = 60 * MINUTE

/** The nth request back from NOW, a minute apart. */
const event = (n: number, now = NOW): CursorUsageEvent => ({
  id: `e${n}@${now}`,
  at: now - n * MINUTE,
  model: 'claude-opus-5-5-medium',
  conversationId: `c${n % 3}`,
  input: 1,
  output: 10,
  cacheRead: 100,
  cacheWrite: 5,
})

function reader(events: CursorUsageEvent[], token: string | null = 'token') {
  let now = NOW
  const page = vi.fn<CursorReaderDeps['page']>(async (_token, _place, range) => {
    const inRange = events
      .filter((e) => e.at >= range.start && e.at <= range.end)
      .sort((a, b) => b.at - a.at)
    const from = (range.page - 1) * range.pageSize
    const listed = inRange.slice(from, from + range.pageSize)
    return {
      events: listed,
      total: inRange.length,
      oldest: listed.length > 0 ? listed.at(-1)!.at : null,
    }
  })
  const deps: CursorReaderDeps = { now: () => now, token: async () => token, page }
  return { reader: createCursorReader(deps), page, later: (ms: number) => (now += ms) }
}

describe("Cursor's usage events", () => {
  it('reads the newest requests first as rows keyed by the event', async () => {
    const { reader: cursor, page } = reader([event(1), event(2)])
    const context = memoryContext()
    expect(await cursor.scan(context)).toBe(true)
    expect(page.mock.calls[0]![2]).toEqual({
      start: NOW - CURSOR_HISTORY_MS,
      end: NOW,
      page: 1,
      pageSize: CURSOR_PAGE_SIZE,
    })
    expect(context.rows.get(`cursor:e1@${NOW}`)).toMatchObject({
      source: 'log',
      agentId: 'cursor',
      sessionId: 'c1',
      model: 'claude-opus-5-5-medium',
      at: NOW - MINUTE,
      input: 1,
      output: 10,
      reasoning: null,
      cacheRead: 100,
      cacheWrite: 5,
      turn: 0,
    })
  })

  it('goes back through a few pages a scan until it has 90 days', async () => {
    const count = CURSOR_PAGES * CURSOR_PAGE_SIZE + 2500
    const events = Array.from({ length: count }, (_, i) => event(i + 1))
    const { reader: cursor, page, later } = reader(events)
    const context = memoryContext()
    await cursor.scan(context)
    expect(page).toHaveBeenCalledTimes(CURSOR_PAGES)
    expect(context.rows.size).toBe(CURSOR_PAGES * CURSOR_PAGE_SIZE)

    later(MINUTE)
    page.mockClear()
    await cursor.scan(context)
    expect(context.rows.size).toBe(count)
    // What was new, then the older pages from where the first scan stopped.
    expect(page.mock.calls.at(-1)![2].end).toBe(NOW - CURSOR_PAGES * CURSOR_PAGE_SIZE * MINUTE)

    later(MINUTE)
    page.mockClear()
    await cursor.scan(context)
    expect(page).toHaveBeenCalledTimes(1)
  })

  it('reads on from the last scan, an hour back for requests listed late', async () => {
    const { reader: cursor, page, later } = reader([event(1)])
    const context = memoryContext()
    await cursor.scan(context)
    later(10 * MINUTE)
    page.mockClear()
    await cursor.scan(context)
    expect(page).toHaveBeenCalledTimes(1)
    expect(page.mock.calls[0]![2]).toMatchObject({ start: NOW - HOUR, end: NOW + 10 * MINUTE })
    expect(context.rows.size).toBe(1)
  })

  it('finds nothing while the CLI is signed out', async () => {
    const { reader: cursor, page } = reader([event(1)], null)
    expect(await cursor.scan(memoryContext())).toBe(false)
    expect(page).not.toHaveBeenCalled()
  })
})
