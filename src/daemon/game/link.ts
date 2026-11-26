// The daemon's side of the idle game. It turns this computer's agent work into game facts, queues
// them on disk while the game service is out of reach (7 days at most, as the service accepts),
// and sends them over its own socket, which also tells the service this computer is online. While
// an app watches, a second socket follows the account as a viewer and its frames go on to the app.
//
// The game service is reached only when one is configured: SARTO_GAME_URL, or `server` in
// <data>/game.json. Until the account service issues game tokens, only a development service on
// this computer can be used, with development tokens.

import { randomBytes, randomUUID } from 'node:crypto'
import { appendFile, mkdir, readFile, rename, stat, truncate, writeFile } from 'node:fs/promises'
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
const PING_MS = 30_000
const COMMAND_TIMEOUT_MS = 15_000
const UPLOAD_LOG_MAX_BYTES = 1024 * 1024
const LOOPBACK = new Set(['127.0.0.1', 'localhost', '[::1]', '::1'])

export interface GameLinkStatus {
  /** A game service is configured and the account is signed in. */
  enabled: boolean
  server: string | null
  connected: boolean
  queued: number
  lastError: string | null
}

export interface GameLinkOptions {
  dataPath: string
  env: NodeJS.ProcessEnv
  /** The signed-in account, or null. */
  account(): { id: string } | null
  /** Follows the agent host's work facts. */
  onHostEvent(listener: (event: HostEvent | null) => void): () => void
  /** Model names the public price snapshot lists. */
  knownModels(): Promise<ReadonlySet<string>>
  log: Logger
  onFrame(frame: ServerFrame): void
  onStatus(status: GameLinkStatus): void
  retryMs?: number
}

interface AccountQueue {
  seq: number
  queue: GameFact[]
}

interface PersistedFile {
  accounts: Record<string, AccountQueue>
}

interface Socket {
  ws: WebSocket
  open: boolean
  ping: ReturnType<typeof setInterval> | null
}

export class GameLink {
  private server: string | null = null
  private secret = ''
  private accounts: Record<string, AccountQueue> = {}
  private activeAccountId: string | null = null
  private inFlight: { accountId: string; batch: string; ids: Set<string> } | null = null
  private daemon: Socket | null = null
  private viewer: Socket | null = null
  private viewers = 0
  private state: GameStateView | null = null
  private lastError: string | null = null
  private retry: ReturnType<typeof setTimeout> | null = null
  private saving: Promise<void> = Promise.resolve()
  private knownModels: ReadonlySet<string> = new Set()
  private readonly commands = new Map<string, (result: CommandResult) => void>()
  private unsubscribe: (() => void) | null = null
  private stopped = false

  constructor(private readonly options: GameLinkOptions) {}

  async start(): Promise<void> {
    this.server = await this.configuredServer()
    if (!this.server) return
    await mkdir(this.stateDir(), { recursive: true })
    this.secret = await this.loadSecret()
    this.accounts = await this.loadQueues()
    this.activeAccountId = this.options.account()?.id ?? null
    await this.refreshModels()
    this.unsubscribe = this.options.onHostEvent((event) => {
      if (event?.type === 'work.facts') this.received(event.facts)
    })
    this.connect()
  }

  async refreshModels(): Promise<void> {
    const models = await this.options.knownModels().catch(() => null)
    if (models && models.size > 0) this.knownModels = models
  }

  stop(): void {
    this.stopped = true
    this.unsubscribe?.()
    if (this.retry) {
      clearTimeout(this.retry)
      this.retry = null
    }
    this.clearPendingCommands('The game link stopped')
    this.inFlight = null
    this.close(this.daemon)
    this.close(this.viewer)
    this.daemon = this.viewer = null
  }

