import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { PlanLimit } from '@shared/agent-host'
import type { QuotaReading, QuotaSample, QuotaWindow } from '@shared/usage'
import { latestActivity } from './activity'
import { UsageDb } from './db'
import type { UsageRow } from './model'
import { accountFingerprint, limitsReading, mergeOrigins, recordSample } from './quota'

const H = 3_600_000
const NOW = Date.UTC(2026, 10, 21, 12)

describe('account fingerprints', () => {
  it('are the first 8 bytes of SHA-256("<provider>:<id>"), as the Mac app makes them', () => {
    expect(accountFingerprint('codex', 'ws-123')).toBe('b85c269bf0711afc')
    expect(accountFingerprint('antigravity', 'brave-fox-1234567')).toBe('b74d6c21e7e33bf0')
  })
})

describe('quota history', () => {
  const sample = (minutes: number, used: number, resetsAt: number | null = NOW + 4 * H) => ({
    at: NOW + minutes * 60_000,
    usedPercent: used,
    resetsAt,
  })

  it('adds a measurement that moved, and skips one that barely did within ten minutes', () => {
    let list: QuotaSample[] = recordSample([], sample(0, 10), NOW)
    list = recordSample(list, sample(5, 10.01), NOW)
    expect(list).toHaveLength(1)
    list = recordSample(list, sample(11, 10.01), NOW)
    list = recordSample(list, sample(12, 11), NOW)
    expect(list.map((s) => s.usedPercent)).toEqual([10, 10.01, 11])
  })

  it('ignores an older measurement and starts over on a new reset cycle or a hard drop', () => {
    const list = [sample(0, 10), sample(30, 20)]
    expect(recordSample(list, sample(10, 15), NOW)).toEqual(list)
    expect(recordSample(list, sample(40, 1, NOW + 9 * H), NOW)).toEqual([
      sample(40, 1, NOW + 9 * H),
    ])
    expect(recordSample(list, sample(40, 4), NOW)).toEqual([sample(40, 4)])
    // Reset times ten minutes apart are one cycle.
    expect(recordSample(list, sample(40, 21, NOW + 4 * H + 600_000), NOW)).toHaveLength(3)
    expect(recordSample([sample(0, 10, null)], sample(40, 12), NOW)).toEqual([sample(40, 12)])
  })

  it('keeps 48 hours and 48 measurements', () => {
    const old = { at: NOW - 49 * H, usedPercent: 1, resetsAt: NOW + 4 * H }
    expect(recordSample([old], sample(0, 2), NOW)).toEqual([sample(0, 2)])
    let list: QuotaSample[] = []
    for (let i = 0; i < 60; i++)
      list = recordSample(list, sample(i * 11, i), NOW + 60 * 11 * 60_000)
    expect(list).toHaveLength(48)
    expect(list[0]?.usedPercent).toBe(12)
  })
})

