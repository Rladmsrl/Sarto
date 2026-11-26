import { mkdtempSync, rmSync } from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { deviceId } from '@shared/remote/device'
import type { KnownHost } from '@shared/remote/hosts'
import { MeshHosts, parseMeshHosts, type MeshClient, type MeshHost } from './mesh-hosts'

const dirs: string[] = []

function tempDir(): string {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'sarto-mesh-'))
  dirs.push(dir)
  return dir
}

afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true })
})

const key = (byte: number): string => Buffer.alloc(32, byte).toString('base64')
const idOf = (byte: number): Promise<string> => deviceId(Buffer.alloc(32, byte))

function host(byte: number, name = `Mac ${byte}`): MeshHost {
  return { publicKey: key(byte), name, platform: 'darwin' }
}

/** HostClient's part the mesh uses, over a plain map. */
function fakeClient(): MeshClient & { hosts: Map<string, Pick<KnownHost, 'id' | 'name'>> } {
  const hosts = new Map<string, Pick<KnownHost, 'id' | 'name'>>()
  return {
    hosts,
    list: () => [...hosts.values()],
    trust: async (next, known) => {
      const id = known ?? (await deviceId(Buffer.from(next.publicKey, 'base64')))
      hosts.set(id, { id, name: next.name })
      return { id, name: next.name } as KnownHost
    },
    remove: async (id) => hosts.delete(id),
  }
}

const silent = () => {}

describe("the account's hosts", () => {
  it('adds the hosts the account names and forgets the ones it no longer does', async () => {
    const dir = tempDir()
    const client = fakeClient()
    const mesh = await MeshHosts.load(dir, silent)
    await mesh.apply(client, [host(1), host(2)])
    expect([...client.hosts.keys()].sort()).toEqual([await idOf(1), await idOf(2)].sort())

    await mesh.apply(client, [host(2, 'Renamed')])
    expect([...client.hosts.keys()]).toEqual([await idOf(2)])
    expect(client.hosts.get(await idOf(2))?.name).toBe('Renamed')
  })

  it('never forgets a host that was paired by hand', async () => {
    const dir = tempDir()
    const client = fakeClient()
    const paired = await idOf(3)
    client.hosts.set(paired, { id: paired, name: 'Paired' })
    const mesh = await MeshHosts.load(dir, silent)
    await mesh.apply(client, [host(3)])
    await mesh.apply(client, [])
    expect(client.hosts.has(paired)).toBe(true)
  })

  it('remembers what it added across runs', async () => {
    const dir = tempDir()
    const client = fakeClient()
    await (await MeshHosts.load(dir, silent)).apply(client, [host(4)])
    const again = await MeshHosts.load(dir, silent)
    await again.apply(client, [])
    expect(client.hosts.size).toBe(0)
  })

  it('takes only hosts that are well formed', () => {
    expect(parseMeshHosts([host(5)])).toEqual([host(5)])
    expect(parseMeshHosts([{ ...host(5), publicKey: 'short' }])).toBeNull()
    expect(parseMeshHosts([{ ...host(5), name: '' }])).toBeNull()
    expect(parseMeshHosts([{ ...host(5), relay: { id: 'not a relay id', urls: [] } }])).toBeNull()
    expect(parseMeshHosts('hosts')).toBeNull()
  })
})
