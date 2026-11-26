// Google Antigravity's plugins through its official `agy plugin` commands: list, install,
// uninstall, enable and disable. Arguments go as an argv array, never through a shell.

import { readdir, readFile, stat } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import type {
  CatalogPlugin,
  InstalledPlugin,
  PluginDetails,
  PluginMarketplace,
} from '@shared/marketplace'
import type { Platform } from '@shared/platform'
import type { AgentId } from '@shared/thread'
import {
  programFailure,
  runProgram,
  type ProgramOptions,
  type ProgramRun,
} from '../adapter-install'
import type { Env } from '../find-command'
import { t, type HostKey } from '../i18n'
import { LocalizedError } from '../localized-error'

export const AGY_MARKETPLACE = 'antigravity'
const PLUGIN_NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/
const LIST_MS = 60_000
const CHANGE_MS = 180_000
const MANIFEST_BYTES = 1024 * 1024

export interface AgyCli {
  agentId: AgentId
  program: string
  env: Env
  platform: Platform
  run?: (options: ProgramOptions) => Promise<ProgramRun>
}

export interface AgyListedPlugin {
  name: string
  enabled: boolean
  path: string | null
  version: string | null
  description: string | null
  rules: string[]
  skills: string[]
  commands: string[]
  agents: string[]
  hooks: string[]
  mcpServers: string[]
}

type Fields = Record<string, unknown>

