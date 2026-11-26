import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { FakeRelays } from './fake-relay'
import { importRelayKey, newRelaySeed, relayHostId } from './relay'
import { RelayHost } from './relay-host'

const MAIN = 'https://relay.example'

async function hostOn(relays: FakeRelays): Promise<RelayHost> {
  const key = await importRelayKey(await newRelaySeed())
  relays.accounts.set('token', 'account')
  return new RelayHost({
    main: MAIN,
    id: await relayHostId(key.publicKey),
    key,
    openSocket: relays.openSocket,
    fetchInfo: relays.fetchInfo,
    accepted: () => {},
    changed: () => {},
    log: () => {},
  })
}

describe('the host on the relay', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('still gives up on a relay that never answers after a retry during the sign-in', async () => {
    const relays = new FakeRelays()
    const server = relays.relay(MAIN)
    server.mode = 'silent'
    const host = await hostOn(relays)
    host.start()
    host.setToken('token')
    await vi.advanceTimersByTimeAsync(1000)
    expect(server.sockets.length).toBe(1)

    host.retry()
    await vi.advanceTimersByTimeAsync(10 * 60_000)

    // The socket that got no answer was dropped and others were tried in its place.
    expect(server.sockets.length).toBeGreaterThan(1)
    host.stop()
  })

  it('backs off from a relay that closes each sign-in once it is ready', async () => {
    const relays = new FakeRelays()
    const server = relays.relay(MAIN)
    const host = await hostOn(relays)
    host.start()
    host.setToken('token')
    // The host pings at once when the relay says ready; this relay then closes the socket.
    const dropping = setInterval(() => {
      for (const socket of server.sockets) {
        if (socket.readyState === socket.OPEN && socket.sent.includes('ping')) socket.closed(1000)
      }
    }, 20)
    await vi.advanceTimersByTimeAsync(60_000)
    clearInterval(dropping)

    // Each sign-in waits longer than the one before, as for a relay that cannot be reached.
    expect(server.sockets.length).toBeLessThan(15)
    host.stop()
  })

  it('stays signed in when the relay sends a message type it does not know', async () => {
    const relays = new FakeRelays()
    const server = relays.relay(MAIN)
    const host = await hostOn(relays)
    host.start()
    host.setToken('token')
    const socket = await vi.waitFor(() => {
      const first = server.sockets[0]
      if (!first?.sent.includes('ping')) throw new Error('not signed in yet')
      return first
    })

    socket.receive(JSON.stringify({ type: 'notice', text: 'from a later relay' }))
    await vi.advanceTimersByTimeAsync(5000)
    expect(socket.readyState).toBe(socket.OPEN)
    expect(server.sockets.length).toBe(1)
    host.stop()
  })
})
