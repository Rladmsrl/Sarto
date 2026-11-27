// Host-side service for own-account remote Claude Code: runs Claude Code queries on this
// computer for another paired computer of the same Sarto account, disabling built-in local
// file/shell tools and routing MCP execution back to the controller over the encrypted channel.

import type { Platform } from '@shared/platform'
import {
  DEFAULT_REMOTE_CLAUDE_SETTINGS,
  HOSTED_CLAUDE_DISALLOWED_TOOLS,
  HOSTED_CLAUDE_TOOLS,
  REMOTE_CLAUDE_EXEC_MCP,
  REMOTE_CLAUDE_EXEC_TOOLS,
  type RemoteClaudeActiveRun,
  type RemoteClaudeClosedEvent,
  type RemoteClaudeCloseReason,
  type RemoteClaudeMcpAnswer,
  type RemoteClaudeMcpCall,
  type RemoteClaudeOpenParams,
  type RemoteClaudeOpenResult,
  type RemoteClaudeOutputEvent,
  type RemoteClaudePermissionAnswer,
  type RemoteClaudePermissionRequest,
  type RemoteClaudePromptParams,
  type RemoteClaudePromptResult,
  type RemoteClaudeSetConfigParams,
  type RemoteClaudeSettings,
  type RemoteClaudeSnapshotFile,
  type RemoteClaudeStatus,
} from '@shared/remote-claude'
import type { PortDevice } from '@shared/remote/device'
import {
  applyPatchInPlace,
  harnessOf,
  type AgentId,
  type ConfigOption,
  type SessionView,
  type ThreadState,
} from '@shared/thread'
import type { AgentManager, AgentRuntime } from '../agents'
import {
  AgentRequestError,
  type AgentConnection,
  type McpServer,
  type PermissionAnswer,
  type PermissionRequest,
  type SessionOptions,
  type SessionTarget,
} from '../connection'
import { HostError } from '../errors'
import { t } from '../i18n'
import { newTurnScope } from '../session-updates'
import type { LogFn } from '../storage'
import { prepareShadowWorkspace, sanitizeSnapshotFiles, type ShadowWorkspace } from './shadow'
import { createRunTunnel, type RunTunnel, type TunnelRequest, type TunnelResponse } from './tunnel'

const SWEEP_INTERVAL_MS = 30_000
/** Maximum time a remote MCP tool call (e.g. long Bash command) may wait for the controller. */
const MCP_CALL_TIMEOUT_MS = 10 * 60_000
const MAX_PENDING_MCP_PER_RUN = 16
const MAX_PENDING_PERMS_PER_RUN = 8
/** Concurrent lightweight hidden queries (branch names, outline titles, drafts) allowed per host. */
const MAX_HIDDEN_CONCURRENT = 4
/** Pages of a shadow folder's sessions read to find the one a device resumes. */
const MAX_RESUME_PAGES = 20

interface PendingMcp {
  resolve(response: TunnelResponse): void
  reject(error: Error): void
  timer: ReturnType<typeof setTimeout>
}

interface PendingPermission {
  resolve(answer: PermissionAnswer): void
}

interface HostedRun {
  runId: string
  sessionId: string
  /** The device and its session, which own the run's shadow folder. */
  key: string
  portId: string
  deviceId: string
  deviceName: string
  agentId: AgentId
  acpSessionId: string
  hidden: boolean
  connection: AgentConnection
  target: SessionTarget
  tunnel: RunTunnel | null
  shadow: ShadowWorkspace
  startedAt: number
  lastActiveAt: number
  busy: boolean
  cancelling: boolean
  closing: boolean
  nextCallId: number
  pendingMcp: Map<number, PendingMcp>
  pendingPerms: Map<string, PendingPermission>
  nextPermId: number
}

