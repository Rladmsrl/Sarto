// The thread worker's work, apart from the worker itself so tests can run it in their own thread.

import path from 'node:path'
import { INDEX_FILE, SearchIndex } from '../search/index'
import { Indexer, type IndexerOptions } from '../search/indexer'
import { IndexReads } from '../search/reads'
import { ThreadDb, ThreadDbError } from './db'
import type { ThreadReply, ThreadRequest, ThreadWorkerData } from './protocol'

/**
 * Opens the database at `file`, reports how with a `ready` reply, and returns the handler that
 * answers each request in the order it arrives.
 */
export function startThreadService(
  { file, reader }: ThreadWorkerData,
  reply: (message: ThreadReply) => void,
  now?: () => number,
  indexing?: IndexerOptions,
): (request: ThreadRequest) => void {
  const log = (level: 'info' | 'warn' | 'error', message: string): void =>
    reply({ type: 'log', level, message })
  let db: ThreadDb | null = null
  try {
    db = reader ? ThreadDb.openReader(file, log) : ThreadDb.open(file, log, now)
    reply({ type: 'ready', status: db.status })
  } catch (error) {
    log('error', `Could not open the thread database: ${(error as Error).message}`)
    reply({ type: 'ready', status: 'unavailable' })
  }
  // The search index lives beside the database: the writer keeps it current, and each worker
  // answers searches from it.
  const indexFile = path.join(path.dirname(file), INDEX_FILE)
  let indexer: Indexer | null = null
  let reads: IndexReads | null = null
  if (db) {
    try {
      if (!reader) {
        indexer = new Indexer(db, SearchIndex.open(indexFile, log), indexFile, log, indexing)
        indexer.start()
      }
      reads = new IndexReads(indexFile, db, log, indexer)
    } catch (error) {
      log('error', `Search is unavailable, its index did not open: ${(error as Error).message}`)
    }
  }
  let recoveries = db?.recoveries ?? 0
  return (request) => {
    if (!db) {
      reply({
        type: 'error',
        id: request.id,
        message: 'The thread database is not open',
        code: 'unavailable',
        text: { key: 'threadDb.notOpen' },
      })
      return
    }
    try {
      reply({ type: 'result', id: request.id, value: run(db, request, indexer, reads) })
    } catch (error) {
      const known = error instanceof ThreadDbError ? error : null
      reply({
        type: 'error',
        id: request.id,
        message: (error as Error).message,
        code: known?.code ?? null,
        ...(known?.text ? { text: known.text } : {}),
      })
    }
    if (db.recoveries !== recoveries) {
      recoveries = db.recoveries
      indexer?.recovered()
      reply({ type: 'recovered' })
    }
  }
}

function run(
  db: ThreadDb,
  request: ThreadRequest,
  indexer: Indexer | null,
  reads: IndexReads | null,
): unknown {
  switch (request.op) {
    case 'page':
      return db.page(
        request.sessionId,
        request.before,
        request.from,
        request.images,
        request.budget,
      )
    case 'tail':
      return db.tail(request.sessionId, request.from, request.images, request.budget)
    case 'entry':
      return db.entry(request.sessionId, request.entryId, request.images)
    case 'load':
      return db.load(request.sessionId)
    case 'write': {
      const before = indexer?.markBefore(request.sessionId) ?? null
      db.write(request.sessionId, request.change)
      indexer?.written(request.sessionId, request.change, before)
      return null
    }
    case 'remove':
      db.remove(request.sessionIds)
      indexer?.removed(request.sessionIds)
      return null
    case 'blob':
      return db.blob(request.sessionId, request.hash)
    case 'mentions':
      return db.mentions(request.sessionId, request.text)
    case 'outline':
      return db.outline(request.sessionId)
    case 'search':
      if (!reads)
        throw new ThreadDbError('The search index is not open', 'unavailable', {
          key: 'threadDb.searchNotOpen',
        })
      return reads.find(request.words)
    case 'find':
      if (!reads)
        throw new ThreadDbError('The search index is not open', 'unavailable', {
          key: 'threadDb.searchNotOpen',
        })
      return reads.findIn(request.sessionId, request.words, request.limit)
    case 'snippets':
      if (!reads)
        throw new ThreadDbError('The search index is not open', 'unavailable', {
          key: 'threadDb.searchNotOpen',
        })
      return reads.snippets(request.words, request.picks)
    case 'outputs':
      return db.outputs(request.sessionId)
    case 'setOutlineTitles':
      return db.setOutlineTitles(request.sessionId, request.titles)
    case 'origins':
      return db.origins(request.sessionId)
    case 'putOrigin':
      db.putOrigin(request.sessionId, request.origin)
      return null
    case 'close':
      indexer?.stop()
      reads?.close()
      db.close()
      return null
  }
}
