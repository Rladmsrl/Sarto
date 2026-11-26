// The agent host, assembled: state, agents, sessions, git and the ports. start.ts runs it in
// the utility process or under Node.js; tests run it in-process with fakes for the launcher,
// shell and git.

import { DEVICE_ACCESS_WAIT_MS, type DeviceCall, type DeviceCallAnswer } from '@shared/device-agent'
import {
  replyRunNotice,
  type TerminalCall,
  type TerminalCallAnswer,
  type TerminalCallErrorCode,
} from '@shared/terminal-agent'
import { DeviceAccessStore } from './devices/access'
import os from 'node:os'
import path from 'node:path'
import { mkdir } from 'node:fs/promises'
import type {
  AgentOptions,
  AgentStatus,
  AppUpdateStatus,
  DiagnosticsBundle,
  HostEvent,
  HostParams,
  McpStatus,
} from '@shared/agent-host'
import { flushLog, logFolder, redactLogText, writeLog } from '@shared/log/process-log'
import { writeReport } from '@shared/log/report-bundle'
import { parseReportRequest } from '@shared/report'
import { harnessOf, takesStartMode, type HarnessId } from '@shared/agents'
import type { AttachmentGrant } from '@shared/attachments'
import {
  siteOf,
  type BrowserCallAnswer,
  type BrowserCallRequest,
  type BrowserOriginAnswer,
} from '@shared/browser'
import { isControlOutcome, isControlStep, SURFACE_ACCESS_WAIT_MS } from '@shared/control'
import type {
  AgentProcess,
  AttentionFront,
  ComputerControlAction,
  HostToMain,
  MainToHost,
  NodeRuntime,
  ReportBuildResult,
  SettingFacts,
  SettingsCall,
  SettingsCallAnswer,
  SettingsSnapshot,
} from '@shared/host-control'
import type { ComputerFrame } from '@shared/computer-use'
import type { Platform } from '@shared/platform'
import type { PortChannel } from '@shared/port-channel'
import type { FromPort, PortErrorCode } from '@shared/port-rpc'
import { isRemoteDevice, type PortDevice } from '@shared/remote/device'
import type { MemorySource } from '@shared/memory'
import type { HostSettings } from '@shared/settings'
import { serverFor, type MarketConnection, type MarketServer } from '@shared/marketplace'
import { HARNESSES_FOLDER, SARTO_HOME_FOLDER } from '@shared/storage'
import type {
  SyncedAgentPlanReading,
  SyncedHostUsageSection,
  SyncedUsageSelf,
} from '@shared/sync/protocol'
import type {
  AgentId,
  DigestedThreadEntry,
  FromDevice,
  ThreadEntry,
  UserContent,
} from '@shared/thread'
import { AgentFiles } from './agent-files'
import { agentOptionsFile, AgentOptionsStore, startModeIn } from './agent-options'
import { clearFlagSettings, flagSettingsFolder } from './claude/flag-settings'
import { listedModels } from './claude/user-settings'
import { STOP_TIMINGS } from './agent-process'
import { AgentTrees } from './agent-trees'
import { McpService, SERVICE_NAME } from './mcp-service'
import {
  AgentManager,
  processLauncher,
  type AgentLauncher,
  type AgentManagerDeps,
  type AgentTimings,
} from './agents'
import { buildCatalog, configFolders, type AgentDefinition } from './catalog'
import {
  answerOf,
  BROWSER_GONE,
  browserTarget,
  DeviceBrowserCalls,
  type BrowserTarget,
} from './device-browser'
import { BrowserTurns } from './browser-turns'
import { writeCommitMessage } from './commit-message'
import { writePullRequestDraft } from './pull-request-draft'
import { lightTarget } from './light-model'
import { reportDraftPrompt, writeReportDraft } from './report-draft'
import { Diagnostics } from './diagnostics'
import { HostError } from './errors'
import { setLocale, t, tSettings, tSettingsEnglish } from './i18n'
import { FilesService } from './files'
import { FilesWatches } from './files-watch'
import { HtmlPreviews } from './html-preview'
import { MediaService } from './media'
import { MemoryError, type MemoryErrorCode } from './memory/errors'
import { MemoryService } from './memory/service'
import { catalogFile, MarketCatalogService } from './marketplace/catalog'
import { MarketConnectionsService } from './marketplace/connections'
import { logText } from './localized-error'
import { parseSignIns } from './marketplace/oauth'
import { McpProxy } from './marketplace/proxy'
import type { CodexRequest } from './marketplace/codex-plugins'
import { MarketPluginsService, pluginsFile } from './marketplace/plugins'
import { MarketSkillsService, skillFor, skillsCatalogFile } from './marketplace/skills'
import {
  SETTINGS_WAIT_MS,
  SettingsTools,
  StaleUndo,
  type LocalFacts,
  type SettingsTarget,
} from './settings/tools'
import {
  ALL_TRANSPORTS,
  keyState,
  libraryServers,
  parseMarketKeys,
  serverHeaders,
  type MarketKeys,
} from './marketplace/servers'
import type { Env } from './find-command'
import type { GitServiceApi, GitServiceDeps } from './git/api'
import { createExec, type ExecRunner } from './git/exec'
import { proxyFetch } from './proxy-fetch'
import { GitRetains } from './git/retains'
import type { SkillsListResponse } from './codex/protocol'
import { completePath } from './path-completion'
import { pathKey } from './paths'
import { PreparedRecords, preparedFile, settingsTargets } from './prepared'
import { processControl, type ProcessControl } from './process-tree'
import { ProjectHooksAnswers } from './project-hooks'
import { ProjectMcpAnswers } from './project-mcp'
import { Projects } from './projects'
import { RemoteClaudeManager } from './remote-claude/client'
import { RemoteClaudeHost } from './remote-claude/host'
import { clearShadowWorkspaces } from './remote-claude/shadow'
import { WorkFactTracker } from './work-facts'
import { claudeOutside, type OutsideReader } from './outside-sessions'
import { claudeCacheTtl, type CacheTtlReader } from './prompt-cache'
import { antigravityModelRequests } from './model-requests/antigravity'
import { shutdownAgySqliteWorker } from './acp/agy-sqlite-worker'
import { claudeModelRequests } from './model-requests/claude'
import { clineModelRequests } from './model-requests/cline'
import { codexModelRequests } from './model-requests/codex'
import { opencodeModelRequests } from './model-requests/opencode'
import { byHarness } from './model-requests/reader'
import { AcpMessages, acpModelRequests } from './model-requests/acp-messages'
import { IdleRelease } from './idle-release'
import { LoadMonitor } from './load/monitor'
import { SystemReader } from './load/system'
import { PortHub, type Handlers, type RequestContext } from './rpc'
import { Attachments } from './attachments'
import { ScratchFolders } from './scratch'
import { createWorktreeGit } from './worktrees/git'
import { WorktreeManager } from './worktrees/manager'
import { ComputerDriver, probePermissions } from './computer/driver'
import { ComputerUse } from './computer/service'
import { SessionFiles } from './session-files'
import { SessionManager, type SessionTimings } from './sessions'
import { EnvironmentService, type EnvironmentServiceDeps } from './shell-env'
import {
  agentProcessesFile,
  agentsFile,
  agentUpdatesFile,
  projectsFile,
  projectHooksFile,
  projectMcpFile,
  registryListingFile,
  harnessManifestFile,
  returnedFile,
  sessionsFile,
  type AgentsFile,
  type AgentUpdatesFile,
  type JsonFile,
  type RegistryListingFile,
  type HarnessManifestFile,
} from './storage'
import { digestEntries, fitSingleEntry } from './threads/digest'
import {
  REMOTE_ENTRY_BYTES,
  REMOTE_PAGE_BYTES,
  type ImageMode,
  type PageBudget,
} from './threads/model'
import { ThreadStore, type ThreadWorkerFactory } from './threads/store'
import { forgottenAccountsFile } from './usage/forgotten'
import { UsageManager, type AgentPlan, type UsageTimings } from './usage/manager'
import { accountFingerprint } from './usage/quota'
import type { LogReader } from './usage/model'
import { LimitNotices, limitNoticeText, type LimitNotice } from './limit-notices'
import { LOG_READERS } from './usage/readers'
import { UsageStore, type UsageWorkerFactory } from './usage/store'
import { createValidators } from './validate'

// The agent menu reads a running agent's options again once they are older than this.
const OPTIONS_FRESH_MS = 5 * 60_000
/** How long a used-up window's notice waits for the turn it stopped to fail. */
const LIMIT_MERGE_MS = 2_000
/** How long the summaries of worktree and scratch sessions gather before the folders are read. */
const FOLDERS_DELAY_MS = 250
/** A turn that failed this long before its window was used up counts as stopped by it. */
const LIMIT_FAILED_WITHIN_MS = 15_000
/** Harnesses whose quota the usage readers take from their own files. */
const FILE_QUOTA_HARNESSES: ReadonlySet<HarnessId> = new Set(['claude-code', 'codex'])

/** Whether the agent's program or adapter is on this computer, so the usage views may show it. */
function isInstalled(agent: AgentStatus): boolean {
  if (agent.uninstalled || agent.registered === false) return false
  return !['not-installed', 'node-missing', 'node-outdated'].includes(agent.state)
}

/** Refuses a port that is not a desktop app's: only one runs browser calls for the host. */
function browserApp(ctx: RequestContext): void {
  if (!ctx.device?.browser) {
    throw new HostError('forbidden', 'Only a paired desktop app answers browser calls')
  }
}

/** A window, and a device that said so, read stored images by hash; other devices get bytes. */
function imagesFor(device: PortDevice | null): ImageMode {
  return device && !device.imageRefs ? 'inline' : 'refs'
}

/** The byte budget for a page sent to a paired device; none for a local window. */
function pageBudgetFor(device: PortDevice | null): PageBudget | undefined {
  if (!device) return undefined
  return {
    ...(device.toolDigests ? { digest: true } : {}),
    maxBytes: REMOTE_PAGE_BYTES,
  }
}

/**
 * A page as a device reads it: with long tool outputs and inputs as digests when it said so, and
 * every entry capped safely below the 32 MiB remote channel ceiling.
 */
function digestsFor<T extends { entries: ThreadEntry[] }>(
  device: PortDevice | null,
  page: T,
): T | (Omit<T, 'entries'> & { entries: DigestedThreadEntry[] }) {
  if (!device) return page
  if (device.toolDigests) {
    const digested = digestEntries(page)
    return {
      ...digested,
      entries: digested.entries.map((entry) => fitSingleEntry(entry, REMOTE_PAGE_BYTES)),
    }
  }
  return {
    ...page,
    entries: page.entries.map((entry) => fitSingleEntry(entry, REMOTE_PAGE_BYTES)),
  }
}

/** What a message or answer from a paired device's port keeps of it; none from a window. */
function fromDevice(device: PortDevice | null): FromDevice | undefined {
  return isRemoteDevice(device) ? { id: device.id, name: device.name } : undefined
}

/** The user's own writes to Sarto's memory, from Settings, name no agent or session. */
const BY_USER: MemorySource = { agentId: null, sessionId: null }

const MEMORY_ERRORS: Record<MemoryErrorCode, PortErrorCode> = {
  invalid: 'invalid_params',
  secret: 'invalid_params',
  full: 'conflict',
  not_found: 'not_found',
  conflict: 'conflict',
  off: 'unavailable',
}

/** Runs a memory request, its refusals crossing the port with `memory_<code>` as `data.reason`. */
async function memoryCall<T>(run: () => Promise<T>): Promise<T> {
  try {
    return await run()
  } catch (error) {
    if (!(error instanceof MemoryError)) throw error
    throw new HostError(MEMORY_ERRORS[error.code], error.message, {
      reason: `memory_${error.code}`,
    })
  }
}

export interface HostOptions {
  userDataPath: string
  appVersion: string
  platform: Platform
  nodeRuntime: NodeRuntime
  fakeAgentPath: string | null
  /** The session router's bundle, which a per-session agent's process runs under. */
  sessionRouterPath?: string | null
  /** The bundle of the process that runs Cline's SDK; without it Cline runs over ACP. */
  clineHostPath?: string | null
  settings: HostSettings
  baseEnv: Env
  send(message: HostToMain): void
  /** The git service, or how to make one with the host's log; without it every `git.*` fails. */
  git?: GitServiceApi | ((deps: GitServiceDeps) => GitServiceApi) | null
  launcher?: AgentLauncher
  resolveEnv?: EnvironmentServiceDeps['resolve']
  probeNode?: EnvironmentServiceDeps['probe']
  detect?: AgentManagerDeps['detect']
  /** Each agent's protocol over the catalog's, as a test runs the fake ACP agent under its id. */
  protocols?: AgentManagerDeps['protocols']
  /** Drivers over the built-in ones, as a test's own. */
  drivers?: AgentManagerDeps['drivers']
  agentTimings?: Partial<AgentTimings>
  sessionTimings?: Partial<SessionTimings>
  /** How long after an agent's traffic its process tree is listed again. */
  treeNoteMs?: number
  /** Lists and stops the agents' process trees; the system's tools by default. */
  processControl?: ProcessControl
  mirrorTraffic?: boolean
  /** Starts the worker that owns the thread database; without it no thread is stored. */
  threadWorker?: ThreadWorkerFactory
  /** Starts the worker that owns the usage database; without it no usage is kept. */
  usageWorker?: UsageWorkerFactory
  usageTimings?: Partial<UsageTimings>
  /** The agents' log readers, for the manager; the worker has its own. */
  usageReaders?: readonly LogReader[]
  /** Where the agents' logs are looked for; the user's home by default. */
  homeDir?: string
  /** Where harness packages are installed; `~/.sarto/harnesses` by default, which apps share. */
  harnessesDir?: string
  /** Reads a session's prompt cache lifetime; Claude Code's transcripts by default. */
  cacheTtl?: CacheTtlReader
  /** Reads Claude Code sessions run outside Sarto; tests pass their own. */
  outside?: OutsideReader
  /** The desktop app's computer use; the daemon has none. */
  computer?: ComputerHostOptions | null
  /** What the host's requests to Sarto's download service say they are: the app or the daemon. */
  userAgent?: string
  /** Omit the problem report tool when the client turns problem reports off. */
  disableReports?: boolean
}

/** What the desktop app gives the host for computer use. */
export interface ComputerHostOptions {
  /** The `cua-driver` program in the app's resources, which may be missing in a checkout. */
  driverPath: string
  /** Sarto's own process and app ids, which computer use never touches. */
  selfPid: number
  selfIds: string[]
}

/** Whether a path is a directory, without raising when it is not there. */
function harnessesFolder(options: HostOptions): string {
  return (
    options.harnessesDir ??
    path.join(options.homeDir ?? os.homedir(), SARTO_HOME_FOLDER, HARNESSES_FOLDER)
  )
}

const REPLY_RUN_ERRORS: Record<TerminalCallErrorCode, PortErrorCode> = {
  not_found: 'not_found',
  restricted: 'restricted',
  not_allowed: 'terminal_not_allowed',
  stopped: 'busy',
  unavailable: 'unavailable',
  failed: 'conflict',
}

/** Whether the user referenced a surface in a message to `sessionId`. */
function sharedWith(shared: Map<string, Set<string>>, id: string, sessionId: string): boolean {
  return shared.get(id)?.has(sessionId) === true
}

function addShared(shared: Map<string, Set<string>>, id: string, sessionId: string): void {
  let sessions = shared.get(id)
  if (!sessions) shared.set(id, (sessions = new Set()))
  sessions.add(sessionId)
}

function removeShared(shared: Map<string, Set<string>>, id: string, sessionId: string): void {
  const sessions = shared.get(id)
  if (!sessions) return
  sessions.delete(sessionId)
  if (sessions.size === 0) shared.delete(id)
}

function removeSharedSession(shared: Map<string, Set<string>>, sessionId: string): void {
  for (const [id, sessions] of shared) {
    sessions.delete(sessionId)
    if (sessions.size === 0) shared.delete(id)
  }
}

