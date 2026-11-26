// Runs read-only SQLite queries against Google Antigravity (`agy`) local databases on a dedicated
// worker thread so synchronous `node:sqlite` I/O never blocks the agent-host event loop.

import { Worker } from 'node:worker_threads'

export interface RawGenRow {
  idx: number
  data: Uint8Array
}

export interface RawStepRow {
  idx: number
  metadata: Uint8Array
}

export interface RawSubagentRow {
  id: string
  parentId: string
  status: string
  killed: boolean
  agent: string
  title: string
}

export interface RawRequestsPage {
  hasTable: boolean
  rows: RawGenRow[]
  steps: RawStepRow[]
}

export interface RawRequestsSummary {
  hasTable: boolean
  count: number
  tokens: {
    input: number
    cacheRead: number
    output: number
    reasoning: number | null
  } | null
}

export interface RawRequestRecord {
  hasTable: boolean
  row: RawGenRow | null
  steps: RawStepRow[]
}

type WorkerRequest =
  | { id: number; op: 'genSince'; file: string; afterIdx: number }
  | { id: number; op: 'genLatest'; file: string }
  | { id: number; op: 'subagents'; file: string; parentIds: string[] }
  | { id: number; op: 'requestsPage'; file: string; cursor: number | null; pageSize: number }
  | { id: number; op: 'requestsSummary'; file: string }
  | { id: number; op: 'requestRaw'; file: string; idx: number }

type WorkerReply =
  { id: number; ok: true; value: unknown } | { id: number; ok: false; message: string }

const IDLE_MS = 30_000

