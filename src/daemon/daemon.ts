// `sarto run`: what main does in the desktop app, without windows. It holds the control socket,
// the host's key and the settings, starts the hosts and stops them in order. It alone writes the
// settings, so a change from the CLI comes through the control socket and applies at once.

import {
  adoptReportZip,
  bundleForDevice,
  readReportFile,
  ReportShelf,
} from '@shared/log/report-bundle'
import { constants } from 'node:fs'
import { chmod, copyFile, rm } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { DEBUG_PORTS_FILE } from '@shared/debug'
import {
  DebugPortsFile,
  INSPECT_ENV,
  openInspector,
  removePortsFile,
} from '@shared/log/debug-inspector'
import {
  logEnvironment,
  logFolder,
  setLogLevel,
  setVerboseRecords,
  verboseRecords,
} from '@shared/log/process-log'
import { matchLocale, resolveLocale } from '@shared/locale'
import type { HostPairingState } from '@shared/remote/hosts'
import { PUSH_URL_ENV, pushUrlFrom } from '@shared/remote/push'
import { RELAY_TOKENS_FEATURE, RELAY_URL_ENV, relayUrlFrom } from '@shared/remote/relay'
import {
  detectDaemonOrigin,
  formatDaemonBuildDetails,
  type DaemonBuildInfo,
  type DaemonOrigin,
} from '../core/build-info'
import type { HostAdmin } from '../core/host-admin'
import { clientInfo } from '../core/account/service'
import { locale as currentLocale, setLocale, t } from '../core/i18n'
import { createLogger } from '../core/log'
import { MarketKeys, marketKeysFile } from '../core/market-keys'
import { RelayFeatures, RelayToken, readRelayFeatures } from '../core/relay-token'
import { nodeSystemReleaseForRun } from '../core/system-name'
import type { RemoteIdentity } from '../core/remote-identity'
import { SettingsStore } from '../core/settings'
import { answerSettingsCall } from '../core/settings-call'
import { SettingsError } from '../core/settings-schema'
import { startDaemonAdmin } from './admin'
import {
  callControl,
  ControlError,
  NotRunning,
  serveControl,
  type ControlConnection,
  type ControlHandlers,
  type ControlServer,
  type DaemonStatus,
  type TerminalReport,
} from './control'
import { isUnavailable, type HostTimings } from './forked-host'
import { Hosts } from './hosts'
import { takeDebugRun } from './debug'
import {
  keyIsPrivate,
  loadDeviceHostKey,
  loadHostKey,
  loadRelayHostKey,
  newHostKey,
  newRelayHostKey,
  prepareDataFolder,
} from './key'
import { createKeychainCipher } from './keychain'
import { proxiedFetch } from './proxy'
import { keyPath } from './paths'
import { clearReports, daemonReport, reportsFolder, submitShelvedReport } from './problem-report'
import { readSshPort, writeSshPort } from './ssh-port'
import { CloudAccount } from './cloud-account'
import { CloudThemeSync } from './cloud-theme'
import { PriceUpdates } from './prices'
import { applyUsageDefault, claimUsageDefault } from './usage-default'
import { AgentHostLink } from './sync/agent-host-link'
import { SartoSyncService } from './sync/service'

const log = createLogger('daemon')

/** Set in the service's environment, so the daemon can say it runs as one. */
export const SERVICE_ENV = 'SARTO_DAEMON_SERVICE'

/** How long `sarto verbose on` keeps the detailed records on, as the app's switch. */
const VERBOSE_MS = 24 * 60 * 60 * 1000
/** setTimeout holds at most about 24.8 days. */
const MAX_TIMER_MS = 2 ** 31 - 1
/** How long changes of the remote host's device sessions gather before they sync. */
const REMOTE_SYNC_DEBOUNCE_MS = 3_000

export interface DaemonOptions {
  dataPath: string
  controlSocket: string
  version: string
  /** Build metadata for diagnostics and status reporting; optional for tests and callers. */
  buildInfo?: DaemonBuildInfo
  bundleDir: string
  env: NodeJS.ProcessEnv
  /** `sarto run --debug`; a marker `sarto restart --debug` left asks for the same. */
  debug: boolean
  timings?: HostTimings
}

/** Something already listens on the data folder's control socket. */
export class AlreadyRunning extends Error {
  constructor(readonly pid: number | null) {
    super(
      pid === null
        ? 'Something already listens on the control socket'
        : `A Sarto daemon is already running on this data folder (pid ${pid})`,
    )
    this.name = 'AlreadyRunning'
  }
}

export interface RunningDaemon {
  /** Stops the hosts, then lets the control socket go; the same promise for every call. */
  stop(): Promise<void>
}