export class AgentHost {
  readonly diagnostics: Diagnostics
  /** What each ACP session sent and received since the host started, for the Requests pane. */
  private readonly acpMessages = new AcpMessages()
  private readonly limitNotices = new LimitNotices()
  private readonly workFacts = new WorkFactTracker()
  /** Each agent's session whose turn failed last, which a used-up window's notice may stand for. */
  private readonly lastFailed = new Map<AgentId, { sessionId: string; at: number }>()
  /** The session a used-up window stopped, by the window's key, which its reset opens. */
  private readonly stoppedBy = new Map<string, string>()
  readonly env: EnvironmentService
  readonly projects: Projects
  readonly scratch: ScratchFolders
  private readonly worktrees: WorktreeManager
  readonly agents: AgentManager
  /** What the agents last reported about their accounts and plans, kept across runs. */
  private readonly remembered: JsonFile<AgentsFile>
  /** What the last update check found, so a found update shows after a restart. */
  private readonly updates: JsonFile<AgentUpdatesFile>
  private readonly registryListing: JsonFile<RegistryListingFile>
  private readonly harnessManifest: JsonFile<HarnessManifestFile>
  /** Each agent's config options from its last new session, for New session. */
  private readonly agentOptions: AgentOptionsStore
  /** New session's prepared sessions not yet adopted or removed, for the host after a crash. */
  private readonly preparedRecords: PreparedRecords
  /** The agent processes and what they leave behind, until seen gone. */
  private readonly trees: AgentTrees
  readonly sessions: SessionManager
  /** When idle Claude Code sessions let their agent go, by the setting and the system's memory. */
  private readonly idleRelease: IdleRelease
  private readonly load: LoadMonitor
  private readonly system: SystemReader
  private onBattery: boolean | null = null
  /** The attachments of drafts and queued prompts, until sent or removed. */
  readonly attachments: Attachments
  /** Every session's thread, read a page at a time, in a worker of its own. */
  readonly threads: ThreadStore | null
  /** Sarto's record and the agents' logs, in a worker of its own. */
  readonly usage: UsageManager
  /** The `sarto` MCP server, through which the sessions' agents reach Sarto's tools. */
  readonly mcpService: McpService
  /** Own-account remote Claude Code: hosts runs for paired devices and dials remote hosts. */
  readonly remoteClaudeHost: RemoteClaudeHost
  readonly remoteClaudeManager: RemoteClaudeManager
  /** Sarto's memory of the user and of each project, which every session is handed. */
  readonly memory: MemoryService
  /** Agents using the desktop apps of this computer; null on a host without the driver. */
  private readonly computer: ComputerUse | null
  readonly hub: PortHub
  private settings: HostSettings
  private readonly git: GitServiceApi | null
  /** Runs git for the project's files, with the agent environment. */
  private readonly execRunner: ExecRunner
  private readonly files: FilesService
  /** The projects whose folders ports watch for the Files pane. */
  private readonly fileWatches: FilesWatches
  private readonly agentFiles: AgentFiles
  private readonly sessionFiles: SessionFiles
  /** Grants for the media a thread names and the Files pane opens, which main serves. */
  private readonly media: MediaService
  private readonly htmlPreviews: HtmlPreviews
  private gitUnsubscribe: (() => void)[] = []
  /** Ports keeping a project's git status live, by path key. */
  private readonly gitRetains = new GitRetains()
  /** Browser calls awaiting main's answer, by the id the call was given. */
  private readonly browserCalls = new Map<number, (answer: BrowserCallAnswer) => void>()
  private readonly deviceCalls = new Map<number, (answer: DeviceCallAnswer) => void>()
  private readonly terminalCalls = new Map<number, (answer: TerminalCallAnswer) => void>()
  private nextTerminalCall = 1
  // Sessions whose running turn used a terminal, told to the terminal host when the turn ends.
  private readonly terminalTurns = new Set<string>()
  // Terminals the user referenced in a message, by id, with the sessions allowed to use them.
  private readonly sharedTerminals = new Map<string, Set<string>>()
  // Browser tabs and devices the user referenced the same way.
  private readonly sharedTabs = new Map<string, Set<string>>()
  private readonly sharedDevices = new Map<string, Set<string>>()
  /** Timers delaying `reached` limit notices so a failed turn can merge with them. */
  private readonly limitNoticeTimers = new Set<ReturnType<typeof setTimeout>>()
  /** Sessions whose running turn acted on a device, which the device host hears the end of. */
  private readonly deviceTurns = new Set<string>()
  private nextDeviceCall = 1
  private readonly deviceAccess: DeviceAccessStore
  /** Browser calls sent to the desktop apps that sent their turns. */
  private readonly deviceBrowser: DeviceBrowserCalls
  /** The running turns that use each session's page, whose end ends the page's agent state. */
  private readonly browserTurns = new BrowserTurns()
  /** The site each session's page last showed, from its calls' answers, which an asked step names. */
  private readonly browserSites = new Map<string, string>()
  /** The values of the Marketplace servers' inputs from main, held only in memory. */
  private marketKeys: MarketKeys = new Map()
  private agentEnvKeys: Record<string, Record<string, string>> = {}
  /** The Marketplace's catalog of MCP servers, from the registry. */
  private readonly marketCatalog: MarketCatalogService
  /** The sign-ins of the Marketplace's OAuth servers. */
  private readonly marketConnections: MarketConnectionsService
  /** Where agents reach the OAuth servers, with a fresh token. */
  private readonly mcpProxy: McpProxy
  /** The sign-ins sent to main that no push has carried back yet, by server id. */
  private readonly unkept = new Map<string, { state: string | null; pushes: number }>()
  /** Claude Code's and Codex's plugins, through each agent's harness. */
  private readonly marketPlugins: MarketPluginsService
  /** The skills catalog, the skills Sarto keeps, and what each agent gets of them. */
  private readonly marketSkills: MarketSkillsService
  /** Trash calls awaiting main's answer: null once done, else why not. */
  private readonly trashCalls = new Map<number, (error: string | null) => void>()
  private nextTrashCall = 1
  /** Settings calls awaiting main's or the daemon's answer. */
  private readonly settingsCalls = new Map<number, (answer: SettingsCallAnswer) => void>()
  private nextSettingsCall = 1
  /** The settings tools of Sarto's MCP service. */
  private readonly settingsTools: SettingsTools
  private lastProcesses = '[]'
  private sentFolders: string | null = null
  private shadowsCleared: Promise<void> = Promise.resolve()
  private foldersTimer: ReturnType<typeof setTimeout> | null = null
  private appUpdateState: AppUpdateStatus | null = null
  private stopping: Promise<void> | null = null
  private readonly catalog: readonly AgentDefinition[]

