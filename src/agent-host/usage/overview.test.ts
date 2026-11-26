import { describe, expect, it } from 'vitest'
import type { QuotaReading, TokenParts, WindowForecast } from '@shared/usage'
import type { OverviewAnswer, QuotaGroup } from './db'
import { assembleOverview, hourStarts, localDayStarts, type OverviewInput } from './overview'

const NOW = 1_800_000_000_000
const H = 3_600_000

const parts = (input: number, cost: number | null): TokenParts => ({
  input,
  output: 0,
  reasoning: 0,
  cacheRead: 0,
  cacheWrite: 0,
  requests: 1,
  turns: 0,
  cost,
  unpricedTokens: cost === null ? input : 0,
  cacheSaved: 0,
})

const steady: WindowForecast = {
  status: { kind: 'steady' },
  estimatedRemainingTokens: 1000,
  windowTokens: 10,
}

function reading(account: string, used: number[]): QuotaReading {
  const kinds = ['scoped', 'weekly', 'session'] as const
  return {
    agentId: 'claude-code',
    account,
    plan: 'Max',
    windows: used.map((usedPercent, i) => ({
      id: `w${i}`,
      kind: kinds[i % 3]!,
      scope: kinds[i % 3] === 'scoped' ? 'Fable' : null,
      minutes: null,
      usedPercent,
      // The first window reset an hour ago.
      resetsAt: i === 0 ? NOW - H : NOW + H,
      observedAt: NOW - 2 * H,
    })),
    observedAt: NOW - 2 * H,
  }
}

const group = (account: string, here: boolean, device: QuotaGroup['device']): QuotaGroup => ({
  device,
  reading: reading(account, [90, 60, 20]),
  here,
  forecasts: { w1: steady, w2: steady },
})

function input(scope: OverviewInput['scope'], groups: QuotaGroup[]): OverviewInput {
  const answer: OverviewAnswer = {
    today: [{ agentId: 'claude-code', ...parts(1000, 0.5) }],
    models: [
      {
        days: 90,
        models: [
          {
            agentId: 'codex',
            model: 'gpt-x',
            ...parts(5000, null),
            price: { kind: 'unpriced', model: null, origin: null },
          },
          {
            agentId: 'claude-code',
            model: 'claude-fable-5-9',
            ...parts(100, 2),
            price: { kind: 'family', model: 'claude-fable-5-2', origin: 'registry' },
          },
          {
            agentId: 'claude-code',
            model: 'claude-sonnet-4-5',
            ...parts(900, 2),
            price: { kind: 'exact', model: 'claude-sonnet-4-5', origin: 'bundled' },
          },
        ],
      },
    ],
    daily: [{ day: 89, agentId: 'claude-code', ...parts(1000, 0.5) }],
    hourly: [{ day: 23, agentId: 'claude-code', ...parts(1000, 0.5) }],
    localActivity: [{ agentId: 'claude-code', at: NOW - H, model: 'claude-sonnet-4-5' }],
    remoteActivity: [
      { agentId: 'claude-code', at: NOW - 60_000, model: 'claude-fable-5-9' },
      { agentId: 'antigravity', at: NOW - 60_000, model: 'gemini-3.8-flash' },
    ],
    quotas: [{ agentId: 'claude-code', groups }],
    devices: [
      { id: 'z', name: 'Mac 10', updatedAt: NOW },
      { id: 'y', name: 'Mac 9', updatedAt: NOW },
    ],
    pricesAsOf: '2026-11-23',
  }
  return {
    answer,
    scope,
    now: NOW,
    dayStarts: localDayStarts(NOW, 90),
    hourStarts: hourStarts(NOW, 24),
    self: { deviceId: 'x', deviceName: 'This Mac', updatedAt: NOW - 5000 },
    local: new Set(['claude-code']),
    signedOut: new Set(['antigravity']),
    label: (window) => `${window.kind}:${window.scope ?? ''}`,
  }
}

