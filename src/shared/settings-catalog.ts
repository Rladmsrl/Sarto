// Every row of the Settings page as data: where it is, the catalog keys of its words, how its value
// reads and changes, and what agents may do with it. The page draws its rows' words from here, and
// Sarto's settings tools read the same entries, so a row added to the page is one agents see.

import { isFullAccessMode } from './agents'
import { takesAutoCompact } from './auto-compact'
import { IDLE_RELEASE_MODES } from './idle-release'
import type { Platform } from './platform'
import { type SettingsFile, type SettingsPatch } from './settings'
import type { AgentId, HarnessId } from './thread'

export const SETTINGS_SECTIONS = [
  'general',
  'appearance',
  'agents',
  'harnesses',
  'memory',
  'terminal',
  'git',
  'notifications',
  'account',
  'usage',
  'archived',
  'sharing',
  'remote',
  'hosts',
  'browser',
  'devices',
  'computer-use',
  'advanced',
  'about',
] as const
export type SettingsSection = (typeof SETTINGS_SECTIONS)[number]

/**
 * What a row's value is: one the tools may change (a switch, a choice, a number, a text), one they
 * only read (a path, an account's facts), a secret they read only as set or not, a list they count,
 * or an action the user takes on the page.
 */
export type SettingKind =
  'switch' | 'choice' | 'number' | 'text' | 'path' | 'secret' | 'list' | 'info' | 'action'

/** `read`: agents never change it. `change`: as the session's mode allows. `ask`: always asks. */
export type SettingAccess = 'read' | 'change' | 'ask'

/** `host`: on every host. */
export type SettingPart = 'host'

export type SettingScalar = string | number | boolean | null

/** A key of the settings catalog, or of another namespace as `usage:key`. */
export type TextKey = string

/** A text that differs by system, as Dock and taskbar do; `other` for the rest. */
export type PlatformText = { mac?: TextKey; windows?: TextKey; linux?: TextKey; other: TextKey }

export type EntryText = TextKey | PlatformText

/** How a choice reads: a catalog key, words as they are, or words that differ by system. */
export type OptionLabel =
  | { key: TextKey; params?: Record<string, string> }
  | { text: string }
  | { platform: Partial<Record<'mac' | 'windows' | 'linux', string>> & { other: string } }

export interface SettingOption {
  value: SettingScalar
  label: OptionLabel
}

/** What the host knows when it lists its entries: its system, whether it draws a window. */
export interface CatalogContext {
  platform: Platform
  /** The agents of the host, for the rows of each agent's page and the default agent's choice. */
  agents: readonly { id: AgentId; name: string; harnessId: HarnessId }[]
  /** The harnesses of the host, for the rows of each harness's page. */
  harnesses: readonly { id: HarnessId; name: string }[]
  /** The modes each agent's new sessions may start in, by agent; absent before it was used. */
  modes: Readonly<Partial<Record<AgentId, readonly { value: string; name: string }[]>>>
}

export interface CatalogEntry {
  section: SettingsSection
  /** The row's id on its page, which a search result scrolls to and flashes. */
  row: string
  /** The label of the group the row shows under, when it has one. */
  group?: TextKey
  name: EntryText
  description?: EntryText
  keywords?: TextKey | readonly TextKey[]
  part: SettingPart
  kind: SettingKind
  access?: SettingAccess
  /** For an always-asking row: what changing it opens up, said on the card. */
  warning?: TextKey
  /** Values for its words' placeholders, such as a shortcut's keys, on the host's system. */
  params?(platform: Platform): Record<string, string>
  /** A row of each agent's or harness's own page, named by its id. */
  item?: 'agent' | 'harness'
  /** Whether the host has the row; always when absent. */
  on?(ctx: CatalogContext, item: string | null): boolean
  options?:
    readonly SettingOption[] | ((ctx: CatalogContext, item: string | null) => SettingOption[])
  /** A number's bounds and the unit it reads in. */
  min?: number
  max?: number
  /** A text's length at most. */
  chars?: number
  check?(value: string): boolean
  /** The value in the settings file; absent for what the host reads elsewhere, as a fact. */
  get?(file: SettingsFile, item: string | null): SettingScalar
  /** The patch that sets the value, for the kinds agents may change. */
  patch?(value: SettingScalar, file: SettingsFile, item: string | null): SettingsPatch
}

