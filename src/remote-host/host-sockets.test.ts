import { afterEach, describe, expect, it, vi } from 'vitest'
import type { PortChannel } from '@shared/port-channel'
import type { HostStatus } from '@shared/remote/hosts'
import { HostSockets } from './host-sockets'
import { memoryPorts } from './testing/memory'

const A = 'a'.repeat(32)
const B = 'b'.repeat(32)

/** The app's end of a connection on the hosts socket, and what it heard. */
function connect(sockets: HostSockets): { port: PortChannel; heard: unknown[]; closed(): boolean } {
  const [app, daemon] = memoryPorts()
  const heard: unknown[] = []
  let closed = false
  app.onMessage((message) => heard.push(message))
  app.onClose(() => (closed = true))
  sockets.accept(daemon)
  return { port: app, heard, closed: () => closed }
}

/** HostClient's side of a session: the link's end, and the requests the host got. */
function open(sockets: HostSockets, hostId: string): { port: PortChannel; got: unknown[] } {
  const port = sockets.openMainPort(hostId)
  const got: unknown[] = []
  port.onMessage((message) => got.push(message))
  return { port, got }
}

function status(id: string, state: HostStatus['connection']['state']): HostStatus {
  return { id, connection: { state } } as HostStatus
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 0))

afterEach(() => {
  vi.useRealTimers()
})