  status(): GameLinkStatus {
    const account = this.options.account()
    const queued = account ? (this.accounts[account.id]?.queue.length ?? 0) : 0
    return {
      enabled: this.server !== null && account !== null,
      server: this.server,
      connected: this.daemon?.open ?? false,
      queued,
      lastError: this.lastError,
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
    this.lastError = null
    this.inFlight = null
    if (this.retry) {
      clearTimeout(this.retry)
      this.retry = null
    }
    this.clearPendingCommands('The signed-in account changed')
    this.close(this.daemon)
    this.close(this.viewer)
    this.daemon = this.viewer = null
    this.connect()
  }

  /** An app began (+1) or stopped (-1) watching; the viewer socket is open while any does. */
  watch(delta: 1 | -1): void {
    this.viewers = Math.max(0, this.viewers + delta)
    if (this.viewers > 0 && !this.viewer) this.viewer = this.open('app')
    if (this.viewers === 0 && this.viewer) {
      this.close(this.viewer)
      this.viewer = null
    }
  }

  async command(command: Omit<Command, 'v' | 'actionId' | 'actor'>): Promise<CommandResult> {
    const socket = this.viewer?.open ? this.viewer : this.daemon?.open ? this.daemon : null
    if (!socket) return { ok: false, error: 'The game service is out of reach' }
    const actionId = randomUUID()
    const full = { ...command, v: GAME_PROTOCOL_VERSION, actionId, actor: 'player' }
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.commands.delete(actionId)
        resolve({ ok: false, error: 'The game service did not answer' })
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
      this.lastError =
        'This game server needs game tokens, which the account service does not issue yet'
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

  private async loadQueues(): Promise<Record<string, AccountQueue>> {
    try {
      const raw = JSON.parse(
        await readFile(path.join(this.stateDir(), 'game-queue.json'), 'utf8'),
      ) as Partial<PersistedFile>
      const floor = Date.now() - FACT_MAX_AGE_MS
      const out: Record<string, AccountQueue> = {}
      if (raw.accounts && typeof raw.accounts === 'object') {
        for (const [accountId, item] of Object.entries(raw.accounts)) {
          if (!item || typeof item !== 'object') continue
          out[accountId] = {
            seq: Number.isSafeInteger(item.seq) ? item.seq : 0,
            queue: Array.isArray(item.queue) ? item.queue.filter((f) => f.at >= floor) : [],
          }
        }
      }
      return out
    } catch {
      return {}
    }
  }

  private save(): void {
    const data = JSON.stringify({ accounts: this.accounts } satisfies PersistedFile)
    const file = path.join(this.stateDir(), 'game-queue.json')
    this.saving = this.saving
      .then(async () => {
        await writeFile(`${file}.tmp`, data, { mode: 0o600 })
        await rename(`${file}.tmp`, file)
      })
      .catch((error: unknown) => {
        this.options.log.warn(`Could not keep the game queue: ${(error as Error).message}`)
      })
  }

  /** Keeps every batch sent, so the user can see what left the computer. */
  private logUpload(batch: string, facts: GameFact[]): void {
    const file = path.join(this.stateDir(), 'game-uploads.jsonl')
    void (async () => {
      const size = await stat(file)
        .then((s) => s.size)
        .catch(() => 0)
      if (size > UPLOAD_LOG_MAX_BYTES) await truncate(file, 0)
      await appendFile(file, `${JSON.stringify({ at: Date.now(), batch, facts })}\n`, {
        mode: 0o600,
      })
    })().catch(() => {})
  }

  // ---- facts ----

  private received(facts: WorkFact[]): void {
    const account = this.options.account()
    if (!account) return
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
    if (!account || !socket?.open || this.inFlight) return
    const bucket = this.accounts[account.id]
    if (!bucket || bucket.queue.length === 0) return
    const floor = Date.now() - FACT_MAX_AGE_MS
    bucket.queue = bucket.queue.filter((f) => f.at >= floor)
    const facts = bucket.queue.slice(0, BATCH)
    if (facts.length === 0) return
    const batch = randomUUID()
    this.inFlight = { accountId: account.id, batch, ids: new Set(facts.map((f) => f.id)) }
    socket.ws.send(
      JSON.stringify({
        type: 'facts',
        batch: { v: GAME_PROTOCOL_VERSION, batch, daemonVersion: this.daemonVersion(), facts },
      }),
    )
    this.logUpload(batch, facts)
  }

  private daemonVersion(): string {
    return (this.options.env.SARTO_DAEMON_VERSION ?? 'dev').slice(0, 64)
  }

  // ---- sockets ----

  private connect(): void {
    if (this.stopped) return
    if (!this.daemon) this.daemon = this.open('daemon')
    if (this.viewers > 0 && !this.viewer) this.viewer = this.open('app')
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
      this.lastError = null
      socket.ping = setInterval(() => socket.ws.send(JSON.stringify({ type: 'ping' })), PING_MS)
      socket.ping.unref()
      if (kind === 'daemon') this.flush()
      this.publishStatus()
    })
    socket.ws.on('message', (data) => this.frame(kind, String(data)))
    socket.ws.on('error', (error) => {
      this.lastError = error.message
    })
    socket.ws.on('close', () => {
      socket.open = false
      if (socket.ping) clearInterval(socket.ping)
      if (kind === 'daemon' && this.daemon === socket) {
        this.daemon = null
        this.inFlight = null
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
        if (this.inFlight?.batch === frame.batch) {
          const { accountId, ids } = this.inFlight
          const bucket = this.accounts[accountId]
          if (bucket) bucket.queue = bucket.queue.filter((f) => !ids.has(f.id))
          this.inFlight = null
          this.save()
          this.publishStatus()
          this.flush()
        }
        return
      case 'commandResult': {
        const done = this.commands.get(frame.actionId)
        this.commands.delete(frame.actionId)
        done?.(frame.result)
        return
      }
      case 'error':
        this.lastError = frame.error
        if (kind === 'daemon' && this.inFlight) {
          this.inFlight = null
          setTimeout(() => this.flush(), this.options.retryMs ?? RETRY_MS).unref()
        }
        return
      case 'hello':
      case 'state':
        this.state = frame.state
        this.options.onFrame({ type: 'state', state: frame.state })
        return
      default:
        // Battle events and notices reach the app from the viewer socket alone, once each.
        if (kind === 'app' || !this.viewer) this.options.onFrame(frame)
    }
  }

  private publishStatus(): void {
    this.options.onStatus(this.status())
  }
}