export interface RemoteClaudeHostDeps {
  userDataPath: string
  platform: Platform
  agents: Pick<AgentManager, 'ensureReady' | 'list'> &
    Partial<Pick<AgentManager, 'sessionsChanged'>>
  /** Remembered options for `claude-code` so `status` can report models without starting a query. */
  claudeOptions(): ConfigOption[]
  settings(): RemoteClaudeSettings | undefined
  sendToPort(
    portId: string,
    event:
      | { type: 'remoteClaude.output'; event: RemoteClaudeOutputEvent }
      | { type: 'remoteClaude.mcpCall'; call: RemoteClaudeMcpCall }
      | { type: 'remoteClaude.permission'; request: RemoteClaudePermissionRequest }
      | { type: 'remoteClaude.closed'; event: RemoteClaudeClosedEvent },
  ): void
  onActiveChanged(active: RemoteClaudeActiveRun[]): void
  log: LogFn
  now?: () => number
}

function hostedInstructions(
  localProjectPath: string,
  virtualRoot: string,
  snapshotFiles: readonly RemoteClaudeSnapshotFile[],
): string {
  const sections = [
    [
      'You are running in Sarto Remote Claude Code mode on a model host for the user’s local computer.',
      `The user’s project is located on their local computer (${localProjectPath}) and mapped to this workspace root (${virtualRoot}).`,
      `All file operations and shell commands MUST use the \`${REMOTE_CLAUDE_EXEC_MCP}\` MCP tools (Read, Write, Edit, Glob, Grep, Bash, BashOutput, KillShell), which execute directly on the user’s local computer after local permission checks.`,
      'Do not assume files exist on this model host; always read and modify files through the `sarto_exec` tools.',
    ].join('\n'),
  ]
  for (const file of snapshotFiles) {
    sections.push(`Contents of ${file.relativePath} from the user’s project:\n\n${file.content}`)
  }
  return sections.join('\n\n')
}

/** The shadow folder a device's session runs in, as one key. */
function shadowKey(deviceId: string, sessionId: string): string {
  return `${deviceId}\n${sessionId}`
}

export class RemoteClaudeHost {
  private readonly runs = new Map<string, HostedRun>()
  /** Runs still opening, by run id, with the port, agent and whether the run is hidden. */
  private readonly opening = new Map<
    string,
    { portId: string; agentId: AgentId; hidden: boolean }
  >()
  /** Shadow folders a run is opening in, so a second open of the same session waits for none. */
  private readonly openingKeys = new Set<string>()
  /** Opening runs their controller closed before they were ready, which end once they are. */
  private readonly abandoned = new Set<string>()
  /** Runs still ending, by shadow folder, whose cleanup a new run of the folder waits for. */
  private readonly settling = new Map<string, Promise<void>>()
  /** Agent connections already watched so their closure ends every hosted run they carry. */
  private readonly watchedConnections = new WeakSet<AgentConnection>()
  private sweepTimer: ReturnType<typeof setInterval> | null = null
  private readonly now: () => number

  constructor(private readonly deps: RemoteClaudeHostDeps) {
    this.now = deps.now ?? Date.now
  }

  /** Number of active or opening hosted runs on `agentId`, kept alive against idle stops. */
  liveCount(agentId: AgentId): number {
    let count = 0
    for (const run of this.runs.values()) {
      if (run.agentId === agentId && !run.closing) count++
    }
    for (const entry of this.opening.values()) {
      if (entry.agentId === agentId) count++
    }
    return count
  }

  private config(): RemoteClaudeSettings {
    return this.deps.settings() ?? DEFAULT_REMOTE_CLAUDE_SETTINGS
  }

  private assertEnabled(): RemoteClaudeSettings {
    const cfg = this.config()
    if (!cfg.enabled) throw new HostError('forbidden', t('remoteClaude.off'))
    return cfg
  }

  private visibleActiveCount(): number {
    let count = 0
    for (const run of this.runs.values()) if (!run.hidden) count++
    return count
  }

