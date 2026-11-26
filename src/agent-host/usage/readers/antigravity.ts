// Google Antigravity's usage from its conversations: one SQLite database per conversation under
// ~/.gemini/antigravity/conversations (the desktop app) and ~/.gemini/antigravity-cli/conversations
// (agy). `gen_metadata` rows are protobuf messages with the model and token usage of each call, and
// `steps` rows carry the time of the step that made it, matched by call id. There is no public
// schema; the field numbers are those Sarto's Mac app read off real files and checked against a
// third-party ledger (UsageIslandKit's AntigravityReader.swift):
//   gen_metadata.data: 1 { 4 { 2 input, 3 output, 5 cache read, 9 thinking, 11 call id }, 19 model }
//   steps.metadata:    1 { 1 seconds }, 9 { 11 call id }
// A conversation that changed is read again in full; its calls keep their keys.

import type { BigIntStats, Dirent } from 'node:fs'
import { readdir, readFile, stat } from 'node:fs/promises'
import path from 'node:path'
import { DatabaseSync, type SQLOutputValue } from 'node:sqlite'
import { pathToFileURL } from 'node:url'
import type { Platform } from '@shared/platform'
import {
  antigravityAccount,
  antigravityAuthStateFile,
  antigravityOnboardingFile,
  antigravityProjectFile,
} from '../../vendor-usage/antigravity'
import { unchanged } from '../lines'
import {
  normalizeModel,
  type FileCursor,
  type LogReader,
  type QuotaContext,
  type ScanContext,
  type UsageRow,
} from '../model'

const AGENT_ID = 'antigravity'
const EXTENSIONS = new Set(['.db', '.vscdb'])
/** Outlasts agy's own write transactions, which are short. */
const BUSY_TIMEOUT_MS = 500
// SQLite's primary result codes, the low byte of node:sqlite's `errcode`.
const SQLITE_BUSY = 5
const SQLITE_LOCKED = 6

export function conversationFolders(home: string, platform: Platform): string[] {
  const p = platform === 'win32' ? path.win32 : path.posix
  return [
    p.join(home, '.gemini', 'antigravity', 'conversations'),
    p.join(home, '.gemini', 'antigravity-cli', 'conversations'),
  ]
}

// Protobuf

/** A message's fields by number, the first of each kind, as far as it could be read. */
export interface Fields {
  int(field: number): number | null
  bytes(field: number): Uint8Array | null
  string(field: number): string | null
  message(field: number): Fields | null
}

const MAX_SAFE = BigInt(Number.MAX_SAFE_INTEGER)

/**
 * Just enough of protobuf's wire format to take numbers and strings by field number. The bytes
 * come from another app's files, so every length is checked against what is left, and anything
 * malformed ends the message with the fields read so far.
 */
export function decodeFields(data: Uint8Array): Fields {
  const ints = new Map<number, number>()
  const blobs = new Map<number, Uint8Array>()
  let i = 0
  /** At most 10 bytes; null when the input ends first or the value needs more than 64 bits. */
  const varint = (): bigint | null => {
    let result = 0n
    let shift = 0n
    while (i < data.length && shift < 64n) {
      const byte = data[i++]!
      const part = BigInt(byte & 0x7f)
      if (shift === 63n && part > 1n) return null
      result |= part << shift
      if (byte < 0x80) return result
      shift += 7n
    }
    return null
  }
  const skip = (count: bigint): boolean => {
    if (count > BigInt(data.length - i)) return false
    i += Number(count)
    return true
  }
  read: while (i < data.length) {
    const key = varint()
    if (key === null) break
    const field = Number(key >> 3n)
    switch (Number(key & 7n)) {
      case 0: {
        const value = varint()
        if (value === null) break read
        if (!ints.has(field) && value <= MAX_SAFE) ints.set(field, Number(value))
        break
      }
      case 1:
        if (!skip(8n)) break read
        break
      case 2: {
        const length = varint()
        if (length === null) break read
        const start = i
        if (!skip(length)) break read
        if (!blobs.has(field)) blobs.set(field, data.subarray(start, i))
        break
      }
      case 5:
        if (!skip(4n)) break read
        break
      default:
        break read
    }
  }
  const decoder = new TextDecoder('utf-8', { fatal: true })
  const fields: Fields = {
    int: (field) => ints.get(field) ?? null,
    bytes: (field) => blobs.get(field) ?? null,
    string(field) {
      const bytes = blobs.get(field)
      if (!bytes) return null
      try {
        return decoder.decode(bytes)
      } catch {
        return null
      }
    },
    message(field) {
      const bytes = blobs.get(field)
      return bytes ? decodeFields(bytes) : null
    },
  }
  return fields
}

