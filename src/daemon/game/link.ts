// The daemon's side of the idle game. It turns this computer's agent work into game facts, queues
// them on disk while the game service is out of reach (7 days at most, as the service accepts),
// and sends them over its own socket, which also tells the service this computer is online. While
// an app watches, a second socket follows the account as a viewer and its frames go on to the app.
//
// The game service is reached only when one is configured: SARTO_GAME_URL, or `server` in
// <data>/game.json. Until the account service issues game tokens, only a development service on
// this computer can be used, with development tokens.
//
// Nothing of this runs until the owner turns the game on for this computer, a choice kept in
// <data>/state/game-consent.json: until then the link reads none of its files, follows no work
// and opens no socket. Turning it off stops all of that again and deletes every fact not sent
// yet; the upload log, the owner's record of what was sent, stays.

import { randomBytes, randomUUID } from 'node:crypto'
import { appendFile, mkdir, open, readFile, rename, stat, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { WebSocket } from 'ws'
import {
  GAME_PROTOCOL_VERSION,
  type Command,
  type CommandResult,
  type GameFact,
  type GameStateView,
  type ServerFrame,
} from '@sarto/wire/game'
import type { HostEvent } from '@shared/agent-host'
import type { WorkFact } from '@shared/work-facts'
import type { Logger } from '../../core/log'
import { toGameFacts } from './facts'

export const GAME_URL_ENV = 'SARTO_GAME_URL'

const FACT_MAX_AGE_MS = 7 * 24 * 60 * 60_000
const MAX_QUEUE = 5000
const BATCH = 200
const RETRY_MS = 10_000
const MAX_BACKOFF_MS = 5 * 60_000
const BATCH_TIMEOUT_MS = 30_000
/** Rejections of the same batch in a row after which it is dropped. */
const MAX_REJECTIONS = 5
const SAVE_DELAY_MS = 1_000
const PING_MS = 30_000
const COMMAND_TIMEOUT_MS = 15_000
const UPLOAD_LOG_MAX_BYTES = 1024 * 1024
const LOOPBACK = new Set(['127.0.0.1', 'localhost', '[::1]', '::1'])
const QUEUE_FILE = 'game-queue.json'
const CONSENT_FILE = 'game-consent.json'
const UPLOAD_LOG = 'game-uploads.jsonl'

/** Why the link last failed, for the app to say in its own words. */
export type GameLinkErrorCode = 'needs_tokens' | 'unreachable' | 'rejected'

export interface GameLinkStatus {
  /** A game service is configured for this computer. */
  available: boolean
  /** The owner turned the game on for this computer. */
  optedIn: boolean
  /** Available, turned on and signed in: facts go to the game service and the game shows. */
  enabled: boolean
  server: string | null
  connected: boolean
  queued: number
  lastError: string | null
  lastErrorCode: GameLinkErrorCode | null
  /** Where every batch sent is recorded, for the owner to read. */
  uploadLog: string
}

export interface GameLinkOptions {
  dataPath: string
  env: NodeJS.ProcessEnv
  /** The signed-in account, or null. */
  account(): { id: string } | null
  /** Follows the agent host's work facts, from the call until the returned function's. */
  onHostEvent(listener: (event: HostEvent | null) => void): () => void
  /** Model names the public price snapshot lists. */
  knownModels(): Promise<ReadonlySet<string>>
  log: Logger
  onFrame(frame: ServerFrame): void
  onStatus(status: GameLinkStatus): void
  /** The first retry's delay; later ones double up to five minutes. */
  retryMs?: number
  batchTimeoutMs?: number
  saveDelayMs?: number
}

interface AccountQueue {
  seq: number
  queue: GameFact[]
}

interface PersistedFile {
  accounts: Record<string, AccountQueue>
}

interface ConsentFile {
  optedIn: boolean
  /** When the owner last changed it, in ms since the epoch; no fact from before goes. */
  at: number
}

/** Replaces `file` in one step, so a crash leaves the old contents or the new ones. */
async function writeAtomically(file: string, data: string): Promise<void> {
  const temp = `${file}.tmp`
  const handle = await open(temp, 'w', 0o600)
  try {
    await handle.writeFile(data)
    await handle.sync()
  } finally {
    await handle.close()
  }
  await rename(temp, file)
}

interface Socket {
  ws: WebSocket
  open: boolean
  ping: ReturnType<typeof setInterval> | null
}

interface Flight {
  accountId: string
  batch: string
  ids: Set<string>
  timer: ReturnType<typeof setTimeout>
}

/** The failures in a row of the batch at the head of an account's queue. */
interface HeadFailures {
  accountId: string
  head: string
  attempts: number
  rejections: number
}

export class GameLink {
  private server: string | null = null
  private secret = ''
  private accounts: Record<string, AccountQueue> = {}
  private activeAccountId: string | null = null
  private inFlight: Flight | null = null
  private failures: HeadFailures | null = null
  /** Holds the next batch back after a failure. */
  private backoff: ReturnType<typeof setTimeout> | null = null
  private daemon: Socket | null = null
  private viewer: Socket | null = null
  private viewers = 0
  private state: GameStateView | null = null
  private lastError: string | null = null
  private lastErrorCode: GameLinkErrorCode | null = null
  private retry: ReturnType<typeof setTimeout> | null = null
  private saveTimer: ReturnType<typeof setTimeout> | null = null
  private dirty = false
  private saving: Promise<void> = Promise.resolve()
  private uploads: Promise<void> = Promise.resolve()
  private knownModels: ReadonlySet<string> = new Set()
  private readonly commands = new Map<string, (result: CommandResult) => void>()
  private unsubscribe: (() => void) | null = null
  private stopped = false
  private optedIn = false
  private consentAt = 0
  private starting: Promise<void> | null = null
  private switching: Promise<unknown> = Promise.resolve()

  constructor(private readonly options: GameLinkOptions) {}

  start(): Promise<void> {
    this.starting ??= this.begin()
    return this.starting
  }

  private async begin(): Promise<void> {
    this.server = await this.configuredServer()
    const consent = await this.loadConsent()
    this.optedIn = consent.optedIn
    this.consentAt = consent.at
    if (this.optedIn) await this.wake()
    this.publishStatus()
  }

  /** Loads the game's files and follows this computer's work; only while the game is on. */
  private async wake(): Promise<void> {
    if (!this.server || this.unsubscribe || this.stopped) return
    await mkdir(this.stateDir(), { recursive: true })
    this.secret = await this.loadSecret()
    const { accounts, dropped } = await this.loadQueues()
    this.accounts = accounts
    if (dropped) this.save()
    this.activeAccountId = this.options.account()?.id ?? null
    await this.refreshModels()
    if (this.stopped || !this.optedIn) return
    this.unsubscribe = this.options.onHostEvent((event) => {
      if (event?.type === 'work.facts') this.received(event.facts)
    })
    this.connect()
  }

  /** Stops following this computer's work, closes the sockets and deletes the unsent facts. */
  private async sleep(): Promise<void> {
    this.unsubscribe?.()
    this.unsubscribe = null
    if (this.retry) {
      clearTimeout(this.retry)
      this.retry = null
    }
    this.clearBackoff()
    this.clearPendingCommands('link stopped')
    this.endFlight()
    this.failures = null
    this.close(this.daemon)
    this.close(this.viewer)
    this.daemon = this.viewer = null
    this.state = null
    this.setError(null)
    await this.dropQueues()
    this.accounts = {}
    this.secret = ''
  }

  /**
   * Turns the game on or off for this computer, as its owner chose in the app. Off closes the
   * sockets and deletes the facts not sent yet, of every account; the upload log stays.
   */
  setEnabled(enabled: boolean): Promise<GameLinkStatus> {
    const next = this.switching.then(() => this.switchTo(enabled))
    this.switching = next.catch(() => {})
    return next
  }

  private async switchTo(enabled: boolean): Promise<GameLinkStatus> {
    await this.starting?.catch(() => {})
    if (this.stopped || enabled === this.optedIn) return this.status()
    const at = Date.now()
    await mkdir(this.stateDir(), { recursive: true })
    await writeAtomically(
      path.join(this.stateDir(), CONSENT_FILE),
      JSON.stringify({ optedIn: enabled, at } satisfies ConsentFile),
    )
    this.optedIn = enabled
    this.consentAt = at
    if (enabled) await this.wake()
    else await this.sleep()
    this.publishStatus()
    return this.status()
  }

  async refreshModels(): Promise<void> {
    if (!this.optedIn) return
    const models = await this.options.knownModels().catch(() => null)
    if (models && models.size > 0) this.knownModels = models
  }

  /** Closes the sockets; resolves once the queue is on disk. */
  async stop(): Promise<void> {
    this.stopped = true
    this.unsubscribe?.()
    if (this.retry) {
      clearTimeout(this.retry)
      this.retry = null
    }
    this.clearBackoff()
    this.clearPendingCommands('link stopped')
    this.endFlight()
    this.close(this.daemon)
    this.close(this.viewer)
    this.daemon = this.viewer = null
    if (this.saveTimer) {
      clearTimeout(this.saveTimer)
      this.saveTimer = null
    }
    if (this.dirty) this.persist()
    await Promise.all([this.saving, this.uploads])
  }

  status(): GameLinkStatus {
    const account = this.options.account()
    const queued = account ? (this.accounts[account.id]?.queue.length ?? 0) : 0
    return {
      available: this.server !== null,
      optedIn: this.optedIn,
      enabled: this.server !== null && account !== null && this.optedIn,
      server: this.server,
      connected: this.daemon?.open ?? false,
      queued,
      lastError: this.lastError,
      lastErrorCode: this.lastErrorCode,
      uploadLog: path.join(this.stateDir(), UPLOAD_LOG),
    }
  }

  latestState(): GameStateView | null {
    return this.state
  }

  /** The signed-in account changed: start again as it. */
  accountChanged(): void {
    const nextId = this.options.account()?.id ?? null
    if (nextId === this.activeAccountId && this.daemon) return
    this.activeAccountId = nextId
    this.state = null
    this.setError(null)
    this.endFlight()
    this.failures = null
    this.clearBackoff()
    if (this.retry) {
      clearTimeout(this.retry)
      this.retry = null
    }
    this.clearPendingCommands('account changed')
    this.close(this.daemon)
    this.close(this.viewer)
    this.daemon = this.viewer = null
    this.connect()
  }

  /** An app began (+1) or stopped (-1) watching; the viewer socket is open while any does. */
  watch(delta: 1 | -1): void {
    this.viewers = Math.max(0, this.viewers + delta)
    if (this.viewers > 0 && !this.viewer && this.optedIn) this.viewer = this.open('app')
    if (this.viewers === 0 && this.viewer) {
      this.close(this.viewer)
      this.viewer = null
    }
  }

  // Errors are short codes, like the game service's own, which the app puts in its own words.
  async command(command: Omit<Command, 'v' | 'actionId' | 'actor'>): Promise<CommandResult> {
    const socket = this.viewer?.open ? this.viewer : this.daemon?.open ? this.daemon : null
    if (!socket) return { ok: false, error: 'unreachable' }
    const actionId = randomUUID()
    const full = { ...command, v: GAME_PROTOCOL_VERSION, actionId, actor: 'player' }
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.commands.delete(actionId)
        resolve({ ok: false, error: 'no answer' })
      }, COMMAND_TIMEOUT_MS)
      timer.unref()
      this.commands.set(actionId, (result) => {
        clearTimeout(timer)
        resolve(result)
      })
      socket.ws.send(JSON.stringify({ type: 'command', command: full }))
    })
  }

  private clearPendingCommands(error: string): void {
    for (const resolve of this.commands.values()) resolve({ ok: false, error })
    this.commands.clear()
  }

  private bucket(accountId: string): AccountQueue {
    let entry = this.accounts[accountId]
    if (!entry) {
      entry = { seq: 0, queue: [] }
      this.accounts[accountId] = entry
    }
    return entry
  }

  // ---- configuration ----

  private stateDir(): string {
    return path.join(this.options.dataPath, 'state')
  }

  private async configuredServer(): Promise<string | null> {
    let server = this.options.env[GAME_URL_ENV]?.trim() || null
    if (!server) {
      try {
        const file = JSON.parse(
          await readFile(path.join(this.options.dataPath, 'game.json'), 'utf8'),
        ) as { server?: unknown }
        if (typeof file.server === 'string' && file.server.trim()) server = file.server.trim()
      } catch {
        // No game configured.
      }
    }
    if (!server) return null
    try {
      const url = new URL(server)
      if (url.protocol !== 'http:' && url.protocol !== 'https:') throw new Error('protocol')
      return url.origin
    } catch {
      this.options.log.warn(`The game server ${server} is not an http(s) URL; the game stays off`)
      return null
    }
  }

  private token(kind: 'daemon' | 'app'): string | null {
    const account = this.options.account()
    if (!account || !this.server) return null
    // Until the account service issues game tokens, only a development service on this computer
    // takes development tokens.
    if (!LOOPBACK.has(new URL(this.server).hostname)) {
      this.setError(
        'needs_tokens',
        'This game server needs game tokens, which the account service does not issue yet',
      )
      return null
    }
    return `dev.${account.id}.${kind}`
  }

  private async loadSecret(): Promise<string> {
    const file = path.join(this.stateDir(), 'game-secret')
    try {
      const secret = (await readFile(file, 'utf8')).trim()
      if (secret.length >= 32) return secret
    } catch {
      // Made below.
    }
    const secret = randomBytes(32).toString('hex')
    await writeFile(file, secret, { mode: 0o600 })
    return secret
  }

  private async loadConsent(): Promise<ConsentFile> {
    try {
      const raw = JSON.parse(
        await readFile(path.join(this.stateDir(), CONSENT_FILE), 'utf8'),
      ) as Partial<ConsentFile>
      const at = typeof raw.at === 'number' && Number.isFinite(raw.at) ? raw.at : 0
      return { optedIn: raw.optedIn === true, at }
    } catch {
      return { optedIn: false, at: 0 }
    }
  }

  private async loadQueues(): Promise<{
    accounts: Record<string, AccountQueue>
    dropped: boolean
  }> {
    try {
      const raw = JSON.parse(
        await readFile(path.join(this.stateDir(), QUEUE_FILE), 'utf8'),
      ) as Partial<PersistedFile>
      // Nothing from before the owner turned the game on goes, nor anything older than it takes.
      const floor = Math.max(Date.now() - FACT_MAX_AGE_MS, this.consentAt)
      const out: Record<string, AccountQueue> = {}
      let dropped = false
      if (raw.accounts && typeof raw.accounts === 'object') {
        for (const [accountId, item] of Object.entries(raw.accounts)) {
          if (!item || typeof item !== 'object') continue
          const queue = Array.isArray(item.queue) ? item.queue : []
          const kept = queue.filter((f) => f.at >= floor)
          dropped ||= kept.length < queue.length
          out[accountId] = { seq: Number.isSafeInteger(item.seq) ? item.seq : 0, queue: kept }
        }
      }
      return { accounts: out, dropped }
    } catch {
      return { accounts: {}, dropped: false }
    }
  }

  /** Writes the queue soon, once for all the changes until then. */
  private save(): void {
    this.dirty = true
    if (this.saveTimer || this.stopped) return
    this.saveTimer = setTimeout(() => {
      this.saveTimer = null
      this.persist()
    }, this.options.saveDelayMs ?? SAVE_DELAY_MS)
    this.saveTimer.unref()
  }

  private persist(): void {
    this.saving = this.saving
      .then(() => this.writeQueue())
      .catch((error: unknown) => {
        this.options.log.warn(`Could not keep the game queue: ${(error as Error).message}`)
      })
  }

  private async writeQueue(): Promise<void> {
    if (!this.dirty) return
    this.dirty = false
    await writeAtomically(
      path.join(this.stateDir(), QUEUE_FILE),
      JSON.stringify({ accounts: this.accounts } satisfies PersistedFile),
    )
  }

  /**
   * Deletes every fact not sent yet, of every account, and writes that out now. The counters go
   * on, so facts sent after the game is on again do not look like a replay.
   */
  private async dropQueues(): Promise<void> {
    for (const entry of Object.values(this.accounts)) {
      if (entry.queue.length === 0) continue
      entry.queue = []
      this.dirty = true
    }
    if (this.saveTimer) {
      clearTimeout(this.saveTimer)
      this.saveTimer = null
    }
    if (this.dirty) this.persist()
    await this.saving
  }

  /** Keeps every batch sent, so the user can see what left the computer. */
  private logUpload(batch: string, facts: GameFact[]): void {
    const file = path.join(this.stateDir(), UPLOAD_LOG)
    const line = `${JSON.stringify({ at: Date.now(), batch, facts })}\n`
    this.uploads = this.uploads
      .then(async () => {
        const size = await stat(file)
          .then((s) => s.size)
          .catch(() => 0)
        if (size > UPLOAD_LOG_MAX_BYTES) await rename(file, `${file}.1`)
        await appendFile(file, line, { mode: 0o600 })
      })
      .catch(() => {})
  }

  // ---- facts ----

  private received(facts: WorkFact[]): void {
    const account = this.options.account()
    if (!account || !this.optedIn) return
    const bucket = this.bucket(account.id)
    const game = toGameFacts(facts, {
      secret: this.secret,
      knownModels: this.knownModels,
      nextSeq: () => ++bucket.seq,
      localHour: (at) => new Date(at).getHours(),
    })
    if (game.length === 0) return
    bucket.queue.push(...game)
    if (bucket.queue.length > MAX_QUEUE) bucket.queue.splice(0, bucket.queue.length - MAX_QUEUE)
    this.save()
    this.flush()
    this.publishStatus()
  }

  private flush(): void {
    const account = this.options.account()
    const socket = this.daemon
    if (!account || !socket?.open || this.inFlight || this.backoff) return
    const bucket = this.accounts[account.id]
    if (!bucket || bucket.queue.length === 0) return
    const floor = Date.now() - FACT_MAX_AGE_MS
    bucket.queue = bucket.queue.filter((f) => f.at >= floor)
    const facts = bucket.queue.slice(0, BATCH)
    if (facts.length === 0) return
    const batch = randomUUID()
    const flight: Flight = {
      accountId: account.id,
      batch,
      ids: new Set(facts.map((f) => f.id)),
      timer: setTimeout(
        () => this.unanswered(flight, socket),
        this.options.batchTimeoutMs ?? BATCH_TIMEOUT_MS,
      ),
    }
    flight.timer.unref()
    this.inFlight = flight
    socket.ws.send(
      JSON.stringify({
        type: 'facts',
        batch: { v: GAME_PROTOCOL_VERSION, batch, daemonVersion: this.daemonVersion(), facts },
      }),
    )
    this.logUpload(batch, facts)
  }

  private endFlight(): Flight | null {
    const flight = this.inFlight
    if (flight) clearTimeout(flight.timer)
    this.inFlight = null
    return flight
  }

  private acknowledged(): void {
    const flight = this.endFlight()
    if (!flight) return
    const bucket = this.accounts[flight.accountId]
    if (bucket) bucket.queue = bucket.queue.filter((f) => !flight.ids.has(f.id))
    this.failures = null
    this.save()
    this.publishStatus()
    this.flush()
  }

  /**
   * The service refused the batch in flight. Its error frames name no batch, so the one in flight
   * takes the blame; a batch refused for something else is sent again after the backoff, and the
   * service drops the facts it already has.
   */
  private rejected(error: string): void {
    const flight = this.endFlight()
    if (!flight) return
    const failures = this.failed(flight)
    failures.rejections += 1
    if (failures.rejections < MAX_REJECTIONS) {
      this.holdBack(failures.attempts)
      return
    }
    const bucket = this.accounts[flight.accountId]
    if (bucket) bucket.queue = bucket.queue.filter((f) => !flight.ids.has(f.id))
    this.failures = null
    this.options.log.warn(
      `The game service refused a batch of ${flight.ids.size} fact(s) ${MAX_REJECTIONS} times ` +
        `(${error}); dropping it`,
    )
    this.save()
    this.publishStatus()
    this.holdBack(1)
  }

  /** No answer in time: the socket is likely dead, so start it again and send the batch then. */
  private unanswered(flight: Flight, socket: Socket): void {
    if (this.inFlight !== flight) return
    this.endFlight()
    this.holdBack(this.failed(flight).attempts)
    this.options.log.warn('The game service did not answer a batch of facts; reconnecting')
    if (this.daemon === socket) socket.ws.terminate()
  }

  private failed(flight: Flight): HeadFailures {
    const head = this.accounts[flight.accountId]?.queue[0]?.id ?? ''
    const same = this.failures?.accountId === flight.accountId && this.failures.head === head
    if (!same || !this.failures) {
      this.failures = { accountId: flight.accountId, head, attempts: 0, rejections: 0 }
    }
    this.failures.attempts += 1
    return this.failures
  }

  private holdBack(attempts: number): void {
    this.clearBackoff()
    const base = this.options.retryMs ?? RETRY_MS
    const delay = Math.min(MAX_BACKOFF_MS, base * 2 ** Math.max(0, attempts - 1))
    this.backoff = setTimeout(() => {
      this.backoff = null
      this.flush()
    }, delay)
    this.backoff.unref()
  }

  private clearBackoff(): void {
    if (this.backoff) clearTimeout(this.backoff)
    this.backoff = null
  }

  private daemonVersion(): string {
    return (this.options.env.SARTO_DAEMON_VERSION ?? 'dev').slice(0, 64)
  }

  // ---- sockets ----

  private connect(): void {
    if (this.stopped) return
    if (this.optedIn) {
      if (!this.daemon) this.daemon = this.open('daemon')
      if (this.viewers > 0 && !this.viewer) this.viewer = this.open('app')
    }
    this.publishStatus()
  }

  private open(kind: 'daemon' | 'app'): Socket | null {
    const token = this.token(kind)
    if (!token || !this.server) {
      this.publishStatus()
      return null
    }
    const url = `${this.server.replace(/^http/, 'ws')}/v1/stream?token=${encodeURIComponent(token)}`
    const socket: Socket = { ws: new WebSocket(url), open: false, ping: null }
    socket.ws.on('open', () => {
      socket.open = true
      this.setError(null)
      socket.ping = setInterval(() => socket.ws.send(JSON.stringify({ type: 'ping' })), PING_MS)
      socket.ping.unref()
      if (kind === 'daemon') this.flush()
      this.publishStatus()
    })
    socket.ws.on('message', (data) => this.frame(kind, String(data)))
    socket.ws.on('error', (error) => {
      this.setError('unreachable', error.message)
    })
    socket.ws.on('close', () => {
      socket.open = false
      if (socket.ping) clearInterval(socket.ping)
      if (kind === 'daemon' && this.daemon === socket) {
        this.daemon = null
        this.endFlight()
        this.scheduleRetry()
      }
      if (kind === 'app' && this.viewer === socket) {
        this.viewer = null
        if (this.viewers > 0) this.scheduleRetry()
      }
      this.publishStatus()
    })
    return socket
  }

  private close(socket: Socket | null): void {
    if (!socket) return
    if (socket.ping) clearInterval(socket.ping)
    socket.ws.removeAllListeners('close')
    socket.ws.removeAllListeners('message')
    socket.ws.close()
  }

  private scheduleRetry(): void {
    if (this.stopped || this.retry) return
    this.retry = setTimeout(() => {
      this.retry = null
      this.connect()
    }, this.options.retryMs ?? RETRY_MS)
    this.retry.unref()
  }

  private frame(kind: 'daemon' | 'app', text: string): void {
    let frame: ServerFrame
    try {
      frame = JSON.parse(text) as ServerFrame
    } catch {
      return
    }
    switch (frame.type) {
      case 'factsResult':
        if (kind === 'daemon' && this.inFlight?.batch === frame.batch) this.acknowledged()
        return
      case 'commandResult': {
        const done = this.commands.get(frame.actionId)
        this.commands.delete(frame.actionId)
        done?.(frame.result)
        return
      }
      case 'error': {
        const error = typeof frame.error === 'string' ? frame.error.slice(0, 200) : 'error'
        this.setError('rejected', error)
        if (kind === 'daemon') this.rejected(error)
        this.publishStatus()
        return
      }
      case 'hello':
      case 'state':
        this.state = frame.state
        // Both sockets get every state; while a viewer is open, its copy goes on, in order with
        // its battle events.
        if (kind === 'app' || !this.viewer) {
          this.options.onFrame({ type: 'state', state: frame.state })
        }
        return
      default:
        // Battle events and notices reach the app from the viewer socket alone, once each.
        if (kind === 'app' || !this.viewer) this.options.onFrame(frame)
    }
  }

  private setError(code: GameLinkErrorCode | null, message: string | null = null): void {
    this.lastErrorCode = code
    this.lastError = code ? message : null
  }

  private publishStatus(): void {
    this.options.onStatus(this.status())
  }
}
