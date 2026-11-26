// The thread database: every session's entries in one SQLite file, read a page at a time.
// node:sqlite is synchronous, so this runs in the thread worker, never on the host's event loop.

import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, renameSync, statfsSync } from 'node:fs'
import path from 'node:path'
import { DatabaseSync, type SQLOutputValue, type StatementSync } from 'node:sqlite'
import type { SessionOutputs } from '@shared/agent-host'
import { githubReferenceFromLink } from '@shared/git'
import { OUTLINE_TEXT } from '@shared/outline'
import { isThreadEntry, type ThreadEntry } from '@shared/thread'
import type { IndexedMessage } from '../search/messages'
import { transaction } from '../sqlite'
import { digestEntry, entryJsonBytes } from './digest'
import {
  storedBlobs,
  EMPTY_SESSION,
  INLINE_MEDIA_LIMIT,
  type ImageMode,
  mapRefs,
  PAGE_ENTRIES,
  PAGE_LIMIT,
  type PageBudget,
  parseStoredSession,
  settled,
  turnOf,
  type OutlineRow,
  type PositionedEntry,
  type StoredBlob,
  type StoredEntry,
  type StoredOutline,
  type StoredOutputs,
  type StoredSession,
  type StoredThread,
  type ThreadHead,
  type ThreadPage,
  type ThreadWrite,
} from './model'
import { originOf, type MessageOrigin, type StoredOrigin } from './origins'
import type { HostMessage } from '../i18n'
import type { ThreadDbStatus, ThreadErrorCode } from './protocol'

export const SCHEMA_VERSION = 14

// `turn` is the position of the entry that opened the entry's turn, so a page that starts at a
// turn is one range of the primary key.
const SCHEMA = `
  CREATE TABLE threads (
    session_id     TEXT PRIMARY KEY,
    agent_id       TEXT NOT NULL,
    acp_session_id TEXT NOT NULL,
    session_json   TEXT NOT NULL,
    next_pos       INTEGER NOT NULL,
    updated_at     INTEGER NOT NULL
  ) STRICT;
  CREATE TABLE entries (
    session_id TEXT NOT NULL REFERENCES threads (session_id) ON DELETE CASCADE,
    pos        INTEGER NOT NULL,
    turn       INTEGER NOT NULL,
    entry_id   TEXT NOT NULL,
    kind       TEXT NOT NULL,
    json       TEXT NOT NULL,
    PRIMARY KEY (session_id, pos)
  ) STRICT, WITHOUT ROWID;
  CREATE UNIQUE INDEX entries_by_id ON entries (session_id, entry_id);
  CREATE INDEX entries_by_kind ON entries (session_id, kind, pos);
  CREATE TABLE blobs (
    session_id TEXT NOT NULL REFERENCES threads (session_id) ON DELETE CASCADE,
    hash       TEXT NOT NULL,
    mime       TEXT NOT NULL,
    data       BLOB NOT NULL,
    PRIMARY KEY (session_id, hash)
  ) STRICT, WITHOUT ROWID;
  CREATE TABLE outline_titles (
    session_id TEXT NOT NULL REFERENCES threads (session_id) ON DELETE CASCADE,
    pos        INTEGER NOT NULL,
    title      TEXT NOT NULL,
    PRIMARY KEY (session_id, pos)
  ) STRICT, WITHOUT ROWID;
  CREATE TABLE origins (
    session_id TEXT NOT NULL,
    seq        INTEGER NOT NULL,
    text       TEXT NOT NULL,
    json       TEXT NOT NULL,
    PRIMARY KEY (session_id, seq)
  ) STRICT, WITHOUT ROWID;
  CREATE TABLE set_aside (
    session_id TEXT NOT NULL REFERENCES threads (session_id) ON DELETE CASCADE,
    pos        INTEGER NOT NULL,
    entry_id   TEXT NOT NULL,
    json       TEXT NOT NULL,
    PRIMARY KEY (session_id, pos)
  ) STRICT, WITHOUT ROWID;
`