const ON_OFF: readonly SettingOption[] = [
  { value: true, label: { key: 'agentSettings.on' } },
  { value: false, label: { key: 'agentSettings.off' } },
]

function choices(
  values: readonly SettingScalar[],
  key: (value: string) => TextKey,
): SettingOption[] {
  return values.map((value) => ({ value, label: { key: key(String(value)) } }))
}

const isAgent = (ctx: CatalogContext, item: string | null): boolean =>
  ctx.agents.some((agent) => agent.id === item)
const isHarness = (ctx: CatalogContext, item: string | null): boolean =>
  ctx.harnesses.some((harness) => harness.id === item)

/** A switch of the file's own: true while the value is. */
function flag<S extends keyof SettingsPatch>(
  section: S,
  key: string,
  read: (file: SettingsFile) => boolean,
): Pick<CatalogEntry, 'kind' | 'options' | 'get' | 'patch'> {
  return {
    kind: 'switch',
    options: ON_OFF,
    get: (file) => read(file),
    patch: (value) => ({ [section]: { [key]: value === true } }) as SettingsPatch,
  }
}

function pick<S extends keyof SettingsPatch>(
  section: S,
  key: string,
  read: (file: SettingsFile) => SettingScalar,
  options: readonly SettingOption[],
): Pick<CatalogEntry, 'kind' | 'options' | 'get' | 'patch'> {
  return {
    kind: 'choice',
    options,
    get: (file) => read(file),
    patch: (value) => ({ [section]: { [key]: value } }) as SettingsPatch,
  }
}

