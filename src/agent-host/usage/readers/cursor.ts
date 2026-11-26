// Cursor's usage from its dashboard: the account's requests with their model and tokens, the list
// cursor.com/dashboard shows. Cursor keeps no usage on disk and its ACP agent reports none, so this
// is the account's whole usage, from the IDE and other computers too, read with the CLI's sign-in.
//
// A busy account makes hundreds of requests a day and Cursor sends a thousand a page, some five
// seconds each. So a scan reads what is new since the last one first (from an hour before it, for
// requests listed late), then goes back through a few older pages, until the reads reach 90 days
// ago. Events keep their ids as keys, so reading one again changes nothing.

import {
  cursorAccessToken,
  readCursorUsageEvents,
  type CursorPlace,
  type CursorUsageEvent,
  type CursorUsagePage,
} from '../../vendor-usage/cursor'
import type { SignInPlace } from '../../vendor-usage/stored-sign-in'
import {
  normalizeModel,
  type FileCursor,
  type LogReader,
  type ScanContext,
  type UsageRow,
} from '../model'

const AGENT_ID = 'cursor'
const CURSOR_ID = 'cursor:usage-events'
const DAY_MS = 24 * 60 * 60_000
export const CURSOR_HISTORY_MS = 90 * DAY_MS
const OVERLAP_MS = 60 * 60_000
export const CURSOR_PAGE_SIZE = 1000
/** Pages of each read: what is new, then older history. */
export const CURSOR_PAGES = 10

export interface CursorReaderDeps {
  now(): number
  token(place: CursorPlace): Promise<string | null>
  page(
    token: string,
    place: SignInPlace,
    range: { start: number; end: number; page: number; pageSize: number },
  ): Promise<CursorUsagePage>
}

const DEPS: CursorReaderDeps = {
  now: Date.now,
  token: cursorAccessToken,
  page: readCursorUsageEvents,
}

/** Every request from `back` to `through` has been read. */
interface Span {
  back: number
  through: number
}

function readSpan(cursor: FileCursor | null): Span | null {
  if (!cursor?.state) return null
  try {
    const { back, through } = JSON.parse(cursor.state) as Partial<Record<string, unknown>>
    return typeof back === 'number' && typeof through === 'number' ? { back, through } : null
  } catch {
    return null
  }
}

function cursorOf(span: Span): FileCursor {
  return {
    id: CURSOR_ID,
    agentId: AGENT_ID,
    size: 0,
    mtimeNs: 0n,
    offset: 0,
    tail: null,
    state: JSON.stringify(span),
  }
}

function rowOf(event: CursorUsageEvent): UsageRow {
  return {
    key: `cursor:${event.id}`,
    source: 'log',
    agentId: AGENT_ID,
    sessionId: event.conversationId,
    project: null,
    model: normalizeModel(event.model),
    at: event.at,
    input: event.input,
    output: event.output,
    reasoning: null,
    cacheRead: event.cacheRead,
    cacheWrite: event.cacheWrite,
    cacheWrite1h: 0,
    turn: 0,
  }
}

export function createCursorReader(deps: CursorReaderDeps = DEPS): LogReader {
  async function scan(context: ScanContext): Promise<boolean> {
    const place: CursorPlace = {
      env: context.env,
      home: context.home,
      platform: context.platform,
      now: deps.now(),
    }
    const token = await deps.token(place)
    if (!token) return false
    const now = place.now
    const oldest = now - CURSOR_HISTORY_MS

    /**
     * Reads `start` to `end`, newest first, through at most `CURSOR_PAGES` pages, and returns the
     * rows and how far back it read: `start` when it read all.
     */
    const read = async (start: number, end: number) => {
      const rows: UsageRow[] = []
      for (let page = 1; page <= CURSOR_PAGES; page++) {
        context.signal.throwIfAborted()
        const got = await deps.page(token, place, {
          start,
          end,
          page,
          pageSize: CURSOR_PAGE_SIZE,
        })
        for (const event of got.events) rows.push(rowOf(event))
        if (page * CURSOR_PAGE_SIZE >= got.total || got.oldest === null) {
          return { rows, reached: start }
        }
        if (page === CURSOR_PAGES) return { rows, reached: Math.max(start, got.oldest) }
      }
      return { rows, reached: start }
    }

    context.plan(1, 0)
    let span: Span = { back: now, through: now }
    const known = readSpan(context.cursor(CURSOR_ID))
    if (known) {
      const start = Math.max(oldest, known.through - OVERLAP_MS)
      const recent = await read(start, now)
      // What was read before stays; a gap the new pages did not reach is read again from them.
      span =
        recent.reached === start
          ? { back: Math.min(known.back, start), through: now }
          : { back: recent.reached, through: now }
      context.commit(recent.rows, cursorOf(span))
    }
    if (span.back > oldest) {
      const older = await read(oldest, span.back)
      span = { back: older.reached, through: span.through }
      context.commit(older.rows, cursorOf(span))
    }
    context.done(0)
    return true
  }

  return {
    agentId: AGENT_ID,
    locations: () => ['https://cursor.com/dashboard'],
    scan,
  }
}

export const cursorReader = createCursorReader()