// SQLite's primary result codes, the low byte of node:sqlite's `errcode`.
const SQLITE_IOERR = 10
const SQLITE_CORRUPT = 11
const SQLITE_FULL = 13
const SQLITE_CONSTRAINT = 19
const SQLITE_NOTADB = 26
// Above every position; SQLite compares it as a 64-bit integer.
const END = Number.MAX_SAFE_INTEGER
// What a session's card shows at most: the references it counts and the start of its last reply.
const OUTPUT_REFERENCES = 50
const OUTPUT_REPLY = 600
// A github.com address in a reply, in ASCII so CJK punctuation right after it stays out.
const GITHUB_LINK = /https:\/\/(?:www\.)?github\.com\/[\w\-./?#=&%~+:@!$*,;]+/g

/** The canonical pull request and issue addresses a reply links, in their order. */
function githubLinks(markdown: string): string[] {
  const links: string[] = []
  for (const [match] of markdown.matchAll(GITHUB_LINK)) {
    const ref = githubReferenceFromLink(match.replace(/[.,;:!?]+$/, ''))
    if (ref) links.push(ref.url)
  }
  return links
}

// The content refs that carry bytes, which a large one keeps in the blobs table.
const CARRIED_KINDS: ReadonlySet<string> = new Set(['image', 'audio', 'video'])

export type ThreadDbLog = (level: 'info' | 'warn' | 'error', message: string) => void

export class ThreadDbError extends Error {
  constructor(
    message: string,
    readonly code: ThreadErrorCode,
    /** The message for the user, which the worker cannot word in their language itself. */
    readonly text?: HostMessage,
  ) {
    super(message)
    this.name = 'ThreadDbError'
  }
}

function resultCode(error: unknown): number | null {
  const errcode = (error as { errcode?: unknown } | null)?.errcode
  return typeof errcode === 'number' ? errcode & 0xff : null
}

const isCorrupt = (error: unknown): boolean => {
  const code = resultCode(error)
  return code === SQLITE_CORRUPT || code === SQLITE_NOTADB
}

// Less free space than this makes an I/O error a full disk's.
const LOW_SPACE_BYTES = 64 * 1024 * 1024

/** Whether the failure is for want of room: SQLite's own, or an I/O error on a disk nearly full. */
function isFull(error: unknown, folder: string): boolean {
  const code = resultCode(error)
  if (code === SQLITE_FULL) return true
  if (code !== SQLITE_IOERR) return false
  try {
    const { bavail, bsize } = statfsSync(folder)
    return bavail * bsize < LOW_SPACE_BYTES
  } catch {
    return false
  }
}

type Row = Record<string, SQLOutputValue>

const optionalText = (value: SQLOutputValue | undefined): string | null =>
  value === null || value === undefined ? null : String(value)

function prepareAll(db: DatabaseSync) {
  // Plain `?` marks only: Node 22 binds no positional arguments to numbered ones such as `?1`.
  const sql = (text: string): StatementSync => db.prepare(text)
  return {
    thread: sql(
      'SELECT agent_id, acp_session_id, session_json, next_pos FROM threads WHERE session_id = ?',
    ),
    pageStart: sql(`
      SELECT MIN(turn) AS start FROM (
        SELECT turn FROM entries WHERE session_id = ? AND pos < ? ORDER BY pos DESC LIMIT ?)`),
    pageFloor: sql(
      'SELECT pos FROM entries WHERE session_id = ? AND pos < ? ORDER BY pos DESC LIMIT 1 OFFSET ?',
    ),
    range: sql(
      'SELECT pos, json FROM entries WHERE session_id = ? AND pos >= ? AND pos < ? ORDER BY pos',
    ),
    previous: sql(
      'SELECT pos, kind, turn FROM entries WHERE session_id = ? AND pos < ? ORDER BY pos DESC LIMIT 1',
    ),
    latestPlan: sql(
      "SELECT pos, json FROM entries WHERE session_id = ? AND kind = 'plan' ORDER BY pos DESC LIMIT 1",
    ),
    byId: sql('SELECT pos FROM entries WHERE session_id = ? AND entry_id = ?'),
    entryById: sql('SELECT pos, json FROM entries WHERE session_id = ? AND entry_id = ?'),
    turnFrom: sql(
      'SELECT turn FROM entries WHERE session_id = ? AND pos >= ? ORDER BY pos LIMIT 1',
    ),
    // A message's text as `outlineText` reads it, in two parts: the length, then the session.
    userMessages: sql(`
      SELECT e.pos, e.entry_id, t.title,
        substr((SELECT group_concat(json_extract(part.value, '$.text'), char(10))
          FROM json_each(e.json, '$.content') AS part
          WHERE json_extract(part.value, '$.type') = 'text'), 1, ?) AS text,
        (SELECT group_concat(COALESCE(
            json_extract(part.value, '$.ref.attachment.name'),
            json_extract(part.value, '$.ref.name')), ', ')
          FROM json_each(e.json, '$.content') AS part
          WHERE json_extract(part.value, '$.type') = 'ref') AS names
      FROM entries e LEFT JOIN outline_titles t ON t.session_id = e.session_id AND t.pos = e.pos
      WHERE e.session_id = ? AND e.kind = 'user'
        AND json_extract(e.json, '$.from') IS NULL
        AND json_extract(e.json, '$.approval') IS NULL
        AND json_extract(e.json, '$.sarto') IS NULL ORDER BY e.pos`),
    // The text of the user messages and agent replies in a range of positions, as the search
    // index reads them; an answer a card already shows, or a message Sarto wrote itself, is no
    // message of the user's own.
    messagesIn: sql(`
      SELECT pos, entry_id, kind,
        CASE kind WHEN 'agent' THEN json_extract(json, '$.markdown')
          ELSE (SELECT group_concat(json_extract(part.value, '$.text'), char(10))
            FROM json_each(entries.json, '$.content') AS part
            WHERE json_extract(part.value, '$.type') = 'text') END AS text
      FROM entries
      WHERE session_id = ? AND pos >= ? AND pos < ? AND kind IN ('user', 'agent')
        AND json_extract(json, '$.approval') IS NULL AND json_extract(json, '$.sarto') IS NULL
      ORDER BY pos`),
    threadState: sql('SELECT next_pos, updated_at FROM threads WHERE session_id = ?'),
    threadMarks: sql('SELECT session_id, updated_at FROM threads'),
    storedThreads: sql('SELECT count(*) AS n FROM threads'),
    // What a session made, latest first, for its card in the sidebar.
    artifactWrites: sql(`
      SELECT json_extract(json, '$.artifactId') AS id, json_extract(json, '$.title') AS title,
        json_extract(json, '$.action') AS action
      FROM entries WHERE session_id = ? AND kind = 'artifact' ORDER BY pos DESC`),
    linkingReplies: sql(`
      SELECT json_extract(json, '$.markdown') AS markdown FROM entries
      WHERE session_id = ? AND kind = 'agent' AND instr(json, 'github.com/') > 0
      ORDER BY pos DESC`),
    lastReply: sql(`
      SELECT substr(json_extract(json, '$.markdown'), 1, ?) AS markdown FROM entries
      WHERE session_id = ? AND kind = 'agent' AND json_extract(json, '$.markdown') <> ''
      ORDER BY pos DESC LIMIT 1`),
    lastTurnMs: sql(`
      SELECT json_extract(json, '$.durationMs') AS ms FROM entries
      WHERE session_id = ? AND kind = 'turn_end' ORDER BY pos DESC LIMIT 1`),
    titles: sql('SELECT pos, title FROM outline_titles WHERE session_id = ?'),
    userAt: sql("SELECT 1 FROM entries WHERE session_id = ? AND pos = ? AND kind = 'user'"),
    putTitle: sql(`
      INSERT INTO outline_titles (session_id, pos, title) VALUES (?, ?, ?)
      ON CONFLICT (session_id, pos) DO UPDATE SET title = excluded.title`),
    insertEntry: sql(
      'INSERT INTO entries (session_id, pos, turn, entry_id, kind, json) VALUES (?, ?, ?, ?, ?, ?)',
    ),
    updateEntry: sql('UPDATE entries SET json = ? WHERE session_id = ? AND pos = ?'),
    upsertThread: sql(`
      INSERT INTO threads (session_id, agent_id, acp_session_id, session_json, next_pos, updated_at)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT (session_id) DO UPDATE SET
        agent_id = excluded.agent_id,
        acp_session_id = excluded.acp_session_id,
        session_json = excluded.session_json,
        next_pos = excluded.next_pos,
        updated_at = excluded.updated_at`),
    deleteThread: sql('DELETE FROM threads WHERE session_id = ?'),
    cutFrom: sql('DELETE FROM entries WHERE session_id = ? AND pos >= ?'),
    setAside: sql('SELECT pos, json FROM set_aside WHERE session_id = ? ORDER BY pos'),
    clearSetAside: sql('DELETE FROM set_aside WHERE session_id = ?'),
    insertSetAside: sql(
      'INSERT INTO set_aside (session_id, pos, entry_id, json) VALUES (?, ?, ?, ?)',
    ),
    // `entries.json`, as in `mentions`; a hash is 64 hex digits, so no other text holds one.
    namesBlob: sql(
      'SELECT 1 FROM entries WHERE session_id = ? AND instr(entries.json, ?) > 0 LIMIT 1',
    ),
    deleteBlob: sql('DELETE FROM blobs WHERE session_id = ? AND hash = ?'),
    deleteTitle: sql('DELETE FROM outline_titles WHERE session_id = ? AND pos = ?'),
    origins: sql('SELECT text, json FROM origins WHERE session_id = ? ORDER BY seq'),
    putOrigin: sql(`
      INSERT INTO origins (session_id, seq, text, json)
      SELECT ?, COALESCE(MAX(seq), -1) + 1, ?, ? FROM origins WHERE session_id = ?`),
    deleteOrigins: sql('DELETE FROM origins WHERE session_id = ?'),
    insertBlob: sql(
      'INSERT OR IGNORE INTO blobs (session_id, hash, mime, data) VALUES (?, ?, ?, ?)',
    ),
    blob: sql('SELECT mime, data FROM blobs WHERE session_id = ? AND hash = ?'),
    hasBlob: sql('SELECT 1 AS found FROM blobs WHERE session_id = ? AND hash = ?'),
    // `entries.json`, since json_each has a hidden column of that name.
    mentions: sql(`SELECT 1 FROM entries WHERE session_id = ? AND (
      (kind = 'agent' AND instr(json_extract(json, '$.markdown'), ?) > 0)
      OR (kind = 'user' AND EXISTS (
        SELECT 1 FROM json_each(entries.json, '$.content') AS part
        WHERE json_extract(part.value, '$.type') = 'text'
          AND instr(json_extract(part.value, '$.text'), ?) > 0
      ))
    ) LIMIT 1`),
  }
}

type Statements = ReturnType<typeof prepareAll>

export class ThreadDb {
  private db: DatabaseSync | null = null
  private sql: Statements | null = null
  status: ThreadDbStatus = 'ok'
  /** How many times a damaged file was moved aside and an empty one started. */
  recoveries = 0
  /** Opened only to read, beside the connection that writes and recovers. */
  private reader = false

  private constructor(
    private readonly file: string,
    private readonly log: ThreadDbLog,
    private readonly now: () => number,
  ) {}

  /**
   * Opens the file, creating it, or moving a damaged one aside and starting empty.
   */
  static open(file: string, log: ThreadDbLog, now: () => number = Date.now): ThreadDb {
    const store = new ThreadDb(file, log, now)
    mkdirSync(path.dirname(file), { recursive: true })
    try {
      store.connect()
    } catch (error) {
      if (!isCorrupt(error)) throw error
      store.recover(error)
    }
    return store
  }

  /**
   * Opens the file another connection created and migrated, only to read the threads: it never
   * creates, migrates or moves the file aside, and fails when it is not at this schema version.
   */
  static openReader(file: string, log: ThreadDbLog): ThreadDb {
    const store = new ThreadDb(file, log, Date.now)
    store.reader = true
    const db = new DatabaseSync(file)
    try {
      const version = Number(db.prepare('PRAGMA user_version').get()?.user_version ?? 0)
      if (version !== SCHEMA_VERSION) {
        throw new Error(
          `${path.basename(file)} is at schema version ${version}, not ${SCHEMA_VERSION}`,
        )
      }
      db.exec('PRAGMA query_only = ON')
      store.sql = prepareAll(db)
      store.db = db
    } catch (error) {
      db.close()
      throw error
    }
    return store
  }

  private connect(): void {
    const db = new DatabaseSync(this.file)
    try {
      const version = Number(db.prepare('PRAGMA user_version').get()?.user_version ?? 0)
      if (version > SCHEMA_VERSION) {
        db.close()
        this.status = 'newer'
        this.log(
          'warn',
          `${path.basename(this.file)} has schema version ${version}, newer than this app understands (${SCHEMA_VERSION}); threads are neither read nor written this run`,
        )
        return
      }
      if (version === 0) {
        // auto_vacuum takes effect only before the first table exists.
        db.exec('PRAGMA auto_vacuum = INCREMENTAL')
        db.exec('PRAGMA journal_mode = WAL')
        db.exec(`BEGIN; ${SCHEMA} PRAGMA user_version = ${SCHEMA_VERSION}; COMMIT;`)
        if (this.status === 'ok') this.status = 'created'
      } else if (version < SCHEMA_VERSION) {
        throw new Error(
          `${path.basename(this.file)} is at unsupported schema version ${version} (expected ${SCHEMA_VERSION})`,
        )
      }
      db.exec('PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA foreign_keys = ON;')
      this.sql = prepareAll(db)
      this.db = db
    } catch (error) {
      try {
        db.close()
      } catch {
        // Closing a handle that failed to read anything can fail too; the first error matters.
      }
      throw error
    }
  }

  /** Moves the damaged file and its WAL aside, keeping them together, and starts empty. */
  private recover(error: unknown): void {
    try {
      this.close(false)
    } catch {
      // A damaged file may refuse to close cleanly; it is moved aside either way.
    }
    const stamp = new Date(this.now()).toISOString().replace(/[:.]/g, '-')
    const target = `${this.file}.corrupt-${stamp}`
    for (const suffix of ['', '-wal', '-shm']) {
      if (existsSync(this.file + suffix)) renameSync(this.file + suffix, target + suffix)
    }
    this.log(
      'error',
      `${path.basename(this.file)} is damaged (${(error as Error).message}); it was moved to ${path.basename(target)} and threads start empty`,
    )
    this.status = 'recovered'
    this.recoveries++
    this.connect()
  }

  /**
   * Runs `run`, turning damage into a fresh database and SQLite's errors into ours; `fallback` is
   * the answer while the database is not open.
   */
  private guard<T>(run: (sql: Statements, db: DatabaseSync) => T, fallback: T): T {
    const { sql, db } = this
    if (!sql || !db) return fallback
    return this.attempt(sql, db, run)
  }

  private attempt<T>(
    sql: Statements,
    db: DatabaseSync,
    run: (sql: Statements, db: DatabaseSync) => T,
  ): T {
    try {
      return run(sql, db)
    } catch (error) {
      if (error instanceof ThreadDbError) throw error
      if (isCorrupt(error)) {
        // A reader leaves the file to the connection that writes, which the store asks again.
        if (this.reader) throw new ThreadDbError((error as Error).message, 'corrupt')
        this.recover(error)
        throw new ThreadDbError(
          `The thread database was damaged: ${(error as Error).message}`,
          'corrupt',
          { key: 'threadDb.damaged', params: { reason: (error as Error).message } },
        )
      }
      if (resultCode(error) === SQLITE_CONSTRAINT) {
        throw new ThreadDbError((error as Error).message, 'conflict')
      }
      if (isFull(error, path.dirname(this.file))) {
        throw new ThreadDbError((error as Error).message, 'full')
      }
      throw error
    }
  }

  private transaction<T>(db: DatabaseSync, run: () => T): T {
    return transaction(db, run)
  }

  // Reading.

  private headOf(
    sql: Statements,
    sessionId: string,
  ): (ThreadHead & { session: StoredSession }) | null {
    const row = sql.thread.get(sessionId)
    if (!row) return null
    let session: StoredSession | null = null
    try {
      session = parseStoredSession(JSON.parse(String(row.session_json)))
    } catch {
      // Reported below with the session.
    }
    if (!session) {
      this.log('error', `The stored session view of ${sessionId} does not parse`)
      return null
    }
    return {
      agentId: String(row.agent_id) as ThreadHead['agentId'],
      acpSessionId: String(row.acp_session_id),
      session,
    }
  }

  /**
   * An entry as stored, with its sounds and clips put back, and its images too when `images` is
   * `inline`; with `refs`, an image names its bytes by their hash instead. Null when it does not
   * parse.
   */
  private entryOf(
    sql: Statements,
    sessionId: string,
    row: Row,
    images: ImageMode,
  ): ThreadEntry | null {
    let value: unknown
    try {
      value = JSON.parse(String(row.json))
    } catch {
      value = null
    }
    if (typeof value === 'object' && value !== null) {
      value = mapRefs(value as Record<string, unknown>, (ref) => {
        if (typeof ref.blob !== 'string') return ref
        if (images === 'refs' && ref.kind === 'image') {
          if (sql.hasBlob.get(sessionId, ref.blob)) {
            return { kind: 'image', mimeType: ref.mimeType, blob: ref.blob }
          }
          this.log('warn', `Media ${ref.blob} of session ${sessionId} is missing`)
          return { kind: 'unsupported', label: String(ref.mimeType) }
        }
        const blob = sql.blob.get(sessionId, ref.blob)
        if (!blob) {
          this.log('warn', `Media ${ref.blob} of session ${sessionId} is missing`)
          return { kind: 'unsupported', label: String(ref.mimeType) }
        }
        const restored: Record<string, unknown> = {
          ...ref,
          data: Buffer.from(blob.data as Uint8Array).toString('base64'),
        }
        delete restored.blob
        return restored
      })
    }
    if (isThreadEntry(value)) return value
    this.log('error', `Entry ${String(row.pos)} of session ${sessionId} does not parse`)
    return null
  }

  private entriesOf(
    sql: Statements,
    sessionId: string,
    rows: Row[],
    images: ImageMode,
  ): ThreadEntry[] | null {
    const entries: ThreadEntry[] = []
    for (const row of rows) {
      const entry = this.entryOf(sql, sessionId, row, images)
      if (!entry) return null
      entries.push(entry)
    }
    return entries
  }

  private pageOf(
    sql: Statements,
    sessionId: string,
    from: number,
    before: number,
    images: ImageMode,
    budget?: PageBudget,
  ): ThreadPage | null {
    const head = this.headOf(sql, sessionId)
    if (!head) return null
    const rows = sql.range.all(sessionId, from, before)
    let entries: ThreadEntry[] | null
    let effectiveFrom = from
    if (budget?.maxBytes !== undefined && rows.length > 0) {
      const kept: ThreadEntry[] = []
      let used = 0
      let firstIndex = rows.length
      for (let i = rows.length - 1; i >= 0; i--) {
        const row = rows[i]!
        if (!budget.digest && images === 'refs') {
          const rawBytes = Buffer.byteLength(String(row.json))
          if (kept.length > 0 && used + rawBytes + 1 > budget.maxBytes) break
          const entry = this.entryOf(sql, sessionId, row, images)
          if (!entry) return null
          kept.push(entry)
          used += rawBytes + 1
          firstIndex = i
          continue
        }
        const entry = this.entryOf(sql, sessionId, row, images)
        if (!entry) return null
        const size =
          budget.digest && entry.kind === 'tool'
            ? entryJsonBytes(digestEntry(settled(entry)))
            : images === 'refs'
              ? Buffer.byteLength(String(row.json))
              : entryJsonBytes(entry)
        if (kept.length > 0 && used + size + 1 > budget.maxBytes) break
        kept.push(entry)
        used += size + 1
        firstIndex = i
      }
      kept.reverse()
      entries = kept
      if (firstIndex < rows.length) effectiveFrom = Number(rows[firstIndex]!.pos)
    } else {
      entries = this.entriesOf(sql, sessionId, rows, images)
    }
    if (!entries) return null
    const older = sql.previous.get(sessionId, effectiveFrom) ? effectiveFrom : null
    let plan: ThreadPage['plan'] = null
    const latest = sql.latestPlan.get(sessionId)
    if (latest && Number(latest.pos) < effectiveFrom) {
      const entry = this.entryOf(sql, sessionId, latest, images)
      if (entry?.kind === 'plan') plan = entry
    }
    const { session, ...rest } = head
    return { head: rest, session, entries, from: effectiveFrom, older, plan }
  }

  /**
   * The page that ends below `before`, or the latest page when it is null: at least
   * `PAGE_ENTRIES` entries back to the start of their turn, cut at `PAGE_LIMIT`. With `reach`, it
   * goes back to the start of the turn holding that position instead, uncut. Null when the
   * session has no stored thread, or a part of it does not parse. Images are references unless
   * `images` is `inline`, for a client that reads only the bytes.
   */
  page(
    sessionId: string,
    before: number | null,
    reach: number | null = null,
    images: ImageMode = 'refs',
    budget?: PageBudget,
  ): ThreadPage | null {
    return this.guard((sql) => {
      const bound = before ?? END
      if (reach !== null && reach < bound) {
        const turn = sql.turnFrom.get(sessionId, reach)?.turn
        const start = turn === undefined || turn === null ? reach : Math.min(Number(turn), reach)
        return this.pageOf(sql, sessionId, start, bound, images, budget)
      }
      const start = sql.pageStart.get(sessionId, bound, PAGE_ENTRIES)?.start
      if (start === null || start === undefined) {
        const head = this.headOf(sql, sessionId)
        if (!head) return null
        const { session, ...rest } = head
        const end = before ?? Number(sql.thread.get(sessionId)?.next_pos ?? 0)
        return { head: rest, session, entries: [], from: end, older: null, plan: null }
      }
      let from = Number(start)
      const floor = sql.pageFloor.get(sessionId, bound, PAGE_LIMIT - 1)?.pos
      if (floor !== undefined && floor !== null && Number(floor) > from) from = Number(floor)
      return this.pageOf(sql, sessionId, from, bound, images, budget)
    }, null)
  }

  /** Everything from `from` to the end, for a window the renderer holds already. */
  tail(
    sessionId: string,
    from: number,
    images: ImageMode = 'refs',
    budget?: PageBudget,
  ): ThreadPage | null {
    return this.guard((sql) => this.pageOf(sql, sessionId, from, END, images, budget), null)
  }

  /**
   * One entry by its id, as a page gives it; null when the session has no stored thread, the
   * thread no such entry, or the entry does not parse.
   */
  entry(sessionId: string, entryId: string, images: ImageMode = 'refs'): StoredEntry | null {
    return this.guard((sql) => {
      const head = this.headOf(sql, sessionId)
      if (!head) return null
      const row = sql.entryById.get(sessionId, entryId)
      if (!row) return null
      const entry = this.entryOf(sql, sessionId, row, images)
      return entry
        ? { head: { agentId: head.agentId, acpSessionId: head.acpSessionId }, entry }
        : null
    }, null)
  }

  /** The session's user messages with their titles, oldest first; null without a stored thread. */
  outline(sessionId: string): StoredOutline | null {
    return this.guard((sql) => {
      const head = this.headOf(sql, sessionId)
      if (!head) return null
      const entries: OutlineRow[] = sql.userMessages.all(OUTLINE_TEXT, sessionId).map((row) => ({
        pos: Number(row.pos),
        entryId: String(row.entry_id),
        text: optionalText(row.text) || (optionalText(row.names) ?? ''),
        title: optionalText(row.title),
      }))
      const { session, ...rest } = head
      return { head: rest, session, entries }
    }, null)
  }

  /** When each stored thread last changed, which the search index is kept in step with. */
  threadMarks(): Map<string, number> {
    return this.guard(
      (sql) =>
        new Map(
          sql.threadMarks.all().map((row) => [String(row.session_id), Number(row.updated_at)]),
        ),
      new Map(),
    )
  }

  /** The number of stored threads. */
  threadCount(): number {
    return this.guard((sql) => Number(sql.storedThreads.get()?.n ?? 0), 0)
  }

  /** Where a thread's entries end and when it last changed; null without a stored thread. */
  threadState(sessionId: string): { nextPos: number; updatedAt: number } | null {
    return this.guard((sql) => {
      const row = sql.threadState.get(sessionId)
      return row ? { nextPos: Number(row.next_pos), updatedAt: Number(row.updated_at) } : null
    }, null)
  }

  /**
   * The user messages and agent replies stored at positions from `from` up to `to`, for the
   * search index. A reply is read as stored, still streaming or not.
   */
  messagesIn(sessionId: string, from: number, to: number): IndexedMessage[] {
    return this.guard((sql) => {
      const out: IndexedMessage[] = []
      for (const row of sql.messagesIn.all(sessionId, from, to)) {
        const text = optionalText(row.text)?.trim()
        if (!text) continue
        out.push({
          pos: Number(row.pos),
          entryId: String(row.entry_id),
          role: row.kind === 'user' ? 'user' : 'agent',
          text,
        })
      }
      return out
    }, [])
  }

  /** What the session made, from its stored thread; null without one. */
  outputs(sessionId: string): StoredOutputs | null {
    return this.guard((sql) => {
      const stored = this.headOf(sql, sessionId)
      if (!stored) return null
      const artifacts: SessionOutputs['artifacts'] = []
      const seen = new Set<string>()
      for (const row of sql.artifactWrites.all(sessionId)) {
        const id = optionalText(row.id)
        if (!id || seen.has(id)) continue
        seen.add(id)
        // The latest write decides: a deleted artifact is gone even if earlier turns wrote it.
        if (row.action !== 'delete') artifacts.push({ id, title: optionalText(row.title) ?? '' })
      }
      const references: string[] = []
      for (const row of sql.linkingReplies.all(sessionId)) {
        const links = githubLinks(optionalText(row.markdown) ?? '')
        for (let i = links.length - 1; i >= 0; i--) {
          if (!references.includes(links[i]!)) references.push(links[i]!)
        }
        if (references.length >= OUTPUT_REFERENCES) break
      }
      const reply = optionalText(sql.lastReply.get(OUTPUT_REPLY, sessionId)?.markdown)
      const ms = sql.lastTurnMs.get(sessionId)?.ms
      const latest = sql.latestPlan.get(sessionId)
      const planEntry = latest ? this.entryOf(sql, sessionId, latest, 'refs') : null
      return {
        head: { agentId: stored.agentId, acpSessionId: stored.acpSessionId },
        outputs: {
          artifacts,
          references: references.slice(0, OUTPUT_REFERENCES),
          reply,
          turnMs: typeof ms === 'number' || typeof ms === 'bigint' ? Number(ms) : null,
          plan: planEntry?.kind === 'plan' ? planEntry.items : null,
        },
      }
    }, null)
  }

  /** Who sent the messages Sarto marked in a session, in the order they were added. */
  origins(sessionId: string): StoredOrigin[] {
    return this.guard((sql) => {
      const out: StoredOrigin[] = []
      for (const row of sql.origins.all(sessionId)) {
        let origin: MessageOrigin | null = null
        try {
          const parsed: unknown = JSON.parse(String(row.json))
          if (typeof parsed === 'object' && parsed !== null) {
            origin = originOf({ ...(parsed as MessageOrigin), kind: 'user', id: '', content: [] })
          }
        } catch {
          // A row that does not parse marks nothing.
        }
        if (origin) out.push({ text: String(row.text), origin })
      }
      return out
    }, [])
  }

  /** Keeps who sent a message Sarto marked, after the session's others. */
  putOrigin(sessionId: string, origin: StoredOrigin): void {
    this.guard((sql) => {
      sql.putOrigin.run(sessionId, origin.text, JSON.stringify(origin.origin), sessionId)
    }, undefined)
  }

  /** Stores the outline's titles of a session's messages; false when it has no stored thread. */
  setOutlineTitles(sessionId: string, titles: readonly { pos: number; title: string }[]): boolean {
    return this.guard(
      (sql, db) =>
        this.transaction(db, () => {
          if (!sql.thread.get(sessionId)) return false
          for (const { pos, title } of titles) sql.putTitle.run(sessionId, pos, title)
          return true
        }),
      false,
    )
  }

  /** The whole thread, for a session whose agent connects, its images as references. */
  load(sessionId: string): StoredThread | null {
    return this.guard((sql) => {
      const head = this.headOf(sql, sessionId)
      if (!head) return null
      const entries: PositionedEntry[] = []
      for (const row of sql.range.all(sessionId, 0, END)) {
        const entry = this.entryOf(sql, sessionId, row, 'refs')
        if (!entry) return null
        entries.push({ pos: Number(row.pos), entry })
      }
      // What does not parse of them is only gone from Put back; the thread opens without it.
      const setAside: PositionedEntry[] = []
      for (const row of sql.setAside.all(sessionId)) {
        const entry = this.entryOf(sql, sessionId, row, 'refs')
        if (entry) setAside.push({ pos: Number(row.pos), entry })
      }
      const { session, ...rest } = head
      return { head: rest, session, entries, setAside }
    }, null)
  }

  /** The entries an edit set aside as stored, parsed only for the bytes they name. */
  private storedSetAside(sql: Statements, sessionId: string): PositionedEntry[] {
    const out: PositionedEntry[] = []
    for (const row of sql.setAside.all(sessionId)) {
      try {
        const value: unknown = JSON.parse(String(row.json))
        if (isThreadEntry(value)) out.push({ pos: Number(row.pos), entry: value })
      } catch {
        // Unreadable, so it names nothing that could be kept.
      }
    }
    return out
  }

  /**
   * Writes the set-aside entries whole. The bytes and outline titles that only the earlier ones
   * named go, unless the thread names them again, as after Put back.
   */
  private writeSetAside(sql: Statements, sessionId: string, next: PositionedEntry[]): void {
    const before = this.storedSetAside(sql, sessionId)
    sql.clearSetAside.run(sessionId)
    for (const { pos, entry } of next) {
      sql.insertSetAside.run(sessionId, pos, entry.id, this.storedJson(sql, sessionId, entry))
    }
    const kept = storedBlobs(next.map(({ entry }) => entry))
    for (const hash of storedBlobs(before.map(({ entry }) => entry))) {
      if (kept.has(hash) || sql.namesBlob.get(sessionId, hash)) continue
      sql.deleteBlob.run(sessionId, hash)
    }
    const positions = new Set(next.map(({ pos }) => pos))
    for (const { pos, entry } of before) {
      if (entry.kind !== 'user' || positions.has(pos) || sql.userAt.get(sessionId, pos)) continue
      sql.deleteTitle.run(sessionId, pos)
    }
  }

  // Writing.

  /** The entry's JSON, with large images, sounds and clips moved into the session's blobs. */
  private storedJson(sql: Statements, sessionId: string, entry: ThreadEntry): string {
    const stored = mapRefs(entry as unknown as Record<string, unknown>, (ref) => {
      if (
        !CARRIED_KINDS.has(String(ref.kind)) ||
        typeof ref.data !== 'string' ||
        ref.data.length <= INLINE_MEDIA_LIMIT
      ) {
        return ref
      }
      const bytes = Buffer.from(ref.data, 'base64')
      const hash = createHash('sha256').update(bytes).digest('hex')
      sql.insertBlob.run(sessionId, hash, String(ref.mimeType), bytes)
      const moved: Record<string, unknown> = { ...ref, blob: hash }
      delete moved.data
      return moved
    })
    return JSON.stringify(stored)
  }

  /**
   * Writes new and changed entries in one transaction. A changed entry must be stored at the
   * position given; when it is not, or a new one's position is taken, nothing changes and the
   * write fails with `conflict`.
   */
  write(sessionId: string, change: ThreadWrite): void {
    this.guard((sql, db) => {
      this.transaction(db, () => {
        // Writing whole drops the session's bytes with its rows; those its entries name stay.
        const kept: StoredBlob[] = []
        // So do the outline's titles, whose positions keep their messages.
        let titles: Row[] = []
        // An edit's set-aside entries, written whole with a replace, keep theirs as well.
        const aside = change.setAside ?? []
        if (change.replace) {
          const named = [...change.entries, ...aside].map(({ entry }) => entry)
          for (const hash of storedBlobs(named)) {
            const row = sql.blob.get(sessionId, hash)
            if (row) kept.push({ hash, mime: String(row.mime), data: row.data as Uint8Array })
          }
          titles = sql.titles.all(sessionId)
          sql.deleteThread.run(sessionId)
        }
        const stored = sql.thread.get(sessionId)
        let nextPos = Number(stored?.next_pos ?? 0)
        for (const { pos } of change.entries) nextPos = Math.max(nextPos, pos + 1)
        const session = change.session
          ? JSON.stringify(change.session)
          : stored
            ? String(stored.session_json)
            : JSON.stringify(EMPTY_SESSION)
        sql.upsertThread.run(
          sessionId,
          change.head.agentId,
          change.head.acpSessionId,
          session,
          nextPos,
          this.now(),
        )
        for (const blob of [...kept, ...(change.blobs ?? [])]) {
          sql.insertBlob.run(sessionId, blob.hash, blob.mime, blob.data)
        }
        if (change.cut !== undefined && !change.replace) sql.cutFrom.run(sessionId, change.cut)
        const entries = [...change.entries].sort((a, b) => a.pos - b.pos)
        for (const { pos, entry } of entries) {
          const json = this.storedJson(sql, sessionId, entry)
          const known = sql.byId.get(sessionId, entry.id)
          if (known) {
            if (Number(known.pos) !== pos) {
              throw new ThreadDbError(
                `Entry ${entry.id} of session ${sessionId} is stored at ${String(known.pos)}, not ${pos}`,
                'conflict',
              )
            }
            sql.updateEntry.run(json, sessionId, pos)
            continue
          }
          const previous = sql.previous.get(sessionId, pos)
          const turn = turnOf(
            entry,
            pos,
            previous ? { kind: String(previous.kind), turn: Number(previous.turn) } : null,
          )
          sql.insertEntry.run(sessionId, pos, turn, entry.id, entry.kind, json)
        }
        if (change.setAside !== undefined) this.writeSetAside(sql, sessionId, change.setAside)
        const asideUsers = new Set(
          aside.flatMap(({ pos, entry }) => (entry.kind === 'user' ? [pos] : [])),
        )
        for (const { pos, title } of titles) {
          if (asideUsers.has(Number(pos)) || sql.userAt.get(sessionId, pos)) {
            sql.putTitle.run(sessionId, pos, title)
          }
        }
      })
    }, undefined)
  }

  /** The bytes a session keeps under this hash, as for a sent attachment; null when none. */
  blob(sessionId: string, hash: string): StoredBlob | null {
    return this.guard((sql) => {
      const row = sql.blob.get(sessionId, hash)
      return row ? { hash, mime: String(row.mime), data: row.data as Uint8Array } : null
    }, null)
  }

  /**
   * Whether the text of an agent reply or a user message of the session holds `text`, as the
   * live thread tells it (`entryHolds`).
   */
  mentions(sessionId: string, text: string): boolean {
    return this.guard((sql) => sql.mentions.get(sessionId, text, text) !== undefined, false)
  }

  /** Drops the threads of these sessions, with their images, and returns the space. */
  remove(sessionIds: readonly string[]): void {
    this.guard((sql, db) => {
      this.transaction(db, () => {
        for (const sessionId of sessionIds) {
          sql.deleteThread.run(sessionId)
          sql.deleteOrigins.run(sessionId)
        }
      })
      db.exec('PRAGMA incremental_vacuum')
    }, undefined)
  }

  /** Folds the WAL into the file and closes it; a later call does nothing. */
  close(checkpoint = true): void {
    const db = this.db
    this.db = null
    this.sql = null
    if (!db) return
    try {
      if (checkpoint && !this.reader) db.exec('PRAGMA wal_checkpoint(TRUNCATE)')
    } catch (error) {
      this.log('warn', `Could not fold the thread database's WAL: ${(error as Error).message}`)
    }
    db.close()
  }
}
