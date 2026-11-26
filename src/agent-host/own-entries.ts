// Entries the host adds to a session's thread itself (started sessions, git events, turn ends,
// cards and host notices) and how they outlive an agent replay.

import type { Patch, ThreadEntry, ThreadState } from '@shared/thread'
import type { GitEventDraft } from './git/api'

type OwnEntry = Extract<
  ThreadEntry,
  {
    kind:
      | 'artifact'
      | 'session_started'
      | 'git'
      | 'turn_end'
      | 'notice'
      | 'browser_origin'
      | 'control_ask'
      | 'control_note'
      | 'device_access'
      | 'surface_access'
      | 'computer_app'
      | 'computer_setup'
      | 'project_mcp'
      | 'project_hooks'
      | 'problem_report'
      | 'memory'
      | 'market_publish'
      | 'settings_change'
      | 'task_delivery'
      | 'takeover'
  }
>

/** The agent's entry before the thread's end, skipping the ones the host added itself. */
export function agentEntryBefore(thread: ThreadState): string | null {
  const { order, byId } = thread
  for (let i = order.length - 1; i >= 0; i--) {
    const entry = byId[order[i]!]
    if (entry && !isOwn(entry)) return entry.id
  }
  return null
}

/** The entry a session another one's agent started adds to the caller's thread. */
export function startedPatch(thread: ThreadState, sessionId: string, newId: () => string): Patch {
  return {
    op: 'entry.add',
    entry: {
      kind: 'session_started',
      id: newId(),
      sessionId,
      after: agentEntryBefore(thread),
    },
  }
}

/** The entry a git event adds to a session's thread. */
export function gitPatch(thread: ThreadState, draft: GitEventDraft, newId: () => string): Patch {
  return { op: 'entry.add', entry: { ...draft, id: newId(), after: agentEntryBefore(thread) } }
}

/**
 * Whether the host added the entry itself, which an agent's replay never sends again: a notice only
 * when it records `after`, as an agent's never does.
 */
function isOwn(entry: ThreadEntry): entry is OwnEntry {
  switch (entry.kind) {
    case 'artifact':
    case 'browser_origin':
    case 'control_ask':
    case 'control_note':
    case 'device_access':
    case 'surface_access':
    case 'computer_app':
    case 'computer_setup':
    case 'project_mcp':
    case 'project_hooks':
    case 'problem_report':
    case 'memory':
    case 'settings_change':
    case 'session_started':
    case 'git':
    case 'turn_end':
    case 'takeover':
      return true
    case 'notice':
      return entry.after !== undefined
    default:
      return false
  }
}

/**
 * A thread's entries the host added and keeps while a replay rebuilds it (started sessions, git
 * events, turn ends, cards and host notices): each goes back after the entry it followed, or, when
 * the replay never sends that one or it recorded none, at the end of its turn, counted by user
 * messages.
 */
export class ReplayKeeper {
  private kept: { entry: OwnEntry; turn: number }[] = []
  private users = 0

  constructor(thread: ThreadState) {
    let turn = 0
    for (const id of thread.order) {
      const entry = thread.byId[id]
      if (entry?.kind === 'user') turn++
      else if (entry && isOwn(entry)) this.kept.push({ entry, turn })
    }
  }

  get empty(): boolean {
    return this.kept.length === 0
  }

  /** The kept entries that go in before this entry of the replay. */
  before(entry: ThreadEntry): OwnEntry[] {
    if (entry.kind !== 'user') return []
    const ended = this.users++
    return this.take((k) => k.turn <= ended)
  }

  /** The kept entries that go in right after this entry of the replay. */
  after(entry: ThreadEntry): OwnEntry[] {
    if (isOwn(entry)) return []
    return this.take((k) => k.entry.after === entry.id)
  }

  /** What the replay never came back to, for its end. */
  rest(): OwnEntry[] {
    return this.take(() => true)
  }

  private take(test: (kept: { entry: OwnEntry; turn: number }) => boolean): OwnEntry[] {
    const out: OwnEntry[] = []
    this.kept = this.kept.filter((k) => {
      if (!test(k)) return true
      out.push(k.entry)
      return false
    })
    return out
  }
}
