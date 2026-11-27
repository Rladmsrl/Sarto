// Controller-side client for own-account remote Claude Code: connects to another online computer
// of the same Sarto account through `remote-host`'s `HostSockets`, exposes an `AgentConnection`
// that is transparent to `SessionManager`, and runs every file/shell tool locally via `LocalExecMcp`.

import { randomUUID } from 'node:crypto'
import { readdir, readFile, realpath } from 'node:fs/promises'
import path from 'node:path'
import type { HostEvent } from '@shared/agent-host'
import { hostRequestLimit } from '@shared/host-request-limits'
import type { Platform } from '@shared/platform'
import type { PortChannel } from '@shared/port-channel'
import type { PortError } from '@shared/port-rpc'
import {
  REMOTE_CLAUDE_MAX_SNAPSHOT_FILE_BYTES,
  REMOTE_CLAUDE_MAX_SNAPSHOT_FILES,
  REMOTE_CLAUDE_MAX_SNAPSHOT_TOTAL_BYTES,
  type RemoteClaudeClosedEvent,
  type RemoteClaudeHostInfo,
  type RemoteClaudeMcpCall,
  type RemoteClaudeOpenParams,
  type RemoteClaudeOpenResult,
  type RemoteClaudeOutputEvent,
  type RemoteClaudePermissionRequest,
  type RemoteClaudePromptResult,
  type RemoteClaudeSnapshotFile,
  type RemoteClaudeStatus,
} from '@shared/remote-claude'
import type { HostStatus } from '@shared/remote/hosts'
import { connectPort } from '@shared/socket-port'
import { harnessOf, type AgentId, type ConfigOption, type Patch } from '@shared/thread'
import type { AgentRuntime } from '../agents'
import {
  AgentRequestError,
  type AgentConnection,
  type AgentInit,
  type ListedSession,
  type McpServer,
  type OpenedSession,
  type PermissionAnswer,
  type PromptBlock,
  type PromptResult,
  type SessionOptions,
  type SessionSetup,
  type SessionTarget,
} from '../connection'
import { HostError } from '../errors'
import { t } from '../i18n'
import type { MapperEffect } from '../session-updates'
import type { LogFn } from '../storage'
import { LocalExecMcp, runNotOpenAnswer } from './executor'
import { createWorkspaceMapper, normalizeHostedPatches, type WorkspaceMapper } from './workspace'

const STATUS_TIMEOUT_MS = 5_000
/** The least a request waits, for a large answer over a slow relay. */
const RPC_TIMEOUT_MS = 60_000
const OPEN_WAIT_MS = 10_000

/** How long to wait for `method`'s answer from the remote host; null to wait for it however long. */
function remoteRequestLimit(method: string): number | null {
  const limit = hostRequestLimit(method)
  return limit === null ? null : Math.max(limit, RPC_TIMEOUT_MS)
}

/** Collects CLAUDE.md and `.claude/rules/*.md` from the local project for the remote shadow dir. */
export async function collectProjectSnapshot(
  projectPath: string,
): Promise<RemoteClaudeSnapshotFile[]> {
  const files: RemoteClaudeSnapshotFile[] = []
  let totalBytes = 0
  const root = await realpath(projectPath).catch(() => null)
  if (root === null) return files

  const addFile = async (relativePath: string): Promise<void> => {
    if (files.length >= REMOTE_CLAUDE_MAX_SNAPSHOT_FILES) return
    // A file that links outside the project, as to a key, is not the project's to send.
    const full = await realpath(path.join(projectPath, ...relativePath.split('/'))).catch(
      () => null,
    )
    const rel = full === null ? '' : path.relative(root, full)
    if (rel === '' || rel.split(path.sep)[0] === '..' || path.isAbsolute(rel)) return
    const content = await readFile(full!, 'utf8').catch(() => null)
    if (content === null || content.includes('\0')) return
    const bytes = Buffer.byteLength(content, 'utf8')
    if (bytes > REMOTE_CLAUDE_MAX_SNAPSHOT_FILE_BYTES) return
    if (totalBytes + bytes > REMOTE_CLAUDE_MAX_SNAPSHOT_TOTAL_BYTES) return
    totalBytes += bytes
    files.push({ relativePath, content })
  }

  await addFile('CLAUDE.md')
  await addFile('CLAUDE.local.md')
  await addFile('.claude/CLAUDE.md')

  const walkRules = async (dir: string, relDir: string): Promise<void> => {
    if (files.length >= REMOTE_CLAUDE_MAX_SNAPSHOT_FILES) return
    const entries = await readdir(dir, { withFileTypes: true }).catch(() => [])
    for (const entry of entries) {
      if (files.length >= REMOTE_CLAUDE_MAX_SNAPSHOT_FILES) return
      const nextRel = `${relDir}/${entry.name}`
      if (entry.isDirectory()) {
        await walkRules(path.join(dir, entry.name), nextRel)
      } else if ((entry.isFile() || entry.isSymbolicLink()) && entry.name.endsWith('.md')) {
        await addFile(nextRel)
      }
    }
  }
  await walkRules(path.join(projectPath, '.claude', 'rules'), '.claude/rules')

  return files
}

