import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { SyncedHostUsageSection, SyncedUsageBucket } from '@shared/sync/protocol'
import type { QuotaReading } from '@shared/usage'
import {
  accountGroups,
  isForgotten,
  mergedReading,
  type DeviceReading,
  type ForgottenAccount,
} from './accounts'
import { QUARTER_MS, UsageDb, type OverviewRequest } from './db'
import { forget } from './forgotten'
import type { UsageRow } from './model'
import { hourStarts, localDayStarts } from './overview'
import { syncedQuotas } from './synced'

const NOW = 1_800_000_000_000
const H = 3_600_000
const DAY = 24 * H

/** A Claude Code reading with one weekly window, as the app's tests make them. */
function claude(
  account: string | null,
  usedPercent: number,
  observedAt: number,
  plan: string | null = 'Max',
): QuotaReading {
  return {
    agentId: 'claude-code',
    account,
    plan,
    windows: [
      {
        id: 'seven_day',
        kind: 'weekly',
        scope: null,
        minutes: 10080,
        usedPercent,
        resetsAt: observedAt + DAY,
        observedAt,
      },
    ],
    observedAt,
  }
}

const remote = (id: string, reading: QuotaReading): DeviceReading => ({
  device: { id, name: `Mac ${id.toUpperCase()}` },
  reading,
})

describe('account groups, as the Mac app’s accountReadings', () => {
  it('merge one account’s readings, the freshest leading, and keep other accounts apart', () => {
    const groups = accountGroups(
      null,
      [
        remote('a', claude('acct-1', 20, NOW - 600_000)),
        remote('b', claude('acct-1', 35, NOW - 60_000)),
        remote('c', claude('acct-2', 80, NOW - 300_000, 'Pro')),
      ],
      NOW,
    )
    expect(groups.map((g) => g.map((item) => item.device?.id))).toEqual([['b', 'a'], ['c']])
    expect(mergedReading(groups[0]!).windows[0]?.usedPercent).toBe(35)
    expect(mergedReading(groups[1]!).plan).toBe('Pro')
  })

  it('never merge readings without an account, even with equal numbers', () => {
    const groups = accountGroups(
      null,
      [remote('a', claude(null, 40, NOW - 60_000)), remote('b', claude(null, 40, NOW - 120_000))],
      NOW,
    )
    expect(groups.map((g) => g[0]?.device?.id)).toEqual(['a', 'b'])
  })

  it('leave out another account unread for a week, and put this computer’s account first', () => {
    const local = claude('acct-1', 10, NOW - 3 * H)
    const groups = accountGroups(
      local,
      [
        remote('b', claude('acct-2', 10, NOW - 8 * DAY)),
        remote('c', claude('acct-3', 50, NOW - 60_000)),
        remote('d', claude('acct-1', 12, NOW - 60_000, null)),
      ],
      NOW,
    )
    expect(groups.map((g) => g[0]?.reading.account)).toEqual(['acct-1', 'acct-3'])
    // The freshest reading leads; the plan is the newest one any reading names.
    expect(groups[0]!.map((item) => item.device?.id ?? 'here')).toEqual(['d', 'here'])
    expect(mergedReading(groups[0]!)).toMatchObject({ plan: 'Max', account: 'acct-1' })
    // A stale account that is this computer's own still shows.
    expect(accountGroups(claude('acct-9', 1, NOW - 9 * DAY), [], NOW)).toHaveLength(1)
  })
})