  /** Reports whether this computer can host remote Claude Code sessions (no secrets or paths). */
  async status(): Promise<RemoteClaudeStatus> {
    const cfg = this.config()
    const list = await this.deps.agents.list()
    const claude = list.find((item) => item.id === 'claude-code')
    const models = this.deps.claudeOptions().filter((opt) => opt.category === 'model')
    const activeRuns = this.visibleActiveCount()
    if (!cfg.enabled) {
      return {
        enabled: false,
        ready: false,
        authRequired: false,
        accountLabel: null,
        models: [],
        activeRuns,
        maxConcurrent: cfg.maxConcurrent,
        error: null,
      }
    }
    if (
      !claude ||
      claude.state === 'not-installed' ||
      claude.state === 'node-missing' ||
      claude.state === 'node-outdated' ||
      claude.disabled
    ) {
      return {
        enabled: true,
        ready: false,
        authRequired: false,
        accountLabel: null,
        models: [],
        activeRuns,
        maxConcurrent: cfg.maxConcurrent,
        error: t('remoteClaude.notInstalled'),
      }
    }
    const authRequired = claude.signIn === 'required'
    const failed = claude.state === 'failed'
    return {
      enabled: true,
      ready: !authRequired && !failed,
      authRequired,
      accountLabel: claude.account?.label ?? null,
      models,
      activeRuns,
      maxConcurrent: cfg.maxConcurrent,
      error: failed ? t('remoteClaude.unavailable') : null,
    }
  }

  /** Lists active hosted runs for this computer's local Settings UI. */
  activeRuns(): RemoteClaudeActiveRun[] {
    return [...this.runs.values()]
      .filter((run) => !run.hidden)
      .map((run) => ({
        runId: run.runId,
        deviceId: run.deviceId,
        deviceName: run.deviceName,
        startedAt: run.startedAt,
        lastActiveAt: run.lastActiveAt,
      }))
  }

  /** Called when host settings change: turning `enabled` off closes every active hosted run. */
  async updateSettings(next: RemoteClaudeSettings | undefined): Promise<void> {
    const enabled = next?.enabled ?? false
    if (!enabled && (this.runs.size > 0 || this.opening.size > 0)) {
      await this.disconnectAll('disabled', t('remoteClaude.turnedOff'))
    }
  }

  /** Closes every active hosted run on this computer. */
  async disconnectAll(
    reason: RemoteClaudeCloseReason = 'disabled',
    message = t('remoteClaude.disconnectedByOwner'),
  ): Promise<{ closed: number }> {
    for (const runId of this.opening.keys()) this.abandoned.add(runId)
    const list = [...this.runs.values()]
    await Promise.all(list.map((run) => this.finishRun(run, reason, message)))
    return { closed: list.length }
  }

  /** Cleans up every run owned by a controller port that disconnected. */
  portClosed(portId: string): void {
    for (const [runId, entry] of this.opening) {
      if (entry.portId === portId) this.abandoned.add(runId)
    }
    for (const run of [...this.runs.values()]) {
      if (run.portId === portId) {
        void this.finishRun(run, 'disconnected')
      }
    }
  }

  /** Shuts down all hosted runs and timers when the agent host exits. */
  async shutdown(): Promise<void> {
    this.stopSweeper()
    await this.disconnectAll('closed', t('remoteClaude.shuttingDown'))
  }

  async open(
    portId: string,
    device: PortDevice,
    params: RemoteClaudeOpenParams,
  ): Promise<RemoteClaudeOpenResult> {
    const cfg = this.assertEnabled()
    if (harnessOf(params.agentId) !== 'claude-code') {
      throw new HostError('invalid_params', t('remoteClaude.claudeOnly'))
    }
    // Everything up to the reservation is synchronous, so two opens never both pass the checks.
    if (this.runs.has(params.runId) || this.opening.has(params.runId)) {
      throw new HostError('conflict', t('remoteClaude.runExists'))
    }
    const hidden = params.hidden === true
    const key = shadowKey(device.id, params.sessionId)
    const previous = [...this.runs.values()].filter((run) => run.key === key)
    // The run of the same session shares its shadow folder, which a new run starts over.
    if (this.openingKeys.has(key) || previous.some((run) => run.busy)) {
      throw new HostError('busy', t('remoteClaude.sessionBusy'))
    }
    if (hidden) {
      let activeHidden = 0
      for (const run of this.runs.values()) if (run.hidden) activeHidden++
      for (const entry of this.opening.values()) if (entry.hidden) activeHidden++
      const prevHidden = previous.filter((run) => run.hidden).length
      if (activeHidden - prevHidden >= MAX_HIDDEN_CONCURRENT) {
        throw new HostError(
          'busy',
          t('remoteClaude.limit', {
            active: String(activeHidden - prevHidden),
            max: String(MAX_HIDDEN_CONCURRENT),
          }),
        )
      }
    } else {
      let openingVisible = 0
      for (const entry of this.opening.values()) if (!entry.hidden) openingVisible++
      const prevVisible = previous.filter((run) => !run.hidden).length
      const active = this.visibleActiveCount() - prevVisible + openingVisible
      if (active >= cfg.maxConcurrent) {
        throw new HostError(
          'busy',
          t('remoteClaude.limit', { active: String(active), max: String(cfg.maxConcurrent) }),
        )
      }
    }
    this.opening.set(params.runId, { portId, agentId: params.agentId, hidden })
    this.openingKeys.add(key)
    this.deps.agents.sessionsChanged?.(params.agentId)
    try {
      return await this.openReserved(portId, device, params, key, previous, hidden)
    } finally {
      this.opening.delete(params.runId)
      this.openingKeys.delete(key)
      this.abandoned.delete(params.runId)
      this.deps.agents.sessionsChanged?.(params.agentId)
    }
  }

