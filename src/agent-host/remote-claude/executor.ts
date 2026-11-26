// Local execution MCP server (`sarto_exec`) and `sarto` MCP proxy for own-account remote Claude
// Code. Runs inside the controller's agent host: enforces local path boundaries, `command-safety`
// checks, local permission approval cards, and output size limits so Relay bandwidth stays bounded.

import { spawn, type ChildProcess } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { lstat, mkdir, readdir, readFile, stat, writeFile } from 'node:fs/promises'
import path from 'node:path'
import vm from 'node:vm'
import {
  REMOTE_CLAUDE_MAX_MCP_BODY_BYTES,
  REMOTE_CLAUDE_MAX_OUTPUT_CHARS,
  type RemoteClaudeMcpAnswer,
  type RemoteClaudeMcpCall,
} from '@shared/remote-claude'
import type { Patch, ToolEntry } from '@shared/thread'
import { unsafeCommand, type Shell } from '../command-safety'
import type { PermissionAnswer, PermissionRequest } from '../connection'
import { t } from '../i18n'
import { defaultShell } from '../shell-env'
import { runGlobInWorker } from './glob-worker'
import type { WorkspaceMapper } from './workspace'

const DEFAULT_READ_LINES = 2000
const DEFAULT_BASH_TIMEOUT_MS = 120_000
const MAX_BASH_TIMEOUT_MS = 600_000
const MAX_GLOB_RESULTS = 500
const MAX_GREP_RESULTS = 200
const MAX_WALK_FILES = 10_000
/** The largest file Read and Edit take whole, and Grep searches. */
const MAX_FILE_BYTES = 8 * 1024 * 1024
/** How much Grep reads in all, and how long its pattern may take on one file. */
const MAX_GREP_TOTAL_BYTES = 64 * 1024 * 1024
const GREP_FILE_MS = 1_000
const MAX_BG_SHELLS = 8
const MAX_BG_BUFFER_CHARS = 256 * 1024
/** How long a stopped command's processes get to end before they are killed. */
const KILL_GRACE_MS = 3_000
const SKIP_DIRS = new Set(['.git', 'node_modules', '.next', 'dist', 'out'])

interface BackgroundShell {
  id: string
  command: string
  child: ChildProcess
  output: string
  done: boolean
  exitCode: number | null
}

export interface LocalExecMcpDeps {
  mapper: WorkspaceMapper | (() => WorkspaceMapper)
  hostName: string
  /** Current local permission mode (`default`, `acceptEdits`, `auto`, `plan`, `dontAsk`, `bypassPermissions`). */
  permissionMode(): string
  /** Asks the local user to approve an action on this computer. */
  requestPermission(request: PermissionRequest, signal: AbortSignal): Promise<PermissionAnswer>
  /** Shows changes to the approval cards the executor added to the session's thread. */
  apply?(patches: Patch[]): void
  /** Environment for local shell commands (enriched PATH and proxy from `EnvService.agentEnv()`). */
  env?(): NodeJS.ProcessEnv
  /** Optional local `McpService` endpoint + session token for proxying `/mcp/sarto`. */
  sartoMcp?(): { url: string; token: string } | null
  /** Optional hook notified before writing a local file (for diff capture). */
  beforeWrite?(localPath: string): Promise<void>
}

interface McpToolDef {
  name: string
  description: string
  inputSchema: Record<string, unknown>
}

