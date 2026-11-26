import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { DbSummary } from './db'
import type { UsageRow } from './model'
import { BUNDLED_PRICES, canonicalModel, Pricing } from './pricing'
import type { UsageReply, UsageRequest } from './protocol'
import { startUsageService } from './service'

// The app's numbers are what Sarto's Mac app (UsageIslandKit's Pricing.swift, its bundled table)
// gives for each name, run on 2026-11-24.

describe('model names', () => {
  it('normalize across providers and wrappers as the app does', () => {
    const cases: Record<string, string> = {
      'anthropic/claude-sonnet-4-5/high': 'claude-sonnet-4-5',
      'openai/gpt-5/xhigh': 'gpt-5',
      'claude-sonnet-4-5[1m]': 'claude-sonnet-4-5',
      'anthropic/claude-opus-4-6[1m]/max': 'claude-opus-4-6',
      'us.anthropic.claude-sonnet-4-20250514-v1:0': 'claude-sonnet-4',
      'global.anthropic.claude-sonnet-4-5-20250929-v1:0': 'claude-sonnet-4-5',
      'claude-sonnet-4@20250514': 'claude-sonnet-4',
      'claude-opus-4-6-thinking-fast': 'claude-opus-4-6',
    }
    for (const [raw, expected] of Object.entries(cases)) expect(canonicalModel(raw)).toBe(expected)
  })
})

describe('prices on the Mac app’s table', () => {
  // [match, priced as, per million: in, out, cache read, cache write]
  type Case = ['exact' | 'family' | 'unpriced', string | null, number[] | null]
  const APP: Record<string, Case> = {
    'claude-sonnet-4-5': ['exact', 'claude-sonnet-4-5', [3, 15, 0.3, 3.75]],
    'anthropic/claude-sonnet-4-5/high': [
      'exact',
      'anthropic/claude-sonnet-4-5',
      [3, 15, 0.3, 3.75],
    ],
    'claude-sonnet-4-5[1m]': ['exact', 'claude-sonnet-4-5', [3, 15, 0.3, 3.75]],
    'us.anthropic.claude-sonnet-4-20250514-v1:0': [
      'family',
      'claude-sonnet-4-5',
      [3, 15, 0.3, 3.75],
    ],
    'claude-sonnet-4@20250514': ['family', 'claude-sonnet-4-5', [3, 15, 0.3, 3.75]],
    'claude-fable-5-2': ['exact', 'claude-fable-5-2', [8, 40, 0.2, 10]],
    'claude-sonnet-4': ['family', 'claude-sonnet-4-5', [3, 15, 0.3, 3.75]],
    'gemini-4-carbon': ['exact', 'gemini-4-carbon', [2, 10, 0.1, 2]],
    'gemini-4-hydrogen': ['exact', 'gemini-4-hydrogen', [1.5, 7.5, 0.075, 1.5]],
    'gemini-4-neon': ['exact', 'gemini-4-neon', [3, 15, 0.15, 3]],
    'gemini-4-argon': ['exact', 'gemini-4-argon', [2, 10, 0.1, 2]],
    'gemini-4-preview': ['unpriced', null, null],
    'gemini-3.8-flash': ['exact', 'gemini-3.8-flash', [0.75, 3.75, 0.075, 0.75]],
    'gemini-3.9-flash': ['family', 'gemini-3.8-flash', [0.75, 3.75, 0.075, 0.75]],
    'gemini-4-carbon-preview': ['exact', 'gemini-4-carbon', [2, 10, 0.1, 2]],
    'gpt-5.6': ['exact', 'gpt-5.6', [4, 20, 0.4, 5]],
    'gpt-6.1-sol': ['exact', 'gpt-6.1-sol', [2, 10, 0.1, 2.5]],
    'claude-opus-4-6-thinking': ['exact', 'claude-opus-4-6', [5, 25, 0.5, 6.25]],
    o3: ['exact', 'o3', [2, 8, 0.5, 2]],
    'totally-unknown-model': ['unpriced', null, null],
    'gemini-flash-worker-agy': ['exact', 'gemini-flash-worker-agy', [0.75, 3.75, 0.075, 0.75]],
    'kimi-k3': ['exact', 'kimi-k3', [3, 15, 0.3, 3]],
  }

  it('resolve every name as the app does, sibling versions included', () => {
    const pricing = new Pricing({ bundled: false })
    for (const [name, [kind, model, million]] of Object.entries(APP)) {
      const resolved = pricing.resolve(name)
      expect([name, resolved?.match.kind ?? 'unpriced']).toEqual([name, kind])
      expect([name, resolved?.match.model ?? null]).toEqual([name, model])
      if (!million) continue
      const prices = resolved!.prices
      const got = [prices.input, prices.output, prices.cacheRead, prices.cacheWrite]
      got.forEach((value, i) => expect(value * 1e6).toBeCloseTo(million[i]!, 9))
      // The app bills an hour's cache writes at twice the input price.
      expect(prices.cacheWrite1h! * 1e6).toBeCloseTo(million[0]! * 2, 9)
    }
  })
})