  private async openReserved(
    portId: string,
    device: PortDevice,
    params: RemoteClaudeOpenParams,
    key: string,
    previous: readonly HostedRun[],
    hidden: boolean,
  ): Promise<RemoteClaudeOpenResult> {
    await Promise.all(
      previous.map((run) => this.finishRun(run, 'closed', t('remoteClaude.superseded'))),
    )
    await this.settling.get(key)

    const safeSnapshot = hidden ? [] : sanitizeSnapshotFiles(params.snapshotFiles)
    const shadow = await prepareShadowWorkspace(this.deps.userDataPath, device.id, params.sessionId)
    let tunnel: RunTunnel | null = null
    let runtime: AgentRuntime
    try {
      if (!hidden) {
        tunnel = await createRunTunnel((request, signal) =>
          this.forwardMcp(params.runId, request, signal),
        )
      }
      runtime = await this.deps.agents.ensureReady(params.agentId)
      this.watchConnection(runtime.connection)
      if (params.resumeSessionId) {
        await this.assertResumable(runtime.connection, params.resumeSessionId, shadow.virtualRoot)
      }
      if (
        this.abandoned.has(params.runId) ||
        runtime.connection.isClosed ||
        !this.config().enabled
      ) {
        throw new HostError('unavailable', t('remoteClaude.notOpen'))
      }
    } catch (error) {
      await tunnel?.close()
      await shadow.cleanup()
      throw this.sanitizeError(error)
    }

    const mcpServers: McpServer[] = tunnel
      ? [
          {
            type: 'http',
            name: REMOTE_CLAUDE_EXEC_MCP,
            url: `${tunnel.url}/mcp/${REMOTE_CLAUDE_EXEC_MCP}`,
            headers: [{ name: 'Authorization', value: `Bearer ${tunnel.token}` }],
            autoAllow: [...REMOTE_CLAUDE_EXEC_TOOLS],
            secret: true,
          },
        ]
      : []
    if (tunnel && params.sartoMcp) {
      mcpServers.push({
        type: 'http',
        name: 'sarto',
        url: `${tunnel.url}/mcp/sarto`,
        headers: [{ name: 'Authorization', value: `Bearer ${tunnel.token}` }],
        ...(params.sartoAutoAllow ? { autoAllow: params.sartoAutoAllow } : {}),
        ...(params.sartoPrompt ? { prompt: params.sartoPrompt } : {}),
        secret: true,
      })
    }

    const options: SessionOptions = hidden
      ? {
          hidden: 'titles',
          mcpServers: [],
          hosted: {
            tools: [],
            disallowedTools: [...HOSTED_CLAUDE_DISALLOWED_TOOLS, ...HOSTED_CLAUDE_TOOLS],
            settingSources: [],
            inheritSignIn: true,
            disableAllHooks: true,
          },
        }
      : {
          mcpServers,
          ...(params.memoryText ? { memory: { text: params.memoryText } } : {}),
          ...(params.suggestions ? { suggestions: true } : {}),
          hosted: {
            tools: [...HOSTED_CLAUDE_TOOLS],
            disallowedTools: [...HOSTED_CLAUDE_DISALLOWED_TOOLS],
            settingSources: [],
            inheritSignIn: true,
            disableAllHooks: true,
            systemPromptAppend: hostedInstructions(
              params.localProjectPath,
              shadow.virtualRoot,
              safeSnapshot,
            ),
          },
        }

    const now = this.now()
    const view: SessionView = {
      id: params.sessionId,
      agentId: params.agentId,
      projectPath: shadow.virtualRoot,
      acpSessionId: params.resumeSessionId ?? null,
      status: 'starting',
      title: null,
      config: [],
      commands: [],
      usage: null,
      error: null,
      turnStartedAt: null,
      turnStartUsed: null,
      createdAt: now,
      updatedAt: now,
      parentId: null,
      origin: 'user',
      subagent: null,
      queue: [],
      queuePaused: false,
    }
    const thread: ThreadState = { session: view, byId: {}, order: [] }
    const scope = newTurnScope()
    let nextEntryId = 1

    const target: SessionTarget = {
      context: () => ({
        thread,
        replaying: false,
        cancelling: this.runs.get(params.runId)?.cancelling ?? false,
        scope,
        now: this.now(),
        nextId: () => `rc:${params.runId}:${nextEntryId++}`,
        sessionIdFor: () => null,
      }),
      apply: (output) => {
        const live = this.runs.get(params.runId)
        if (!live || live.closing) return
        live.lastActiveAt = this.now()
        for (const patch of output.patches) applyPatchInPlace(thread, patch)
        if (output.patches.length === 0 && output.effects.length === 0) return
        this.deps.sendToPort(live.portId, {
          type: 'remoteClaude.output',
          event: { runId: live.runId, patches: output.patches, effects: output.effects },
        })
      },
      requestPermission: (request, signal) => this.forwardPermission(params.runId, request, signal),
      send: () => {},
      startMode: () => 'default',
    }

    const placeholderRun: HostedRun = {
      runId: params.runId,
      sessionId: params.sessionId,
      key,
      portId,
      deviceId: device.id,
      deviceName: device.name,
      agentId: params.agentId,
      acpSessionId: params.resumeSessionId ?? '',
      hidden,
      connection: runtime.connection,
      target,
      tunnel,
      shadow,
      startedAt: now,
      lastActiveAt: now,
      busy: false,
      cancelling: false,
      closing: false,
      nextCallId: 1,
      pendingMcp: new Map(),
      pendingPerms: new Map(),
      nextPermId: 1,
    }
    this.runs.set(params.runId, placeholderRun)
    this.opening.delete(params.runId)

    try {
      let acpSessionId: string
      let config: ConfigOption[]
      let harnessVersion: string | undefined
      if (params.resumeSessionId) {
        runtime.connection.register(params.resumeSessionId, target)
        const setup = await runtime.connection.resumeSession(
          params.resumeSessionId,
          shadow.virtualRoot,
          options,
        )
        acpSessionId = params.resumeSessionId
        config = setup.config
        harnessVersion = setup.harnessVersion
      } else {
        const opened = await runtime.connection.newSession(shadow.virtualRoot, options)
        acpSessionId = opened.sessionId
        config = opened.config
        harnessVersion = opened.harnessVersion
        runtime.connection.register(acpSessionId, target)
      }
      placeholderRun.acpSessionId = acpSessionId
      this.assertStillOpening(placeholderRun)

      // Apply requested initial config options (such as model / effort / fast mode).
      if (params.options) {
        for (const [optionId, value] of Object.entries(params.options)) {
          if (optionId === 'mode') continue // Permission mode is enforced locally on the controller.
          try {
            config = await runtime.connection.setConfigOption(acpSessionId, optionId, value)
          } catch (error) {
            this.deps.log(
              'warn',
              `Remote Claude ignored initial option ${optionId}: ${(error as Error).message}`,
            )
          }
        }
      }

      this.assertStillOpening(placeholderRun)
      this.ensureSweeper()
      if (!hidden) this.notifyActive()
      return {
        runId: params.runId,
        acpSessionId,
        virtualRoot: shadow.virtualRoot,
        remotePlatform: this.deps.platform,
        config,
        ...(harnessVersion ? { harnessVersion } : {}),
      }
    } catch (error) {
      // A run that ended while it opened may have had no Claude Code session yet to close then.
      const endedEarly = placeholderRun.closing
      await this.finishRun(placeholderRun, 'error')
      if (endedEarly && placeholderRun.acpSessionId) {
        runtime.connection.unregister(placeholderRun.acpSessionId, target)
        if (hidden) {
          await runtime.connection
            .removeHidden(placeholderRun.acpSessionId, () => {})
            .catch(() => {})
        } else {
          await runtime.connection.closeSession(placeholderRun.acpSessionId).catch(() => {})
        }
      }
      throw this.sanitizeError(error)
    }
  }