describe('the hosts socket', () => {
  it("routes each connection's requests to its host and answers under its own ids", async () => {
    const sockets = new HostSockets({ log: () => {} })
    const a = open(sockets, A)
    const b = open(sockets, B)
    const one = connect(sockets)
    const two = connect(sockets)
    one.port.send({ type: 'hosts:connect', hostId: A })
    two.port.send({ type: 'hosts:connect', hostId: B })
    await settle()
    one.port.send({ type: 'request', id: 1, method: 'sessions.list', params: null })
    two.port.send({ type: 'request', id: 1, method: 'sessions.list', params: null })
    await settle()
    await settle()
    const toA = a.got[0] as { id: number; method: string }
    const toB = b.got[0] as { id: number; method: string }
    expect(toA.method).toBe('sessions.list')
    // The same id from two connections reaches the hosts under ids that differ.
    expect(toA.id).not.toBe(toB.id)
    b.port.send({ type: 'response', id: toB.id, result: 'from b' })
    a.port.send({ type: 'response', id: toA.id, result: 'from a' })
    await settle()
    await settle()
    expect(one.heard).toContainEqual({ type: 'response', id: 1, result: 'from a' })
    expect(two.heard).toContainEqual({ type: 'response', id: 1, result: 'from b' })
    expect(one.heard).not.toContainEqual({ type: 'response', id: 1, result: 'from b' })
  })

  it('gives events only to the connections of their host', async () => {
    const sockets = new HostSockets({ log: () => {} })
    const a = open(sockets, A)
    open(sockets, B)
    const one = connect(sockets)
    const two = connect(sockets)
    one.port.send({ type: 'hosts:connect', hostId: A })
    two.port.send({ type: 'hosts:connect', hostId: B })
    await settle()
    a.port.send({ type: 'event', event: { type: 'session.patches' } })
    a.port.send({ type: 'resync' })
    a.port.send({ type: 'welcome' })
    await settle()
    await settle()
    expect(one.heard).toEqual([
      { type: 'hosts:open' },
      { type: 'event', event: { type: 'session.patches' } },
      { type: 'resync' },
    ])
    expect(two.heard).toEqual([{ type: 'hosts:open' }])
  })

  it('takes nothing before the connection names its host', async () => {
    const sockets = new HostSockets({ log: () => {} })
    const a = open(sockets, A)
    const app = connect(sockets)
    app.port.send({ type: 'request', id: 1, method: 'sessions.list', params: null })
    await settle()
    await settle()
    expect(app.closed()).toBe(true)
    expect(a.got).toEqual([])

    const bad = connect(sockets)
    bad.port.send({ type: 'hosts:connect', hostId: '../agent' })
    await settle()
    await settle()
    expect(bad.closed()).toBe(true)
  })

  it('closes a connection that names no host in time', async () => {
    vi.useFakeTimers()
    const sockets = new HostSockets({ log: () => {}, nameMs: 1000 })
    const app = connect(sockets)
    await vi.advanceTimersByTimeAsync(1001)
    expect(app.closed()).toBe(true)
  })

  it('holds requests while the host connects and sends them once it is open', async () => {
    const sockets = new HostSockets({ log: () => {} })
    sockets.setHosts([status(A, 'connecting')])
    const app = connect(sockets)
    app.port.send({ type: 'hosts:connect', hostId: A })
    app.port.send({ type: 'request', id: 7, method: 'sessions.list', params: null })
    await settle()
    await settle()
    const a = open(sockets, A)
    await settle()
    expect(a.got).toMatchObject([{ type: 'request', method: 'sessions.list' }])
    expect(app.heard).toEqual([{ type: 'hosts:open' }])
  })

  it('fails requests for a host that is not connecting, or that took too long', async () => {
    vi.useFakeTimers()
    const sockets = new HostSockets({ log: () => {}, holdMs: 1000 })
    const app = connect(sockets)
    app.port.send({ type: 'hosts:connect', hostId: A })
    app.port.send({ type: 'request', id: 1, method: 'sessions.list', params: null })
    await vi.advanceTimersByTimeAsync(10)
    expect(app.heard).toMatchObject([{ type: 'error', id: 1, error: { code: 'host_offline' } }])

    sockets.setHosts([status(A, 'connecting')])
    app.port.send({ type: 'request', id: 2, method: 'sessions.list', params: null })
    await vi.advanceTimersByTimeAsync(1010)
    expect(app.heard).toMatchObject([
      { id: 1 },
      { type: 'error', id: 2, error: { code: 'host_offline' } },
    ])
  })

  it('fails what was held once the host stops trying', async () => {
    const sockets = new HostSockets({ log: () => {} })
    sockets.setHosts([status(A, 'connecting')])
    const app = connect(sockets)
    app.port.send({ type: 'hosts:connect', hostId: A })
    app.port.send({ type: 'request', id: 3, method: 'sessions.list', params: null })
    await settle()
    await settle()
    sockets.setHosts([status(A, 'offline')])
    await settle()
    await settle()
    expect(app.heard).toMatchObject([{ type: 'error', id: 3, error: { code: 'host_offline' } }])
  })

  it('fails requests in flight when the session ends, and says so', async () => {
    const sockets = new HostSockets({ log: () => {} })
    const a = open(sockets, A)
    const app = connect(sockets)
    app.port.send({ type: 'hosts:connect', hostId: A })
    app.port.send({ type: 'request', id: 4, method: 'sessions.list', params: null })
    await settle()
    await settle()
    expect(a.got).toHaveLength(1)
    a.port.close()
    await settle()
    await settle()
    expect(app.heard).toMatchObject([
      { type: 'hosts:open' },
      { type: 'error', id: 4, error: { code: 'host_restarted' } },
      { type: 'hosts:closed' },
    ])
    expect(sockets.openHosts()).toEqual([])
  })

  it('drops answers for a connection that closed', async () => {
    const sockets = new HostSockets({ log: () => {} })
    const a = open(sockets, A)
    const app = connect(sockets)
    app.port.send({ type: 'hosts:connect', hostId: A })
    app.port.send({ type: 'request', id: 5, method: 'sessions.list', params: null })
    await settle()
    await settle()
    const sent = a.got[0] as { id: number }
    app.port.close()
    await settle()
    await settle()
    a.port.send({ type: 'response', id: sent.id, result: null })
    await settle()
    await settle()
    expect(app.heard).toEqual([{ type: 'hosts:open' }])
  })
})
