// The game's work facts, read from the summaries a host sends as its sessions change: the host
// that runs a session is the only one that tells of its work, so no turn is counted twice, and
// the facts do not depend on what a window shows or how often it redraws.

import { randomUUID } from 'node:crypto'
import type { SessionSummary } from '@shared/agent-host'
import type { TokenTotals } from '@shared/thread'
import type { WorkFact, WorkFactBody, WorkFactTokens, WorkKind } from '@shared/work-facts'

// A turn whose summary says nothing new for this long more likely hangs than works; a stretch
// counts at most this much. The clock below stops while the computer sleeps.
const MAX_STRETCH_MS = 30 * 60_000

interface Seen {
  /** When the turn under way started, as the summary says; null between turns. */
  turn: number | null
  /** What the running turn spends its time on since `since`; null while no turn runs. */
  work: WorkKind | null
  since: number
  planRef: string | null
  steps: readonly string[]
  /** The running turn's seconds by kind, and the stretches it waited for the user. */
  turnWork: Record<WorkKind, number>
  waits: { start: number; end: number }[]
  waitSince: number | null
}

const noWork = (): Record<WorkKind, number> => ({ think: 0, scan: 0, command: 0, edit: 0 })

function tokensOf(tokens: TokenTotals): WorkFactTokens {
  return {
    input: tokens.input,
    output: tokens.output,
    thought: tokens.thought ?? 0,
    cacheRead: tokens.cacheRead ?? 0,
    cacheWrite: tokens.cacheWrite ?? 0,
  }
}

export interface WorkFactClock {
  /** Wall time, in ms since the epoch, for the facts' `at`. */
  wall(): number
  /** Monotonic time in ms, for the seconds of work. */
  mono(): number
}

const SYSTEM_CLOCK: WorkFactClock = { wall: () => Date.now(), mono: () => performance.now() }

function counted(summary: SessionSummary): boolean {
  return (
    summary.origin !== 'subagent' &&
    summary.prepared === undefined &&
    summary.archivedAt === null &&
    summary.status !== 'closed'
  )
}

// Turns that did not finish their work.
const UNFINISHED: ReadonlySet<string> = new Set(['failed', 'limit', 'cancelled'])

/** What a running turn does now; null while none runs, as while the agent starts or waits. */
function workOf(summary: SessionSummary): WorkKind | null {
  if (summary.status !== 'running') return null
  switch (summary.phase) {
    case 'thinking':
    case 'writing':
    case 'compacting':
      return 'think'
    case 'read':
    case 'search':
    case 'fetch':
      return 'scan'
    case 'execute':
      return 'command'
    case 'edit':
      return 'edit'
  }
  switch (summary.activity?.toolKind) {
    case 'read':
    case 'search':
    case 'fetch':
      return 'scan'
    case 'execute':
      return 'command'
    case 'edit':
    case 'delete':
    case 'move':
      return 'edit'
  }
  return 'think'
}

export class WorkFactTracker {
  private readonly seen = new Map<string, Seen>()
  /** Tokens per model of a turn that just ended, until the summary that shows it ended. */
  private readonly usage = new Map<string, { model: string; tokens: WorkFactTokens }[]>()
  private counter = 0

  constructor(
    private readonly clock: WorkFactClock = SYSTEM_CLOCK,
    private readonly boot: string = randomUUID(),
  ) {}

  /** The facts a session's new summary makes; none the first time the session is seen. */
  observe(summary: SessionSummary): WorkFact[] {
    if (!counted(summary)) {
      this.seen.delete(summary.id)
      return []
    }
    const now = this.clock.mono()
    const work = workOf(summary)
    const turn = summary.turnStartedAt ?? null
    const planRef = summary.plan?.ref ?? null
    const steps = summary.plan?.steps ?? []
    const wall = this.clock.wall()
    const prev = this.seen.get(summary.id)
    if (!prev) {
      this.seen.set(summary.id, {
        turn,
        work,
        since: now,
        planRef,
        steps,
        turnWork: noWork(),
        waits: [],
        waitSince: summary.status === 'awaiting_permission' ? wall : null,
      })
      return []
    }
    let turnWork = prev.turnWork
    let waits = prev.waits
    let waitSince = prev.waitSince

    const bodies: WorkFactBody[] = []
    let since = now
    if (prev.work) {
      const elapsed = Math.min(MAX_STRETCH_MS, Math.max(0, now - prev.since))
      const seconds = Math.floor(elapsed / 1000)
      if (seconds > 0) turnWork = { ...turnWork, [prev.work]: turnWork[prev.work] + seconds }
      // The part of a second not counted yet carries over while the turn goes on.
      if (work && elapsed < MAX_STRETCH_MS) since = prev.since + seconds * 1000
    }

    if (summary.status === 'awaiting_permission' && waitSince === null) waitSince = wall
    if (summary.status !== 'awaiting_permission' && waitSince !== null) {
      waits = [...waits, { start: waitSince, end: wall }]
      waitSince = null
    }

    // Steps that turned completed on the session's first plan, or within the same plan entry.
    if (planRef !== null && (prev.planRef === null || planRef === prev.planRef)) {
      steps.forEach((status, stepIndex) => {
        if (status === 'completed' && prev.steps[stepIndex] !== 'completed') {
          bodies.push({ kind: 'todo.step', planRef, stepIndex })
        }
      })
    }

    // A turn ended when the one under way is no longer, or another took its place; a session that
    // only started its agent ran none.
    if (prev.turn !== null && turn !== prev.turn) {
      const unfinished =
        summary.status === 'failed' ||
        (summary.lastTurn ? UNFINISHED.has(summary.lastTurn.reason) : false)
      const end = summary.lastTurn?.endedAt ?? wall
      if (waitSince !== null) waits = [...waits, { start: waitSince, end }]
      bodies.push({
        kind: 'turn.completed',
        start: prev.turn,
        end: Math.max(prev.turn, end),
        ok: !unfinished,
        workSeconds: turnWork,
        waits,
        models: this.usage.get(summary.id) ?? [],
      })
      this.usage.delete(summary.id)
      turnWork = noWork()
      waits = []
      waitSince = summary.status === 'awaiting_permission' ? wall : null
    }

    this.seen.set(summary.id, {
      turn,
      work,
      since,
      planRef,
      steps,
      turnWork,
      waits,
      waitSince,
    })

    const at = wall
    return bodies.map((body) => ({
      ...body,
      id: `${this.boot}:${++this.counter}`,
      sessionId: summary.id,
      agentId: summary.agentId,
      at,
    }))
  }

  /** A turn of the session ended with these tokens; they go with its `turn.completed`. */
  noteUsage(sessionId: string, models: { model: string; tokens: TokenTotals }[]): void {
    this.usage.set(
      sessionId,
      models.map((m) => ({ model: m.model, tokens: tokensOf(m.tokens) })),
    )
  }

  forget(sessionId: string): void {
    this.seen.delete(sessionId)
    this.usage.delete(sessionId)
  }
}