// Self-contained CJS worker using only Node built-ins so it works in both Vitest and the bundled
// daemon without requiring a separate Rollup entrypoint.
const WORKER_SOURCE = `'use strict';
const fs = require('node:fs');
const { pathToFileURL } = require('node:url');
const { parentPort } = require('node:worker_threads');
const { DatabaseSync } = require('node:sqlite');

function isFile(file) {
  try {
    return fs.statSync(file).isFile();
  } catch {
    return false;
  }
}

function asBlob(value) {
  return value instanceof Uint8Array && value.length > 0 ? value : null;
}

function openDb(file, immutable) {
  let target = file;
  if (immutable) {
    const url = pathToFileURL(file);
    url.searchParams.set('mode', 'ro');
    url.searchParams.set('immutable', '1');
    target = url;
  }
  return new DatabaseSync(target, { readOnly: true, timeout: 0 });
}

function withConversationDb(file, fn) {
  if (!isFile(file)) return null;
  const walBefore = isFile(file + '-wal');
  let db;
  try {
    db = openDb(file, !walBefore);
  } catch {
    return null;
  }
  let result;
  try {
    result = fn(db);
  } finally {
    db.close();
  }
  // If agy created a -wal file while we opened with immutable=1, re-read with WAL visibility.
  if (!walBefore && isFile(file + '-wal')) {
    let walDb;
    try {
      walDb = openDb(file, false);
    } catch {
      return result;
    }
    try {
      return fn(walDb);
    } finally {
      walDb.close();
    }
  }
  return result;
}

function hasTable(db, name) {
  return (
    db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?").get(name) !==
    undefined
  );
}

// Minimal protobuf wire-format scanner matching src/agent-host/usage/readers/antigravity.ts.
const decoder = new TextDecoder();

function readVarint(buf, offset) {
  let result = 0n;
  let shift = 0n;
  let pos = offset;
  while (pos < buf.length && shift <= 63n) {
    const byte = buf[pos++];
    result |= BigInt(byte & 0x7f) << shift;
    if ((byte & 0x80) === 0) return { value: result, next: pos };
    shift += 7n;
  }
  return null;
}

function decodeFields(buf) {
  const ints = new Map();
  const bytes = new Map();
  let pos = 0;
  while (pos < buf.length) {
    const tag = readVarint(buf, pos);
    if (!tag) break;
    pos = tag.next;
    const field = Number(tag.value >> 3n);
    const wire = Number(tag.value & 7n);
    if (field <= 0) break;
    if (wire === 0) {
      const val = readVarint(buf, pos);
      if (!val) break;
      pos = val.next;
      if (!ints.has(field)) ints.set(field, Number(val.value));
    } else if (wire === 1) {
      if (pos + 8 > buf.length) break;
      pos += 8;
    } else if (wire === 2) {
      const len = readVarint(buf, pos);
      if (!len) break;
      pos = len.next;
      const size = Number(len.value);
      if (size < 0 || pos + size > buf.length) break;
      if (!bytes.has(field)) bytes.set(field, buf.subarray(pos, pos + size));
      pos += size;
    } else if (wire === 5) {
      if (pos + 4 > buf.length) break;
      pos += 4;
    } else {
      break;
    }
  }
  return {
    int(field) {
      const v = ints.get(field);
      return v !== undefined && Number.isSafeInteger(v) ? v : null;
    },
    string(field) {
      const b = bytes.get(field);
      return b ? decoder.decode(b) : null;
    },
    message(field) {
      const b = bytes.get(field);
      return b ? decodeFields(b) : null;
    },
  };
}

function genCallId(data) {
  const usage = decodeFields(data).message(1)?.message(4);
  if (!usage) return null;
  return usage.string(11) ?? usage.string(7) ?? null;
}

function genTokenSummary(data) {
  const usage = decodeFields(data).message(1)?.message(4);
  if (!usage) return null;
  const input = usage.int(2) ?? 0;
  const output = usage.int(3) ?? 0;
  const cacheRead = usage.int(5) ?? 0;
  if (input < 0 || output < 0 || cacheRead < 0) return null;
  if (input + cacheRead + output <= 0) return null;
  const rawThinking = usage.int(9);
  const reasoning = rawThinking !== null && rawThinking >= 0 ? rawThinking : null;
  return { input, cacheRead, output, reasoning };
}

function stepMatches(metadata, genIdxs, callIds) {
  const fields = decodeFields(metadata);
  const genIdx = fields.message(20)?.int(3) ?? null;
  if (genIdx !== null && genIdxs.has(genIdx)) return true;
  if (callIds.size > 0) {
    const callId = fields.message(9)?.string(11) ?? null;
    if (callId !== null && callIds.has(callId)) return true;
  }
  return false;
}

function readMatchingSteps(db, genIdxs, callIds) {
  if (genIdxs.size === 0 && callIds.size === 0) return [];
  if (!hasTable(db, 'steps')) return [];
  const out = [];
  const stmt = db.prepare('SELECT idx, metadata FROM steps ORDER BY idx');
  for (const row of stmt.iterate()) {
    const blob = asBlob(row.metadata);
    if (!blob) continue;
    if (stepMatches(blob, genIdxs, callIds)) {
      out.push({ idx: Number(row.idx ?? 0), metadata: Uint8Array.from(blob) });
    }
  }
  return out;
}

function handle(req) {
  switch (req.op) {
    case 'genSince':
      return (
        withConversationDb(req.file, (db) => {
          try {
            if (!hasTable(db, 'gen_metadata')) return [];
            const rows = db
              .prepare('SELECT idx, data FROM gen_metadata WHERE idx > ? ORDER BY idx')
              .all(req.afterIdx);
            const out = [];
            for (const row of rows) {
              const data = asBlob(row.data);
              if (data) out.push({ idx: Number(row.idx ?? 0), data: Uint8Array.from(data) });
            }
            return out;
          } catch {
            return [];
          }
        }) ?? []
      );

    case 'genLatest':
      return (
        withConversationDb(req.file, (db) => {
          try {
            if (!hasTable(db, 'gen_metadata')) return null;
            const row = db
              .prepare('SELECT idx, data FROM gen_metadata ORDER BY idx DESC LIMIT 1')
              .get();
            if (!row) return null;
            const data = asBlob(row.data);
            return data ? { idx: Number(row.idx ?? 0), data: Uint8Array.from(data) } : null;
          } catch {
            return null;
          }
        }) ?? null
      );

    case 'subagents': {
      if (req.parentIds.length === 0 || !isFile(req.file)) return [];
      const db = new DatabaseSync(req.file, { readOnly: true, timeout: 0 });
      try {
        const placeholders = req.parentIds.map(() => '?').join(', ');
        const rows = db
          .prepare(
            'SELECT conversation_id, parent_conversation_id, status, killed, agent_name, title ' +
              'FROM conversation_summaries ' +
              'WHERE parent_conversation_id IN (' +
              placeholders +
              ') ORDER BY rowid',
          )
          .all(...req.parentIds);
        const out = [];
        for (const row of rows) {
          const id = row.conversation_id;
          const parentId = row.parent_conversation_id;
          if (typeof id !== 'string' || typeof parentId !== 'string' || id === '' || id === parentId) {
            continue;
          }
          out.push({
            id,
            parentId,
            status: typeof row.status === 'string' ? row.status : '',
            killed: row.killed === 1 || row.killed === 1n,
            agent: typeof row.agent_name === 'string' ? row.agent_name : '',
            title: typeof row.title === 'string' ? row.title : '',
          });
        }
        return out;
      } finally {
        db.close();
      }
    }

    case 'requestsPage':
      return withConversationDb(req.file, (db) => {
        if (!hasTable(db, 'gen_metadata')) return { hasTable: false, rows: [], steps: [] };
        const limit = req.pageSize + 1;
        const rawRows =
          req.cursor !== null
            ? db
                .prepare('SELECT idx, data FROM gen_metadata WHERE idx < ? ORDER BY idx DESC LIMIT ?')
                .all(req.cursor, limit)
            : db.prepare('SELECT idx, data FROM gen_metadata ORDER BY idx DESC LIMIT ?').all(limit);
        const rows = [];
        for (const row of rawRows) {
          const blob = asBlob(row.data);
          if (blob) rows.push({ idx: Number(row.idx ?? 0), data: Uint8Array.from(blob) });
        }
        const pageRows = rows.length > req.pageSize ? rows.slice(0, req.pageSize) : rows;
        const genIdxs = new Set();
        const callIds = new Set();
        for (const row of pageRows) {
          genIdxs.add(row.idx);
          const cid = genCallId(row.data);
          if (cid) callIds.add(cid);
        }
        const steps = readMatchingSteps(db, genIdxs, callIds);
        return { hasTable: true, rows, steps };
      });

    case 'requestsSummary':
      return withConversationDb(req.file, (db) => {
        if (!hasTable(db, 'gen_metadata')) return { hasTable: false, count: 0, tokens: null };
        let count = 0;
        let input = 0;
        let cacheRead = 0;
        let output = 0;
        let reasoning = null;
        const stmt = db.prepare('SELECT idx, data FROM gen_metadata ORDER BY idx');
        for (const row of stmt.iterate()) {
          const blob = asBlob(row.data);
          if (!blob) continue;
          const t = genTokenSummary(blob);
          if (!t) continue;
          count++;
          input += t.input;
          cacheRead += t.cacheRead;
          output += t.output;
          if (t.reasoning !== null) reasoning = (reasoning ?? 0) + t.reasoning;
        }
        return {
          hasTable: true,
          count,
          tokens: count > 0 ? { input, cacheRead, output, reasoning } : null,
        };
      });

    case 'requestRaw':
      return withConversationDb(req.file, (db) => {
        if (!hasTable(db, 'gen_metadata')) return { hasTable: false, row: null, steps: [] };
        const found = db.prepare('SELECT idx, data FROM gen_metadata WHERE idx = ?').get(req.idx);
        const blob = asBlob(found && found.data);
        if (!blob) return { hasTable: true, row: null, steps: [] };
        const data = Uint8Array.from(blob);
        const genIdxs = new Set([req.idx]);
        const callIds = new Set();
        const cid = genCallId(data);
        if (cid) callIds.add(cid);
        const steps = readMatchingSteps(db, genIdxs, callIds);
        return { hasTable: true, row: { idx: req.idx, data }, steps };
      });
  }
}

parentPort.on('message', (req) => {
  try {
    parentPort.postMessage({ id: req.id, ok: true, value: handle(req) });
  } catch (error) {
    parentPort.postMessage({
      id: req.id,
      ok: false,
      message: error instanceof Error ? error.message : String(error),
    });
  }
});
`

