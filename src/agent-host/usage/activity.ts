// An agent's latest request and the model it ran on, as the Mac app's menu bar names them.

import type { AgentId } from '@shared/thread'
import type { AgentActivity } from '@shared/usage'

/** The latest rows read per agent, enough to look past a run of helper calls. */
export const ACTIVITY_ROWS = 50

/** How close to a main model's call a small Haiku call counts as its helper. */
const HELPER_MS = 600_000

export interface ActivityRow {
  at: number
  model: string
  output: number
  total: number
}

const named = (model: string): boolean =>
  model !== '' && model !== 'unknown' && model !== '<synthetic>'
const isHaiku = (model: string): boolean => model.includes('haiku')

/**
 * The newest row's time and model, from rows newest first. Claude Code runs small Haiku calls for
 * titles and summaries beside a main model; such a call within ten minutes after a call of
 * another model leaves that model, as the Mac app's `noteActivity` does.
 */
export function latestActivity(
  agentId: AgentId,
  rows: readonly ActivityRow[],
): AgentActivity | null {
  const first = rows[0]
  if (!first) return null
  const index = rows.findIndex((row) => named(row.model))
  const latest = rows[index]
  if (!latest) return { agentId, at: first.at, model: null }
  let model = latest.model
  const helper =
    agentId.startsWith('claude-code') &&
    isHaiku(model) &&
    latest.output < 400 &&
    latest.total < 6000
  if (helper) {
    const main = rows
      .slice(index + 1)
      .find((row) => named(row.model) && !isHaiku(row.model) && row.at >= latest.at - HELPER_MS)
    if (main) model = main.model
  }
  return { agentId, at: first.at, model }
}
