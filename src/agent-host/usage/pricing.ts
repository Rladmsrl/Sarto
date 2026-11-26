// The prices usage is valued at, resolved per model name the way Sarto's Mac app does
// (UsageIslandKit's Pricing.swift), from these tables in order:
//
// 1. the user's own file, `<data>/model-prices.json`, in the Mac app's shape
//    `{"models": {"gemini-4-carbon": {"in": 2, "out": 12, "cr": 0.2, "cw": 2}}}` (dollars per
//    million tokens)
// 2. the Sarto server's daily LiteLLM snapshot, `<data>/state/prices-server.json`, when it is
//    valid and no older than the bundled one
// 3. the LiteLLM snapshot bundled with the build (prices.json)
// 4. the Mac app's bundled table (registry-prices.json)
//
// A name none of them has takes the price of its nearest sibling version of the same family and
// major version, as the app's `familySibling`.
//
// registry-prices.json is a copy of the Mac app's Resources/model-prices.json, prices from
// models.dev (https://github.com/sst/models.dev, MIT) and Cindy's offline model registry
// (https://github.com/makecindy/cindy, packages/model-providers/catalog/model-registry.json,
// Apache-2.0).

import { isPriceSnapshot, type ModelPrices, type PriceSnapshot } from '@shared/usage-prices'
import type { PriceMatch, PriceOrigin } from '@shared/usage'
import bundled from './prices.json'
import registry from './registry-prices.json'

export const BUNDLED_PRICES: PriceSnapshot = bundled

/** A model's resolved price and where it came from. */
export interface ResolvedPrice {
  prices: ModelPrices
  match: PriceMatch
}

const CONTEXT = /\s*\[[^\]]*\]$/
const SLASH_EFFORT = /\/(minimal|low|medium|high|xhigh|max|none)$/
const BEDROCK_VERSION = /-v\d+:\d+$/
const VERTEX_DATE = /@(\d{8}|default)$/
const DATE_SUFFIX = /-(\d{4}|\d{8}|\d{4}-\d{2}-\d{2})$/
const CHANNEL = /-(pro|lab|preview|latest|exp|beta)$/
const VERSION = /\d+(?:[.-]\d+)*/g
const PROXIES = ['umans-', 'openrouter-', 'bedrock-', 'vertex-']
const BEDROCK = [
  'global.',
  'us-gov.',
  'us.',
  'eu.',
  'apac.',
  'ap.',
  'anthropic.',
  'amazon.',
  'meta.',
  'mistral.',
  'deepseek.',
  'cohere.',
]
const DASH_EFFORTS = [
  '-low',
  '-medium',
  '-high',
  '-xhigh',
  '-max',
  '-minimal',
  '-thinking',
  '-fast',
]

/** Removes a pattern's first match, unless it starts the name, as the app's `stripMatch`. */
function strip(pattern: RegExp, text: string): string {
  const match = pattern.exec(text)
  return match && match.index > 0
    ? text.slice(0, match.index) + text.slice(match.index + match[0].length)
    : text
}

function stripSlashEffort(text: string): string {
  const match = SLASH_EFFORT.exec(text)
  return match && match.index > 0 ? text.slice(0, match.index) : text
}

function stripPrefixes(text: string): string {
  let out = text
  for (let changed = true; changed;) {
    changed = false
    for (const prefix of BEDROCK) {
      if (out.startsWith(prefix) && out.length > prefix.length) {
        out = out.slice(prefix.length)
        changed = true
      }
    }
  }
  return out
}

function stripEfforts(text: string): string {
  let out = text
  for (let changed = true; changed;) {
    changed = false
    for (const suffix of DASH_EFFORTS) {
      if (out.endsWith(suffix) && out.length > suffix.length) {
        out = out.slice(0, -suffix.length)
        changed = true
      }
    }
  }
  return out
}

function stripProxies(text: string): string {
  let out = text
  for (const prefix of PROXIES) if (out.startsWith(prefix)) out = out.slice(prefix.length)
  return out
}

/**
 * One name per model across providers and wrappers, as the app's `ModelPricing.normalize`: no
 * context tag, effort, provider prefix, proxy, Bedrock or Vertex wrapper, dash effort or date.
 */