describe('live plan limits as readings', () => {
  const limit = (window: string, label: string, usedPercent: number | null): PlanLimit => ({
    window,
    label,
    usedPercent,
    resetsAt: NOW + H,
    state: 'ok',
    observedAt: NOW,
  })

  it('scopes a labeled window, except Antigravity’s Gemini group', () => {
    const claude = limitsReading('claude-code', {
      tier: '5x',
      limits: [
        limit('five_hour', '5-hour', 40),
        limit('seven_day_opus', 'Weekly · Opus', 70),
        limit('overage', 'Extra usage', 5),
        limit('seven_day', 'Weekly', null),
      ],
    })
    expect(claude?.plan).toBe('5x')
    expect(claude?.windows.map((w) => [w.id, w.kind, w.scope, w.minutes])).toEqual([
      ['five_hour', 'session', null, 300],
      ['seven_day_opus', 'scoped', 'Opus', 10080],
    ])
    const agy = limitsReading('antigravity', {
      limits: [
        limit('five_hour_gemini_models', '5-hour · Gemini Models', 2),
        limit('seven_day_claude_and_gpt_models', 'Weekly · Claude and GPT models', 0),
      ],
    })
    expect(agy?.windows.map((w) => [w.id, w.kind, w.scope])).toEqual([
      ['five_hour_gemini_models', 'session', null],
      ['seven_day_claude_and_gpt_models', 'scoped', 'Claude and GPT models'],
    ])
    expect(limitsReading('codex', { limits: [] })).toBeNull()
  })

  it('reads the pools of a plan period as scoped windows of its length, with the account', () => {
    const cursor = limitsReading('cursor', {
      tier: 'Ultra',
      account: 'acct',
      limits: [
        { ...limit('monthly', 'Monthly', 7), amount: { used: 28, total: 400, unit: 'USD' } },
        limit('auto', 'Auto', 1),
        limit('other_models', 'Other models', 0.2),
      ],
    })
    expect(cursor?.account).toBe('acct')
    expect(cursor?.windows.map((w) => [w.id, w.kind, w.scope, w.minutes])).toEqual([
      ['monthly', 'weekly', null, 43_200],
      ['auto', 'scoped', 'Auto', 43_200],
      ['other_models', 'scoped', 'Other models', 43_200],
    ])
    expect(cursor?.windows[0]?.amount).toEqual({ used: 28, total: 400, unit: 'USD' })
    // A window of no length, with none beside it, stays the plan's.
    const lone = limitsReading('mistral-vibe', { limits: [limit('credits', 'Credits', 10)] })
    expect(lone?.windows.map((w) => [w.kind, w.scope])).toEqual([['other', null]])
  })

  it('merge with the files’ reading: the fresher window wins, the account is the files’', () => {
    const window = (id: string, used: number, observedAt: number): QuotaWindow => ({
      id,
      kind: 'session',
      scope: null,
      minutes: 300,
      usedPercent: used,
      resetsAt: null,
      observedAt,
    })
    const files: QuotaReading = {
      agentId: 'codex',
      account: 'b85c269bf0711afc',
      plan: null,
      windows: [window('five_hour', 10, NOW), window('seven_day', 30, NOW)],
      observedAt: NOW,
    }
    const agent: QuotaReading = {
      agentId: 'codex',
      account: null,
      plan: 'Pro',
      windows: [window('five_hour', 12, NOW + 60_000)],
      observedAt: NOW + 60_000,
    }
    expect(mergeOrigins(files, agent)).toEqual({
      agentId: 'codex',
      account: 'b85c269bf0711afc',
      plan: 'Pro',
      windows: [window('five_hour', 12, NOW + 60_000), window('seven_day', 30, NOW)],
      observedAt: NOW + 60_000,
    })
  })
})

describe('latest activity', () => {
  const row = (seconds: number, model: string, output = 1000, total = 50_000) => ({
    at: NOW + seconds * 1000,
    model,
    output,
    total,
  })

  it('leaves the main model through Claude Code’s small Haiku helpers within ten minutes', () => {
    const rows = [
      row(200, 'claude-haiku-4-5', 50, 900),
      row(100, 'claude-haiku-4-5', 50, 900),
      row(0, 'claude-opus-5-5'),
    ]
    expect(latestActivity('claude-code', rows)).toEqual({
      agentId: 'claude-code',
      at: NOW + 200_000,
      model: 'claude-opus-5-5',
    })
    // Past ten minutes, or a Haiku call of real size, Haiku is the model.
    expect(
      latestActivity('claude-code', [
        row(700, 'claude-haiku-4-5', 50, 900),
        row(0, 'claude-opus-5-5'),
      ])?.model,
    ).toBe('claude-haiku-4-5')
    expect(
      latestActivity('claude-code', [row(100, 'claude-haiku-4-5'), row(0, 'claude-opus-5-5')])
        ?.model,
    ).toBe('claude-haiku-4-5')
    expect(
      latestActivity('opencode', [row(100, 'claude-haiku-4-5', 50, 900), row(0, 'gpt-6')])?.model,
    ).toBe('claude-haiku-4-5')
    expect(latestActivity('codex', [row(5, ''), row(0, 'gpt-6.1-sol')])).toEqual({
      agentId: 'codex',
      at: NOW + 5000,
      model: 'gpt-6.1-sol',
    })
    expect(latestActivity('codex', [])).toBeNull()
  })
})

