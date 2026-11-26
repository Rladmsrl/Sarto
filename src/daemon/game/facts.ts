// What leaves the computer for the game service: the agent host's work facts, cut down to the game's
// facts. Session and plan ids become opaque references keyed by a secret that never leaves this
// computer, model names the price snapshot does not list become `custom`, and nothing else of the
// session goes with them.

import { createHmac } from 'node:crypto'
import type { GameFact, TodoFact, TurnFact, WorkInterval } from '@sarto/wire/game'
import { priceKey } from '@sarto/wire/prices'
import { harnessOf, isHarnessId } from '@shared/agents'
import type { WorkFact } from '@shared/work-facts'

export interface FactContext {
  /** The secret the opaque references are made with; per data folder, never sent. */
  secret: string
  /** Model names the public price snapshot lists. */
  knownModels: ReadonlySet<string>
  nextSeq(): number
  /** The local hour of a time, for the late-night easter egg; no time zone is sent. */
  localHour(at: number): number
}

function ref(secret: string, kind: string, value: string): string {
  return createHmac('sha256', secret).update(`${kind}\0${value}`).digest('base64url').slice(0, 22)
}

/** The turn's time from start to end, with the waits cut out and marked as waiting. */
export function intervalsOf(
  start: number,
  end: number,
  waits: { start: number; end: number }[],
): WorkInterval[] {
  const out: WorkInterval[] = []
  let cursor = start
  const sorted = waits
    .map((w) => ({ start: Math.max(start, w.start), end: Math.min(end, w.end) }))
    .filter((w) => w.end > w.start)
    .sort((a, b) => a.start - b.start)
  for (const wait of sorted) {
    if (wait.start > cursor) out.push({ start: cursor, end: wait.start, state: 'work' })
    const from = Math.max(cursor, wait.start)
    if (wait.end > from) out.push({ start: from, end: wait.end, state: 'waiting' })
    cursor = Math.max(cursor, wait.end)
  }
  if (end > cursor) out.push({ start: cursor, end, state: 'work' })
  return out
}

export function toGameFacts(facts: WorkFact[], context: FactContext): GameFact[] {
  const out: GameFact[] = []
  for (const fact of facts) {
    if (fact.kind !== 'turn.completed' && fact.kind !== 'todo.step') continue
    const harness = harnessOf(fact.agentId)
    if (!isHarnessId(harness)) continue
    const base = {
      id: ref(context.secret, 'fact', fact.id),
      at: fact.at,
      seq: context.nextSeq(),
      sessionRef: ref(context.secret, 'session', fact.sessionId),
      harness,
      nightLocal: (() => {
        const hour = context.localHour(fact.at)
        return hour >= 1 && hour < 5
      })(),
    }
    if (fact.kind === 'todo.step') {
      const todo: TodoFact = {
        ...base,
        type: 'todo',
        planRef: ref(context.secret, 'plan', `${fact.sessionId}\0${fact.planRef}`),
        planVersion: 1,
        stepIndex: fact.stepIndex,
      }
      out.push(todo)
      continue
    }
    const intervals = intervalsOf(fact.start, fact.end, fact.waits)
    if (intervals.length === 0) continue
    const turn: TurnFact = {
      ...base,
      at: fact.end,
      type: 'turn',
      ok: fact.ok,
      intervals,
      workSeconds: fact.workSeconds,
      models: fact.models.map((m) => {
        const key = priceKey(m.model)
        return { model: key && context.knownModels.has(key) ? key : 'custom', tokens: m.tokens }
      }),
    }
    out.push(turn)
  }
  return out
}
