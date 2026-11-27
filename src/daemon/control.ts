// The control socket: how the CLI reaches the running daemon, which alone writes the host's state.
// It sits in the data folder, which only the user can open, and carries the envelope of the hosts'
// ports, framed as their sockets frame it.

import type { Server } from 'node:net'
import type { DebugStatus } from '@shared/debug'
import type { PortChannel } from '@shared/port-channel'
import {
  DEVICE_ID,
  isDeviceField,
  isDeviceModel,
  normalizeDeviceName,
  type NewDevice,
} from '@shared/remote/device'
import type { Platform } from '@shared/platform'
import type { DiscoveredHosts } from '@shared/remote/discovery'
import type { HostPairingState, HostStatus as OtherHost } from '@shared/remote/hosts'
import { isRelayHostId } from '@shared/remote/relay'
import {
  isReportPath,
  isReportStatus,
  parseReportClientPayload,
  parseReportRequest,
  ReportRequestError,
  type PreparedReport,
  type ReportBuildResult,
  type ReportClientPayload,
  type ReportFileInfo,
  type ReportFileView,
  type ReportRequest,
  type ReportStatus,
  type ReportSubmitResult,
  type ReportSummary,
} from '@shared/report'
import type { RelayReport } from '@shared/remote/status'
import {
  isSyncDeviceId,
  isSyncItemKey,
  type SartoSyncStatus,
  type SyncedUsageRecord,
  type TrustedWorkspaceDevice,
} from '@shared/sync/protocol'
import { connectPort, listenPorts } from '@shared/socket-port'
import type { BuildChannel, DaemonOrigin } from '../core/build-info'
import { publicKeyBytes } from '../remote-host/devices'
import {
  isCloudAppTheme,
  type CloudAccountPreferences,
  type CloudAccountStatus,
  type CloudAppTheme,
  type CloudDevice,
} from './cloud-account'
import type { HostState } from './forked-host'
import {
  GAME_PROTOCOL_VERSION,
  parseCommand,
  type CommandResult,
  type GameStateView,
  type ServerFrame,
} from '@sarto/wire/game'
import type { GameLinkStatus } from './game/link'

/** A player's command for the game service, without the envelope the daemon adds. */
export interface GameCommandParams {
  type: string
  args: Record<string, unknown>
}

/** A host that takes ports; the remote host takes devices' connections instead. */
export type HostName = 'agent' | 'terminal'
/**
 * Hosts whose local port socket `host.socket` can return, including the on-demand device host, and
 * `hosts`, where the app reaches the sessions on other hosts (docs/sarto-remote-design.md).
 */
export type SocketHostName = HostName | 'device' | 'hosts'

/** The key this daemon connects to other hosts with, for the app to publish as its device. */
export interface DeviceKeyInfo {
  /** The id hosts know this daemon by: 32 hexadecimal digits from the key. */
  id: string
  /** The X25519 public key, in base64. */
  publicKey: string
}

export interface HostStatus {
  state: HostState
  pid: number | null
  /** How many times the daemon restarted it after it exited. */
  restarts: number
}

/** A paired device, without its key. */
export interface DeviceSummary {
  id: string
  name: string
  kind: string
  platform: string
  /** It has a session open now. */
  connected: boolean
  lastConnectedAt: number | null
}

export interface DaemonStatus {
  version: string
  /** Monotonic build identifier, e.g. 12-digit UTC YYMMDDHHmmss; absent from older daemons. */
  build?: string | null
  /** Release channel (`stable`, `beta`, `dev`); absent from older daemons. */
  channel?: BuildChannel
  /** Short git commit SHA (with `-dirty` when built from a modified tree); absent from older daemons. */
  commit?: string | null
  /** How this daemon bundle is installed (`bundled`, `standalone`, `checkout`); absent from older daemons. */
  origin?: DaemonOrigin
  pid: number
  startedAt: number
  /** It got a signal to stop and is stopping its hosts. */
  stopping: boolean
  dataPath: string
  /** It runs as the service `sarto service install` set up, not in someone's terminal. */
  service: boolean
  key: {
    storage: 'file'
    path: string
    /** Whether only the user can read the file; null when it is missing. */
    private: boolean | null
  }
  hosts: Record<HostName | 'remote', HostStatus>
  /** How many devices are connected, or null while remote access is not running. */
  connectedDevices: number | null
  /** This run's inspectors and their file in a debug run; null or absent, from older daemons, else. */
  debug?: { inspectors: DebugStatus['inspectors']; file: string | null } | null
  /** The Sarto relay, as Settings shows it; absent from older daemons. */
  relay?: RelayReport
}