export function canonicalModel(raw: string): string {
  let name = raw.trim().toLowerCase()
  if (!name) return ''
  name = strip(CONTEXT, name)
  name = stripSlashEffort(name)
  name = strip(CONTEXT, name)
  if (name.includes('/')) name = name.slice(name.lastIndexOf('/') + 1)
  name = stripProxies(name)
  name = stripPrefixes(name)
  name = strip(BEDROCK_VERSION, name)
  name = strip(VERTEX_DATE, name)
  name = stripEfforts(name)
  name = strip(DATE_SUFFIX, name)
  return stripEfforts(name)
}

/**
 * The names a price is looked up by, most exact first, as the app's `ModelPricing.candidates`:
 * the name, then without its context tag, effort, provider, wrappers, date and stacked channel
 * suffixes such as `-pro-lab`.
 */
export function priceCandidates(raw: string): string[] {
  const out: string[] = []
  const add = (name: string): void => {
    if (name && !out.includes(name)) out.push(name)
  }
  let name = raw.trim().toLowerCase()
  if (!name) return out
  add(name)
  for (const step of [
    (s: string) => strip(CONTEXT, s),
    stripSlashEffort,
    (s: string) => strip(CONTEXT, s),
    (s: string) => (s.includes('/') ? s.slice(s.lastIndexOf('/') + 1) : s),
  ]) {
    name = step(name)
    add(name)
  }
  for (const prefix of PROXIES) {
    if (name.startsWith(prefix)) {
      name = name.slice(prefix.length)
      add(name)
    }
  }
  for (const step of [
    stripPrefixes,
    (s: string) => strip(BEDROCK_VERSION, s),
    (s: string) => strip(VERTEX_DATE, s),
    stripEfforts,
    (s: string) => strip(DATE_SUFFIX, s),
    stripEfforts,
  ]) {
    name = step(name)
    add(name)
  }
  for (;;) {
    const peeled = strip(CHANNEL, name)
    if (peeled === name || !peeled) break
    name = peeled
    add(name)
  }
  return out
}

/** A name's family (its last version number as `#`) and that version, as the app's `shape`. */
export function modelShape(name: string): { family: string; version: number[] } | null {
  const dated = strip(DATE_SUFFIX, name)
  const target = [...dated.matchAll(VERSION)].length > 0 ? dated : name
  const match = [...target.matchAll(VERSION)].at(-1)
  if (!match) return null
  const version = match[0]
    .split(/[.-]/)
    .map(Number)
    .filter((n) => Number.isInteger(n))
  if (version.length === 0) return null
  const family = target.slice(0, match.index) + '#' + target.slice(match.index + match[0].length)
  return { family, version }
}

/** A table in the Mac app's shape, in dollars per million tokens, as dollars per token. */
export function parseAppPrices(value: unknown): Map<string, ModelPrices> {
  const out = new Map<string, ModelPrices>()
  const models =
    typeof value === 'object' && value !== null ? (value as { models?: unknown }).models : null
  if (typeof models !== 'object' || models === null || Array.isArray(models)) return out
  const amount = (v: unknown): number | null =>
    typeof v === 'number' && Number.isFinite(v) && v >= 0 && v < 1e6 ? v : null
  for (const [key, raw] of Object.entries(models)) {
    if (!key || key.length > 200 || typeof raw !== 'object' || raw === null) continue
    const entry = raw as Record<string, unknown>
    const input = amount(entry.in)
    const output = amount(entry.out)
    const cacheRead = amount(entry.cr)
    const cacheWrite = amount(entry.cw)
    if (input === null || output === null || cacheRead === null || cacheWrite === null) continue
    out.set(key.trim().toLowerCase(), {
      input: input / 1e6,
      output: output / 1e6,
      cacheRead: cacheRead / 1e6,
      cacheWrite: cacheWrite / 1e6,
      // The app bills an hour's cache writes at twice the input price.
      cacheWrite1h: (input * 2) / 1e6,
    })
  }
  return out
}

interface Table {
  origin: PriceOrigin
  models: ReadonlyMap<string, ModelPrices>
}

interface FamilyEntry {
  key: string
  origin: PriceOrigin
  prices: ModelPrices
  family: string
  version: number[]
}

const REGISTRY = parseAppPrices(registry)
const BUNDLED = new Map(Object.entries(BUNDLED_PRICES.models))

