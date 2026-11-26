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
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { memoryContext, type MemoryContext } from '../testing'
import { createCodexReader } from './codex'
import { codexPlan, parseCodexAccount } from './codex-quota'

const ROLLOUT = 'rollout-2026-11-21T10-00-00-019a1234-5678-7abc-8def-0123456789ab.jsonl'

let home: string
let file: string
beforeEach(() => {
  home = mkdtempSync(path.join(tmpdir(), 'usage-codex-quota-'))
  const folder = path.join(home, '.codex', 'sessions', '2026', '11', '21')
  mkdirSync(folder, { recursive: true })
  file = path.join(folder, ROLLOUT)
  writeFileSync(
    file,
    readFileSync(path.join(import.meta.dirname, 'fixtures', 'codex-rollout.jsonl'), 'utf8'),
  )
})
afterEach(() => rmSync(home, { recursive: true, force: true }))

const at = (time: string): number => Date.parse(time)
const windows = (context: MemoryContext) =>
  context.quotas
    .get('codex')
    ?.reading.windows.map((w) => [w.id, w.kind, w.scope, w.usedPercent, w.observedAt])

describe("Codex's plan quota from its rollouts", () => {
  it("keeps Codex's own pool's latest snapshot with windows and plan, and no other pool", async () => {
    const context = memoryContext({ home })
    expect(await createCodexReader().scan(context)).toBe(true)
    const reading = context.quotas.get('codex')?.reading
    expect(reading?.plan).toBe('Pro 200')
    // The last snapshot carries no windows and says nothing; the Spark pool's snapshot, though
    // newer, is another model's and is not shown.
    expect(windows(context)).toEqual([
      ['five_hour', 'session', null, 12, at('2026-11-21T10:00:05Z')],
      ['seven_day', 'weekly', null, 40, at('2026-11-21T10:00:05Z')],
    ])
    expect(reading?.windows[0]?.resetsAt).toBe(1795710000 * 1000)
    expect(reading?.windows[0]?.minutes).toBe(300)
    expect(reading?.observedAt).toBe(at('2026-11-21T10:00:05Z'))
    // The usage is still read as before.
    expect(context.rows.size).toBe(1)
  })

  it('merges a later scan into the stored pools: only a newer snapshot replaces one', async () => {
    const reader = createCodexReader()
    const context = memoryContext({ home })
    await reader.scan(context)
    appendFileSync(
      file,
      `${JSON.stringify({
        timestamp: '2026-11-21T10:05:00.000Z',
        type: 'event_msg',
        payload: {
          type: 'token_count',
          info: null,
          rate_limits: {
            limit_id: 'codex',
            primary: { used_percent: 15, window_minutes: 300, resets_at: 1795710000 },
            secondary: { used_percent: 41, window_minutes: 10080, resets_at: 1796200000 },
            plan_type: 'prolite',
          },
        },
      })}\n`,
    )
    await reader.scan(context)
    expect(context.quotas.get('codex')?.reading.plan).toBe('Pro 100')
    expect(windows(context)?.map(([id, , , used]) => [id, used])).toEqual([
      ['five_hour', 15],
      ['seven_day', 41],
    ])
  })

  it('takes the account from auth.json as a fingerprint, and nothing else of the file', async () => {
    writeFileSync(
      path.join(home, '.codex', 'auth.json'),
      JSON.stringify({ tokens: { account_id: 'ws-123', access_token: 'secret-token' } }),
    )
    const context = memoryContext({ home })
    await createCodexReader().scan(context)
    const stored = context.quotas.get('codex')
    // SHA-256("codex:ws-123"), its first 8 bytes, as the Mac app's test vector.
    expect(stored?.reading.account).toBe('b85c269bf0711afc')
    expect(JSON.stringify(stored)).not.toContain('ws-123')
    expect(JSON.stringify(stored)).not.toContain('secret-token')
    expect(parseCodexAccount('{"OPENAI_API_KEY":"sk-x","tokens":null}')).toBeNull()
    expect(parseCodexAccount('not json')).toBeNull()
  })

  it('stores the account even where no rollout exists', async () => {
    rmSync(path.join(home, '.codex', 'sessions'), { recursive: true })
    writeFileSync(
      path.join(home, '.codex', 'auth.json'),
      JSON.stringify({ tokens: { account_id: 'ws-123' } }),
    )
    const context = memoryContext({ home })
    expect(await createCodexReader().scan(context)).toBe(false)
    expect(context.quotas.get('codex')?.reading).toMatchObject({
      account: 'b85c269bf0711afc',
      windows: [],
    })
  })

  it('names plans as Codex does', () => {
    expect(codexPlan('pro')).toBe('Pro 200')
    expect(codexPlan('team')).toBe('Business')
    expect(codexPlan('business')).toBe('Enterprise')
    expect(codexPlan('self_serve_business_prolite')).toBe('Business Premium')
    expect(codexPlan(' Edu_Plus ')).toBe('Edu Plus')
    expect(codexPlan('brand_new-plan')).toBe('Brand New Plan')
    expect(codexPlan('')).toBeNull()
    expect(codexPlan(null)).toBeNull()
  })
})