const TOOL_DEFS: readonly McpToolDef[] = [
  {
    name: 'Read',
    description: 'Read a file from the local workspace with line numbers.',
    inputSchema: {
      type: 'object',
      properties: {
        file_path: { type: 'string', description: 'Absolute or workspace-relative file path.' },
        offset: { type: 'number', description: '1-based starting line number.' },
        limit: { type: 'number', description: 'Maximum number of lines to read.' },
      },
      required: ['file_path'],
    },
  },
  {
    name: 'Write',
    description: 'Write or overwrite a file in the local workspace.',
    inputSchema: {
      type: 'object',
      properties: {
        file_path: { type: 'string', description: 'Absolute or workspace-relative file path.' },
        content: { type: 'string', description: 'Full UTF-8 file contents to write.' },
      },
      required: ['file_path', 'content'],
    },
  },
  {
    name: 'Edit',
    description: 'Replace exact string occurrences in a local file.',
    inputSchema: {
      type: 'object',
      properties: {
        file_path: { type: 'string' },
        old_string: { type: 'string' },
        new_string: { type: 'string' },
        replace_all: { type: 'boolean' },
      },
      required: ['file_path', 'old_string', 'new_string'],
    },
  },
  {
    name: 'Glob',
    description: 'Find files matching a glob pattern in the local workspace.',
    inputSchema: {
      type: 'object',
      properties: {
        pattern: { type: 'string' },
        path: { type: 'string' },
      },
      required: ['pattern'],
    },
  },
  {
    name: 'Grep',
    description: 'Search file contents by regular expression in the local workspace.',
    inputSchema: {
      type: 'object',
      properties: {
        pattern: { type: 'string' },
        path: { type: 'string' },
        glob: { type: 'string' },
        output_mode: { type: 'string', enum: ['files_with_matches', 'content', 'count'] },
      },
      required: ['pattern'],
    },
  },
  {
    name: 'Bash',
    description: 'Execute a shell command on the local computer inside the project workspace.',
    inputSchema: {
      type: 'object',
      properties: {
        command: { type: 'string' },
        timeout: { type: 'number', description: 'Timeout in milliseconds (up to 600000).' },
        run_in_background: { type: 'boolean' },
        description: { type: 'string' },
      },
      required: ['command'],
    },
  },
  {
    name: 'BashOutput',
    description: 'Read buffered output from a background shell started by Bash.',
    inputSchema: {
      type: 'object',
      properties: { bash_id: { type: 'string' } },
      required: ['bash_id'],
    },
  },
  {
    name: 'KillShell',
    description: 'Terminate a background shell started by Bash.',
    inputSchema: {
      type: 'object',
      properties: { shell_id: { type: 'string' } },
      required: ['shell_id'],
    },
  },
]

function jsonRpcResponse(
  runId: string,
  callId: number,
  id: unknown,
  result: unknown,
): RemoteClaudeMcpAnswer {
  return {
    runId,
    callId,
    status: 200,
    headers: [['content-type', 'application/json']],
    body: JSON.stringify({ jsonrpc: '2.0', id, result }),
  }
}

function jsonRpcError(
  runId: string,
  callId: number,
  id: unknown,
  code: number,
  message: string,
): RemoteClaudeMcpAnswer {
  return {
    runId,
    callId,
    status: 200,
    headers: [['content-type', 'application/json']],
    body: JSON.stringify({ jsonrpc: '2.0', id, error: { code, message } }),
  }
}

/** The JSON-RPC id of a request body, to answer it with an error. */
function requestId(body: string): unknown {
  try {
    return (JSON.parse(body) as { id?: unknown }).id ?? null
  } catch {
    return null
  }
}

/** Stops a command and every process it started, killing what is left after a grace period. */
function stopTree(child: ChildProcess): void {
  const signal = (name: NodeJS.Signals): void => {
    try {
      // A negative pid addresses the process group the detached shell leads, which outlives the
      // shell while anything it started still runs.
      if (process.platform !== 'win32' && child.pid) process.kill(-child.pid, name)
      else if (child.exitCode === null && child.signalCode === null) child.kill(name)
    } catch {
      // Already gone.
    }
  }
  // Only while the shell runs is its group surely the command's, not a later one with its id.
  if (child.exitCode !== null || child.signalCode !== null) return
  signal('SIGTERM')
  setTimeout(() => signal('SIGKILL'), KILL_GRACE_MS).unref()
}