describe('the usage database’s quotas', () => {
  let dir: string
  let now = NOW
  beforeEach(() => {
    dir = mkdtempSync(path.join(tmpdir(), 'usage-quota-db-'))
    now = NOW
  })
  afterEach(() => rmSync(dir, { recursive: true, force: true }))
  const open = (): UsageDb =>
    UsageDb.open(
      path.join(dir, 'usage.db'),
      () => {},
      () => now,
    )

  const reading = (
    used: number,
    observedAt: number | null,
    resetsAt = NOW + 4 * H,
  ): QuotaReading => ({
    agentId: 'claude-code',
    account: 'efe658764602f1ff',
    plan: 'Max 20×',
    windows: [
      {
        id: 'five_hour',
        kind: 'session',
        scope: null,
        minutes: 300,
        usedPercent: used,
        resetsAt,
        observedAt,
      },
    ],
    observedAt,
  })

  it('stores a reading and its measurements, and only a change counts', () => {
    const db = open()
    expect(db.putQuota(reading(10, NOW), 'files', null)).toBe(true)
    expect(db.putQuota(reading(10, NOW), 'files', null)).toBe(false)
    now = NOW + 20 * 60_000
    expect(db.putQuota(reading(14, now), 'files', '{"v":1}')).toBe(true)
    expect(db.storedQuota('claude-code')).toEqual({ reading: reading(14, now), state: '{"v":1}' })
    const { readings, history } = db.quotas()
    expect(readings).toEqual([reading(14, now)])
    expect(history).toEqual([
      {
        agentId: 'claude-code',
        window: 'five_hour',
        samples: [
          { at: NOW, usedPercent: 10, resetsAt: NOW + 4 * H },
          { at: now, usedPercent: 14, resetsAt: NOW + 4 * H },
        ],
      },
    ])
    db.close()
  })

  it('measures no window that has reset or says no time, and shows no empty reading', () => {
    const db = open()
    now = NOW + 5 * H
    db.putQuota(reading(90, NOW), 'files')
    db.putQuota(reading(90, null, NOW + 9 * H), 'agent')
    db.putQuota(
      { agentId: 'antigravity', account: null, plan: null, windows: [], observedAt: null },
      'files',
    )
    const { readings, history } = db.quotas()
    expect(history).toEqual([])
    expect(readings.map((r) => r.agentId)).toEqual(['claude-code'])
    db.close()
  })

  it('answers each counted agent’s latest request from its source', () => {
    const db = open()
    const row = (key: string, source: 'log' | 'sarto', at: number, model: string): UsageRow => ({
      key,
      source,
      agentId: 'claude-code',
      sessionId: null,
      project: null,
      model,
      at,
      input: 10,
      output: 1000,
      reasoning: null,
      cacheRead: 40_000,
      cacheWrite: 0,
      cacheWrite1h: 0,
      turn: 0,
    })
    db.write([
      row('a', 'log', NOW, 'claude-opus-5-5'),
      row('b', 'sarto', NOW + H, 'claude-sonnet-5'),
    ])
    expect(db.activity({ 'claude-code': 'log' })).toEqual([
      { agentId: 'claude-code', at: NOW, model: 'claude-opus-5-5' },
    ])
    expect(db.activity({ 'claude-code': 'sarto', codex: 'log' })).toEqual([
      { agentId: 'claude-code', at: NOW + H, model: 'claude-sonnet-5' },
    ])
    db.close()
  })
})
