// Persistent Requests pane reader for Google Antigravity (`agy`).
//
// Reads per-request records directly from agy's local conversation SQLite database under
// `~/.gemini/antigravity-cli/conversations/<acpSessionId>.db`, surviving daemon restarts and
// exposing real per-request token/cache breakdowns, models, TTFT, generation timing, and tool
// actions. When the database is absent or unreadable, falls back to the in-memory ACP log.

import path from 'node:path'
import {
  REQUESTS_PAGE,
  type ModelRequest,
  type ModelRequestsOverview,
  type RequestActionKind,
  type RequestParam,
  type RequestPart,
  type RequestTokens,
  type RequestTurn,
} from '@shared/model-requests'
import {
  agyReadRequestRaw,
  agyReadRequestsPage,
  agyReadRequestsSummary,
} from '../acp/agy-sqlite-worker'
import { agyConversationFile, parseAgyGeneration, type AgyGeneration } from '../acp/agy-telemetry'
import { t } from '../i18n'
import { decodeFields } from '../usage/readers/antigravity'
import { preview, summarizeActions } from './claude-transcript'
import { foldAll, type ModelRequestsReader, type RequestsTarget } from './reader'

const RAW_PREFIX = 'gen:'
const NEW_TURN_GAP_MS = 15_000

export interface AgyStepInfo {
  idx: number
  createdAt: number | null
  completedAt: number | null
  toolName: string | null
  toolArgsPreview: string | null
  callId: string | null
  genIdx: number | null
}

function timestampMs(seconds: number | null, nanos: number | null): number | null {
  if (seconds === null || seconds <= 0) return null
  return Math.round(seconds * 1000 + (nanos ?? 0) / 1_000_000)
}

/** Decodes one `steps.metadata` protobuf blob for timing and tool correlation. */
export function parseAgyStep(idx: number, metadata: Uint8Array): AgyStepInfo {
  const fields = decodeFields(metadata)
  const created = fields.message(1)
  const completed = fields.message(8)
  const tool = fields.message(4)
  const rawArgs = tool?.string(3) ?? null
  return {
    idx,
    createdAt: timestampMs(created?.int(1) ?? null, created?.int(2) ?? null),
    completedAt: timestampMs(completed?.int(1) ?? null, completed?.int(2) ?? null),
    toolName: tool?.string(2) ?? null,
    toolArgsPreview: rawArgs ? preview(rawArgs) : null,
    callId: fields.message(9)?.string(11) ?? null,
    genIdx: fields.message(20)?.int(3) ?? null,
  }
}

function toolActionKind(name: string): RequestActionKind {
  const lower = name.toLowerCase()
  if (lower.includes('read') || lower.includes('view')) return 'read'
  if (lower.includes('edit') || lower.includes('write') || lower.includes('replace')) return 'edit'
  if (
    lower.includes('grep') ||
    lower.includes('find') ||
    lower.includes('search') ||
    lower.includes('list')
  ) {
    return lower.includes('web') ? 'web' : 'search'
  }
  if (lower.includes('command') || lower.includes('shell') || lower.includes('bash')) return 'run'
  if (lower.includes('url') || lower.includes('web') || lower.includes('fetch')) return 'web'
  if (lower.includes('subagent') || lower.includes('swarm') || lower.includes('send_message')) {
    return 'agent'
  }
  return 'tool'
}

function formatMs(ms: number): string {
  return ms >= 1000 ? `${(ms / 1000).toFixed(2)}s` : `${Math.round(ms)}ms`
}

function requestTokens(gen: AgyGeneration): RequestTokens {
  return {
    input: gen.input,
    cacheRead: gen.cacheRead,
    cacheWrite: 0,
    cacheWrite1h: null,
    output: gen.output,
    reasoning: gen.thinking,
  }
}

/**
 * Turns decoded `gen_metadata` rows and correlated `steps` into Requests pane turns.
 * Generations must be passed in ascending `idx` order.
 */