const ENTRIES = {
  // ---- General
  'general.session-titles': {
    section: 'general',
    row: 'session-titles',
    group: 'general.groups.sessions',
    name: 'general.sessionTitles.name',
    description: 'general.sessionTitles.description',
    keywords: 'general.sessionTitles.keywords',
    part: 'host',
    access: 'change',
    ...flag('general', 'sessionTitles', (file) => file.general.sessionTitles),
  },
  'general.continue-after-limit': {
    section: 'general',
    row: 'continue-after-limit',
    group: 'general.groups.sessions',
    name: 'general.continueAfterLimit.name',
    description: 'general.continueAfterLimit.description',
    keywords: 'general.continueAfterLimit.keywords',
    part: 'host',
    access: 'change',
    ...flag('general', 'continueAfterLimit', (file) => file.general.continueAfterLimit),
  },
  'general.prompt-suggestions': {
    section: 'general',
    row: 'prompt-suggestions',
    group: 'general.groups.sessions',
    name: 'general.promptSuggestions.name',
    description: 'general.promptSuggestions.description',
    keywords: 'general.promptSuggestions.keywords',
    part: 'host',
    access: 'change',
    ...flag('general', 'promptSuggestions', (file) => file.general.promptSuggestions),
  },
  'general.agent-passwords': {
    section: 'general',
    row: 'agent-passwords',
    group: 'general.groups.sessions',
    name: 'general.agentPasswords.name',
    description: 'general.agentPasswords.description',
    keywords: 'general.agentPasswords.keywords',
    part: 'host',
    access: 'ask',
    warning: 'agentSettings.warning.passwords',
    ...flag('general', 'agentPasswords', (file) => file.general.agentPasswords),
  },
  'general.light-model': {
    section: 'general',
    row: 'light-model',
    group: 'general.groups.sessions',
    name: 'general.lightModel.name',
    description: 'general.lightModel.description',
    keywords: 'general.lightModel.keywords',
    part: 'host',
    kind: 'info',
  },

  // ---- Appearance

  // ---- Hosts
  // The web client's own page: the host that served it, and this browser's name there.

  // ---- Agents
  'agents.agents': {
    section: 'agents',
    row: 'agents',
    group: 'agents.groups.list',
    name: 'sections.agents',
    description: 'pages.agents',
    keywords: 'agents.keywords',
    part: 'host',
    kind: 'list',
  },
  'agents.add-agent': {
    section: 'agents',
    row: 'add-agent',
    group: 'agents.groups.list',
    name: 'agents.add.button',
    keywords: 'agents.add.keywords',
    part: 'host',
    kind: 'action',
  },
  'agents.account': {
    section: 'agents',
    row: 'account',
    name: 'agentSettings.agent.account',
    keywords: 'agents.keywords',
    part: 'host',
    kind: 'info',
    item: 'agent',
    on: isAgent,
  },
  'agents.enabled': {
    section: 'agents',
    row: 'enabled',
    name: 'agents.enable.name',
    description: 'agents.enable.on',
    part: 'host',
    access: 'ask',
    warning: 'agentSettings.warning.agentOff',
    item: 'agent',
    on: isAgent,
    kind: 'switch',
    options: ON_OFF,
    get: (file, item) => !file.disabledAgents.includes(item as AgentId),
    patch: (value, file, item) => {
      const others = file.disabledAgents.filter((id) => id !== item)
      return { disabledAgents: value === true ? others : [...others, item as AgentId] }
    },
  },
  'agents.start-mode': {
    section: 'agents',
    row: 'start-mode',
    name: 'agents.startMode.name',
    description: 'agents.startMode.description',
    part: 'host',
    access: 'ask',
    warning: 'agentSettings.warning.startMode',
    item: 'agent',
    on: (ctx, item) => isAgent(ctx, item) && ctx.modes[item as AgentId] !== undefined,
    kind: 'choice',
    options: (ctx, item) => [
      { value: null, label: { key: 'agentSettings.agent.followAgent' } },
      ...(ctx.modes[item as AgentId] ?? []).map((mode) => ({
        value: mode.value,
        label: { text: mode.name },
      })),
    ],
    get: (file, item) => file.startModes[item as AgentId] ?? null,
    patch: (value, _, item) => ({ startModes: { [item as AgentId]: value as string | null } }),
  },
  'agents.sarto-mcp': {
    section: 'agents',
    row: 'mcp-servers',
    name: 'agentSettings.agent.sartoMcp',
    description: 'agents.mcpServers.description',
    part: 'host',
    access: 'ask',
    warning: 'agentSettings.warning.sartoMcp',
    item: 'agent',
    on: isAgent,
    kind: 'switch',
    options: ON_OFF,
    get: (file, item) => !file.mcp.sarto.off.includes(item as AgentId),
    patch: (value, file, item) => {
      const others = file.mcp.sarto.off.filter((id) => id !== item)
      return { mcp: { sarto: { off: value === true ? others : [...others, item as AgentId] } } }
    },
  },
  'agents.api-key': {
    section: 'agents',
    row: 'api-key',
    name: 'agents.key.row',
    part: 'host',
    kind: 'secret',
    item: 'agent',
    on: isAgent,
  },
  'agents.favorite-models': {
    section: 'agents',
    row: 'favorite-models',
    name: 'agents.favorites.name',
    description: 'agents.favorites.description',
    keywords: 'agents.favorites.keywords',
    part: 'host',
    kind: 'list',
    item: 'agent',
    on: isAgent,
  },
  'agents.auto-compact': {
    section: 'agents',
    row: 'auto-compact',
    name: 'agents.autoCompact.name',
    description: 'agents.autoCompact.catalog',
    part: 'host',
    kind: 'info',
    item: 'agent',
    on: (ctx, item) => ctx.agents.some((a) => a.id === item && takesAutoCompact(a.id)),
  },
  'agents.prompt-cache': {
    section: 'agents',
    row: 'prompt-cache',
    name: 'agents.claudeSettings.cache.name',
    description: 'agents.claudeSettings.cache.description',
    part: 'host',
    kind: 'info',
    item: 'agent',
    on: (ctx, item) => ctx.agents.some((a) => a.id === item && a.harnessId === 'claude-code'),
  },
  'agents.config-folder': {
    section: 'agents',
    row: 'config',
    name: 'agents.config.folder',
    part: 'host',
    kind: 'path',
    item: 'agent',
    on: isAgent,
    get: (file, item) =>
      file.addedAgents.find((agent) => agent.id === item)?.configDir ??
      file.agents[item as HarnessId]?.configDir ??
      null,
  },
  'agents.remove': {
    section: 'agents',
    row: 'remove',
    name: 'agents.remove.name',
    description: 'agents.remove.description',
    part: 'host',
    kind: 'action',
    item: 'agent',
    on: isAgent,
  },
  'agents.idle-release': {
    section: 'agents',
    row: 'idle-release',
    group: 'agents.idle.group',
    name: 'agents.idle.release.name',
    description: 'agents.idle.release.description',
    keywords: 'agents.idle.keywords',
    part: 'host',
    access: 'change',
    ...pick(
      'idleSessions',
      'release',
      (file) => file.idleSessions.release,
      choices(IDLE_RELEASE_MODES, (mode) => `agents.idle.release.${mode}`),
    ),
  },
  'agents.idle-fallback': {
    section: 'agents',
    row: 'idle-release',
    group: 'agents.idle.group',
    name: 'agents.idle.fallback.title',
    keywords: 'agents.idle.keywords',
    part: 'host',
    kind: 'info',
    on: () => false,
  },

  // ---- Harnesses
  'harnesses.installed': {
    section: 'harnesses',
    row: 'installed',
    group: 'harnesses.groups.installed',
    name: 'sections.harnesses',
    description: 'pages.harnesses',
    keywords: 'harnesses.keywords',
    part: 'host',
    kind: 'list',
  },
  'harnesses.environment': {
    section: 'harnesses',
    row: 'environment',
    name: 'agents.environment.reload',
    keywords: 'agents.environment.keywords',
    part: 'host',
    kind: 'action',
  },
  'harnesses.program': {
    section: 'harnesses',
    row: 'program',
    name: 'agentSettings.harness.program',
    part: 'host',
    kind: 'path',
    item: 'harness',
    on: isHarness,
    get: (file, item) => file.agents[item as HarnessId]?.binaryPath ?? null,
  },
  'harnesses.auto-update': {
    section: 'harnesses',
    row: 'auto-update',
    name: 'harnesses.autoUpdate.name',
    description: 'harnesses.autoUpdate.on',
    part: 'host',
    access: 'change',
    item: 'harness',
    on: isHarness,
    kind: 'switch',
    options: ON_OFF,
    get: (file, item) => file.agents[item as HarnessId]?.autoUpdate !== false,
    patch: (value, _, item) => ({
      agents: { [item as HarnessId]: { autoUpdate: value === true } },
    }),
  },
  'harnesses.install': {
    section: 'harnesses',
    row: 'install',
    name: 'agentSettings.harness.install',
    part: 'host',
    kind: 'action',
    item: 'harness',
    on: isHarness,
  },

  // ---- Memory
  'memory.enabled': {
    section: 'memory',
    row: 'enabled',
    name: 'memory.switch.name',
    description: 'memory.switch.on',
    keywords: ['memory.keywords', 'memory.switch.keywords'],
    part: 'host',
    kind: 'info',
  },
  'memory.entries': {
    section: 'memory',
    row: 'search',
    name: 'agentSettings.lists.memory',
    keywords: 'memory.keywords',
    part: 'host',
    kind: 'list',
  },

  // ---- Usage
  'usage.from-computer': {
    section: 'usage',
    row: 'from-computer',
    group: 'usage:settings.groups.sources',
    name: 'usage:settings.fromComputer.name',
    description: 'usage:settings.fromComputer.description',
    keywords: 'usage:settings.fromComputer.keywords',
    part: 'host',
    access: 'change',
    ...flag('usage', 'fromComputer', (file) => file.usage.fromComputer),
  },
  'usage.logs': {
    section: 'usage',
    row: 'from-computer',
    group: 'usage:settings.groups.logs',
    name: 'usage:settings.groups.logs',
    keywords: 'usage:settings.groups.logs',
    part: 'host',
    kind: 'list',
  },
  'usage.clear-record': {
    section: 'usage',
    row: 'clear-record',
    group: 'usage:settings.groups.danger',
    name: 'usage:settings.clear.name',
    description: 'usage:settings.clear.description',
    part: 'host',
    kind: 'action',
  },

  // ---- Git
  'git.git': {
    section: 'git',
    row: 'git',
    group: 'git.groups.tools',
    name: 'git.git.name',
    description: 'git.git.description',
    part: 'host',
    kind: 'info',
  },
  'git.gh': {
    section: 'git',
    row: 'gh',
    group: 'git.groups.tools',
    name: 'git.gh.name',
    description: 'git.gh.description',
    keywords: 'git.gh.keywords',
    part: 'host',
    kind: 'info',
  },
  'git.fetch': {
    section: 'git',
    row: 'fetch',
    group: 'git.groups.sync',
    name: 'git.fetch.name',
    description: 'git.fetch.description',
    part: 'host',
    access: 'change',
    ...flag('git', 'backgroundFetch', (file) => file.git.backgroundFetch),
  },
  'git.worktree-root': {
    section: 'git',
    row: 'worktree-root',
    group: 'git.groups.worktrees',
    name: 'git.worktreeRoot.name',
    description: 'git.worktreeRoot.description',
    keywords: 'git.worktreeRoot.keywords',
    part: 'host',
    kind: 'path',
    get: (file) => file.git.worktreeRoot,
  },

  // ---- Archived
  'archived.sessions': {
    section: 'archived',
    row: 'archived',
    group: 'archived.group',
    name: 'sections.archived',
    description: 'pages.archived',
    keywords: 'archived.keywords',
    part: 'host',
    kind: 'list',
  },

  // ---- Terminal
  'terminal.shell': {
    section: 'terminal',
    row: 'shell',
    group: 'terminal.groups.shell',
    name: 'terminal.shell.name',
    description: {
      windows: 'terminal.shell.descriptionWindows',
      other: 'terminal.shell.description',
    },
    part: 'host',
    kind: 'path',
    get: (file) => file.terminal.shellPath ?? null,
  },

  // ---- Remote access
  'remote.remote': {
    section: 'remote',
    row: 'remote',
    name: 'remote.switch',
    description: 'pages.remote',
    keywords: 'remote.keywords',
    part: 'host',
    access: 'ask',
    warning: 'agentSettings.warning.remote',
    ...flag('remote', 'enabled', (file) => file.remote.enabled),
  },
  'remote.host-name': {
    section: 'remote',
    row: 'host-name',
    name: 'remote.hostName.name',
    description: 'remote.hostName.description',
    part: 'host',
    access: 'change',
    kind: 'text',
    chars: 64,
    get: (file) => file.remote.name,
    patch: (value) => ({ remote: { name: value === '' || value === null ? null : String(value) } }),
  },
  'remote.devices': {
    section: 'remote',
    row: 'add-device',
    group: 'remote.devices.group',
    name: 'remote.devices.group',
    keywords: 'remote.keywords',
    part: 'host',
    kind: 'list',
  },
  'remote.add-device': {
    section: 'remote',
    row: 'add-device',
    group: 'remote.devices.group',
    name: 'remote.devices.add',
    keywords: 'remote.keywords',
    part: 'host',
    kind: 'action',
  },
  'remote.direct': {
    section: 'remote',
    row: 'direct',
    group: 'remote.direct.group',
    name: 'remote.direct.name',
    description: 'remote.direct.descriptionFree',
    keywords: 'remote.direct.keywords',
    part: 'host',
    access: 'ask',
    warning: 'agentSettings.warning.direct',
    kind: 'switch',
    options: ON_OFF,
    get: (file) => file.remote.direct.enabled,
    patch: (value) => ({ remote: { direct: { enabled: value === true } } }),
  },
  'remote.direct-port': {
    section: 'remote',
    row: 'direct-port',
    group: 'remote.direct.group',
    name: 'remote.direct.port.name',
    description: 'remote.direct.port.description',
    keywords: 'remote.direct.keywords',
    part: 'host',
    access: 'ask',
    warning: 'agentSettings.warning.direct',
    kind: 'number',
    min: 1024,
    max: 65535,
    get: (file) => file.remote.direct.port,
    patch: (value) => ({ remote: { direct: { port: Number(value) } } }),
  },
  'remote.direct-found': {
    section: 'remote',
    row: 'direct-found',
    group: 'remote.direct.group',
    name: 'remote.direct.found.name',
    description: 'remote.direct.found.description',
    keywords: 'remote.direct.keywords',
    part: 'host',
    kind: 'list',
  },
  'remote.direct-own': {
    section: 'remote',
    row: 'direct-own',
    group: 'remote.direct.group',
    name: 'remote.direct.own.name',
    description: 'remote.direct.own.description',
    keywords: 'remote.direct.keywords',
    part: 'host',
    kind: 'list',
    get: (file) => file.remote.direct.addresses.length,
  },
  'remote.terminal': {
    section: 'remote',
    row: 'terminal',
    group: 'remote.groups.permissions',
    name: 'remote.terminal.name',
    description: 'remote.terminal.description',
    keywords: 'remote.terminal.keywords',
    part: 'host',
    access: 'ask',
    warning: 'agentSettings.warning.terminal',
    ...flag('remote', 'terminal', (file) => file.remote.terminal),
  },
  'remote.discoverable': {
    section: 'remote',
    row: 'discoverable',
    group: 'remote.groups.permissions',
    name: 'remote.discoverable.name',
    description: 'remote.discoverable.description',
    keywords: 'remote.discoverable.keywords',
    part: 'host',
    access: 'ask',
    warning: 'agentSettings.warning.discoverable',
    ...flag('remote', 'discoverable', (file) => file.remote.discoverable),
  },
  'remote.relay': {
    section: 'remote',
    row: 'relay',
    group: 'remote.groups.advanced',
    name: 'remote.relay.name',
    description: 'remote.relay.description',
    keywords: 'remote.relay.keywords',
    part: 'host',
    access: 'ask',
    warning: 'agentSettings.warning.relay',
    ...flag('remote', 'relay', (file) => file.remote.relay),
  },
  'remote.reset': {
    section: 'remote',
    row: 'reset',
    group: 'remote.groups.danger',
    name: 'remote.reset.name',
    description: 'remote.reset.description',
    keywords: 'remote.reset.keywords',
    part: 'host',
    kind: 'action',
  },

  // ---- Advanced
  'advanced.proxy': {
    section: 'advanced',
    row: 'proxy',
    group: 'advanced.groups.network',
    name: 'advanced.proxy.name',
    description: 'advanced.proxy.description',
    keywords: 'advanced.proxy.keywords',
    part: 'host',
    access: 'ask',
    warning: 'agentSettings.warning.proxy',
    kind: 'text',
    chars: 2048,
    // A proxy with a password is set on the page, so none goes through an agent or its thread.
    check: (value) => value === '' || !hasCredentials(value),
    get: (file) => (file.proxy.mode === 'custom' ? withoutPassword(file.proxy.url) : ''),
    patch: (value, file) => {
      const url = typeof value === 'string' ? value.trim() : ''
      if (url === '') return { proxy: { mode: 'environment' } }
      const noProxy = file.proxy.mode === 'custom' ? file.proxy.noProxy : ''
      return { proxy: { mode: 'custom', url, noProxy } }
    },
  },
  'advanced.report': {
    section: 'advanced',
    row: 'report',
    group: 'advanced.groups.data',
    name: 'advanced.report.name',
    description: 'advanced.report.description',
    keywords: 'advanced.report.keywords',
    part: 'host',
    kind: 'action',
  },
  'advanced.data-folder': {
    section: 'advanced',
    row: 'data-folder',
    group: 'advanced.groups.data',
    name: 'advanced.dataFolder.name',
    description: 'advanced.dataFolder.description',
    part: 'host',
    kind: 'path',
  },
  'advanced.remove-sessions': {
    section: 'advanced',
    row: 'remove-sessions',
    group: 'advanced.groups.danger',
    name: 'advanced.removeSessions.name',
    description: 'advanced.removeSessions.description',
    keywords: 'advanced.removeSessions.keywords',
    part: 'host',
    kind: 'action',
  },

  // ---- About
  'about.update': {
    section: 'about',
    row: 'update',
    group: 'about.groups.updates',
    name: 'about.updates.name',
    keywords: 'about.updates.keywords',
    part: 'host',
    kind: 'info',
  },
  'about.github': {
    section: 'about',
    row: 'github',
    name: 'about.github.name',
    keywords: 'about.github.keywords',
    part: 'host',
    kind: 'action',
  },
} as const satisfies Record<string, CatalogEntry>