/** A valid server snapshot: the bundled one, its date and some prices changed. */
function snapshot(asOf: string, changes: Record<string, number> = {}): unknown {
  const models = { ...BUNDLED_PRICES.models }
  for (const [model, input] of Object.entries(changes)) {
    models[model] = { input, output: input * 5, cacheRead: input / 10, cacheWrite: input }
  }
  return { asOf, models, etag: '"abc"' }
}

describe('the order of the price tables', () => {
  it('takes the bundled snapshot first, then the app’s table, then a sibling', () => {
    const pricing = new Pricing()
    expect(pricing.match('gemini-4-argon')).toEqual({
      kind: 'exact',
      model: 'gemini-4-argon',
      origin: 'bundled',
    })
    // Gemini 4 Carbon is in the app's table only.
    expect(pricing.match('gemini-4-carbon')).toEqual({
      kind: 'exact',
      model: 'gemini-4-carbon',
      origin: 'registry',
    })
    expect(pricing.match('gemini-3.95-flash').kind).toBe('family')
    expect(pricing.match('gemini-9-nothing')).toEqual({
      kind: 'unpriced',
      model: null,
      origin: null,
    })
  })

  it('takes a newer server snapshot over the bundled one, and ignores an older or invalid one', () => {
    const pricing = new Pricing()
    const bundled = pricing.resolve('claude-sonnet-4-5')!.prices.input
    const day = BUNDLED_PRICES.asOf
    expect(pricing.setServer(snapshot('2099-01-01', { 'claude-sonnet-4-5': 9e-6 }))).toBe(true)
    expect(pricing.resolve('claude-sonnet-4-5')).toMatchObject({
      prices: { input: 9e-6 },
      match: { kind: 'exact', origin: 'server' },
    })
    expect(pricing.asOf).toBe('2099-01-01')
    // The same day as the bundled one is taken too.
    expect(pricing.setServer(snapshot(day, { 'claude-sonnet-4-5': 8e-6 }))).toBe(true)
    expect(pricing.resolve('claude-sonnet-4-5')!.prices.input).toBe(8e-6)
    expect(pricing.setServer(snapshot('2020-01-01', { 'claude-sonnet-4-5': 7e-6 }))).toBe(false)
    expect(pricing.resolve('claude-sonnet-4-5')!.prices.input).toBe(bundled)
    expect(pricing.asOf).toBe(day)
    for (const invalid of [
      null,
      'prices',
      { asOf: '2099-01-01', models: {} },
      { asOf: 'tomorrow', models: BUNDLED_PRICES.models },
      snapshot('2099-01-01', { 'claude-sonnet-4-5': -1 }),
    ]) {
      expect(pricing.setServer(invalid)).toBe(false)
      expect(pricing.resolve('claude-sonnet-4-5')!.match.origin).toBe('bundled')
    }
  })

  it('takes the user’s own prices over every table, leaving out entries that do not fit', () => {
    const pricing = new Pricing()
    pricing.setServer(snapshot('2099-01-01', { 'claude-sonnet-4-5': 9e-6 }))
    pricing.setOverride({
      models: {
        'Claude-Sonnet-4-5': { in: 1, out: 2, cr: 0.1, cw: 1.25 },
        'gemini-4-carbon': { in: 'free', out: 2, cr: 0, cw: 0 },
      },
    })
    expect(pricing.resolve('claude-sonnet-4-5')).toMatchObject({
      prices: { input: 1e-6, output: 2e-6, cacheWrite1h: 2e-6 },
      match: { kind: 'exact', origin: 'override' },
    })
    expect(pricing.match('gemini-4-carbon').origin).toBe('registry')
    const version = pricing.version
    pricing.setOverride(null)
    expect(pricing.version).toBeGreaterThan(version)
    expect(pricing.match('claude-sonnet-4-5').origin).toBe('server')
  })
})

