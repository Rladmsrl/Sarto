// The usage worker's work, apart from the worker itself so tests can run it in their own thread.
// Requests are answered in order; a scan runs in the background, so queries keep being answered
// while the logs are read.

import { unwatchFile, watchFile, type Stats } from 'node:fs'
import { readFile } from 'node:fs/promises'
import type { ScanProgress } from '@shared/usage'
import { UsageDb } from './db'
import type { LogReader, QuotaContext, ScanContext } from './model'
import { Pricing } from './pricing'
import type { PriceFiles, ScanRequest, ScanResult, UsageReply, UsageRequest } from './protocol'

/** How often progress notices go out while a scan writes. */
export const NOTICE_MS = 200
/**
 * How often change notices do. Each has an open usage page read its figures again, which takes
 * the worker 100-200 ms on a year of logs, so more often would slow the scan it reports on.
 */
export const CHANGE_MS = 1000

/** How often the price files are looked at for a change. */
export const PRICE_POLL_MS = 30_000

export interface ScanOutcome {
  results: ScanResult[]
  cancelled: boolean
}

/**
 * Reads a prices file now and again whenever it changes, off the host's event loop; `apply` gets
 * its JSON, or null while it is missing or unreadable. Returns what stops watching it.
 */
function watchPrices(
  file: string,
  interval: number,
  apply: (value: unknown) => void,
  log: (level: 'info' | 'warn' | 'error', message: string) => void,
): () => void {
  // Missing is where the prices start, so a file that is not there changes nothing.
  let last: string | null = null
  let reading: Promise<void> = Promise.resolve()
  const load = (): void => {
    reading = reading.then(async () => {
      const text = await readFile(file, 'utf8').catch(() => null)
      if (text === last) return
      last = text
      if (text === null) return apply(null)
      try {
        apply(JSON.parse(text))
      } catch {
        log('warn', `${file} is not JSON; its prices are not used`)
        apply(null)
      }
    })
  }
  const listener = (now: Stats, before: Stats): void => {
    if (now.mtimeMs !== before.mtimeMs || now.size !== before.size) load()
  }
  watchFile(file, { interval, persistent: false }, listener)
  load()
  return () => unwatchFile(file, listener)
}

/** Calls `run` at most once per `ms`, the last call coming through. */
function throttle(run: () => void, ms: number): { call(): void; flush(): void } {
  let timer: ReturnType<typeof setTimeout> | null = null
  let last = 0
  const fire = (): void => {
    timer = null
    last = Date.now()
    run()
  }
  return {
    call() {
      if (timer) return
      const wait = last + ms - Date.now()
      if (wait <= 0) fire()
      else timer = setTimeout(fire, wait)
    },
    flush() {
      if (!timer) return
      clearTimeout(timer)
      fire()
    },
  }
}