  /** A run ended or abandoned while it opened is not handed to its controller. */
  private assertStillOpening(run: HostedRun): void {
    if (
      run.closing ||
      run.connection.isClosed ||
      this.abandoned.has(run.runId) ||
      !this.config().enabled
    ) {
      throw new HostError('unavailable', t('remoteClaude.notOpen'))
    }
  }

  private watchConnection(connection: AgentConnection): void {
    if (this.watchedConnections.has(connection)) return
    this.watchedConnections.add(connection)
    void connection.closed.then(() => this.connectionClosed(connection))
  }

  private connectionClosed(connection: AgentConnection): void {
    for (const run of [...this.runs.values()]) {
      if (run.connection === connection) {
        void this.finishRun(run, 'closed')
      }
    }
  }

  /**
   * A device resumes only a session it started for the same local session on this computer: one
   * Claude Code keeps under that session's shadow folder, never the owner's own sessions or
   * another device's, which the shared Claude Code connection would otherwise hand over.
   */
  private async assertResumable(
    connection: AgentConnection,
    acpSessionId: string,
    virtualRoot: string,
  ): Promise<void> {
    const other = [...this.runs.values()].some(
      (run) => run.acpSessionId === acpSessionId && run.shadow.virtualRoot !== virtualRoot,
    )
    let cursor: string | null = null
    for (let page = 0; !other && page < MAX_RESUME_PAGES; page++) {
      const listed = await connection.listSessions(virtualRoot, cursor)
      if (listed.sessions.some((session) => session.sessionId === acpSessionId)) return
      cursor = listed.nextCursor
      if (cursor === null) break
    }
    throw new HostError('not_found', t('remoteClaude.notResumable'))
  }