type Pending = { resolve: (value: unknown) => void; reject: (error: Error) => void }
type WithoutId<T> = T extends unknown ? Omit<T, 'id'> : never

class AgySqlitePool {
  private worker: Worker | null = null
  private readonly pending = new Map<number, Pending>()
  private nextId = 1
  private idleTimer: ReturnType<typeof setTimeout> | null = null

  private ensureWorker(): Worker {
    if (this.worker) return this.worker
    const worker = new Worker(WORKER_SOURCE, { eval: true })
    worker.unref()
    worker.on('message', (reply: WorkerReply) => {
      const entry = this.pending.get(reply.id)
      this.pending.delete(reply.id)
      this.updateIdle()
      if (!entry) return
      if (reply.ok) entry.resolve(reply.value)
      else entry.reject(new Error(reply.message))
    })
    worker.on('error', (error) => {
      this.failAll(worker, error instanceof Error ? error : new Error(String(error)))
    })
    worker.on('exit', (code) => {
      if (this.worker === worker) {
        this.failAll(worker, new Error(`Agy SQLite worker exited with code ${code}`))
      }
    })
    this.worker = worker
    return worker
  }

  private failAll(worker: Worker, error: Error): void {
    if (this.worker !== worker) return
    this.worker = null
    if (this.idleTimer) {
      clearTimeout(this.idleTimer)
      this.idleTimer = null
    }
    for (const entry of this.pending.values()) entry.reject(error)
    this.pending.clear()
  }