/** Listens on the control socket, the lock on the data folder, unless a daemon answers on it. */
async function claimControlSocket(
  socketPath: string,
  serve: () => Promise<ControlServer>,
): Promise<ControlServer> {
  let pid: number | null = null
  try {
    pid = (await callControl(socketPath, 'status', undefined, 5000)).pid
  } catch (error) {
    // Anything else listens but does not answer as a daemon would, so it is left alone.
    if (!(error instanceof NotRunning)) throw new AlreadyRunning(null)
  }
  if (pid !== null) throw new AlreadyRunning(pid)
  // Left by a daemon that was killed.
  await rm(socketPath, { force: true })
  try {
    return await serve()
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'EADDRINUSE') throw new AlreadyRunning(null)
    throw error
  }
}

function debugFile(): string | null {
  const folder = logFolder()
  return folder ? path.join(folder, DEBUG_PORTS_FILE) : null
}

/**
 * A debug run logs at the debug level and opens the daemon's inspector on 127.0.0.1, then each
 * host's as it starts; a normal run removes the list a debug run left.
 */
async function startDebugMode(debug: boolean): Promise<DebugPortsFile | null> {
  const file = debugFile()
  if (!debug) {
    if (file) await removePortsFile(file)
    return null
  }
  setLogLevel('debug')
  const ports = new DebugPortsFile(file, { cdp: false })
  log.warn('Debug mode: inspectors without authentication are open on 127.0.0.1 for this run')
  try {
    ports.setInspector('daemon', openInspector())
  } catch (error) {
    log.error('Could not open the inspector', error)
  }
  return ports
}

