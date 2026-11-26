// Burn-rate forecasts of quota windows, ported from Sarto's Mac app (UsageIslandKit's
// Forecast.swift, `QuotaForecaster` and `ProviderScope`) so both give the same numbers. A window's
// forecast blends three rates, from the window's average, its recent measurements and the tokens
// spent lately, and counts only the usage of the computers signed in to its account, of the models
// that draw on it.

import { harnessOf } from '@shared/agents'
import type { AgentId } from '@shared/thread'
import type { QuotaSample, QuotaWindow, WindowForecast } from '@shared/usage'
import { canonicalModel } from './pricing'
import { HISTORY_MS, sameCycle } from './quota'

/** One quarter hour (or legacy hour) of one model's tokens. */
export interface LedgerBucket {
  /** ms since the epoch. */
  start: number
  /** ms. */
  duration: number
  total: number
  model: string
}

const HOUR = 3600
const FILLER = new Set(['claude', 'anthropic', 'model', 'models', 'only', 'weekly', 'session'])
const PARTS = /[^\p{L}\p{N}]+/u

const parts = (text: string): string[] => text.split(PARTS).filter(Boolean)

/** Antigravity's third-party pool: Claude, GPT and OpenAI's o-series models. */
export function isAntigravityThirdParty(model: string): boolean {
  const normalized = canonicalModel(model)
  const target = normalized || model.toLowerCase()
  if (/claude|gpt|sonnet|opus|haiku|fable|mythos/.test(target)) return true
  return target.split(/[-/_. ]/).some((token) => token === 'o1' || token === 'o3' || token === 'o4')
}

/**
 * Whether a model's usage draws on a window, as the app's `ProviderScope.matches`: a Claude Code
 * window scoped to some models takes theirs only, Antigravity's groups take their pool's, and
 * any other window takes every model.
 */
export function drawsOn(agentId: AgentId, window: QuotaWindow, model: string): boolean {
  const canonical = canonicalModel(model) || model.toLowerCase()
  switch (harnessOf(agentId)) {
    case 'claude-code': {
      if (window.kind !== 'scoped') return true
      const scope = (window.scope ?? '').trim().toLowerCase()
      if (!scope || canonical.includes(scope)) return true
      const scopeParts = parts(scope)
      const distinctive = scopeParts.filter((part) => !FILLER.has(part))
      const required = distinctive.length > 0 ? distinctive : scopeParts
      if (required.length === 0) return true
      // Claude Code's `opusplan` alias runs Opus and Sonnet.
      const expanded = canonical === 'opusplan' ? 'claude-opus-sonnet' : canonical
      const modelParts = new Set(parts(expanded))
      const hasDigits = /\p{N}/u.test(expanded)
      return required.every(
        (token) =>
          // A bare alias such as `opus` matches a scope that names a version.
          (!hasDigits && /^\p{N}+$/u.test(token)) ||
          modelParts.has(token) ||
          expanded.includes(token),
      )
    }
    case 'antigravity': {
      const thirdParty = isAntigravityThirdParty(canonical)
      const argon = canonical.includes('argon')
      const scope = window.scope ?? ''
      if (/claude|gpt/i.test(scope)) return thirdParty
      if (/argon/i.test(scope)) return argon
      return !thirdParty && !argon
    }
    default:
      return true
  }
}

/**
 * A window's length in ms: as measured, else by its kind (a session is 5 hours, a weekly or a
 * scoped one a week, as the app takes them); null when neither says.
 */
export function windowLength(window: QuotaWindow): number | null {
  const minutes =
    window.minutes ??
    (window.kind === 'session'
      ? 300
      : window.kind === 'weekly' || window.kind === 'scoped'
        ? 7 * 24 * 60
        : null)
  return minutes === null ? null : minutes * 60_000
}

/**
 * Tokens in [start, end], each bucket prorated by its overlap, the current one against the time
 * it has run so far, as the app's `spanTotal` (in seconds, as there).
 */
export function spanTotal(
  buckets: readonly LedgerBucket[],
  start: number,
  end: number,
  now: number,
): number {
  if (end <= start) return 0
  const startSec = start / 1000
  const endSec = end / 1000
  const nowSec = now / 1000
  let total = 0
  for (const bucket of buckets) {
    const from = bucket.start / 1000
    const nominalEnd = from + bucket.duration / 1000
    if (!(nominalEnd > startSec && from < endSec)) continue
    const current = nowSec >= from && nowSec < nominalEnd
    const observedEnd = current ? Math.max(from + 1, nowSec) : nominalEnd
    const overlap = Math.max(0, Math.min(endSec, observedEnd) - Math.max(startSec, from))
    total += bucket.total * Math.min(1, overlap / Math.max(1, observedEnd - from))
  }
  return total
}

/**
 * The measurements of one reset cycle from several computers' lists, oldest first, without a
 * repeat within a minute, as the app's `QuotaForecaster.merge`.
 */
export function mergeSamples(
  lists: readonly (readonly QuotaSample[])[],
  resetsAt: number | null,
  now: number,
): QuotaSample[] {
  const flat = lists
    .flat()
    .filter((s) => now - s.at <= HISTORY_MS && sameCycle(s.resetsAt, resetsAt))
    .sort((a, b) => a.at - b.at)
  const out: QuotaSample[] = []
  for (const sample of flat) {
    const previous = out.at(-1)
    if (
      previous &&
      Math.abs(sample.at - previous.at) < 60_000 &&
      Math.abs(sample.usedPercent - previous.usedPercent) < 0.05
    ) {
      continue
    }
    out.push(sample)
  }
  return out
}