  private updateIdle(): void {
    if (!this.worker) return
    if (this.pending.size > 0) {
      this.worker.ref()
      if (this.idleTimer) {
        clearTimeout(this.idleTimer)
        this.idleTimer = null
      }
      return
    }
    this.worker.unref()
    if (!this.idleTimer) {
      this.idleTimer = setTimeout(() => {
        this.idleTimer = null
        if (this.pending.size === 0 && this.worker) {
          const stale = this.worker
          this.worker = null
          void stale.terminate()
        }
      }, IDLE_MS)
      this.idleTimer.unref?.()
    }
  }

  run<T>(request: WithoutId<WorkerRequest>): Promise<T> {
    const worker = this.ensureWorker()
    const id = this.nextId++
    const promise = new Promise<T>((resolve, reject) => {
      this.pending.set(id, { resolve: resolve as (value: unknown) => void, reject })
    })
    this.updateIdle()
    worker.postMessage({ ...request, id })
    return promise
  }

  async shutdown(): Promise<void> {
    if (this.idleTimer) {
      clearTimeout(this.idleTimer)
      this.idleTimer = null
    }
    const worker = this.worker
    this.worker = null
    for (const entry of this.pending.values()) {
      entry.reject(new Error('Agy SQLite worker stopped'))
    }
    this.pending.clear()
    if (worker) await worker.terminate()
  }
}

const pool = new AgySqlitePool()

export function agyReadGenSince(file: string, afterIdx: number): Promise<RawGenRow[]> {
  return pool.run<RawGenRow[]>({ op: 'genSince', file, afterIdx })
}

export function agyReadGenLatest(file: string): Promise<RawGenRow | null> {
  return pool.run<RawGenRow | null>({ op: 'genLatest', file })
}

export function agyReadSubagentChildren(
  file: string,
  parentIds: readonly string[],
): Promise<RawSubagentRow[]> {
  return pool.run<RawSubagentRow[]>({ op: 'subagents', file, parentIds: [...parentIds] })
}

export function agyReadRequestsPage(
  file: string,
  cursor: number | null,
  pageSize: number,
): Promise<RawRequestsPage | null> {
  return pool.run<RawRequestsPage | null>({ op: 'requestsPage', file, cursor, pageSize })
}

export function agyReadRequestsSummary(file: string): Promise<RawRequestsSummary | null> {
  return pool.run<RawRequestsSummary | null>({ op: 'requestsSummary', file })
}

export function agyReadRequestRaw(file: string, idx: number): Promise<RawRequestRecord | null> {
  return pool.run<RawRequestRecord | null>({ op: 'requestRaw', file, idx })
}

export function shutdownAgySqliteWorker(): Promise<void> {
  return pool.shutdown()
}