  private constructor(private readonly options: HostOptions) {
    const { platform } = options
    this.settings = options.settings
    setLocale(options.settings.locale)
    this.diagnostics = new Diagnostics({ mirrorTraffic: options.mirrorTraffic ?? false })
    const log = this.diagnostics.log.bind(this.diagnostics)
    this.env = new EnvironmentService({
      platform,
      nodeRuntime: options.nodeRuntime,
      baseEnv: options.baseEnv,
      ...(options.resolveEnv ? { resolve: options.resolveEnv } : {}),
      ...(options.probeNode ? { probe: options.probeNode } : {}),
    })
    const catalog = buildCatalog(options.fakeAgentPath)
    this.catalog = catalog
    this.env.setProxy(options.settings.proxy)
    this.env.setConfigFolders(configFolders(catalog, options.settings))
    this.execRunner = createExec(() => this.env.agentEnv() as NodeJS.ProcessEnv)
    const net = proxyFetch(() => this.env.agentEnv(), platform)
    this.media = new MediaService({
      platform,
      homeDir: options.homeDir ?? os.homedir(),
      names: (sessionId, text) => this.sessions.names(sessionId, text),
      grant: (grant) => options.send({ type: 'host:media-grant', grant }),
    })
    this.htmlPreviews = new HtmlPreviews({
      platform,
      folderOf: (sessionId) =>
        this.sessions.has(sessionId) && this.sessions.summary(sessionId).archivedAt === null
          ? this.sessions.workFolder(sessionId)
          : null,
      log: (level, message) => writeLog(level, 'host', message),
    })
    const filesHomeDir = options.homeDir ?? os.homedir()
    this.files = new FilesService({
      exec: this.execRunner.exec,
      platform,
      homeDir: filesHomeDir,
      ignorePaths: [options.userDataPath],
      media: (real, info) => this.media.grantFile(real, info, null, true),
      describeMedia: (real, info) => this.media.describe(real, info, true),
      trash: (paths) => this.trash(paths),
    })
    this.fileWatches = new FilesWatches({
      platform,
      homeDir: filesHomeDir,
      ignorePaths: [options.userDataPath],
      changed: (portId, projectPath) =>
        this.hub.send([portId], { type: 'files.changed', projectPath }),
      log: (level, message) => writeLog(level, 'host', message),
    })
    this.agentFiles = new AgentFiles({
      platform,
      homeDir: options.homeDir ?? os.homedir(),
      session: (sessionId) => this.sessions.agentSession(sessionId),
      read: (real, shown) => this.files.readAllowed(real, shown),
    })
    this.sessionFiles = new SessionFiles({
      platform,
      folder: (sessionId) => this.sessions.workFolder(sessionId),
      read: (folder, relative) =>
        this.filesCall(folder, (root) => this.files.read(root, relative, true)),
    })
    this.deviceAccess = new DeviceAccessStore(options.userDataPath, log)
    this.settingsTools = new SettingsTools({
      platform,
      read: () => this.settingsCall({ kind: 'read' }),
      apply: (patch) => this.settingsCall({ kind: 'change', patch }),
      local: () => this.settingsLocal(),
      fullAccess: (sessionId) => this.sessions.settingsFullAccess(sessionId),
      ask: (sessionId, ask) => this.sessions.settingsAsked(sessionId, ask, SETTINGS_WAIT_MS),
      recorded: (sessionId, items) => this.sessions.settingsRecorded(sessionId, items),
      settle: (sessionId, entryId, outcome) =>
        this.sessions.settingsSettled(sessionId, entryId, outcome),
      open: (sessionId, target) => this.openSettings(sessionId, target),
      words: tSettings,
      english: tSettingsEnglish,
    })
    this.projects = new Projects({ file: projectsFile(options.userDataPath, log), platform })
    this.scratch = new ScratchFolders(path.join(options.userDataPath, 'scratch'), platform)
    this.remembered = agentsFile(options.userDataPath, log)
    this.updates = agentUpdatesFile(options.userDataPath, log)
    this.registryListing = registryListingFile(options.userDataPath, log)
    this.harnessManifest = harnessManifestFile(options.userDataPath, log)
    this.agentOptions = new AgentOptionsStore({
      file: agentOptionsFile(options.userDataPath, log),
      changed: (changed) =>
        this.hub.broadcast({ type: 'agent.options', options: this.withStartMode(changed) }),
    })
    this.preparedRecords = new PreparedRecords(preparedFile(options.userDataPath, log))
    this.marketCatalog = new MarketCatalogService({
      file: catalogFile(options.userDataPath, log),
      log,
      fetch: net,
    })
    this.marketConnections = new MarketConnectionsService({
      log,
      servers: () => this.settings.marketplace.mcp,
      headers: (server) => serverHeaders(server, this.marketKeys),
      keep: (serverId, state) => this.keepSignIn(serverId, state),
      changed: (serverId, connection, loginId, error) =>
        this.connectionChanged(serverId, connection, loginId, error),
      fetch: net,
    })
    this.mcpProxy = new McpProxy({
      servers: () => this.settings.marketplace.mcp,
      headers: (server) => serverHeaders(server, this.marketKeys),
      token: (serverId) => this.marketConnections.token(serverId),
      refused: (serverId, used) => this.marketConnections.refused(serverId, used),
      fetch: net,
    })
    const home = options.homeDir ?? os.homedir()
    this.marketPlugins = new MarketPluginsService({
      file: pluginsFile(options.userDataPath, log),
      log,
      platform,
      agents: () => this.installedAgents(['claude-code', 'codex', 'antigravity']),
      program: (agentId) => this.agents.harnessProgram(agentId),
      appServer: (agentId) => this.appServer(agentId),
    })
    this.marketSkills = new MarketSkillsService({
      userDataPath: options.userDataPath,
      file: skillsCatalogFile(options.userDataPath, log),
      log,
      platform,
      home,
      settings: () => this.settings.marketplace.skills,
      agents: () => this.agents.ids().filter((id) => !this.settings.disabledAgents.includes(id)),
      configFolder: (agentId) => this.agents.configFolder(agentId),
      codexSkills: async (agentId) => {
        if ((await this.installedAgents(['codex'], [agentId])).length === 0) return null
        return (await this.appServer(agentId))<SkillsListResponse>('skills/list', { cwds: [home] })
      },
      ownSkills: () => this.mcpService.guideFlags,
      sartoOn: (agentId) => !this.settings.mcp.sarto.off.includes(agentId),
      fetch: net,
    })
    this.trees = new AgentTrees({
      file: agentProcessesFile(options.userDataPath, log),
      control: options.processControl ?? processControl(platform),
      graceMs: STOP_TIMINGS.termMs,
      ...(options.treeNoteMs !== undefined ? { noteMs: options.treeNoteMs } : {}),
      log,
    })
    this.attachments = new Attachments({ userDataPath: options.userDataPath, log })
    this.threads = options.threadWorker
      ? new ThreadStore({
          file: path.join(options.userDataPath, 'state', 'threads.db'),
          createWorker: options.threadWorker,
          log,
        })
      : null
    const computer = options.computer ?? null
    this.computer = computer
      ? new ComputerUse({
          platform,
          driver: new ComputerDriver({ path: computer.driverPath, log }),
          self: { pids: [computer.selfPid, process.pid], ids: computer.selfIds },
          settings: () => this.settings.computerUse,
          turnRefusal: (sessionId) => this.sessions.computerRefusal(sessionId),
          sessionTitle: (sessionId) => this.sessions.title(sessionId) ?? 'Untitled',
          asked: (sessionId, requestId, app) =>
            this.sessions.computerAppAsked(sessionId, requestId, app),
          settled: (requestId, answer) => this.sessions.computerAppSettled(requestId, answer),
          allowAlways: (app) => options.send({ type: 'host:computer-app-allow', app }),
          using: (sessionId, view) => this.sessions.computerUsing(sessionId, view),
          permissions: () => probePermissions({ path: computer.driverPath, log }),
          setupAsked: (sessionId, requestId, steps) =>
            this.sessions.computerSetupAsked(sessionId, requestId, steps),
          setupDone: (requestId, done) => this.sessions.computerSetupDone(requestId, done),
          setupSettled: (requestId, outcome) =>
            this.sessions.computerSetupSettled(requestId, outcome),
          stopped: (sessionId) => this.sessions.computerStopped(sessionId),
          handedBack: (sessionId, durationMs) =>
            this.sessions.controlHandedBack(sessionId, 'computer', durationMs),
          paused: (sessionId, app) => this.sessions.controlPaused(sessionId, 'computer', app),
          agent: (sessionId) => ({
            id: this.sessions.sessionAgent(sessionId) ?? '',
            name: this.sessions.agentName(sessionId),
          }),
          held: (hold) => options.send({ type: 'host:computer-hold', hold }),
          log,
        })
      : null
    this.memory = new MemoryService({
      root: path.join(options.userDataPath, 'memory'),
      log,
      projects: () => this.projects.list().map(({ path, name }) => ({ path, name })),
      claudeAgents: () => this.claudeAgents(),
    })
    this.memory.onChange(() => this.hub.broadcast({ type: 'memory.changed' }))
    this.mcpService = new McpService({
      sessionOf: (process, id) => this.sessions.sessionOf(process, id),
      subagentCall: (process, id) => this.sessions.isSubagentCall(process, id),
      plan: { set: (sessionId, items) => this.sessions.planSet(sessionId, items) },
      suggest: { note: (sessionId, message) => this.sessions.noteSuggestion(sessionId, message) },
      report: { add: (sessionId, draft) => this.sessions.reportDrafted(sessionId, draft) },
      memory: {
        service: this.memory,
        projectOf: (caller) => this.projects.find(caller.project)?.path ?? null,
        written: (sessionId, write) => this.sessions.memoryWritten(sessionId, write),
        proposed: (sessionId, proposal) => this.sessions.memoryProposed(sessionId, proposal),
        agentOf: (sessionId) => this.sessions.sessionAgent(sessionId),
      },
      browserCall: (request, caller) => this.browserCall(request, caller),
      browserAccess: {
        fullAccess: (sessionId) => this.sessions.surfaceAccessOf(sessionId).fullAccess,
        ask: (sessionId, tab) =>
          this.sessions.surfaceAccessAsked(
            sessionId,
            { surface: 'browser', id: tab.id, name: tab.title },
            { readOnly: false },
            SURFACE_ACCESS_WAIT_MS,
          ),
        used: (sessionId, title) => this.sessions.surfaceUsed(sessionId, 'browser', title),
        shared: (sessionId, tabId) => sharedWith(this.sharedTabs, tabId, sessionId),
      },
      browserSession: (sessionId) => this.sessions.browserSession(sessionId),
      devices: {
        call: (call) => this.deviceCall(call),
        agentName: (sessionId) => this.sessions.agentName(sessionId),
        ask: (sessionId, deviceId, deviceName) =>
          this.sessions.deviceAccessAsked(sessionId, deviceId, deviceName, DEVICE_ACCESS_WAIT_MS),
        alwaysAllowed: (deviceId) => this.deviceAccess.has(deviceId),
        fullAccess: (sessionId) => this.sessions.surfaceAccessOf(sessionId).fullAccess,
        used: (sessionId, name) => this.sessions.surfaceUsed(sessionId, 'device', name),
        shared: (sessionId, deviceId) => sharedWith(this.sharedDevices, deviceId, sessionId),
        allowAlways: (deviceId) => this.deviceAccess.add(deviceId),
      },
      terminals: {
        call: (call) => this.terminalCall(call),
        agentOf: (sessionId) => this.sessions.sessionAgent(sessionId),
        accessOf: (sessionId) => this.sessions.surfaceAccessOf(sessionId),
        ask: (sessionId, terminal, ask) =>
          this.sessions.surfaceAccessAsked(
            sessionId,
            { surface: 'terminal', id: terminal.id, name: terminal.name ?? terminal.title },
            ask,
            SURFACE_ACCESS_WAIT_MS,
          ),
        used: (sessionId, terminal) =>
          this.sessions.surfaceUsed(sessionId, 'terminal', terminal.name ?? terminal.title),
        shared: (sessionId, terminalId) => sharedWith(this.sharedTerminals, terminalId, sessionId),
        passwords: () => this.settings.agentPasswords,
      },
      sessionProject: (sessionId) => this.sessions.sessionProject(sessionId),
      sessionFolder: (sessionId) => this.sessions.sessionFolder(sessionId),
      ...(this.computer ? { computer: this.computer } : {}),
      settings: this.settingsTools,
      proxy: this.mcpProxy,
      sessions: {
        info: (sessionId) => this.sessions.sessionInfo(sessionId),
        list: (projectPath) => this.sessions.toolSessions(projectPath),
        lastReply: (sessionId) => this.sessions.lastReply(sessionId),
        rename: (sessionId, title) => this.sessions.renameByAgent(sessionId, title),
        work: (sessionId) => this.sessions.runningWork([sessionId]),
        archiveAfterTurn: (sessionId, agentName) =>
          this.sessions.archiveWhenIdle(sessionId, agentName),
        archiveNow: (sessionId, agentName) => this.sessions.archiveByAgent(sessionId, agentName),
        start: (callerId, params) => this.sessions.startFromTool(callerId, params),
        carried: (callerId, agentId) => this.sessions.carriedOptions(callerId, agentId),
        agentOptions: (agentId) => this.agentOptions.get(agentId),
        readOptions: (agentId) => this.agents.readFirstOptions(agentId),
        choices: (sessionId) => this.sessions.toolChoices(sessionId),
        held: (sessionId) => this.sessions.firstHeld(sessionId),
        send: (sessionId, text, from, now) =>
          this.sessions.sendFromTool(sessionId, text, from, now),
        started: (callerId) => this.sessions.startedBy(callerId),
        name: (sessionId) => this.sessions.toolName(sessionId),
        agentName: (sessionId) => this.sessions.agentName(sessionId),
        agentLabel: (agentId) => this.agents.name(agentId),
        agents: () => this.agents.statuses(),
        history: (sessionId) => this.sessions.historyTurns(sessionId),
        mode: (sessionId) => this.sessions.toolMode(sessionId),
        starterRank: (sessionId) => this.sessions.starterRank(sessionId),
        startMode: (agentId) => startModeIn(this.settings, agentId),
      },
      log,
      appVersion: options.appVersion,
      ...(options.disableReports ? { reports: false } : {}),
    })
    const usageStore = options.usageWorker
      ? new UsageStore({
          file: path.join(options.userDataPath, 'state', 'usage.db'),
          createWorker: options.usageWorker,
          log,
          onChanged: () => this.usage.rowsChanged(),
          onProgress: (progress) => this.usage.progressed(progress),
          onStatus: (status) => this.usage.storeStatus(status),
        })
      : null
    this.usage = new UsageManager({
      store: usageStore,
      forgotten: usageStore ? forgottenAccountsFile(options.userDataPath, log) : null,
      readers: options.usageReaders ?? LOG_READERS,
      fromComputer: options.settings.usage.fromComputer,
      platform,
      home: options.homeDir ?? os.homedir(),
      env: async (agentId) => {
        await this.env.ready()
        return this.env.agentEnv(agentId)
      },
      isScratch: (folder) => this.scratch.contains(folder),
      worktreeProject: (folder) => this.sessions.worktreeProject(folder),
      plans: () => this.usagePlans(),
      refreshPlan: (agentId) => this.agents.refreshLimits(agentId),
      agents: async () =>
        (await this.agents.list()).map((agent) => ({
          id: agent.id,
          name: agent.name,
          harnessId: agent.harnessId,
          installed: isInstalled(agent),
        })),
      log,
      changed: (source) => {
        this.hub.broadcast({ type: 'usage.changed' })
        if (source !== 'remote') {
          this.options.send({ type: 'host:usage-changed' })
        }
      },
      status: (status) => this.hub.broadcast({ type: 'usage.status', status }),
      ...(options.usageTimings ? { timings: options.usageTimings } : {}),
    })
    const adaptersDir = harnessesFolder(options)
    this.agents = new AgentManager({
      catalog,
      platform,
      nodeRuntime: options.nodeRuntime,
      appVersion: options.appVersion,
      env: this.env,
      diagnostics: this.diagnostics,
      acpMessages: this.acpMessages,
      launcher: options.launcher ?? processLauncher(platform),
      settings: () => this.settings,
      reportsDir: path.join(options.userDataPath, 'agent-reports'),
      adaptersDir,
      sessionRouterPath: options.sessionRouterPath ?? null,
      clineHostPath: options.clineHostPath ?? null,
      claudeSettingsDir: flagSettingsFolder(options.userDataPath),
      ...(options.detect ? { detect: options.detect } : {}),
      ...(options.protocols ? { protocols: options.protocols } : {}),
      ...(options.drivers ? { drivers: options.drivers } : {}),
      ...(options.agentTimings ? { timings: options.agentTimings } : {}),
      status: (status) => {
        this.hub.broadcast({ type: 'agent.status', status })
        this.limitsNoticed(status)
        if (status.limits.length > 0 || (status.balances && status.balances.length > 0)) {
          this.options.send({ type: 'host:usage-changed' })
        }
      },
      removed: (agentId) => this.hub.broadcast({ type: 'agent.removed', agentId }),
      processes: (processes) => this.reportProcesses(processes),
      trees: this.trees,
      authCommands: (commands) => options.send({ type: 'host:auth-commands', commands }),
      remember: (file) => this.remembered.save(file),
      rememberUpdates: (file) => this.updates.save(file),
      rememberRegistry: (file) => this.registryListing.save(file),
      rememberManifest: (file) => this.harnessManifest.save(file),
      ...(options.userAgent ? { userAgent: options.userAgent } : {}),
      launchEnv: (agentId, env) => ({
        ...this.marketSkills.launchEnv(agentId, env),
        ...(this.agentEnvKeys[agentId] ?? {}),
      }),
      envKeyIsSet: (agentId, variable) =>
        typeof this.agentEnvKeys[agentId]?.[variable] === 'string',
    })
    this.worktrees = new WorktreeManager({
      git: createWorktreeGit({
        exec: this.execRunner.exec,
        platform,
        homeDir: options.homeDir ?? os.homedir(),
      }),
      platform,
      settings: (projectPath) => this.projects.worktreeSettings(projectPath),
      root: () => this.settings.git.worktreeRoot,
      env: async () => {
        await this.env.ready()
        return this.env.agentEnv() as NodeJS.ProcessEnv
      },
      takenByPullRequest: (projectPath, branch) =>
        this.git?.branchPullRequests(projectPath).has(branch) ?? false,
      log,
    })
    this.idleRelease = new IdleRelease({
      platform,
      settings: () => this.settings.idleSessions,
      log: (level, message) => this.diagnostics.log(level, message),
      changed: () => {
        this.sessions.idleRulesChanged()
        this.hub.broadcast({ type: 'idleRelease.changed', state: this.idleRelease.state() })
      },
    })
    this.system = new SystemReader({
      platform,
      // The volumes that hold a project, the worktrees or Sarto's data.
      folders: () => [
        options.userDataPath,
        ...this.projects.paths(),
        ...(this.settings.git.worktreeRoot ? [this.settings.git.worktreeRoot] : []),
      ],
      onBattery: () => this.onBattery,
      log: (level, message) => this.diagnostics.log(level, message),
    })
    this.load = new LoadMonitor({
      source: {
        sample: () => this.system.sample(),
        read: (from, to) => this.system.read(from, to),
        forget: () => this.system.forget(),
      },
      send: (portIds, event) => this.hub.send(portIds, event),
      log: (level, message) => this.diagnostics.log(level, message),
    })
    this.remoteClaudeManager = new RemoteClaudeManager({
      platform,
      log,
      env: async () => {
        await this.env.ready()
        return this.env.agentEnv() as NodeJS.ProcessEnv
      },
    })
    this.sessions = new SessionManager({
      platform,
      agents: this.agents,
      projects: this.projects,
      scratch: this.scratch,
      worktrees: this.worktrees,
      file: sessionsFile(options.userDataPath, log),
      returned: returnedFile(options.userDataPath, log),
      projectMcp: new ProjectMcpAnswers(projectMcpFile(options.userDataPath, log)),
      projectHooks: new ProjectHooksAnswers(projectHooksFile(options.userDataPath, log)),
      portOpen: (portId) => this.hub.has(portId),
      portDevice: (portId) => this.hub.deviceOf(portId),
      threads: this.threads,
      agentFile: (sessionId, file) =>
        this.agentFiles.read(sessionId, file).then(
          (content) => (content.kind === 'text' ? content.text : null),
          (error: unknown) => {
            log('warn', `Could not read ${file}: ${(error as Error).message}`)
            return null
          },
        ),
      projectFile: (sessionId, file) =>
        this.sessionFiles.text(sessionId, file).catch((error: unknown) => {
          log('warn', `Could not read ${file}: ${(error as Error).message}`)
          return null
        }),
      reportsDir: path.join(options.userDataPath, 'agent-reports'),
      attachments: this.attachments,
      mcp: {
        servers: (sessionId, record, connection, suggests) => {
          const gateway = this.agents.toolGateway(record.agentId)
          return this.agents.mcpServersByName(record.agentId)
            ? this.mcpService.folderServers(
                connection,
                record.projectPath,
                sessionId,
                gateway,
                suggests,
              )
            : this.mcpService.servers(sessionId, record.projectPath, gateway, suggests)
        },
        library: (sessionId, record, connection, transports, taken) =>
          libraryServers(
            this.settings.marketplace.mcp,
            this.marketKeys,
            record.agentId,
            transports,
            {
              platform,
              taken,
              node: options.nodeRuntime,
              oauth: {
                access: (server) => this.marketConnections.access(server),
                bearer: () =>
                  this.mcpService.bearer(
                    sessionId,
                    record.projectPath,
                    this.agents.mcpServersByName(record.agentId) ? connection : null,
                  ),
              },
            },
          ),
        detached: (sessionId) => {
          this.mcpService.revoke(sessionId)
          this.computer?.forget(sessionId)
          this.browserSites.delete(sessionId)
          this.forgetSharedSurfaces(sessionId)
        },
        guide: (agentId, suggests) =>
          this.mcpService.guidePrompt(
            this.marketSkills.takesSkills(agentId),
            this.agents.toolGateway(agentId),
            suggests,
          ),
        turnEnded: (sessionId) => {
          this.computer?.turnEnded(sessionId)
          this.browserTurnEnded(sessionId)
          this.settingsTools.turnEnded(sessionId)
          if (this.deviceTurns.delete(sessionId)) {
            this.options.send({ type: 'host:device-turn-ended', sessionId })
          }
          if (this.terminalTurns.delete(sessionId)) {
            this.options.send({ type: 'host:terminal-turn-ended', sessionId })
          }
        },
      },
      skills: (record, sarto) => this.marketSkills.sessionOptions(record.agentId, sarto),
      memory: this.memory,
      usage: this.usage,
      cacheTtl:
        options.cacheTtl ??
        claudeCacheTtl({
          platform,
          home: options.homeDir ?? os.homedir(),
          env: async () => {
            await this.env.ready()
            return this.env.agentEnv('claude-code')
          },
          log,
        }),
      modelRequests: (() => {
        const acpFallback = acpModelRequests(this.acpMessages)
        return byHarness(
          {
            'claude-code': claudeModelRequests({
              platform,
              home: options.homeDir ?? os.homedir(),
              env: async () => {
                await this.env.ready()
                return this.env.agentEnv('claude-code')
              },
            }),
            codex: codexModelRequests({
              home: options.homeDir ?? os.homedir(),
              env: async () => {
                await this.env.ready()
                return this.env.agentEnv('codex')
              },
            }),
            opencode: opencodeModelRequests({
              sessions: (agentId) => this.agents.openCode(agentId),
            }),
            cline: clineModelRequests({
              home: options.homeDir ?? os.homedir(),
              env: async () => {
                await this.env.ready()
                return this.env.agentEnv('cline')
              },
            }),
            antigravity: antigravityModelRequests({
              home: options.homeDir ?? os.homedir(),
              fallback: acpFallback,
            }),
          },
          acpFallback,
        )
      })(),
      outside:
        options.outside ??
        claudeOutside({
          platform,
          home: options.homeDir ?? os.homedir(),
          env: async () => {
            await this.env.ready()
            return this.env.agentEnv('claude-code')
          },
          log,
        }),
      idleRelease: this.idleRelease,
      remoteClaude: this.remoteClaudeManager,
      diagnostics: this.diagnostics,
      git: () => this.git,
      options: this.agentOptions,
      settings: () => this.settings,
      ...(options.sessionTimings ? { timings: options.sessionTimings } : {}),
      prepared: this.preparedRecords,
      settingsTargets: (agentId, folder) =>
        settingsTargets(
          agentId,
          folder,
          (name) => this.env.get(name, agentId),
          options.homeDir ?? os.homedir(),
          platform,
        ),
      events: {
        patches: (batch, portIds) => this.hub.send(portIds, { type: 'session.patches', batch }),
        summary: (summary, portIds) => {
          if (portIds) {
            this.hub.send(portIds, { type: 'session.summary', summary })
            return
          }
          this.hub.broadcast({ type: 'session.summary', summary })
          if (summary.scratch || summary.worktree) this.sendFoldersSoon()
          // Only the daemon's game link takes these: a port must select them, and no device may.
          const facts = this.workFacts.observe(summary)
          if (facts.length > 0) this.hub.broadcast({ type: 'work.facts', facts })
        },
        turnUsage: (sessionId, models) => this.workFacts.noteUsage(sessionId, models),
        removed: (sessionId, portIds) => {
          if (portIds) {
            this.hub.send(portIds, { type: 'session.removed', sessionId })
            return
          }
          this.hub.broadcast({ type: 'session.removed', sessionId })
          this.workFacts.forget(sessionId)
          this.sendFolders()
        },
        ended: (sessionIds) => {
          this.htmlPreviews.end(sessionIds)
          options.send({ type: 'host:sessions-ended', sessionIds })
        },
        returned: (sessionId, portIds) => {
          if (portIds) this.hub.send(portIds, { type: 'session.returned', sessionId })
          else this.hub.broadcast({ type: 'session.returned', sessionId })
        },
        viewers: (sessionId, showing, to) => {
          for (const portId of to) {
            const viewers = this.hub.viewers(showing, portId)
            this.hub.send([portId], { type: 'session.viewers', sessionId, viewers })
          }
        },
        attention: (sessionId, kind, title, body, request) => {
          if (kind === 'error') this.sessionFailed(sessionId)
          options.send({
            type: 'host:attention',
            sessionId,
            kind,
            title,
            body,
            ...(request?.allow
              ? { allowOnce: { requestId: request.id, optionId: request.allow.optionId } }
              : {}),
            ...(request ? { request } : {}),
            front: this.front(sessionId),
          })
        },
        badge: (count) => options.send({ type: 'host:badge', count }),
        waiting: (sessions) => options.send({ type: 'host:waiting', sessions }),
        seen: (sessionId) => options.send({ type: 'host:seen', sessionId }),
        busy: (counts) => options.send({ type: 'host:busy-changed', ...counts }),
      },
    })
    this.remoteClaudeHost = new RemoteClaudeHost({
      userDataPath: options.userDataPath,
      platform,
      agents: this.agents,
      claudeOptions: () => this.agentOptions.get('claude-code')?.config ?? [],
      settings: () => this.settings.remoteClaude,
      sendToPort: (portId, event) => this.hub.send([portId], event),
      onActiveChanged: (active) => {
        const local = this.hub.localPorts()
        if (local.length > 0) {
          this.hub.send(local, { type: 'remoteClaude.activeChanged', active })
        }
      },
      log,
    })
    // Earlier runs' shadow workspaces go before a device's first open makes one of its own.
    this.shadowsCleared = clearShadowWorkspaces(options.userDataPath)
    this.deviceBrowser = new DeviceBrowserCalls({
      send: (portId, event) => this.hub.send([portId], event),
      servicePort: () => this.mcpService.listeningPort,
    })
    this.hub = new PortHub({
      handlers: this.handlers(),
      validators: createValidators(platform),
      closed: (portId) => this.portClosed(portId),
      log,
    })
    this.projects.onChange((projects, noProject) => {
      this.system.forgetMounts()
      this.broadcast({ type: 'projects.changed', projects, noProject })
      this.sendFolders()
    })
    this.env.onChange((info) => {
      this.broadcast({ type: 'environment.changed', info })
      this.git?.setEnvironment(this.env.agentEnv() as NodeJS.ProcessEnv)
    })
    // As Reload does: the fallback's PATH may have missed programs the login shell's finds.
    this.env.onRecovered(() => {
      this.agents
        .redetect()
        .catch((error: unknown) =>
          log('warn', `Could not detect the agents again: ${(error as Error).message}`),
        )
    })
    this.git =
      typeof options.git === 'function'
        ? options.git({
            env: this.env.agentEnv() as NodeJS.ProcessEnv,
            log: (level, message) => log(level, `git: ${message}`),
          })
        : (options.git ?? null)
    if (this.git) this.wireGit(this.git)
  }

  /** Loads the state, answers `host:ready`, and resolves the environment in the background. */
  static async start(options: HostOptions): Promise<AgentHost> {
    // Before any agent starts: what a run before this one left is no process's any more.
    await clearFlagSettings(flagSettingsFolder(options.userDataPath)).catch((error: unknown) =>
      writeLog('warn', 'host', `Could not clear Claude Code's settings files: ${String(error)}`),
    )
    const host = new AgentHost(options)
    const [, , , remembered, updates, listing, manifest] = await Promise.all([
      host.scratch.ready(),
      host.projects.load(),
      host.sessions.load(),
      host.remembered.load(),
      host.updates.load(),
      host.registryListing.load(),
      host.harnessManifest.load(),
      host.trees.load(),
      host.agentOptions.load(),
      host.preparedRecords.load(),
      host.attachments.load(),
      host.mcpService.start(),
      host.memory.load(),
    ])
    host.agents.restore(remembered)
    host.agents.restoreRegistry(listing)
    host.agents.restoreManifest(manifest)
    host.agents.restoreUpdates(updates)
    void host.marketSkills.sync()
    host.sendFolders()
    void host.sessions.checkWorktrees()
    host.usage.start()
    host.idleRelease.start()
    options.send({ type: 'host:service-port', port: host.mcpService.listeningPort })
    options.send({ type: 'host:ready' })
    void host.trees.stopLeftovers()
    host.agents.startLimitReads()
    void host.agents.removeAntigravityUsageServer()
    void host.agents.detectAll().then(() => {
      host.agents.scheduleUpdateChecks()
      host.agents.scheduleRegistryReads()
      host.firstStart()
    })
    return host
  }

