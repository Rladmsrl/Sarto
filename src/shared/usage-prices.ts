// The API list prices usage is valued at, as one snapshot of LiteLLM's model list: the Sarto
// server cuts a fresh one every day and daemons fetch it, so a running daemon prices new models
// without waiting for a release. The cut is tools/usage/update-prices.mjs's, which makes the
// snapshot bundled with each build, so both have the same shape.

/** LiteLLM's model list, which the server fetches once a day. */
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
  /** The day the list was taken, as YYYY-MM-DD. */
  asOf: string
  /** Keyed by `normalizePriceModel`. */
  models: Record<string, ModelPrices>
}

/** More than any real list holds; a larger one is refused rather than kept. */
const MAX_MODELS = 20_000
/** Fewer than a usable list holds; a smaller one is taken for a broken fetch. */
export const MIN_MODELS = 100

const EFFORTS = new Set(['minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'none'])

/** The usage reader's model key: lowercase, no provider prefix, effort suffix or date. */
export function normalizePriceModel(name: string | null | undefined): string {
  let model = (name ?? '').trim().toLowerCase()
  model = model.replace(/\[[^\]]*\]$/, '')
  const parts = model.split('/').filter(Boolean)
  if (parts.length > 1 && EFFORTS.has(parts[parts.length - 1]!)) parts.pop()
  model = parts[parts.length - 1] ?? ''
  return model.replace(/-\d{8}$/, '').replace(/-\d{4}-\d{2}-\d{2}$/, '')
}

const price = (value: unknown): number =>
  typeof value === 'number' && Number.isFinite(value) ? value : 0

/**
 * The chat models of LiteLLM's list that carry an input and an output price, keyed by
 * `normalizePriceModel`: an unprefixed name wins over a provider-prefixed one, and so does the
 * first alphabetically among names of the same kind, so the same list always cuts the same way.
 */
export function cutPrices(source: unknown, asOf: string): PriceSnapshot {
  const cut = new Map<string, { name: string; prefixed: boolean; prices: ModelPrices }>()
  const entries = typeof source === 'object' && source !== null ? Object.entries(source) : []
  for (const [name, raw] of entries) {
    const entry = typeof raw === 'object' && raw !== null ? (raw as Record<string, unknown>) : null
    if (entry?.mode !== 'chat') continue
    const input = entry.input_cost_per_token
    const output = entry.output_cost_per_token
    if (typeof input !== 'number' || typeof output !== 'number') continue
    const key = normalizePriceModel(name)
    if (!key) continue
    const prefixed = name.includes('/')
    const known = cut.get(key)
    if (known) {
      const wins = known.prefixed === prefixed ? known.name <= name : !known.prefixed
      if (wins) continue
    }
    const prices: ModelPrices = {
      input,
      output,
      cacheRead: price(entry.cache_read_input_token_cost),
      cacheWrite: price(entry.cache_creation_input_token_cost),
    }
    const hour = entry.cache_creation_input_token_cost_above_1hr
    if (typeof hour === 'number' && Number.isFinite(hour)) prices.cacheWrite1h = hour
    cut.set(key, { name, prefixed, prices })
  }
  const models: Record<string, ModelPrices> = {}
  for (const key of [...cut.keys()].sort()) models[key] = cut.get(key)!.prices
  return { asOf, models }
}

const isPrice = (value: unknown): value is number =>
  typeof value === 'number' && Number.isFinite(value) && value >= 0 && value < 1

/** A snapshot as a server or a file hands it over, checked field by field before it is used. */
export function isPriceSnapshot(value: unknown): value is PriceSnapshot {
  if (typeof value !== 'object' || value === null) return false
  const { asOf, models } = value as { asOf?: unknown; models?: unknown }
  if (typeof asOf !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(asOf)) return false
  if (typeof models !== 'object' || models === null || Array.isArray(models)) return false
  const entries = Object.entries(models)
  if (entries.length < MIN_MODELS || entries.length > MAX_MODELS) return false
  return entries.every(([key, raw]) => {
    if (!key || key.length > 200 || typeof raw !== 'object' || raw === null) return false
    const p = raw as Record<string, unknown>
    return (
      isPrice(p.input) &&
      isPrice(p.output) &&
      isPrice(p.cacheRead) &&
      isPrice(p.cacheWrite) &&
      (p.cacheWrite1h === undefined || isPrice(p.cacheWrite1h))
    )
  })
}
