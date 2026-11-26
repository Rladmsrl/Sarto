// What an owner's device asks of a host beyond its sessions: the host's part of the settings and the
// host-level actions of the Settings page. The remote host hands each call to its parent, the
// desktop app's main process or the daemon, which runs it with the checks of the local page.

import type { HostToMain } from '../host-control'
import type { MarketKeysPatch, MarketKeyState } from '../marketplace'
import {
  DEFAULT_SETTINGS,
  type AgentColor,
  type SettingsFile,
  type SettingsPatch,
} from '../settings'
import type { ReportFileInfo, ReportRequest, ReportSubmitResult } from '../report'
import type { AgentId, HarnessId } from '../thread'
import type { InstalledTheme, ThemeInstallResult, ThemeLoadFailure } from '../themes'
import type { DeviceActivity } from './activity'
import type { RemoteStatus } from './status'

export interface AppInfo {
  name: string
  version: string
  /** The system and its version, then the architecture, as a bug report names them. */
  system: string
  userDataPath: string
  /** The folder of the log files; absent from hosts older than it. */
  logsPath?: string
  isPackaged: boolean
}

/**
 * The settings that take effect on the host, by section: all of it, or the keys in it. A client
 * keeps the rest, which only changes the window showing them.
 */
export const HOST_SETTING_KEYS = {
  general: ['sessionTitles', 'promptSuggestions', 'agentPasswords', 'lightModel'],
  agents: 'all',
  addedAgents: 'all',
  disabledAgents: 'all',
  proxy: 'all',
  terminal: ['shellPath'],
  git: 'all',
  mcp: 'all',
  marketplace: 'all',
  startModes: 'all',
  idleSessions: 'all',
  usage: ['fromComputer'],
  remote: 'all',
} as const satisfies Partial<Record<keyof SettingsFile, 'all' | readonly string[]>>

/**
 * What of `remote` only the owner at the host's own computer changes, never a device: whether
 * devices may use its terminals, which run any command, and its Claude Code and sign-in.
 */
export const OWNER_ONLY_REMOTE_KEYS = [
  'terminal',
  'claude',
] as const satisfies readonly (keyof SettingsFile['remote'])[]

/** The setting of a patch that only the owner at the host's computer changes, or null for none. */
export function ownerOnlySetting(patch: SettingsPatch): string | null {
  const remote: unknown = patch.remote
  if (typeof remote !== 'object' || remote === null) return null
  const key = OWNER_ONLY_REMOTE_KEYS.find((name) => Object.hasOwn(remote, name))
  return key ? `remote.${key}` : null
}

/** The host's part of the settings file. */
export interface HostSettingsPart {
  general: Pick<
    SettingsFile['general'],
    'sessionTitles' | 'promptSuggestions' | 'agentPasswords' | 'lightModel'
  >
  agents: SettingsFile['agents']
  addedAgents: SettingsFile['addedAgents']
  disabledAgents: SettingsFile['disabledAgents']
  proxy: SettingsFile['proxy']
  terminal: Pick<SettingsFile['terminal'], 'shellPath'>
  git: SettingsFile['git']
  mcp: SettingsFile['mcp']
  marketplace: SettingsFile['marketplace']
  startModes: SettingsFile['startModes']
  idleSessions: SettingsFile['idleSessions']
  usage: Pick<SettingsFile['usage'], 'fromComputer'>
  remote: SettingsFile['remote']
}

type Keys = 'all' | readonly string[]

function hostKeys(section: string): Keys | undefined {
  return (HOST_SETTING_KEYS as Record<string, Keys>)[section]
}

function pick(value: object, keys: readonly string[], kept: boolean): Record<string, unknown> {
  return Object.fromEntries(Object.entries(value).filter(([key]) => keys.includes(key) === kept))
}

/** The host's part of a settings file. */
export function hostSettingsPart(file: SettingsFile): HostSettingsPart {
  const part: Record<string, unknown> = {}
  for (const [section, keys] of Object.entries(HOST_SETTING_KEYS) as [keyof SettingsFile, Keys][]) {
    const value = file[section]
    part[section] = keys === 'all' ? structuredClone(value) : pick(value as object, keys, true)
  }
  return part as unknown as HostSettingsPart
}