interface PendingRpc {
  resolve(value: unknown): void
  reject(error: Error): void
  timer: ReturnType<typeof setTimeout> | undefined
}

/** One multiplexed RPC + event port to a remote host via `remote-host`'s `hostsSocket`. */
export class RemoteHostPeer {
  private nextId = 1
  private readonly pending = new Map<number, PendingRpc>()
  private readonly eventListeners = new Set<(event: HostEvent) => void>()
  private readonly closeListeners = new Set<() => void>()
  private closed = false
  private opened = false
  private readonly readyPromise: Promise<void>

  constructor(
    readonly hostId: string,
    private readonly port: PortChannel,
    private readonly log: LogFn,
    /** Set true when `port` already speaks the remote host protocol directly (e.g. in-process test). */
    direct = false,
  ) {
    this.readyPromise = direct
      ? Promise.resolve().then(() => {
          this.opened = true
        })
      : new Promise<void>((resolve, reject) => {
          const timer = setTimeout(() => {
            this.onReady = null
            reject(new HostError('unavailable', t('remoteClaude.peerTimeout')))
            // A peer that never opened is dropped, so the next request connects again.
            this.close()
          }, OPEN_WAIT_MS)
          timer.unref()
          const finish = (ok: boolean): void => {
            clearTimeout(timer)
            if (ok) {
              this.opened = true
              resolve()
            } else {
              reject(new HostError('unavailable', t('remoteClaude.peerClosed')))
            }
          }
          this.onReady = finish
        })
    // Nothing may be waiting on it yet; each request awaits it on its own.
    this.readyPromise.catch(() => {})

    port.onMessage((data) => this.handleMessage(data))
    port.onClose(() => this.handleClose())
    if (!direct) {
      port.send({ type: 'hosts:connect', hostId })
    }
  }

  private onReady: ((ok: boolean) => void) | null = null

  get isClosed(): boolean {
    return this.closed
  }

  onEvent(listener: (event: HostEvent) => void): () => void {
    this.eventListeners.add(listener)
    return () => this.eventListeners.delete(listener)
  }

  onClose(listener: () => void): () => void {
    if (this.closed) {
      queueMicrotask(listener)
      return () => {}
    }
    this.closeListeners.add(listener)
    return () => this.closeListeners.delete(listener)
  }

  async request<T>(
    method: string,
    params?: unknown,
    timeoutMs: number | null = remoteRequestLimit(method),
  ): Promise<T> {
    if (this.closed) throw new HostError('unavailable', t('remoteClaude.peerClosed'))
    if (!this.opened) await this.readyPromise
    if (this.closed) throw new HostError('unavailable', t('remoteClaude.peerClosed'))
    const id = this.nextId++
    return new Promise<T>((resolve, reject) => {
      const timer =
        timeoutMs === null
          ? undefined
          : setTimeout(() => {
              this.pending.delete(id)
              reject(new HostError('timeout', t('remoteClaude.timedOut', { method })))
            }, timeoutMs)
      timer?.unref()
      this.pending.set(id, {
        resolve: (value) => resolve(value as T),
        reject,
        timer,
      })
      this.port.send({ type: 'request', id, method, params })
    })
  }

  close(): void {
    if (this.closed) return
    this.port.close()
    this.handleClose()
  }

  private handleMessage(data: unknown): void {
    if (typeof data !== 'object' || data === null) return
    const msg = data as Record<string, unknown>
    if (msg.type === 'hosts:open') {
      const ready = this.onReady
      this.onReady = null
      ready?.(true)
      return
    }
    if (msg.type === 'hosts:closed') {
      this.handleClose()
      return
    }
    if (msg.type === 'response' && typeof msg.id === 'number') {
      const pending = this.pending.get(msg.id)
      if (!pending) return
      clearTimeout(pending.timer)
      this.pending.delete(msg.id)
      pending.resolve(msg.result)
      return
    }
    if (msg.type === 'error' && typeof msg.id === 'number') {
      const pending = this.pending.get(msg.id)
      if (!pending) return
      clearTimeout(pending.timer)
      this.pending.delete(msg.id)
      const err = msg.error as PortError | undefined
      pending.reject(
        new HostError(err?.code ?? 'internal', err?.message ?? t('remoteClaude.failed'), err?.data),
      )
      return
    }
    if (msg.type === 'event' && typeof msg.event === 'object' && msg.event !== null) {
      const event = msg.event as HostEvent
      for (const listener of [...this.eventListeners]) {
        try {
          listener(event)
        } catch (error) {
          this.log('warn', `Remote peer event handler failed: ${(error as Error).message}`)
        }
      }
    }
  }