export interface ControlCalls {
  status: { params: undefined; result: DaemonStatus }
  /** A host's socket, for a port of its own; the terminal host starts on the first ask. */
  'host.socket': { params: { host: SocketHostName }; result: { path: string } }
  'devices.list': { params: undefined; result: DeviceSummary[] }
  'devices.remove': { params: { id: string }; result: null }
  /** Whether devices may use this computer's terminal. */
  'terminal.get': { params: undefined; result: TerminalReport }
  /** Allows devices the terminal, or stops allowing it, which closes their terminals at once. */
  'terminal.set': { params: { allowed: boolean }; result: TerminalReport }
  /** Reports whether the user is actively at the desktop app, for `onlyAway` push notifications. */
  'presence.set': { params: { present: boolean }; result: null }
  /**
   * What a computer adding this one over SSH connects with, after adding its `device`, whose key
   * came over the login, as a device of the owner's.
   */
  'ssh.setup': { params: { device: NewDevice | null }; result: SshSetup }
  /** A problem report's bundle, written into the data folder for the CLI to move. */
  'report.build': { params: { request: ReportRequest }; result: ReportBuildResult }
  /** Builds a problem report and keeps it on the daemon's shelf for preview, save or submission. */
  'report.prepare': {
    params: { request: ReportRequest; client?: ReportClientPayload | null }
    result:
      | ({ ok: true } & PreparedReport)
      | { ok: false; reason: 'too_large' | 'failed'; message: string }
  }
  /** Adopts a base64 zip received from a remote host onto the local shelf for preview and save. */
  'report.adopt': {
    params: {
      zip: string
      files: ReportFileInfo[]
      redactionCount?: number
    }
    result:
      | ({ ok: true } & PreparedReport)
      | { ok: false; reason: 'too_large' | 'failed'; message: string }
  }
  /** Reads one file out of a shelved report bundle for review before saving or submitting. */
  'report.read': { params: { id: string; path: string }; result: ReportFileView }
  /** Copies a shelved report bundle to a destination path chosen by the user. */
  'report.save': {
    params: { id: string; destination: string; overwrite?: boolean }
    result: { ok: true; path: string }
  }
  /** Submits a shelved report bundle to Sarto Cloud (signed-in or anonymous). */
  'report.submit': {
    params: { id: string; allowAnonymous?: boolean }
    result: ReportSubmitResult
  }
  /** Discards a shelved report bundle and deletes its temporary zip file. */
  'report.drop': { params: { id: string }; result: null }
  /** Lists the signed-in account's problem reports from Sarto Cloud. */
  'report.list': {
    params: { limit?: number; status?: ReportStatus }
    result: {
      signedIn: boolean
      origin: string
      reports: ReportSummary[]
      total: number
      countsByStatus: Record<ReportStatus, number>
    }
  }
  /** Turns the detailed records on for 24 hours, or off; when they end, or null. */
  'verbose.set': { params: { on: boolean }; result: { until: number | null } }
  /** Reads the account file again, as after `sarto login` or `sarto logout` changed it. */
  'account.reload': { params: undefined; result: null }
  /** The Sarto Cloud account: its server and sign-in. */
  'account.status': { params: undefined; result: CloudAccountStatus }
  /** The status, then `account.updated` whenever it changes, until the connection closes. */
  'account.subscribe': { params: undefined; result: CloudAccountStatus }
  /**
   * The idle game's link and latest state, then `game.status` and `game.frame` (state, live
   * battle events, notices) until the connection closes.
   */
  'game.subscribe': {
    params: undefined
    result: { status: GameLinkStatus; state: GameStateView | null }
  }
  /** Marks whether a game surface is visible on this connection, opening the live battle stream. */
  'game.watch': { params: { watching: boolean }; result: null }
  /** Sends a player's command to the game service and returns its answer. */
  'game.command': { params: GameCommandParams; result: CommandResult }
  /**
   * Turns the idle game on or off for this computer, as its owner chose in the app; off deletes
   * the facts not sent yet. Only this socket's clients may: no device reaches it.
   */
  'game.setEnabled': { params: { enabled: boolean }; result: GameLinkStatus }
  /**
   * Starts browser sign-in at the server's sign-in page; the status follows once it comes back. A
   * `serverUrl` other than the current one is taken only while signed out. Pass `openBrowser: false`
   * so a foreground app can open `authUrl` itself instead of the daemon spawning a browser opener.
   */
  'account.signIn': {
    params: { serverUrl?: string; openBrowser?: boolean }
    result: CloudAccountStatus
  }
  /** Cancels an in-flight browser sign-in immediately and releases its loopback callback server. */
  'account.cancelSignIn': { params: undefined; result: CloudAccountStatus }
  /** Signs out here and at the server, even when the server is away. */
  'account.signOut': { params: undefined; result: CloudAccountStatus }
  /** Reads the account again, as when the app shows it. */
  'account.check': { params: undefined; result: CloudAccountStatus }
  /** The clients signed in to the account. */
  'account.devices': { params: undefined; result: CloudDevice[] }
  /** Signs a client of the account out. */
  'account.removeDevice': { params: { id: string }; result: null }
  /** A short-lived relay token for the app to reach hosts as a device. */
  'account.relayToken': { params: undefined; result: { token: string; expiresAt: number } }
  /** Reads cloud account preferences (active App theme). */
  'account.preferences': { params: undefined; result: CloudAccountPreferences }
  /** Updates cloud account preferences (active App theme). */
  'account.setPreferences': {
    params: { appTheme?: CloudAppTheme | null }
    result: CloudAccountPreferences
  }
  /** The device key this daemon connects to other hosts with. */
  'hosts.device': { params: undefined; result: DeviceKeyInfo }
  /** The other hosts this daemon knows and their connections. */
  'hosts.list': { params: undefined; result: OtherHost[] }
  /** The same, then `hosts.updated` whenever they change, until the connection closes. */
  'hosts.subscribe': { params: undefined; result: OtherHost[] }
  /** Whether the code both screens show is the same; false ends the pairing. */
  'hosts.pairMatch': { params: { pairId: number; match: boolean }; result: null }
  /** Ends a pairing this connection started, unless the host was added. */
  'hosts.pairClose': { params: { pairId: number }; result: null }
  /** The hosts of the account the relay lists, to pair with without a code. */
  'hosts.discover': { params: undefined; result: DiscoveredHosts }
  /** Pairs with one of them, by its id on the relay; `hosts.pairing` events follow. */
  'hosts.pairDiscovered': { params: { relayId: string; model: string }; result: { pairId: number } }
  /** Forgets a host. */
  'hosts.remove': { params: { id: string }; result: null }
  /** Renames this computer on a host; false when the host is not connected. */
  'hosts.rename': { params: { id: string; name: string }; result: { renamed: boolean } }
  /** Runs a host-level admin call locally with the same checks an owner's device gets. */
  admin: { params: { method: string; params?: unknown }; result: unknown }
  /** Sarto E2EE Workspace Sync control calls for Sarto.app. */
  'sync.status': { params: undefined; result: SartoSyncStatus }
  'sync.subscribe': { params: undefined; result: SartoSyncStatus }
  'sync.setupVault': {
    params: undefined
    /** The one-time recovery key; null when another Mac holds the account's keybag already. */
    result: { status: SartoSyncStatus; recoveryKey: string | null }
  }
  'sync.unlockRecovery': {
    params: { recoveryKey: string }
    result: SartoSyncStatus
  }
  'sync.approveDevice': {
    params: { deviceId: string }
    result: SartoSyncStatus
  }
  'sync.rejectDevice': {
    params: { deviceId: string }
    result: SartoSyncStatus
  }
  /** On a Mac waiting for approval: whether its code matches the one the answering Mac shows. */
  'sync.confirmApproval': {
    params: { matches: boolean }
    result: SartoSyncStatus
  }
  'sync.removeDeviceWrap': {
    params: { deviceId: string }
    result: SartoSyncStatus
  }
  'sync.putUsage': {
    params: {
      deviceId?: string
      deviceName?: string
      updatedAt: number
      island: Record<string, unknown>
      ifOlderOnly?: boolean
    }
    result: SartoSyncStatus
  }
  'sync.getUsage': {
    params: undefined
    result: { ownDeviceId: string; records: SyncedUsageRecord[] }
  }
  'sync.removeUsage': {
    params: { deviceId: string }
    result: SartoSyncStatus
  }
  'sync.disconnect': { params: undefined; result: SartoSyncStatus }
  'sync.now': { params: undefined; result: SartoSyncStatus }
  'sync.pushClientState': {
    params: {
      uiPrefs?: Record<string, { value: unknown; updatedAt: number }>
      device?: TrustedWorkspaceDevice
    }
    result: SartoSyncStatus
  }
}

