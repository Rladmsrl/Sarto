import { describe, expect, it } from 'vitest'
import { parseFact } from '@sarto/wire/game'
import type { WorkFact } from '@shared/work-facts'
import { intervalsOf, toGameFacts } from './facts'

const context = () => {
  let seq = 0
  return {
    secret: 'a'.repeat(64),
    knownModels: new Set(['gpt-5.5', 'claude-opus-5-5']),
    nextSeq: () => ++seq,
    localHour: () => 14,
  }
}

const turn: WorkFact = {
  kind: 'turn.completed',
  id: 'boot:1',
  sessionId: 'session-with-a-real-id',
  agentId: 'codex',
  at: 1_800_000_060_000,
  start: 1_800_000_000_000,
  end: 1_800_000_060_000,
  ok: true,
  workSeconds: { think: 10, scan: 20, command: 10, edit: 10 },
  waits: [{ start: 1_800_000_020_000, end: 1_800_000_030_000 }],
  models: [
    { model: 'gpt-5.5', tokens: { input: 1, output: 2, thought: 0, cacheRead: 3, cacheWrite: 0 } },
    {
      model: 'acme-internal-model',
      tokens: { input: 1, output: 1, thought: 0, cacheRead: 0, cacheWrite: 0 },
    },
  ],
}

describe('game facts', () => {
  it('cuts the waits out of a turn and marks them as waiting', () => {
    expect(intervalsOf(0, 100, [{ start: 20, end: 30 }])).toEqual([
      { start: 0, end: 20, state: 'work' },
      { start: 20, end: 30, state: 'waiting' },
      { start: 30, end: 100, state: 'work' },
    ])
  })

  it('keeps ids opaque, hides unlisted model names, and passes the wire check', () => {
    const [fact] = toGameFacts([turn], context())
    expect(fact).toBeDefined()
    const json = JSON.stringify(fact)
    expect(json).not.toContain('session-with-a-real-id')
    expect(json).not.toContain('boot:1')
    expect(json).not.toContain('acme-internal-model')
    expect(json).toContain('"custom"')
    expect(typeof parseFact(fact)).not.toBe('string')
  })

  it('gives the same session the same reference and plans their own', () => {
    const step = (planRef: string, stepIndex: number): WorkFact => ({
      kind: 'todo.step',
      id: `boot:${planRef}:${stepIndex}`,
      sessionId: 'session-with-a-real-id',
      agentId: 'codex',
      at: 1,
      planRef,
      stepIndex,
    })
    const facts = toGameFacts(
      [turn, step('plan-a', 0), step('plan-a', 1), step('plan-b', 0)],
      context(),
    )
    const refs = new Set(facts.map((f) => f.sessionRef))
    expect(refs.size).toBe(1)
    const plans = facts
      .filter((f) => f.type === 'todo')
      .map((f) => (f as { planRef: string }).planRef)
    expect(plans[0]).toBe(plans[1])
    expect(plans[0]).not.toBe(plans[2])
    expect(plans.join()).not.toContain('plan-a')
  })

  it('sends nothing for the facts the game does not take', () => {
    // A kind a newer agent host may send, which this daemon does not know.
    const unknown = {
      kind: 'todo.completed',
      count: 2,
      id: 'x',
      sessionId: 's',
      agentId: 'codex',
      at: 1,
    }
    const facts = toGameFacts([unknown as unknown as WorkFact], context())
    expect(facts).toEqual([])
  })

  it('maps added agent ids back to their harness without leaking the profile slug', () => {
    const facts = toGameFacts([{ ...turn, agentId: 'claude-code~work-profile' }], context())
    expect(facts[0]?.harness).toBe('claude-code')
    expect(JSON.stringify(facts)).not.toContain('work-profile')
  })
})