  private handleClose(): void {
    if (this.closed) return
    this.closed = true
    const ready = this.onReady
    this.onReady = null
    ready?.(false)
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer)
      pending.reject(new HostError('unavailable', t('remoteClaude.peerClosed')))
    }
    this.pending.clear()
    for (const listener of [...this.closeListeners]) listener()
    this.closeListeners.clear()
  }
}

interface ActiveLocalRun {
  runId: string
  acpSessionId: string
  localCwd: string
  localMode: string
  mapper: WorkspaceMapper
  env: NodeJS.ProcessEnv
  exec: LocalExecMcp
  config: ConfigOption[]
  openTemplate: Omit<RemoteClaudeOpenParams, 'runId' | 'resumeSessionId'>
  /** The host ended the run, idle or otherwise; the next prompt opens it again. */
  reclaimed: boolean
  reopening: Promise<ActiveLocalRun> | null
  collector: ((patches: readonly Patch[]) => void) | null
}

function withLocalMode(config: readonly ConfigOption[], mode: string): ConfigOption[] {
  return config.map((option) =>
    option.id === 'mode' || option.category === 'mode' ? { ...option, value: mode } : option,
  )
}

function findSartoMcp(servers: readonly McpServer[] | undefined): {
  url: string
  token: string
  autoAllow?: string[]
  prompt?: string
} | null {
  const sarto = servers?.find((server) => server.type === 'http' && server.name === 'sarto')
  if (!sarto || sarto.type !== 'http') return null
  const auth = sarto.headers.find((header) => header.name.toLowerCase() === 'authorization')?.value
  const match = /^Bearer (.+)$/.exec(auth ?? '')
  if (!match) return null
  return {
    url: sarto.url,
    token: match[1]!,
    ...(sarto.autoAllow ? { autoAllow: sarto.autoAllow } : {}),
    ...(sarto.prompt ? { prompt: sarto.prompt } : {}),
  }
}

/**
 * Implements `AgentConnection` over a `RemoteHostPeer`, making a remote Claude Code host look
 * identical to a local Claude Code driver to `SessionManager`.
 */
export class RemoteClaudeConnection implements AgentConnection {
  readonly ownInstructions = true
  readonly hiddenSessions = true
  readonly unpromptedSessions = false
  readonly allowsOwnTools = true

  readonly closed: Promise<void>
  private resolveClosed!: () => void
  private readonly targets = new Map<string, SessionTarget>()
  private readonly runsBySession = new Map<string, ActiveLocalRun>()
  private readonly runsByRunId = new Map<string, ActiveLocalRun>()
  /** Executors of runs still opening, which Claude Code there connects to before they are open. */
  private readonly openingExecs = new Map<string, LocalExecMcp>()
  private readonly unsubEvent: () => void
  private readonly unsubClose: () => void

  constructor(
    private readonly peer: RemoteHostPeer,
    private readonly hostName: string,
    private readonly agentId: AgentId,
    private readonly localPlatform: Platform,
    private readonly log: LogFn,
    private readonly env?: () => Promise<NodeJS.ProcessEnv> | NodeJS.ProcessEnv,
  ) {
    this.closed = new Promise<void>((resolve) => {
      this.resolveClosed = resolve
    })
    this.unsubEvent = peer.onEvent((event) => this.handleEvent(event))
    this.unsubClose = peer.onClose(() => this.handlePeerClosed())
  }

  get isClosed(): boolean {
    return this.peer.isClosed
  }

  close(): void {
    this.unsubEvent()
    this.unsubClose()
    for (const run of this.runsByRunId.values()) run.exec.close()
    this.runsByRunId.clear()
    this.runsBySession.clear()
    this.peer.close()
    this.resolveClosed()
  }