function toolText(
  text: string,
  isError = false,
): { content: { type: 'text'; text: string }[]; isError?: boolean } {
  const capped =
    text.length > REMOTE_CLAUDE_MAX_OUTPUT_CHARS
      ? `${text.slice(0, REMOTE_CLAUDE_MAX_OUTPUT_CHARS)}\n... [truncated ${text.length - REMOTE_CLAUDE_MAX_OUTPUT_CHARS} chars]`
      : text
  return { content: [{ type: 'text', text: capped }], ...(isError ? { isError: true } : {}) }
}

function globToRegExp(pattern: string): RegExp {
  let out = '^'
  for (let i = 0; i < pattern.length; i++) {
    const ch = pattern[i]!
    if (ch === '*') {
      if (pattern[i + 1] === '*') {
        if (pattern[i + 2] === '/') {
          out += '(?:.*/)?'
          i += 2
        } else {
          out += '.*'
          i += 1
        }
      } else {
        out += '[^/]*'
      }
    } else if (ch === '?') {
      out += '[^/]'
    } else if ('.+^$()|[]\\{}'.includes(ch)) {
      out += `\\${ch}`
    } else {
      out += ch
    }
  }
  return new RegExp(`${out}$`)
}

export class LocalExecMcp {
  private readonly shells = new Map<string, BackgroundShell>()
  /** Commands running in the foreground, stopped with the session. */
  private readonly running = new Set<ChildProcess>()
  private nextShellId = 1
  private closed = false

  constructor(private readonly deps: LocalExecMcpDeps) {}

  private get shellKind(): Shell {
    return this.mapper.localPlatform === 'win32' ? 'powershell' : 'posix'
  }

  private get mapper(): WorkspaceMapper {
    return typeof this.deps.mapper === 'function' ? this.deps.mapper() : this.deps.mapper
  }

  /** Handles one reverse MCP HTTP call forwarded from the remote model host. */
  async handle(call: RemoteClaudeMcpCall): Promise<RemoteClaudeMcpAnswer> {
    const answer = await this.answer(call)
    // The model host refuses a larger answer, which would leave its call waiting for one.
    if (Buffer.byteLength(answer.body, 'utf8') <= REMOTE_CLAUDE_MAX_MCP_BODY_BYTES) return answer
    return jsonRpcError(
      call.runId,
      call.callId,
      requestId(call.body),
      -32000,
      `The answer is larger than ${REMOTE_CLAUDE_MAX_MCP_BODY_BYTES} bytes.`,
    )
  }

  private async answer(call: RemoteClaudeMcpCall): Promise<RemoteClaudeMcpAnswer> {
    if (this.closed) {
      return jsonRpcError(call.runId, call.callId, null, -32000, 'Local executor closed.')
    }
    if (call.server === 'sarto') {
      return this.forwardSartoMcp(call)
    }
    let parsed: { jsonrpc?: unknown; id?: unknown; method?: unknown; params?: unknown }
    try {
      parsed = JSON.parse(call.body) as typeof parsed
    } catch {
      return jsonRpcError(call.runId, call.callId, null, -32700, 'Invalid JSON')
    }
    const id = parsed.id ?? null
    const method = typeof parsed.method === 'string' ? parsed.method : ''
    if (method === 'initialize') {
      return jsonRpcResponse(call.runId, call.callId, id, {
        protocolVersion: '2025-03-26',
        capabilities: { tools: {} },
        serverInfo: { name: 'sarto_exec', version: '1.0.0' },
      })
    }
    if (method === 'notifications/initialized' || method === 'ping') {
      return jsonRpcResponse(call.runId, call.callId, id, {})
    }
    if (method === 'tools/list') {
      return jsonRpcResponse(call.runId, call.callId, id, { tools: TOOL_DEFS })
    }
    if (method === 'tools/call') {
      const params = (parsed.params ?? {}) as { name?: unknown; arguments?: unknown }
      const name = typeof params.name === 'string' ? params.name : ''
      const args =
        params.arguments && typeof params.arguments === 'object' && !Array.isArray(params.arguments)
          ? (params.arguments as Record<string, unknown>)
          : {}
      const result = await this.callTool(name, args)
      return jsonRpcResponse(call.runId, call.callId, id, result)
    }
    return jsonRpcError(call.runId, call.callId, id, -32601, `Unknown method: ${method}`)
  }

