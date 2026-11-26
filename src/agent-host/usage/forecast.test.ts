import { describe, expect, it } from 'vitest'
import type { AgentId } from '@shared/thread'
import type { QuotaSample, QuotaWindow, QuotaWindowKind, WindowForecast } from '@shared/usage'
import { drawsOn, forecastWindow, mergeSamples, spanTotal, type LedgerBucket } from './forecast'

// The expected numbers are what Sarto's Mac app gives for the same input: UsageIslandKit's own
// Forecast.swift, run on each case below (2026-11-24).

const NOW = 1_800_000_000_000
const MIN = 60_000
const at = (minutes: number): number => NOW + minutes * MIN

/** A record of `tokens` every quarter hour from `from` to `to` minutes, as the app's ledger. */
function steady(model: string, from: number, to: number, tokens: number): LedgerBucket[] {
  const out: LedgerBucket[] = []
  for (let m = from; m < to; m += 15) {
    out.push({ start: at(m), duration: 15 * MIN, total: tokens, model })
  }
  return out
}

function window(
  kind: QuotaWindowKind,
  usedPercent: number,
  resetsAt: number | null,
  minutes: number | null,
  scope: string | null = null,
): QuotaWindow {
  return { id: 'w', kind, scope, minutes, usedPercent, resetsAt, observedAt: null }
}

const sample = (minutes: number, usedPercent: number, resetsAt: number): QuotaSample => ({
  at: at(minutes),
  usedPercent,
  resetsAt,
})

function expectForecast(actual: WindowForecast, expected: WindowForecast): void {
  expect(actual.status.kind).toBe(expected.status.kind)
  if (actual.status.kind === 'exhausts' && expected.status.kind === 'exhausts') {
    expect(actual.status.seconds).toBeCloseTo(expected.status.seconds, 6)
  }
  if (actual.status.kind === 'survives' && expected.status.kind === 'survives') {
    expect(actual.status.remainingAtReset).toBeCloseTo(expected.status.remainingAtReset, 12)
  }
  if (expected.estimatedRemainingTokens === null) expect(actual.estimatedRemainingTokens).toBeNull()
  else expect(actual.estimatedRemainingTokens).toBeCloseTo(expected.estimatedRemainingTokens, 4)
  expect(actual.windowTokens).toBeCloseTo(expected.windowTokens, 4)
}

const forecast = (
  agentId: AgentId,
  w: QuotaWindow,
  observedAt: number | null,
  samples: QuotaSample[],
  buckets: LedgerBucket[],
): WindowForecast => forecastWindow({ agentId, window: w, observedAt, samples, buckets, now: NOW })

describe('window tokens', () => {
  it('count only the models that draw on a window, prorating partial buckets', () => {
    // The app's testQuotaWindowTokensCountOnlyMatchingModelsAndProrate.
    const now = Date.parse('2026-11-21T12:00:00Z')
    const quarter = (iso: string, model: string, total: number): LedgerBucket => ({
      start: Date.parse(iso),
      duration: 15 * MIN,
      total,
      model,
    })
    const ledger = [
      quarter('2026-11-21T10:00:00Z', 'claude-sonnet-4-5', 1000),
      quarter('2026-11-21T10:00:00Z', 'claude-opus-4-6', 500),
      quarter('2026-11-21T08:00:00Z', 'claude-sonnet-4-5', 4000),
    ]
    const scoped = window('scoped', 10, null, null, 'Claude Sonnet 4')
    const session = window('session', 10, null, 300)
    const only = (w: QuotaWindow) =>
      ledger.filter((bucket) => drawsOn('claude-code', w, bucket.model))
    const start = Date.parse('2026-11-21T10:00:00Z')
    expect(spanTotal(only(scoped), start, now, now)).toBe(1000)
    expect(spanTotal(only(session), start, now, now)).toBe(1500)
    expect(spanTotal(only(session), Date.parse('2026-11-21T10:07:30Z'), now, now)).toBe(750)
  })

  it('match Claude Code’s scoped windows and Antigravity’s groups as the app does', () => {
    const sonnet = window('scoped', 25, null, null, 'Claude Sonnet 4')
    expect(drawsOn('claude-code', sonnet, 'us.anthropic.claude-sonnet-4-20250514-v1:0')).toBe(true)
    expect(drawsOn('claude-code', sonnet, 'anthropic/claude-sonnet-4-5[1m]/high')).toBe(true)
    expect(drawsOn('claude-code', sonnet, 'anthropic/claude-opus-4-6/high')).toBe(false)
    const opus = window('scoped', 25, null, null, 'Opus')
    expect(drawsOn('claude-code', opus, 'opusplan')).toBe(true)
    expect(drawsOn('claude-code', opus, 'claude-sonnet-4-5')).toBe(false)
    expect(drawsOn('claude-code', window('weekly', 1, null, null), 'claude-sonnet-4-5')).toBe(true)
    const gemini = window('session', 1, null, 300)
    const thirdParty = window('scoped', 1, null, 300, 'Claude and GPT models')
    expect(drawsOn('antigravity', gemini, 'gemini-3.8-flash')).toBe(true)
    expect(drawsOn('antigravity', gemini, 'claude-sonnet-4-6')).toBe(false)
    expect(drawsOn('antigravity', thirdParty, 'gpt-oss-120b-medium')).toBe(true)
    expect(drawsOn('antigravity', thirdParty, 'gemini-3.8-flash')).toBe(false)
    expect(drawsOn('codex', thirdParty, 'anything')).toBe(true)
  })
})

