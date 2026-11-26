// The Agent RPG's facts, read from the summaries a host sends as its sessions change: the host
// that runs a session is the only one that tells of its work, so no client counts it twice, and
// the facts no longer depend on what a window shows or how often it redraws.

import { randomUUID } from 'node:crypto'
import type { SessionSummary } from '@shared/agent-host'
import type { SessionStatus } from '@shared/thread'
import type { WorkFact, WorkFactBody, WorkKind } from '@shared/work-facts'

// A turn whose summary says nothing new for this long more likely hangs than works; a stretch
// counts at most this much. The clock below stops while the computer sleeps.
const MAX_STRETCH_MS = 30 * 60_000

interface Seen {
  status: SessionStatus
  /** When the turn under way started, as the summary says; null between turns. */
  turn: number | null
  planDone: number
  planTotal: number
  openPlan: boolean
  /** What the running turn spends its time on since `since`; null while no turn runs. */
  work: WorkKind | null
  since: number
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

// Turns that did not finish their work: no reward, and the streak ends.
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
    const planDone = summary.plan?.done ?? 0
    const planTotal = summary.plan?.total ?? 0
    const openPlan = planTotal > 0 && planDone < planTotal
    const work = workOf(summary)
    const turn = summary.turnStartedAt ?? null
    const prev = this.seen.get(summary.id)
    if (!prev) {
      this.seen.set(summary.id, {
        status: summary.status,
        turn,
        planDone,
        planTotal,
        openPlan,
        work,
        since: now,
      })
      return []
    }

    const bodies: WorkFactBody[] = []
    let since = now
    if (prev.work) {
      const elapsed = Math.min(MAX_STRETCH_MS, Math.max(0, now - prev.since))
      const seconds = Math.floor(elapsed / 1000)
      if (seconds > 0) {
        bodies.push({
          kind: 'work.active',
          seconds,
          work: prev.work,
          child: summary.parentId !== null,
        })
      }
      // The part of a second not counted yet carries over while the turn goes on.
      if (work && elapsed < MAX_STRETCH_MS) since = prev.since + seconds * 1000
    }

    if (prev.status === 'awaiting_permission' && summary.status === 'running') {
      bodies.push({ kind: 'permission.granted' })
    }

    let cleared = 0
    if (planDone > prev.planDone) {
      if (planTotal === prev.planTotal) cleared = planDone - prev.planDone
      else if (prev.openPlan && planTotal > 0 && planDone >= planTotal) {
        cleared = planDone - prev.planDone
      }
    }
    if (cleared > 0) bodies.push({ kind: 'todo.completed', count: cleared })

    const unfinished =
      summary.status === 'failed' ||
      (summary.lastTurn ? UNFINISHED.has(summary.lastTurn.reason) : false)
    const planEnded =
      prev.openPlan &&
      ((planTotal > 0 && planDone >= planTotal) ||
        (summary.status === 'ready' && !unfinished && planTotal === 0))
    if (planEnded) bodies.push({ kind: 'plan.completed', steps: Math.max(1, prev.planTotal) })

    // A turn ended when the one under way is no longer, or another took its place; a session that
    // only started its agent ran none.
    if (prev.turn !== null && turn !== prev.turn) {
      bodies.push({ kind: 'turn.ended', ok: !unfinished })
    }

    this.seen.set(summary.id, {
      status: summary.status,
      turn,
      planDone,
      planTotal,
      openPlan,
      work,
      since,
    })

    const at = this.clock.wall()
    return bodies.map((body) => ({
      ...body,
      id: `${this.boot}:${++this.counter}`,
      sessionId: summary.id,
      agentId: summary.agentId,
      at,
    }))
  }

  forget(sessionId: string): void {
    this.seen.delete(sessionId)
  }
}