  async prompt(
    portId: string,
    params: RemoteClaudePromptParams,
  ): Promise<RemoteClaudePromptResult> {
    this.assertEnabled()
    const run = this.ownedRun(portId, params.runId)
    run.busy = true
    run.cancelling = false
    run.lastActiveAt = this.now()
    let promptRef: string | undefined
    try {
      const result = await run.connection.prompt(run.acpSessionId, params.prompt, (ref) => {
        promptRef = ref
      })
      run.lastActiveAt = this.now()
      return {
        stopReason: result.stopReason,
        tokens: result.tokens,
        models: result.models,
        ...(promptRef ? { promptRef } : {}),
      }
    } catch (error) {
      throw this.sanitizeError(error)
    } finally {
      run.busy = false
      run.lastActiveAt = this.now()
    }
  }

  async cancel(portId: string, runId: string): Promise<void> {
    const run = this.ownedRun(portId, runId)
    run.cancelling = true
    run.lastActiveAt = this.now()
    await run.connection.cancel(run.acpSessionId)
  }

  async setConfig(portId: string, params: RemoteClaudeSetConfigParams): Promise<ConfigOption[]> {
    this.assertEnabled()
    const run = this.ownedRun(portId, params.runId)
    run.lastActiveAt = this.now()
    if (params.optionId === 'mode') {
      throw new HostError('invalid_params', t('remoteClaude.modeLocal'))
    }
    try {
      return await run.connection.setConfigOption(run.acpSessionId, params.optionId, params.value)
    } catch (error) {
      throw this.sanitizeError(error)
    }
  }