export function buildAgyTurns(
  generations: readonly AgyGeneration[],
  steps: readonly AgyStepInfo[],
): RequestTurn[] {
  const byGenIdx = new Map<number, AgyStepInfo[]>()
  const byCallId = new Map<string, AgyStepInfo[]>()
  for (const step of steps) {
    if (step.genIdx !== null) {
      const list = byGenIdx.get(step.genIdx) ?? []
      list.push(step)
      byGenIdx.set(step.genIdx, list)
    }
    if (step.callId) {
      const list = byCallId.get(step.callId) ?? []
      list.push(step)
      byCallId.set(step.callId, list)
    }
  }

  const turns: RequestTurn[] = []
  let currentTurn: RequestTurn | null = null
  let prevHadTools = false
  let prevEndedAt: number | null = null

  for (const gen of generations) {
    const matched = new Map<number, AgyStepInfo>()
    for (const s of byGenIdx.get(gen.idx) ?? []) matched.set(s.idx, s)
    if (gen.callId) {
      for (const s of byCallId.get(gen.callId) ?? []) matched.set(s.idx, s)
    }
    const genSteps = [...matched.values()].sort((a, b) => a.idx - b.idx)

    const createdCandidates = genSteps
      .map((s) => s.createdAt)
      .filter((v): v is number => v !== null)
    const completedCandidates = genSteps
      .map((s) => s.completedAt)
      .filter((v): v is number => v !== null)

    const totalMs =
      gen.ttftMs !== null || gen.genMs !== null
        ? Math.round((gen.ttftMs ?? 0) + (gen.genMs ?? 0))
        : null
    const sentAt =
      createdCandidates.length > 0
        ? Math.min(...createdCandidates)
        : completedCandidates.length > 0 && totalMs !== null
          ? Math.max(0, Math.min(...completedCandidates) - totalMs)
          : null
    const endedAt =
      sentAt !== null && totalMs !== null
        ? sentAt + totalMs
        : completedCandidates.length > 0
          ? Math.max(...completedCandidates)
          : null

    const toolSteps = genSteps.filter((s) => s.toolName !== null)
    const seen: { kind: RequestActionKind; label: string; tool?: string }[] = []
    if (gen.thinking !== null && gen.thinking > 0) {
      seen.push({ kind: 'thinking', label: 'Thinking' })
    }
    for (const s of toolSteps) {
      const name = s.toolName!
      seen.push({ kind: toolActionKind(name), label: name, tool: name })
    }
    if (toolSteps.length === 0 && (gen.response === null || gen.response > 0)) {
      seen.push({ kind: 'reply', label: 'Reply' })
    }

    const params: RequestParam[] = []
    if (gen.modelLabel && gen.modelLabel !== gen.model) {
      params.push({ name: 'variant', value: gen.modelLabel })
    }
    if (gen.ttftMs !== null) params.push({ name: 'ttft', value: formatMs(gen.ttftMs) })
    if (gen.genMs !== null) params.push({ name: 'generation', value: formatMs(gen.genMs) })

    const received: RequestPart[] = []
    if (gen.thinking !== null && gen.thinking > 0) {
      received.push({
        kind: 'thinking',
        label: 'thinking',
        preview: `${gen.thinking} tokens`,
        bytes: null,
      })
    }
    for (const s of toolSteps) {
      received.push({
        kind: 'tool-call',
        label: s.toolName!,
        preview: s.toolArgsPreview ?? '',
        bytes: null,
      })
    }
    if (gen.response !== null && gen.response > 0) {
      received.push({
        kind: 'text',
        label: 'response',
        preview: `${gen.response} tokens`,
        bytes: null,
      })
    }

    const startsNewTurn =
      !currentTurn ||
      (!prevHadTools &&
        (prevEndedAt === null || sentAt === null || sentAt - prevEndedAt >= NEW_TURN_GAP_MS)) ||
      (!prevHadTools && toolSteps.length === 0)

    if (startsNewTurn) {
      currentTurn = {
        id: `agy-turn-${gen.idx}`,
        index: null,
        prompt: '',
        startedAt: sentAt,
        requests: [],
      }
      turns.push(currentTurn)
    }

    const request: ModelRequest = {
      id: gen.callId ?? `gen-${gen.idx}`,
      turnId: currentTurn!.id,
      sentAt,
      endedAt,
      model: gen.model,
      params,
      requestId: gen.callId,
      stop: null,
      tokens: requestTokens(gen),
      actions: summarizeActions(seen),
      sent: [],
      received,
      kept: null,
      added: null,
      status: 'done',
      error: null,
      records: 1 + genSteps.length,
      raw: `${RAW_PREFIX}${gen.idx}`,
    }
    currentTurn!.requests.push(request)
    prevHadTools = toolSteps.length > 0
    prevEndedAt = endedAt ?? sentAt
  }

  return turns
}

function conversationsDir(home: string): string {
  return path.join(home, '.gemini', 'antigravity-cli', 'conversations')
}

export interface AntigravityRequestsOptions {
  home: string
  /** Used when a session has no local conversation database yet. */
  fallback?: ModelRequestsReader
}

