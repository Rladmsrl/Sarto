import {
  appendFileSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { SyncedHostUsageSection } from '@shared/sync/protocol'
import type { AgentId } from '@shared/thread'
import type { QuotaReading } from '@shared/usage'
import { UsageManager } from './manager'
import type { LogReader } from './model'
import { refreshClaudeQuota } from './readers/claude-quota'
import { refreshCodexQuota } from './readers/codex-quota'
import { startUsageService } from './service'
import { UsageStore, type UsageWorker } from './store'
import { memoryContext } from './testing'

const fixture = (name: string): string =>
  readFileSync(path.join(import.meta.dirname, 'readers', 'fixtures', name), 'utf8')

let home: string
beforeEach(() => {
  home = mkdtempSync(path.join(tmpdir(), 'usage-refresh-'))
})
afterEach(() => rmSync(home, { recursive: true, force: true }))

describe('quick quota reads between scans', () => {
  it('read .claude.json again only once it changed', async () => {
    const file = path.join(home, '.claude.json')
    writeFileSync(file, fixture('claude-json-limits.json'))
    const context = memoryContext({ home })
    const stored = vi.spyOn(context, 'quota')
    await refreshClaudeQuota(context)
    expect(context.quotas.get('claude-code')?.reading.windows).toHaveLength(4)
    await refreshClaudeQuota(context)
    expect(stored).toHaveBeenCalledTimes(1)
    writeFileSync(file, fixture('claude-json-legacy.json'))
    await refreshClaudeQuota(context)
    expect(stored).toHaveBeenCalledTimes(2)
    expect(context.quotas.get('claude-code')?.reading.plan).toBe('Max 20×')
  })

  it('take Codex’s rate limits from the end of its newest rollouts, read again once they grow', async () => {
    const folder = path.join(home, '.codex', 'sessions', '2026', '11', '21')
    mkdirSync(folder, { recursive: true })
    const rollout = path.join(folder, 'rollout-2026-11-21T10-00-00-019a.jsonl')
    // A long rollout: its first lines lie before the end that is read.
    writeFileSync(
      rollout,
      `${'{"type":"filler"}\n'.repeat(20_000)}${fixture('codex-rollout.jsonl')}`,
    )
    const context = memoryContext({ home })
    const stored = vi.spyOn(context, 'quota')
    const root = path.join(home, '.codex')
    await refreshCodexQuota(context, root)
    const reading = context.quotas.get('codex')?.reading
    expect(reading?.plan).toBe('Pro 200')
    expect(reading?.windows.map((w) => [w.id, w.usedPercent])).toEqual([
      ['five_hour', 12],
      ['seven_day', 40],
    ])
    await refreshCodexQuota(context, root)
    expect(stored).toHaveBeenCalledTimes(1)
    appendFileSync(
      rollout,
      `${JSON.stringify({
        timestamp: '2026-11-21T10:30:00.000Z',
        type: 'event_msg',
        payload: {
          type: 'token_count',
          info: null,
          rate_limits: {
            limit_id: 'codex',
            primary: { used_percent: 30, window_minutes: 300, resets_at: 1795710000 },
            secondary: { used_percent: 41, window_minutes: 10080, resets_at: 1796200000 },
            plan_type: 'pro',
          },
        },
      })}\n`,
    )
    await refreshCodexQuota(context, root)
    expect(stored).toHaveBeenCalledTimes(2)
    expect(context.quotas.get('codex')?.reading.windows.map((w) => w.usedPercent)).toEqual([30, 41])
  })
})

/** The usage service in this thread, as the store's worker. */
function inlineWorker(file: string): UsageWorker {
  const listeners: ((reply: never) => void)[] = []
  let handle: ((request: never) => void) | null = null
  queueMicrotask(() => {
    handle = startUsageService(file, readers, (reply) => {
      for (const listener of listeners) listener(reply as never)
    }) as (request: never) => void
  })
  return {
    postMessage: (request) => queueMicrotask(() => handle?.(request as never)),
    onMessage: (listener) => listeners.push(listener as (reply: never) => void),
    onExit: () => {},
    terminate: async () => {},
  }
}

const NOW = Date.UTC(2026, 10, 21, 12)
const ACCOUNT = 'b74d6c21e7e33bf0'

/** Antigravity's reader stores the account agy is signed in to, as its quick read does. */
const readers: LogReader[] = [
  {
    agentId: 'antigravity',
    locations: () => [],
    scan: async () => true,
    quota: async (context) => {
      context.quota({
        agentId: 'antigravity',
        account: ACCOUNT,
        plan: null,
        windows: [],
        observedAt: null,
      })
    },
  },
]

function manager(fromComputer = true, firstScanMs = 600_000) {
  const store = new UsageStore({
    file: path.join(home, 'usage.db'),
    createWorker: inlineWorker,
    log: () => {},
    onChanged: () => {},
    onProgress: () => {},
    onStatus: () => {},
  })
  const refreshPlan = vi.fn<(agentId: AgentId) => Promise<void>>(async () => {})
  const usage = new UsageManager({
    store,
    readers,
    fromComputer,
    platform: 'darwin',
    home,
    env: async () => ({}),
    isScratch: () => false,
    plans: async () => ({ antigravity: { limits: [] } }),
    refreshPlan,
    log: () => {},
    changed: () => {},
    status: () => {},
    now: () => NOW,
    timings: { firstScanMs, intervalMs: 600_000, quotaMs: 600_000, planMs: 300_000 },
  })
  return { store, usage, refreshPlan }
}

const section = (reading: Partial<QuotaReading>): SyncedHostUsageSection =>
  ({
    updatedAt: NOW,
    fromComputer: true,
    computerSources: {},
    buckets: [],
    quotas: [
      {
        agentId: 'antigravity',
        account: ACCOUNT,
        plan: 'Google AI Pro',
        windows: [],
        observedAt: NOW - 60_000,
        ...reading,
      },
    ],
  }) as SyncedHostUsageSection

describe('reading agy’s /usage', () => {
  it('is left while another computer read the same account within five minutes', async () => {
    const { store, usage, refreshPlan } = manager()
    await store.ready
    await usage.refreshQuotas()
    await usage.setRemoteUsage({ b: section({}) })
    await usage.refreshPlans()
    expect(refreshPlan).not.toHaveBeenCalled()

    await usage.setRemoteUsage({ b: section({ observedAt: NOW - 6 * 60_000 }) })
    await usage.refreshPlans()
    expect(refreshPlan).toHaveBeenCalledTimes(1)

    await usage.setRemoteUsage({ b: section({ account: 'another' }) })
    await usage.refreshPlans()
    expect(refreshPlan).toHaveBeenCalledTimes(2)
    await usage.close()
  })

  it('runs once startup settles, without waiting a whole interval', async () => {
    vi.useFakeTimers({ toFake: ['setTimeout', 'setInterval'] })
    try {
      const { store, usage, refreshPlan } = manager(true, 1_000)
      await store.ready
      usage.start()
      await vi.advanceTimersByTimeAsync(1_000)
      await vi.waitFor(() => expect(refreshPlan).toHaveBeenCalledWith('antigravity'))
      await usage.close()
    } finally {
      vi.useRealTimers()
    }
  })

  it('is not run while Usage on this computer is off', async () => {
    const { store, usage, refreshPlan } = manager(false)
    await store.ready
    await usage.refreshPlans()
    expect(refreshPlan).not.toHaveBeenCalled()
    await usage.close()
  })
})
