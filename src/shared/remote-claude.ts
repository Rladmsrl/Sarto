// Own-account remote Claude Code: a local session runs its Claude Code process on another
// computer of the same Sarto account while keeping project files, shell commands, permissions and
// Sarto MCP tools on the local computer.

import type { Platform } from './platform'
import type {
  AgentId,
  ConfigOption,
  FormValues,
  PendingElicitation,
  PendingPermission,
  PendingQuestion,
  QuestionAnswer,
  StopReason,
  TokenTotals,
} from './thread'

/** Host-side settings controlling whether other computers of the same account may use Claude Code. */
export interface RemoteClaudeSettings {
  /** Off by default: the owner must opt in before other devices may start hosted Claude runs. */
  enabled: boolean
  /** Maximum concurrent hosted Claude Code runs allowed on this computer. */
  maxConcurrent: number
  /** Minutes of inactivity before a hosted Claude Code process is reclaimed (session can resume). */
  idleMinutes: number
}

export const REMOTE_CLAUDE_MIN_CONCURRENT = 1
export const REMOTE_CLAUDE_MAX_CONCURRENT = 8
export const REMOTE_CLAUDE_MIN_IDLE_MINUTES = 1
export const REMOTE_CLAUDE_MAX_IDLE_MINUTES = 60

export const DEFAULT_REMOTE_CLAUDE_SETTINGS: RemoteClaudeSettings = {
  enabled: false,
  maxConcurrent: 3,
  idleMinutes: 10,
}

/** Identifies the remote computer running Claude Code for a local session. */
export interface ModelHostRef {
  hostId: string
  hostName: string
}

/** Snapshot file copied from the local project into the remote shadow workspace (e.g. CLAUDE.md). */
export interface RemoteClaudeSnapshotFile {
  relativePath: string
  content: string
}

export const REMOTE_CLAUDE_MAX_SNAPSHOT_FILES = 32
export const REMOTE_CLAUDE_MAX_SNAPSHOT_FILE_BYTES = 128 * 1024
export const REMOTE_CLAUDE_MAX_SNAPSHOT_TOTAL_BYTES = 512 * 1024
export const REMOTE_CLAUDE_MAX_MCP_BODY_BYTES = 4 * 1024 * 1024
export const REMOTE_CLAUDE_MAX_OUTPUT_CHARS = 128 * 1024

/**
 * The only built-in tools a hosted Claude Code process has: none of them reads, writes or runs
 * anything on the model host. Files and commands go through `sarto_exec` on the controller.
 */
export const HOSTED_CLAUDE_TOOLS = [
  'AskUserQuestion',
  'EnterPlanMode',
  'ExitPlanMode',
  'TodoWrite',
  'TaskCreate',
  'TaskGet',
  'TaskList',
  'TaskUpdate',
  'ToolSearch',
  'WebSearch',
] as const

/** Built-in tools also refused by name, should a Claude Code version not honor the list above. */
export const HOSTED_CLAUDE_DISALLOWED_TOOLS = [
  'Agent',
  'Task',
  'Bash',
  'BashOutput',
  'KillShell',
  'PowerShell',
  'Monitor',
  'TaskOutput',
  'TaskStop',
  'Read',
  'Write',
  'Edit',
  'MultiEdit',
  'Glob',
  'Grep',
  'LSP',
  'NotebookEdit',
  'WebFetch',
  'Skill',
  'SlashCommand',
  'CronCreate',
  'CronDelete',
  'CronList',
  'ListMcpResourcesTool',
  'ReadMcpResourceTool',
  'EnterWorktree',
  'ExitWorktree',
] as const

/** Name of the local execution MCP server exposed through the per-run loopback tunnel. */
export const REMOTE_CLAUDE_EXEC_MCP = 'sarto_exec'

/** Tools provided by `sarto_exec` on the local computer. */
export const REMOTE_CLAUDE_EXEC_TOOLS = [
  'Read',
  'Write',
  'Edit',
  'Glob',
  'Grep',
  'Bash',
  'BashOutput',
  'KillShell',
] as const

/** A content block forwarded across the remote Claude prompt RPC. */
export type RemoteClaudePromptBlock =
  | { type: 'text'; text: string }
  | { type: 'image'; mimeType: string; data: string; uri?: string }
  | { type: 'resource_link'; uri: string; name: string; mimeType?: string; size?: number }
  | { type: 'resource'; resource: { uri: string; mimeType: string; text: string } }

