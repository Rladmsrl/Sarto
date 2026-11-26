// The daemon's own port to its agent host, as a window's: the requests the sync makes about what
// the host keeps, such as pinned models, workflows and routines, and the events that say one
// changed. The host may restart, so the port connects again when it closes.

import type { HostEvent, HostMethod, HostParams, HostResult } from '@shared/agent-host'
import type { PortChannel } from '@shared/port-channel'
import { PortRequestError, type FromPort, type ToPort } from '@shared/port-rpc'
import { connectPort } from '@shared/socket-port'
import type { Logger } from '../../core/log'
import type { SyncAgentHost } from './service'

const REQUEST_TIMEOUT_MS = 30_000
const RECONNECT_MS = 5_000

interface Waiting {
  resolve(result: unknown): void
  reject(error: Error): void
  timer: ReturnType<typeof setTimeout>
}

export class AgentHostLink implements SyncAgentHost {
  private port: PortChannel<ToPort> | null = null
  private connecting: Promise<PortChannel<ToPort>> | null = null
  private nextId = 1
  private readonly waiting = new Map<number, Waiting>()
  private readonly listeners = new Set<(event: HostEvent | null) => void>()
  private retry: ReturnType<typeof setTimeout> | null = null
  private stopped = false

  constructor(
    private readonly options: {
      /** The agent host's socket once it runs; rejects while it cannot. */
      socket(): Promise<string>
      log: Logger
      /** The events this port follows; the sync's, the agents' options, by default. */
      events?: HostEvent['type'][]
    },
  ) {}

  /** Connects now, so the host's events arrive before the first request. */
  start(): void {
    void this.connect().catch(() => this.scheduleRetry())
  }

  stop(): void {
    this.stopped = true
    if (this.retry) clearTimeout(this.retry)
    this.retry = null
    const port = this.port
    this.port = null
    port?.close()
    this.failWaiting('The sync stopped')
  }

  async request<M extends HostMethod>(method: M, params: HostParams<M>): Promise<HostResult<M>> {
    // A host that is slow to start holds the sync no longer than an answer would.
    let timer: ReturnType<typeof setTimeout> | undefined
    const port = await Promise.race([
      this.connect(),
      new Promise<never>((_, reject) => {
        timer = setTimeout(
          () => reject(new Error('The agent host did not start')),
          REQUEST_TIMEOUT_MS,
        )
        timer.unref()
      }),
    ]).finally(() => clearTimeout(timer))
    return (await this.send(port, method, params)) as HostResult<M>
  }

  onEvent(listener: (event: HostEvent | null) => void): () => void {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  private send(port: PortChannel<ToPort>, method: string, params: unknown): Promise<unknown> {
    const id = this.nextId++
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.waiting.delete(id)
        reject(new Error(`The agent host did not answer ${method}`))
      }, REQUEST_TIMEOUT_MS)
      timer.unref()
      this.waiting.set(id, { resolve, reject, timer })
      port.send({ type: 'request', id, method, params })
    })
  }

  private connect(): Promise<PortChannel<ToPort>> {
    if (this.port) return Promise.resolve(this.port)
    this.connecting ??= (async () => {
      if (this.stopped) throw new Error('The sync stopped')
      const port = await connectPort<ToPort>(await this.options.socket())
      if (this.stopped) {
        port.close()
        throw new Error('The sync stopped')
      }
      port.onMessage((data) => this.received(data))
      port.onClose(() => this.closed(port))
      this.port = port
      // The host serves a port as a window's from its first request, and sends it events after.
      // The sync follows the agents' options alone; every other event would cross for nothing.
      const types = this.options.events ?? ['agent.options']
      await this.send(port, 'events.select', { types }).catch(() => {})
      if (types.includes('agent.options')) {
        await this.send(port, 'agents.options', undefined).catch(() => {})
      }
      this.emit(null)
      return port
    })().finally(() => {
      this.connecting = null
    })
    return this.connecting
  }

  private received(data: unknown): void {
    const message = data as FromPort<HostEvent> | null
    if (message?.type === 'event') {
      this.emit(message.event)
      return
    }
    if (message?.type !== 'response' && message?.type !== 'error') return
    const waiting = this.waiting.get(message.id)
    if (!waiting) return
    this.waiting.delete(message.id)
    clearTimeout(waiting.timer)
    if (message.type === 'response') waiting.resolve(message.result)
    else waiting.reject(new PortRequestError(message.error))
  }

  private emit(event: HostEvent | null): void {
    for (const listener of this.listeners) {
      try {
        listener(event)
      } catch (error) {
        this.options.log.warn(`A sync listener failed: ${(error as Error).message}`)
      }
    }
  }

  private closed(port: PortChannel<ToPort>): void {
    if (this.port !== port) return
    this.port = null
    this.failWaiting('The agent host closed its port')
    this.scheduleRetry()
  }

  private failWaiting(reason: string): void {
    for (const waiting of this.waiting.values()) {
      clearTimeout(waiting.timer)
      waiting.reject(new Error(reason))
    }
    this.waiting.clear()
  }

  private scheduleRetry(): void {
    if (this.stopped || this.retry) return
    this.retry = setTimeout(() => {
      this.retry = null
      void this.connect().catch(() => this.scheduleRetry())
    }, RECONNECT_MS)
    this.retry.unref()
  }
}
