// What an agent's work came to, as the host that ran it saw it: the facts the Agent RPG's rules
// turn into experience, loot and achievements. Each host tells only of its own sessions, so the
// same work is never told twice, and a fact carries numbers and ids alone: no titles, plan text or
// paths, since it is meant to leave the computer for a game service one day.

import type { AgentId } from './agents'

/** What a session spent a stretch of its turn on. */
export type WorkKind = 'think' | 'scan' | 'command' | 'edit'

export type WorkFactBody =
  /** Seconds of a running turn, all spent on `work`; `child` for a session the user started from another. */
  | { kind: 'work.active'; seconds: number; work: WorkKind; child: boolean }
  /** The user answered what the session waited on, and it runs again. */
  | { kind: 'permission.granted' }
  /** Steps of the session's plan were done. */
  | { kind: 'todo.completed'; count: number }
  /** The session's plan was done, or its turn ended well while a plan was still open. */
  | { kind: 'plan.completed'; steps: number }
  /** A turn ended: `ok` unless it failed, a plan limit refused it or the user cancelled it. */
  | { kind: 'turn.ended'; ok: boolean }

export type WorkFact = WorkFactBody & {
  /** Unique to this fact; a receiver that sees it twice counts it once. */
  id: string
  sessionId: string
  agentId: AgentId
  /** When the host saw it, in ms since the epoch. */
  at: number
}