export type SettingId = keyof typeof ENTRIES

export const CATALOG: Readonly<Record<SettingId, CatalogEntry>> = ENTRIES

export function isSettingId(value: unknown): value is SettingId {
  return typeof value === 'string' && Object.hasOwn(ENTRIES, value)
}

/** Whether agents may change a row at all, as the mode allows or always asking. */
export function changeable(entry: CatalogEntry): boolean {
  return (
    (entry.access === 'change' || entry.access === 'ask') &&
    entry.patch !== undefined &&
    (entry.kind === 'switch' ||
      entry.kind === 'choice' ||
      entry.kind === 'number' ||
      entry.kind === 'text')
  )
}

/** A row's search words, as one key or several. */
export function keywordKeys(entry: CatalogEntry): readonly TextKey[] {
  return entry.keywords === undefined
    ? []
    : typeof entry.keywords === 'string'
      ? [entry.keywords]
      : entry.keywords
}

/** The text for the host's system: Dock on macOS, taskbar elsewhere. */
export function platformKey(text: EntryText, platform: Platform): TextKey {
  if (typeof text === 'string') return text
  if (platform === 'darwin') return text.mac ?? text.other
  if (platform === 'win32') return text.windows ?? text.other
  if (platform === 'linux') return text.linux ?? text.other
  return text.other
}