describe('the usage overview', () => {
  it('shows each window ready to draw, and the tube’s windows', () => {
    const overview = assembleOverview(input('computer', [group('acct-1', true, null)]))
    const quota = overview.agents.find((a) => a.agentId === 'claude-code')!.quota!
    expect(quota.windows.map((w) => [w.id, w.label, w.usedPercent, w.remaining])).toEqual([
      ['w2', 'session:', 20, 0.8],
      ['w1', 'weekly:', 60, 0.4],
      ['w0', 'scoped:Fable', 0, 1],
    ])
    // A window past its reset shows reset, with no reset time, until it is measured again.
    expect(quota.windows[2]).toMatchObject({ reset: true, resetsAt: null })
    expect(quota.windows[2]!.forecast.status).toEqual({ kind: 'reset' })
    expect(quota.windows[1]!.forecast).toEqual(steady)
    expect([quota.primary, quota.secondary]).toEqual(['w1', 'w2'])
    expect(quota.device).toBeNull()
  })

  it('shows other accounts and other computers’ requests only in the all scope', () => {
    const groups = [group('acct-1', false, { id: 'b', name: 'Mac B' }), group('acct-2', true, null)]
    const mine = assembleOverview(input('computer', groups))
    const claude = mine.agents.find((a) => a.agentId === 'claude-code')!
    expect(claude.quota).toBeNull()
    expect(claude.otherAccounts).toEqual([])
    expect(claude.activity).toEqual({ at: NOW - H, model: 'claude-sonnet-4-5' })
    // Antigravity was only used on another computer.
    expect(mine.agents.map((a) => a.agentId)).toEqual(['claude-code', 'codex'])

    const all = assembleOverview(input('all', groups))
    const everyone = all.agents.find((a) => a.agentId === 'claude-code')!
    expect(everyone.quota).toMatchObject({ account: 'acct-1', device: { id: 'b' } })
    expect(everyone.otherAccounts.map((q) => q.account)).toEqual(['acct-2'])
    expect(everyone.activity).toEqual({ at: NOW - 60_000, model: 'claude-fable-5-9' })
    expect(everyone.localActivity).toEqual({ at: NOW - H, model: 'claude-sonnet-4-5' })
    expect(all.agents.find((a) => a.agentId === 'antigravity')).toMatchObject({
      available: true,
      signedOut: true,
      quota: null,
    })
  })

  it('ranks the models, names the unpriced and sibling-priced ones, and lists the computers', () => {
    const overview = assembleOverview(input('all', []))
    expect(overview.models[0]!.models.map((m) => [m.model, m.cost])).toEqual([
      ['claude-sonnet-4-5', 2],
      ['claude-fable-5-9', 2],
      ['gpt-x', 0],
    ])
    expect(overview.unpricedModels).toEqual(['gpt-x'])
    expect(overview.familyPriced).toEqual([
      { model: 'claude-fable-5-9', standIn: 'claude-fable-5-2' },
    ])
    expect(overview.devices.map((d) => [d.name, d.thisComputer])).toEqual([
      ['This Mac', true],
      ['Mac 9', false],
      ['Mac 10', false],
    ])
    expect(overview.daily.starts).toHaveLength(90)
    expect(overview.daily.agents[0]!.tokens.at(-1)).toBe(1000)
    expect(overview.hourly.starts).toEqual(hourStarts(NOW, 24).slice(0, 24))
    expect(overview.hourly.agents[0]!.cost[23]).toBe(0.5)
    expect(overview.agents[0]!.today).toEqual({
      tokens: 1000,
      cost: 0.5,
      requests: 1,
      unpricedTokens: 0,
    })
  })

  it('shows a quota only of an installed agent used within 30 days', () => {
    const agents = [
      { id: 'claude-code', name: 'Claude Code', harnessId: 'claude-code', installed: true },
      { id: 'codex', name: 'Codex', harnessId: 'codex', installed: false },
    ] as const
    const here = { ...input('computer', [group('acct-1', true, null)]), agents }
    const claude = assembleOverview(here).agents.find((a) => a.agentId === 'claude-code')!
    expect(claude).toMatchObject({ eligible: true, name: 'Claude Code', harnessId: 'claude-code' })
    // Codex has usage but is not installed here, and no quota.
    expect(assembleOverview(here).agents.find((a) => a.agentId === 'codex')!.eligible).toBe(false)

    const removed = { ...here, agents: [{ ...agents[0], installed: false }] }
    expect(assembleOverview(removed).agents[0]!.eligible).toBe(false)
    // Another computer's reading shows in the all scope, though the agent is not installed here.
    const elsewhere = {
      ...input('all', [group('acct-1', false, { id: 'b', name: 'Mac B' })]),
      agents: [{ ...agents[0], installed: false }],
    }
    expect(assembleOverview(elsewhere).agents[0]!.eligible).toBe(true)
  })

  it('counts a used window as use, and leaves out an idle agent with an untouched quota', () => {
    const idle = (used: number): OverviewInput => {
      const base = input('computer', [])
      const quota: QuotaGroup = {
        device: null,
        here: true,
        forecasts: {},
        reading: {
          agentId: 'cursor',
          account: 'c',
          plan: 'Ultra',
          windows: [
            {
              id: 'monthly',
              kind: 'weekly',
              scope: null,
              minutes: 43_200,
              usedPercent: used,
              resetsAt: NOW + 24 * H,
              observedAt: NOW,
              amount: { used: used * 4, total: 400, unit: 'USD' },
            },
          ],
          observedAt: NOW,
        },
      }
      return {
        ...base,
        answer: { ...base.answer, quotas: [{ agentId: 'cursor', groups: [quota] }] },
        agents: [{ id: 'cursor', name: 'Cursor', harnessId: 'cursor', installed: true }],
      }
    }
    const cursor = (used: number) =>
      assembleOverview(idle(used)).agents.find((a) => a.agentId === 'cursor')!
    expect(cursor(7).eligible).toBe(true)
    expect(cursor(7).quota!.windows[0]!.amount).toEqual({ used: 28, total: 400, unit: 'USD' })
    expect(cursor(0).eligible).toBe(false)
  })

  it('takes local days in the host’s time zone and whole hours, the current one last', () => {
    const days = localDayStarts(NOW, 90)
    expect(days).toHaveLength(91)
    expect(days.at(-2)! <= NOW && NOW < days.at(-1)!).toBe(true)
    const hours = hourStarts(NOW + 1000, 24)
    expect(hours).toHaveLength(25)
    expect(hours.at(-2)).toBe(NOW)
  })
})
