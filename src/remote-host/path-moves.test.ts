// This computer as a device moving its session between paths: from the relay to a direct address
// once the host is reachable there, keeping the relay on standby, and back to the standby once the
// direct path goes. Nothing the host sent is lost or repeated, and no drop shows meanwhile.

import { mkdtempSync, rmSync } from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { FakeRelays } from '@shared/remote/fake-relay'
import type { HostAdminEvent } from '@shared/remote/host-admin'
import type { HostConnection } from '@shared/remote/hosts'
import type { KeepaliveTimings } from '@shared/remote/keepalive'
import { generateKeyPair } from '@shared/remote/noise'
import type { DirectAddress } from '@shared/remote/protocol'
import { importRelayKey, newRelaySeed, relayHostId } from '@shared/remote/relay'
import { RelayHost } from '@shared/remote/relay-host'
import type { Transport } from '@shared/remote/transport'
import { webSocketTransport } from '@shared/remote/websocket-transport'
import { ActivityLog } from './activity'
import { HostClient } from './client'
import { DeviceStore } from './devices'
import { DiscoveryRequests } from './discovery'
import { HostStore } from './hosts'
import { RemoteServer } from './server'
import { memoryPorts, memoryTransports } from './testing/memory'

const MAIN = 'https://relay.test'
const HK = 'https://hk-1.relay.test'
const LAN: DirectAddress = { host: '192.168.1.8', port: 47821 }
const log = (): void => {}
const cleanups: (() => Promise<void> | void)[] = []

afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup()
})

function tempDir(): string {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'sarto-path-moves-'))
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }))
  return dir
}

/** The host hears what comes through the relay `ms` late, as a relay far away; sends `sendMs`. */
function late(transport: Transport, ms: number, sendMs = 0): Transport {
  return {
    ...transport,
    ...(sendMs > 0
      ? { send: (message: Uint8Array) => void setTimeout(() => transport.send(message), sendMs) }
      : {}),
    onMessage: (listener) =>
      transport.onMessage((message) => void setTimeout(() => listener(message), ms)),
    onClose: (listener) => transport.onClose(() => void setTimeout(listener, ms)),
  }
}

/**
 * A host on the relay at MAIN, which it hears through `relayLate` ms late and sends through
 * `sendsLate` ms late.
 */
