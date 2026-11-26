// An in-memory scan context for the readers' tests, keeping rows and quotas as the database does.

import type { Platform } from '@shared/platform'
import type { AgentId } from '@shared/thread'
import type { QuotaReading } from '@shared/usage'
import type { FileCursor, ScanContext, UsageRow } from './model'
import type { StoredQuota } from './quota'
import { keepsNewer } from './rows'

export interface MemoryContext extends ScanContext {
  readonly rows: Map<string, UsageRow>
  readonly cursors: Map<string, FileCursor>
  readonly quotas: Map<AgentId, StoredQuota>
  readonly logs: { level: string; message: string }[]
}

export function memoryContext(
  options: { env?: Record<string, string | undefined>; home?: string; platform?: Platform } = {},
): MemoryContext {
  const rows = new Map<string, UsageRow>()
  const cursors = new Map<string, FileCursor>()
  const quotas = new Map<AgentId, StoredQuota>()
  const logs: { level: string; message: string }[] = []
  return {
    env: options.env ?? {},
    home: options.home ?? '/home/test',
    platform: options.platform ?? process.platform,
    signal: new AbortController().signal,
    rows,
    cursors,
    quotas,
    logs,
    cursor: (id) => cursors.get(id) ?? null,
    commit(next, cursor) {
      for (const row of next) {
        const stored = rows.get(row.key)
        if (!stored || keepsNewer(stored, row)) rows.set(row.key, row)
      }
      cursors.set(cursor.id, cursor)
    },
    plan() {},
    done() {},
    log: (level, message) => logs.push({ level, message }),
    storedQuota: (agentId) => quotas.get(agentId) ?? null,
    quota(reading: QuotaReading, state = null) {
      quotas.set(reading.agentId, { reading, state })
    },
  }
}