export async function startDaemon(options: DaemonOptions): Promise<RunningDaemon> {
  const startedAt = Date.now()
  const origin: DaemonOrigin = detectDaemonOrigin(options.bundleDir)
  const daemonMetadata = {
    build: options.buildInfo?.build,
    channel: options.buildInfo?.channel,
    commit: options.buildInfo?.commit,
    origin,
  }
  await prepareDataFolder(options.dataPath)
  let stopping = false
  let hosts: Hosts | null = null
  let syncService: SartoSyncService | null = null
  let debugPorts: DebugPortsFile | null = null
  const syncConnections = new Set<ControlConnection>()
  let cloud: CloudAccount | null = null
  let cloudTheme: CloudThemeSync | null = null
  let relayToken: RelayToken | null = null
  const accountConnections = new Set<ControlConnection>()
  const hostPairOwners = new Map<number, ControlConnection>()
  const reportShelf = new ReportShelf(reportsFolder(options.dataPath))
  /** Sends `hosts.pairing` events to `connection`, and ends the pairing once it closes. */
  const ownHostPairing = (
    connection: ControlConnection,
    start: (listener: (pairing: HostPairingState) => void) => number,
  ): { pairId: number } => {
    let pairId = 0
    let done = false
    pairId = start((pairing) => {
      if (pairing.state === 'added' || pairing.state === 'failed') {
        done = true
        hostPairOwners.delete(pairId)
      }
      connection.notify({ type: 'hosts.pairing', pairId, pairing })
    })
    if (!done) {
      hostPairOwners.set(pairId, connection)
      connection.onClose(() => {
        if (hostPairOwners.get(pairId) !== connection) return
        hostPairOwners.delete(pairId)
        hosts?.closeHostPairing(pairId)
      })
    }
    return { pairId }
  }
  const requireHostPairing = (pairId: number, connection: ControlConnection): Hosts => {
    if (hostPairOwners.get(pairId) !== connection) {
      throw new ControlError('not_found', 'This connection started no such pairing')
    }
    return starting()
  }

  const starting = (): Hosts => {
    if (!hosts) throw new ControlError('unavailable', 'The daemon is starting')
    return hosts
  }
  const requireCloud = (): CloudAccount => {
    if (!cloud) throw new ControlError('unavailable', 'The account is starting')
    return cloud
  }
  const requireCloudTheme = (): CloudThemeSync => {
    if (!cloudTheme) throw new ControlError('unavailable', 'The account is starting')
    return cloudTheme
  }
  const requireSync = (): SartoSyncService => {
    if (!syncService) throw new ControlError('unavailable', 'Sarto sync is starting')
    return syncService
  }
  const handlers: ControlHandlers = {
    status: async () => status(),
    'host.socket': async ({ host }) => {
      try {
        return { path: await starting().socket(host) }
      } catch (error) {
        if (!isUnavailable(error)) throw error
        throw new ControlError('unavailable', `The ${host} host is ${error.message}`)
      }
    },
    'devices.list': async () => starting().devices(),
    'devices.remove': async ({ id }) => {
      await starting().removeDevice(id)
      await syncService?.deviceRemovedByHand(id)
      return null
    },
    'terminal.get': async () => {
      starting()
      return terminalReport()
    },
    'terminal.set': async ({ allowed }) => {
      starting()
      changeSettings({ remote: { terminal: allowed } })
      return terminalReport()
    },
    'report.build': async ({ request }) =>
      daemonReport(
        starting(),
        {
          version: options.version,
          dataPath: options.dataPath,
          settings: settings.get(),
          metadata: daemonMetadata,
        },
        request,
      ),
    'report.prepare': async ({ request, client }) => {
      const built = await daemonReport(
        starting(),
        {
          version: options.version,
          dataPath: options.dataPath,
          settings: settings.get(),
          metadata: daemonMetadata,
        },
        request,
        client ?? null,
      )
      if (!built.ok) return built
      const platformParts = [client?.osVersion?.trim(), client?.hardware?.trim()].filter(
        (item): item is string => Boolean(item),
      )
      const id = reportShelf.put({
        file: built.file,
        files: built.files,
        size: built.size,
        request,
        ...(built.redactionCount !== undefined ? { redactionCount: built.redactionCount } : {}),
        ...(client?.appVersion || platformParts.length > 0
          ? {
              clientMeta: {
                version: client?.appVersion ?? null,
                platform: platformParts.length > 0 ? platformParts.join(' ') : null,
              },
            }
          : {}),
      })
      if (!id) {
        await rm(built.file, { force: true }).catch(() => {})
        return { ok: false, reason: 'failed', message: 'Could not keep the prepared report' }
      }
      return {
        ok: true,
        id,
        files: built.files,
        size: built.size,
        ...(built.redactionCount !== undefined ? { redactionCount: built.redactionCount } : {}),
      }
    },
    'report.adopt': async ({ zip, files, redactionCount }) => {
      const adopted = await adoptReportZip(reportShelf, zip, files, redactionCount)
      if (!adopted) {
        return { ok: false, reason: 'failed', message: 'Could not keep the remote report bundle' }
      }
      return { ok: true, ...adopted }
    },
    'report.read': async ({ id, path: entryPath }) => {
      const shelved = reportShelf.get(id)
      if (!shelved) {
        throw new ControlError('not_found', 'The prepared report is no longer available')
      }
      const view = await readReportFile(shelved.file, entryPath)
      if (!view) throw new ControlError('not_found', 'The file is not in this report')
      return view
    },
    'report.save': async ({ id, destination, overwrite }) => {
      const shelved = reportShelf.get(id)
      if (!shelved) {
        throw new ControlError('not_found', 'The prepared report is no longer available')
      }
      if (!path.isAbsolute(destination)) {
        throw new ControlError('invalid_params', 'destination must be an absolute path')
      }
      const target = path.resolve(destination)
      const flags = overwrite ? 0 : constants.COPYFILE_EXCL
      try {
        await copyFile(shelved.file, target, flags)
      } catch (error) {
        const code = (error as NodeJS.ErrnoException).code
        if (code === 'EEXIST') {
          throw new ControlError('invalid_params', `${target} already exists`)
        }
        throw new ControlError('unavailable', (error as Error).message)
      }
      return { ok: true, path: target }
    },
    'report.submit': async ({ id, allowAnonymous }) =>
      submitShelvedReport(reportShelf, id, {
        cloud,
        version: options.version,
        settings: settings.get(),
        ...(allowAnonymous !== undefined ? { allowAnonymous } : {}),
      }),
    'report.drop': async ({ id }) => {
      reportShelf.drop(id)
      return null
    },
    'report.list': async ({ limit, status }) => {
      const emptyCounts = {
        submitted: 0,
        investigating: 0,
        confirmed: 0,
        fixed: 0,
        wont_fix: 0,
        closed: 0,
      }
      if (!cloud || cloud.status().account.state !== 'signed-in') {
        return {
          signedIn: false,
          origin: cloud?.origin() ?? '',
          reports: [],
          total: 0,
          countsByStatus: emptyCounts,
        }
      }
      try {
        const list = await cloud.listReports({
          ...(limit !== undefined ? { limit } : {}),
          ...(status !== undefined ? { status } : {}),
        })
        return {
          signedIn: true,
          origin: cloud.origin(),
          reports: list.reports,
          total: list.total,
          countsByStatus: list.countsByStatus ?? emptyCounts,
        }
      } catch (error) {
        throw new ControlError('unavailable', (error as Error).message)
      }
    },
    'verbose.set': async ({ on }) => {
      starting()
      changeSettings({ diagnostics: { verboseUntil: on ? Date.now() + VERBOSE_MS : null } })
      return { until: settings.get().diagnostics.verboseUntil }
    },
    'account.reload': async () => {
      await cloud?.account().reload()
      return null
    },
    'account.status': async () => requireCloud().status(),
    'account.subscribe': async (_, connection) => {
      const holder = requireCloud()
      accountConnections.add(connection)
      connection.onClose(() => accountConnections.delete(connection))
      return holder.status()
    },
    'account.signIn': async ({ serverUrl, openBrowser }) => {
      try {
        return await requireCloud().signIn(
          serverUrl,
          openBrowser !== undefined ? { openBrowser } : undefined,
        )
      } catch (error) {
        throw new ControlError('invalid_params', (error as Error).message)
      }
    },
    'account.cancelSignIn': async () => requireCloud().cancelSignIn(),
    'account.signOut': async () => requireCloud().signOut(),
    'account.check': async () => {
      const next = await requireCloud().check()
      void cloudTheme?.pushIfNeeded().catch(() => {})
      return next
    },
    'account.devices': async () => {
      try {
        return await requireCloud().devices()
      } catch (error) {
        throw new ControlError('unavailable', (error as Error).message)
      }
    },
    'account.removeDevice': async ({ id }) => {
      try {
        await requireCloud().removeDevice(id)
        if (syncService) void syncService.syncNow().catch(() => {})
        return null
      } catch (error) {
        throw new ControlError('unavailable', (error as Error).message)
      }
    },
    'account.relayToken': async () => {
      try {
        return await requireCloud().relayToken()
      } catch (error) {
        throw new ControlError('unavailable', (error as Error).message)
      }
    },
    'account.preferences': async () => {
      try {
        return await requireCloudTheme().getPreferences()
      } catch (error) {
        throw new ControlError('unavailable', (error as Error).message)
      }
    },
    'account.setPreferences': async ({ appTheme }) => {
      try {
        if (appTheme === undefined) return await requireCloudTheme().getPreferences()
        return await requireCloudTheme().setAppTheme(appTheme)
      } catch (error) {
        throw new ControlError('unavailable', (error as Error).message)
      }
    },
    'hosts.device': async () => starting().deviceKeyInfo(),
    'hosts.list': async () => starting().otherHostList(),
    'hosts.subscribe': async (_, connection) => {
      const hosts = starting()
      const stop = hosts.onOtherHosts((list) =>
        connection.notify({ type: 'hosts.updated', hosts: list }),
      )
      connection.onClose(stop)
      // Before the remote host's first report, the list follows as an event.
      return hosts.otherHostsNow() ?? []
    },
    'hosts.pairDiscovered': async ({ relayId, model }, connection) => {
      const hosts = starting()
      return ownHostPairing(connection, (listener) =>
        hosts.pairDiscovered(relayId, model, listener),
      )
    },
    'hosts.pairMatch': async ({ pairId, match }, connection) => {
      requireHostPairing(pairId, connection).matchHostPairing(pairId, match)
      return null
    },
    'hosts.pairClose': async ({ pairId }, connection) => {
      requireHostPairing(pairId, connection).closeHostPairing(pairId)
      hostPairOwners.delete(pairId)
      return null
    },
    'hosts.discover': async () => starting().discoverHosts(),
    'hosts.remove': async ({ id }) => {
      starting().removeOtherHost(id)
      return null
    },
    'hosts.rename': async ({ id, name }) => ({ renamed: starting().renameOnHost(id, name) }),
    admin: async ({ method, params }) => {
      starting()
      if (!admin) throw new ControlError('unavailable', 'The daemon is starting')
      // The control socket is the owner's, on this computer.
      const answer = await admin.answer('00000000000000000000000000000000', method, params, true)
      if ('error' in answer) {
        const { code, message } = answer.error
        const mapped =
          code === 'unknown_method' ||
          code === 'invalid_params' ||
          code === 'not_found' ||
          code === 'unavailable'
            ? code
            : 'internal'
        throw new ControlError(mapped, message)
      }
      return answer.result
    },
    'ssh.setup': async ({ device }) => {
      const running = starting()
      // Throws while nothing listens, before the device is added.
      const info = running.sshInfo()
      if (device) await running.addDevice(device)
      return {
        ...info,
        name: settings.get().remote.name ?? os.hostname(),
        platform: process.platform,
        version: options.version,
      }
    },
    'sync.status': async () => requireSync().status(),
    'sync.subscribe': async (_, connection) => {
      const svc = requireSync()
      syncConnections.add(connection)
      connection.onClose(() => syncConnections.delete(connection))
      return svc.status()
    },
    'sync.setupVault': async () => {
      try {
        return await requireSync().setupVault()
      } catch (error) {
        throw new ControlError('invalid_params', (error as Error).message)
      }
    },
    'sync.unlockRecovery': async ({ recoveryKey }) => {
      try {
        return await requireSync().unlockWithRecoveryKey(recoveryKey)
      } catch (error) {
        throw new ControlError('invalid_params', (error as Error).message)
      }
    },
    'sync.approveDevice': async ({ deviceId }) => {
      try {
        return await requireSync().approveDevice(deviceId)
      } catch (error) {
        throw new ControlError('invalid_params', (error as Error).message)
      }
    },
    'sync.confirmApproval': async ({ matches }) => {
      try {
        return await requireSync().confirmApproval(matches)
      } catch (error) {
        throw new ControlError('invalid_params', (error as Error).message)
      }
    },
    'sync.rejectDevice': async ({ deviceId }) => {
      try {
        return await requireSync().rejectDevice(deviceId)
      } catch (error) {
        throw new ControlError('invalid_params', (error as Error).message)
      }
    },
    'sync.removeDeviceWrap': async ({ deviceId }) => {
      try {
        return await requireSync().removeDeviceWrap(deviceId)
      } catch (error) {
        throw new ControlError('unavailable', (error as Error).message)
      }
    },
    'sync.putUsage': async (params) => {
      try {
        return await requireSync().putUsage(params)
      } catch (error) {
        throw new ControlError('invalid_params', (error as Error).message)
      }
    },
    'sync.getUsage': async () => requireSync().clientUsageSnapshot(),
    'sync.removeUsage': async ({ deviceId }) => {
      try {
        return await requireSync().removeUsage(deviceId)
      } catch (error) {
        throw new ControlError('invalid_params', (error as Error).message)
      }
    },
    'sync.disconnect': async () => requireSync().disconnect(),
    'sync.now': async () => {
      try {
        const res = await requireSync().syncNow()
        void cloudTheme?.pushIfNeeded().catch(() => {})
        return res
      } catch (error) {
        throw new ControlError('unavailable', (error as Error).message)
      }
    },
    'sync.pushClientState': async (params) => {
      const res = await requireSync().pushClientState(params)
      const palette = params.uiPrefs?.palette?.value
      if (palette !== undefined) cloudTheme?.noteAppTheme(palette)
      return res
    },
  }
  const server = await claimControlSocket(options.controlSocket, () =>
    serveControl(options.controlSocket, handlers, (message) => log.warn(message)),
  )

  let settings: SettingsStore
  let identity: RemoteIdentity
  let relayKey: RemoteIdentity | null = null
  let deviceKey: RemoteIdentity | null = null
  let sshPort: number | null
  try {
    await chmod(options.controlSocket, 0o600)
    identity = await loadHostKey(options.dataPath, (message) => log.warn(message))
    settings = await SettingsStore.load(options.dataPath)
    sshPort = await readSshPort(options.dataPath)
    if (!settings.get().remote.enabled) settings.update({ remote: { enabled: true } })
    if (settings.get().remote.direct.enabled) {
      settings.update({ remote: { direct: { enabled: false } } })
    }
    await clearReports(options.dataPath)
  } catch (error) {
    await release(server, options.controlSocket)
    throw error
  }
  // The text main's modules write follows the daemon's language, as its hosts' does.
  const systemLocale = matchLocale([Intl.DateTimeFormat().resolvedOptions().locale])
  setLocale(resolveLocale(settings.get().general.language, systemLocale))
  settings.onChange((next, changed) => {
    if (changed.has('general')) setLocale(resolveLocale(next.general.language, systemLocale))
  })
  try {
    relayKey = await loadRelayHostKey(options.dataPath)
  } catch (error) {
    log.error(`The relay cannot be used without its key: ${(error as Error).message}`)
  }
  try {
    deviceKey = await loadDeviceHostKey(options.dataPath)
  } catch (error) {
    log.error(`Other hosts cannot be reached without the device key: ${(error as Error).message}`)
  }
  // Local secret encryption via macOS Keychain (falls back to 0600 files when unavailable/locked).
  const localCipher = await createKeychainCipher(options.dataPath, {
    env: options.env,
    log: createLogger('keychain'),
  })
  // The Sarto Cloud account: signing in through the browser, its tokens kept fresh, and the
  // relay and push gateway at the same origin unless the environment names others.
  cloud = await CloudAccount.load({
    dataPath: options.dataPath,
    env: options.env,
    fetch: proxiedFetch(() => settings.get().proxy, options.env),
    cipher: localCipher,
    clientInfo: async () =>
      clientInfo({
        kind: 'daemon',
        name: settings.get().remote.name ?? os.hostname(),
        os: await nodeSystemReleaseForRun(),
        arch: process.arch,
        version: options.version,
      }),
    locale: currentLocale,
    log: createLogger('account'),
  })
  const signedInCloud = cloud
  cloudTheme = new CloudThemeSync({
    cloud: signedInCloud,
    log: createLogger('cloud-theme'),
  })
  signedInCloud.onChange((status) => {
    relayToken?.update()
    hosts?.settingsChanged(new Set(['remote']))
    cloudTheme?.noteAccountChanged()
    void syncService?.accountChanged().catch((error: unknown) => {
      log.warn(`The sync could not follow the account: ${(error as Error).message}`)
    })
    for (const conn of accountConnections) conn.notify({ type: 'account.updated', status })
  })
  const rawRelayUrl = options.env[RELAY_URL_ENV]?.trim() ?? ''
  let relayUrl = signedInCloud.origin()
  if (rawRelayUrl) {
    try {
      relayUrl = relayUrlFrom(rawRelayUrl)
    } catch (error) {
      log.error(`Invalid ${RELAY_URL_ENV}; relay disabled: ${(error as Error).message}`)
    }
  }
  const rawPushUrl = options.env[PUSH_URL_ENV]?.trim() ?? ''
  let pushUrl = signedInCloud.origin()
  if (rawPushUrl) {
    try {
      pushUrl = pushUrlFrom(rawPushUrl)
    } catch (error) {
      log.error(`Invalid ${PUSH_URL_ENV}; push gateway disabled: ${(error as Error).message}`)
    }
  }
  const signedIn = (): boolean => signedInCloud.account().status().state === 'signed-in'

  // Taken once the socket is this run's, so a second `sarto run` leaves the service's marker be.
  const marked = await takeDebugRun(options.dataPath).catch((error: unknown) => {
    log.warn(`Could not read the debug marker: ${(error as Error).message}`)
    return false
  })
  debugPorts = await startDebugMode(options.debug || marked)
  // The marker stays with the daemon, so a `sarto run` in a shell an agent or terminal starts is
  // not taken for the service.
  const hostEnv: NodeJS.ProcessEnv = {
    ...options.env,
    ...logEnvironment(),
    ...(options.env.SARTO_DISABLE_REPORTS !== undefined
      ? { SARTO_DISABLE_REPORTS: options.env.SARTO_DISABLE_REPORTS }
      : {}),
    ...(options.debug || marked ? { [INSPECT_ENV]: '1' } : {}),
  }
  delete hostEnv[SERVICE_ENV]
  let admin: HostAdmin | null = null
  // Encrypted with the macOS Keychain when available, else in a 0600 file only the user can read.
  const marketKeys = await MarketKeys.load({
    file: marketKeysFile(options.dataPath),
    cipher: localCipher,
    plainTextAllowed: true,
    servers: () => settings.get().marketplace.mcp,
    changed: (contents) => {
      hosts?.marketKeysChanged(contents)
      syncService?.noteMarketKeysChanged()
    },
    log: createLogger('market-keys'),
  })
  settings.onChange((_, changed) => {
    if (changed.has('marketplace')) marketKeys.prune()
  })
  const running = new Hosts({
    bundleDir: options.bundleDir,
    dataPath: options.dataPath,
    version: options.version,
    systemLocale,
    settings: () => settings.get(),
    marketKeys: () => marketKeys.contentsForHost(),
    marketOAuth: (serverId, state) => void marketKeys.setOAuth(serverId, state),
    firstStart: (harnesses) => settings.firstStart(harnesses),
    privateKey: identity.privateKey,
    newIdentity: async () => (await newHostKey(options.dataPath)).privateKey,
    relayKey: relayKey?.privateKey ?? null,
    newRelayKey: async () => (await newRelayHostKey(options.dataPath)).privateKey,
    deviceKey: deviceKey?.privateKey ?? null,
    relayUrl,
    pushUrl,
    signedIn,
    settingsCall: (call) =>
      answerSettingsCall(call, {
        settings,
        facts: () => ({
          'remote.devices': hosts?.remoteAccess().devices.length ?? null,
          'advanced.data-folder': options.dataPath,
        }),
      }),
    hostName: os.hostname(),
    env: hostEnv,
    inspector: (name, url) => debugPorts?.setInspector(name, url),
    timings: options.timings,
    sshPort,
    sshPortChanged: (port) => {
      writeSshPort(options.dataPath, port).catch((error: unknown) => {
        log.warn(`Could not keep the port for SSH: ${(error as Error).message}`)
      })
    },
    admin: async (deviceId, method, params) =>
      admin
        ? admin.answer(deviceId, method, params)
        : { error: { code: 'unavailable', message: t('hostAdmin.starting') } },
  })
  hosts = running
  {
    let mainRelay = new RelayFeatures(() => readRelayFeatures(relayUrl))
    let relayOrigin = relayUrl
    relayToken = new RelayToken({
      current: () => signedInCloud.account().currentToken(),
      exchange: async () => {
        // Signing in to another server moves the relay and push gateway with it.
        const origin = rawRelayUrl ? relayUrl : signedInCloud.origin()
        if (origin !== relayOrigin) {
          relayOrigin = origin
          mainRelay = new RelayFeatures(() => readRelayFeatures(origin))
          running.configureRelay({
            url: origin,
            pushUrl: rawPushUrl ? pushUrl : origin,
            enabled: settings.get().remote.relay,
            token: null,
          })
        }
        return (await mainRelay.has(RELAY_TOKENS_FEATURE))
          ? signedInCloud.account().relayToken()
          : null
      },
      signedIn,
      account: () => signedInCloud.account().signedIn()?.id ?? null,
      needed: () => true,
      send: (token, relay) => {
        running.setToken(token, relay)
      },
    })
    relayToken.update()
  }
  const adminHandle = await startDaemonAdmin({
    dataPath: options.dataPath,
    version: options.version,
    settings,
    hosts: running,
    marketKeys,
    onThemesChanged: () => syncService?.noteThemesChanged(),
    onDeviceRemoved: async (id) => syncService?.deviceRemovedByHand(id),
    report: async (request) =>
      bundleForDevice(
        await daemonReport(
          running,
          {
            version: options.version,
            dataPath: options.dataPath,
            settings: settings.get(),
            metadata: daemonMetadata,
          },
          request,
        ),
        request,
        reportShelf,
      ),
    submitReport: async (ref, opts) =>
      submitShelvedReport(reportShelf, ref, {
        cloud: signedInCloud,
        version: options.version,
        settings: settings.get(),
        ...(opts?.allowAnonymous !== undefined ? { allowAnonymous: opts.allowAnonymous } : {}),
      }),
  })
  admin = adminHandle.admin

  // The sync's own port to the agent host, which waits for the hosts to start.
  let hostsStarted: () => void = () => {}
  const started = new Promise<void>((resolve) => (hostsStarted = resolve))
  // The day's model prices from the Sarto server, which the usage pricing prefers to the
  // snapshot bundled with this build.
  const priceUpdates = new PriceUpdates({
    origin: () => signedInCloud.origin(),
    fetch: proxiedFetch(() => settings.get().proxy, options.env),
    file: path.join(options.dataPath, 'state', 'prices-server.json'),
    log: createLogger('prices'),
  })
  const agentHostLink = new AgentHostLink({
    socket: async () => {
      await started
      return running.socket('agent')
    },
    log: createLogger('sarto-sync'),
  })
  const usageDefault = await claimUsageDefault(options.dataPath).catch((error: unknown) => {
    log.warn(`Could not record the usage default: ${(error as Error).message}`)
    return false
  })
  syncService = await SartoSyncService.start({
    dataPath: options.dataPath,
    cipher: localCipher,
    account: {
      origin: () => signedInCloud.origin(),
      profile: () => {
        const status = signedInCloud.account().status()
        return status.state === 'signed-in'
          ? {
              id: status.account.id,
              email: status.account.email,
              name: status.account.name,
            }
          : null
      },
      token: async () => (await signedInCloud.account().currentToken())?.token ?? null,
      check: async () => {
        await signedInCloud.check()
      },
      signOut: async () => {
        await signedInCloud.signOut()
      },
    },
    settings,
    marketKeys,
    themes: adminHandle.themes,
    relaySeedBase64: relayKey?.privateKey ?? null,
    hostPublicKey: () => running.hostPublicKey(),
    hostName: () => settings.get().remote.name ?? os.hostname(),
    configureRelay: (cfg) => running.configureRelay(cfg),
    addTrustedDevice: (dev) => running.addDevice(dev),
    meshHosts: (list) => running.setMeshHosts(list),
    knownDeviceIds: () => new Set(running.remoteAccess().devices.map((d) => d.id)),
    pairedDevices: () => running.remoteAccess().devices,
    removeTrustedDevice: (id) => running.removeDevice(id),
    reloadMemory: () => running.reloadMemory(),
    exportHostUsage: () => running.exportHostUsage(),
    onRemoteUsageChanged: (remoteHosts, self) => running.setRemoteUsage(remoteHosts, self),
    agentHost: agentHostLink,
    fetchImpl: proxiedFetch(() => settings.get().proxy, options.env),
    log: createLogger('sarto-sync'),
  })
  // Right after the sync starts following the settings, before any of its own steps can run, so
  // the account's copy takes the change with a newer stamp than any it holds.
  if (usageDefault && applyUsageDefault(settings)) {
    log.info('Turned Usage on this computer on, as Sarto counts usage by default')
  }
  // A sign-in made before this start, or by `sarto login`, takes the sync over now.
  void syncService.accountChanged().catch((error: unknown) => {
    log.warn(`The sync could not follow the account: ${(error as Error).message}`)
  })
  syncService.onChange((syncSnap) => {
    for (const conn of syncConnections) {
      conn.notify({ type: 'sync.updated', status: syncSnap })
    }
  })
  syncService.onUsageUpdated((usageSnap) => {
    const clientRecords = usageSnap.records.map((r) => ({
      v: r.v,
      deviceId: r.deviceId,
      deviceName: r.deviceName,
      updatedAt: r.updatedAt,
      ...(r.island ? { island: r.island } : {}),
    }))
    for (const conn of syncConnections) {
      conn.notify({
        type: 'sync.usage.updated',
        ownDeviceId: usageSnap.ownDeviceId,
        records: clientRecords,
      })
    }
  })
  running.onUsageChanged(() => {
    syncService?.noteHostUsageChanged()
  })
  // Each device session that starts, resumes, detaches or ends changes the remote host, and a
  // network change brings a burst of them: they sync once, after the burst.
  let remoteSyncTimer: NodeJS.Timeout | null = null
  running.onRemoteChanged(() => {
    // The remote host's sessions end as it stops; none of that is a change to act on.
    if (stopping) return
    void syncService?.pairedDevicesChanged().catch((error: unknown) => {
      log.warn(`Could not unpair the devices the account removed: ${(error as Error).message}`)
    })
    if (remoteSyncTimer) return
    remoteSyncTimer = setTimeout(() => {
      remoteSyncTimer = null
      if (stopping || !syncService?.isConfigured() || !running.hostPublicKey()) return
      void syncService.syncNow().catch(() => {})
    }, REMOTE_SYNC_DEBOUNCE_MS)
    remoteSyncTimer.unref()
  })
  let verboseTimer: NodeJS.Timeout | null = null
  /** Applies the detailed records setting to the daemon and its agent host, until it ends. */
  const applyVerbose = (): void => {
    if (verboseTimer) clearTimeout(verboseTimer)
    verboseTimer = null
    const until = settings.get().diagnostics.verboseUntil
    const now = Date.now()
    if (until !== null && until <= now) {
      // The change comes back here, with the setting off.
      settings.update({ diagnostics: { verboseUntil: null } })
      return
    }
    const verbose = until !== null
    // A debug run logs at the debug level whether or not detailed records are on.
    const level = verbose || debugPorts ? 'debug' : 'info'
    if (verbose !== verboseRecords())
      log.info(verbose ? 'Detailed records on' : 'Detailed records off')
    setLogLevel(level)
    setVerboseRecords(verbose)
    running.setLogLevel(level, verbose)
    if (until !== null) {
      verboseTimer = setTimeout(applyVerbose, Math.min(until - now, MAX_TIMER_MS))
      verboseTimer.unref()
    }
  }
  applyVerbose()
  settings.onChange((_, changed) => {
    if (changed.has('diagnostics')) applyVerbose()
  })
  running.start()
  hostsStarted()
  agentHostLink.start()
  priceUpdates.start()
  relayToken?.update()
  const buildDetails = formatDaemonBuildDetails(daemonMetadata)
  log.info(
    `Sarto daemon ${options.version}${buildDetails ? ` (${buildDetails})` : ''} running (pid ${process.pid}), data in ${options.dataPath}`,
  )

  // Asked for as soon as the socket listens, before the key and the hosts exist.
  async function status(): Promise<DaemonStatus> {
    const keyFile = keyPath(options.dataPath)
    const idle = { state: 'idle', pid: null, restarts: 0 } as const
    return {
      version: options.version,
      ...(options.buildInfo
        ? {
            build: options.buildInfo.build,
            channel: options.buildInfo.channel,
            commit: options.buildInfo.commit,
          }
        : {}),
      origin,
      pid: process.pid,
      startedAt,
      stopping,
      dataPath: options.dataPath,
      service: options.env[SERVICE_ENV] === '1',
      key: { storage: 'file', path: keyFile, private: await keyIsPrivate(keyFile) },
      hosts: hosts?.status() ?? { agent: idle, terminal: idle, remote: idle },
      connectedDevices: hosts?.connectedDevices() ?? null,
      debug: debugPorts ? { inspectors: debugPorts.status().inspectors, file: debugFile() } : null,
      ...(hosts ? { relay: hosts.relayReport() } : {}),
    }
  }

  function terminalReport(): TerminalReport {
    return { allowed: settings.get().remote.terminal }
  }

  /** Applies a change to the settings, refused with the store's reason when it is not valid. */
  function changeSettings(patch: unknown): void {
    try {
      settings.update(patch)
    } catch (error) {
      if (error instanceof SettingsError) throw new ControlError('invalid_params', error.message)
      throw error
    }
  }

  let stopped: Promise<void> | null = null
  return {
    stop: () => {
      stopped ??= (async () => {
        stopping = true
        if (remoteSyncTimer) clearTimeout(remoteSyncTimer)
        if (verboseTimer) clearTimeout(verboseTimer)
        log.info('Stopping')
        relayToken?.stop()
        cloudTheme?.stop()
        cloud?.stop()
        agentHostLink.stop()
        priceUpdates.stop()
        await syncService?.stop()
        await running.stop()
        await Promise.all([settings.flush(), marketKeys.flush()])
        // Held until now, so a daemon that starts meanwhile cannot run hosts beside these.
        await release(server, options.controlSocket)
        log.info('Stopped')
      })()
      return stopped
    },
  }
}

async function release(server: ControlServer, socketPath: string): Promise<void> {
  await server.close()
  await rm(socketPath, { force: true })
}
