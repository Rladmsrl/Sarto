// Messages between the thread store in the host and the thread worker that owns the database.

import type { OutlineTitle } from '@shared/agent-host'
import type { HostMessage } from '../i18n'
import type { ImageMode, PageBudget, ThreadWrite } from './model'
import type { StoredOrigin } from './origins'

/**
 * What the worker is started with: the database. A `reader` only reads the pages, outlines and
 * bytes of threads, beside the worker that writes.
 */
export interface ThreadWorkerData {
  file: string
  reader?: boolean
}

/**
 * How the database opened: as it was, new, recovered from corruption (the old file moved aside),
 * left alone because a newer app wrote it, or not at all.
 */
export type ThreadDbStatus = 'ok' | 'created' | 'recovered' | 'newer' | 'unavailable'

/**
 * `corrupt`: the file was damaged and is replaced by an empty one, so every thread is gone.
 * `conflict`: a write does not fit what is stored and changed nothing; write the thread whole.
 * `unavailable`: the database is not open, or the store has closed.
 * `full`: the disk has no room for the write, which changed nothing.
 */
export type ThreadErrorCode = 'corrupt' | 'conflict' | 'unavailable' | 'full'

export type ThreadRequest =
  | {
      id: number
      op: 'page'
      sessionId: string
      before: number | null
      from: number | null
      images?: ImageMode
      budget?: PageBudget
    }
  | {
      id: number
      op: 'tail'
      sessionId: string
      from: number
      images?: ImageMode
      budget?: PageBudget
    }
  | { id: number; op: 'entry'; sessionId: string; entryId: string; images?: ImageMode }
  | { id: number; op: 'load'; sessionId: string }
  | { id: number; op: 'write'; sessionId: string; change: ThreadWrite }
  | { id: number; op: 'remove'; sessionIds: string[] }
  | { id: number; op: 'blob'; sessionId: string; hash: string }
  | { id: number; op: 'mentions'; sessionId: string; text: string }
  | { id: number; op: 'outline'; sessionId: string }
  | { id: number; op: 'search'; words: string[] }
  | { id: number; op: 'find'; sessionId: string; words: string[]; limit: number }
  | { id: number; op: 'snippets'; words: string[]; picks: { sessionId: string; pos: number }[] }
  | { id: number; op: 'outputs'; sessionId: string }
  | { id: number; op: 'setOutlineTitles'; sessionId: string; titles: OutlineTitle[] }
  | { id: number; op: 'origins'; sessionId: string }
  | { id: number; op: 'putOrigin'; sessionId: string; origin: StoredOrigin }
  | { id: number; op: 'close' }

export type ThreadReply =
  | { type: 'ready'; status: ThreadDbStatus }
  // The database was damaged and replaced by an empty one, which a reader must open again.
  | { type: 'recovered' }
  | { type: 'log'; level: 'info' | 'warn' | 'error'; message: string }
  | { type: 'result'; id: number; value: unknown }
  | {
      type: 'error'
      id: number
      message: string
      code: ThreadErrorCode | null
      // What the user reads for it, which the host words in their language.
      text?: HostMessage
    }