  async initialize(): Promise<AgentInit> {
    return {
      name: `Claude Code (${this.hostName})`,
      version: null,
      capabilities: {
        loadSession: false,
        listSessions: false,
        resumeSession: true,
        closeSession: true,
        deleteSession: false,
        forkSession: false,
        forkAtMessage: false,
        // Claude Code on the remote computer titles the session, as it does here.
        ownTitles: 'sent',
        logout: false,
        steering: false,
        mcpHttp: true,
        mcpSse: false,
        mcpStdio: false,
        prompt: { image: true, audio: false, embeddedContext: true },
      },
      authMethods: [],
      raw: { remoteHostId: this.peer.hostId },
    }
  }

  async authenticate(): Promise<void> {
    throw new AgentRequestError(
      'auth_required',
      t('remoteClaude.signInThere', { host: this.hostName }),
    )
  }

  async logout(): Promise<void> {}

  async newSession(cwd: string, options: SessionOptions = {}): Promise<OpenedSession> {
    const run = await this.openRemoteRun(cwd, options)
    return {
      sessionId: run.acpSessionId,
      config: withLocalMode(run.config, run.localMode),
    }
  }

  async loadSession(
    sessionId: string,
    cwd: string,
    options: SessionOptions = {},
  ): Promise<SessionSetup> {
    return this.resumeSession(sessionId, cwd, options)
  }

  async resumeSession(
    sessionId: string,
    cwd: string,
    options: SessionOptions = {},
  ): Promise<SessionSetup> {
    const run = await this.openRemoteRun(cwd, options, sessionId)
    return { config: withLocalMode(run.config, run.localMode) }
  }

  async forkSession(): Promise<OpenedSession> {
    throw new AgentRequestError('agent_error', t('remoteClaude.noFork'))
  }

  async closeSession(sessionId: string): Promise<void> {
    const run = this.runsBySession.get(sessionId)
    if (!run) return
    this.runsBySession.delete(sessionId)
    this.runsByRunId.delete(run.runId)
    run.exec.close()
    if (!run.reclaimed && !this.peer.isClosed) {
      await this.peer.request('remoteClaude.close', { runId: run.runId }).catch(() => {})
    }
  }

  async deleteSession(sessionId: string): Promise<void> {
    await this.closeSession(sessionId)
  }

  async listSessions(): Promise<{ sessions: ListedSession[]; nextCursor: string | null }> {
    return { sessions: [], nextCursor: null }
  }

  register(sessionId: string, target: SessionTarget): void {
    this.targets.set(sessionId, target)
  }

  unregister(sessionId: string, target?: SessionTarget): void {
    if (!target || this.targets.get(sessionId) === target) this.targets.delete(sessionId)
  }

  reopen(): void {}

  rootOf(id: string): string {
    return id
  }

  async prompt(
    sessionId: string,
    blocks: readonly PromptBlock[],
    sent?: (ref: string) => void,
  ): Promise<PromptResult> {
    const run = this.runsBySession.get(sessionId)
    if (!run) throw new AgentRequestError('closed', t('remoteClaude.notOpen'))
    try {
      return await this.promptRun(run, blocks, sent)
    } catch (error) {
      // The host ended the run, as an idle one, just as the prompt went: it opens again once.
      if (!(error instanceof HostError) || error.code !== 'not_found') {
        if (error instanceof HostError && error.code === 'unavailable') run.reclaimed = true
        throw toAgentError(error)
      }
      run.reclaimed = true
      try {
        return await this.promptRun(run, blocks, sent)
      } catch (again) {
        throw toAgentError(again)
      }
    }
  }

  private async promptRun(
    run: ActiveLocalRun,
    blocks: readonly PromptBlock[],
    sent?: (ref: string) => void,
  ): Promise<PromptResult> {
    if (run.reclaimed) {
      run.reopening ??= this.reopenReclaimed(run).finally(() => {
        run.reopening = null
      })
      await run.reopening
    }
    const projected = blocks.map((block): PromptBlock => {
      if (block.type === 'text') return { ...block, text: run.mapper.toRemoteText(block.text) }
      return block
    })
    const result = await this.peer.request<RemoteClaudePromptResult>('remoteClaude.prompt', {
      runId: run.runId,
      prompt: projected,
    })
    if (result.promptRef) sent?.(result.promptRef)
    return {
      stopReason: result.stopReason,
      tokens: result.tokens,
      models: result.models,
    }
  }