/** Availability reported by a remote host's `remoteClaude.status`. */
export interface RemoteClaudeStatus {
  enabled: boolean
  ready: boolean
  authRequired: boolean
  accountLabel: string | null
  models: ConfigOption[]
  activeRuns: number
  maxConcurrent: number
  error: string | null
}

/** Aggregated entry returned by local `remoteClaude.hosts` for the desktop UI. */
export interface RemoteClaudeHostInfo {
  hostId: string
  hostName: string
  platform: Platform
  status: RemoteClaudeStatus
}

/** Summary of an active hosted run on this computer (for Settings and Disconnect All). */
export interface RemoteClaudeActiveRun {
  runId: string
  deviceId: string
  deviceName: string
  startedAt: number
  lastActiveAt: number
}

export interface RemoteClaudeOpenParams {
  runId: string
  sessionId: string
  agentId: AgentId
  resumeSessionId?: string
  localProjectPath: string
  localPlatform: Platform
  snapshotFiles?: RemoteClaudeSnapshotFile[]
  sartoMcp?: boolean
  sartoAutoAllow?: string[]
  sartoPrompt?: string
  memoryText?: string
  suggestions?: boolean
  hidden?: boolean
  options?: Record<string, string | boolean>
}

export interface RemoteClaudeOpenResult {
  runId: string
  acpSessionId: string
  virtualRoot: string
  remotePlatform: Platform
  config: ConfigOption[]
  harnessVersion?: string
}

export interface RemoteClaudePromptParams {
  runId: string
  prompt: RemoteClaudePromptBlock[]
}

export interface RemoteClaudePromptResult {
  stopReason: StopReason
  tokens: TokenTotals | null
  models: { model: string; tokens: TokenTotals }[]
  promptRef?: string
}

export interface RemoteClaudeSetConfigParams {
  runId: string
  optionId: string
  value: string | boolean
}

export interface RemoteClaudeMcpCall {
  runId: string
  callId: number
  server: 'sarto_exec' | 'sarto'
  headers: [string, string][]
  body: string
}

export interface RemoteClaudeMcpAnswer {
  runId: string
  callId: number
  status: number
  headers: [string, string][]
  body: string
}

export interface RemoteClaudePermissionRequest {
  runId: string
  requestId: string
  toolCallId: string
  toolEntryId: string
  options: PendingPermission['options']
  questions?: PendingQuestion[]
  plan?: string
  elicitation?: PendingElicitation
  nonBlocking?: true
  patches: unknown[]
  effects: unknown[]
}

export type RemoteClaudePermissionReply =
  | { optionId: string; note?: string }
  | { answers: QuestionAnswer[] }
  | { values: FormValues }
  | 'cancelled'

export interface RemoteClaudePermissionAnswer {
  runId: string
  requestId: string
  answer: RemoteClaudePermissionReply
}

export interface RemoteClaudeOutputEvent {
  runId: string
  patches: unknown[]
  effects: unknown[]
}

export type RemoteClaudeCloseReason =
  'closed' | 'idle_reclaimed' | 'disabled' | 'disconnected' | 'error'

export interface RemoteClaudeClosedEvent {
  runId: string
  reason: RemoteClaudeCloseReason
  message?: string
}

export function isRemoteClaudeSettings(value: unknown): value is RemoteClaudeSettings {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return false
  const { enabled, maxConcurrent, idleMinutes } = value as Record<string, unknown>
  return (
    typeof enabled === 'boolean' &&
    typeof maxConcurrent === 'number' &&
    Number.isSafeInteger(maxConcurrent) &&
    maxConcurrent >= REMOTE_CLAUDE_MIN_CONCURRENT &&
    maxConcurrent <= REMOTE_CLAUDE_MAX_CONCURRENT &&
    typeof idleMinutes === 'number' &&
    Number.isSafeInteger(idleMinutes) &&
    idleMinutes >= REMOTE_CLAUDE_MIN_IDLE_MINUTES &&
    idleMinutes <= REMOTE_CLAUDE_MAX_IDLE_MINUTES
  )
}
