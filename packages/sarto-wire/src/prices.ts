// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Zhengru
//
// The daily price snapshot (PROTOCOL.md section 3): its shape, its validation and the cut a server
// makes from LiteLLM's model list.

import { isObject } from './codec'

export const LITELLM_PRICES_URL =
  'https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json'

/** Dollars per token. */
export interface ModelPrices {
  input: number
  output: number
  cacheRead: number
  cacheWrite: number
  cacheWrite1h?: number
}

export interface PriceSnapshot {
  asOf: string
  models: Record<string, ModelPrices>
}

export const MIN_SNAPSHOT_MODELS = 100
export const MAX_SNAPSHOT_MODELS = 20_000
const MAX_MODEL_KEY = 200

const EFFORT_SUFFIXES: ReadonlySet<string> = new Set([
  'minimal',
  'low',
  'medium',
  'high',
  'xhigh',
  'max',
  'none',
])

/** The snapshot key of a LiteLLM entry name; '' when nothing is left. */
export function priceKey(name: string): string {
  const lowered = name
    .trim()
    .toLowerCase()
    .replace(/\[[^\]]*\]$/, '')
  const parts = lowered.split('/').filter((part) => part !== '')
  if (parts.length > 1 && EFFORT_SUFFIXES.has(parts.at(-1)!)) parts.length -= 1
  const last = parts.at(-1) ?? ''
  return last.replace(/-\d{8}$/, '').replace(/-\d{4}-\d{2}-\d{2}$/, '')
}

const finiteOrZero = (value: unknown): number =>
  typeof value === 'number' && Number.isFinite(value) ? value : 0

interface Candidate {
  name: string
  hasProvider: boolean
  prices: ModelPrices
}

/** Whether `next` should replace `current` for the same key. */
function prefer(next: Candidate, current: Candidate): boolean {
  if (next.hasProvider !== current.hasProvider) return !next.hasProvider
  return next.name < current.name
}

/** Cuts LiteLLM's model list into a snapshot dated `asOf`. */
export function cutPriceSnapshot(list: unknown, asOf: string): PriceSnapshot {
  const best = new Map<string, Candidate>()
  if (isObject(list)) {
    for (const name of Object.keys(list)) {
      const entry = list[name]
      if (!isObject(entry) || entry.mode !== 'chat') continue
      const input = entry.input_cost_per_token
      const output = entry.output_cost_per_token
      if (typeof input !== 'number' || typeof output !== 'number') continue
      const key = priceKey(name)
      if (key === '') continue
      const prices: ModelPrices = {
        input,
        output,
        cacheRead: finiteOrZero(entry.cache_read_input_token_cost),
        cacheWrite: finiteOrZero(entry.cache_creation_input_token_cost),
      }
      const longCache = entry.cache_creation_input_token_cost_above_1hr
      if (typeof longCache === 'number' && Number.isFinite(longCache)) {
        prices.cacheWrite1h = longCache
      }
      const candidate: Candidate = { name, hasProvider: name.includes('/'), prices }
      const current = best.get(key)
      if (!current || prefer(candidate, current)) best.set(key, candidate)
    }
  }
  const models: Record<string, ModelPrices> = {}
  for (const key of [...best.keys()].sort()) models[key] = best.get(key)!.prices
  return { asOf, models }
}

const isTokenPrice = (value: unknown): value is number =>
  typeof value === 'number' && Number.isFinite(value) && value >= 0 && value < 1

function isModelPrices(value: unknown): value is ModelPrices {
  if (!isObject(value)) return false
  const { input, output, cacheRead, cacheWrite, cacheWrite1h } = value
  return (
    [input, output, cacheRead, cacheWrite].every(isTokenPrice) &&
    (cacheWrite1h === undefined || isTokenPrice(cacheWrite1h))
  )
}

export function isPriceSnapshot(value: unknown): value is PriceSnapshot {
  if (!isObject(value)) return false
  if (typeof value.asOf !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value.asOf)) return false
  if (!isObject(value.models)) return false
  const keys = Object.keys(value.models)
  if (keys.length < MIN_SNAPSHOT_MODELS || keys.length > MAX_SNAPSHOT_MODELS) return false
  const models = value.models
  return keys.every(
    (key) => key !== '' && key.length <= MAX_MODEL_KEY && isModelPrices(models[key]),
  )
}
