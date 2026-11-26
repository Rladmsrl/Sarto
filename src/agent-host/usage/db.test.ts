import { mkdtempSync, rmSync } from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { DatabaseSync } from 'node:sqlite'
import { afterEach, describe, expect, it } from 'vitest'
import type { SyncedHostUsageSection } from '@shared/sync/protocol'
import { SCHEMA_VERSION, UsageDb } from './db'

const dirs: string[] = []

function tempFile(): string {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'sarto-usage-'))
  dirs.push(dir)
  return path.join(dir, 'state', 'usage.db')
}

afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true })
})

describe('UsageDb schema', () => {
  it('initializes at the current schema version and reopens cleanly', () => {
    const file = tempFile()
    const first = UsageDb.open(file, () => {})
    expect(first.status).toBe('created')
    first.close()

    const check = new DatabaseSync(file)
    expect(check.prepare('PRAGMA user_version').get()!.user_version).toBe(SCHEMA_VERSION)
    check.close()

    const reopened = UsageDb.open(file, () => {})
    expect(reopened.status).toBe('ok')
    reopened.close()
  })

  it('refuses to open a database from a newer schema version', () => {
    const file = tempFile()
    UsageDb.open(file, () => {}).close()
    const raw = new DatabaseSync(file)
    raw.exec(`PRAGMA user_version = ${SCHEMA_VERSION + 1}`)
    raw.close()

    const db = UsageDb.open(file, () => {})
    expect(db.status).toBe('newer')
    expect(db.open).toBe(false)
    db.close()
  })
})

describe("other Macs' synced usage", () => {
  const section = (rows: number, updatedAt: number): SyncedHostUsageSection => ({
    updatedAt,
    fromComputer: false,
    computerSources: {},
    buckets: [
      {
        quarter: 7_000_000,
        source: 'sarto',
        agentId: 'codex',
        model: 'gpt-5',
        project: '',
        rows,
        input: 10,
        output: 2,
        reasoning: 0,
        cacheRead: 0,
        cacheWrite: 0,
        cacheWrite1h: 0,
        turns: 1,
      },
    ],
  })
  const rows = (db: UsageDb): number => db.remoteStats().reduce((sum, stat) => sum + stat.rows, 0)

  it('replaces only the Macs an update carries, and drops one it no longer names', () => {
    const db = UsageDb.open(tempFile(), () => {})
    db.setRemoteUsage({ a: section(1, 1), b: section(10, 1) })
    expect(rows(db)).toBe(11)
    db.setRemoteUsage({ b: section(20, 2) }, ['a', 'b'])
    expect(rows(db)).toBe(21)
    db.setRemoteUsage({}, ['b'])
    expect(rows(db)).toBe(20)
    // Without the list of Macs, the update is all there is.
    db.setRemoteUsage({ a: section(3, 3) })
    expect(rows(db)).toBe(3)
    db.close()
  })

  it("counts an account's Cursor requests once, however many Macs read them", () => {
    const cursorSection = (rows: number, account: string | null): SyncedHostUsageSection => ({
      ...section(rows, 1),
      computerSources: { cursor: 'log' },
      buckets: section(rows, 1).buckets.map((b) => ({ ...b, source: 'log', agentId: 'cursor' })),
      quotas: [{ agentId: 'cursor', account, plan: 'Ultra', windows: [], observedAt: 1 }],
    })
    const db = UsageDb.open(tempFile(), () => {})
    db.setRemoteUsage({
      a: cursorSection(1, 'x'),
      b: cursorSection(10, 'x'),
      c: cursorSection(100, 'y'),
      d: cursorSection(1000, null),
    })
    expect(rows(db)).toBe(1101)

    // This Mac reads account y itself, so c's copy of it no longer counts.
    db.putQuota(
      { agentId: 'cursor', account: 'y', plan: 'Ultra', windows: [], observedAt: 1 },
      'agent',
    )
    expect(rows(db)).toBe(1101)
    db.write([
      {
        key: 'cursor:e1',
        source: 'log',
        agentId: 'cursor',
        sessionId: null,
        project: null,
        model: 'claude-opus-5-5',
        at: 7_000_000 * 15 * 60_000,
        input: 1,
        output: 1,
        reasoning: null,
        cacheRead: 0,
        cacheWrite: 0,
        cacheWrite1h: 0,
        turn: 0,
      },
    ])
    expect(rows(db)).toBe(1001)
    db.close()
  })
})