describe('quota forecasts, against the Mac app’s numbers', () => {
  it('blends the measured, recent and token rates of a 5-hour window', () => {
    const resets = at(120)
    expectForecast(
      forecast(
        'claude-code',
        window('session', 40, resets, 300),
        at(-10),
        [sample(-120, 20, resets), sample(-60, 30, resets), sample(-10, 40, resets)],
        steady('claude-sonnet-4-5', -180, 0, 200_000),
      ),
      {
        status: { kind: 'survives', remainingAtReset: 0.32620320855614965 },
        estimatedRemainingTokens: 3266666.6666666665,
        windowTokens: 2400000.0000000005,
      },
    )
  })

  it('takes flat measurements as no recent burn on a weekly window', () => {
    const resets = at(5 * 1440)
    expectForecast(
      forecast(
        'codex',
        window('weekly', 10, resets, 10080),
        at(-30),
        [sample(-150, 10, resets), sample(-30, 10, resets)],
        steady('gpt-6.1-sol', -48 * 60, 0, 30_000),
      ),
      {
        status: { kind: 'survives', remainingAtReset: 0.7473684210526315 },
        estimatedRemainingTokens: 51240000,
        windowTokens: 5760000,
      },
    )
  })

  it('is steady when barely used, insufficient with no reset time, reset once past it', () => {
    expectForecast(
      forecast(
        'claude-code',
        window('session', 1, at(200), 300),
        at(-5),
        [],
        steady('claude-sonnet-4-5', -30, 0, 1_000),
      ),
      {
        status: { kind: 'steady' },
        estimatedRemainingTokens: null,
        windowTokens: 1999.9999999999998,
      },
    )
    expectForecast(forecast('claude-code', window('session', 50, null, 300), NOW, [], []), {
      status: { kind: 'insufficient' },
      estimatedRemainingTokens: null,
      windowTokens: 0,
    })
    expectForecast(forecast('claude-code', window('session', 50, at(-1), 300), NOW, [], []), {
      status: { kind: 'reset' },
      estimatedRemainingTokens: null,
      windowTokens: 0,
    })
  })

  it('counts only the scoped models’ tokens, and runs a heavily used window out', () => {
    const resets = at(3 * 1440)
    expectForecast(
      forecast(
        'claude-code',
        window('scoped', 70, resets, null, 'Fable'),
        at(-60),
        [sample(-20 * 60, 40, resets), sample(-12 * 60, 55, resets), sample(-60, 70, resets)],
        [
          ...steady('claude-fable-5', -24 * 60, 0, 400_000),
          ...steady('claude-sonnet-4-5', -24 * 60, 0, 900_000),
        ],
      ),
      {
        status: { kind: 'exhausts', seconds: 58801.99667221298 },
        estimatedRemainingTokens: 14171428.571428575,
        windowTokens: 38400000,
      },
    )
  })

  it('forecasts Antigravity’s Gemini window and its Claude and GPT group apart', () => {
    const ledger = [
      ...steady('gemini-3.8-flash', -240, 0, 120_000),
      ...steady('claude-sonnet-4-6', -120, 0, 80_000),
    ]
    expectForecast(
      forecast('antigravity', window('session', 25, at(60), 300), at(-3), [], ledger),
      {
        status: { kind: 'survives', remainingAtReset: 0.6835443037974683 },
        estimatedRemainingTokens: 5664000,
        windowTokens: 1920000,
      },
    )
    expectForecast(
      forecast(
        'antigravity',
        window('scoped', 50, at(180), 300, 'Claude and GPT models'),
        at(-3),
        [],
        ledger,
      ),
      {
        status: { kind: 'exhausts', seconds: 6840 },
        estimatedRemainingTokens: 608000,
        windowTokens: 640000,
      },
    )
  })

  it('counts tokens spent since the measurement against what is left', () => {
    expectForecast(
      forecast(
        'claude-code',
        window('session', 99.95, at(60), 300),
        at(-1),
        [],
        steady('claude-sonnet-4-5', -60, 0, 100_000),
      ),
      {
        status: { kind: 'exhausts', seconds: 0 },
        estimatedRemainingTokens: 0,
        windowTokens: 400000,
      },
    )
    const resets = at(50)
    expectForecast(
      forecast(
        'claude-code',
        window('session', 30, resets, 300),
        at(-90),
        [sample(-200, 10, resets), sample(-90, 30, resets)],
        steady('claude-opus-4-6', -240, 0, 500_000),
      ),
      {
        status: { kind: 'survives', remainingAtReset: 0.42579545454545453 },
        estimatedRemainingTokens: 8666666.666666666,
        windowTokens: 8000000,
      },
    )
  })

  it('merges two computers’ measurements of one cycle, without repeats or older ones', () => {
    const resets = at(120)
    const merged = mergeSamples(
      [
        [sample(-100, 10, resets), sample(-50, 20, resets)],
        [
          { at: at(-100) + 30_000, usedPercent: 10.01, resetsAt: resets },
          sample(-70, 15, resets + 300_000),
          sample(-60, 2, at(400)),
          sample(-49 * 60, 1, resets),
        ],
      ],
      resets,
      NOW,
    )
    expect(merged.map((s) => [(s.at - NOW) / MIN, s.usedPercent])).toEqual([
      [-100, 10],
      [-70, 15],
      [-50, 20],
    ])
  })
})
