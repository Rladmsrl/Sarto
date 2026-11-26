// The accounts the user removed from the usage views, kept in the data folder: an account no
// longer used still leaves its last quota on the computer, in the agent's own files, so its
// readings are told apart by when they were measured.

import path from 'node:path'
import { isStoredAgentId } from '@shared/agents'
import { JsonFile, type LogFn } from '../storage'
import type { ForgottenAccount } from './accounts'

const VERSION = 1
/** More than anyone removes; the oldest go first. */
export const MAX_FORGOTTEN = 200

export interface ForgottenFile {
  accounts: ForgottenAccount[]
}

const ACCOUNT = /^[0-9a-f]{16}$/

function parse(data: Record<string, unknown>): ForgottenFile | string {
  if (!Array.isArray(data.accounts)) return 'accounts is not a list'
  const accounts: ForgottenAccount[] = []
  for (const item of data.accounts.slice(-MAX_FORGOTTEN)) {
    const entry = typeof item === 'object' && item !== null ? (item as Record<string, unknown>) : {}
    const { agentId, account, before } = entry
    if (
      typeof agentId === 'string' &&
      isStoredAgentId(agentId) &&
      typeof account === 'string' &&
      ACCOUNT.test(account) &&
      typeof before === 'number' &&
      Number.isFinite(before)
    ) {
      accounts.push({ agentId, account, before })
    }
  }
  return { accounts }
}

export type ForgottenStore = Pick<JsonFile<ForgottenFile>, 'load' | 'save' | 'flush'>

export function forgottenAccountsFile(userDataPath: string, log: LogFn): ForgottenStore {
  return new JsonFile<ForgottenFile>({
    file: path.join(userDataPath, 'state', 'usage-forgotten.json'),
    version: VERSION,
    migrations: {},
    parse,
    empty: () => ({ accounts: [] }),
    log,
    debounceMs: 0,
  })
}

/** The list with `account` removed as of `now`, replacing an earlier removal of it. */
export function forget(
  list: readonly ForgottenAccount[],
  agentId: ForgottenAccount['agentId'],
  account: string,
  now: number,
): ForgottenAccount[] {
  const rest = list.filter((f) => !(f.agentId === agentId && f.account === account))
  return [...rest, { agentId, account, before: now }].slice(-MAX_FORGOTTEN)
}