export interface TerminalReport {
  allowed: boolean
}

/** What a computer adding this one over SSH connects with. */
export interface SshSetup {
  /** The host's X25519 public key, in base64, which the channel's handshake is made to. */
  publicKey: string
  name: string
  platform: Platform
  version: string
  /** The port it takes channels from SSH on, on 127.0.0.1 alone. */
  port: number
}

/** What the daemon tells a connection unasked. */
export type ControlEvent =
  | { type: 'sync.updated'; status: SartoSyncStatus }
  | { type: 'sync.usage.updated'; ownDeviceId: string; records: SyncedUsageRecord[] }
  | { type: 'account.updated'; status: CloudAccountStatus }
  | { type: 'hosts.updated'; hosts: OtherHost[] }
  | { type: 'hosts.pairing'; pairId: number; pairing: HostPairingState }
  | { type: 'game.status'; status: GameLinkStatus }
  | { type: 'game.frame'; frame: ServerFrame }

/** One client's connection, as a handler sees it. */
export interface ControlConnection {
  notify(event: ControlEvent): void
  /** Runs once the client is gone. */
  onClose(listener: () => void): void
}

export type ControlMethod = keyof ControlCalls
type Params<M extends ControlMethod> = ControlCalls[M]['params']
type Result<M extends ControlMethod> = ControlCalls[M]['result']