/** An option label's words for the host's system, when they are not a catalog key. */
export function optionWords(label: OptionLabel, platform: Platform): string | null {
  if ('text' in label) return label.text
  if ('platform' in label) {
    const key = platform === 'darwin' ? 'mac' : platform === 'win32' ? 'windows' : 'linux'
    return label.platform[key] ?? label.platform.other
  }
  return null
}

/** The choices a row takes now, static or from the host's agents. */
export function optionsOf(
  entry: CatalogEntry,
  ctx: CatalogContext,
  item: string | null,
): SettingOption[] {
  if (!entry.options) return []
  return typeof entry.options === 'function' ? entry.options(ctx, item) : [...entry.options]
}

/** A row's id as the tools name it: `section.row`, with `:item` for an agent's or a harness's. */
export function toolId(id: SettingId, item: string | null): string {
  return item === null ? id : `${id}:${item}`
}

export function parseToolId(value: string): { id: SettingId; item: string | null } | null {
  const at = value.indexOf(':')
  const id = at < 0 ? value : value.slice(0, at)
  const item = at < 0 ? null : value.slice(at + 1)
  if (!isSettingId(id)) return null
  const entry = CATALOG[id]
  if ((entry.item === undefined) !== (item === null)) return null
  if (item !== null && item.length === 0) return null
  return { id, item }
}

