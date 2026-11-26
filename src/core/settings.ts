import { randomInt } from 'node:crypto'
import { join } from 'node:path'
import type { AddedAgent, SettingsFile } from '@shared/settings'
import type { AgentId, HarnessId } from '@shared/thread'
import { JsonFileWriter, quarantineFile, readJsonFile } from './json-file'
import { createLogger } from './log'
import {
  changedSections,
  mergeSettings,
  parseSettingsFile,
  SETTINGS_VERSION,
  type SettingsSection,
  validateSettingsPatch,
  withAddedAgent,
  withFirstStart,
  withAgentBinary,
  withAgentColor,
  withDirectPort,
  withMovedAgent,
  withoutAgent,
  withRenamedAgent,
  withAllowedComputerApp,
  withShellPath,
} from './settings-schema'

const log = createLogger('settings')

/** A port from the dynamic range, which no service registers, for direct connections. */
function randomDirectPort(): number {
  return randomInt(49152, 65536)
}

export type SettingsListener = (settings: SettingsFile, changed: Set<SettingsSection>) => void

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/** Owns settings.json: read once at startup, validated on every change, written atomically. */
export class SettingsStore {
  private readonly listeners = new Set<SettingsListener>()

  private constructor(
    private current: SettingsFile,
    private readonly writer: JsonFileWriter | null,
  ) {}

  static async load(userDataPath: string): Promise<SettingsStore> {
    const path = join(userDataPath, 'settings.json')
    const read = await readJsonFile(path)
    if (read.kind === 'missing') {
      return new SettingsStore(parseSettingsFile({ version: SETTINGS_VERSION }).settings, writer())
    }
    const loaded =
      read.kind === 'ok'
        ? parseSettingsFile(read.value)
        : { ...parseSettingsFile(null), problems: [read.reason], readOnly: false }
    // A file saved before the first start was recorded belongs to a host already set up by hand.
    const recorded = read.kind === 'ok' && isRecord(read.value) && 'initialSetup' in read.value
    if (!recorded) {
      loaded.settings.initialSetup = { done: true }
    }
    // Likewise a file from before the onboarding belongs to someone who already uses Sarto.
    if (!(read.kind === 'ok' && isRecord(read.value) && 'onboarding' in read.value)) {
      loaded.settings.onboarding = { done: true, step: 'welcome' }
    }
    // Direct connections now come on with remote access, so the same network is not routed through
    // the relay. Off was the old default, so a file from before turns them on once, whether remote
    // access is on now or later; the owner may turn them off again.
    const needsDirect = !(
      read.kind === 'ok' &&
      isRecord(read.value) &&
      read.value.remoteDirectVersion === 1
    )
    if (needsDirect) {
      if (!loaded.settings.remote.direct.enabled) {
        loaded.settings.remote.direct.enabled = true
        log.info('Turned direct connections on, which now come with remote access')
      }
      loaded.settings.remoteDirectVersion = 1
    }
    // A file that turns direct connections on by hand gets its port as a change would.
    const settings = withDirectPort(loaded.settings, randomDirectPort)
    if (loaded.readOnly) {
      log.warn('settings.json comes from a newer version; changes this run are not saved')
      return new SettingsStore(settings, null)
    }
    // The Agents page no longer has a control for this, so a stored true would keep the account,
    // sharing and git names masked with no way to show them.
    const clearedHide = settings.privacy.hideAccount
    if (clearedHide) settings.privacy.hideAccount = false
    const store = new SettingsStore(settings, writer())
    if (loaded.problems.length > 0) {
      log.warn(`settings.json is invalid: ${loaded.problems.join('; ')}`)
      try {
        log.warn(`Moved the invalid file to ${await quarantineFile(path)}`)
      } catch (error) {
        log.error('Could not move the invalid settings.json aside', error)
        return new SettingsStore(settings, null)
      }
      store.save()
    } else if (settings !== loaded.settings || needsDirect || clearedHide) {
      store.save()
    }
    return store

    function writer(): JsonFileWriter {
      return new JsonFileWriter(path, log)
    }
  }

  get(): SettingsFile {
    return this.current
  }

  /** Applies a patch from the renderer; throws a `SettingsError` and changes nothing if invalid. */
  update(patch: unknown): SettingsFile {
    const merged = mergeSettings(this.current, validateSettingsPatch(patch))
    return this.replace(withDirectPort(merged, randomDirectPort))
  }

  setAgentBinary(harnessId: HarnessId, binaryPath: string): SettingsFile {
    return this.replace(withAgentBinary(this.current, harnessId, binaryPath))
  }

  addAgent(agent: AddedAgent): SettingsFile {
    return this.replace(withAddedAgent(this.current, agent))
  }

  /** The agent host's first start found the programs of these harnesses. */
  firstStart(found: unknown): SettingsFile {
    return this.replace(withFirstStart(this.current, found))
  }

  renameAgent(agentId: AgentId, name: string): SettingsFile {
    return this.replace(withRenamedAgent(this.current, agentId, name))
  }

  colorAgent(agentId: unknown, color: unknown): SettingsFile {
    return this.replace(withAgentColor(this.current, agentId, color))
  }

  removeAgent(agentId: AgentId): SettingsFile {
    return this.replace(withoutAgent(this.current, agentId))
  }

  moveAgent(agentId: AgentId, configDir: string): SettingsFile {
    return this.replace(withMovedAgent(this.current, agentId, configDir))
  }

  setShellPath(shellPath: string): SettingsFile {
    return this.replace(withShellPath(this.current, shellPath))
  }

  /** A session's card allowed an app always. */
  allowComputerApp(app: unknown): SettingsFile {
    return this.replace(withAllowedComputerApp(this.current, app))
  }

  onChange(listener: SettingsListener): () => void {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  flush(): Promise<void> {
    return this.writer?.flush() ?? Promise.resolve()
  }

  private replace(next: SettingsFile): SettingsFile {
    const changed = changedSections(this.current, next)
    if (changed.size === 0) return this.current
    this.current = next
    this.save()
    for (const listener of this.listeners) {
      try {
        listener(next, changed)
      } catch (error) {
        log.error('A settings listener failed', error)
      }
    }
    return next
  }

  private save(): void {
    this.writer?.schedule(this.current)
  }
}