  async collect(sessionId: string, text: string): Promise<string[]> {
    const run = this.runsBySession.get(sessionId)
    if (!run) throw new AgentRequestError('closed', t('remoteClaude.notOpen'))
    const entries = new Map<string, string>()
    const order: string[] = []
    run.collector = (patches) => {
      for (const patch of patches) {
        if (patch.op === 'entry.add' && patch.entry.kind === 'agent') {
          if (!entries.has(patch.entry.id)) order.push(patch.entry.id)
          entries.set(patch.entry.id, patch.entry.markdown)
        } else if (patch.op === 'entry.appendText') {
          const prev = entries.get(patch.id)
          if (prev !== undefined) entries.set(patch.id, prev + patch.text)
        } else if (patch.op === 'entry.update' && entries.has(patch.id)) {
          const nextMarkdown = (patch.changes as { markdown?: unknown }).markdown
          if (typeof nextMarkdown === 'string') entries.set(patch.id, nextMarkdown)
        }
      }
    }
    try {
      await this.prompt(sessionId, [{ type: 'text', text }])
    } finally {
      run.collector = null
    }
    return order.map((id) => entries.get(id) ?? '').filter((s) => s !== '')
  }

  async steer(): Promise<'injected' | 'promptRequired'> {
    return 'promptRequired'
  }

  async cancel(sessionId: string): Promise<void> {
    const run = this.runsBySession.get(sessionId)
    if (!run || run.reclaimed) return
    await this.peer.request('remoteClaude.cancel', { runId: run.runId }).catch(() => {})
  }

  async setMode(sessionId: string, modeId: string): Promise<void> {
    const run = this.runsBySession.get(sessionId)
    if (run) run.localMode = modeId
  }

  async setConfigOption(
    sessionId: string,
    optionId: string,
    value: string | boolean,
  ): Promise<ConfigOption[]> {
    const run = this.runsBySession.get(sessionId)
    if (!run) throw new AgentRequestError('closed', t('remoteClaude.notOpen'))
    if (optionId === 'mode' && typeof value === 'string') {
      run.localMode = value
      return withLocalMode(run.config, run.localMode)
    }
    if (run.reclaimed) {
      run.config = run.config.map((opt) =>
        opt.id === optionId ? ({ ...opt, value } as ConfigOption) : opt,
      )
      return withLocalMode(run.config, run.localMode)
    }
    try {
      const updated = await this.peer.request<ConfigOption[]>('remoteClaude.setConfig', {
        runId: run.runId,
        optionId,
        value,
      })
      run.config = updated
      return withLocalMode(updated, run.localMode)
    } catch (error) {
      if (error instanceof HostError && error.code === 'not_found') {
        run.reclaimed = true
        run.config = run.config.map((opt) =>
          opt.id === optionId ? ({ ...opt, value } as ConfigOption) : opt,
        )
        return withLocalMode(run.config, run.localMode)
      }
      throw toAgentError(error)
    }
  }

  async removeHidden(sessionId: string): Promise<void> {
    await this.closeSession(sessionId)
    this.unregister(sessionId)
  }

  private async openRemoteRun(
    cwd: string,
    options: SessionOptions,
    resumeSessionId?: string,
  ): Promise<ActiveLocalRun> {
    const runId = `rc-${randomUUID()}`
    const hidden = options.hidden !== undefined
    const sartoMcp = hidden ? null : findSartoMcp(options.mcpServers)
    const snapshotFiles = hidden ? [] : await collectProjectSnapshot(cwd)
    const openTemplate: Omit<RemoteClaudeOpenParams, 'runId' | 'resumeSessionId'> = {
      sessionId: options.modelHostKey ?? resumeSessionId ?? runId,
      agentId: this.agentId,
      localProjectPath: cwd,
      localPlatform: this.localPlatform,
      snapshotFiles,
      ...(sartoMcp
        ? {
            sartoMcp: true,
            ...(sartoMcp.autoAllow ? { sartoAutoAllow: sartoMcp.autoAllow } : {}),
            ...(sartoMcp.prompt ? { sartoPrompt: sartoMcp.prompt } : {}),
          }
        : {}),
      ...(!hidden && options.memory ? { memoryText: options.memory.text } : {}),
      ...(!hidden && options.suggestions ? { suggestions: true } : {}),
      ...(hidden ? { hidden: true } : {}),
    }

    const localEnv = (await this.env?.()) ?? process.env
    let currentRun: ActiveLocalRun | null = null
    // Made before the run opens: until then it answers the MCP handshake, which needs no mapping,
    // and refuses tools, which need the run's workspace.
    const exec = new LocalExecMcp({
      mapper: () => {
        if (!currentRun) throw new Error('The run is still opening.')
        return currentRun.mapper
      },
      env: () => currentRun?.env ?? localEnv,
      hostName: this.hostName,
      permissionMode: () => currentRun?.localMode ?? 'default',
      requestPermission: (request, signal) => {
        const target = currentRun ? this.targets.get(currentRun.acpSessionId) : undefined
        if (!target) return Promise.resolve('cancelled')
        return target.requestPermission(request, signal)
      },
      apply: (patches) => {
        if (!currentRun) return
        this.targets.get(currentRun.acpSessionId)?.apply({ patches, effects: [] })
      },
      sartoMcp: () => (sartoMcp ? { url: sartoMcp.url, token: sartoMcp.token } : null),
    })

    let opened: RemoteClaudeOpenResult
    try {
      opened = await this.openRun(
        { ...openTemplate, runId, ...(resumeSessionId ? { resumeSessionId } : {}) },
        exec,
      )
    } catch (error) {
      exec.close()
      throw error
    }

    const mapper = createWorkspaceMapper({
      localRoot: cwd,
      remoteRoot: opened.virtualRoot,
      localPlatform: this.localPlatform,
      remotePlatform: opened.remotePlatform,
    })

    const existing = this.runsBySession.get(opened.acpSessionId)
    if (existing) {
      this.runsByRunId.delete(existing.runId)
      existing.exec.close()
    }

    const localMode =
      existing?.localMode ?? this.targets.get(opened.acpSessionId)?.startMode() ?? 'default'
    const run: ActiveLocalRun = {
      runId,
      acpSessionId: opened.acpSessionId,
      localCwd: cwd,
      localMode,
      mapper,
      env: localEnv,
      exec,
      config: opened.config,
      openTemplate,
      reclaimed: false,
      reopening: null,
      collector: null,
    }
    currentRun = run
    this.runsBySession.set(opened.acpSessionId, run)
    this.runsByRunId.set(runId, run)
    return run
  }