/** Resolves model names to prices; a table changing bumps `version` and empties the cache. */
export class Pricing {
  private override: ReadonlyMap<string, ModelPrices> = new Map()
  private server: PriceSnapshot | null = null
  private tables: Table[] = []
  private families: FamilyEntry[] = []
  private readonly cache = new Map<string, ResolvedPrice | null>()
  private readonly bundled: ReadonlyMap<string, ModelPrices>
  /** Bumped whenever a table changes, so stored resolutions are made again. */
  version = 0

  /** `bundled: false` leaves the bundled LiteLLM snapshot out, as the Mac app prices. */
  constructor(options: { bundled?: boolean } = {}) {
    this.bundled = options.bundled === false ? new Map() : BUNDLED
    this.rebuild()
  }

  /** The date of the LiteLLM snapshot in use. */
  get asOf(): string {
    return this.server?.asOf ?? BUNDLED_PRICES.asOf
  }

  /** The user's own prices, in the Mac app's shape; null or an unreadable file for none. */
  setOverride(value: unknown): void {
    this.override = parseAppPrices(value)
    this.rebuild()
  }

  /**
   * The server's snapshot; one that is not valid, or older than the bundled snapshot, is not
   * used. Returns whether it is used.
   */
  setServer(value: unknown): boolean {
    const usable = isPriceSnapshot(value) && value.asOf >= BUNDLED_PRICES.asOf
    this.server = usable ? value : null
    this.rebuild()
    return usable
  }

  private rebuild(): void {
    this.tables = [
      { origin: 'override', models: this.override },
      ...(this.server
        ? [{ origin: 'server' as const, models: new Map(Object.entries(this.server.models)) }]
        : []),
      { origin: 'bundled', models: this.bundled },
      { origin: 'registry', models: REGISTRY },
    ]
    // Each name once, from the first table that has it; a dated name whose undated twin is
    // priced, and a provider-prefixed one, is no family's member.
    const merged = new Map<string, { origin: PriceOrigin; prices: ModelPrices }>()
    for (const table of this.tables) {
      for (const [key, prices] of table.models) {
        if (!merged.has(key)) merged.set(key, { origin: table.origin, prices })
      }
    }
    const families: FamilyEntry[] = []
    for (const [key, { origin, prices }] of merged) {
      if (key.includes('/')) continue
      const dated = strip(DATE_SUFFIX, key)
      if (dated !== key && merged.has(dated)) continue
      const shape = modelShape(key)
      if (shape) families.push({ key, origin, prices, ...shape })
    }
    // Sorted, so ties between equally near versions always fall the same way.
    families.sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0))
    this.families = families
    this.cache.clear()
    this.version++
  }

  /** A model's price, or null when no table has it or a sibling of it. */
  resolve(model: string): ResolvedPrice | null {
    const key = model.trim().toLowerCase()
    const known = this.cache.get(key)
    if (known !== undefined) return known
    const resolved = this.lookUp(key)
    this.cache.set(key, resolved)
    return resolved
  }

  /** How a model is priced: its own name, a sibling's, or not at all. */
  match(model: string): PriceMatch {
    return this.resolve(model)?.match ?? { kind: 'unpriced', model: null, origin: null }
  }

  private lookUp(key: string): ResolvedPrice | null {
    const names = priceCandidates(key)
    for (const table of this.tables) {
      for (const name of names) {
        const prices = table.models.get(name)
        if (prices) return { prices, match: { kind: 'exact', model: name, origin: table.origin } }
      }
    }
    for (const name of names) {
      const sibling = this.sibling(name)
      if (sibling) {
        return {
          prices: sibling.prices,
          match: { kind: 'family', model: sibling.key, origin: sibling.origin },
        }
      }
    }
    return null
  }

  /** The nearest version of the same family and major version; never a 6.x for a 5.x. */
  private sibling(name: string): FamilyEntry | null {
    const target = modelShape(name)
    if (!target) return null
    let best: { entry: FamilyEntry; distance: number } | null = null
    for (const entry of this.families) {
      if (entry.family !== target.family || entry.version[0] !== target.version[0]) continue
      let distance = 0
      for (let i = 0; i < Math.max(entry.version.length, target.version.length); i++) {
        distance += Math.abs((entry.version[i] ?? 0) - (target.version[i] ?? 0)) / 100 ** i
      }
      if (!best || distance < best.distance) best = { entry, distance }
    }
    return best?.entry ?? null
  }
}