function isRecord(value: unknown): value is Fields {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function text(value: unknown): string | null {
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : null
}

function stringList(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  return value.filter((item): item is string => typeof item === 'string' && item.trim() !== '')
}

function json(stdout: string, notJson: HostKey): unknown {
  try {
    return JSON.parse(stdout) as unknown
  } catch {
    throw new LocalizedError({ key: notJson })
  }
}

/** Sarto's `<name>@<marketplace>` plugin identifier for an installed agy plugin. */
export function agyPluginId(name: string): string {
  return `${name}@${AGY_MARKETPLACE}`
}

/**
 * Extracts the bare plugin name for `agy plugin enable|disable|uninstall`.
 * Accepts either `<name>@antigravity` or `<name>@<marketplace>` and validates it strictly.
 */
export function agyPluginName(id: string): string {
  const at = id.indexOf('@')
  if (at === -1) {
    if (!PLUGIN_NAME.test(id)) {
      throw new Error(`Invalid Antigravity plugin name: ${id}`)
    }
    return id
  }
  const name = id.slice(0, at)
  const marketplace = id.slice(at + 1)
  if (!PLUGIN_NAME.test(name) || !PLUGIN_NAME.test(marketplace)) {
    throw new Error(`Invalid Antigravity plugin name: ${id}`)
  }
  return name
}

/** Parses `agy plugin list --json` output. */
export function parseAgyPluginList(stdout: string): AgyListedPlugin[] {
  const trimmed = stdout.trim()
  if (trimmed === '') return []
  const value = json(trimmed, 'marketPlugins.agyListNotJson')
  const list = Array.isArray(value)
    ? value
    : isRecord(value) && Array.isArray(value.plugins)
      ? value.plugins
      : null
  if (!list) throw new LocalizedError({ key: 'marketPlugins.agyListNotList' })
  return list.filter(isRecord).flatMap((item): AgyListedPlugin[] => {
    const name = text(item.name)
    if (!name || !PLUGIN_NAME.test(name)) return []
    return [
      {
        name,
        enabled: item.enabled !== false,
        path: text(item.path),
        version: text(item.version),
        description: text(item.description),
        rules: stringList(item.rules),
        skills: stringList(item.skills),
        commands: stringList(item.commands),
        agents: stringList(item.agents),
        hooks: stringList(item.hooks),
        mcpServers: stringList(item.mcpServers),
      },
    ]
  })
}

async function runAgy(cli: AgyCli, args: string[], timeoutMs: number): Promise<string> {
  const exec = cli.run ?? runProgram
  const result = await exec({
    program: cli.program,
    args,
    cwd: os.homedir(),
    env: cli.env,
    platform: cli.platform,
    timeoutMs,
  })
  if (result.code !== 0 || result.timedOut || result.aborted || result.error) {
    const failure = programFailure('agy', result, timeoutMs)
    if (failure) throw new Error(failure)
    throw new LocalizedError({ key: 'marketPlugins.agyFailed' })
  }
  return result.stdout
}

export async function listAgyPlugins(cli: AgyCli): Promise<{
  catalog: CatalogPlugin[]
  installed: InstalledPlugin[]
  marketplaces: PluginMarketplace[]
  paths: Record<string, string>
  logos: Record<string, never>
}> {
  const stdout = await runAgy(cli, ['plugin', 'list', '--json'], LIST_MS)
  const listed = parseAgyPluginList(stdout)
  const paths: Record<string, string> = {}
  const installed: InstalledPlugin[] = listed.map((item) => {
    const id = agyPluginId(item.name)
    if (item.path) paths[id] = item.path
    return {
      id,
      harness: 'antigravity',
      agentId: cli.agentId,
      version: item.version,
      scope: 'user',
      enabled: item.enabled,
      projectPath: null,
    }
  })
  return { catalog: [], installed, marketplaces: [], paths, logos: {} }
}

export async function installedAgyPlugins(cli: AgyCli): Promise<InstalledPlugin[]> {
  return (await listAgyPlugins(cli)).installed
}

/** Installs an agy plugin via `agy plugin install <target>`. */
export async function installAgyPlugin(cli: AgyCli, id: string): Promise<InstalledPlugin> {
  const name = agyPluginName(id)
  const target = id.endsWith(`@${AGY_MARKETPLACE}`) ? name : id
  await runAgy(cli, ['plugin', 'install', target], CHANGE_MS)
  const installed = await installedAgyPlugins(cli)
  const found = installed.find((plugin) => plugin.id === agyPluginId(name) || plugin.id === id)
  if (!found) {
    throw new Error(t('marketPlugins.notListedInstalled', { agent: 'Google Antigravity', id }))
  }
  return found
}

export async function uninstallAgyPlugin(cli: AgyCli, id: string): Promise<void> {
  await runAgy(cli, ['plugin', 'uninstall', agyPluginName(id)], CHANGE_MS)
}

export async function setAgyPluginEnabled(
  cli: AgyCli,
  id: string,
  enabled: boolean,
): Promise<void> {
  await runAgy(cli, ['plugin', enabled ? 'enable' : 'disable', agyPluginName(id)], CHANGE_MS)
}

async function listSubfolderNames(folder: string): Promise<string[]> {
  try {
    const entries = await readdir(folder, { withFileTypes: true })
    return entries
      .filter((entry) => !entry.name.startsWith('.'))
      .map((entry) => entry.name)
      .sort()
  } catch {
    return []
  }
}

async function readManifest(folder: string): Promise<Fields | null> {
  for (const name of ['plugin.json', 'manifest.json']) {
    try {
      const file = path.join(folder, name)
      const info = await stat(file)
      if (!info.isFile() || info.size > MANIFEST_BYTES) continue
      const raw = await readFile(file)
      if (raw.length > MANIFEST_BYTES) continue
      const parsed = JSON.parse(raw.toString('utf8')) as unknown
      if (isRecord(parsed)) return parsed
    } catch {
      continue
    }
  }
  return null
}

/** Reads details of an installed agy plugin from its local manifest and component folders. */
export async function agyPluginDetails(
  agentId: AgentId,
  id: string,
  pluginPath: string | null,
): Promise<PluginDetails> {
  if (!pluginPath) {
    return {
      id,
      agentId,
      description: null,
      skills: [],
      commands: [],
      agents: [],
      hooks: [],
      mcpServers: [],
      lspServers: [],
      alwaysOnTokens: null,
    }
  }
  const [manifest, skills, commands, agents, rules, hooks] = await Promise.all([
    readManifest(pluginPath),
    listSubfolderNames(path.join(pluginPath, 'skills')),
    listSubfolderNames(path.join(pluginPath, 'commands')),
    listSubfolderNames(path.join(pluginPath, 'agents')),
    listSubfolderNames(path.join(pluginPath, 'rules')),
    listSubfolderNames(path.join(pluginPath, 'hooks')),
  ])
  const mcpObj = isRecord(manifest?.mcpServers) ? Object.keys(manifest.mcpServers) : []
  let ruleBytes = 0
  for (const rule of rules) {
    try {
      const info = await stat(path.join(pluginPath, 'rules', rule))
      if (info.isFile() && info.size <= MANIFEST_BYTES) ruleBytes += info.size
    } catch {
      // Ignore unreadable rule files.
    }
  }
  return {
    id,
    agentId,
    description: text(manifest?.description),
    skills,
    commands,
    agents,
    hooks: hooks.length > 0 ? hooks : rules,
    mcpServers: mcpObj,
    lspServers: [],
    alwaysOnTokens: ruleBytes > 0 ? Math.ceil(ruleBytes / 4) : null,
  }
}