  /**
   * `remoteClaude.open`. Claude Code on the remote host connects its MCP servers before it answers,
   * so `exec` takes the run's calls from the start; the caller registers the run as soon as the
   * answer comes, with no await in between. A run whose answer never came is closed, since the
   * remote host may still open it and would hold it, and one of its limited runs, until it went
   * idle.
   */
  private async openRun(
    params: RemoteClaudeOpenParams,
    exec: LocalExecMcp,
  ): Promise<RemoteClaudeOpenResult> {
    this.openingExecs.set(params.runId, exec)
    try {
      return await this.peer.request<RemoteClaudeOpenResult>('remoteClaude.open', params)
    } catch (error) {
      if (error instanceof HostError && error.code === 'timeout' && !this.peer.isClosed) {
        void this.peer.request('remoteClaude.close', { runId: params.runId }).catch(() => {})
      }
      throw toAgentError(error)
    } finally {
      this.openingExecs.delete(params.runId)
    }
  }

  /** Transparently re-opens a hosted run that the remote host reclaimed or ended. */
  private async reopenReclaimed(run: ActiveLocalRun): Promise<ActiveLocalRun> {
    const newRunId = `rc-${randomUUID()}`
    const snapshotFiles = await collectProjectSnapshot(run.localCwd)
    // The model and effort chosen meanwhile go with it; the mode stays on this computer.
    const options = Object.fromEntries(
      run.config
        .filter((option) => option.id !== 'mode' && option.category !== 'mode')
        .map((option) => [option.id, option.value]),
    )
    const env = (await this.env?.()) ?? run.env
    const opened = await this.openRun(
      {
        ...run.openTemplate,
        snapshotFiles,
        runId: newRunId,
        resumeSessionId: run.acpSessionId,
        ...(Object.keys(options).length > 0 ? { options } : {}),
      },
      run.exec,
    )
    this.runsByRunId.delete(run.runId)
    run.runId = newRunId
    run.reclaimed = false
    run.config = opened.config
    run.env = env
    run.mapper = createWorkspaceMapper({
      localRoot: run.localCwd,
      remoteRoot: opened.virtualRoot,
      localPlatform: this.localPlatform,
      remotePlatform: opened.remotePlatform,
    })
    this.runsByRunId.set(newRunId, run)
    return run
  }

  private handleEvent(event: HostEvent): void {
    switch (event.type) {
      case 'remoteClaude.output':
        this.onOutput(event.event)
        break
      case 'remoteClaude.mcpCall':
        void this.onMcpCall(event.call)
        break
      case 'remoteClaude.permission':
        void this.onPermission(event.request)
        break
      case 'remoteClaude.closed':
        this.onRunClosed(event.event)
        break
      default:
        break
    }
  }

  private onOutput(event: RemoteClaudeOutputEvent): void {
    const run = this.runsByRunId.get(event.runId)
    if (!run) return
    const patches = normalizeHostedPatches(event.patches as Patch[], run.mapper)
    run.collector?.(patches)
    const target = this.targets.get(run.acpSessionId)
    if (!target) return
    target.apply({ patches, effects: event.effects as MapperEffect[] })
  }

