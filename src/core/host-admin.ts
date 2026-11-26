// The host's parent answering its owner's devices beyond their sessions: the host's part of the
// settings and the host's actions in Settings, with the checks the window's calls have. Main and
// the daemon each hand it what they run, so it never imports Electron.

import { stat } from 'node:fs/promises'
import path from 'node:path'
import type { AdminAnswer, HostToMain } from '@shared/host-control'
import type { Platform } from '@shared/platform'
import type { MarketKeyState, MarketServer } from '@shared/marketplace'
import type { PortErrorCode } from '@shared/port-rpc'
import type { DeviceActivity } from '@shared/remote/activity'
import { DEVICE_ID, normalizeDeviceName } from '@shared/remote/device'
import {
  hostSettingsPart,
  isHostAdminMethod,
  ownerOnlySetting,
  splitSettingsPatch,
  type DeviceReport,
  type HostAdminEvent,
  type HostAdminMethod,
  type HostAdminResult,
  type HostAttention,
  type HostInfo,
  type HostThemes,
} from '@shared/remote/host-admin'
import { parseReportRequest, type ReportRequest, type ReportSubmitResult } from '@shared/report'
import type { RemoteStatus } from '@shared/remote/status'
import type { SettingsFile, SettingsPatch } from '@shared/settings'
import type { ThemeInstallResult } from '@shared/themes'
import { isHarnessId } from '@shared/thread'
import { isAbsolutePath } from '../agent-host/paths'
import type { AgentFolders } from './agent-folders'
import { isExecutableFile } from './executable'
import { t } from './i18n'
import { MarketKeysError } from './market-keys'
import type { SettingsStore } from './settings'
import { SettingsError } from './settings-schema'
import { checkThemeText, type ThemeReadResult, type ThemeSelect } from './themes'

// Windows extended-length paths go up to 32,767 characters.
const PATH_CHARS = 32_767
const FILE_NAME_CHARS = 255

/** A call refused with the code its caller is answered, such as `invalid_params`. */
export class AdminError extends Error {
  constructor(
    readonly code: PortErrorCode,
    message: string,
  ) {
    super(message)
    this.name = 'AdminError'
  }
}

const invalid = (message: string): AdminError => new AdminError('invalid_params', message)
const forbidden = (message: string): AdminError => new AdminError('forbidden', message)

function modifiesStdioMcp(current: readonly MarketServer[], patch: SettingsPatch): boolean {
  const marketplace: unknown = patch.marketplace
  if (
    typeof marketplace !== 'object' ||
    marketplace === null ||
    !Object.hasOwn(marketplace, 'mcp')
  ) {
    return false
  }
  const next = (marketplace as { mcp?: unknown }).mcp
  if (!Array.isArray(next)) return false
  const existingStdio = new Map<string, MarketServer>()
  for (const server of current) {
    if (server.spec.type === 'stdio') existingStdio.set(server.id, server)
  }
  for (const entry of next) {
    if (typeof entry !== 'object' || entry === null) continue
    const { id, spec } = entry as { id?: unknown; spec?: unknown }
    if (typeof spec !== 'object' || spec === null) continue
    const { type, transport } = spec as { type?: unknown; transport?: unknown }
    if (type !== 'stdio' && transport !== 'stdio') continue
    const prev = typeof id === 'string' ? existingStdio.get(id) : undefined
    if (!prev || JSON.stringify(prev.spec) !== JSON.stringify(spec)) return true
  }
  return false
}

/** A paired device's id: untrusted input from a window or a device. */
export function deviceIdArg(value: unknown): string {
  if (typeof value !== 'string' || !DEVICE_ID.test(value)) throw invalid('Not a device id')
  return value
}

/** A device's name as the owner typed it, cleaned up as the remote host keeps it. */
export function deviceName(value: unknown): string {
  const name = normalizeDeviceName(value)
  if (!name) throw invalid(t('hostAdmin.deviceNeedsName'))
  return name
}

/** A program the host may run, as a dialog picked it or a device typed it; refused otherwise. */
export async function runnableProgram(file: string): Promise<string> {
  if (!(await isExecutableFile(file))) {
    throw invalid(t('hostAdmin.notProgram', { path: file }))
  }
  return file
}

/** An absolute path on the host as a device typed it, normalized. */
function typedPath(value: unknown, key: string, platform: Platform): string {
  if (typeof value !== 'string' || value.length === 0 || value.length > PATH_CHARS) {
    throw invalid(`${key} must be a path of 1 to ${PATH_CHARS} characters`)
  }
  if (value.includes('\0')) throw invalid(`${key} must not contain a NUL character`)
  if (!isAbsolutePath(value, platform)) throw invalid(`${key} must be an absolute path`)
  return (platform === 'win32' ? path.win32 : path.posix).resolve(value)
}