export type ControlErrorCode =
  'unknown_method' | 'invalid_params' | 'not_found' | 'unavailable' | 'internal'

export class ControlError extends Error {
  constructor(
    readonly code: ControlErrorCode,
    message: string,
  ) {
    super(message)
    this.name = 'ControlError'
  }
}

/** No daemon listens on the control socket. */
export class NotRunning extends Error {
  constructor() {
    super('The daemon is not running')
    this.name = 'NotRunning'
  }
}

type Request = { type: 'request'; id: number; method: string; params: unknown }
type Reply =
  | { type: 'response'; id: number; result: unknown }
  | { type: 'error'; id: number; error: { code: ControlErrorCode; message: string } }
  | { type: 'event'; event: ControlEvent }

export type ControlHandlers = {
  [M in ControlMethod]: (params: Params<M>, connection: ControlConnection) => Promise<Result<M>>
}

const CLOSE_WAIT_MS = 2000

function none(raw: unknown): undefined {
  if (raw !== undefined && raw !== null) throw new ControlError('invalid_params', 'Takes no params')
  return undefined
}

function record(raw: unknown): Record<string, unknown> {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
    throw new ControlError('invalid_params', 'Params must be an object')
  }
  return raw as Record<string, unknown>
}

function newDevice(raw: unknown): NewDevice {
  const { publicKey, name, kind, platform, model } = record(raw)
  if (typeof publicKey !== 'string' || !publicKeyBytes(publicKey)) {
    throw new ControlError('invalid_params', "A device's key is 32 bytes in base64")
  }
  const kept = normalizeDeviceName(name)
  if (kept === null) throw new ControlError('invalid_params', 'The name must not be empty')
  if (!isDeviceField(kind) || !isDeviceField(platform) || !isDeviceModel(model)) {
    throw new ControlError('invalid_params', "The device's kind, platform or model is not one")
  }
  return { publicKey, name: kept, kind, platform, model }
}

function pairIdOf(raw: unknown): number {
  if (!Number.isSafeInteger(raw))
    throw new ControlError('invalid_params', 'pairId must be an integer')
  return raw as number
}

function hostIdOf(raw: unknown): string {
  if (typeof raw !== 'string' || !DEVICE_ID.test(raw)) {
    throw new ControlError('invalid_params', "A host's id is 32 hexadecimal digits")
  }
  return raw
}

/** The app's hardware model, or none when it gives none that is one. */
function modelOf(raw: unknown): string {
  if (raw === undefined || raw === null) return ''
  if (!isDeviceModel(raw)) throw new ControlError('invalid_params', 'model is not a device model')
  return raw
}