/** Whether the host has the row: its part applies there, and it is on for its system and item. */
export function present(entry: CatalogEntry, ctx: CatalogContext, item: string | null): boolean {
  return entry.on?.(ctx, item) ?? true
}

/** Every row the host has, each agent's and each harness's once per item. */
export function presentRows(ctx: CatalogContext): { id: SettingId; item: string | null }[] {
  const rows: { id: SettingId; item: string | null }[] = []
  for (const id of Object.keys(ENTRIES) as SettingId[]) {
    const entry = CATALOG[id]
    const items =
      entry.item === 'agent'
        ? ctx.agents.map((agent) => agent.id as string)
        : entry.item === 'harness'
          ? ctx.harnesses.map((harness) => harness.id as string)
          : [null]
    for (const item of items) if (present(entry, ctx, item)) rows.push({ id, item })
  }
  return rows
}

/** Whether a start mode is Full access, which a row that sets one names on its card. */
export function namesFullAccess(value: SettingScalar): boolean {
  return typeof value === 'string' && isFullAccessMode(value)
}

/**
 * A value the agent gave, as the row takes it, or why not: a choice must be one of its values, a
 * switch true or false, a number whole and within bounds, a text within its length and check.
 */
export function coerce(
  entry: CatalogEntry,
  ctx: CatalogContext,
  item: string | null,
  value: unknown,
): { value: SettingScalar } | { error: string } {
  switch (entry.kind) {
    case 'switch': {
      if (value === true || value === 'on' || value === 'true') return { value: true }
      if (value === false || value === 'off' || value === 'false') return { value: false }
      return { error: 'takes true or false' }
    }
    case 'choice': {
      const options = optionsOf(entry, ctx, item)
      const found = options.find(
        (option) =>
          option.value === value ||
          (value !== null && typeof option.value === 'number' && Number(value) === option.value) ||
          (option.value === null && (value === 'null' || value === undefined)),
      )
      if (found) return { value: found.value }
      return {
        error: `takes one of ${options.map((option) => JSON.stringify(option.value)).join(', ')}`,
      }
    }
    case 'number': {
      const number = typeof value === 'string' && value.trim() !== '' ? Number(value) : value
      if (
        typeof number !== 'number' ||
        !Number.isInteger(number) ||
        (entry.min !== undefined && number < entry.min) ||
        (entry.max !== undefined && number > entry.max)
      ) {
        return { error: `takes a whole number from ${entry.min} to ${entry.max}` }
      }
      return { value: number }
    }
    case 'text': {
      if (value === null) return { value: '' }
      if (typeof value !== 'string') return { error: 'takes a text' }
      const text = value.trim()
      if (entry.chars !== undefined && text.length > entry.chars) {
        return { error: `takes at most ${entry.chars} characters` }
      }
      if (entry.check && !entry.check(text)) return { error: 'does not take that text' }
      return { value: text }
    }
    default:
      return { error: 'cannot be changed by agents' }
  }
}