async function setup({
  sendsLate = 0,
  relayLate = 100,
  keepalive,
  wrapRelay,
}: {
  sendsLate?: number
  relayLate?: number
  keepalive?: KeepaliveTimings
  wrapRelay?: (transport: Transport) => Transport
} = {}) {
  const relays = new FakeRelays()
  relays.accounts.set('host-token', 'account')
  relays.accounts.set('laptop-token', 'account')

  const hostDir = tempDir()
  const hostKey = await generateKeyPair()
  const laptopKey = await generateKeyPair()
  const relayKey = await importRelayKey(await newRelaySeed())
  const relayId = await relayHostId(relayKey.publicKey)
  const devices = await DeviceStore.load(hostDir, log)
  await devices.add({
    publicKey: Buffer.from(laptopKey.publicKey).toString('base64'),
    name: 'Laptop',
    kind: 'desktop',
    platform: 'darwin',
    model: '',
  })
  const server: RemoteServer = new RemoteServer({
    staticKey: hostKey,
    devices,
    activity: await ActivityLog.load(hostDir, log),
    discovery: new DiscoveryRequests({ send: () => {} }),
    host: { name: 'Studio', platform: 'darwin', version: '0.0.0-test' },
    uploads: path.join(hostDir, 'uploads'),
    openAgentPort: async () => memoryPorts()[0],
    relay: () => ({ id: relayId, urls: [MAIN] }),
    changed: () => {},
    log,
  })
  const relay = new RelayHost({
    main: MAIN,
    id: relayId,
    key: relayKey,
    openSocket: relays.openSocket,
    fetchInfo: relays.fetchInfo,
    accepted: (socket) =>
      void webSocketTransport(socket, true).then((transport) =>
        server.accept(
          wrapRelay
            ? wrapRelay(transport)
            : socket.url.startsWith(HK.replace('https', 'wss'))
              ? transport
              : late(transport, relayLate, sendsLate),
          'relay',
        ),
      ),
    profile: () => null,
    changed: () => {},
    log,
  })
  relay.start()
  relay.setToken('host-token')
  cleanups.push(async () => {
    relay.stop()
    await server.stop('stopping')
  })

  // The host's address on the network this computer may join, and its connections there.
  // With `cut`, the direct path goes as soon as the session is on it, before the standby notice.
  const lan = { up: false, cut: false, cuts: 0, tries: 0, ends: [] as Transport[] }
  const hosts = await HostStore.load(tempDir(), log)
  const host = (await hosts.add({
    publicKey: Buffer.from(hostKey.publicKey).toString('base64'),
    name: 'Studio',
    platform: 'darwin',
    version: '0.0.0-test',
    addresses: [],
    deviceName: 'Laptop',
    relay: { id: relayId, urls: [MAIN] },
  }))!
  // What reached main, and every connection state the host had.
  const main: unknown[] = []
  const states: HostConnection['state'][] = []
  const client: HostClient = new HostClient({
    key: laptopKey,
    hosts,
    client: { kind: 'desktop', version: '1.0.0', platform: 'macOS 26.1' },
    name: () => 'Laptop',
    openMainPort: async () => {
      const [ours, theirs] = memoryPorts()
      theirs.onMessage((message) => main.push(message))
      return ours
    },
    changed: () => {
      const state = client.list()[0]?.connection.state
      if (state && state !== states.at(-1)) states.push(state)
      if (lan.cut && via() === 'direct') {
        lan.up = false
        lan.cuts++
        for (const end of lan.ends) end.close()
      }
    },
    pairing: () => {},
    log,
    connect: async (address) => {
      if (address.host === LAN.host) lan.tries++
      if (!lan.up || address.host !== LAN.host) throw new Error('No route to the host')
      const [deviceEnd, hostEnd] = memoryTransports()
      lan.ends.push(hostEnd)
      server.accept(hostEnd)
      return deviceEnd
    },
    relay: {
      main: MAIN,
      token: () => 'laptop-token',
      openSocket: relays.openSocket,
      fetchJson: relays.fetchJson,
    },
    ...(keepalive ? { keepalive } : {}),
    timeoutMs: 5000,
    networkCheckMs: null,
  })
  cleanups.push(() => client.stop())
  await expect.poll(() => relays.relay(MAIN).hosts.has(relayId), { timeout: 15_000 }).toBe(true)

  const connection = () => client.list().find((known) => known.id === host.id)!.connection
  const via = (): string => {
    const current = connection()
    if (current.state !== 'online') return current.state
    return 'relay' in current ? 'relay' : 'direct'
  }
  const events = (): number[] =>
    main
      .filter((message) => (message as { type?: unknown }).type === 'event')
      .map((message) => (message as { event: { n: number } }).event.n)
  return { relays, server, client, hosts, host, lan, via, connection, events, states }
}