describe('other computers’ quota sections', () => {
  it('keep what fits and leave out what does not', () => {
    const section = {
      updatedAt: NOW,
      deviceName: 'Mac B',
      quotas: [
        claude('acct-1', 10, NOW),
        { agentId: 'codex', windows: [{ id: 'five_hour', kind: 'weird', usedPercent: 3 }] },
        { windows: [] },
        'junk',
      ],
      quotaHistory: [
        {
          agentId: 'claude-code',
          window: 'seven_day',
          samples: [
            { at: NOW - H, usedPercent: 140, resetsAt: null },
            { at: NOW - 3 * DAY, usedPercent: 5, resetsAt: null },
            { at: 'yesterday', usedPercent: 5 },
          ],
        },
      ],
      activity: [{ agentId: 'codex', at: NOW, model: 7 }, { agentId: 'x' }],
    } as unknown as SyncedHostUsageSection
    const read = syncedQuotas('b', section, NOW)
    expect(read.name).toBe('Mac B')
    expect(read.quotas).toEqual([
      claude('acct-1', 10, NOW),
      { agentId: 'codex', account: null, plan: null, windows: [], observedAt: null },
    ])
    expect(read.history).toEqual([
      {
        agentId: 'claude-code',
        window: 'seven_day',
        samples: [{ at: NOW - H, usedPercent: 100, resetsAt: null }],
      },
    ])
    expect(read.activity).toEqual([{ agentId: 'codex', at: NOW, model: null }])
    // An older daemon's section, with none of these fields, has none.
    expect(syncedQuotas('c', { updatedAt: NOW } as SyncedHostUsageSection, NOW)).toEqual({
      name: 'c',
      updatedAt: NOW,
      quotas: [],
      history: [],
      activity: [],
    })
  })
})