/** Persistent Requests pane reader for `antigravity`, backed by agy's local SQLite files. */
export function antigravityModelRequests(options: AntigravityRequestsOptions): ModelRequestsReader {
  const folder = conversationsDir(options.home)

  const fileFor = (target: RequestsTarget): string | null =>
    agyConversationFile(target.acpSessionId, folder)

  return {
    async page(target, before) {
      let cursor: number | null = null
      if (before !== null) {
        if (!/^\d+$/.test(before)) throw new Error('Invalid page cursor')
        cursor = Number(before)
      }
      const file = fileFor(target)
      if (!file) return (await options.fallback?.page(target, before)) ?? null
      const loaded = await agyReadRequestsPage(file, cursor, REQUESTS_PAGE)
      if (!loaded || !loaded.hasTable) {
        return (await options.fallback?.page(target, before)) ?? null
      }
      if (loaded.rows.length === 0 && cursor === null) {
        return (await options.fallback?.page(target, before)) ?? null
      }
      const hasMore = loaded.rows.length > REQUESTS_PAGE
      const slice = (hasMore ? loaded.rows.slice(0, REQUESTS_PAGE) : loaded.rows).reverse()
      const generations: AgyGeneration[] = []
      for (const row of slice) {
        const parsed = parseAgyGeneration(row.idx, row.data)
        if (parsed) generations.push(parsed)
      }
      const steps = loaded.steps.map((row) => parseAgyStep(row.idx, row.metadata))
      const oldestIdx = generations[0]?.idx ?? null
      return {
        source: 'antigravity',
        turns: buildAgyTurns(generations, steps),
        before: hasMore && oldestIdx !== null ? String(oldestIdx) : null,
      }
    },

    async summary(target): Promise<ModelRequestsOverview | null> {
      const file = fileFor(target)
      if (!file) return (await options.fallback?.summary(target)) ?? null
      const overview = await agyReadRequestsSummary(file)
      if (!overview || !overview.hasTable || overview.count === 0) {
        return (await options.fallback?.summary(target)) ?? null
      }
      return {
        source: 'antigravity',
        requests: overview.count,
        costUsd: null,
        tokens: overview.tokens
          ? {
              input: overview.tokens.input,
              cacheRead: overview.tokens.cacheRead,
              cacheWrite: 0,
              cacheWrite1h: null,
              output: overview.tokens.output,
              reasoning: overview.tokens.reasoning,
            }
          : null,
        system: null,
        turns: null,
      }
    },

    async raw(target, raw, full) {
      if (!raw.startsWith(RAW_PREFIX)) {
        if (options.fallback) return options.fallback.raw(target, raw, full)
        throw new Error(t('modelRequest.noRecord'))
      }
      const idxText = raw.slice(RAW_PREFIX.length)
      if (!/^\d+$/.test(idxText)) throw new Error('Not a request of this session')
      const idx = Number(idxText)
      const file = fileFor(target)
      if (!file) throw new Error(t('modelRequest.noSessionFile'))
      const record = await agyReadRequestRaw(file, idx)
      if (!record || !record.hasTable) throw new Error(t('modelRequest.noSessionFile'))
      const parsed = record.row ? parseAgyGeneration(idx, record.row.data) : null
      if (!parsed) throw new Error(t('modelRequest.noRecord'))
      const steps = record.steps
        .map((row) => parseAgyStep(row.idx, row.metadata))
        .filter(
          (step) =>
            step.genIdx === idx || (parsed.callId !== null && step.callId === parsed.callId),
        )
      return foldAll(
        [
          {
            type: 'gen_metadata',
            idx: parsed.idx,
            callId: parsed.callId,
            model: parsed.model,
            modelLabel: parsed.modelLabel,
            usage: {
              input: parsed.input,
              cacheRead: parsed.cacheRead,
              output: parsed.output,
              thinking: parsed.thinking,
              response: parsed.response,
            },
            timingMs: {
              ttft: parsed.ttftMs !== null ? Math.round(parsed.ttftMs) : null,
              generation: parsed.genMs !== null ? Math.round(parsed.genMs) : null,
            },
          },
          ...steps.map((step) => ({
            type: 'step',
            idx: step.idx,
            createdAt: step.createdAt,
            completedAt: step.completedAt,
            toolName: step.toolName,
            toolArgsPreview: step.toolArgsPreview,
            callId: step.callId,
          })),
        ],
        full,
      )
    },
  }
}