describe('a device moving its session between paths', () => {
  it(
    'moves to the direct path and back to the relay standby, losing and repeating nothing',
    {
      timeout: 60_000,
    },
    async () => {
      const t = await setup()
      t.client.start()
      await expect.poll(t.via, { timeout: 15_000 }).toBe('relay')

      // The host keeps sending while the session moves under it.
      let sent = 0
      const sending = setInterval(() => {
        t.server.adminEvent({ type: 'test', n: ++sent } as unknown as HostAdminEvent, null)
      }, 3)
      cleanups.push(() => clearInterval(sending))
      await expect.poll(() => t.events().length, { timeout: 15_000 }).toBeGreaterThan(5)

      // This computer joins the host's network.
      t.lan.up = true
      t.server.setAddresses([LAN])
      t.client.resume()
      await expect.poll(t.via, { timeout: 15_000 }).toBe('direct')
      const moved = sent
      await expect.poll(() => t.events().length, { timeout: 15_000 }).toBeGreaterThan(moved + 5)

      // It leaves it: the direct path goes, and the relay standby takes the session over.
      t.lan.up = false
      for (const end of t.lan.ends) end.close()
      await expect.poll(t.via, { timeout: 15_000 }).toBe('relay')
      const back = sent
      await expect.poll(() => t.events().length, { timeout: 15_000 }).toBeGreaterThan(back + 5)

      clearInterval(sending)
      const last = sent
      await expect.poll(() => t.events().at(-1), { timeout: 15_000 }).toBe(last)
      expect(t.events()).toEqual(Array.from({ length: last }, (_, i) => i + 1))
      // Online throughout: no move or promotion showed a drop.
      expect(t.states).toEqual(['online'])
    },
  )

  it(
    'takes the session back on the relay when the direct path goes before it is the standby',
    { timeout: 60_000 },
    async () => {
      // The relay is far both ways, so its standby notice comes well after the direct welcome.
      const t = await setup({ sendsLate: 300 })
      t.client.start()
      await expect.poll(t.via, { timeout: 15_000 }).toBe('relay')

      let sent = 0
      const sending = setInterval(() => {
        t.server.adminEvent({ type: 'test', n: ++sent } as unknown as HostAdminEvent, null)
      }, 3)
      cleanups.push(() => clearInterval(sending))
      await expect.poll(() => t.events().length, { timeout: 15_000 }).toBeGreaterThan(5)

      // The session moves to the direct path, which goes before the relay hears it is the standby.
      t.lan.cut = true
      t.lan.up = true
      t.server.setAddresses([LAN])
      t.client.resume()
      await expect.poll(() => t.lan.cuts, { timeout: 15_000 }).toBeGreaterThan(0)
      await expect.poll(t.via, { timeout: 15_000 }).toBe('relay')
      const back = sent
      await expect.poll(() => t.events().length, { timeout: 15_000 }).toBeGreaterThan(back + 5)

      clearInterval(sending)
      const last = sent
      await expect.poll(() => t.events().at(-1), { timeout: 15_000 }).toBe(last)
      expect(t.events()).toEqual(Array.from({ length: last }, (_, i) => i + 1))
      expect(t.states).toEqual(['online'])
    },
  )

  it(
    'compares once for pings that keep coming back slow, and at once when woken',
    { timeout: 30_000 },
    async () => {
      // Once jittering, every other message the host hears comes 150 ms late, in order, so the
      // path's median stays low and each of those pings is far slower than it.
      const jitter = { on: false, heard: 0, slow: 0 }
      const jittery = (transport: Transport): Transport => ({
        ...transport,
        onMessage: (listener) => {
          let queue = Promise.resolve()
          return transport.onMessage((message) => {
            const wait = jitter.on && ++jitter.heard % 2 === 0 ? 150 : 0
            if (wait > 0) jitter.slow++
            queue = queue
              .then(() => new Promise<void>((done) => setTimeout(done, wait)))
              .then(() => listener(message))
          })
        },
      })
      const t = await setup({
        keepalive: { quietMs: 20, answerMs: 300 },
        wrapRelay: jittery,
      })
      t.client.start()
      await expect.poll(t.via, { timeout: 15_000 }).toBe('relay')
      // A few quick pings first, so the path has a median to be slower than.
      await new Promise((done) => setTimeout(done, 600))
      t.hosts.update(t.host.id, { addresses: [LAN] })
      const before = t.lan.tries
      const compared = (): number => t.lan.tries - before

      // However many come back slow, the paths are compared once within the gap.
      jitter.on = true
      await expect.poll(() => jitter.slow, { timeout: 15_000 }).toBeGreaterThanOrEqual(5)
      await new Promise((done) => setTimeout(done, 300))
      expect(compared()).toBe(1)

      // Waking compares at once, however soon after the last comparison.
      t.client.resume()
      await expect.poll(compared, { timeout: 5_000 }).toBe(2)
      expect(t.via()).toBe('relay')
    },
  )
})
