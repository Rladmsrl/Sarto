// The log readers, one per agent that keeps its own usage on disk or, as Cursor, on its account.

import type { LogReader } from '../model'
import { antigravityReader } from './antigravity'
import { claudeReader } from './claude'
import { codexReader } from './codex'
import { cursorReader } from './cursor'
import { opencodeReader } from './opencode'

export const LOG_READERS: readonly LogReader[] = [
  claudeReader,
  codexReader,
  opencodeReader,
  antigravityReader,
  cursorReader,
]