/** Two values read the same, as a change that would leave a row as it is. */
export function sameValue(a: SettingScalar, b: SettingScalar): boolean {
  return a === b || ((a === null || a === '') && (b === null || b === ''))
}

/** Merges patches in order, the later winning key by key, lists and `proxy` replaced whole. */
export function mergePatches(patches: readonly SettingsPatch[]): SettingsPatch {
  const merged: Record<string, unknown> = {}
  for (const patch of patches) {
    for (const [section, value] of Object.entries(patch)) {
      const held = merged[section]
      merged[section] =
        isRecord(held) && isRecord(value) && section !== 'proxy' ? deepMerge(held, value) : value
    }
  }
  return merged as SettingsPatch
}

/** Whether a URL carries a user name or password. */
export function hasCredentials(url: string): boolean {
  return /^[a-z][a-z0-9+.-]*:\/\/[^/?#]*@/i.test(url.trim())
}

/** A URL with any password in it hidden. */
function withoutPassword(url: string): string {
  return url.replace(/^([a-z][a-z0-9+.-]*:\/\/[^:/?#@]*):[^/?#@]*@/i, '$1:•••@')
}

/** Whether agents may change the row now: a proxy that has a password they may not. */
export function lockedNow(id: SettingId, file: SettingsFile): boolean {
  return id === 'advanced.proxy' && file.proxy.mode === 'custom' && hasCredentials(file.proxy.url)
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function deepMerge(
  a: Record<string, unknown>,
  b: Record<string, unknown>,
): Record<string, unknown> {
  const out: Record<string, unknown> = { ...a }
  for (const [key, value] of Object.entries(b)) {
    const held = out[key]
    out[key] = isRecord(held) && isRecord(value) ? deepMerge(held, value) : value
  }
  return out
}
