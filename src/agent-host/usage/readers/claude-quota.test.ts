import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { memoryContext } from '../testing'
import { claudeReader } from './claude'
import { claudePlan, parseClaudeQuota } from './claude-quota'

const fixture = (name: string): string =>
  readFileSync(path.join(import.meta.dirname, 'fixtures', name), 'utf8')

const FETCHED = 1795200000000

describe("Claude Code's plan quota from .claude.json", () => {
  it('reads the windows of the limits list, scoping one to its model', () => {
    const reading = parseClaudeQuota(fixture('claude-json-limits.json'))
    expect(reading?.windows).toEqual([
      {
        id: 'five_hour',
        kind: 'session',
        scope: null,
        minutes: 300,
        usedPercent: 42.5,
        resetsAt: Date.parse('2026-11-21T15:00:00Z'),
        observedAt: FETCHED,
      },
      {
        id: 'seven_day',
        kind: 'weekly',
        scope: null,
        minutes: 10080,
        usedPercent: 18,
        resetsAt: Date.parse('2026-11-25T08:00:00Z'),
        observedAt: FETCHED,
      },
      {
        id: 'seven_day_fable',
        kind: 'scoped',
        scope: 'Fable',
        minutes: 10080,
        usedPercent: 61,
        resetsAt: Date.parse('2026-11-25T08:00:00Z'),
        observedAt: FETCHED,
      },
      {
        id: 'monthly_spend',
        kind: 'other',
        scope: null,
        minutes: null,
        usedPercent: 3,
        resetsAt: null,
        observedAt: FETCHED,
      },
    ])
    expect(reading?.observedAt).toBe(FETCHED)
  })

  it('names the plan by the organization, not the rate-limit tier', () => {
    // A Team premium seat has Max 5x limits and is still a Team plan.
    expect(parseClaudeQuota(fixture('claude-json-limits.json'))?.plan).toBe('Team Premium')
    expect(parseClaudeQuota(fixture('claude-json-legacy.json'))?.plan).toBe('Max 20×')
    expect(claudePlan({ planDisplayName: ' Max (5x) ', organizationType: 'claude_pro' })).toBe(
      'Max (5x)',
    )
    expect(claudePlan({ organizationType: 'claude_max', userRateLimitTier: 'x_max_5x' })).toBe(
      'Max 5×',
    )
    expect(
      claudePlan({ organizationType: 'claude_enterprise', seatTier: 'enterprise_standard' }),
    ).toBe('Enterprise Standard')
    // An older Claude Code wrote no organization type; the tier stands in.
    expect(claudePlan({ userRateLimitTier: 'default_claude_pro' })).toBe('Pro')
    expect(claudePlan({})).toBeNull()
    expect(claudePlan(null)).toBeNull()
  })

  it('reads the older five_hour and seven_day form', () => {
    const reading = parseClaudeQuota(fixture('claude-json-legacy.json'))
    expect(reading?.windows.map((w) => [w.id, w.kind, w.usedPercent, w.resetsAt])).toEqual([
      ['five_hour', 'session', 42.5, Date.parse('2026-11-21T15:00:00Z')],
      ['seven_day', 'weekly', 7, 1795700000 * 1000],
    ])
  })

  it('fingerprints the account id, else the address, and never keeps either', () => {
    const limits = parseClaudeQuota(fixture('claude-json-limits.json'))
    // SHA-256("claude:4f1c6b9e-0000-4000-8000-000000000001"), its first 8 bytes.
    expect(limits?.account).toBe('efe658764602f1ff')
    expect(JSON.stringify(limits)).not.toContain('4f1c6b9e')
    expect(JSON.stringify(limits)).not.toContain('someone@example.com')
    expect(parseClaudeQuota(fixture('claude-json-legacy.json'))?.account).toMatch(/^[0-9a-f]{16}$/)
  })

  it('reads no quota from a half-written file, and nothing from one without a sign-in', () => {
    expect(parseClaudeQuota('{ "oauthAccount": {"organizationType": "claude_max"')).toBeNull()
    expect(parseClaudeQuota('{"theme":"dark"}')).toEqual({
      agentId: 'claude-code',
      account: null,
      plan: null,
      windows: [],
      observedAt: null,
    })
  })
})

describe("Claude Code's reader", () => {
  let home: string
  beforeEach(() => {
    home = mkdtempSync(path.join(tmpdir(), 'usage-claude-quota-'))
  })
  afterEach(() => rmSync(home, { recursive: true, force: true }))

  it('stores the quota beside the logs, from the folder CLAUDE_CONFIG_DIR moves it to', async () => {
    const moved = path.join(home, 'claude-config')
    mkdirSync(moved)
    writeFileSync(path.join(home, '.claude.json'), fixture('claude-json-legacy.json'))
    writeFileSync(path.join(moved, '.claude.json'), fixture('claude-json-limits.json'))
    const context = memoryContext({ home, env: { CLAUDE_CONFIG_DIR: moved } })
    // No logs folder: the reader finds no logs, and still reads the quota.
    expect(await claudeReader.scan(context)).toBe(false)
    expect(context.quotas.get('claude-code')?.reading.plan).toBe('Team Premium')
  })

  it('stores nothing while .claude.json is missing', async () => {
    const context = memoryContext({ home })
    await claudeReader.scan(context)
    expect(context.quotas.size).toBe(0)
  })
})