  async close(portId: string, runId: string): Promise<void> {
    // A controller that gave up waiting for its open closes the run it never got.
    if (this.opening.get(runId)?.portId === portId) this.abandoned.add(runId)
    const run = this.runs.get(runId)
    if (!run || run.portId !== portId) return
    await this.finishRun(run, 'closed')
  }

  mcpAnswer(portId: string, answer: RemoteClaudeMcpAnswer): void {
    const run = this.runs.get(answer.runId)
    if (!run || run.portId !== portId) throw new HostError('not_found', t('remoteClaude.notOpen'))
    const pending = run.pendingMcp.get(answer.callId)
    if (!pending) throw new HostError('not_found', t('remoteClaude.noCall'))
    clearTimeout(pending.timer)
    run.pendingMcp.delete(answer.callId)
    run.lastActiveAt = this.now()
    pending.resolve({ status: answer.status, headers: answer.headers, body: answer.body })
  }

  permissionAnswer(portId: string, reply: RemoteClaudePermissionAnswer): void {
    const run = this.runs.get(reply.runId)
    if (!run || run.portId !== portId) throw new HostError('not_found', t('remoteClaude.notOpen'))
    const pending = run.pendingPerms.get(reply.requestId)
    if (!pending) throw new HostError('not_found', t('remoteClaude.noPermission'))
    run.pendingPerms.delete(reply.requestId)
    run.lastActiveAt = this.now()
    pending.resolve(reply.answer)
  }

  private ownedRun(portId: string, runId: string): HostedRun {
    const run = this.runs.get(runId)
    if (!run || run.portId !== portId || run.closing || run.connection.isClosed) {
      if (run && !run.closing && run.connection.isClosed) {
        void this.finishRun(run, 'closed')
      }
      throw new HostError('not_found', t('remoteClaude.notOpen'))
    }
    return run
  }

  private forwardMcp(
    runId: string,
    request: TunnelRequest,
    signal: AbortSignal,
  ): Promise<TunnelResponse> {
    const run = this.runs.get(runId)
    if (!run || run.closing) return Promise.reject(new Error('Run closed'))
    if (run.pendingMcp.size >= MAX_PENDING_MCP_PER_RUN) {
      return Promise.reject(new Error('Too many concurrent MCP calls'))
    }
    const callId = run.nextCallId++
    run.lastActiveAt = this.now()
    return new Promise<TunnelResponse>((resolve, reject) => {
      const cleanup = (): void => {
        clearTimeout(timer)
        run.pendingMcp.delete(callId)
        signal.removeEventListener('abort', onAbort)
      }
      const onAbort = (): void => {
        cleanup()
        reject(new Error('Aborted'))
      }
      const timer = setTimeout(() => {
        cleanup()
        reject(new Error('MCP call timed out'))
      }, MCP_CALL_TIMEOUT_MS)
      timer.unref()
      signal.addEventListener('abort', onAbort, { once: true })
      run.pendingMcp.set(callId, {
        resolve: (response) => {
          cleanup()
          resolve(response)
        },
        reject: (error) => {
          cleanup()
          reject(error)
        },
        timer,
      })
      this.deps.sendToPort(run.portId, {
        type: 'remoteClaude.mcpCall',
        call: {
          runId,
          callId,
          server: request.server,
          headers: request.headers,
          body: request.body,
        },
      })
    })
  }