/** A client's settings file with the host's part in place of its own. */
export function withHostSettings(file: SettingsFile, part: HostSettingsPart): SettingsFile {
  const next = structuredClone(file) as unknown as Record<string, unknown>
  for (const [section, keys] of Object.entries(HOST_SETTING_KEYS) as [string, Keys][]) {
    const value = (part as unknown as Record<string, unknown>)[section]
    if (keys === 'all') {
      // A host older than a section has none, and works as its default.
      const fallback = DEFAULT_SETTINGS[section as keyof SettingsFile]
      next[section] = structuredClone(value === undefined ? fallback : value)
      continue
    }
    // A key the host's part leaves out is unset there, as an unpicked shell is.
    const own = pick(next[section] as object, keys, false)
    next[section] = { ...own, ...(value as object) }
  }
  return next as unknown as SettingsFile
}

/** A patch split into what the host keeps and what the client keeps; null for an empty side. */
export function splitSettingsPatch(patch: SettingsPatch): {
  host: SettingsPatch | null
  client: SettingsPatch | null
} {
  const host: Record<string, unknown> = {}
  const client: Record<string, unknown> = {}
  for (const [section, value] of Object.entries(patch) as [string, unknown][]) {
    if (value === undefined) continue
    const keys = hostKeys(section)
    if (keys === 'all') host[section] = value
    else if (!keys) client[section] = value
    else {
      const kept = pick(value as object, keys, true)
      const rest = pick(value as object, keys, false)
      if (Object.keys(kept).length > 0) host[section] = kept
      if (Object.keys(rest).length > 0) client[section] = rest
    }
  }
  return {
    host: Object.keys(host).length > 0 ? (host as SettingsPatch) : null,
    client: Object.keys(client).length > 0 ? (client as SettingsPatch) : null,
  }
}

/** A bundle built for an owner's device, or why there is none. */
export type DeviceReport =
  /** `ref`: the bundle as the host keeps it a while. */
  | {
      ok: true
      zip: string
      files: ReportFileInfo[]
      size: number
      ref: string
      redactionCount?: number
    }
  | { ok: false; reason: 'too_large' | 'failed' }

/** The host's own facts, and what it can do beyond its sessions. */
export interface HostInfo extends AppInfo {
  /**
   * Turning remote access off, which the desktop app allows; the daemon is reached only through
   * it, so it always serves it.
   */
  remoteSwitch: boolean
  /** Resetting remote access to a new identity, which both hosts have; false from older daemons. */
  remoteReset: boolean
  /**
   * Setting an agent's pinned models in order, with `agents.setPinnedModels`; absent from hosts
   * before it.
   */
  pinnedModels?: boolean
}

/** The host's themes folder: the themes it holds, and why the others fail. */
export interface HostThemes {
  installed: InstalledTheme[]
  failed: { id: string; failure: ThemeLoadFailure }[]
}

/**
 * An install's answer to a device: whether the device now shows the theme, as a window does after
 * installing one, and not after updating it from the catalog.
 */
export type DeviceThemeInstall<R> = R extends { status: 'installed' } ? R & { show: boolean } : R

type AttentionMessage = Extract<HostToMain, { type: 'host:attention' }>

/** What the host would notify its own window about, sent to its owner's devices. */
export type HostAttention = AttentionMessage extends infer M
  ? M extends unknown
    ? Omit<M, 'type'>
    : never
  : never

