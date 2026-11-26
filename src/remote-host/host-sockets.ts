// Sarto: the daemon's side of the sessions on other hosts, as main's HostSessions
// (src/core/host-sessions.ts) is the desktop app's, which needs Electron. Each connection on the
// hosts socket names one host first, then speaks that host's protocol as on the local agent host's
// socket: its requests go to the host under ids of this process's own, so connections never share
// one, and its answers come back under the connection's; the host's events reach every connection
// that named it (docs/sarto-remote-design.md).

import { portError } from '@shared/hosts-text'
import type { PortChannel } from '@shared/port-channel'
import type { PortError } from '@shared/port-rpc'
import { DEVICE_ID } from '@shared/remote/device'
import type { HostStatus } from '@shared/remote/hosts'
import type { LogFn } from '../agent-host/storage'

/** How long a request waits for a host whose connection is under way. */
export const HOLD_MS = 20_000

/** Requests held for one host while it connects; more fail at once. */
const MAX_HELD = 500

/** How long a new connection may take to name its host before it is closed. */
export const NAME_MS = 10_000

/** What a connection sends first. */
export interface HostsConnect {
  type: 'hosts:connect'
  hostId: string
}

/** What this process sends a connection beyond the host's own messages. */
export type HostSocketState =
  /** A session with the host is open: after a `closed`, what the app shows is read again. */
  | { type: 'hosts:open' }
  /** The session ended, and the requests in flight on it failed. */
  | { type: 'hosts:closed' }

type Answer = { type: 'response'; result: unknown } | { type: 'error'; error: PortError }

interface Connection {
  port: PortChannel
  hostId: string | null
  timer: ReturnType<typeof setTimeout> | null
}

interface InFlight {
  hostId: string
  connection: Connection
  id: number
}

interface Held {
  connection: Connection
  id: number
  method: string
  params: unknown
  timer: ReturnType<typeof setTimeout>
}

export interface HostSocketsOptions {
  log: LogFn
  holdMs?: number
  nameMs?: number
}

const offline = (): PortError => portError('host_offline', 'hostSockets.offline')
const ended = (): PortError => portError('host_restarted', 'hostSockets.ended')

/**
 * Two ends of an in-process port, for a host's session: what one sends the other hears on a later
 * turn, as a MessagePort delivers, and closing either closes both.
 */
export function portPair(): [PortChannel, PortChannel] {
  const make = () => ({
    listener: null as ((data: unknown) => void) | null,
    waiting: [] as unknown[],
    closeListeners: [] as (() => void)[],
  })
  const ends = [make(), make()]
  let closed = false
  const close = (): void => {
    if (closed) return
    closed = true
    for (const end of ends) {
      end.waiting.length = 0
      for (const notify of end.closeListeners.splice(0)) queueMicrotask(notify)
    }
  }
  const channel = (own: (typeof ends)[number], other: (typeof ends)[number]): PortChannel => ({
    send: (message) => {
      if (closed) return
      queueMicrotask(() => {
        if (closed) return
        if (other.listener) other.listener(message)
        else other.waiting.push(message)
      })
    },
    onMessage: (listener) => {
      own.listener = listener
      for (const message of own.waiting.splice(0)) listener(message)
    },
    onClose: (listener) => {
      if (closed) queueMicrotask(listener)
      else own.closeListeners.push(listener)
    },
    close,
  })
  return [channel(ends[0]!, ends[1]!), channel(ends[1]!, ends[0]!)]
}

export class HostSockets {
  /** This process's end of each open session's port, by host. */
  private readonly hosts = new Map<string, PortChannel>()
  private readonly connections = new Set<Connection>()
  private readonly inFlight = new Map<number, InFlight>()
  private readonly held = new Map<string, Held[]>()
  /** The hosts whose connection is under way, where requests wait rather than fail. */
  private connecting = new Set<string>()
  private nextId = 1

  constructor(private readonly options: HostSocketsOptions) {}

  /** HostClient's `openMainPort`: the link's end of a new session with `hostId`. */
  openMainPort(hostId: string): PortChannel {
    const [link, own] = portPair()
    this.opened(hostId, own)
    return link
  }

  /** A connection on the hosts socket. */
  accept(port: PortChannel): void {
    const connection: Connection = { port, hostId: null, timer: null }
    this.connections.add(connection)
    connection.timer = setTimeout(() => {
      if (connection.hostId !== null) return
      this.options.log('warn', 'A connection on the hosts socket named no host in time')
      port.close()
    }, this.options.nameMs ?? NAME_MS)
    port.onMessage((data) => this.fromConnection(connection, data))
    port.onClose(() => this.detach(connection))
  }

  /** The hosts as HostClient reports them; held requests fail once their host is not trying. */
  setHosts(hosts: readonly HostStatus[]): void {
    this.connecting = new Set(
      hosts.filter((host) => host.connection.state === 'connecting').map((host) => host.id),
    )
    for (const hostId of [...this.held.keys()]) {
      if (!this.connecting.has(hostId)) this.failHeld(hostId)
    }
  }

  /** The hosts whose session is open now. */
  openHosts(): string[] {
    return [...this.hosts.keys()]
  }

  /** The daemon stops: every session's port and every connection closes. */
  close(): void {
    for (const [hostId, port] of [...this.hosts]) this.ended(hostId, port)
    for (const hostId of [...this.held.keys()]) this.failHeld(hostId)
    for (const connection of [...this.connections]) {
      this.detach(connection)
      connection.port.close()
    }
  }