  private async onMcpCall(call: RemoteClaudeMcpCall): Promise<void> {
    const exec = this.runsByRunId.get(call.runId)?.exec ?? this.openingExecs.get(call.runId)
    if (!exec) this.log('warn', `${this.hostName} made an MCP call for a run that is not open`)
    const answer = exec ? await exec.handle(call) : runNotOpenAnswer(call)
    if (this.peer.isClosed) return
    await this.peer.request('remoteClaude.mcpAnswer', answer).catch((error: unknown) => {
      this.log('warn', `Could not send MCP answer to ${this.hostName}: ${(error as Error).message}`)
    })
  }

  private async onPermission(request: RemoteClaudePermissionRequest): Promise<void> {
    const run = this.runsByRunId.get(request.runId)
    if (!run) return
    const target = this.targets.get(run.acpSessionId)
    let answer: PermissionAnswer = 'cancelled'
    if (target) {
      const patches = normalizeHostedPatches(request.patches as Patch[], run.mapper)
      const abort = new AbortController()
      answer = await target.requestPermission(
        {
          toolCallId: request.toolCallId,
          toolEntryId: request.toolEntryId,
          output: { patches, effects: request.effects as MapperEffect[] },
          options: request.options,
          ...(request.questions ? { questions: request.questions } : {}),
          ...(request.plan !== undefined ? { plan: request.plan } : {}),
          ...(request.elicitation ? { elicitation: request.elicitation } : {}),
          ...(request.nonBlocking ? { nonBlocking: true as const } : {}),
        },
        abort.signal,
      )
    }
    if (this.peer.isClosed) return
    await this.peer
      .request('remoteClaude.permissionAnswer', {
        runId: request.runId,
        requestId: request.requestId,
        answer,
      })
      .catch(() => {})
  }

  private onRunClosed(event: RemoteClaudeClosedEvent): void {
    const run = this.runsByRunId.get(event.runId)
    if (!run) return
    // The local session and its executor stay; the next prompt opens the run again, or says why
    // it cannot, so the session is never left holding a run that is gone.
    run.reclaimed = true
    if (event.reason === 'idle_reclaimed' || event.reason === 'closed') return
    this.targets.get(run.acpSessionId)?.apply({
      patches: [
        {
          op: 'session.update',
          changes: {
            error: {
              message:
                event.message ??
                t('remoteClaude.ended', { host: this.hostName, reason: event.reason }),
            },
          },
        },
      ],
      effects: [],
    })
  }

  private handlePeerClosed(): void {
    for (const run of this.runsByRunId.values()) run.exec.close()
    this.runsByRunId.clear()
    this.runsBySession.clear()
    this.resolveClosed()
  }
}

function toAgentError(error: unknown): AgentRequestError {
  if (error instanceof AgentRequestError) return error
  if (error instanceof HostError) {
    if (error.code === 'auth_required') return new AgentRequestError('auth_required', error.message)
    if (error.code === 'unavailable') return new AgentRequestError('closed', error.message)
    return new AgentRequestError('agent_error', error.message)
  }
  return new AgentRequestError(
    'agent_error',
    error instanceof Error ? error.message : String(error),
  )
}

export interface RemoteClaudeManagerDeps {
  platform: Platform
  log: LogFn
  /** Enriched agent environment (`EnvService.agentEnv()`) for local Bash execution. */
  env?: () => Promise<NodeJS.ProcessEnv> | NodeJS.ProcessEnv
  /** Optional port opener override for tests; production connects to `hostsSocket`. */
  openPort?: (hostId: string, socketPath: string) => Promise<PortChannel>
}

/**
 * Manages outbound connections from the local agent host to remote peers that offer Claude Code.
 */
export class RemoteClaudeManager {
  private hostsSocket: string | null = null
  private remoteHosts: HostStatus[] = []
  private readonly peers = new Map<string, RemoteHostPeer>()
  private readonly openingPeers = new Map<string, Promise<RemoteHostPeer>>()
  private readonly runtimes = new Map<string, Promise<AgentRuntime>>()

  constructor(private readonly deps: RemoteClaudeManagerDeps) {}

  setHostsSocket(socketPath: string | null): void {
    if (this.hostsSocket === socketPath) return
    this.hostsSocket = socketPath
    if (!socketPath) this.closeAllPeers()
  }

