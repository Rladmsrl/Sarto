// What an agent's work came to, as the host that ran it saw it: the facts the daemon's game link
// turns into the game service's (`src/daemon/game/facts.ts`). Each host tells only of its own
// sessions, so the same work is never told twice, and a fact carries numbers and ids alone: no
// titles, plan text or paths, since the game link sends them off the computer. Only a port that
// selects `work.facts` takes them, and never a paired device's.

import type { AgentId } from './agents'

/** A turn's tokens for one model, as its agent reported them. */
export interface WorkFactTokens {
  input: number
  output: number
  thought: number
  cacheRead: number
  cacheWrite: number
}

/** What a session spent a stretch of its turn on. */
export type WorkKind = 'think' | 'scan' | 'command' | 'edit'

export type WorkFactBody =
  /**
   * A turn ended: its wall times in ms, the seconds it spent on each kind of work, the stretches
   * it waited for the user, and its tokens per model. `ok` unless it failed, a plan limit refused
   * it or the user cancelled it; `models` is empty when the agent reported none, as for a failed
   * turn.
   */
  | {
      kind: 'turn.completed'
      start: number
      end: number
      ok: boolean
      workSeconds: Record<WorkKind, number>
      waits: { start: number; end: number }[]
      models: { model: string; tokens: WorkFactTokens }[]
    }
  /** One step of a plan was done; `planRef` names the plan entry, opaque outside the session. */
  | { kind: 'todo.step'; planRef: string; stepIndex: number }

export type WorkFact = WorkFactBody & {
  /** Unique to this fact; a receiver that sees it twice counts it once. */
  id: string
  sessionId: string
  agentId: AgentId
  /** When the host saw it, in ms since the epoch. */
  at: number
}
