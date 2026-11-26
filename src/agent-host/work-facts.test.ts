import { describe, expect, it } from 'vitest'
import type { SessionSummary } from '@shared/agent-host'
import type { WorkFact } from '@shared/work-facts'
import { WorkFactTracker } from './work-facts'

function clock() {
  let wall = 1_800_000_000_000
  let mono = 0
  return {
    wall: () => wall,
    mono: () => mono,
    advance(ms: number) {
      wall += ms
      mono += ms
    },
  }
}

function summary(over: Partial<SessionSummary>): SessionSummary {
  return {
    id: 's1',
    agentId: 'codex',
    origin: 'user',
    parentId: null,
    archivedAt: null,
    status: 'ready',
    turnStartedAt: null,
    lastTurn: null,
    plan: null,
    phase: null,
    activity: null,
    ...over,
  } as unknown as SessionSummary
}

const kinds = (facts: WorkFact[]) => facts.map((f) => f.kind)

describe('WorkFactTracker for the game', () => {
  it('reports a finished turn with its work, waits and tokens per model', () => {
    const c = clock()
    const tracker = new WorkFactTracker(c, 'boot')
    const start = c.wall()
    tracker.observe(summary({}))
    expect(
      tracker.observe(summary({ status: 'running', turnStartedAt: start, phase: 'edit' })),
    ).toEqual([])
    c.advance(10_000)
    expect(
      tracker.observe(summary({ status: 'awaiting_permission', turnStartedAt: start })),
    ).toEqual([])
    c.advance(5_000)
    expect(
      tracker.observe(summary({ status: 'running', turnStartedAt: start, phase: 'thinking' })),
    ).toEqual([])
    c.advance(3_000)
    tracker.noteUsage('s1', [
      {
        model: 'gpt-5',
        tokens: { total: 15, input: 10, output: 5, thought: null, cacheRead: 7, cacheWrite: null },
      },
    ])
    const end = c.wall()
    const facts = tracker.observe(
      summary({
        status: 'ready',
        turnStartedAt: null,
        lastTurn: { reason: 'end_turn', endedAt: end } as never,
      }),
    )
    expect(kinds(facts)).toEqual(['turn.completed'])
    const turn = facts.find((f) => f.kind === 'turn.completed')
    expect(turn).toMatchObject({
      kind: 'turn.completed',
      start,
      end,
      ok: true,
      workSeconds: { edit: 10, think: 3, scan: 0, command: 0 },
      waits: [{ start: start + 10_000, end: start + 15_000 }],
      models: [
        {
          model: 'gpt-5',
          tokens: { input: 10, output: 5, thought: 0, cacheRead: 7, cacheWrite: 0 },
        },
      ],
    })
  })

  it('reports a turn without tokens with no models, and keeps no text', () => {
    const c = clock()
    const tracker = new WorkFactTracker(c, 'boot')
    tracker.observe(summary({}))
    tracker.observe(summary({ status: 'running', turnStartedAt: c.wall(), phase: 'execute' }))
    c.advance(2_000)
    const facts = tracker.observe(summary({ status: 'failed', turnStartedAt: null }))
    const turn = facts.find((f) => f.kind === 'turn.completed')
    expect(turn).toMatchObject({ ok: false, models: [] })
    expect(JSON.stringify(facts)).not.toContain('text')
  })

  it('reports each plan step that turns completed, once, within the same plan entry', () => {
    const c = clock()
    const tracker = new WorkFactTracker(c, 'boot')
    const plan = (steps: string[]) => ({
      done: steps.filter((s) => s === 'completed').length,
      total: steps.length,
      current: null,
      ref: 'plan-1',
      steps,
    })
    tracker.observe(summary({ plan: plan(['pending', 'pending', 'pending']) as never }))
    const first = tracker.observe(
      summary({ plan: plan(['completed', 'in_progress', 'pending']) as never }),
    )
    expect(first.filter((f) => f.kind === 'todo.step')).toMatchObject([
      { planRef: 'plan-1', stepIndex: 0 },
    ])
    const again = tracker.observe(
      summary({ plan: plan(['completed', 'completed', 'completed']) as never }),
    )
    expect(
      again
        .filter((f) => f.kind === 'todo.step')
        .map((f) => (f as { stepIndex: number }).stepIndex),
    ).toEqual([1, 2])
    const replanned = tracker.observe(
      summary({ plan: { ...plan(['completed', 'pending']), ref: 'plan-2' } as never }),
    )
    expect(kinds(replanned)).not.toContain('todo.step')
  })

  it('reports steps that are already completed when a session sets its first plan', () => {
    const c = clock()
    const tracker = new WorkFactTracker(c, 'boot')
    tracker.observe(summary({}))
    const first = tracker.observe(
      summary({
        plan: {
          done: 1,
          total: 2,
          current: { index: 1, text: 'next' },
          ref: 'plan-first',
          steps: ['completed', 'in_progress'],
        } as never,
      }),
    )
    expect(first.filter((f) => f.kind === 'todo.step')).toMatchObject([
      { planRef: 'plan-first', stepIndex: 0 },
    ])
  })
})