async function isDirectory(folder: string): Promise<boolean> {
  try {
    return (await stat(folder)).isDirectory()
  } catch {
    return false
  }
}

function fields(params: unknown): Record<string, unknown> {
  if (typeof params !== 'object' || params === null || Array.isArray(params)) {
    throw invalid('params must be an object')
  }
  return params as Record<string, unknown>
}

/** Remote access as the parent runs it, as Settings > Remote access uses it. */
export interface AdminRemote {
  /** False when the device could not be renamed. */
  renameDevice(id: string, name: string): Promise<boolean>
  /** False when the device could not be removed. */
  removeDevice(id: string): Promise<boolean>
  activity(id: string): Promise<DeviceActivity[]>
  reset(): Promise<void>
  retryRelay(): void
}

/** The themes folder, as main's and the daemon's theme stores keep it. */
export interface AdminThemes {
  hostThemes(): HostThemes
  /** Reads the folder again, so a file changed by hand shows. */
  refresh(): Promise<unknown>
  add(file: string, read: ThemeReadResult, select: ThemeSelect): Promise<ThemeInstallResult>
  replace(token: unknown): Promise<ThemeInstallResult>
  remove(id: unknown): Promise<void>
  fileOf(id: unknown): string
}

export interface HostAdminDeps {
  settings: SettingsStore
  agentFolders: AgentFolders
  platform: Platform
  remote: AdminRemote
  remoteStatus(): RemoteStatus
  info(): Promise<HostInfo>
  /** Starts the agent or terminal host again after it failed, as Settings' Restart does. */
  restart(process: 'agent' | 'terminal'): void
  /** Null where the host publishes nothing, as under the daemon. */
  /** Null where Sarto is not updated from Settings, as under the daemon. */
  themes: AdminThemes
  /** The Marketplace's keys, which check an untrusted patch themselves. */
  marketKeys: {
    set(patch: unknown): Promise<MarketKeyState>
    setAgentEnv(agentId: string, variable: string, value: string | null): Promise<void>
  }
  /** A problem report's bundle for an owner's device, built with the host's own logs. */
  report?: (request: ReportRequest) => Promise<DeviceReport>
  /** Submits a shelved bundle built earlier by `report`, using this host's cloud account. */
  submitReport?: (
    ref: string,
    options?: { allowAnonymous?: boolean },
  ) => Promise<ReportSubmitResult>
  /** Remote access is always on, as under the daemon, so a device may not turn it off. */
  remoteAlwaysOn?: boolean
  /** Tells every owner's device, or only `deviceId`. */
  send(event: HostAdminEvent, deviceId: string | null): void
}

/** Answers the owner's devices and tells them what changes on the host. */
export class HostAdmin {
  private sentSettings: string
  private sentRemote: string | null = null
  /** Calls waiting for the updater to say what it does next. */
  /** Themes a device's install showed, which its answer tells it to show. */
  private readonly shown = new Set<string>()
  private readonly showOnDevice: ThemeSelect = (id) => void this.shown.add(id)

  constructor(private readonly deps: HostAdminDeps) {
    this.sentSettings = JSON.stringify(this.part(deps.settings.get()))
  }

  /**
   * Runs a device's call as the remote host passed it, checked again here, answered with its
   * result or the error that refused it. `atThisComputer` is for a call the owner makes on the
   * host's own computer, which alone changes what no device may.
   */
  async answer(
    deviceId: unknown,
    method: unknown,
    params: unknown,
    atThisComputer = false,
  ): Promise<AdminAnswer> {
    try {
      if (typeof deviceId !== 'string' || !DEVICE_ID.test(deviceId)) {
        throw invalid('A call names no device')
      }
      if (typeof method !== 'string' || !isHostAdminMethod(method)) {
        throw new AdminError('unknown_method', `Unknown method "${String(method)}"`)
      }
      return { result: await this.run(deviceId, method, params, atThisComputer) }
    } catch (error) {
      if (error instanceof AdminError) {
        return { error: { code: error.code, message: error.message } }
      }
      if (error instanceof SettingsError) {
        return { error: { code: 'invalid_params', message: error.message } }
      }
      if (error instanceof MarketKeysError) {
        return { error: { code: error.code, message: error.message } }
      }
      return { error: { code: 'internal', message: (error as Error)?.message ?? String(error) } }
    }
  }