  private forwardPermission(
    runId: string,
    request: PermissionRequest,
    signal: AbortSignal,
  ): Promise<PermissionAnswer> {
    const run = this.runs.get(runId)
    if (!run || run.closing) return Promise.resolve('cancelled')
    if (run.pendingPerms.size >= MAX_PENDING_PERMS_PER_RUN) return Promise.resolve('cancelled')
    const requestId = `rcp-${run.nextPermId++}`
    run.lastActiveAt = this.now()
    return new Promise<PermissionAnswer>((resolve) => {
      const onAbort = (): void => {
        run.pendingPerms.delete(requestId)
        resolve('cancelled')
      }
      signal.addEventListener('abort', onAbort, { once: true })
      run.pendingPerms.set(requestId, {
        resolve: (answer) => {
          signal.removeEventListener('abort', onAbort)
          resolve(answer)
        },
      })
      this.deps.sendToPort(run.portId, {
        type: 'remoteClaude.permission',
        request: {
          runId,
          requestId,
          toolCallId: request.toolCallId,
          toolEntryId: request.toolEntryId,
          options: request.options,
          ...(request.questions ? { questions: request.questions } : {}),
          ...(request.plan !== undefined ? { plan: request.plan } : {}),
          ...(request.elicitation ? { elicitation: request.elicitation } : {}),
          ...(request.nonBlocking ? { nonBlocking: true as const } : {}),
          patches: request.output.patches,
          effects: request.output.effects,
        },
      })
    })
  }

  private finishRun(
    run: HostedRun,
    reason: RemoteClaudeCloseReason,
    message?: string,
  ): Promise<void> {
    if (run.closing) return this.settling.get(run.key) ?? Promise.resolve()
    run.closing = true
    const done = this.endRun(run, reason, message)
    this.settling.set(run.key, done)
    void done.finally(() => {
      if (this.settling.get(run.key) === done) this.settling.delete(run.key)
    })
    return done
  }

  private async endRun(
    run: HostedRun,
    reason: RemoteClaudeCloseReason,
    message?: string,
  ): Promise<void> {
    this.runs.delete(run.runId)
    for (const pending of run.pendingMcp.values()) {
      clearTimeout(pending.timer)
      pending.reject(new Error('Run closed'))
    }
    run.pendingMcp.clear()
    for (const pending of run.pendingPerms.values()) pending.resolve('cancelled')
    run.pendingPerms.clear()

    if (run.acpSessionId) {
      run.connection.unregister(run.acpSessionId, run.target)
      if (!run.connection.isClosed) {
        if (run.hidden) {
          await run.connection.removeHidden(run.acpSessionId, () => {}).catch(() => {})
        } else {
          await run.connection.closeSession(run.acpSessionId).catch(() => {})
        }
      }
    }
    await run.tunnel?.close().catch(() => {})
    await run.shadow.cleanup()

    if (reason !== 'disconnected') {
      this.deps.sendToPort(run.portId, {
        type: 'remoteClaude.closed',
        event: { runId: run.runId, reason, ...(message ? { message } : {}) },
      })
    }
    if (this.runs.size === 0) this.stopSweeper()
    if (!run.hidden) this.notifyActive()
    this.deps.agents.sessionsChanged?.(run.agentId)
  }

  private ensureSweeper(): void {
    if (this.sweepTimer) return
    this.sweepTimer = setInterval(() => this.sweepIdle(), SWEEP_INTERVAL_MS)
    this.sweepTimer.unref()
  }

  private stopSweeper(): void {
    if (!this.sweepTimer) return
    clearInterval(this.sweepTimer)
    this.sweepTimer = null
  }

  /** Reclaims idle hosted runs past `idleMinutes`; exposed for deterministic tests. */
  sweepIdle(): void {
    const idleMs = this.config().idleMinutes * 60_000
    const now = this.now()
    for (const run of [...this.runs.values()]) {
      if (run.busy || run.closing) continue
      if (now - run.lastActiveAt >= idleMs) {
        void this.finishRun(run, 'idle_reclaimed', t('remoteClaude.idle'))
      }
    }
  }

  private notifyActive(): void {
    this.deps.onActiveChanged(this.activeRuns())
  }

  private sanitizeError(error: unknown): Error {
    if (error instanceof HostError) return error
    if (error instanceof AgentRequestError) {
      if (error.kind === 'auth_required') {
        return new HostError('auth_required', t('remoteClaude.signIn'))
      }
      if (error.kind === 'closed') {
        return new HostError('unavailable', error.message)
      }
      return new HostError('agent_error', error.message)
    }
    return new HostError(
      'internal',
      error instanceof Error ? error.message : t('remoteClaude.failed'),
    )
  }
}