export interface ForecastInput {
  agentId: AgentId
  window: QuotaWindow
  /** When the reading was measured: the newest of its windows. */
  observedAt: number | null
  /** The window's measurements of the account's computers, merged. */
  samples: readonly QuotaSample[]
  /** The agent's usage on the account's computers. */
  buckets: readonly LedgerBucket[]
  now: number
}

const clamp01 = (value: number): number => Math.max(0, Math.min(1, value))

/**
 * A window's forecast, as the app's `QuotaForecaster.forecast`: the tokens per 1% used are taken
 * when the quota was measured, and tokens spent since then count against what is left.
 */
export function forecastWindow(input: ForecastInput): WindowForecast {
  const { window, now } = input
  const resetsAt = window.resetsAt
  const length = windowLength(window)
  if (resetsAt !== null && resetsAt <= now) {
    return { status: { kind: 'reset' }, estimatedRemainingTokens: null, windowTokens: 0 }
  }
  if (resetsAt === null || length === null) {
    return { status: { kind: 'insufficient' }, estimatedRemainingTokens: null, windowTokens: 0 }
  }
  const timeToReset = (resetsAt - now) / 1000
  const start = resetsAt - length
  const draws = new Map<string, boolean>()
  const buckets = input.buckets.filter((bucket) => {
    let hit = draws.get(bucket.model)
    if (hit === undefined) {
      hit = drawsOn(input.agentId, window, bucket.model)
      draws.set(bucket.model, hit)
    }
    return hit
  })
  const observed =
    input.observedAt === null ? now : Math.min(now, Math.max(start, input.observedAt))
  const elapsedAtObserved = Math.max(0, (observed - start) / 1000)
  const elapsedNow = Math.max(0, (now - start) / 1000)
  const used = clamp01(window.usedPercent / 100)
  const remaining = clamp01(1 - window.usedPercent / 100)

  const tokensAtObserved = spanTotal(buckets, start, observed, now)
  const unmeasured = observed < now ? spanTotal(buckets, observed, now, now) : 0
  const windowTokens = tokensAtObserved + unmeasured

  const perUnit = used >= 0.01 && tokensAtObserved >= 10_000 ? tokensAtObserved / used : null
  const estimated = perUnit === null ? null : Math.max(0, perUnit * remaining - unmeasured)
  const effective =
    perUnit !== null && perUnit > 0 ? Math.max(0, remaining - unmeasured / perUnit) : remaining
  const verdict = (status: WindowForecast['status']): WindowForecast => ({
    status,
    estimatedRemainingTokens: estimated,
    windowTokens,
  })

  if (effective <= 0.001) {
    return { status: { kind: 'exhausts', seconds: 0 }, estimatedRemainingTokens: 0, windowTokens }
  }
  if (used < 0.015 && unmeasured < 50_000) return verdict({ kind: 'steady' })

  const short = length <= 6 * HOUR * 1000
  // The window's average rate up to the measurement, a share per second.
  const byWindow = elapsedAtObserved >= 600 && used >= 0.015 ? used / elapsedAtObserved : null

  // The measurements' recent rate: over 2 hours of a short window, 24 of a long one.
  const cycle = input.samples
    .filter((s) => sameCycle(s.resetsAt, resetsAt))
    .sort((a, b) => a.at - b.at)
  let byHistory: number | null = null
  const latest = cycle.at(-1)
  if (latest) {
    const cutoff = latest.at - (short ? 2 : 24) * HOUR * 1000
    const anchor = cycle.find((s) => s.at >= cutoff) ?? cycle[0]
    if (anchor) {
      const dt = (latest.at - anchor.at) / 1000
      const du = (latest.usedPercent - anchor.usedPercent) / 100
      if (dt >= 900 && du >= 0.005) byHistory = du / dt
      else if (dt >= 1800 && du <= 0.001) byHistory = 0
    }
  }

  // The tokens' recent rate, which covers the lag before another computer measures again.
  let byTokens: number | null = null
  if (perUnit !== null && tokensAtObserved >= 50_000 && used >= 0.02) {
    const span = Math.min(elapsedNow, (short ? 2 : 12) * HOUR)
    if (span >= 600) {
      const recent = spanTotal(buckets, now - span * 1000, now, now)
      byTokens = recent / span / perUnit
    }
  }

  const weighted: [number | null, number][] = short
    ? [
        [byHistory, 0.5],
        [byTokens, 0.3],
        [byWindow, 0.2],
      ]
    : [
        [byHistory, 0.4],
        [byTokens, 0.25],
        [byWindow, 0.35],
      ]
  let sumRate = 0
  let sumWeight = 0
  for (const [rate, weight] of weighted) {
    if (rate === null) continue
    sumRate += rate * weight
    sumWeight += weight
  }
  if (sumWeight <= 0) return verdict({ kind: 'steady' })
  const rate = sumRate / sumWeight
  if (rate <= 1e-9) return verdict({ kind: 'steady' })
  const toExhaust = effective / rate
  if (toExhaust < timeToReset) return verdict({ kind: 'exhausts', seconds: toExhaust })
  return verdict({ kind: 'survives', remainingAtReset: clamp01(effective - rate * timeToReset) })
}