  private opened(hostId: string, port: PortChannel): void {
    const previous = this.hosts.get(hostId)
    if (previous) this.ended(hostId, previous)
    this.hosts.set(hostId, port)
    port.onMessage((data) => this.fromHost(hostId, port, data))
    port.onClose(() => {
      if (this.hosts.get(hostId) === port) this.ended(hostId, port)
    })
    this.broadcast(hostId, { type: 'hosts:open' })
    for (const held of this.held.get(hostId)?.splice(0) ?? []) {
      clearTimeout(held.timer)
      this.send(held.connection, held.id, hostId, held.method, held.params)
    }
    this.held.delete(hostId)
  }

  private ended(hostId: string, port: PortChannel): void {
    this.hosts.delete(hostId)
    port.close()
    for (const [ownId, request] of [...this.inFlight]) {
      if (request.hostId !== hostId) continue
      this.inFlight.delete(ownId)
      this.answer(request.connection, request.id, { type: 'error', error: ended() })
    }
    this.broadcast(hostId, { type: 'hosts:closed' })
  }

  private detach(connection: Connection): void {
    if (!this.connections.delete(connection)) return
    if (connection.timer) clearTimeout(connection.timer)
    for (const [ownId, request] of [...this.inFlight]) {
      if (request.connection === connection) this.inFlight.delete(ownId)
    }
    for (const [hostId, list] of this.held) {
      const kept = list.filter((held) => {
        if (held.connection !== connection) return true
        clearTimeout(held.timer)
        return false
      })
      if (kept.length > 0) this.held.set(hostId, kept)
      else this.held.delete(hostId)
    }
  }

  private fromConnection(connection: Connection, data: unknown): void {
    if (!this.connections.has(connection)) return
    const message = (typeof data === 'object' && data !== null ? data : {}) as Record<
      string,
      unknown
    >
    if (connection.hostId === null) {
      if (message.type !== 'hosts:connect' || typeof message.hostId !== 'string') {
        this.options.log('warn', 'A connection on the hosts socket did not name its host first')
        return connection.port.close()
      }
      if (!DEVICE_ID.test(message.hostId)) {
        this.options.log('warn', 'A connection on the hosts socket named a host that is not one')
        return connection.port.close()
      }
      if (connection.timer) clearTimeout(connection.timer)
      connection.timer = null
      connection.hostId = message.hostId
      if (this.hosts.has(message.hostId)) connection.port.send({ type: 'hosts:open' })
      return
    }
    const { type, id, method, params } = message
    if (type !== 'request' || typeof id !== 'number' || !Number.isSafeInteger(id)) {
      this.options.log('warn', 'Ignored a message on the hosts socket that is no request')
      return
    }
    if (typeof method !== 'string') {
      return this.answer(connection, id, {
        type: 'error',
        error: { code: 'invalid_params', message: 'A request names its method' },
      })
    }
    this.ask(connection, id, connection.hostId, method, params)
  }

  /** Sends now, holds while the host connects, or fails at once. */
  private ask(
    connection: Connection,
    id: number,
    hostId: string,
    method: string,
    params: unknown,
  ): void {
    if (this.hosts.has(hostId)) return this.send(connection, id, hostId, method, params)
    const list = this.held.get(hostId) ?? []
    if (!this.connecting.has(hostId) || list.length >= MAX_HELD) {
      return this.answer(connection, id, { type: 'error', error: offline() })
    }
    const timer = setTimeout(() => {
      const waiting = this.held.get(hostId)
      const at = waiting?.indexOf(held) ?? -1
      if (at < 0) return
      waiting!.splice(at, 1)
      if (waiting!.length === 0) this.held.delete(hostId)
      this.answer(connection, id, { type: 'error', error: offline() })
    }, this.options.holdMs ?? HOLD_MS)
    const held: Held = { connection, id, method, params, timer }
    list.push(held)
    this.held.set(hostId, list)
  }

  private failHeld(hostId: string): void {
    const list = this.held.get(hostId) ?? []
    this.held.delete(hostId)
    for (const held of list) {
      clearTimeout(held.timer)
      this.answer(held.connection, held.id, { type: 'error', error: offline() })
    }
  }

  private send(
    connection: Connection,
    id: number,
    hostId: string,
    method: string,
    params: unknown,
  ): void {
    const port = this.hosts.get(hostId)
    if (!port) return this.answer(connection, id, { type: 'error', error: offline() })
    const ownId = this.nextId++
    this.inFlight.set(ownId, { hostId, connection, id })
    port.send({ type: 'request', id: ownId, method, params })
  }

  private fromHost(hostId: string, port: PortChannel, data: unknown): void {
    if (this.hosts.get(hostId) !== port || typeof data !== 'object' || data === null) return
    const message = data as Record<string, unknown>
    if (message.type === 'response' || message.type === 'error') {
      const request = typeof message.id === 'number' ? this.inFlight.get(message.id) : undefined
      if (!request || request.hostId !== hostId) return
      this.inFlight.delete(message.id as number)
      return this.answer(
        request.connection,
        request.id,
        message.type === 'response'
          ? { type: 'response', result: message.result }
          : { type: 'error', error: message.error as PortError },
      )
    }
    const passed =
      message.type === 'event' ||
      message.type === 'resync' ||
      (message.type === 'terminals.restarted' && Array.isArray(message.ids))
    if (passed) this.broadcast(hostId, message)
  }

  private answer(connection: Connection, id: number, answer: Answer): void {
    if (this.connections.has(connection)) connection.port.send({ ...answer, id })
  }

  private broadcast(hostId: string, message: unknown): void {
    for (const connection of this.connections) {
      if (connection.hostId === hostId) connection.port.send(message)
    }
  }
}