// A conversation

/** One call's usage, before it is a row. */
export interface Call {
  /** The call id, else the row's index in `gen_metadata`. */
  id: string
  model: string
  at: number | null
  input: number
  output: number
  cacheRead: number
}

/** The calls of a conversation's tables: steps' times by call id, then each call's usage. */
export function conversationCalls(
  steps: readonly Uint8Array[],
  generations: readonly { idx: number; data: Uint8Array }[],
): Call[] {
  const times = new Map<string, number>()
  for (const blob of steps) {
    const fields = decodeFields(blob)
    const call = fields.message(9)?.string(11)
    const seconds = fields.message(1)?.int(1)
    if (call && seconds !== null && seconds !== undefined) times.set(call, seconds * 1000)
  }
  const calls: Call[] = []
  for (const { idx, data } of generations) {
    const gen = decodeFields(data).message(1)
    const usage = gen?.message(4)
    if (!gen || !usage) continue
    const input = usage.int(2) ?? 0
    const output = usage.int(3) ?? 0
    if (input + output <= 0) continue
    const call = usage.string(11) ?? ''
    calls.push({
      id: call || `#${idx}`,
      model: normalizeModel(gen.string(19)),
      at: call ? (times.get(call) ?? null) : null,
      input,
      output,
      cacheRead: usage.int(5) ?? 0,
    })
  }
  return calls
}

/**
 * A call as a row. Thinking (field 9) is left out, as the Mac app leaves it out of its totals
 * and cost; whether `output` already holds it is not known.
 */
function rowOf(conversation: string, call: Call, fallbackAt: number): UsageRow {
  return {
    key: `antigravity:${conversation}:${call.id}`,
    source: 'log',
    agentId: AGENT_ID,
    sessionId: conversation,
    project: null,
    model: call.model,
    at: call.at ?? fallbackAt,
    input: call.input,
    output: call.output,
    reasoning: null,
    cacheRead: call.cacheRead,
    cacheWrite: 0,
    cacheWrite1h: 0,
    turn: 0,
  }
}

function isBusy(error: unknown): boolean {
  const errcode = (error as { errcode?: unknown } | null)?.errcode
  if (typeof errcode !== 'number') return false
  const code = errcode & 0xff
  return code === SQLITE_BUSY || code === SQLITE_LOCKED
}

const blob = (value: SQLOutputValue | undefined): Uint8Array | null =>
  value instanceof Uint8Array && value.length > 0 ? value : null

/** A table's first column, or none when the conversation has no such table yet. */
function column(db: DatabaseSync, table: 'steps' | 'gen_metadata'): SQLOutputValue[][] {
  const known = db
    .prepare(`SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?`)
    .get(table)
  if (!known) return []
  const sql =
    table === 'steps' ? 'SELECT metadata FROM steps' : 'SELECT idx, data FROM gen_metadata'
  return db
    .prepare(sql)
    .all()
    .map((row) => Object.values(row))
}

/**
 * Reads a conversation read-only. A database no writer has open (no `-wal` beside it) holds every
 * page in its main file and is opened immutable, which needs no lock and leaves no `-wal` or
 * `-shm` behind in agy's folder.
 */
function readConversation(file: string, walExists: boolean): Call[] {
  let target: string | URL = file
  if (!walExists) {
    const url = pathToFileURL(file)
    url.searchParams.set('mode', 'ro')
    url.searchParams.set('immutable', '1')
    target = url
  }
  const db = new DatabaseSync(target, { readOnly: true, timeout: BUSY_TIMEOUT_MS })
  try {
    const steps = column(db, 'steps')
      .map(([metadata]) => blob(metadata))
      .filter((value) => value !== null)
    const generations = column(db, 'gen_metadata')
      .map(([idx, data]) => ({ idx: Number(idx ?? 0), data: blob(data) }))
      .filter((row): row is { idx: number; data: Uint8Array } => row.data !== null)
      .sort((a, b) => a.idx - b.idx)
    return conversationCalls(steps, generations)
  } finally {
    db.close()
  }
}

// Finding them

async function statOf(file: string): Promise<BigIntStats | null> {
  try {
    return await stat(file, { bigint: true })
  } catch {
    return null
  }
}

interface Conversation {
  file: string
  id: string
  size: number
  mtimeNs: bigint
  bytes: number
  wal: boolean
}