  /**
   * The first start of this host: names the programs it found for the settings' owner to add
   * their agents. A host whose login shell could not be read waits for the next start, since
   * the programs on its `PATH` may be missing.
   */
  private firstStart(): void {
    if (this.settings.initialSetupDone || this.env.info().source === 'fallback') return
    this.options.send({ type: 'host:first-start', harnesses: this.agents.userPrograms() })
  }

  /** The Claude Code agents of this host and their configuration folders, for memory's import. */
  private claudeAgents(): { agentId: AgentId; name: string; configDir: string }[] {
    return this.agents.ids().flatMap((agentId) => {
      if (harnessOf(agentId) !== 'claude-code') return []
      const configDir = this.agents.configFolder(agentId)
      return configDir ? [{ agentId, name: this.agents.name(agentId), configDir }] : []
    })
  }

  private wireGit(git: GitServiceApi): void {
    git.setBackgroundFetch(this.settings.git.backgroundFetch)
    this.gitUnsubscribe = [
      git.onChanged((status) =>
        this.sendToRetainers(status.projectPath, { type: 'git.changed', status }),
      ),
      git.onPullRequest((projectPath, pr) =>
        this.sendToRetainers(projectPath, { type: 'git.pr', projectPath, pr }),
      ),
      git.onTools((tools) => this.broadcast({ type: 'git.tools', tools })),
      git.onBranchPullRequests((projectPath) => this.sessions.pullRequestsChanged(projectPath)),
      git.onReferenceChanged((url, found) => {
        this.hub.send(git.referenceWatchers(url), { type: 'git.reference', url, found })
        if (found.kind === 'pull') this.sessions.pullRequestLoaded(found.pullRequest.url)
      }),
      git.onSessionEvents((sessionId, events) => this.sessions.gitEvents(sessionId, events)),
    ]
  }

  /**
   * The folders terminals may open in, sent when they change: the projects, scratch folders and
   * sessions' worktrees.
   */
  /**
   * The folders again after a worktree or scratch session's summary: each tool call of one sends
   * a summary, and reading the folders goes through every session.
   */
  private sendFoldersSoon(): void {
    if (this.foldersTimer || this.stopping) return
    this.foldersTimer = setTimeout(() => {
      this.foldersTimer = null
      if (!this.stopping) this.sendFolders()
    }, FOLDERS_DELAY_MS)
    this.foldersTimer.unref?.()
  }

  private sendFolders(): void {
    const paths = [...this.projects.paths(), ...this.sessions.sessionFolders()]
    const key = paths.join('\n')
    if (key === this.sentFolders) return
    this.sentFolders = key
    this.options.send({ type: 'host:projects', paths })
  }

  private broadcast(event: HostEvent): void {
    this.hub.broadcast(event)
  }

  /** What a status changed in the agent's plan limit windows, said as notices. */
  private limitsNoticed(status: AgentStatus): void {
    for (const notice of this.limitNotices.observe(status, Date.now())) {
      // A used-up window waits a moment for the turn it stopped to fail, so the two say it once.
      if (notice.level === 'reached') {
        const timer = setTimeout(() => {
          this.limitNoticeTimers.delete(timer)
          this.sendLimitNotice(notice)
        }, LIMIT_MERGE_MS)
        this.limitNoticeTimers.add(timer)
      } else {
        this.sendLimitNotice(notice)
      }
    }
  }

  private sessionFailed(sessionId: string): void {
    if (!this.sessions.has(sessionId)) return
    this.lastFailed.set(this.sessions.summary(sessionId).agentId, { sessionId, at: Date.now() })
  }

  private sendLimitNotice(notice: LimitNotice): void {
    const now = Date.now()
    let sessionId: string | undefined
    if (notice.level === 'reached') {
      const failed = this.lastFailed.get(notice.agentId)
      if (failed && now - failed.at < LIMIT_FAILED_WITHIN_MS) {
        sessionId = failed.sessionId
        this.stoppedBy.set(notice.key, sessionId)
        if (this.sessions.has(sessionId)) {
          this.sessions.turnLimited(sessionId, this.agents.status(notice.agentId), notice.limit)
        }
      }
    } else if (notice.level === 'reset') {
      sessionId = this.stoppedBy.get(notice.key)
      this.stoppedBy.delete(notice.key)
    }
    const summary =
      sessionId && this.sessions.has(sessionId) ? this.sessions.summary(sessionId) : null
    const { title, body } = limitNoticeText(notice, summary?.title ?? null, now)
    this.options.send({
      type: 'host:attention',
      kind: 'plan-limit',
      agentId: notice.agentId,
      level: notice.level,
      key: notice.key,
      usedPercent: notice.limit.usedPercent,
      ...(summary ? { sessionId: summary.id } : {}),
      title,
      body,
    })
  }

  /** Who shows a session in front now: any window or device, and which devices. */
  private front(sessionId: string): AttentionFront {
    const ports = this.sessions.showing(sessionId)
    const devices = ports.flatMap((portId) => this.hub.deviceOf(portId)?.id ?? [])
    return { any: ports.length > 0, devices: [...new Set(devices)] }
  }

  private sendToRetainers(projectPath: string, event: HostEvent): void {
    this.hub.send(this.gitRetains.ports(pathKey(projectPath, this.options.platform)), event)
  }

  private reportProcesses(processes: AgentProcess[]): void {
    const json = JSON.stringify(processes)
    if (json === this.lastProcesses) return
    this.lastProcesses = json
    this.options.send({ type: 'host:agent-processes', processes })
  }

  /** Serves a window's port, or a paired device's when `device` names it. */
  connect(channel: PortChannel<FromPort<HostEvent>>, device: PortDevice | null = null): string {
    return this.hub.add(channel, device)
  }

  private portClosed(portId: string): void {
    this.remoteClaudeHost.portClosed(portId)
    this.deviceBrowser.portClosed(portId)
    this.browserTurns.portClosed(portId)
    this.sessions.portClosed(portId)
    this.load.portClosed(portId)
    this.gitRetains.dropPort(portId)
    this.git?.releaseAll(portId)
    this.fileWatches.dropPort(portId)
  }

  /** `host:hosts-socket`: where `remote-host` listens for outbound connections to paired hosts. */
  setHostsSocket(socketPath: string | null): void {
    this.remoteClaudeManager.setHostsSocket(socketPath)
  }

  /** `host:remote-hosts`: live statuses of known paired/mesh hosts from `remote-host`. */
  setRemoteHosts(hosts: import('@shared/remote/hosts').HostStatus[]): void {
    this.remoteClaudeManager.setRemoteHosts(hosts)
  }

  /** `host:battery`: whether the computer is on battery power. */
  battery(onBattery: boolean): void {
    this.onBattery = onBattery
  }

  /** `host:settings`: binary overrides, the proxy and background fetch, applied live. */
  async updateSettings(next: HostSettings): Promise<void> {
    const previous = this.settings
    this.settings = next
    if (setLocale(next.locale))
      this.broadcast({ type: 'environment.changed', info: this.env.info() })
    if (JSON.stringify(previous.remoteClaude) !== JSON.stringify(next.remoteClaude)) {
      await this.remoteClaudeHost.updateSettings(next.remoteClaude)
    }
    if (JSON.stringify(previous.proxy) !== JSON.stringify(next.proxy)) {
      this.env.setProxy(next.proxy)
      this.git?.setEnvironment(this.env.agentEnv() as NodeJS.ProcessEnv)
    }
    if (previous.git.backgroundFetch !== next.git.backgroundFetch) {
      this.git?.setBackgroundFetch(next.git.backgroundFetch)
    }
    this.usage.setFromComputer(next.usage.fromComputer)
    if (JSON.stringify(previous.computerUse) !== JSON.stringify(next.computerUse)) {
      this.computer?.settingsChanged()
    }
    this.env.setConfigFolders(configFolders(this.catalog, next))
    this.startModesChanged(previous, next)
    if (JSON.stringify(previous.idleSessions) !== JSON.stringify(next.idleSessions)) {
      this.idleRelease.notify()
    }
    if (previous.continueAfterLimit !== next.continueAfterLimit) {
      this.sessions.continueSettingChanged(next.continueAfterLimit)
    }
    this.marketChanged(previous.marketplace.mcp, this.marketKeys)
    if (JSON.stringify(previous.marketplace.skills) !== JSON.stringify(next.marketplace.skills)) {
      void this.skillsChanged(previous.marketplace.skills)
    }
    const removed = await this.agents.settingsChanged(previous, next)
    const turnedOff = next.disabledAgents.filter((id) => !previous.disabledAgents.includes(id))
    const gone = [...removed, ...turnedOff]
    if (gone.length > 0) await this.sessions.agentsRemoved(gone)
  }

  async reloadMemory(): Promise<void> {
    await this.memory.load()
    this.hub.broadcast({ type: 'memory.changed' })
  }

  /** Exports this host's quarter-hour usage buckets and agent plan readings for E2EE sync. */
  async exportHostUsage(requestId: number): Promise<void> {
    let usage: SyncedHostUsageSection | null
    try {
      const plans: Partial<Record<AgentId, SyncedAgentPlanReading>> = {}
      for (const agent of await this.agents.list()) {
        const limits = agent.limits ?? []
        const balances = agent.balances ?? []
        const tier = agent.account?.tier ?? (agent.account?.label || undefined)
        if (limits.length === 0 && balances.length === 0) continue
        const latestObserved = limits.reduce(
          (max: number, lim) => (lim.observedAt > max ? lim.observedAt : max),
          0,
        )
        plans[agent.id] = {
          ...(tier ? { tier } : {}),
          limits,
          balances,
          observedAt: latestObserved,
        }
      }
      usage = await this.usage.exportHostUsage(plans)
    } catch {
      usage = null
    }
    this.options.send({ type: 'host:usage-export', requestId, usage })
  }

  /** Replaces remote Macs' synced usage, and this Mac as the sync names it, for usage. */
  async setRemoteUsage(
    devices: Record<string, SyncedHostUsageSection>,
    self: SyncedUsageSelf | null = null,
    present?: readonly string[],
  ): Promise<void> {
    await this.usage.setRemoteUsage(devices, self, present)
  }

  /**
   * The live plans whose quota no file holds, for the usage quotas: every installed agent that
   * reads its limits, as Antigravity's agy `/usage` and Cursor's dashboard. Claude Code's and
   * Codex's come from their files. Antigravity's account comes from its files too; the others'
   * is their signed-in email's fingerprint.
   */
  private async usagePlans(): Promise<Partial<Record<AgentId, AgentPlan>>> {
    const plans: Partial<Record<AgentId, AgentPlan>> = {}
    for (const agent of await this.agents.list()) {
      if (FILE_QUOTA_HARNESSES.has(agent.harnessId) || !isInstalled(agent)) continue
      if (!this.agents.hasLimits(agent.id)) continue
      const account = agent.account
      const tier = account?.tier ?? (account?.kind === 'account' ? account.label : undefined)
      const email = account?.kind === 'account' ? account.email?.trim().toLowerCase() : undefined
      plans[agent.id] = {
        ...(tier ? { tier } : {}),
        limits: agent.limits,
        signedOut: agent.signIn === 'required',
        ...(email && agent.harnessId !== 'antigravity'
          ? { account: accountFingerprint(agent.harnessId, email) }
          : {}),
        idle: this.agents.readsLimitsIdle(agent.id),
      }
    }
    return plans
  }

  /** Moves the paths to the system's trash, which only main reaches; the daemon has none. */
  private async trash(paths: string[]): Promise<void> {
    const callId = this.nextTrashCall++
    const error = await new Promise<string | null>((resolve) => {
      this.trashCalls.set(callId, resolve)
      this.options.send({ type: 'host:trash-call', callId, paths })
    })
    if (error !== null) throw new HostError('unavailable', error)
  }

  /** `trash-result`: main's or the daemon's answer to a trash call. */
  trashResult(callId: number, error: string | null): void {
    const resolve = this.trashCalls.get(callId)
    if (!resolve) return
    this.trashCalls.delete(callId)
    resolve(error)
  }

  /** Reads or changes the settings through main or the daemon, which keep the file. */
  private settingsCall(call: SettingsCall): Promise<SettingsSnapshot> {
    const callId = this.nextSettingsCall++
    return new Promise<SettingsCallAnswer>((resolve) => {
      this.settingsCalls.set(callId, resolve)
      this.options.send({ type: 'host:settings-call', callId, call })
    }).then((answer) => {
      if ('error' in answer) throw new Error(answer.error)
      return answer.result
    })
  }

  /** `settings-result`: main's or the daemon's answer to a settings call. */
  settingsResult(callId: number, answer: SettingsCallAnswer): void {
    const resolve = this.settingsCalls.get(callId)
    if (!resolve) return
    this.settingsCalls.delete(callId)
    resolve(answer)
  }

  /** What the settings tools read of the host itself: its agents and harnesses, and their facts. */
  private async settingsLocal(): Promise<LocalFacts> {
    const statuses = this.agents
      .statuses()
      .filter((status) => status.registered !== false && status.uninstalled !== true)
    const facts: SettingFacts = {}
    const modes: Partial<Record<AgentId, { value: string; name: string }[]>> = {}
    for (const status of statuses) {
      const account = status.account
      facts[`agents.account:${status.id}`] =
        account && account.kind !== 'none'
          ? [account.label, account.email].filter(Boolean).join(' · ') || null
          : null
      // Only whether a key is set; its value stays where Sarto keeps it.
      facts[`agents.api-key:${status.id}`] = status.apiKey ? status.apiKey.set : null
      if (takesStartMode(status.id)) {
        const option = this.agentOptions
          .get(status.id)
          ?.config.find((o) => o.category === 'mode' && o.type === 'select' && !!o.choices?.length)
        if (option?.choices) {
          modes[status.id] = option.choices.map((choice) => ({
            value: choice.value,
            name: choice.name,
          }))
        }
      }
    }
    const harnesses = new Map(statuses.map((s) => [s.harnessId, s.harnessName]))
    facts['agents.agents'] = statuses.length
    facts['harnesses.installed'] = harnesses.size
    facts['archived.sessions'] = this.sessions
      .summaries()
      .filter((summary) => summary.archivedAt !== null).length
    facts['memory.enabled'] = this.memory.enabled
    try {
      await this.deviceAccess.ready
      facts['devices.allowed-devices'] = this.deviceAccess.list().length
    } catch {
      // As above.
    }
    return {
      agents: statuses.map((status) => ({
        id: status.id,
        name: status.name,
        harnessId: status.harnessId,
      })),
      harnesses: [...harnesses].map(([id, name]) => ({ id, name })),
      modes,
      facts,
    }
  }

  /**
   * open_settings: Settings opens at the row in the desktop windows that show the session, a
   * desktop app connected as a device included; a row of the desktop app's own only in this
   * computer's windows. False when no such window shows it.
   */
  private openSettings(sessionId: string, target: SettingsTarget): boolean {
    const ports = this.sessions.showing(sessionId).filter((portId) => {
      const device = this.hub.deviceOf(portId)
      return device === null || device.browser === true
    })
    if (ports.length === 0) return false
    this.hub.send(ports, {
      type: 'settings.open',
      section: target.section,
      item: target.item,
      row: target.row,
    })
    return true
  }

  /** Undo on a settings line: the rows go back, unless one changed again since. */
  private async undoSettings(sessionId: string, entryId: string): Promise<void> {
    const items = this.sessions.settingsChange(sessionId, entryId)
    try {
      await this.settingsTools.undo(items)
    } catch (error) {
      if (error instanceof StaleUndo) {
        this.sessions.settingsSettled(sessionId, entryId, { kind: 'changed', stale: true })
        throw new HostError('conflict', error.message)
      }
      throw new HostError('unavailable', (error as Error).message)
    }
    this.sessions.settingsSettled(sessionId, entryId, { kind: 'changed', undone: true })
  }

  /**
   * `host:market-keys`: every value of the Marketplace servers' inputs, replacing those before.
   * They stay in memory and go only into what agents are handed; a malformed message is dropped.
   */
  setMarketKeys(values: unknown, oauth?: unknown, agentEnv?: unknown): void {
    const keys = parseMarketKeys(values)
    const signIns = oauth === undefined ? undefined : parseSignIns(oauth)
    if (!keys || signIns === null) {
      this.diagnostics.log('warn', 'host:market-keys was not a map of values; ignored')
      return
    }
    const previous = this.marketKeys
    this.marketKeys = keys
    const previousAgentEnv = this.agentEnvKeys
    if (typeof agentEnv === 'object' && agentEnv !== null && !Array.isArray(agentEnv)) {
      this.agentEnvKeys = Object.fromEntries(
        Object.entries(agentEnv).flatMap(([id, vars]) =>
          typeof vars === 'object' && vars !== null && !Array.isArray(vars)
            ? [
                [
                  id,
                  Object.fromEntries(
                    Object.entries(vars).filter(
                      (entry): entry is [string, string] => typeof entry[1] === 'string',
                    ),
                  ),
                ],
              ]
            : [],
        ),
      )
    }
    for (const agentId of new Set([
      ...Object.keys(previousAgentEnv),
      ...Object.keys(this.agentEnvKeys),
    ])) {
      if (
        JSON.stringify(previousAgentEnv[agentId] ?? {}) !==
        JSON.stringify(this.agentEnvKeys[agentId] ?? {})
      ) {
        void this.agents.agentEnvChanged(agentId as AgentId).catch((error: unknown) => {
          this.diagnostics.log(
            'warn',
            `Could not restart ${agentId} after its key changed: ${(error as Error).message}`,
          )
        })
      }
    }
    this.marketChanged(this.settings.marketplace.mcp, previous)
    if (signIns) this.signInsPushed(signIns)
    this.hub.broadcast({ type: 'market.keysChanged' })
  }