  /** Stops every command still running when the local session closes. */
  close(): void {
    this.closed = true
    for (const shell of this.shells.values()) stopTree(shell.child)
    this.shells.clear()
    for (const child of this.running) stopTree(child)
    this.running.clear()
  }

  private async forwardSartoMcp(call: RemoteClaudeMcpCall): Promise<RemoteClaudeMcpAnswer> {
    const target = this.deps.sartoMcp?.()
    if (!target) {
      return {
        runId: call.runId,
        callId: call.callId,
        status: 404,
        headers: [['content-type', 'application/json']],
        body: JSON.stringify({ error: 'Sarto MCP server is unavailable for this session.' }),
      }
    }
    try {
      // Drop untrusted remote headers/queries; bind strictly to this session's own local token.
      const res = await fetch(target.url, {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          accept: 'application/json, text/event-stream',
          authorization: `Bearer ${target.token}`,
        },
        body: call.body,
      })
      const body = await res.text()
      return {
        runId: call.runId,
        callId: call.callId,
        status: res.status,
        headers: [['content-type', res.headers.get('content-type') ?? 'application/json']],
        body,
      }
    } catch {
      return {
        runId: call.runId,
        callId: call.callId,
        status: 502,
        headers: [['content-type', 'application/json']],
        body: JSON.stringify({ error: 'Could not reach local Sarto MCP server.' }),
      }
    }
  }

  private async callTool(
    name: string,
    args: Record<string, unknown>,
  ): Promise<{ content: { type: 'text'; text: string }[]; isError?: boolean }> {
    try {
      switch (name) {
        case 'Read':
          return await this.runRead(args)
        case 'Write':
          return await this.runWrite(args)
        case 'Edit':
          return await this.runEdit(args)
        case 'Glob':
          return await this.runGlob(args)
        case 'Grep':
          return await this.runGrep(args)
        case 'Bash':
          return await this.runBash(args)
        case 'BashOutput':
          return this.runBashOutput(args)
        case 'KillShell':
          return this.runKillShell(args)
        default:
          return toolText(`Unknown tool: ${name}`, true)
      }
    } catch (error) {
      return toolText(error instanceof Error ? error.message : String(error), true)
    }
  }

  private async authorize(action: {
    kind: 'read' | 'edit' | 'execute'
    title: string
    detail: string
    insideWorkspace: boolean
    command?: string
  }): Promise<boolean> {
    const mode = this.deps.permissionMode()
    if (mode === 'plan' && action.kind !== 'read') return false
    if (action.kind === 'read' && action.insideWorkspace) return true
    if (mode === 'bypassPermissions') return true
    if (
      action.kind === 'edit' &&
      action.insideWorkspace &&
      (mode === 'acceptEdits' || mode === 'auto')
    ) {
      return true
    }
    if (
      action.kind === 'execute' &&
      action.insideWorkspace &&
      mode === 'auto' &&
      action.command &&
      !unsafeCommand(action.command, this.shellKind)
    ) {
      return true
    }
    // Don't ask refuses what no rule allows rather than asking.
    if (mode === 'dontAsk') return false

    // Unique in the thread, which keeps the cards of earlier runs of the session.
    const id = `rce-${randomUUID()}`
    const toolEntry: ToolEntry = {
      id,
      kind: 'tool',
      title: t('remoteClaude.card.title', { action: action.title, host: this.deps.hostName }),
      toolKind: action.kind,
      status: 'in_progress',
      content: [],
      locations: [],
      permission: null,
      permissionResult: null,
      rawInput: action.detail,
      description: t('remoteClaude.card.requested', { host: this.deps.hostName }),
    }
    const abort = new AbortController()
    const answer = await this.deps.requestPermission(
      {
        toolCallId: id,
        toolEntryId: id,
        output: { patches: [{ op: 'entry.add', entry: toolEntry }], effects: [] },
        options: [
          { id: 'allow_once', name: t('permission.allowOnce'), kind: 'allow_once' },
          { id: 'reject_once', name: t('remoteClaude.card.deny'), kind: 'reject_once' },
        ],
        ...(action.kind === 'execute' ? { shell: this.shellKind } : {}),
      },
      abort.signal,
    )
    const allowed =
      answer !== 'cancelled' && 'optionId' in answer && answer.optionId === 'allow_once'
    // The card stands for the approval; the remote tool call's own card shows the work.
    this.deps.apply?.([
      { op: 'entry.update', id, changes: { status: allowed ? 'completed' : 'failed' } },
    ])
    return allowed
  }

  /** Reads a file that is small enough to take whole. */
  private async readWhole(localPath: string): Promise<string> {
    const info = await stat(localPath)
    if (info.size > MAX_FILE_BYTES) {
      throw new Error(`File is larger than ${MAX_FILE_BYTES} bytes; use Grep or Bash on it.`)
    }
    return readFile(localPath, 'utf8')
  }

  private async runRead(args: Record<string, unknown>) {
    const rawPath = typeof args.file_path === 'string' ? args.file_path : ''
    if (!rawPath) return toolText('file_path is required', true)
    const localPath = this.mapper.toLocalPath(rawPath)
    const inside = await this.mapper.isInsideLocalRoot(localPath)
    if (
      !(await this.authorize({
        kind: 'read',
        title: t('remoteClaude.card.read', { name: path.basename(localPath) }),
        detail: localPath,
        insideWorkspace: inside,
      }))
    ) {
      return toolText(`Permission denied reading ${localPath}`, true)
    }
    const text = await this.readWhole(localPath)
    const lines = text.split('\n')
    const offset =
      typeof args.offset === 'number' && Number.isFinite(args.offset) && args.offset >= 1
        ? Math.floor(args.offset)
        : 1
    const limit =
      typeof args.limit === 'number' && Number.isFinite(args.limit) && args.limit >= 1
        ? Math.min(Math.floor(args.limit), DEFAULT_READ_LINES)
        : DEFAULT_READ_LINES
    const slice = lines.slice(offset - 1, offset - 1 + limit)
    const numbered = slice
      .map((line, i) => `${String(offset + i).padStart(6, ' ')}\t${line}`)
      .join('\n')
    return toolText(numbered)
  }

  private async runWrite(args: Record<string, unknown>) {
    const rawPath = typeof args.file_path === 'string' ? args.file_path : ''
    const content = typeof args.content === 'string' ? args.content : null
    if (!rawPath || content === null) return toolText('file_path and content are required', true)
    const localPath = this.mapper.toLocalPath(rawPath)
    const inside = await this.mapper.isInsideLocalRoot(localPath)
    if (
      !(await this.authorize({
        kind: 'edit',
        title: t('remoteClaude.card.write', { name: path.basename(localPath) }),
        detail: localPath,
        insideWorkspace: inside,
      }))
    ) {
      return toolText(`Permission denied writing ${localPath}`, true)
    }
    await this.deps.beforeWrite?.(localPath)
    await mkdir(path.dirname(localPath), { recursive: true })
    await writeFile(localPath, content, 'utf8')
    return toolText(
      `Wrote ${Buffer.byteLength(content, 'utf8')} bytes to ${this.mapper.toRemoteText(localPath)}`,
    )
  }

  private async runEdit(args: Record<string, unknown>) {
    const rawPath = typeof args.file_path === 'string' ? args.file_path : ''
    const oldStr = typeof args.old_string === 'string' ? args.old_string : null
    const newStr = typeof args.new_string === 'string' ? args.new_string : null
    if (!rawPath || oldStr === null || newStr === null || oldStr.length === 0) {
      return toolText('file_path, non-empty old_string, and new_string are required', true)
    }
    const localPath = this.mapper.toLocalPath(rawPath)
    const inside = await this.mapper.isInsideLocalRoot(localPath)
    if (
      !(await this.authorize({
        kind: 'edit',
        title: t('remoteClaude.card.edit', { name: path.basename(localPath) }),
        detail: localPath,
        insideWorkspace: inside,
      }))
    ) {
      return toolText(`Permission denied editing ${localPath}`, true)
    }
    const current = await this.readWhole(localPath)
    const parts = current.split(oldStr)
    const count = parts.length - 1
    if (count === 0) return toolText('old_string was not found in file', true)
    const replaceAll = args.replace_all === true
    if (!replaceAll && count > 1) {
      return toolText(
        `old_string matched ${count} times; provide more context or set replace_all: true`,
        true,
      )
    }
    // Joined, not `replace`d, so `$&` and the like in new_string stay as written.
    const updated = parts.join(newStr)
    await this.deps.beforeWrite?.(localPath)
    await writeFile(localPath, updated, 'utf8')
    return toolText(
      `Updated ${this.mapper.toRemoteText(localPath)} (${replaceAll ? count : 1} replacement)`,
    )
  }

  private async runGlob(args: Record<string, unknown>) {
    const pattern = typeof args.pattern === 'string' ? args.pattern : ''
    if (!pattern) return toolText('pattern is required', true)
    const base =
      typeof args.path === 'string' && args.path.trim()
        ? this.mapper.toLocalPath(args.path)
        : this.mapper.localRoot
    const inside = await this.mapper.isInsideLocalRoot(base)
    if (
      !(await this.authorize({
        kind: 'read',
        title: t('remoteClaude.card.glob', { pattern }),
        detail: base,
        insideWorkspace: inside,
      }))
    ) {
      return toolText(`Permission denied searching ${base}`, true)
    }
    const regex = globToRegExp(pattern.replaceAll('\\', '/'))
    const localMatches = await runGlobInWorker({
      base,
      patternSource: regex.source,
      maxResults: MAX_GLOB_RESULTS,
      maxWalk: MAX_WALK_FILES,
      skipDirs: [...SKIP_DIRS],
    })
    const matches = localMatches.map((abs) => this.mapper.toRemoteText(abs))
    return toolText(matches.length > 0 ? matches.join('\n') : 'No files matched.')
  }

  private async runGrep(args: Record<string, unknown>) {
    const pattern = typeof args.pattern === 'string' ? args.pattern : ''
    if (!pattern) return toolText('pattern is required', true)
    const target =
      typeof args.path === 'string' && args.path.trim()
        ? this.mapper.toLocalPath(args.path)
        : this.mapper.localRoot
    const inside = await this.mapper.isInsideLocalRoot(target)
    if (
      !(await this.authorize({
        kind: 'read',
        title: t('remoteClaude.card.grep', { pattern }),
        detail: target,
        insideWorkspace: inside,
      }))
    ) {
      return toolText(`Permission denied searching ${target}`, true)
    }
    let regex: RegExp
    try {
      regex = new RegExp(pattern)
    } catch (error) {
      return toolText(`Invalid regex: ${(error as Error).message}`, true)
    }
    const fileGlob = typeof args.glob === 'string' && args.glob ? globToRegExp(args.glob) : null
    const mode = typeof args.output_mode === 'string' ? args.output_mode : 'files_with_matches'
    const results: string[] = []
    let visited = 0
    let readBytes = 0
    // The model's pattern runs with a time limit, so one that backtracks without end cannot hold
    // the agent host and every session it serves.
    const sandbox = vm.createContext({ regex, lines: [] as string[], hits: [] as number[] })
    const match = new vm.Script(
      'hits = []; for (let i = 0; i < lines.length; i++) if (regex.test(lines[i])) hits.push(i)',
    )

    const scanFile = async (abs: string, rel: string): Promise<void> => {
      if (results.length >= MAX_GREP_RESULTS || readBytes >= MAX_GREP_TOTAL_BYTES) return
      if (fileGlob && !fileGlob.test(rel) && !fileGlob.test(path.basename(abs))) return
      // Not through a link: one inside the project may lead to a key outside it.
      const info = await lstat(abs).catch(() => null)
      if (!info || !info.isFile() || info.size > 1024 * 1024) return
      readBytes += info.size
      const text = await readFile(abs, 'utf8').catch(() => null)
      if (text === null || text.includes('\0')) return
      const lines = text.split('\n')
      sandbox.lines = lines
      match.runInContext(sandbox, { timeout: GREP_FILE_MS })
      const hits = sandbox.hits as number[]
      const count = hits.length
      if (mode === 'content') {
        for (const i of hits) {
          results.push(`${this.mapper.toRemoteText(abs)}:${i + 1}:${lines[i]}`)
          if (results.length >= MAX_GREP_RESULTS) return
        }
      }
      if (count > 0) {
        if (mode === 'files_with_matches') results.push(this.mapper.toRemoteText(abs))
        else if (mode === 'count') results.push(`${this.mapper.toRemoteText(abs)}:${count}`)
      }
    }

    const rootInfo = await stat(target).catch(() => null)
    if (!rootInfo) return toolText(`Path not found: ${target}`, true)
    try {
      if (rootInfo.isFile()) {
        await scanFile(target, path.basename(target))
      } else {
        const walk = async (dir: string, prefix: string): Promise<void> => {
          if (results.length >= MAX_GREP_RESULTS || visited >= MAX_WALK_FILES) return
          const entries = await readdir(dir, { withFileTypes: true }).catch(() => [])
          for (const entry of entries) {
            if (results.length >= MAX_GREP_RESULTS || visited >= MAX_WALK_FILES) return
            if (entry.isDirectory() && SKIP_DIRS.has(entry.name)) continue
            if (entry.isSymbolicLink()) continue
            visited += 1
            const rel = prefix ? `${prefix}/${entry.name}` : entry.name
            const abs = path.join(dir, entry.name)
            if (entry.isDirectory()) await walk(abs, rel)
            else await scanFile(abs, rel)
          }
        }
        await walk(target, '')
      }
    } catch (error) {
      if ((error as { code?: string }).code !== 'ERR_SCRIPT_EXECUTION_TIMEOUT') throw error
      return toolText(`The pattern took longer than ${GREP_FILE_MS} ms on one file.`, true)
    }
    return toolText(results.length > 0 ? results.join('\n') : 'No matches found.')
  }

  private async runBash(args: Record<string, unknown>) {
    const rawCommand = typeof args.command === 'string' ? args.command : ''
    if (!rawCommand.trim()) return toolText('command is required', true)
    const command = this.mapper.toLocalText(rawCommand)
    const description =
      typeof args.description === 'string' ? args.description : command.slice(0, 80)
    if (
      !(await this.authorize({
        kind: 'execute',
        title: t('remoteClaude.card.bash', { description }),
        detail: command,
        // It runs in the project's folder; what it reaches is for command safety to judge.
        insideWorkspace: true,
        command,
      }))
    ) {
      return toolText('Permission denied running command on the local computer.', true)
    }
    const timeoutMs =
      typeof args.timeout === 'number' && Number.isFinite(args.timeout) && args.timeout > 0
        ? Math.min(Math.floor(args.timeout), MAX_BASH_TIMEOUT_MS)
        : DEFAULT_BASH_TIMEOUT_MS
    if (args.run_in_background === true) {
      const live = [...this.shells.values()].filter((shell) => !shell.done).length
      if (live >= MAX_BG_SHELLS) {
        return toolText(`Background shell limit (${MAX_BG_SHELLS}) reached.`, true)
      }
      const id = `sh-${this.nextShellId++}`
      const child = this.spawnShell(command)
      const entry: BackgroundShell = {
        id,
        command,
        child,
        output: '',
        done: false,
        exitCode: null,
      }
      const append = (chunk: Buffer): void => {
        entry.output += chunk.toString('utf8')
        if (entry.output.length > MAX_BG_BUFFER_CHARS) {
          entry.output = entry.output.slice(-MAX_BG_BUFFER_CHARS)
        }
      }
      child.stdout?.on('data', append)
      child.stderr?.on('data', append)
      // Without a listener, a shell that cannot start would take the agent host down with it.
      child.on('error', (error) => {
        entry.output += `\nFailed to start shell: ${error.message}`
        entry.done = true
      })
      child.on('close', (code) => {
        entry.done = true
        entry.exitCode = code
      })
      this.shells.set(id, entry)
      return toolText(`Started background shell ${id}`)
    }

    return await new Promise<{ content: { type: 'text'; text: string }[]; isError?: boolean }>(
      (resolve) => {
        const child = this.spawnShell(command)
        this.running.add(child)
        let stdout = ''
        let stderr = ''
        let timedOut = false
        const cap = (buf: string, chunk: Buffer): string => {
          if (buf.length >= REMOTE_CLAUDE_MAX_OUTPUT_CHARS) return buf
          return buf + chunk.toString('utf8')
        }
        child.stdout?.on('data', (chunk: Buffer) => {
          stdout = cap(stdout, chunk)
        })
        child.stderr?.on('data', (chunk: Buffer) => {
          stderr = cap(stderr, chunk)
        })
        const timer = setTimeout(() => {
          timedOut = true
          stopTree(child)
        }, timeoutMs)
        timer.unref()
        child.on('error', (error) => {
          clearTimeout(timer)
          this.running.delete(child)
          resolve(toolText(`Failed to start shell: ${error.message}`, true))
        })
        child.on('close', (code) => {
          clearTimeout(timer)
          this.running.delete(child)
          const combined = [stdout, stderr].filter(Boolean).join('\n')
          const projected = this.mapper.toRemoteText(combined)
          if (timedOut) {
            resolve(toolText(`Command timed out after ${timeoutMs}ms.\n${projected}`, true))
            return
          }
          const header = code === 0 ? '' : `Exit code ${code ?? 'signal'}\n`
          resolve(toolText(`${header}${projected}` || '(no output)', code !== 0))
        })
      },
    )
  }

  /** The user's shell, in the project's folder, as its own process group to stop it whole. */
  private spawnShell(command: string): ChildProcess {
    const isWin = this.mapper.localPlatform === 'win32'
    const env = this.deps.env?.() ?? process.env
    const shell = isWin ? 'powershell.exe' : defaultShell(this.mapper.localPlatform, env)
    const args = isWin ? ['-NoProfile', '-Command', command] : ['-lc', command]
    return spawn(shell, args, {
      cwd: this.mapper.localRoot,
      env,
      stdio: ['ignore', 'pipe', 'pipe'],
      detached: !isWin,
      windowsHide: true,
    })
  }

  private runBashOutput(args: Record<string, unknown>) {
    const id = typeof args.bash_id === 'string' ? args.bash_id : ''
    const shell = this.shells.get(id)
    if (!shell) return toolText(`No background shell with id ${id}`, true)
    const out = this.mapper.toRemoteText(shell.output)
    shell.output = ''
    const status = shell.done ? `completed (exit ${shell.exitCode ?? 'signal'})` : 'running'
    // Its last output is read, so a finished shell no longer takes a place.
    if (shell.done) this.shells.delete(id)
    return toolText(`[${status}]\n${out}`)
  }

  private runKillShell(args: Record<string, unknown>) {
    const id = typeof args.shell_id === 'string' ? args.shell_id : ''
    const shell = this.shells.get(id)
    if (!shell) return toolText(`No background shell with id ${id}`, true)
    stopTree(shell.child)
    this.shells.delete(id)
    return toolText(`Killed shell ${id}`)
  }
}