/** The stat of whichever of the database and its WAL was written last. */
async function conversationOf(file: string): Promise<Conversation | null> {
  const db = await statOf(file)
  if (!db?.isFile()) return null
  const wal = await statOf(`${file}-wal`)
  const newer = wal && wal.mtimeNs > db.mtimeNs ? wal : db
  return {
    file,
    id: path.basename(file, path.extname(file)),
    size: Number(db.size + (wal?.size ?? 0n)),
    mtimeNs: newer.mtimeNs,
    bytes: Number(db.size + (wal?.size ?? 0n)),
    wal: wal !== null,
  }
}

const MAX_CONVERSATION_DIRS = 200
const MAX_CONVERSATION_ENTRIES = 4_000
const MAX_CONVERSATION_DEPTH = 6

/** The conversation databases under the folders that exist; null when none does. */
async function listConversations(folders: readonly string[]): Promise<string[] | null> {
  let found = false
  const files: string[] = []
  let dirsScanned = 0
  let entriesSeen = 0
  for (const folder of folders) {
    let level: string[] = [folder]
    for (let depth = 0; level.length > 0 && depth <= MAX_CONVERSATION_DEPTH; depth++) {
      const next: string[] = []
      for (const dir of level) {
        if (dirsScanned >= MAX_CONVERSATION_DIRS || entriesSeen >= MAX_CONVERSATION_ENTRIES) break
        dirsScanned += 1
        let entries: Dirent[]
        try {
          entries = await readdir(dir, { withFileTypes: true })
        } catch (error) {
          const code = (error as NodeJS.ErrnoException).code
          if (code === 'ENOENT' || code === 'ENOTDIR') continue
          if (depth === 0) throw error
          continue
        }
        found = true
        for (const entry of entries) {
          if (entriesSeen >= MAX_CONVERSATION_ENTRIES) break
          entriesSeen += 1
          if (entry.name.startsWith('.') || entry.isSymbolicLink()) continue
          const full = path.join(dir, entry.name)
          if (entry.isDirectory()) {
            if (dirsScanned + next.length < MAX_CONVERSATION_DIRS) next.push(full)
            continue
          }
          if (!entry.isFile()) continue
          if (!EXTENSIONS.has(path.extname(entry.name))) continue
          files.push(full)
        }
      }
      level = next
    }
  }
  return found ? files.sort() : null
}

async function readText(file: string): Promise<string | null> {
  try {
    return await readFile(file, 'utf8')
  } catch {
    return null
  }
}

/**
 * The account agy is signed in to, for its quota reading: its windows and plan come from agy's
 * own `/usage`, which the agent host runs.
 */
async function storeAccount(context: QuotaContext): Promise<void> {
  const account = antigravityAccount(
    await readText(antigravityAuthStateFile(context.home)),
    await readText(antigravityProjectFile(context.home)),
    await readText(antigravityOnboardingFile(context.home)),
  )
  context.quota({ agentId: AGENT_ID, account, plan: null, windows: [], observedAt: null })
}

const cursorOf = (conversation: Conversation): FileCursor => ({
  id: conversation.file,
  agentId: AGENT_ID,
  size: conversation.size,
  mtimeNs: conversation.mtimeNs,
  offset: 0,
  tail: null,
  state: null,
})

async function scan(context: ScanContext): Promise<boolean> {
  await storeAccount(context)
  const files = await listConversations(conversationFolders(context.home, context.platform))
  if (!files) return false
  const pending: Conversation[] = []
  for (const file of files) {
    const conversation = await conversationOf(file)
    if (!conversation) continue
    if (unchanged(context.cursor(file), conversation.size, conversation.mtimeNs)) continue
    pending.push(conversation)
  }
  context.plan(
    pending.length,
    pending.reduce((sum, item) => sum + item.bytes, 0),
  )
  for (const conversation of pending) {
    context.signal.throwIfAborted()
    try {
      const calls = readConversation(conversation.file, conversation.wal)
      const fallbackAt = Number(conversation.mtimeNs / 1_000_000n)
      context.commit(
        calls.map((call) => rowOf(conversation.id, call, fallbackAt)),
        cursorOf(conversation),
      )
    } catch (error) {
      // Not committed, so the next scan tries it again.
      if (isBusy(error)) context.log('info', `${conversation.file} is busy; it is read next time`)
      else context.log('warn', `Could not read ${conversation.file}: ${(error as Error).message}`)
    }
    context.done(conversation.bytes)
    // Each read is synchronous; the worker answers requests between conversations.
    await new Promise((resolve) => setImmediate(resolve))
  }
  return true
}

export const antigravityReader: LogReader = {
  agentId: AGENT_ID,
  locations: (_env, home) => conversationFolders(home, process.platform),
  scan,
  quota: storeAccount,
}
