// Process trees: everything an agent started, found in one listing of the system's processes
// and stopped together. An agent's own process group is not enough on macOS and Linux: Claude
// Code runs each command in a group of its own, and a command whose CLI is killed outlives it.
// Main imports this file too, for the agents of a host that died.

import { execFile } from 'node:child_process'
import path from 'node:path'
import type { Platform } from '@shared/platform'
import { t } from './i18n'

export interface ProcessRow {
  pid: number
  ppid: number
  /** The process group. */
  pgid: number
  /** Milliseconds since the epoch; from `ps`, to within a second. */
  startedAt: number
}

/** A process named by its start time as well, so a reused pid is never taken for it. */
export interface ProcessId {
  pid: number
  startedAt: number
}

export interface TreeRoot extends ProcessId {
  /**
   * When it was last known to run. Once it has exited, only what started by then can be its:
   * a process that took its pid later may have started a group or children of its own. Without
   * it, an exited root's group and children are not followed.
   */
  seenAt?: number
}

/** How far two readings of one process's start time may differ: `ps` reports whole seconds. */
export const START_SLACK_MS = 2_000

export function isProcess(row: ProcessRow, id: ProcessId): boolean {
  return row.pid === id.pid && Math.abs(row.startedAt - id.startedAt) <= START_SLACK_MS
}

/** `ps -A -o pid=,ppid=,pgid=,etime=`, where etime is `[[dd-]hh:]mm:ss`. */
export function parsePs(text: string, now: number): ProcessRow[] {
  const rows: ProcessRow[] = []
  for (const line of text.split('\n')) {
    const match = /^\s*(\d+)\s+(\d+)\s+(\d+)\s+(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+)\s*$/.exec(line)
    if (!match) continue
    const [, pid, ppid, pgid, days, hours, minutes, seconds] = match
    const elapsed =
      ((Number(days ?? 0) * 24 + Number(hours ?? 0)) * 60 + Number(minutes)) * 60 + Number(seconds)
    rows.push({
      pid: Number(pid),
      ppid: Number(ppid),
      pgid: Number(pgid),
      startedAt: now - elapsed * 1000,
    })
  }
  return rows
}

export interface ToolOptions {
  /** A quit waits for it, which main cuts short: it gets the quit's shorter limit. */
  quitting?: boolean
}

/** What a quit aborts a tool's run with, so that the run's stop gets the quit's limits too. */
export const QUIT_REASON = new Error('Sarto is quitting')

export interface ProcessControl {
  platform: Platform
  list(options?: ToolOptions): Promise<ProcessRow[]>
  /** `process.kill`: a negative target addresses a process group; throws `ESRCH` once it is gone. */
  kill(target: number, signal: NodeJS.Signals | 0): void
  delay(ms: number): Promise<void>
}

/** How long one run of each tool may take before it is killed and its call fails. */
export interface ToolLimits {
  /** A `ps` listing. */
  listMs: number
  quitListMs: number
}

/**
 * Long enough for a slow machine, except while quitting, which main cuts short 6 s after
 * `host:shutdown`.
 */
export function toolLimits(): ToolLimits {
  return {
    listMs: 10_000,
    quitListMs: 1_000,
  }
}

/** Runs a tool to its end. Past `timeoutMs` it is killed, and the run fails with `ETIMEDOUT`. */
export function runTool(
  file: string,
  args: string[],
  timeoutMs: number,
  env?: NodeJS.ProcessEnv,
): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile(
      file,
      args,
      {
        windowsHide: true,
        maxBuffer: 16 * 1024 * 1024,
        timeout: timeoutMs,
        killSignal: 'SIGKILL',
        ...(env ? { env } : {}),
      },
      (error, stdout) => {
        if (!error) resolve(stdout)
        // `killed` is set only when execFile itself killed it, which here is the timeout.
        else if (error.killed) reject(toolTimedOut(file, timeoutMs))
        else reject(error)
      },
    )
  })
}

function toolTimedOut(file: string, timeoutMs: number): NodeJS.ErrnoException {
  const name = path.posix.basename(file)
  return Object.assign(new Error(t('process.toolTimedOut', { name, ms: timeoutMs })), {
    code: 'ETIMEDOUT',
  })
}