const validators: { [M in ControlMethod]: (raw: unknown) => Params<M> } = {
  status: none,
  'host.socket': (raw) => {
    const { host } = record(raw)
    if (host !== 'agent' && host !== 'terminal' && host !== 'device' && host !== 'hosts') {
      throw new ControlError('invalid_params', 'host must be agent, terminal, device or hosts')
    }
    return { host }
  },
  'devices.list': none,
  'devices.remove': (raw) => {
    const { id } = record(raw)
    if (typeof id !== 'string' || !DEVICE_ID.test(id)) {
      throw new ControlError('invalid_params', "A device's id is 32 hexadecimal digits")
    }
    return { id }
  },
  'terminal.get': none,
  'account.reload': none,
  'account.status': none,
  'account.subscribe': none,
  'game.subscribe': none,
  'game.watch': (raw) => {
    const { watching } = record(raw)
    if (typeof watching !== 'boolean') {
      throw new ControlError('invalid_params', 'watching must be a boolean')
    }
    return { watching }
  },
  'game.command': (raw) => {
    const { type, args } = record(raw)
    // The game service checks the command again; this keeps junk off its socket.
    const parsed = parseCommand({
      v: GAME_PROTOCOL_VERSION,
      actionId: 'check',
      actor: 'player',
      type,
      args: args ?? {},
    })
    if (typeof parsed === 'string') throw new ControlError('invalid_params', parsed)
    return { type: parsed.type, args: parsed.args as Record<string, unknown> }
  },
  'game.setEnabled': (raw) => {
    const { enabled } = record(raw)
    if (typeof enabled !== 'boolean') {
      throw new ControlError('invalid_params', 'enabled must be a boolean')
    }
    return { enabled }
  },
  'account.signIn': (raw) => {
    const { serverUrl, openBrowser } = raw === undefined || raw === null ? {} : record(raw)
    if (
      serverUrl !== undefined &&
      serverUrl !== null &&
      (typeof serverUrl !== 'string' || serverUrl.length > 2048)
    ) {
      throw new ControlError('invalid_params', 'serverUrl must be an address')
    }
    if (openBrowser !== undefined && typeof openBrowser !== 'boolean') {
      throw new ControlError('invalid_params', 'openBrowser must be a boolean')
    }
    return {
      ...(typeof serverUrl === 'string' ? { serverUrl } : {}),
      ...(openBrowser !== undefined ? { openBrowser } : {}),
    }
  },
  'account.cancelSignIn': none,
  'account.signOut': none,
  'account.check': none,
  'account.devices': none,
  'account.removeDevice': (raw) => {
    const { id } = record(raw)
    if (typeof id !== 'string' || !/^fam_[0-9a-f]{24}$/.test(id)) {
      throw new ControlError('invalid_params', 'id must be a device of the account')
    }
    return { id }
  },
  'account.relayToken': none,
  'account.preferences': none,
  'account.setPreferences': (raw) => {
    const { appTheme } = record(raw)
    const out: ControlCalls['account.setPreferences']['params'] = {}
    if (appTheme !== undefined) {
      if (appTheme !== null && !isCloudAppTheme(appTheme)) {
        throw new ControlError(
          'invalid_params',
          'appTheme must be obsidian, warm, crystal, alabaster, or null',
        )
      }
      out.appTheme = appTheme
    }
    return out
  },
  'hosts.device': none,
  'hosts.list': none,
  'hosts.subscribe': none,
  'hosts.pairMatch': (raw) => {
    const { pairId, match } = record(raw)
    if (typeof match !== 'boolean')
      throw new ControlError('invalid_params', 'match must be a boolean')
    return { pairId: pairIdOf(pairId), match }
  },
  'hosts.pairClose': (raw) => ({ pairId: pairIdOf(record(raw).pairId) }),
  'hosts.discover': none,
  'hosts.pairDiscovered': (raw) => {
    const { relayId, model } = record(raw)
    if (!isRelayHostId(relayId)) {
      throw new ControlError('invalid_params', "relayId must be a host's id on the relay")
    }
    return { relayId, model: modelOf(model) }
  },
  'hosts.remove': (raw) => ({ id: hostIdOf(record(raw).id) }),
  'hosts.rename': (raw) => {
    const { id, name } = record(raw)
    const kept = normalizeDeviceName(name)
    if (kept === null) throw new ControlError('invalid_params', 'The name must not be empty')
    return { id: hostIdOf(id), name: kept }
  },
  'terminal.set': (raw) => {
    const { allowed } = record(raw)
    if (typeof allowed !== 'boolean') {
      throw new ControlError('invalid_params', 'allowed must be a boolean')
    }
    return { allowed }
  },
  'presence.set': (raw) => {
    const { present } = record(raw)
    if (typeof present !== 'boolean') {
      throw new ControlError('invalid_params', 'present must be a boolean')
    }
    return { present }
  },
  'ssh.setup': (raw) => {
    const { device } = record(raw)
    return { device: device === undefined || device === null ? null : newDevice(device) }
  },
  'report.build': (raw) => {
    try {
      return { request: parseReportRequest(record(raw).request) }
    } catch (error) {
      if (error instanceof ReportRequestError) {
        throw new ControlError('invalid_params', error.message)
      }
      throw error
    }
  },
  'report.prepare': (raw) => {
    const body = record(raw)
    try {
      const request = parseReportRequest(body.request)
      const client = parseReportClientPayload(body.client)
      return { request, ...(client !== null ? { client } : {}) }
    } catch (error) {
      if (error instanceof ReportRequestError) {
        throw new ControlError('invalid_params', error.message)
      }
      throw error
    }
  },
  'report.adopt': (raw) => {
    const body = record(raw)
    if (typeof body.zip !== 'string' || body.zip.length === 0) {
      throw new ControlError('invalid_params', 'zip must be a non-empty base64 string')
    }
    if (!Array.isArray(body.files)) {
      throw new ControlError('invalid_params', 'files must be a list')
    }
    const files: ReportFileInfo[] = []
    for (const item of body.files) {
      const entry = record(item)
      if (
        !isReportPath(entry.path) ||
        typeof entry.size !== 'number' ||
        !Number.isSafeInteger(entry.size) ||
        entry.size < 0 ||
        (entry.kind !== 'text' && entry.kind !== 'image' && entry.kind !== 'binary')
      ) {
        throw new ControlError('invalid_params', 'files contains an invalid file entry')
      }
      files.push({ path: entry.path, size: entry.size, kind: entry.kind })
    }
    const redactionCount =
      typeof body.redactionCount === 'number' &&
      Number.isSafeInteger(body.redactionCount) &&
      body.redactionCount >= 0
        ? body.redactionCount
        : undefined
    return {
      zip: body.zip,
      files,
      ...(redactionCount !== undefined ? { redactionCount } : {}),
    }
  },
  'report.read': (raw) => {
    const { id, path: entryPath } = record(raw)
    if (typeof id !== 'string' || id.length === 0 || id.length > 128) {
      throw new ControlError('invalid_params', 'id must be a report id')
    }
    if (!isReportPath(entryPath)) {
      throw new ControlError('invalid_params', 'path must be a valid bundle file path')
    }
    return { id, path: entryPath }
  },
  'report.save': (raw) => {
    const { id, destination, overwrite } = record(raw)
    if (typeof id !== 'string' || id.length === 0 || id.length > 128) {
      throw new ControlError('invalid_params', 'id must be a report id')
    }
    if (
      typeof destination !== 'string' ||
      destination.length === 0 ||
      destination.length > 4096 ||
      destination.includes('\0')
    ) {
      throw new ControlError('invalid_params', 'destination must be a file path')
    }
    if (overwrite !== undefined && typeof overwrite !== 'boolean') {
      throw new ControlError('invalid_params', 'overwrite must be a boolean')
    }
    return { id, destination, ...(overwrite !== undefined ? { overwrite } : {}) }
  },
  'report.submit': (raw) => {
    const { id, allowAnonymous } = record(raw)
    if (typeof id !== 'string' || id.length === 0 || id.length > 128) {
      throw new ControlError('invalid_params', 'id must be a report id')
    }
    if (allowAnonymous !== undefined && typeof allowAnonymous !== 'boolean') {
      throw new ControlError('invalid_params', 'allowAnonymous must be a boolean')
    }
    return { id, ...(allowAnonymous !== undefined ? { allowAnonymous } : {}) }
  },
  'report.drop': (raw) => {
    const { id } = record(raw)
    if (typeof id !== 'string' || id.length === 0 || id.length > 128) {
      throw new ControlError('invalid_params', 'id must be a report id')
    }
    return { id }
  },
  'report.list': (raw) => {
    if (raw === undefined || raw === null) return {}
    const { limit, status } = record(raw)
    const out: ControlCalls['report.list']['params'] = {}
    if (limit !== undefined) {
      if (typeof limit !== 'number' || !Number.isInteger(limit) || limit < 1 || limit > 100) {
        throw new ControlError('invalid_params', 'limit must be an integer between 1 and 100')
      }
      out.limit = limit
    }
    if (status !== undefined) {
      if (!isReportStatus(status)) {
        throw new ControlError('invalid_params', 'status is not a valid report status')
      }
      out.status = status
    }
    return out
  },
  'verbose.set': (raw) => {
    const { on } = record(raw)
    if (typeof on !== 'boolean') throw new ControlError('invalid_params', 'on must be a boolean')
    return { on }
  },
  admin: (raw) => {
    const { method, params } = record(raw)
    if (typeof method !== 'string' || method.length === 0) {
      throw new ControlError('invalid_params', 'method must be a non-empty string')
    }
    return { method, params }
  },
  'sync.status': none,
  'sync.subscribe': none,
  'sync.setupVault': none,
  'sync.unlockRecovery': (raw) => {
    const { recoveryKey } = record(raw)
    if (
      typeof recoveryKey !== 'string' ||
      recoveryKey.trim().length === 0 ||
      recoveryKey.length > 128
    ) {
      throw new ControlError('invalid_params', 'recoveryKey must be a non-empty string')
    }
    return { recoveryKey }
  },
  'sync.approveDevice': (raw) => {
    const { deviceId } = record(raw)
    if (!isSyncDeviceId(deviceId)) {
      throw new ControlError('invalid_params', 'deviceId must be a 32-character hex sync device id')
    }
    return { deviceId }
  },
  'sync.confirmApproval': (raw) => {
    const { matches } = record(raw)
    if (typeof matches !== 'boolean') {
      throw new ControlError('invalid_params', 'matches must be a boolean')
    }
    return { matches }
  },
  'sync.rejectDevice': (raw) => {
    const { deviceId } = record(raw)
    if (!isSyncDeviceId(deviceId)) {
      throw new ControlError('invalid_params', 'deviceId must be a 32-character hex sync device id')
    }
    return { deviceId }
  },
  'sync.removeDeviceWrap': (raw) => {
    const { deviceId } = record(raw)
    if (!isSyncDeviceId(deviceId)) {
      throw new ControlError('invalid_params', 'deviceId must be a 32-character hex sync device id')
    }
    return { deviceId }
  },
  'sync.putUsage': (raw) => {
    const { deviceId, deviceName, updatedAt, island, ifOlderOnly } = record(raw)
    if (deviceId !== undefined && !isSyncItemKey(deviceId)) {
      throw new ControlError('invalid_params', 'deviceId must be a valid usage device key')
    }
    if (deviceName !== undefined && (typeof deviceName !== 'string' || deviceName.length > 128)) {
      throw new ControlError('invalid_params', 'deviceName must be a string')
    }
    if (typeof updatedAt !== 'number' || !Number.isFinite(updatedAt) || updatedAt < 0) {
      throw new ControlError('invalid_params', 'updatedAt must be a non-negative number')
    }
    const payload = record(island)
    if (ifOlderOnly !== undefined && typeof ifOlderOnly !== 'boolean') {
      throw new ControlError('invalid_params', 'ifOlderOnly must be a boolean')
    }
    return {
      ...(deviceId !== undefined ? { deviceId } : {}),
      ...(deviceName !== undefined ? { deviceName } : {}),
      updatedAt,
      island: payload,
      ...(ifOlderOnly !== undefined ? { ifOlderOnly } : {}),
    }
  },
  'sync.getUsage': none,
  'sync.removeUsage': (raw) => {
    const { deviceId } = record(raw)
    if (!isSyncItemKey(deviceId)) {
      throw new ControlError('invalid_params', 'deviceId must be a valid usage device key')
    }
    return { deviceId }
  },
  'sync.disconnect': none,
  'sync.now': none,
  'sync.pushClientState': (raw) => {
    const { uiPrefs, device } = record(raw)
    const out: ControlCalls['sync.pushClientState']['params'] = {}
    if (uiPrefs !== undefined && uiPrefs !== null) {
      const obj = record(uiPrefs)
      const cleaned: Record<string, { value: unknown; updatedAt: number }> = {}
      for (const [k, v] of Object.entries(obj)) {
        if (typeof v === 'object' && v !== null && !Array.isArray(v)) {
          const entry = v as { value?: unknown; updatedAt?: unknown }
          if (typeof entry.updatedAt === 'number' && Number.isFinite(entry.updatedAt)) {
            cleaned[k] = { value: entry.value, updatedAt: entry.updatedAt }
          }
        }
      }
      out.uiPrefs = cleaned
    }
    if (device !== undefined && device !== null) {
      const d = record(device)
      if (
        typeof d.id === 'string' &&
        DEVICE_ID.test(d.id) &&
        typeof d.publicKey === 'string' &&
        publicKeyBytes(d.publicKey) !== null &&
        typeof d.name === 'string' &&
        typeof d.kind === 'string' &&
        typeof d.platform === 'string'
      ) {
        out.device = {
          id: d.id,
          publicKey: d.publicKey,
          name: d.name.slice(0, 64),
          kind: d.kind.slice(0, 32),
          platform: d.platform.slice(0, 32),
          ...(typeof d.model === 'string' ? { model: d.model.slice(0, 64) } : {}),
        }
      }
    }
    return out
  },
}

