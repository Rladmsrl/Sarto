// The Sarto server, for the daemon's tests against it. The server is closed source and kept in the
// sarto-cloud repository, so those tests run only where its source is found: SARTO_CLOUD_SRC, or
// the server's source folder in a sarto-cloud checkout beside this one. Elsewhere they are skipped.
// This names only what the tests use of it.

import { existsSync } from 'node:fs'
import type http from 'node:http'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import type {
  SyncItemRecord,
  SyncKeybag,
  SyncKeybagV2,
  SyncManifest,
  SyncScopeMeta,
  SyncScopeRecord,
} from '@shared/sync/wire'

const ROOT = fileURLToPath(new URL('../../..', import.meta.url))

const SOURCE =
  process.env.SARTO_CLOUD_SRC ?? path.join(ROOT, '..', 'sarto-cloud', 'services', 'relay', 'src')

export const CLOUD_SOURCE: string | null =
  SOURCE !== '' && existsSync(path.join(SOURCE, 'relay-server.ts')) ? SOURCE : null

export interface CloudAccount {
  id: string
  email: string
  name: string
}

export interface AuthService {
  createPasswordAccount(
    email: string,
    password: string,
    name?: string,
  ): Promise<{ ok: true; account: CloudAccount } | { ok: false; status: number; error: string }>
  issueToken(
    account: Pick<CloudAccount, 'id' | 'email'>,
    scope: 'access' | 'relay',
    options?: { ttlMs?: number; family?: string },
  ): { token: string; expiresAt: number }
  verifyToken(
    token: string | null | undefined,
    options?: { allowGrace?: boolean; requiredScope?: 'access' | 'relay' },
  ): { accountId: string; email: string; scope: 'access' | 'relay'; family?: string } | null
}

export interface OAuthStore {
  createFamily(input: { accountId: string; clientId: string; clientInfo: string; now: number }): {
    id: string
  }
  close(): void
}

export type OAuthService = object

export interface SartoSyncStore {
  getKeybag(accountId: string): SyncKeybag | null
  removeKeybagDevice(
    accountId: string,
    deviceId: string,
  ): { ok: true; keybag: SyncKeybagV2; changed: boolean } | { ok: false; error: string }
  getScope(accountId: string, scope: string): SyncScopeRecord | null
  putScope(
    accountId: string,
    scope: string,
    baseRev: unknown,
    updatedBy: unknown,
    envelope: unknown,
  ): { ok: true; meta: SyncScopeMeta } | { ok: false; status: number; error: string }
  listScopeItems(accountId: string, scope: string): Record<string, SyncScopeMeta> | null
  getScopeItem(accountId: string, scope: string, itemKey: string): SyncItemRecord | null
  getManifest(accountId: string): SyncManifest
  hasBlob(accountId: string, sha256: string): Promise<{ exists: boolean; byteLength: number }>
  resetAccount(accountId: string): Promise<void>
  close(): void
}

export interface PrismRelayServer {
  readonly httpServer: http.Server
  listen(port: number, host?: string): Promise<{ host: string; port: number }>
  close(): Promise<void>
}

export interface CloudModules {
  AuthService: new (options: {
    secret: string
    dataFile: string | null
    allowRegistration?: boolean
    now?: () => number
  }) => AuthService
  OAuthStore: new (dbPath: string | null) => OAuthStore
  OAuthService: new (options: {
    auth: AuthService
    store: OAuthStore
    publicOrigin: string
    allowRegistration: boolean
    allowPasswordLogin?: boolean
    now?: () => number
  }) => OAuthService
  SartoSyncStore: new (options?: { dbPath?: string | null; now?: () => number }) => SartoSyncStore
  PrismRelayServer: new (options: {
    publicOrigin: string
    regionId: string
    auth: AuthService
    oauth?: OAuthService
    syncStore?: SartoSyncStore
    now?: () => number
  }) => PrismRelayServer
}

/** The server's classes, or ones that throw where its source is not found. */
export async function loadCloud(): Promise<CloudModules> {
  const source = CLOUD_SOURCE
  if (!source) {
    const missing = class {
      constructor() {
        throw new Error('The Sarto server source is not here; set SARTO_CLOUD_SRC')
      }
    }
    return {
      AuthService: missing,
      OAuthStore: missing,
      OAuthService: missing,
      SartoSyncStore: missing,
      PrismRelayServer: missing,
    } as unknown as CloudModules
  }
  const load = (name: string) => import(/* @vite-ignore */ path.join(source, `${name}.ts`))
  const [auth, oauthStore, oauthService, syncStore, relay] = await Promise.all([
    load('auth'),
    load('oauth-store'),
    load('oauth-service'),
    load('sync-store'),
    load('relay-server'),
  ])
  return {
    AuthService: auth.AuthService,
    OAuthStore: oauthStore.OAuthStore,
    OAuthService: oauthService.OAuthService,
    SartoSyncStore: syncStore.SartoSyncStore,
    PrismRelayServer: relay.PrismRelayServer,
  }
}