  /** The settings changed: devices hear the host's part when it is not what they last heard. */
  settingsChanged(file: SettingsFile): void {
    const part = this.part(file)
    const sent = JSON.stringify(part)
    if (sent === this.sentSettings) return
    this.sentSettings = sent
    this.deps.send({ type: 'settings.changed', settings: part }, null)
  }

  /** Remote access changed: devices hear its status when it is not what they last heard. */
  remoteChanged(status: RemoteStatus): void {
    const sent = JSON.stringify(status)
    if (sent === this.sentRemote) return
    this.sentRemote = sent
    this.deps.send({ type: 'remote.changed', status }, null)
  }

  themesChanged(themes: HostThemes): void {
    this.deps.send({ type: 'themes.changed', themes }, null)
  }

  /** What needs the user, which the devices notify about as the host's own window does. */
  attention(message: Extract<HostToMain, { type: 'host:attention' }>): void {
    const { title, body } = message
    let attention: HostAttention
    if (message.kind === 'routine-paused') {
      attention = { kind: message.kind, agentId: message.agentId, title, body }
    } else if (message.kind === 'plan-limit') {
      const { agentId, level, key, usedPercent, sessionId } = message
      attention = {
        kind: message.kind,
        agentId,
        level,
        key,
        usedPercent,
        title,
        body,
        ...(sessionId ? { sessionId } : {}),
      }
    } else if ('taskId' in message) {
      attention = { kind: message.kind, taskId: message.taskId, title, body }
    } else {
      attention = {
        kind: message.kind,
        sessionId: message.sessionId,
        title,
        body,
        ...(message.allowOnce ? { allowOnce: message.allowOnce } : {}),
      }
    }
    this.deps.send({ type: 'attention', attention }, null)
  }

  /** An install's answer, telling the device to show the theme when its install showed it. */
  private answered<R extends { status: string; id?: string }>(
    result: R,
  ): R | (R & { show: boolean }) {
    if (result.status !== 'installed' || result.id === undefined) return result
    return { ...result, show: this.shown.delete(result.id) }
  }

  private hostPart(): HostAdminResult<'settings.get'> {
    return this.part(this.deps.settings.get())
  }

  private part(file: SettingsFile): HostAdminResult<'settings.get'> {
    const part = hostSettingsPart(file)
    // The file keeps the desktop app's default, which a host that always serves never reads.
    if (this.deps.remoteAlwaysOn) part.remote.enabled = true
    return part
  }