  /**
   * Main's copy of the sign-ins. Every message to main is answered with one, so a sign-in two
   * pushes have not carried back was refused: it keeps working until the host restarts.
   */
  private signInsPushed(signIns: Record<string, string>): void {
    const before = this.marketConnections.view()
    this.marketConnections.load(signIns)
    for (const [serverId, sent] of this.unkept) {
      const kept = Object.hasOwn(signIns, serverId) ? signIns[serverId]! : null
      if (kept === sent.state) {
        this.unkept.delete(serverId)
      } else if (++sent.pushes >= 2) {
        this.unkept.delete(serverId)
        this.diagnostics.log(
          'warn',
          `Main did not keep the sign-in of ${serverId}; it lasts until the host restarts`,
        )
      }
    }
    const after = this.marketConnections.view()
    for (const [serverId, connection] of Object.entries(after)) {
      if (JSON.stringify(before[serverId]) !== JSON.stringify(connection)) {
        this.connectionChanged(serverId, connection)
      }
    }
  }

  /** Asks main to keep a server's sign-in, or to forget it with null. */
  private keepSignIn(serverId: string, state: string | null): void {
    this.unkept.set(serverId, { state, pushes: 0 })
    this.options.send({ type: 'host:market-oauth', serverId, state })
  }

  /**
   * A server's sign-in changed: the clients hear of it, and the prepared sessions of its agents
   * are replaced, since they started with the server or without it.
   */
  private connectionChanged(
    serverId: string,
    connection: MarketConnection,
    loginId?: string,
    error?: string,
  ): void {
    this.hub.broadcast({
      type: 'market.connectionChanged',
      serverId,
      connection,
      ...(loginId !== undefined ? { loginId } : {}),
      ...(error !== undefined ? { error } : {}),
    })
    const server = this.settings.marketplace.mcp.find((item) => item.id === serverId)
    if (server) this.sessions.libraryChanged((agentId) => serverFor(server, agentId))
  }

  /**
   * The Marketplace's servers or keys may have changed from `servers` and `keys`: each agent whose
   * servers differ now has its prepared sessions replaced.
   */
  private marketChanged(servers: HostSettings['marketplace']['mcp'], keys: MarketKeys): void {
    // Proxied servers compare by where they go, without a session's bearer.
    const oauth = {
      access: (server: MarketServer) => this.marketConnections.access(server),
      bearer: () => ({ origin: '', token: '' }),
    }
    const options = { platform: this.options.platform, oauth, node: this.options.nodeRuntime }
    const of = (list: typeof servers, held: MarketKeys, agentId: AgentId): string =>
      JSON.stringify(libraryServers(list, held, agentId, ALL_TRANSPORTS, options))
    const now = this.settings.marketplace.mcp
    if (servers === now && keys === this.marketKeys) return
    this.sessions.libraryChanged(
      (agentId) => of(servers, keys, agentId) !== of(now, this.marketKeys, agentId),
    )
  }

  /**
   * The skills in the settings changed from `before`: the disk follows, then the prepared sessions
   * of each agent whose skills differ are replaced.
   */
  private async skillsChanged(before: HostSettings['marketplace']['skills']): Promise<void> {
    await this.marketSkills.sync()
    const now = this.settings.marketplace.skills
    const of = (skills: typeof now, agentId: AgentId): string =>
      JSON.stringify(skills.filter((skill) => skillFor(skill, agentId)).map((s) => [s.id, s.name]))
    this.sessions.libraryChanged((agentId) => of(before, agentId) !== of(now, agentId))
  }

  /** The agents of these harnesses that are turned on and whose program is installed. */
  private async installedAgents(
    harnesses: readonly HarnessId[],
    among: readonly AgentId[] = this.agents.ids(),
  ): Promise<AgentId[]> {
    const wanted = among.filter(
      (id) => harnesses.includes(harnessOf(id)) && !this.settings.disabledAgents.includes(id),
    )
    const found = await Promise.all(wanted.map((id) => this.agents.harnessProgram(id)))
    return wanted.filter((_, index) => found[index] !== null)
  }

  /** The agent's app-server for requests outside a session, started if it is not running. */
  private async appServer(agentId: AgentId): Promise<CodexRequest> {
    const { connection } = await this.agents.ensureReady(agentId)
    const request = connection.request?.bind(connection)
    if (!request) throw new HostError('agent_unavailable', t('hostError.agentNoRequest'))
    return request
  }

  /** The options as New session takes them, with the start mode the settings name for the agent. */
  private withStartMode(options: AgentOptions): AgentOptions {
    const startMode = startModeIn(this.settings, options.agentId)
    return startMode === undefined ? options : { ...options, startMode }
  }

  /**
   * An agent's start mode changed: its prepared sessions started in the old one, and the windows
   * learn the new one with its options, after the prepared sessions' removal.
   */
  private startModesChanged(previous: HostSettings, next: HostSettings): void {
    const agentIds = new Set([...Object.keys(previous.startModes), ...Object.keys(next.startModes)])
    for (const agentId of agentIds as Set<AgentId>) {
      if (startModeIn(previous, agentId) === startModeIn(next, agentId)) continue
      this.sessions.startModeChanged(agentId)
      const entry = this.agentOptions.get(agentId)
      if (entry) this.hub.broadcast({ type: 'agent.options', options: this.withStartMode(entry) })
    }
  }

  /** Power state transitions from main (kept for host:power IPC compatibility). */
  power(state: 'suspend' | 'resume'): void {
    void state
  }

  busy(requestId: number): void {
    this.options.send({ type: 'host:busy', requestId, sessions: this.sessions.busy() })
  }

  /** The floating label's buttons and the stop shortcut, from main. */
  computerControl(sessionId: string, action: ComputerControlAction): void {
    this.computer?.control(sessionId, action)
  }

  /** `host:computer-frame-request`: where the window the holding session uses is now. */
  computerFrame(requestId: number): void {
    const answer = (frame: ComputerFrame | null) =>
      this.options.send({ type: 'host:computer-frame', requestId, frame })
    if (!this.computer) return answer(null)
    this.computer.frame().then(answer, (error: unknown) => {
      this.diagnostics.log('info', `Computer use could not find its window: ${String(error)}`)
      answer(null)
    })
  }

  /**
   * `host:report-request`: a problem report's bundle, written into the data folder's `reports`,
   * which the parent removes once the user saved or dropped it.
   */
  async report(message: Extract<MainToHost, { type: 'host:report-request' }>): Promise<void> {
    let result: ReportBuildResult
    try {
      const request = parseReportRequest(message.request)
      await flushLog()
      result = await writeReport(
        {
          request,
          now: Date.now(),
          parent:
            typeof message.parent === 'object' && message.parent !== null ? message.parent : {},
          settings: message.settings ?? null,
          host: await this.collectDiagnostics(),
          logDir: logFolder(),
          crashDir: typeof message.crashDir === 'string' ? message.crashDir : null,
          screenshot:
            typeof message.screenshot === 'string'
              ? new Uint8Array(Buffer.from(message.screenshot, 'base64'))
              : null,
          client: message.client ?? null,
          redact: redactLogText,
        },
        path.join(this.options.userDataPath, 'reports'),
      )
    } catch (error) {
      result = { ok: false, reason: 'failed', message: (error as Error).message }
    }
    if (!result.ok) this.diagnostics.log('warn', `No problem report: ${result.message}`)
    this.options.send({ type: 'host:report', requestId: message.requestId, result })
  }

  /** Allow once from a request's notification; a request already answered elsewhere is left. */
  answerPermission(sessionId: string, requestId: string, optionId: string): void {
    try {
      this.sessions.respond(sessionId, requestId, { optionId })
    } catch (error) {
      this.diagnostics.log(
        'info',
        `A notification's answer was not taken: ${(error as Error).message}`,
      )
    }
  }

  /** Takes the paths main granted for attachments, then says so, before main answers the renderer. */
  grant(requestId: number, grants: AttachmentGrant[]): void {
    this.attachments.grant(grants)
    this.options.send({ type: 'host:granted', requestId })
  }

  /**
   * The agent (and optional remote Claude model host) Sarto asks on its own account about
   * `project`, null for No project: the agent new sessions start with, else the one its latest
   * session used; when local Claude Code is not installed, falls back to an available remote
   * Claude model host rather than installing local Claude Code unasked.
   */
  private preferredTarget(
    project: string | null,
  ): { agentId: AgentId; modelHost?: { hostId: string; hostName: string } } | null {
    const projectSessions = (
      project === null ? this.sessions.list() : this.sessions.list(project)
    ).sort((a, b) => b.updatedAt - a.updatedAt)
    const latestInProject = projectSessions[0]
    const agentId = this.settings.defaultAgent ?? latestInProject?.agentId ?? null
    if (agentId === null || !this.agents.has(agentId)) return null
    let modelHost =
      latestInProject?.agentId === agentId ? (latestInProject.modelHost ?? undefined) : undefined
    if (
      !modelHost &&
      harnessOf(agentId) === 'claude-code' &&
      !this.agents.isInstalledLocally(agentId)
    ) {
      const anyRemote = [...this.sessions.list()]
        .sort((a, b) => b.updatedAt - a.updatedAt)
        .find((s) => s.agentId === agentId && s.modelHost != null)
      modelHost = anyRemote?.modelHost ?? undefined
    }
    if (!modelHost && this.agents.isDisabled(agentId)) return null
    return { agentId, ...(modelHost ? { modelHost } : {}) }
  }

  private async resolveLightRuntime(
    agentId: AgentId,
    modelHost?: { hostId: string; hostName: string },
  ) {
    if (modelHost && harnessOf(agentId) === 'claude-code') {
      return this.remoteClaudeManager.ensureReady(modelHost.hostId, agentId)
    }
    if (harnessOf(agentId) === 'claude-code' && !this.agents.isInstalledLocally(agentId)) {
      const hosts = await this.remoteClaudeManager.listAvailableHosts()
      const ready =
        hosts.find(
          (h) => h.status.enabled && h.status.ready && h.status.activeRuns < h.status.maxConcurrent,
        ) ?? hosts.find((h) => h.status.enabled && h.status.ready)
      if (ready) return this.remoteClaudeManager.ensureReady(ready.hostId, agentId)
      throw new HostError('agent_unavailable', t('remoteClaude.notInstalled'))
    }
    return this.agents.ensureReady(agentId)
  }