describe('the usage overview’s quotas and figures', () => {
  let dir: string
  beforeEach(() => {
    dir = mkdtempSync(path.join(tmpdir(), 'usage-overview-'))
  })
  afterEach(() => rmSync(dir, { recursive: true, force: true }))
  const open = (): UsageDb =>
    UsageDb.open(
      path.join(dir, 'usage.db'),
      () => {},
      () => NOW,
    )

  const request = (includeRemote: boolean): OverviewRequest => ({
    sources: { 'claude-code': 'log' },
    computers: { 'claude-code': 'log' },
    includeRemote,
    dayStarts: localDayStarts(NOW, 90),
    hourStarts: hourStarts(NOW, 24),
    now: NOW,
  })

  /** A Mac's section with `tokens` of Sonnet every quarter hour of the last 12 hours. */
  function section(
    name: string,
    tokens: number,
    reading: QuotaReading,
    history: SyncedHostUsageSection['quotaHistory'] = [],
  ): SyncedHostUsageSection {
    const buckets: SyncedUsageBucket[] = []
    for (let q = NOW - 12 * H; q < NOW; q += QUARTER_MS) {
      buckets.push({
        quarter: q / QUARTER_MS,
        source: 'log',
        agentId: 'claude-code',
        model: 'claude-sonnet-4-5',
        project: '',
        rows: 1,
        input: tokens,
        output: 0,
        reasoning: 0,
        cacheRead: 0,
        cacheWrite: 0,
        cacheWrite1h: 0,
        turns: 0,
      })
    }
    return {
      updatedAt: NOW - 300_000,
      fromComputer: true,
      computerSources: { 'claude-code': 'log' },
      buckets,
      quotas: [reading],
      quotaHistory: history,
      activity: [{ agentId: 'claude-code', at: NOW - 60_000, model: 'claude-sonnet-4-5' }],
      deviceName: name,
    }
  }

  it('leaves out a removed account until it is measured again, here and from other Macs', () => {
    const db = open()
    db.putQuota(claude('aaaaaaaaaaaaaaaa', 30, NOW - 10 * H), 'files')
    db.setRemoteUsage({
      b: section('Mac B', 1_000, claude('bbbbbbbbbbbbbbbb', 50, NOW - 2 * H)),
      c: section('Mac C', 1_000, claude('aaaaaaaaaaaaaaaa', 40, NOW - 9 * H)),
    })
    const accounts = (forgotten: ForgottenAccount[]) =>
      db
        .overview({ ...request(true), forgotten })
        .quotas[0]!.groups.map((g) => [g.reading.account, g.here])
    expect(accounts([])).toEqual([
      ['aaaaaaaaaaaaaaaa', true],
      ['bbbbbbbbbbbbbbbb', false],
    ])
    // Removed now: neither this Mac's reading nor Mac C's of the same account shows, and the
    // other account leads.
    const removed = forget([], 'claude-code', 'aaaaaaaaaaaaaaaa', NOW - H)
    expect(accounts(removed)).toEqual([['bbbbbbbbbbbbbbbb', false]])
    // Used again after it was removed: it is back.
    db.putQuota(claude('aaaaaaaaaaaaaaaa', 35, NOW - 30_000), 'files')
    expect(accounts(removed)).toEqual([
      ['aaaaaaaaaaaaaaaa', true],
      ['bbbbbbbbbbbbbbbb', false],
    ])
    // Readings that name no account are never removed by one.
    expect(isForgotten(claude(null, 1, NOW - 10 * H), removed)).toBe(false)
    db.close()
  })

  it('forecasts an account from the usage of the computers signed in to it only', () => {
    // The app's testForecastCountsOnlyTheUsageOfMacsOnTheSameAccount.
    const db = open()
    const mine = section('Mac A', 1_000_000, claude('acct-1', 10, NOW - 60_000))
    const theirs = section('Mac B', 90_000_000, claude('acct-2', 50, NOW - 120_000))
    db.setRemoteUsage({ a: mine })
    const alone = db.overview(request(true)).quotas[0]!.groups
    db.setRemoteUsage({ a: mine, b: theirs })
    const together = db.overview(request(true)).quotas[0]!.groups
    expect(together.map((g) => g.reading.account)).toEqual(['acct-1', 'acct-2'])
    expect(alone[0]!.forecasts.seven_day!.estimatedRemainingTokens).not.toBeNull()
    expect(together[0]!.forecasts.seven_day).toEqual(alone[0]!.forecasts.seven_day)
    expect(together[1]!.forecasts.seven_day!.windowTokens).toBeGreaterThan(
      together[0]!.forecasts.seven_day!.windowTokens * 50,
    )
    db.close()
  })

  it('answers today, the ranked models, the series, the computers and the latest requests', () => {
    const db = open()
    const row = (key: string, at: number, model: string, input: number): UsageRow => ({
      key,
      source: 'log',
      agentId: 'claude-code',
      sessionId: null,
      project: null,
      model,
      at,
      input,
      output: 0,
      reasoning: null,
      cacheRead: 0,
      cacheWrite: 0,
      cacheWrite1h: 0,
      turn: 0,
    })
    db.write([
      row('a', NOW - 30 * 60_000, 'claude-sonnet-4-5', 1_000_000),
      row('b', NOW - 20 * 60_000, 'gemini-4-carbon', 500_000),
      row('c', NOW - 40 * DAY, 'claude-fable-5-9', 2_000_000),
    ])
    db.putQuota(claude('acct-1', 30, NOW - 60_000), 'files')
    db.setRemoteUsage({ b: section('Mac B', 1000, claude('acct-1', 31, NOW - 30_000)) })
    const answer = db.overview(request(false))
    const today = answer.today.find((t) => t.agentId === 'claude-code')!
    expect(today).toMatchObject({ input: 1_500_000, requests: 2 })
    expect(today.cost).toBeCloseTo(3 + 1, 9)
    const week = answer.models.find((m) => m.days === 7)!.models
    expect(week.map((m) => [m.model, m.price?.kind, m.price?.origin])).toEqual(
      expect.arrayContaining([
        ['claude-sonnet-4-5', 'exact', 'bundled'],
        ['gemini-4-carbon', 'exact', 'registry'],
      ]),
    )
    const quarter = answer.models.find((m) => m.days === 90)!.models
    expect(quarter.find((m) => m.model === 'claude-fable-5-9')?.price).toMatchObject({
      kind: 'family',
    })
    expect(answer.daily.every((d) => d.day >= 0 && d.day < 90)).toBe(true)
    // NOW starts an hour, so half an hour ago is the hour before the current one.
    expect(answer.hourly.map((h) => h.day)).toEqual([22])
    expect(answer.localActivity).toEqual([
      { agentId: 'claude-code', at: NOW - 20 * 60_000, model: 'gemini-4-carbon' },
    ])
    expect(answer.remoteActivity).toEqual([
      { agentId: 'claude-code', at: NOW - 60_000, model: 'claude-sonnet-4-5' },
    ])
    expect(answer.devices).toEqual([{ id: 'b', name: 'Mac B', updatedAt: NOW - 300_000 }])
    // The other Mac's fresher reading of this account leads it.
    const [group] = answer.quotas[0]!.groups
    expect(group).toMatchObject({ device: { id: 'b' }, here: true })
    expect(group!.reading.windows[0]?.usedPercent).toBe(31)
    db.close()
  })
})