  setRemoteHosts(hosts: HostStatus[]): void {
    this.remoteHosts = hosts
    const online = new Set(
      hosts.filter((host) => host.connection.state === 'online').map((host) => host.id),
    )
    for (const [hostId, peer] of [...this.peers]) {
      if (!online.has(hostId)) {
        peer.close()
        this.peers.delete(hostId)
        this.runtimes.delete(hostId)
      }
    }
  }

  hostName(hostId: string): string | null {
    return this.remoteHosts.find((host) => host.id === hostId)?.name ?? null
  }

  /** Queries the model options currently advertised by `hostId`, without touching local agents. */
  async readModels(hostId: string): Promise<ConfigOption[] | null> {
    if (!this.hostsSocket) return null
    try {
      const peer = await this.getPeer(hostId)
      const status = await peer.request<RemoteClaudeStatus>(
        'remoteClaude.status',
        undefined,
        STATUS_TIMEOUT_MS,
      )
      return status.enabled && status.ready ? status.models : null
    } catch {
      return null
    }
  }

  /** Queries all currently online same-account hosts for their remote Claude Code status. */
  async listAvailableHosts(): Promise<RemoteClaudeHostInfo[]> {
    const online = this.remoteHosts.filter((host) => host.connection.state === 'online')
    if (online.length === 0 || !this.hostsSocket) return []
    const results = await Promise.all(
      online.map(async (host): Promise<RemoteClaudeHostInfo | null> => {
        try {
          const peer = await this.getPeer(host.id)
          const status = await peer.request<RemoteClaudeStatus>(
            'remoteClaude.status',
            undefined,
            STATUS_TIMEOUT_MS,
          )
          return {
            hostId: host.id,
            hostName: host.name,
            platform: host.platform,
            status,
          }
        } catch {
          return null
        }
      }),
    )
    return results.filter(
      (entry): entry is RemoteClaudeHostInfo => entry !== null && entry.status.enabled,
    )
  }

  /** Returns an `AgentRuntime` backed by `RemoteClaudeConnection` on `hostId`. */
  async ensureReady(hostId: string, agentId: AgentId): Promise<AgentRuntime> {
    if (harnessOf(agentId) !== 'claude-code') {
      throw new HostError('invalid_params', t('remoteClaude.claudeOnly'))
    }
    const existing = this.runtimes.get(hostId)
    if (existing) {
      const runtime = await existing.catch(() => null)
      if (runtime && !runtime.connection.isClosed) return runtime
      this.runtimes.delete(hostId)
    }
    const pending = this.openRuntime(hostId, agentId)
    this.runtimes.set(hostId, pending)
    try {
      return await pending
    } catch (error) {
      if (this.runtimes.get(hostId) === pending) this.runtimes.delete(hostId)
      throw error
    }
  }

  shutdown(): void {
    this.closeAllPeers()
  }

  private async openRuntime(hostId: string, agentId: AgentId): Promise<AgentRuntime> {
    const peer = await this.getPeer(hostId)
    const name = this.hostName(hostId) ?? hostId
    const connection = new RemoteClaudeConnection(
      peer,
      name,
      agentId,
      this.deps.platform,
      this.deps.log,
      this.deps.env,
    )
    const init = await connection.initialize()
    void connection.closed.then(() => {
      if (this.peers.get(hostId) === peer) this.peers.delete(hostId)
      this.runtimes.delete(hostId)
    })
    return {
      agentId,
      connection,
      init,
      sarto: true,
    }
  }

  private async getPeer(hostId: string): Promise<RemoteHostPeer> {
    const existing = this.peers.get(hostId)
    if (existing && !existing.isClosed) return existing
    const inFlight = this.openingPeers.get(hostId)
    if (inFlight) return inFlight
    const socketPath = this.hostsSocket
    if (!socketPath) throw new HostError('unavailable', t('remoteClaude.noHosts'))
    const opener = this.deps.openPort ?? ((_id: string, p: string) => connectPort(p))
    const opening = opener(hostId, socketPath)
      .then((port) => {
        const peer = new RemoteHostPeer(hostId, port, this.deps.log)
        this.peers.set(hostId, peer)
        peer.onClose(() => {
          if (this.peers.get(hostId) === peer) this.peers.delete(hostId)
          this.runtimes.delete(hostId)
        })
        return peer
      })
      .finally(() => {
        if (this.openingPeers.get(hostId) === opening) this.openingPeers.delete(hostId)
      })
    this.openingPeers.set(hostId, opening)
    return opening
  }

  private closeAllPeers(): void {
    for (const peer of this.peers.values()) peer.close()
    this.peers.clear()
    this.openingPeers.clear()
    this.runtimes.clear()
  }
}