export interface ControlServer {
  /** Stops listening and ends every connection. */
  close(): Promise<void>
}

/** Serves the CLI's requests on `socketPath` until it is closed. */
export async function serveControl(
  socketPath: string,
  handlers: ControlHandlers,
  warn: (message: string) => void,
): Promise<ControlServer> {
  const ports = new Set<PortChannel>()
  const server: Server = await listenPorts(socketPath, (port) => {
    ports.add(port)
    port.onClose(() => ports.delete(port))
    const connection: ControlConnection = {
      notify: (event) => port.send({ type: 'event', event } satisfies Reply),
      onClose: (listener) => port.onClose(listener),
    }
    port.onMessage((data) => void answer(port, connection, data))
  })
  return {
    close: () =>
      new Promise((resolve) => {
        // A client that keeps its end open cannot hold the daemon up.
        const timer = setTimeout(resolve, CLOSE_WAIT_MS)
        server.close(() => {
          clearTimeout(timer)
          resolve()
        })
        for (const port of ports) port.close()
      }),
  }

  async function answer(
    port: PortChannel,
    connection: ControlConnection,
    data: unknown,
  ): Promise<void> {
    const request = data as Request
    if (
      typeof request !== 'object' ||
      request === null ||
      request.type !== 'request' ||
      !Number.isSafeInteger(request.id)
    ) {
      warn('Ignored a malformed control message')
      return
    }
    const method = request.method as ControlMethod
    let reply: Reply
    try {
      if (typeof method !== 'string' || !Object.hasOwn(validators, method)) {
        throw new ControlError('unknown_method', `Unknown method "${String(method)}"`)
      }
      const params = validators[method](request.params)
      const handler = handlers[method] as (
        params: unknown,
        connection: ControlConnection,
      ) => Promise<unknown>
      const result = await handler(params, connection)
      reply = { type: 'response', id: request.id, result: result ?? null }
    } catch (error) {
      const known = error instanceof ControlError
      if (!known) warn(`Control request ${String(method)} failed: ${(error as Error)?.stack}`)
      reply = {
        type: 'error',
        id: request.id,
        error: known
          ? { code: error.code, message: error.message }
          : { code: 'internal', message: 'The daemon could not answer' },
      }
    }
    port.send(reply)
  }
}

