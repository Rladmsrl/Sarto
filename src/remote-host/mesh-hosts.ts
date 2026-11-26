// Sarto: the hosts of the account, which the sync's trustedHosts name and whose daemons trust this
// computer's device key through trustedDevices, so the daemon connects to them without a code. It
// adds each as a known host and keeps which ones it added, so those go once the account no longer
// trusts them, and a host paired by hand stays (docs/sarto-remote-design.md).

import path from 'node:path'
import type { Platform } from '@shared/platform'
import { deviceId } from '@shared/remote/device'
import type { KnownHost } from '@shared/remote/hosts'
import { parseHostRelay, type HostRelay } from '@shared/remote/relay'
import { JsonFile, type LogFn, type Migration } from '../agent-host/storage'
import { publicKeyBytes } from './devices'

/** A host of the account, as the daemon passes it on from the sync. */
export interface MeshHost {
  /** Its X25519 public key, in base64. */
  publicKey: string
  name: string
  platform: Platform
  relay?: HostRelay
}

/** What the mesh needs of HostClient. */
export interface MeshClient {
  list(): readonly Pick<KnownHost, 'id'>[]
  trust(
    host: Pick<KnownHost, 'publicKey' | 'name' | 'platform' | 'relay'>,
    known: string | null,
  ): Promise<KnownHost | null>
  remove(id: string): Promise<boolean>
}

const FILE = ['remote', 'sarto-mesh-hosts.json']
const VERSION = 1
const MIGRATIONS: Readonly<Record<number, Migration>> = {}
// HostStore keeps at most 100 hosts.
const MAX_HOSTS = 100

interface MeshFile {
  version: 1
  /** The ids of the hosts this file's mesh added, which it may remove. */
  added: string[]
}

const isId = (value: unknown): value is string =>
  typeof value === 'string' && /^[0-9a-f]{32}$/.test(value)

function parseFile(data: Record<string, unknown>): MeshFile | string {
  if (!Array.isArray(data.added) || data.added.length > MAX_HOSTS) return 'added is not a list'
  if (!data.added.every(isId)) return 'added holds an id that is not one'
  return { version: 1, added: data.added }
}

const isText = (value: unknown, max: number): value is string =>
  typeof value === 'string' && value.length > 0 && value.length <= max

/** The hosts a message carries, or null when it is not a list of them. */
export function parseMeshHosts(value: unknown): MeshHost[] | null {
  if (!Array.isArray(value) || value.length > MAX_HOSTS) return null
  const hosts: MeshHost[] = []
  for (const item of value) {
    if (typeof item !== 'object' || item === null) return null
    const { publicKey, name, platform, relay } = item as Record<string, unknown>
    if (!isText(publicKey, 64) || !publicKeyBytes(publicKey)) return null
    if (!isText(name, 256) || !isText(platform, 64)) return null
    const parsedRelay = relay === undefined ? undefined : parseHostRelay(relay)
    if (parsedRelay === null) return null
    hosts.push({
      publicKey,
      name,
      // As a stored host's is taken: any short name, since hosts on other systems may come.
      platform: platform as Platform,
      ...(parsedRelay ? { relay: parsedRelay } : {}),
    })
  }
  return hosts
}

export class MeshHosts {
  private applying: Promise<void> = Promise.resolve()

  private constructor(
    private readonly file: JsonFile<MeshFile>,
    private added: Set<string>,
    private readonly log: LogFn,
  ) {}

  static async load(userDataPath: string, log: LogFn): Promise<MeshHosts> {
    const file = new JsonFile<MeshFile>({
      file: path.join(userDataPath, ...FILE),
      version: VERSION,
      migrations: MIGRATIONS,
      parse: parseFile,
      empty: () => ({ version: 1, added: [] }),
      log,
    })
    const { added } = await file.load()
    return new MeshHosts(file, new Set(added), log)
  }

  /**
   * Makes the account's hosts known hosts of `client`, and forgets the ones it added before that
   * the account no longer names. Each call runs after the one before.
   */
  apply(client: MeshClient, hosts: readonly MeshHost[]): Promise<void> {
    this.applying = this.applying
      .then(() => this.run(client, hosts))
      .catch((error: unknown) => {
        this.log('error', `Could not keep the account's hosts: ${(error as Error).message}`)
      })
    return this.applying
  }

  private async run(client: MeshClient, hosts: readonly MeshHost[]): Promise<void> {
    const known = new Set(client.list().map((host) => host.id))
    const wanted = new Set<string>()
    for (const host of hosts) {
      const id = await deviceId(publicKeyBytes(host.publicKey)!)
      wanted.add(id)
      const kept = await client.trust(host, known.has(id) ? id : null)
      // A host known before, as one paired by hand, stays the user's to remove.
      if (kept && !known.has(id)) this.added.add(id)
    }
    for (const id of [...this.added]) {
      if (wanted.has(id)) continue
      this.added.delete(id)
      await client.remove(id)
    }
    for (const id of [...this.added]) {
      if (!client.list().some((host) => host.id === id)) this.added.delete(id)
    }
    this.file.save({ version: 1, added: [...this.added] })
    await this.file.flush()
  }
}