describe('the usage worker’s prices files', () => {
  let dir: string
  beforeEach(() => {
    dir = mkdtempSync(path.join(tmpdir(), 'usage-prices-'))
  })
  afterEach(() => rmSync(dir, { recursive: true, force: true }))

  const row = (key: string, model: string): UsageRow => ({
    key,
    source: 'log',
    agentId: 'claude-code',
    sessionId: null,
    project: null,
    model,
    at: Date.UTC(2026, 10, 21, 12),
    input: 1_000_000,
    output: 0,
    reasoning: null,
    cacheRead: 0,
    cacheWrite: 0,
    cacheWrite1h: 0,
    turn: 0,
  })

  function service(files: { override?: string; server?: string }) {
    const waiting = new Map<number, (value: unknown) => void>()
    let id = 1
    const handle = startUsageService(
      path.join(dir, 'usage.db'),
      [],
      (reply: UsageReply) => {
        if (reply.type === 'result') waiting.get(reply.id)?.(reply.value)
      },
      undefined,
      { ...files, pollMs: 20 },
    )
    type Ask = UsageRequest extends infer R ? (R extends unknown ? Omit<R, 'id'> : never) : never
    const ask = <T>(request: Ask): Promise<T> =>
      new Promise((resolve) => {
        const n = id++
        waiting.set(n, resolve as (value: unknown) => void)
        handle({ ...request, id: n } as UsageRequest)
      })
    const cost = async (): Promise<number | null> => {
      const day = Date.UTC(2026, 10, 21)
      const summary = await ask<DbSummary>({
        op: 'summary',
        dayStarts: [day, day + 86_400_000],
        from: day,
        to: day + 86_400_000,
        sources: { 'claude-code': 'log' },
      })
      return summary.models[0]?.cost ?? null
    }
    return { ask, cost }
  }

  const until = async (check: () => Promise<boolean>): Promise<void> => {
    for (let i = 0; i < 200; i++) {
      if (await check()) return
      await new Promise((resolve) => setTimeout(resolve, 10))
    }
    throw new Error('timed out')
  }

  it('prices with the server’s snapshot, again when it changes, and not with an invalid one', async () => {
    const server = path.join(dir, 'prices-server.json')
    writeFileSync(server, JSON.stringify(snapshot('2099-01-01', { 'claude-sonnet-4-5': 9e-6 })))
    const { ask, cost } = service({ server, override: path.join(dir, 'model-prices.json') })
    await ask({ op: 'write', rows: [row('a', 'claude-sonnet-4-5')] })
    await until(async () => (await cost()) === 9)
    writeFileSync(server, '{"asOf": "2099-01-02", "models": {}}')
    // The bundled price, $3 a million input tokens.
    await until(async () => (await cost()) === 3)
    writeFileSync(
      path.join(dir, 'model-prices.json'),
      JSON.stringify({ models: { 'claude-sonnet-4-5': { in: 1.5, out: 2, cr: 0, cw: 0 } } }),
    )
    await until(async () => (await cost()) === 1.5)
    await ask({ op: 'close' })
  })
})