  /**
   * A commit message for the changed files at `paths`, from the project's preferred agent or the
   * one the lightweight tasks' model is pinned to.
   */
  private async commitMessage(projectPath: string, paths: string[]): Promise<string> {
    const context = await this.gitProjectCall(projectPath, (g, p) => g.commitContext(p, paths))
    const preferred = this.preferredTarget(projectPath)
    const target = lightTarget(this.settings.lightModel, preferred?.agentId ?? null, null)
    if (target === null) throw new HostError('agent_error', t('git.commitMessageNoAgent'))
    const modelHost = target.agentId === preferred?.agentId ? preferred.modelHost : undefined
    const agent = modelHost
      ? `${this.agents.name(target.agentId)} (${modelHost.hostName})`
      : this.agents.name(target.agentId)
    try {
      const runtime = await this.resolveLightRuntime(target.agentId, modelHost)
      const dir = path.join(this.options.userDataPath, 'agent-reports')
      await mkdir(dir, { recursive: true })
      return await writeCommitMessage(runtime, {
        dir,
        context,
        model: target.model,
        log: (line) => this.diagnostics.log('warn', line),
      })
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error)
      this.diagnostics.log('warn', `${agent}: could not write a commit message: ${logText(error)}`)
      throw new HostError('agent_error', t('git.commitMessageFailed', { agent, reason }))
    }
  }

  /**
   * A title and description for a pull request of the branch into `base`, from the project's
   * preferred agent or the one the lightweight tasks' model is pinned to.
   */
  private async pullRequestDraft(
    projectPath: string,
    base: string,
  ): Promise<{ title: string; body: string }> {
    const context = await this.gitProjectCall(projectPath, (g, p) => g.pullRequestContext(p, base))
    const preferred = this.preferredTarget(projectPath)
    const target = lightTarget(this.settings.lightModel, preferred?.agentId ?? null, null)
    if (target === null) throw new HostError('agent_error', t('git.draftNoAgent'))
    const modelHost = target.agentId === preferred?.agentId ? preferred.modelHost : undefined
    const agent = modelHost
      ? `${this.agents.name(target.agentId)} (${modelHost.hostName})`
      : this.agents.name(target.agentId)
    try {
      const runtime = await this.resolveLightRuntime(target.agentId, modelHost)
      const dir = path.join(this.options.userDataPath, 'agent-reports')
      await mkdir(dir, { recursive: true })
      return await writePullRequestDraft(runtime, {
        dir,
        context,
        model: target.model,
        log: (line) => this.diagnostics.log('warn', line),
      })
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error)
      this.diagnostics.log('warn', `${agent}: could not write a pull request: ${logText(error)}`)
      throw new HostError('agent_error', t('git.draftFailed', { agent, reason }))
    }
  }

  private rememberedModelFor(agentId: AgentId): string | null {
    const remembered = this.agentOptions.rememberedOf(agentId)
    const modelOpt = this.agentOptions
      .get(agentId)
      ?.config.find((o) => o.category === 'model' && o.type === 'select')
    if (modelOpt) {
      const value = remembered[modelOpt.id]
      if (typeof value === 'string' && value.trim() !== '') return value.trim()
    }
    const fallback = remembered.model
    return typeof fallback === 'string' && fallback.trim() !== '' ? fallback.trim() : null
  }

  /**
   * A draft of a problem report's description, using the current session's agent/model first,
   * then the new session's last remembered agent/model, falling back to other hidden-session
   * capable agents if needed. Always runs at medium thinking effort (scoped to report drafts only).
   * Returns `{ draft: null, agent: null }` when Sarto observed nothing to write from.
   */
  private async draftReport(
    params: HostParams<'agents.draftReport'>,
  ): Promise<{ draft: string | null; agent: string | null }> {
    const session =
      params.sessionId !== null && this.sessions.has(params.sessionId)
        ? this.sessions.summary(params.sessionId)
        : null
    const about = session?.agentId ?? params.agentId
    const known = about !== null && this.agents.has(about)
    const prompt = reportDraftPrompt(
      {
        origin: params.origin,
        language: params.language,
        agent: known ? this.agents.name(about) : null,
        error: params.error,
        log: this.diagnostics.logEntries(),
        events: known ? this.diagnostics.agentEvents(about) : [],
        now: Date.now(),
      },
      redactLogText,
    )
    if (prompt === null) return { draft: null, agent: null }

    const candidates: Array<{
      agentId: AgentId
      model: string | null
      modelHost?: { hostId: string; hostName: string }
    }> = []
    const seen = new Set<string>()
    const push = (
      agentId: AgentId | null | undefined,
      model: string | null | undefined,
      modelHost?: { hostId: string; hostName: string } | null,
    ): void => {
      if (!agentId) return
      const host = modelHost ?? undefined
      const key = `${agentId}\n${host?.hostId ?? ''}`
      if (seen.has(key)) return
      if (!this.agents.has(agentId) || (!host && this.agents.isDisabled(agentId))) return
      seen.add(key)
      const resolvedModel =
        typeof model === 'string' && model.trim() !== ''
          ? model.trim()
          : host
            ? null
            : this.rememberedModelFor(agentId)
      candidates.push({ agentId, model: resolvedModel, ...(host ? { modelHost: host } : {}) })
    }

    // Priority 1: Current session (or report's session) agent and model.
    if (session) push(session.agentId, session.model, session.modelHost)
    if (params.draftAgentId) push(params.draftAgentId, params.draftModel)
    if (params.agentId) push(params.agentId, params.draftModel)

    // Priority 2: New session's last recorded agent and model.
    if (params.fallbackAgentId) push(params.fallbackAgentId, params.fallbackModel)

    // Priority 3: Recent sessions, preferred agent, then remaining hidden-capable agents.
    const recentSessions = [...this.sessions.list()].sort((a, b) => b.updatedAt - a.updatedAt)
    for (const s of recentSessions) push(s.agentId, s.model, s.modelHost)
    const preferred = this.preferredTarget(session && !session.scratch ? session.projectPath : null)
    if (preferred) push(preferred.agentId, null, preferred.modelHost)
    const lightAgents = this.sessions.lightAgents()
    for (const light of lightAgents) push(light.agentId, null)

    const hiddenCapable = new Set(lightAgents.map((a) => a.agentId))
    const eligible = candidates.filter((c) => {
      if (c.modelHost && harnessOf(c.agentId) === 'claude-code') return true
      if (harnessOf(c.agentId) === 'claude-code' && !this.agents.isInstalledLocally(c.agentId)) {
        return false
      }
      return hiddenCapable.has(c.agentId)
    })
    if (eligible.length === 0) throw new HostError('agent_error', t('report.draftNoAgent'))

    const dir = path.join(this.options.userDataPath, 'agent-reports')
    await mkdir(dir, { recursive: true })

    const labelOf = (c: (typeof eligible)[number]): string =>
      c.modelHost
        ? `${this.agents.name(c.agentId)} (${c.modelHost.hostName})`
        : this.agents.name(c.agentId)
    let lastAgent = labelOf(eligible[0]!)
    let lastReason: string | null = null
    const maxAttempts = Math.min(eligible.length, 2)
    for (let i = 0; i < maxAttempts; i++) {
      const candidate = eligible[i]!
      const agent = labelOf(candidate)
      lastAgent = agent
      try {
        const runtime = await this.resolveLightRuntime(candidate.agentId, candidate.modelHost)
        if (!runtime.connection.hiddenSessions) continue
        const draft = await writeReportDraft(runtime, {
          dir,
          prompt,
          model: { small: false, model: candidate.model },
          log: (line) => this.diagnostics.log('warn', line),
          ...(i === 0 && maxAttempts > 1 ? { timeoutMs: 25_000 } : {}),
        })
        return { draft, agent }
      } catch (error) {
        const reason = error instanceof Error ? error.message : String(error)
        lastReason = reason
        // Info: the report this draft is for must not read its own failure as part of the problem.
        this.diagnostics.log(
          'info',
          `${agent}: could not draft a problem report: ${logText(error)}`,
        )
      }
    }
    if (lastReason !== null) {
      throw new HostError(
        'agent_error',
        t('report.draftFailed', { agent: lastAgent, reason: lastReason }),
      )
    }
    throw new HostError('agent_error', t('report.draftNoAgent'))
  }

  /**
   * Sends a browser call to the desktop app that sent the session's turn, or to main, and settles
   * with its answer, or a failure if the host stops. The caller's turn uses the page from now until
   * it ends; a step the agent asks the user for shows in the page's session's thread meanwhile.
   */
  async browserCall(
    request: BrowserCallRequest,
    caller = request.sessionId,
  ): Promise<BrowserCallAnswer> {
    const page = request.sessionId
    const target = browserTarget(this.sessions.browserSender(page), this.hub)
    if (target.kind === 'gone') {
      return { error: { code: 'unavailable', message: BROWSER_GONE } }
    }
    const left = this.browserTurns.used(caller, page, target)
    if (left) this.tellTurnEnded(page, left)
    const asking = request.tool === 'browser_ask_user'
    if (asking) {
      const { step, reason } = request.args
      this.sessions.controlAsked(page, {
        surface: 'browser',
        step: isControlStep(step) ? step : 'other',
        target: this.browserSites.get(page) ?? null,
        reason: typeof reason === 'string' ? reason : '',
      })
    }
    const answer =
      target.kind === 'device'
        ? await this.deviceBrowser.call(target.portId, request)
        : await this.mainBrowserCall(request)
    if ('result' in answer) {
      const site = siteOf(answer.result.value.url)
      if (site) this.browserSites.set(page, site)
    }
    if (asking) {
      if ('result' in answer) {
        const outcome = answer.result.value.outcome
        this.sessions.controlAskSettled(page, isControlOutcome(outcome) ? outcome : 'ended')
      } else if (answer.error.code !== 'user_has_control') {
        // Only a wait that goes on keeps the card; anything else ended the step.
        this.sessions.controlAskSettled(page, 'ended')
      }
    }
    return answer
  }

  /** Sends a browser call to main, which drives the page of the host's own windows. */
  private mainBrowserCall(request: BrowserCallRequest): Promise<BrowserCallAnswer> {
    // The tools' id travels to main unchanged, so its report of a site wait names the same call.
    const callId = request.callId
    return new Promise<BrowserCallAnswer>((resolve) => {
      this.browserCalls.set(callId, resolve)
      this.options.send({
        type: 'host:browser-call',
        callId,
        sessionId: request.sessionId,
        tool: request.tool,
        args: request.args,
        projectPath: request.projectPath,
        ...(request.allowTab ? { allowTab: request.allowTab } : {}),
      })
    })
  }

  /** A session's turn ended: the pages no running turn uses now are nobody's. */
  private browserTurnEnded(sessionId: string): void {
    for (const { page, target } of this.browserTurns.turnEnded(sessionId)) {
      this.tellTurnEnded(page, target)
    }
  }

  private tellTurnEnded(page: string, target: Exclude<BrowserTarget, { kind: 'gone' }>): void {
    if (target.kind === 'main')
      this.options.send({ type: 'host:browser-turn-ended', sessionId: page })
    else this.hub.send([target.portId], { type: 'browser.turnEnded', sessionId: page })
  }

  /** `host:browser-handed-back`: the user handed main's page back; the thread says for how long. */
  browserHandedBack(sessionId: string, durationMs: number): void {
    this.sessions.controlHandedBack(sessionId, 'browser', durationMs)
  }

  /**
   * `host:browser-waiting`: the call waits on a new origin, so its own time limit grows to that
   * wait and the call fails `not_allowed` rather than timing out first.
   */
  browserWaiting(callId: number, waiting: boolean): void {
    this.mcpService.browserWaiting(callId, waiting)
  }

  /** `host:browser-origin-ask`: main's page waits for a new origin, which the thread shows. */
  browserOriginAsked(requestId: number, sessionId: string, origin: string): void {
    this.sessions.browserOriginAsked(sessionId, requestId, origin)
  }

  /** `host:browser-origin-answer`: the wait ended, so the session's card takes the answer. */
  browserOriginSettled(requestId: number, decision: BrowserOriginAnswer): void {
    this.sessions.browserOriginSettled(requestId, decision)
  }

  /** Sends an agent's device call to its parent, which hands it to the device host. */
  deviceCall(call: DeviceCall): Promise<DeviceCallAnswer> {
    if (call.kind === 'action') this.deviceTurns.add(call.sessionId)
    const callId = this.nextDeviceCall++
    return new Promise<DeviceCallAnswer>((resolve) => {
      this.deviceCalls.set(callId, resolve)
      this.options.send({ type: 'host:device-call', callId, call })
    })
  }

  /** `host:device-handed-back`: the user handed a device back; the thread says for how long. */
  deviceHandedBack(sessionId: string, durationMs: number): void {
    this.sessions.controlHandedBack(sessionId, 'device', durationMs)
  }

  /**
   * The user's Run on a shell code block of a session's reply: a new terminal of the session's
   * agent runs it, the way the agent's own terminal tool does, and unless `notify` is false the
   * session is told which, queued while a turn runs. A subagent's reply runs for the session it
   * runs under, which has the terminals and takes prompts.
   */
  private async runReplyCommand(
    params: { sessionId: string; command: string; notify: boolean },
    portId: string,
    device: PortDevice | null,
  ): Promise<{ terminalId: string; notified: boolean }> {
    const sessionId = this.sessions.browserSession(params.sessionId)
    const agentId = sessionId ? this.sessions.sessionAgent(sessionId) : null
    if (!sessionId || !agentId) throw new HostError('not_found', t('session.notFound'))
    const folder = this.sessions.sessionFolder(sessionId) ?? this.sessions.sessionProject(sessionId)
    if (!folder) throw new HostError('restricted', t('hostError.noFolder'))
    const answer = await this.terminalCall({
      kind: 'reply',
      sessionId,
      agentId,
      folder,
      command: params.command,
      fromDevice: isRemoteDevice(device),
    })
    if ('error' in answer) {
      throw new HostError(REPLY_RUN_ERRORS[answer.error.code], answer.error.message)
    }
    if (answer.result.kind !== 'terminal') throw new HostError('internal', 'No terminal opened')
    const terminalId = answer.result.terminal.id
    if (!params.notify) return { terminalId, notified: false }
    try {
      const text = replyRunNotice(terminalId, params.command)
      await this.sessions.queue(sessionId, [{ type: 'text', text }], portId, fromDevice(device))
      return { terminalId, notified: true }
    } catch (error) {
      writeLog('warn', 'host', `A reply's run could not be told: ${(error as Error).message}`)
      return { terminalId, notified: false }
    }
  }

  /**
   * The terminals, browser tabs and devices a user's message references: the session's agent may
   * use them from now on, as the user shared them. A terminal gets the allow at once, so its tab
   * says so; the rest is given on the agent's first call.
   */
  private shareSurfaces(sessionId: string, content: readonly UserContent[]): void {
    for (const item of content) {
      if (item.type !== 'ref') continue
      if (item.ref.kind === 'page') addShared(this.sharedTabs, item.ref.tabId, sessionId)
      if (item.ref.kind === 'device') addShared(this.sharedDevices, item.ref.deviceId, sessionId)
      if (item.ref.kind !== 'terminal') continue
      const terminalId = item.ref.terminalId
      addShared(this.sharedTerminals, terminalId, sessionId)
      const session = this.sessions.browserSession(sessionId) ?? sessionId
      void this.terminalCall({ kind: 'allow', sessionId: session, terminalId, allowed: true })
    }
  }

  private forgetSharedSurfaces(sessionId: string): void {
    removeSharedSession(this.sharedTerminals, sessionId)
    removeSharedSession(this.sharedTabs, sessionId)
    removeSharedSession(this.sharedDevices, sessionId)
  }

  /** Takes back the session's agent the use of a terminal the user opened, from the tab's menu. */
  private async revokeTerminal(sessionId: string, terminalId: string): Promise<void> {
    removeShared(this.sharedTerminals, terminalId, sessionId)
    const answer = await this.terminalCall({ kind: 'allow', sessionId, terminalId, allowed: false })
    if ('error' in answer) throw new HostError('not_found', answer.error.message)
    this.sessions.surfaceAccessRevoked(sessionId, terminalId)
  }

  /** Sends an agent's terminal call to its parent, which hands it to the terminal host. */
  terminalCall(call: TerminalCall): Promise<TerminalCallAnswer> {
    // Only these take the terminal for the turn; the terminal host frees it when the turn ends.
    if (call.kind === 'run' || call.kind === 'input' || call.kind === 'stop') {
      this.terminalTurns.add(call.sessionId)
    }
    const callId = this.nextTerminalCall++
    return new Promise<TerminalCallAnswer>((resolve) => {
      this.terminalCalls.set(callId, resolve)
      this.options.send({ type: 'host:terminal-call', callId, call })
    })
  }

  /** `terminal-result`: the terminal host's answer to a call this host forwarded. */
  terminalResult(callId: number, answer: TerminalCallAnswer): void {
    const resolve = this.terminalCalls.get(callId)
    if (!resolve) return
    this.terminalCalls.delete(callId)
    resolve(answer)
  }

  /** `host:terminal-handed-back`: the user handed a terminal back; the thread says for how long. */
  terminalHandedBack(sessionId: string, durationMs: number): void {
    this.sessions.controlHandedBack(sessionId, 'terminal', durationMs)
  }

  /** `device-result`: the device host's answer to a call this host forwarded. */
  deviceResult(callId: number, answer: DeviceCallAnswer): void {
    const resolve = this.deviceCalls.get(callId)
    if (!resolve) return
    this.deviceCalls.delete(callId)
    resolve(answer)
  }

  /** `browser-result`: the answer to a call this host forwarded. */
  browserResult(callId: number, result: unknown, problem: unknown): void {
    const resolve = this.browserCalls.get(callId)
    if (!resolve) return
    this.browserCalls.delete(callId)
    resolve(answerOf(result, problem))
  }

  /** Main is gone: every call awaiting it fails so shutdown never hangs on unsettled promises. */
  private failPendingCalls(): void {
    for (const resolve of this.browserCalls.values()) {
      resolve({
        error: { code: 'timeout', message: 'Main stopped before the browser answered.' },
      })
    }
    this.browserCalls.clear()
    for (const resolve of this.deviceCalls.values()) {
      resolve({
        error: { code: 'unavailable', message: 'Sarto stopped before the device answered.' },
      })
    }
    this.deviceCalls.clear()
    for (const resolve of this.terminalCalls.values()) {
      resolve({
        error: { code: 'unavailable', message: 'Sarto stopped before the terminal answered.' },
      })
    }
    this.terminalCalls.clear()
    for (const resolve of this.trashCalls.values()) resolve('Sarto stopped before it answered.')
    this.trashCalls.clear()
    for (const resolve of this.settingsCalls.values()) {
      resolve({ error: 'Sarto stopped before it answered.' })
    }
    this.settingsCalls.clear()
  }

  /** Stops every agent with the documented sequence, flushes the state files, then reports. */
  shutdown(): Promise<void> {
    this.stopping ??= (async () => {
      for (const timer of this.limitNoticeTimers) clearTimeout(timer)
      this.limitNoticeTimers.clear()
      if (this.foldersTimer) clearTimeout(this.foldersTimer)
      this.foldersTimer = null
      this.sessions.shutdown()
      await this.remoteClaudeHost.shutdown()
      this.remoteClaudeManager.shutdown()
      this.failPendingCalls()
      this.idleRelease.stop()
      this.load.stop()
      this.usage.stop()
      this.execRunner.killAll()
      this.fileWatches.stop()
      for (const unsubscribe of this.gitUnsubscribe) unsubscribe()
      await Promise.all([
        this.agents.stopAll(),
        this.git?.dispose().catch((error: unknown) => {
          this.diagnostics.log(
            'warn',
            `Git service did not stop cleanly: ${(error as Error).message}`,
          )
        }),
      ])
      await Promise.all([
        this.mcpService.stop(),
        this.htmlPreviews.stop(),
        this.computer?.shutdown(),
        this.projects.flush(),
        this.sessions.flush(),
        this.remembered.flush(),
        this.updates.flush(),
        this.registryListing.flush(),
        this.harnessManifest.flush(),
        this.trees.close(),
        this.agentOptions.flush(),
        this.preparedRecords.flush(),
        this.attachments.flush(),
        this.marketCatalog.flush(),
        this.marketPlugins.flush(),
        this.marketSkills.flush(),
        this.threads?.close(),
        this.usage.close(),
        shutdownAgySqliteWorker(),
      ])
      this.hub.closeAll()
      this.failPendingCalls()
      this.options.send({ type: 'host:stopped' })
    })()
    return this.stopping
  }

  async collectDiagnostics(): Promise<DiagnosticsBundle> {
    const node = this.env.nodeProbe()
    const adapters = await Promise.all(
      this.agents.ids().map((agentId) => this.agents.adapterFiles(agentId).catch(() => null)),
    )
    return {
      createdAt: Date.now(),
      appVersion: this.options.appVersion,
      platform: this.options.platform,
      environment: {
        PATH: this.env.get('PATH') ?? null,
        SHELL: this.env.get('SHELL') ?? null,
        node: node.nodeVersion,
      },
      environmentInfo: this.env.info(),
      agents: this.agents.ids().map((agentId, i) => ({
        status: this.agents.status(agentId),
        capabilities: this.agents.rawCapabilities(agentId),
        ...this.diagnostics.agentRecords(agentId),
        adapter: adapters[i] ?? null,
      })),
      sessions: this.sessions.list(),
      log: this.diagnostics.logEntries(),
    }
  }

  private requireGit(): GitServiceApi {
    if (!this.git) throw new HostError('git_error', t('git.notReady'))
    return this.git
  }

  /** Runs git with the resolved environment, so git and gh are found as the agents find them. */
  private async gitCall<T>(run: (git: GitServiceApi) => Promise<T>): Promise<T> {
    const git = this.requireGit()
    await this.env.ready()
    try {
      return await run(git)
    } catch (error) {
      if (error instanceof HostError) throw error
      throw new HostError('git_error', (error as Error)?.message ?? String(error))
    }
  }

  /** Runs a git request that reads or writes a registered project or a scratch folder. */
  private async gitProjectCall<T>(
    projectPath: string,
    run: (git: GitServiceApi, canonical: string) => Promise<T>,
  ): Promise<T> {
    const canonical = await this.gitProject(projectPath)
    return this.gitCall((g) => run(g, canonical))
  }

  /**
   * Refuses a canonical folder that is not a registered project, a scratch folder or a worktree a
   * session works in: files, git and media are read nowhere else.
   */
  private assertOpenFolder(canonical: string): void {
    if (this.scratch.contains(canonical) || this.sessions.isSessionWorktree(canonical)) return
    this.projects.match(canonical)
  }

  /** A registered project, a scratch folder or a session's worktree, canonical; git runs nowhere else. */
  private async gitProject(projectPath: string): Promise<string> {
    this.requireGit()
    const canonical = await this.projects.resolveDirectory(projectPath)
    this.assertOpenFolder(canonical)
    return canonical
  }

  /**
   * Runs a file request for a registered project or a scratch folder, once the environment git
   * needs is resolved.
   */
  private async filesCall<T>(projectPath: string, run: (root: string) => Promise<T>): Promise<T> {
    const canonical = await this.projects.resolveDirectory(projectPath)
    this.assertOpenFolder(canonical)
    await this.env.ready()
    return run(canonical)
  }

  /** For Settings › MCP servers: Sarto's own server and where each agent keeps its own. */
  private async mcpStatus(): Promise<McpStatus> {
    const service = this.mcpService
    return {
      servers: [
        {
          name: SERVICE_NAME,
          title: 'Sarto',
          builtIn: true,
          running: service.listeningPort !== null,
          error: service.error,
          tools: service.toolSummaries(),
        },
      ],
      places: await this.agents.mcpPlaces(),
    }
  }

  private handlers(): Handlers {
    const { agents, sessions, projects, memory } = this
    return {
      'agents.list': () => agents.list(),
      'agents.check': ({ agentId }) => agents.check(agentId),
      'agents.reloadEnvironment': async () => {
        const result = await agents.reloadEnvironment()
        // A tool installed since the last probe shows up without a restart.
        if (this.git) await this.gitCall((g) => g.reloadTools())
        return result
      },
      'agents.detectedPrograms': async () => {
        await agents.check()
        return agents.userPrograms()
      },
      'agents.environment': () => this.env.info(),
      'agents.authenticate': ({ agentId, methodId }, ctx) =>
        agents.authenticate(agentId, methodId, {
          device: isRemoteDevice(ctx.device),
          openLink: (url) =>
            this.hub.send([ctx.portId], { type: 'agents.signInLink', agentId, url }),
        }),
      'agents.cancelSignIn': ({ agentId }) => agents.cancelSignIn(agentId),
      'agents.logout': ({ agentId }) => agents.logout(agentId),
      'agents.providerAction': (input) => agents.providerAction(input),
      'agents.retry': ({ agentId }) => agents.retry(agentId),
      'agents.reinstall': ({ agentId }) => agents.reinstall(agentId),
      'agents.checkUpdates': () => agents.checkUpdates(),
      'agents.skipUpdate': ({ agentId }) => agents.skipUpdate(agentId),
      'agents.unskipUpdate': ({ agentId }) => agents.unskipUpdate(agentId),
      'agents.update': ({ agentId }) => agents.update(agentId),
      'agents.updateCli': ({ agentId }) => agents.updateCli(agentId),
      'agents.setApiKey': ({ agentId, ...input }) => agents.setApiKey(agentId, input),
      'agents.clearApiKey': ({ agentId }) => agents.clearApiKey(agentId),
      'agents.install': ({ agentId, method }) => agents.install(agentId, method),
      'agents.uninstall': ({ agentId, removeProgram }) =>
        agents.uninstall(agentId, removeProgram === true),
      'agents.installOffer': ({ agentId }) => agents.installOffer(agentId),
      'agents.cancelTask': ({ agentId }) => agents.cancelTask(agentId),
      'agents.readOptions': async ({ agentId, projectPath }) => {
        const entry = this.agentOptions.get(agentId)
        // A provisional entry lacks the agent's defaults and its mode, which a switch to it shows.
        if (entry && !entry.provisional && Date.now() - entry.observedAt < OPTIONS_FRESH_MS) return
        const folder =
          projectPath === null
            ? null
            : await projects.resolveDirectory(projectPath).catch(() => null)
        await agents.readOptions(agentId, folder ?? undefined)
      },
      'agents.readFirstOptions': async ({ agentId }) => {
        if (this.agentOptions.known(agentId)) return
        await agents.readFirstOptions(agentId)
      },
      'agents.refreshLimits': ({ agentId, force }) => agents.refreshLimits(agentId, { force }),
      'agents.spendReset': ({ agentId, creditId, requestId }) =>
        agents.spendReset(agentId, creditId, requestId),
      'agents.details': ({ agentId }) => agents.details(agentId),
      'agents.claudeSettings': ({ agentId }) =>
        agents.claudeSettings(agentId, listedModels(this.agentOptions.get(agentId)?.config)),
      'agents.setClaudeSetting': ({ agentId, change }) => agents.setClaudeSetting(agentId, change),
      'agents.autoCompact': ({ agentId }) =>
        agents.autoCompact(agentId, this.agentOptions.get(agentId)?.config, () =>
          this.appServer(agentId),
        ),
      'agents.setAutoCompact': ({ agentId, change }) =>
        agents.setAutoCompact(agentId, change, () => this.appServer(agentId)),
      'agents.codebuddySettings': ({ agentId }) => agents.codebuddySettings(agentId),
      'agents.setCodebuddySite': ({ agentId, change }) => agents.setCodebuddySite(agentId, change),
      'agents.refreshAccount': ({ agentId, force }) => agents.refreshAccount(agentId, { force }),
      'agents.options': () => this.agentOptions.list().map((o) => this.withStartMode(o)),
      'agents.pinModel': ({ agentId, model, pinned }) =>
        this.agentOptions.pin(agentId, model, pinned),
      'agents.setPinnedModels': ({ agentId, models }) =>
        this.agentOptions.setPinned(agentId, models),
      'agents.lightAgents': () => ({ agents: this.sessions.lightAgents() }),
      'agents.draftReport': (params) => this.draftReport(params),
      'mcp.status': () => this.mcpStatus(),
      'market.catalog': ({ refresh, cached }) =>
        this.marketCatalog.catalog(refresh === true, cached === true),
      'market.search': ({ query }) => this.marketCatalog.search(query),
      'market.keys': () => keyState(this.settings.marketplace.mcp, this.marketKeys),
      'market.connect': ({ serverId }) => this.marketConnections.connect(serverId),
      'market.detectSignIn': async ({ url, headers }) => ({
        oauth: await this.marketConnections.detect(
          url,
          Object.fromEntries(headers.map((header) => [header.name, header.value])),
        ),
      }),
      'market.cancelConnect': ({ loginId }) => this.marketConnections.cancel(loginId),
      'market.disconnect': ({ serverId }) => this.marketConnections.disconnect(serverId),
      'market.connections': () => this.marketConnections.view(),
      'market.plugins': ({ refresh, cached }) =>
        this.marketPlugins.plugins(refresh === true, cached === true),
      'market.pluginDetails': ({ agentId, pluginId }) =>
        this.marketPlugins.details(agentId, pluginId),
      'market.pluginLogo': ({ pluginId }) => this.marketPlugins.logo(pluginId),
      'market.installPlugin': ({ agentId, pluginId, scope, projectPath }) =>
        this.marketPlugins.install(agentId, pluginId, scope, projectPath ?? null),
      'market.uninstallPlugin': ({ agentId, pluginId, scope, projectPath }) =>
        this.marketPlugins.uninstall(agentId, pluginId, scope, projectPath ?? null),
      'market.setPluginEnabled': ({ agentId, pluginId, enabled, scope, projectPath }) =>
        this.marketPlugins.setEnabled(agentId, pluginId, enabled, scope, projectPath ?? null),
      'market.addMarketplace': ({ agentId, source }) =>
        this.marketPlugins.addMarketplace(agentId, source),
      'market.removeMarketplace': ({ agentId, name }) =>
        this.marketPlugins.removeMarketplace(agentId, name),
      'market.skills': ({ refresh, cached }) =>
        this.marketSkills.skills(refresh === true, cached === true),
      'market.skillRepository': ({ id, refresh }) =>
        this.marketSkills.repository(id, refresh === true),
      'market.addSkill': ({ source }) => this.marketSkills.add(source),
      'settings.answerChange': ({ sessionId, entryId, decision }, { device }) =>
        this.sessions.answerSettings(sessionId, entryId, decision, fromDevice(device)),
      'settings.undoChange': ({ sessionId, entryId }) => this.undoSettings(sessionId, entryId),
      'mcp.retry': async () => {
        await this.mcpService.start()
        this.options.send({ type: 'host:service-port', port: this.mcpService.listeningPort })
        return this.mcpStatus()
      },
      'agents.listSessions': ({ agentId, projectPath, cursor }) =>
        sessions.listImportable(agentId, projectPath, cursor ?? null),
      'projects.list': () => {
        void projects.refreshMissing()
        return projects.list()
      },
      'projects.add': ({ path }) => projects.add(path),
      'projects.remove': async ({ path }) => {
        const record = projects.match(path)
        await sessions.removeProject(record.path)
        projects.remove(record)
        this.options.send({ type: 'host:media-revoke', sessionId: null })
      },
      'projects.touch': ({ path }) => projects.touch(projects.match(path)),
      'projects.pin': ({ path, pinned }) =>
        path === null ? projects.pinNoProject(pinned) : projects.pin(projects.match(path), pinned),
      'projects.move': ({ path, before }) =>
        projects.move(projects.match(path), before === null ? null : projects.match(before)),
      'projects.noProject': () => projects.noProject(),
      'projects.worktreeSettings': ({ path }) =>
        projects.worktreeSettings(projects.match(path).path),
      'projects.setWorktreeSettings': ({ path, settings }, { device }) => {
        if (isRemoteDevice(device) && !this.settings.remoteTerminal) {
          throw new HostError(
            'forbidden',
            'A paired device may not call "projects.setWorktreeSettings"',
          )
        }
        return projects.setWorktreeSettings(projects.match(path).path, settings)
      },
      'paths.complete': ({ path }) =>
        completePath(path, this.options.platform, this.options.homeDir ?? os.homedir()),
      'sessions.list': ({ projectPath }) => sessions.list(projectPath),
      'sessions.changes': ({ since }) => sessions.changes(since),
      'events.select': ({ types }, { portId }) => this.hub.selectEvents(portId, types),
      'sessions.create': async (params, { portId, device }) => {
        // A worktree is made with git, which is found as the agents find it.
        if (params.worktree) await this.env.ready()
        const onCreated = params.prompt
          ? (sessionId: string) => this.shareSurfaces(sessionId, params.prompt!)
          : undefined
        return sessions.create(
          {
            ...(isRemoteDevice(device) ? { ...params, device: fromDevice(device) } : params),
            ...(onCreated ? { onCreated } : {}),
          },
          portId,
        )
      },
      'sessions.prepare': (params, { portId }) => sessions.prepare(params, portId),
      'sessions.discard': ({ sessionId }) => sessions.discard(sessionId),
      'sessions.import': (params) => sessions.importSession(params),
      'sessions.open': async ({ sessionId }, { device }) =>
        digestsFor(
          device,
          await sessions.open(sessionId, imagesFor(device), pageBudgetFor(device)),
        ),
      'sessions.snapshot': async ({ sessionId, from }, { device }) =>
        digestsFor(
          device,
          await sessions.snapshot(sessionId, from, imagesFor(device), pageBudgetFor(device)),
        ),
      'sessions.page': async ({ sessionId, before, from }, { device }) =>
        digestsFor(
          device,
          await sessions.page(sessionId, before, from, imagesFor(device), pageBudgetFor(device)),
        ),
      'sessions.entry': async ({ sessionId, entryId }, { device }) => {
        const entry = await sessions.entry(sessionId, entryId, imagesFor(device))
        return device ? fitSingleEntry(entry, REMOTE_ENTRY_BYTES) : entry
      },
      'sessions.requests': ({ sessionId }, { device }) =>
        sessions.requests(sessionId, imagesFor(device)),
      'sessions.outline': ({ sessionId }) => sessions.outline(sessionId),
      'sessions.modelRequests': ({ sessionId, before }) =>
        sessions.modelRequests(sessionId, before ?? null),
      'sessions.modelRequestsOverview': ({ sessionId }) =>
        sessions.modelRequestsOverview(sessionId),
      'sessions.modelRequestRaw': ({ sessionId, raw, full }) =>
        sessions.modelRequestRaw(sessionId, raw, full === true),
      'sessions.search': ({ query }) => sessions.search(query),
      'sessions.find': ({ sessionId, query }) => sessions.find(sessionId, query),
      'sessions.outputs': ({ sessionId }) => sessions.outputs(sessionId),
      'sessions.outlineTitles': ({ sessionId }) => sessions.outlineTitles(sessionId),
      'sessions.watch': ({ sessionId }, { portId }) => sessions.watch(sessionId, portId),
      'sessions.unwatch': ({ sessionId }, { portId }) => sessions.unwatch(sessionId, portId),
      'sessions.show': ({ sessionIds }, { portId }) => sessions.show(sessionIds, portId),
      'sessions.prompt': ({ sessionId, content }, { portId, device }) => {
        this.shareSurfaces(sessionId, content)
        return sessions.prompt(sessionId, content, portId, fromDevice(device))
      },
      'sessions.attachEarly': ({ sessionId }) => sessions.attachEarly(sessionId),
      'sessions.cancel': ({ sessionId }) => sessions.cancel(sessionId),
      'sessions.runningWork': ({ sessionIds }) => ({ sessions: sessions.runningWork(sessionIds) }),
      'sessions.idleRelease': () => this.idleRelease.state(),
      'sessions.stopTask': ({ sessionId, taskId }) => sessions.stopTask(sessionId, taskId),
      'sessions.taskOutput': ({ sessionId, taskId }) => sessions.taskOutput(sessionId, taskId),
      'sessions.retry': ({ sessionId }, { portId }) => sessions.retry(sessionId, portId),
      'sessions.cancelContinue': ({ sessionId }) => sessions.cancelContinue(sessionId),
      'sessions.rewind': ({ sessionId, entryId, draft }) =>
        sessions.rewind(sessionId, entryId, draft),
      'sessions.putBack': ({ sessionId }) => sessions.putBack(sessionId),
      'sessions.fork': ({ sessionId, entryId, worktree }) =>
        sessions.fork(sessionId, entryId, worktree),
      'worktrees.inspect': ({ sessionId }) =>
        this.gitCall(() => sessions.inspectWorktree(sessionId)),
      'worktrees.remove': ({ sessionId, branch, expected }) =>
        this.gitCall(() => sessions.removeWorktree(sessionId, branch, expected)),
      'worktrees.retrySetup': ({ sessionId }) => sessions.retryWorktreeSetup(sessionId),
      'worktrees.skipSetup': ({ sessionId }) => sessions.skipWorktreeSetup(sessionId),
      'worktrees.setupLog': ({ sessionId, from }) => sessions.worktreeSetupLog(sessionId, from),
      'sessions.switchAgent': (params, { portId, device }) => {
        this.shareSurfaces(params.sessionId, params.content)
        return sessions.switchAgent(params, portId, fromDevice(device))
      },
      'sessions.context': ({ sessionId }) => sessions.context(sessionId),
      'sessions.contextEstimates': ({ sessionId }) => sessions.contextEstimates(sessionId),
      'sessions.queue': ({ sessionId, content, comments }, { portId, device }) => {
        this.shareSurfaces(sessionId, content)
        return sessions.queue(sessionId, content, portId, fromDevice(device), comments)
      },
      'sessions.runCommand': (params, { portId, device }) =>
        this.runReplyCommand(params, portId, device),
      'sessions.unqueue': ({ sessionId, itemId }) => sessions.unqueue(sessionId, itemId),
      'sessions.steer': ({ sessionId, itemId }) => sessions.steer(sessionId, itemId),
      'sessions.sendNow': ({ sessionId, itemId }) => sessions.sendNow(sessionId, itemId),
      'sessions.resumeQueue': ({ sessionId }) => sessions.resumeQueue(sessionId),
      'sessions.blob': ({ sessionId, hash }) => sessions.blob(sessionId, hash),
      'sessions.setConfigOption': ({ sessionId, optionId, value }) =>
        sessions.setConfigOption(sessionId, optionId, value),
      'sessions.refreshModels': ({ sessionId }) => sessions.refreshModels(sessionId),
      'sessions.rename': ({ sessionId, title }) => sessions.rename(sessionId, title),
      'sessions.close': async ({ sessionId }) => {
        await sessions.close(sessionId)
        this.forgetSharedSurfaces(sessionId)
      },
      'sessions.pin': ({ sessionId, pinned }) => sessions.pin(sessionId, pinned),
      'sessions.archive': ({ sessionId, subSessions }) =>
        sessions.archive(sessionId, subSessions ?? true),
      'sessions.unarchive': ({ sessionId }) => sessions.unarchive(sessionId),
      'sessions.markUnread': ({ sessionId, unread }) => sessions.markUnread(sessionId, unread),
      'sessions.delete': async ({ sessionId }) => {
        await sessions.delete(sessionId)
        this.forgetSharedSurfaces(sessionId)
        this.options.send({ type: 'host:media-revoke', sessionId })
      },
      'sessions.removeEmpty': ({ keep }) => sessions.removeEmptyOnce(keep),
      'sessions.takeReturned': ({ sessionId }, { portId }) =>
        sessions.takeReturned(sessionId, portId),
      'sessions.removeAll': async () => {
        await sessions.removeAll()
        this.sharedTerminals.clear()
        this.sharedTabs.clear()
        this.sharedDevices.clear()
        this.options.send({ type: 'host:media-revoke', sessionId: null })
      },
      'permissions.respond': (
        { sessionId, requestId, optionId, note, answers, values },
        { device },
      ) =>
        sessions.respond(
          sessionId,
          requestId,
          answers
            ? { answers }
            : values
              ? { values }
              : { optionId: optionId!, ...(note === undefined ? {} : { note }) },
          fromDevice(device),
        ),
      'git.status': async ({ projectPath, watcher }, { portId }) => {
        const git = this.requireGit()
        const canonical = await this.gitProject(projectPath)
        await this.env.ready()
        if (!this.hub.has(portId)) return this.gitCall((g) => g.status(canonical))
        const key = pathKey(canonical, this.options.platform)
        if (this.gitRetains.add(key, canonical, portId, watcher ?? '')) {
          git.retain(canonical, portId)
        }
        return this.gitCall((g) => g.status(canonical))
      },
      'git.unwatch': async ({ projectPath, watcher }, { portId }) => {
        const git = this.requireGit()
        // The folder may be gone by now; the retained entry still knows its canonical path.
        const canonical = await projects.resolveDirectory(projectPath).catch(() => projectPath)
        const key = pathKey(canonical, this.options.platform)
        const path = this.gitRetains.remove(key, portId, watcher ?? '')
        if (path !== null) git.release(path, portId)
      },
      'git.fetch': ({ projectPath }) => this.gitProjectCall(projectPath, (g, p) => g.fetch(p)),
      'git.pull': ({ projectPath }) => this.gitProjectCall(projectPath, (g, p) => g.pull(p)),
      'git.push': ({ projectPath, remote, branch }) =>
        this.gitProjectCall(projectPath, (g, p) => g.push(p, { remote, branch })),
      'git.publish': ({ projectPath, name, visibility }) =>
        this.gitProjectCall(projectPath, (g, p) => g.publish(p, name, visibility)),
      'git.createPullRequest': ({ projectPath, title, body, base, draft }) =>
        this.gitProjectCall(projectPath, (g, p) =>
          g.createPullRequest(p, { title, body, base, draft }),
        ),
      'git.commit': ({ projectPath, oid }) =>
        this.gitProjectCall(projectPath, (g, p) => g.commit(p, oid)),
      'git.changes': ({ projectPath }) => this.gitProjectCall(projectPath, (g, p) => g.changes(p)),
      'git.commitMessage': ({ projectPath, paths }) => this.commitMessage(projectPath, paths),
      'git.pullRequestDraft': ({ projectPath, base }) => this.pullRequestDraft(projectPath, base),
      'git.incoming': ({ projectPath, from }) =>
        this.gitProjectCall(projectPath, (g, p) => g.incoming(p, from)),
      'git.fileDiff': ({ projectPath, path, oldPath, ref }) =>
        this.gitProjectCall(projectPath, (g, p) => g.fileDiff(p, path, oldPath, ref)),
      'git.branches': ({ projectPath }) =>
        this.gitProjectCall(projectPath, (g, p) => g.branches(p)),
      'git.switchBranch': ({ projectPath, branch, create }) =>
        this.gitProjectCall(projectPath, (g, p) => g.switchBranch(p, branch, create)),
      'git.publishBranch': ({ projectPath, remote }) =>
        this.gitProjectCall(projectPath, (g, p) => g.publishBranch(p, remote)),
      'git.commitChanges': ({ projectPath, message, paths }) =>
        this.gitProjectCall(projectPath, (g, p) => g.commitChanges(p, message, paths)),
      'git.discardChanges': ({ projectPath, paths }) =>
        this.gitProjectCall(projectPath, (g, p) => g.discardChanges(p, paths)),
      'git.pullRequest': ({ url }) => this.gitCall((g) => g.pullRequest(url)),
      'git.issue': ({ url }) => this.gitCall((g) => g.issue(url)),
      // Its first sweep probes gh, so it waits for the environment as every other git call does.
      'git.watchReferences': ({ urls }, { portId }) =>
        this.gitCall(async (g) => {
          if (this.hub.has(portId)) g.watchReferences(portId, urls)
        }),
      'git.avatarUrl': ({ login }) => this.gitCall((g) => g.avatarUrl(login)),
      'git.currentPullRequest': ({ projectPath }) =>
        this.gitProjectCall(projectPath, (g, p) => g.currentPullRequest(p)),
      'git.tools': () => this.gitCall((g) => g.tools()),
      'attachments.add': ({ source, thumb }) =>
        'projectPath' in source
          ? this.filesCall(source.projectPath, async (root) => {
              const found = await this.files.locate(root, source.path)
              return this.attachments.addPath(found.path, found.kind, thumb)
            })
          : this.attachments.add(source, thumb),
      'attachments.read': ({ id }) => this.attachments.read(id),
      'attachments.update': ({ id, thumb, scaled }) => this.attachments.update(id, thumb, scaled),
      'attachments.remove': ({ id }) => this.attachments.remove(id),
      'attachments.held': ({ ids }) => this.attachments.held(ids),
      'files.list': ({ projectPath }) =>
        this.filesCall(projectPath, async (root) => {
          const list = await this.files.list(root)
          this.fileWatches.listed(root, list)
          return list
        }),
      'files.watch': async ({ projectPath }, { portId }) => {
        const root = await projects.resolveDirectory(projectPath)
        this.assertOpenFolder(root)
        if (this.hub.has(portId)) this.fileWatches.add(root, portId, projectPath)
      },
      'files.unwatch': async ({ projectPath }, { portId }) => {
        // The folder may be gone by now, and its watch with it.
        const root = await projects.resolveDirectory(projectPath).catch(() => projectPath)
        this.fileWatches.remove(root, portId)
      },
      'files.listFolder': ({ projectPath, path }) =>
        this.filesCall(projectPath, async (root) => {
          const list = await this.files.listFolder(root, path)
          this.fileWatches.read(root, path)
          return list
        }),
      'files.read': ({ projectPath, path, asText }, { device }) =>
        this.filesCall(projectPath, async (root) => {
          // A device's media is read through its remote host, never main's media scheme.
          const content = await this.files.read(root, path, asText, device !== null)
          this.fileWatches.opened(root, path)
          return content
        }),
      'files.search': ({ projectPath, query }) =>
        this.filesCall(projectPath, (root) => this.files.search(root, query)),
      'files.agentFolder': ({ sessionId }) => this.agentFiles.folder(sessionId),
      'files.readAgentFile': ({ sessionId, path }) => this.agentFiles.read(sessionId, path),
      'files.write': ({ projectPath, path, text, version }) =>
        this.filesCall(projectPath, (root) => this.files.write(root, path, text, version)),
      'files.create': ({ projectPath, path, kind }) =>
        this.filesCall(projectPath, (root) => this.files.create(root, path, kind)),
      'files.rename': ({ projectPath, from, to }) =>
        this.filesCall(projectPath, (root) => this.files.rename(root, from, to)),
      'files.copy': ({ projectPath, paths, folder }) =>
        this.filesCall(projectPath, (root) => this.files.copy(root, paths, folder)),
      'files.upload': ({ projectPath, path, source, replace }) =>
        this.filesCall(projectPath, (root) =>
          this.files.upload(
            root,
            path,
            'grantId' in source
              ? { path: this.attachments.takeGrant(source.grantId).path }
              : source,
            replace === true,
          ),
        ),
      'files.delete': ({ projectPath, paths, permanently }) =>
        this.filesCall(projectPath, (root) => this.files.delete(root, paths, permanently === true)),
      'files.preview': ({ sessionId, path }, { device }) => {
        // Served on this computer's loopback address, which only its own browser reaches.
        if (device) throw new HostError('forbidden', 'Only a window may call "files.preview"')
        return this.htmlPreviews.url(sessionId, path)
      },
      'media.open': async ({ projectPath, path, sessionId }) => {
        const root = await projects.resolveDirectory(projectPath)
        this.assertOpenFolder(root)
        return this.media.open(root, path, sessionId)
      },
      'media.authorize': async ({ projectPath, path, sessionId }, { device }) => {
        // A window has the media scheme; only a device's remote host streams from the path.
        if (!device) {
          throw new HostError('forbidden', 'Only a paired device may call "media.authorize"')
        }
        const root = await projects.resolveDirectory(projectPath)
        this.assertOpenFolder(root)
        return this.media.authorize(root, path, sessionId ?? null)
      },
      'usage.summary': ({ dayStarts, from, to, scope, clock }) =>
        this.usage.summary(dayStarts, from, to, scope, clock),
      'usage.overview': ({ scope }) => this.usage.overview(scope),
      'usage.total': ({ from, to }) => this.usage.total(from, to),
      'usage.status': () => this.usage.status(),
      'usage.sync': () => this.usage.sync(),
      'usage.reimport': ({ agentId }) => this.usage.reimport(agentId),
      'usage.clearRecord': () => this.usage.clearRecord(),
      'usage.forgetAccount': ({ agentId, account }) => this.usage.forgetAccount(agentId, account),
      'browser.answer': ({ callId, answer }, ctx) => {
        browserApp(ctx)
        if (!this.deviceBrowser.answer(ctx.portId, callId, answer)) {
          throw new HostError('not_found', 'This port was sent no such browser call')
        }
      },
      'browser.waiting': ({ callId, waiting }, ctx) => {
        browserApp(ctx)
        if (this.deviceBrowser.owns(ctx.portId, callId)) {
          this.mcpService.browserWaiting(callId, waiting)
        }
      },
      'browser.origin': ({ sessionId, requestId, origin }, ctx) => {
        browserApp(ctx)
        // Only the app the session's calls go to asks for its page.
        const target = browserTarget(sessions.browserSender(sessionId), this.hub)
        if (target.kind !== 'device' || target.portId !== ctx.portId) {
          throw new HostError('forbidden', 'This port does not drive the session’s browser')
        }
        sessions.browserOriginAsked(sessionId, requestId, origin, ctx.portId)
      },
      'browser.originSettled': ({ requestId, decision }, ctx) => {
        browserApp(ctx)
        sessions.browserOriginSettled(requestId, decision, ctx.portId, fromDevice(ctx.device))
      },
      'browser.handedBack': ({ sessionId, durationMs }, ctx) => {
        browserApp(ctx)
        const target = this.browserTurns.targetOf(sessionId)
        if (target?.kind !== 'device' || target.portId !== ctx.portId) {
          throw new HostError('forbidden', 'This port does not drive the session’s browser')
        }
        sessions.controlHandedBack(sessionId, 'browser', durationMs)
      },
      // The first answer goes to the page, whose waiting call then settles the card.
      'control.answerAsk': ({ sessionId, entryId, outcome }, { device }) => {
        sessions.answerControlAsk(sessionId, entryId, outcome, fromDevice(device))
        const target = this.browserTurns.targetOf(sessionId)
        if (!target || target.kind === 'main') {
          this.options.send({ type: 'host:browser-ask-answer', sessionId, outcome })
        } else {
          this.hub.send([target.portId], { type: 'browser.askAnswered', sessionId, outcome })
        }
      },
      'computer.answerApp': ({ sessionId, entryId, decision }, { device }) => {
        const requestId = sessions.answerComputerApp(
          sessionId,
          entryId,
          decision,
          fromDevice(device),
        )
        if (!this.computer?.answer(requestId, decision)) {
          throw new HostError('not_found', t('session.waiting.app.gone'))
        }
      },
      'sessions.answerProjectMcp': ({ sessionId, entryId, decision }, { device }) => {
        sessions.answerProjectMcp(sessionId, entryId, decision, fromDevice(device))
      },
      'sessions.answerProjectHooks': ({ sessionId, entryId, decision }, { device }) => {
        sessions.answerProjectHooks(sessionId, entryId, decision, fromDevice(device))
      },
      'sessions.answerReport': ({ sessionId, entryId, outcome }, { device }) =>
        sessions.answerReport(sessionId, entryId, outcome, fromDevice(device)),
      'sessions.answerMemory': ({ sessionId, entryId, decision }, { device }) =>
        memoryCall(() => sessions.answerMemory(sessionId, entryId, decision, fromDevice(device))),
      'sessions.undoMemory': ({ sessionId, entryId }) =>
        memoryCall(() => sessions.undoMemory(sessionId, entryId)),
      'memory.overview': () => memoryCall(() => memory.overview()),
      'memory.list': ({ scope }) => memoryCall(() => memory.list(scope)),
      'memory.save': ({ scope, id, draft }) =>
        memoryCall(async () => (await memory.save(scope, id, draft, BY_USER)).entry),
      'memory.remove': ({ scope, id }) =>
        memoryCall(async () => {
          await memory.remove(scope, id, BY_USER)
        }),
      'memory.moveToGlobal': ({ project, id }) =>
        memoryCall(() => memory.moveToGlobal(project, id)),
      'memory.setEnabled': ({ enabled }) =>
        memoryCall(async () => {
          const was = memory.enabled
          await memory.setEnabled(enabled)
          if (memory.enabled !== was) sessions.memorySwitched()
        }),
      'memory.importScan': () => memoryCall(() => memory.importScan()),
      'memory.import': ({ sources, global }) => memoryCall(() => memory.import(sources, global)),
      'computer.stop': ({ sessionId }) => {
        this.computer?.stop(sessionId)
      },
      'computer.takeOver': ({ sessionId }) => {
        this.computer?.takeOver(sessionId)
      },
      'computer.handBack': ({ sessionId }) => {
        this.computer?.handBack(sessionId)
      },
      'computer.show': async ({ sessionId }, { device }) => {
        // The window comes forward on this computer, for someone in front of it.
        if (device) throw new HostError('forbidden', t('hostError.showHere'))
        await this.computer?.show(sessionId)
      },
      'computer.declineSetup': ({ sessionId, entryId }, { device }) => {
        const requestId = sessions.declineComputerSetup(sessionId, entryId, fromDevice(device))
        if (!this.computer?.declineSetup(requestId)) {
          throw new HostError('not_found', t('session.waiting.setup.gone'))
        }
      },
      'browser.answerOrigin': ({ sessionId, entryId, decision }, { device }) => {
        const { owner, requestId } = sessions.answerOrigin(
          sessionId,
          entryId,
          decision,
          fromDevice(device),
        )
        if (owner === '') {
          this.options.send({ type: 'host:browser-origin-decide', sessionId, requestId, decision })
        } else {
          this.hub.send([owner], { type: 'browser.originDecided', sessionId, requestId, decision })
        }
      },
      'devices.answerAccess': ({ sessionId, entryId, decision }, { device }) => {
        sessions.answerDeviceAccess(sessionId, entryId, decision, fromDevice(device))
      },
      'surfaces.answerAccess': ({ sessionId, entryId, decision }, { device }) => {
        sessions.answerSurfaceAccess(sessionId, entryId, decision, fromDevice(device))
      },
      'terminals.revokeAccess': ({ sessionId, terminalId }) =>
        this.revokeTerminal(sessionId, terminalId),
      'devices.revokeAccess': ({ sessionId, deviceId }) => {
        this.mcpService.revokeDevice(sessionId, deviceId)
        sessions.deviceAccessRevoked(sessionId, deviceId)
      },
      'devices.allowed': async () => {
        await this.deviceAccess.ready
        return { deviceIds: this.deviceAccess.list() }
      },
      'devices.forget': ({ deviceId }) => this.deviceAccess.remove(deviceId),
      'app.updateStatus': () => this.resolvedAppUpdateStatus(),
      'app.reportUpdateState': (status, { device }) => {
        if (device)
          throw new HostError('forbidden', 'Only the local desktop app may report update state')
        this.appUpdateState = status
        this.hub.broadcast({ type: 'app.updateState', status })
      },
      'app.requestUpdate': ({ action }) => {
        const local = this.hub.localPorts()
        const status = this.resolvedAppUpdateStatus()
        if (local.length === 0) {
          return { accepted: false, reason: 'app_not_running', status }
        }
        if (action === 'install' && this.appUpdateState && !this.appUpdateState.canInstall) {
          return { accepted: false, reason: 'install_unavailable', status }
        }
        this.hub.send(local, { type: 'app.updateCommand', action })
        return { accepted: true, status }
      },
      'host.load.watch': (_, { portId }) => this.load.watch(portId),
      'host.load.unwatch': (_, { portId }) => this.load.unwatch(portId),
      'remoteClaude.hosts': () => this.remoteClaudeManager.listAvailableHosts(),
      'remoteClaude.active': () => this.remoteClaudeHost.activeRuns(),
      'remoteClaude.disconnectAll': () => this.remoteClaudeHost.disconnectAll(),
      'remoteClaude.status': () => this.remoteClaudeHost.status(),
      'remoteClaude.open': async (params, { portId, device }) => {
        if (!device) {
          throw new HostError(
            'forbidden',
            'remoteClaude.open is only accepted from paired devices.',
          )
        }
        await this.shadowsCleared
        return this.remoteClaudeHost.open(portId, device, params)
      },
      'remoteClaude.prompt': (params, { portId, device }) => {
        if (!device) {
          throw new HostError(
            'forbidden',
            'remoteClaude.prompt is only accepted from paired devices.',
          )
        }
        return this.remoteClaudeHost.prompt(portId, params)
      },
      'remoteClaude.cancel': ({ runId }, { portId, device }) => {
        if (!device) {
          throw new HostError(
            'forbidden',
            'remoteClaude.cancel is only accepted from paired devices.',
          )
        }
        return this.remoteClaudeHost.cancel(portId, runId)
      },
      'remoteClaude.setConfig': (params, { portId, device }) => {
        if (!device) {
          throw new HostError(
            'forbidden',
            'remoteClaude.setConfig is only accepted from paired devices.',
          )
        }
        return this.remoteClaudeHost.setConfig(portId, params)
      },
      'remoteClaude.close': ({ runId }, { portId, device }) => {
        if (!device) {
          throw new HostError(
            'forbidden',
            'remoteClaude.close is only accepted from paired devices.',
          )
        }
        return this.remoteClaudeHost.close(portId, runId)
      },
      'remoteClaude.mcpAnswer': (params, { portId, device }) => {
        if (!device) {
          throw new HostError(
            'forbidden',
            'remoteClaude.mcpAnswer is only accepted from paired devices.',
          )
        }
        this.remoteClaudeHost.mcpAnswer(portId, params)
      },
      'remoteClaude.permissionAnswer': (params, { portId, device }) => {
        if (!device) {
          throw new HostError(
            'forbidden',
            'remoteClaude.permissionAnswer is only accepted from paired devices.',
          )
        }
        this.remoteClaudeHost.permissionAnswer(portId, params)
      },
    }
  }

  private resolvedAppUpdateStatus(): AppUpdateStatus {
    if (this.appUpdateState && this.hub.localPorts().length > 0) {
      return this.appUpdateState
    }
    return {
      currentVersion: this.options.appVersion,
      state: 'idle',
      mode: 'unavailable',
      canInstall: false,
      updatedAt: Date.now(),
    }
  }
}
