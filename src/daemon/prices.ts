// Keeps the daemon's model prices current: once a day it asks its Sarto server for the day's
// snapshot (`GET /v1/prices`) and keeps it in the data folder, where the usage pricing takes it
// over the snapshot bundled with the build. The request carries no account; a server without
// prices, or out of reach, leaves the kept snapshot as it was.

import { readJsonFile, writeFileAtomic } from '../core/json-file'
import type { Logger } from '../core/log'
import { isPriceSnapshot, type PriceSnapshot } from '@shared/usage-prices'

const DAY_MS = 24 * 60 * 60_000
const FIRST_DELAY_MS = 30_000
const REQUEST_TIMEOUT_MS = 60_000

/** The file the usage pricing reads: the snapshot, with the tag the server gave it. */
export type KeptPrices = PriceSnapshot & { etag?: string }

export interface PriceUpdatesOptions {
  /** The Sarto server the daemon belongs to. */
  origin(): string
  fetch: (url: string, init: RequestInit) => Promise<Response>
  /** `<data>/state/prices-server.json`. */
  file: string
  log: Logger
  intervalMs?: number
  firstDelayMs?: number
}

export class PriceUpdates {
  private timer: ReturnType<typeof setTimeout> | null = null
  private stopped = false

  constructor(private readonly options: PriceUpdatesOptions) {}

  start(): void {
    this.schedule(this.options.firstDelayMs ?? FIRST_DELAY_MS)
  }

  stop(): void {
    this.stopped = true
    if (this.timer) clearTimeout(this.timer)
    this.timer = null
  }

  /** Asks the server once: `updated` when a new snapshot was kept, else `unchanged` or `failed`. */
  async update(): Promise<'updated' | 'unchanged' | 'failed'> {
    const kept = await this.kept()
    let response: Response
    try {
      response = await this.options.fetch(`${this.options.origin()}/v1/prices`, {
        headers: {
          accept: 'application/json',
          ...(kept?.etag ? { 'if-none-match': kept.etag } : {}),
        },
        redirect: 'error',
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
      })
    } catch (error) {
      this.options.log.info(`Could not ask for the day's model prices: ${(error as Error).message}`)
      return 'failed'
    }
    if (response.status === 304) return 'unchanged'
    // An older server has no prices, or has none yet: the kept ones stay.
    if (!response.ok) return 'failed'
    let snapshot: unknown
    try {
      snapshot = await response.json()
    } catch {
      return 'failed'
    }
    if (!isPriceSnapshot(snapshot)) {
      this.options.log.warn('The server sent model prices in a shape the daemon does not take')
      return 'failed'
    }
    const etag = response.headers.get('etag') ?? undefined
    const next: KeptPrices = {
      asOf: snapshot.asOf,
      models: snapshot.models,
      ...(etag ? { etag } : {}),
    }
    await writeFileAtomic(this.options.file, JSON.stringify(next), 0o600)
    return 'updated'
  }

  private async kept(): Promise<KeptPrices | null> {
    const read = await readJsonFile(this.options.file)
    if (read.kind !== 'ok' || !isPriceSnapshot(read.value)) return null
    return read.value as KeptPrices
  }

  private schedule(delayMs: number): void {
    if (this.stopped) return
    this.timer = setTimeout(() => {
      void this.update()
        .catch((error: unknown) => {
          this.options.log.warn(`Updating the model prices failed: ${(error as Error).message}`)
        })
        .finally(() => this.schedule(this.options.intervalMs ?? DAY_MS))
    }, delayMs)
    this.timer.unref()
  }
}