  private async run(
    _deviceId: string,
    method: HostAdminMethod,
    params: unknown,
    atThisComputer: boolean,
  ): Promise<unknown> {
    const { settings, agentFolders, platform, remote } = this.deps
    switch (method) {
      case 'settings.get':
        return this.hostPart()
      case 'settings.update': {
        const { patch } = fields(params)
        const { client } = splitSettingsPatch(fields(patch) as SettingsPatch)
        if (client) {
          const keys = Object.keys(client).join(', ')
          throw invalid(`A device keeps these settings itself, not the host: ${keys}`)
        }
        if (this.deps.remoteAlwaysOn && (patch as SettingsPatch).remote?.enabled === false) {
          throw invalid(t('hostAdmin.remoteAlwaysOn'))
        }
        if (!atThisComputer) {
          const ownerOnly = ownerOnlySetting(patch as SettingsPatch)
          if (ownerOnly) {
            throw invalid(
              `A device cannot change ${ownerOnly}; its owner changes it on that computer`,
            )
          }
          // The relay is how devices reach a host that always serves, so none of them ends it.
          if (this.deps.remoteAlwaysOn && (patch as SettingsPatch).remote?.relay === false) {
            throw invalid('A device cannot turn the relay off; its owner does on that computer')
          }
          if (
            !settings.get().remote.terminal &&
            modifiesStdioMcp(settings.get().marketplace.mcp, patch as SettingsPatch)
          ) {
            throw forbidden(
              'A device cannot add or modify stdio MCP servers while remote terminal access is off',
            )
          }
        }
        settings.update(patch)
        return this.hostPart()
      }
      case 'settings.addAgent': {
        const { harnessId, name, folder } = fields(params)
        if (folder === null) return agentFolders.add(harnessId, name, null)
        const typed = typedPath(folder, 'folder', platform)
        if (!(await isDirectory(typed))) throw invalid(t('hostAdmin.notFolder', { path: typed }))
        // As the dialog's folder is, once the host has checked it.
        agentFolders.remember(typed)
        return agentFolders.add(harnessId, name, typed)
      }
      case 'settings.renameAgent': {
        const { agentId, name } = fields(params)
        agentFolders.rename(agentId, name)
        return null
      }
      case 'settings.setAgentColor': {
        const { agentId, color } = fields(params)
        settings.colorAgent(agentId, color)
        return null
      }
      case 'settings.removeAgent': {
        const { agentId, trash } = fields(params)
        await agentFolders.remove(agentId, trash)
        return null
      }
      case 'settings.setAgentBinary': {
        if (!atThisComputer && !settings.get().remote.terminal) {
          throw forbidden(
            'A device cannot change agent binaries while remote terminal access is off',
          )
        }
        const { harnessId, path: file } = fields(params)
        if (!isHarnessId(harnessId)) throw invalid(`Unknown harness "${String(harnessId)}"`)
        const program = await runnableProgram(typedPath(file, 'path', platform))
        settings.setAgentBinary(harnessId, program)
        return this.hostPart()
      }
      case 'settings.setShellPath': {
        if (!atThisComputer && !settings.get().remote.terminal) {
          throw forbidden(
            'A device cannot change the shell path while remote terminal access is off',
          )
        }
        const { path: file } = fields(params)
        settings.setShellPath(await runnableProgram(typedPath(file, 'path', platform)))
        return this.hostPart()
      }
      case 'marketplace.setKeys':
        return this.deps.marketKeys.set(fields(params).patch)
      case 'marketplace.setAgentEnv': {
        if (!atThisComputer && !settings.get().remote.terminal) {
          throw forbidden(
            'A device cannot change agent environment variables while remote terminal access is off',
          )
        }
        const { agentId, variable, value } = fields(params)
        if (
          typeof agentId !== 'string' ||
          typeof variable !== 'string' ||
          (value !== null && typeof value !== 'string')
        ) {
          throw invalid('The agent environment key request is invalid')
        }
        return this.deps.marketKeys.setAgentEnv(agentId, variable, value)
      }
      case 'remote.status':
        return this.deps.remoteStatus()
      case 'remote.renameDevice': {
        const { id, name } = fields(params)
        return (await remote.renameDevice(deviceIdArg(id), deviceName(name))) ? null : 'not_renamed'
      }
      case 'remote.removeDevice':
        return (await remote.removeDevice(deviceIdArg(fields(params).id))) ? null : 'not_removed'
      case 'remote.activity':
        return remote.activity(deviceIdArg(fields(params).id))
      case 'remote.reset':
        await remote.reset()
        return null
      case 'remote.retryRelay':
        remote.retryRelay()
        return null
      case 'host.info':
        return this.deps.info()
      case 'host.restart': {
        const target = fields(params).process
        if (target !== 'agent' && target !== 'terminal') {
          throw invalid('"process" must be agent or terminal')
        }
        this.deps.restart(target)
        return null
      }
      case 'themes.get':
        await this.deps.themes.refresh()
        return this.deps.themes.hostThemes()
      case 'themes.add': {
        const { file, text } = fields(params)
        if (
          typeof file !== 'string' ||
          file.length === 0 ||
          file.length > FILE_NAME_CHARS ||
          file.includes('\0')
        ) {
          throw invalid(`"file" must be a name of 1 to ${FILE_NAME_CHARS} characters`)
        }
        if (typeof text !== 'string') throw invalid('"text" must be a theme file\'s text')
        return this.answered(
          await this.deps.themes.add(file, checkThemeText(text), this.showOnDevice),
        )
      }
      case 'themes.replace':
        return this.answered(await this.deps.themes.replace(fields(params).token))
      case 'themes.remove':
        await this.deps.themes.remove(fields(params).id)
        return null
      case 'themes.path':
        return this.deps.themes.fileOf(fields(params).id)
      case 'host.report': {
        if (!this.deps.report) throw new AdminError('unavailable', t('hostAdmin.noReports'))
        let request: ReportRequest
        try {
          request = parseReportRequest(fields(params).request)
        } catch (error) {
          throw invalid((error as Error).message)
        }
        return this.deps.report(request)
      }
      case 'host.submitReport': {
        if (!this.deps.submitReport) throw new AdminError('unavailable', t('hostAdmin.noReports'))
        const { ref, allowAnonymous } = fields(params)
        if (typeof ref !== 'string' || ref.length === 0 || ref.length > 128) {
          throw invalid('ref must be a non-empty string')
        }
        if (allowAnonymous !== undefined && typeof allowAnonymous !== 'boolean') {
          throw invalid('allowAnonymous must be a boolean')
        }
        return this.deps.submitReport(
          ref,
          allowAnonymous !== undefined ? { allowAnonymous } : undefined,
        )
      }
    }
  }
}