export interface ProcessControlOptions {
  limits?: ToolLimits
  /** Runs the tools; `runTool` by default. */
  run?: typeof runTool
}

/** How long a listing waits for others to share its run with; a quit's does not wait. */
const LIST_BATCH_MS = 50

interface Listings {
  /** The listing not yet started, which a listing asked for now joins, by time limit. */
  next: Map<number, Promise<ProcessRow[]>>
  /** When a listing with that limit last timed out. */
  timedOutAt: Map<number, number>
}

/** The real tool's listings, shared by every control of the process: one `ps` serves them all. */
const toolListings: Listings = { next: new Map(), timedOutAt: new Map() }

/**
 * One run of the tool for the listings asked for within `LIST_BATCH_MS`, such as those of every
 * process of an agent that stops. A listing asked for within its time limit after one timed out
 * fails at once: the tool is that slow now, and a stop should not wait for it again.
 */
function sharedListing(
  listings: Listings,
  limitMs: number,
  batchMs: number,
  read: () => Promise<ProcessRow[]>,
): Promise<ProcessRow[]> {
  const timedOutAt = listings.timedOutAt.get(limitMs)
  if (timedOutAt !== undefined && Date.now() - timedOutAt < limitMs) {
    return Promise.reject(
      Object.assign(new Error(`The process listing timed out less than ${limitMs} ms ago`), {
        code: 'ETIMEDOUT',
      }),
    )
  }
  let listing = listings.next.get(limitMs)
  if (!listing) {
    listing = new Promise<void>((resolve) => setTimeout(resolve, batchMs)).then(() => {
      listings.next.delete(limitMs)
      return read().catch((error: unknown) => {
        if ((error as NodeJS.ErrnoException).code === 'ETIMEDOUT') {
          listings.timedOutAt.set(limitMs, Date.now())
        }
        throw error
      })
    })
    listings.next.set(limitMs, listing)
  }
  return listing
}

export function processControl(
  platform: Platform,
  { limits = toolLimits(), run = runTool }: ProcessControlOptions = {},
): ProcessControl {
  const listings = run === runTool ? toolListings : { next: new Map(), timedOutAt: new Map() }
  return {
    platform,
    list({ quitting = false } = {}) {
      const limitMs = quitting ? limits.quitListMs : limits.listMs
      const batchMs = quitting ? 0 : LIST_BATCH_MS
      return sharedListing(listings, limitMs, batchMs, () => listWith(run, limitMs))
    },
    kill: (target, signal) => process.kill(target, signal),
    delay: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  }
}

/** One `ps` listing of all running processes. */
async function listWith(run: typeof runTool, limitMs: number): Promise<ProcessRow[]> {
  const text = await run('ps', ['-A', '-o', 'pid=,ppid=,pgid=,etime='], limitMs, {
    ...process.env,
    LC_ALL: 'C',
  })
  return parsePs(text, Date.now())
}

/**
 * The processes in the tree of `root`, the root included while it runs: its process group, whose
 * members keep it after the root exits, and everything descended from the group. Start times tell
 * a reused pid apart: a child never starts before its parent, and after the root exits only what
 * started while it ran (`seenAt`) is followed.
 */
export function treeOf(rows: ProcessRow[], root: TreeRoot): ProcessRow[] {
  const children = new Map<number, ProcessRow[]>()
  for (const row of rows) {
    const list = children.get(row.ppid)
    if (list) list.push(row)
    else children.set(row.ppid, [row])
  }
  const holder = rows.find((row) => row.pid === root.pid)
  const rootRuns = holder !== undefined && isProcess(holder, root)
  const earliest = root.startedAt - START_SLACK_MS
  const latest = rootRuns ? Infinity : (root.seenAt ?? -Infinity) + START_SLACK_MS
  const ran = (row: ProcessRow): boolean => row.startedAt >= earliest && row.startedAt <= latest
  const members = new Map<number, ProcessRow>()
  const queue: ProcessRow[] = []
  const add = (row: ProcessRow): void => {
    if (row.pid <= 1 || row.pid === process.pid || members.has(row.pid)) return
    members.set(row.pid, row)
    queue.push(row)
  }
  if (rootRuns) add(holder)
  // Once another process holds the root's pid, the group id may be that process's.
  if (rootRuns || holder === undefined) {
    for (const row of rows) if (row.pgid === root.pid && ran(row)) add(row)
  }
  for (let i = 0; i < queue.length; i++) {
    const parent = queue[i]!
    for (const child of children.get(parent.pid) ?? []) {
      if (child.startedAt >= parent.startedAt - START_SLACK_MS) add(child)
    }
  }
  return [...members.values()]
}