export function startUsageService(
  file: string,
  readers: readonly LogReader[],
  reply: (message: UsageReply) => void,
  now?: () => number,
  prices: PriceFiles = {},
): (request: UsageRequest) => void {
  const log = (level: 'info' | 'warn' | 'error', message: string): void =>
    reply({ type: 'log', level, message })
  const pricing = new Pricing()
  let db: UsageDb | null = null
  try {
    db = UsageDb.open(file, log, now, pricing)
    reply({ type: 'ready', status: db.open ? db.status : 'newer' })
  } catch (error) {
    log('error', `Could not open the usage database: ${(error as Error).message}`)
    reply({ type: 'ready', status: 'unavailable' })
  }

  const changed = throttle(() => reply({ type: 'changed' }), CHANGE_MS)
  const unwatch: (() => void)[] = []
  if (prices.override) {
    unwatch.push(
      watchPrices(
        prices.override,
        prices.pollMs ?? PRICE_POLL_MS,
        (value) => {
          pricing.setOverride(value)
          changed.call()
        },
        log,
      ),
    )
  }
  if (prices.server) {
    unwatch.push(
      watchPrices(
        prices.server,
        prices.pollMs ?? PRICE_POLL_MS,
        (value) => {
          const used = pricing.setServer(value)
          if (value !== null && !used) {
            log('info', `${prices.server} is not a valid snapshot newer than the bundled one`)
          }
          changed.call()
        },
        log,
      ),
    )
  }
  let progress: ScanProgress | null = null
  const progressed = throttle(() => reply({ type: 'progress', progress }), NOTICE_MS)
  let scanning: AbortController | null = null
  // Scans run one after another; a request during one waits for it.
  let queue: Promise<unknown> = Promise.resolve()

  async function scan(store: UsageDb, request: ScanRequest): Promise<ScanOutcome> {
    const controller = new AbortController()
    scanning = controller
    progress = { files: 0, bytes: 0, doneFiles: 0, doneBytes: 0 }
    progressed.call()
    const results: ScanResult[] = []
    let cancelled = false
    try {
      for (const agentId of request.agents) {
        const reader = readers.find((r) => r.agentId === agentId)
        if (!reader) continue
        const context: ScanContext = {
          env: request.envs[agentId] ?? {},
          home: request.home,
          platform: request.platform,
          signal: controller.signal,
          cursor: (id) => store.cursor(id),
          commit: (rows, cursor) => {
            if (store.write(rows, cursor) > 0) changed.call()
          },
          plan: (files, bytes) => {
            progress!.files += files
            progress!.bytes += bytes
            progressed.call()
          },
          done: (bytes) => {
            progress!.doneFiles++
            progress!.doneBytes += bytes
            progressed.call()
          },
          log: (level, message) => log(level, `${agentId}: ${message}`),
          storedQuota: (id) => store.storedQuota(id),
          quota: (reading, state = null) => {
            if (store.putQuota(reading, 'files', state)) changed.call()
          },
        }
        try {
          results.push({ agentId, found: await reader.scan(context), error: null })
        } catch (error) {
          if (controller.signal.aborted) {
            cancelled = true
            break
          }
          const message = (error as Error)?.message ?? String(error)
          log('warn', `Reading ${agentId}'s logs failed: ${message}`)
          results.push({ agentId, found: true, error: message })
        }
      }
    } finally {
      scanning = null
      progress = null
      changed.flush()
      progressed.call()
      progressed.flush()
    }
    return { results, cancelled }
  }

  let refreshing: AbortController | null = null

  /** Each agent's quota alone, read by its reader's `quota`; resolves with how many changed. */
  async function refreshQuotas(store: UsageDb, request: ScanRequest): Promise<number> {
    const controller = new AbortController()
    refreshing = controller
    let count = 0
    try {
      for (const agentId of request.agents) {
        const reader = readers.find((r) => r.agentId === agentId)
        if (!reader?.quota || controller.signal.aborted) continue
        const context: QuotaContext = {
          env: request.envs[agentId] ?? {},
          home: request.home,
          platform: request.platform,
          signal: controller.signal,
          log: (level, message) => log(level, `${agentId}: ${message}`),
          storedQuota: (id) => store.storedQuota(id),
          quota: (reading, state = null) => {
            if (!store.putQuota(reading, 'files', state)) return
            count++
            changed.call()
          },
        }
        try {
          await reader.quota(context)
        } catch (error) {
          if (controller.signal.aborted) break
          log('warn', `Reading ${agentId}'s quota failed: ${(error as Error).message}`)
        }
      }
    } finally {
      if (refreshing === controller) refreshing = null
    }
    return count
  }

  return (request) => {
    const answer = (run: () => unknown): void => {
      try {
        reply({ type: 'result', id: request.id, value: run() })
      } catch (error) {
        reply({ type: 'error', id: request.id, message: (error as Error).message })
      }
    }
    if (request.op === 'cancel') {
      scanning?.abort()
      answer(() => null)
      return
    }
    if (request.op === 'close') for (const stop of unwatch.splice(0)) stop()
    if (!db || !db.open) {
      if (request.op === 'close') {
        answer(() => null)
        return
      }
      reply({ type: 'error', id: request.id, message: 'The usage database is not open' })
      return
    }
    const store = db
    switch (request.op) {
      case 'scan':
      case 'removeLogs': {
        // Both wait for the scan in progress, so a re-import never races the reader it resets.
        const run =
          request.op === 'scan'
            ? () => scan(store, request)
            : async () => {
                store.removeLogs(request.agentId)
                changed.call()
                return null
              }
        queue = queue.then(run, run).then(
          (value) => reply({ type: 'result', id: request.id, value }),
          (error: unknown) =>
            reply({ type: 'error', id: request.id, message: (error as Error).message }),
        )
        return
      }
      case 'refreshQuotas':
        refreshQuotas(store, request).then(
          (value) => reply({ type: 'result', id: request.id, value }),
          (error: unknown) =>
            reply({ type: 'error', id: request.id, message: (error as Error).message }),
        )
        return
      case 'overview':
        answer(() => store.overview(request))
        return
      case 'write':
        answer(() => {
          const count = store.write(request.rows)
          if (count > 0) changed.call()
          return count
        })
        return
      case 'summary':
        answer(() =>
          store.summary(
            request.dayStarts,
            request.from,
            request.to,
            request.sources,
            request.clock,
            request.includeRemote === true,
          ),
        )
        return
      case 'totals':
        answer(() =>
          store.totals(request.from, request.to, request.sources, request.includeRemote === true),
        )
        return
      case 'stats':
        answer(() => store.stats())
        return
      case 'quotas':
        answer(() => ({ ...store.quotas(), activity: store.activity(request.sources) }))
        return
      case 'putQuotas':
        answer(() => {
          let count = 0
          for (const reading of request.readings) if (store.putQuota(reading, 'agent')) count++
          return count
        })
        return
      case 'remoteStats':
        answer(() => store.remoteStats())
        return
      case 'exportBuckets':
        answer(() => store.exportBuckets())
        return
      case 'setRemoteUsage':
        answer(() => {
          store.setRemoteUsage(request.devices, request.present)
          changed.call()
          return null
        })
        return
      case 'clearRecord':
        answer(() => {
          store.clearRecord()
          changed.call()
          return null
        })
        return
      case 'close':
        scanning?.abort()
        refreshing?.abort()
        answer(() => {
          store.close()
          return null
        })
        return
    }
  }
}
