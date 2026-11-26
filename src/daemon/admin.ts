// The daemon's answers to its owner's devices beyond their sessions, as main's, from its own
// settings, hosts and themes folder. It publishes no artifacts, captures no previews and is not
// updated from Settings, and every change of the settings reaches the hosts that read them.

import { mkdir, rename } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { AGENTS_FOLDER, SARTO_HOME_FOLDER } from '@shared/storage'
import { BUILTIN_THEME_ID } from '@shared/themes'
import { AgentFolders } from '../core/agent-folders'
import { AdminError, HostAdmin, type HostAdminDeps } from '../core/host-admin'
import { t } from '../core/i18n'
import type { SettingsStore } from '../core/settings'
import { nodeSystemNameForRun } from '../core/system-name'
import { readThemeFolder, ThemeStore } from '../core/themes'
import { ControlError } from './control'
import type { Hosts } from './hosts'

/** What of the hosts the owner's calls and the settings reach. */
export type DaemonHosts = Pick<
  Hosts,
  | 'remoteAccess'
  | 'onRemoteChanged'
  | 'renameDevice'
  | 'removeDevice'
  | 'activity'
  | 'resetRemote'
  | 'retryRelay'
  | 'restart'
  | 'adminEvent'
  | 'settingsChanged'
  | 'onAttention'
>

export interface DaemonAdminOptions {
  dataPath: string
  version: string
  settings: SettingsStore
  hosts: DaemonHosts
  /** The home folder Sarto keeps its agent folders under; the system's unless a test picks one. */
  home?: string
  /** A problem report's bundle for the owner's device. */
  report?: HostAdminDeps['report']
  /** Submits a shelved problem report using this daemon's cloud account. */
  submitReport?: HostAdminDeps['submitReport']
  marketKeys: HostAdminDeps['marketKeys']
  onThemesChanged?: () => void
  /** A device was removed from the host by hand, here or from one of its devices. */
  onDeviceRemoved?: (id: string) => Promise<void>
}

/** A server has no trash, so a folder Sarto made moves into one of the daemon's own. */
async function setAside(folder: string, into: string): Promise<void> {
  await mkdir(into, { recursive: true, mode: 0o700 })
  await rename(folder, path.join(into, `${path.basename(folder)}-${Date.now()}`))
}

export interface DaemonAdminHandle {
  admin: HostAdmin
  themes: ThemeStore
  agentFolders: AgentFolders
}

/** Answers the owner's devices, and passes every change of the settings to the hosts. */
export async function startDaemonAdmin({
  dataPath,
  version,
  settings,
  hosts,
  home = os.homedir(),
  report,
  submitReport,
  marketKeys,
  onThemesChanged,
  onDeviceRemoved,
}: DaemonAdminOptions): Promise<DaemonAdminHandle> {
  const themesDir = path.join(dataPath, 'themes')
  let admin: HostAdmin | null = null
  const themes = new ThemeStore(await readThemeFolder(themesDir), BUILTIN_THEME_ID, {
    dir: themesDir,
    // The daemon has no window to show a theme in; each device shows the one it chose.
    select: () => {},
    changed: () => {
      admin?.themesChanged(themes.hostThemes())
      onThemesChanged?.()
    },
  })
  const removed = path.join(dataPath, 'removed-agent-config')
  const agentFolders = new AgentFolders(
    settings,
    path.join(home, SARTO_HOME_FOLDER, AGENTS_FOLDER),
    (folder) => setAside(folder, removed),
  )
  admin = new HostAdmin({
    settings,
    agentFolders,
    platform: process.platform,
    remote: {
      renameDevice: async (id, name) => hosts.renameDevice(id, name),
      removeDevice: async (id) => {
        try {
          await hosts.removeDevice(id)
          await onDeviceRemoved?.(id)
          return true
        } catch (error) {
          if (error instanceof ControlError) return false
          throw error
        }
      },
      activity: (id) => hosts.activity(id),
      reset: async () => {
        try {
          await hosts.resetRemote()
        } catch (error) {
          if (error instanceof ControlError) {
            throw new AdminError('unavailable', t('remoteHost.resetFailed'))
          }
          throw error
        }
      },
      retryRelay: () => hosts.retryRelay(),
    },
    remoteStatus: () => hosts.remoteAccess(),
    info: async () => ({
      name: 'Sarto',
      version,
      system: await nodeSystemNameForRun(),
      userDataPath: dataPath,
      isPackaged: true,
      remoteSwitch: false,
      remoteReset: true,
      pinnedModels: true,
    }),
    restart: (which) => void hosts.restart(which),
    themes,
    marketKeys,
    remoteAlwaysOn: true,
    report,
    submitReport,
    send: (event, deviceId) => hosts.adminEvent(event, deviceId),
  })
  settings.onChange((next, changed) => {
    hosts.settingsChanged(changed)
    admin.settingsChanged(next)
    // The remote host reports no change of the host's name, which the settings hold.
    if (changed.has('remote')) admin.remoteChanged(hosts.remoteAccess())
  })
  hosts.onRemoteChanged(() => admin.remoteChanged(hosts.remoteAccess()))
  hosts.onAttention((message) => admin.attention(message))
  return { admin, themes, agentFolders }
}