/**
 * The processes started under `pid`, by parent links alone, for a child that shares its parent's
 * process group. A process that started before its listed parent took a reused pid, so it is not
 * followed.
 */
export function descendantsOf(rows: ProcessRow[], pid: number): ProcessRow[] {
  const root = rows.find((row) => row.pid === pid)
  if (!root) return []
  const found = new Set<ProcessRow>()
  const queue = [root]
  for (let parent = queue.shift(); parent; parent = queue.shift()) {
    for (const row of rows) {
      if (row.ppid !== parent.pid || row === root || found.has(row)) continue
      if (row.startedAt < parent.startedAt - START_SLACK_MS) continue
      found.add(row)
      queue.push(row)
    }
  }
  return [...found]
}

/**
 * Where to send a signal on macOS and Linux: each group a root or a member leads, which reaches
 * processes started after the listing too, and a member of a group outside the trees alone.
 * Negative targets are groups.
 */
export function signalTargets(members: ProcessRow[], leaders: ReadonlySet<number>): number[] {
  const targets = new Set<number>()
  for (const row of members) {
    targets.add(row.pgid > 1 && leaders.has(row.pgid) ? -row.pgid : row.pid)
  }
  return [...targets]
}

export interface StopFailure {
  target: number
  error: string
}

export interface Terminated {
  /** Everything in the trees, once each. */
  members: ProcessRow[]
  /** The roots and the members: the groups they lead are the trees'. */
  leaders: ReadonlySet<number>
  failures: StopFailure[]
}

function signalAll(
  control: ProcessControl,
  targets: number[],
  signal: NodeJS.Signals,
  failures: StopFailure[],
): void {
  for (const target of targets) {
    try {
      control.kill(target, signal)
    } catch (error) {
      // ESRCH: already gone, which is the outcome wanted.
      if ((error as NodeJS.ErrnoException).code !== 'ESRCH') {
        failures.push({ target, error: (error as Error).message })
      }
    }
  }
}

/** Asks the trees of `roots` to stop with `SIGTERM`. */
export async function terminateTrees(
  control: ProcessControl,
  roots: TreeRoot[],
  tools?: ToolOptions,
): Promise<Terminated> {
  const rows = await control.list(tools)
  const members = new Map<number, ProcessRow>()
  for (const root of roots) {
    for (const row of treeOf(rows, root)) members.set(row.pid, row)
  }
  const leaders = new Set([...roots.map((root) => root.pid), ...members.keys()])
  const terminated: Terminated = { members: [...members.values()], leaders, failures: [] }
  if (members.size === 0) return terminated
  signalAll(control, signalTargets(terminated.members, leaders), 'SIGTERM', terminated.failures)
  return terminated
}

function alive(control: ProcessControl, pid: number): boolean {
  try {
    control.kill(pid, 0)
    return true
  } catch {
    // ESRCH: gone. EPERM: the pid now belongs to a process of someone else, so not to the tree.
    return false
  }
}

/** `SIGKILL` to the members of terminated trees that are still there. */
export function killSurvivors(control: ProcessControl, terminated: Terminated): StopFailure[] {
  const failures: StopFailure[] = []
  const survivors = terminated.members.filter((row) => alive(control, row.pid))
  signalAll(control, signalTargets(survivors, terminated.leaders), 'SIGKILL', failures)
  return failures
}

/** Stops the trees of `roots`: `SIGTERM`, then `SIGKILL` to what is left after `graceMs`. */
export async function stopTrees(
  control: ProcessControl,
  roots: TreeRoot[],
  graceMs: number,
): Promise<Terminated> {
  const terminated = await terminateTrees(control, roots)
  if (terminated.members.length === 0) return terminated
  await control.delay(graceMs)
  terminated.failures.push(...killSurvivors(control, terminated))
  return terminated
}