/** A connection to the running daemon, for several requests and the events between them. */
export interface ControlClient {
  call<M extends ControlMethod>(
    method: M,
    params: Params<M>,
    timeoutMs?: number,
  ): Promise<Result<M>>
  onEvent(listener: (event: ControlEvent) => void): void
  /** Runs once the connection is gone, closed by either end. */
  onClose(listener: () => void): void
  close(): void
}

/** Connects to the running daemon; throws `NotRunning` when nothing listens. */
export async function connectControl(socketPath: string): Promise<ControlClient> {
  let port: PortChannel
  try {
    port = await connectPort(socketPath)
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code
    if (code === 'ENOENT' || code === 'ECONNREFUSED') throw new NotRunning()
    throw error
  }
  const pending = new Map<number, (reply: Reply | null) => void>()
  const eventListeners: ((event: ControlEvent) => void)[] = []
  let nextId = 1
  let closed = false
  port.onClose(() => {
    closed = true
    for (const settle of [...pending.values()]) settle(null)
  })
  port.onMessage((data) => {
    const reply = data as Reply
    if (reply?.type === 'event') {
      for (const listener of eventListeners) listener(reply.event)
    } else if (reply && pending.has(reply.id)) {
      pending.get(reply.id)!(reply)
    }
  })
  return {
    call: (method, params, timeoutMs = 30_000) =>
      new Promise((resolve, reject) => {
        const id = nextId++
        const timer = setTimeout(() => {
          pending.delete(id)
          reject(new Error(`The daemon did not answer within ${timeoutMs / 1000} s`))
        }, timeoutMs)
        pending.set(id, (reply) => {
          clearTimeout(timer)
          pending.delete(id)
          if (!reply) reject(new Error('The daemon closed the connection before it answered'))
          else if (reply.type === 'response') resolve(reply.result as Result<typeof method>)
          else if (reply.type === 'error') {
            reject(new ControlError(reply.error.code, reply.error.message))
          }
        })
        if (closed) pending.get(id)!(null)
        else port.send({ type: 'request', id, method, params } satisfies Request)
      }),
    onEvent: (listener) => void eventListeners.push(listener),
    onClose: (listener) => port.onClose(listener),
    close: () => port.close(),
  }
}

/** One request to the running daemon; throws `NotRunning` when nothing listens. */
export async function callControl<M extends ControlMethod>(
  socketPath: string,
  method: M,
  params: Params<M>,
  timeoutMs = 30_000,
): Promise<Result<M>> {
  const client = await connectControl(socketPath)
  try {
    return await client.call(method, params, timeoutMs)
  } finally {
    client.close()
  }
}