/** The calls an owner's device makes of the host's parent, by method. */
export interface HostAdminContract {
  'settings.get': { params: undefined; result: HostSettingsPart }
  /** Refused unless every key it sets is the host's. */
  'settings.update': { params: { patch: SettingsPatch }; result: HostSettingsPart }
  /** Adds an agent to Claude Code or Codex, in a folder on the host or a new one. */
  'settings.addAgent': {
    params: { harnessId: HarnessId; name: string; folder: string | null }
    result: AgentId
  }
  'settings.renameAgent': { params: { agentId: AgentId; name: string }; result: null }
  'settings.setAgentColor': { params: { agentId: AgentId; color: AgentColor }; result: null }
  'settings.removeAgent': { params: { agentId: AgentId; trash: boolean }; result: null }
  /** A program on the host for the harness; the host checks it is a file it may run. */
  'settings.setAgentBinary': {
    params: { harnessId: HarnessId; path: string }
    result: HostSettingsPart
  }
  /** A shell on the host; the host checks it is a file it may run. */
  'settings.setShellPath': { params: { path: string }; result: HostSettingsPart }
  /**
   * Fills or clears inputs of a server in the host's `marketplace.mcp`, as `marketplace.setKeys`
   * of the window does; answers which inputs are set, never their values.
   */
  'marketplace.setKeys': { params: { patch: MarketKeysPatch }; result: MarketKeyState }
  'marketplace.setAgentEnv': {
    params: { agentId: string; variable: string; value: string | null }
    result: void
  }
  'remote.status': { params: undefined; result: RemoteStatus }
  'remote.renameDevice': { params: { id: string; name: string }; result: 'not_renamed' | null }
  'remote.removeDevice': { params: { id: string }; result: 'not_removed' | null }
  'remote.activity': { params: { id: string }; result: DeviceActivity[] }
  'remote.reset': { params: undefined; result: null }
  'remote.retryRelay': { params: undefined; result: null }
  'host.info': { params: undefined; result: HostInfo }
  'host.restart': { params: { process: 'agent' | 'terminal' }; result: null }
  'themes.get': { params: undefined; result: HostThemes }
  /** Installs a theme file the device read, named `file`, or names the theme it would replace. */
  'themes.add': {
    params: { file: string; text: string }
    result: DeviceThemeInstall<ThemeInstallResult>
  }
  'themes.replace': { params: { token: string }; result: DeviceThemeInstall<ThemeInstallResult> }
  'themes.remove': { params: { id: string }; result: null }
  /** Where an installed theme's file is on the host. */
  'themes.path': { params: { id: string }; result: string }
  /** A problem report's bundle, which the host builds with its own logs: the zip in base64. */
  'host.report': { params: { request: ReportRequest }; result: DeviceReport }
  /** Submits a shelved bundle built earlier by `host.report` using this host's cloud account. */
  'host.submitReport': {
    params: { ref: string; allowAnonymous?: boolean }
    result: ReportSubmitResult
  }
}

export type HostAdminMethod = keyof HostAdminContract
export type HostAdminParams<M extends HostAdminMethod> = HostAdminContract[M]['params']
export type HostAdminResult<M extends HostAdminMethod> = HostAdminContract[M]['result']

const METHODS: Record<HostAdminMethod, true> = {
  'settings.get': true,
  'settings.update': true,
  'settings.addAgent': true,
  'settings.renameAgent': true,
  'settings.setAgentColor': true,
  'settings.removeAgent': true,
  'settings.setAgentBinary': true,
  'settings.setShellPath': true,
  'marketplace.setKeys': true,
  'marketplace.setAgentEnv': true,
  'remote.status': true,
  'remote.renameDevice': true,
  'remote.removeDevice': true,
  'remote.activity': true,
  'remote.reset': true,
  'remote.retryRelay': true,
  'host.info': true,
  'host.restart': true,
  'themes.get': true,
  'themes.add': true,
  'themes.replace': true,
  'themes.remove': true,
  'themes.path': true,
  'host.report': true,
  'host.submitReport': true,
}

export function isHostAdminMethod(method: string): method is HostAdminMethod {
  return Object.hasOwn(METHODS, method)
}

/**
 * What the host tells its owner's devices as it changes, as `event` messages beside the agent
 * host's. A pairing's progress goes only to the device that opened the code.
 */
export type HostAdminEvent =
  | { type: 'settings.changed'; settings: HostSettingsPart }
  | { type: 'remote.changed'; status: RemoteStatus }
  | { type: 'themes.changed'; themes: HostThemes }
  | { type: 'attention'; attention: HostAttention }

const EVENTS: Record<HostAdminEvent['type'], true> = {
  'settings.changed': true,
  'remote.changed': true,
  'themes.changed': true,
  attention: true,
}

export function isHostAdminEvent(event: { type?: unknown }): event is HostAdminEvent {
  return typeof event.type === 'string' && Object.hasOwn(EVENTS, event.type)
}

/** What `paths.complete` lists: the entries of a folder on the host that start as typed. */
export interface PathCompletion {
  /** The folder the typed path's last part is looked up in, absolute and normalized. */
  folder: string
  /** `repo`: a folder that holds a Git repository; hosts before it was added leave it out. */
  entries: { name: string; kind: 'folder' | 'file'; executable: boolean; repo?: boolean }[]
  /** Whether the typed path itself exists, and what it is. */
  exact: { kind: 'folder' | 'file'; executable: boolean } | null
}
