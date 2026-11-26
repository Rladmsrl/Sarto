// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Zhengru
//
// The idle game's contract between a Sarto daemon or app and the game service: the facts a daemon
// reports about its agents' work (numbers and opaque ids only, never content), the commands a
// player sends, the state and live battle events the service streams back, and their validation.
// Imports nothing so the server runs it directly under Node's type-stripping runtime.

export const GAME_PROTOCOL_VERSION = 1

export type WorkKind = 'think' | 'scan' | 'command' | 'edit'
export const WORK_KINDS: readonly WorkKind[] = ['think', 'scan', 'command', 'edit']

export type School = 'review' | 'search' | 'rewrite' | 'orchestrate'
export const SCHOOLS: readonly School[] = ['review', 'search', 'rewrite', 'orchestrate']

export type Material = 'log' | 'index' | 'patch' | 'pipeline'
export const MATERIALS: readonly Material[] = ['log', 'index', 'patch', 'pipeline']

export type Family = 'package' | 'prompt' | 'tool'
export const FAMILIES: readonly Family[] = ['package', 'prompt', 'tool']

export type Rarity = 'common' | 'rare' | 'legendary'

export interface TokenCounts {
  input: number
  output: number
  thought: number
  cacheRead: number
  cacheWrite: number
}

export interface FactBase {
  /** Unique per fact; a repeat counts once. */
  id: string
  /** ms since the epoch, UTC. */
  at: number
  /** Per device, increasing. */
  seq: number
  /** Random per session, meaningful only inside the account. */
  sessionRef: string
  harness: string
  /** Computed on the Mac; no time zone is sent. */
  nightLocal: boolean
}

export interface WorkInterval {
  start: number
  end: number
  state: 'work' | 'waiting'
}

export interface TurnFact extends FactBase {
  type: 'turn'
  ok: boolean
  intervals: WorkInterval[]
  workSeconds: Record<WorkKind, number>
  models: { model: string; tokens: TokenCounts }[]
}

export interface TodoFact extends FactBase {
  type: 'todo'
  planRef: string
  planVersion: number
  stepIndex: number
}

export type GameFact = TurnFact | TodoFact

export interface FactBatch {
  v: number
  batch: string
  daemonVersion: string
  facts: GameFact[]
}

export interface FactBatchResult {
  accepted: number
  duplicates: number
  rejected: { id: string; reason: string }[]
}

export type Actor = 'player' | 'agent'

export type PickPolicy =
  { kind: 'recommended' } | { kind: 'school'; value: School } | { kind: 'family'; value: Family }

export interface CommandBase {
  v: number
  actionId: string
  actor: Actor
  /** The state revision the client saw; a stale one is refused. Omit to skip the check. */
  expectedRevision?: number
}

export type Command = CommandBase &
  (
    | { type: 'equipMain'; args: { harness: string } }
    | { type: 'equipCard'; args: { cardId: string; slot: number } }
    | { type: 'unequipCard'; args: { slot: number } }
    | { type: 'merge'; args: { cardIds: string[] } }
    | { type: 'craftCard'; args: { school?: School } }
    | { type: 'challengeBoss'; args: Record<string, never> }
    | { type: 'castUlt'; args: Record<string, never> }
    | { type: 'setUltMode'; args: { manual: boolean } }
    | { type: 'pick'; args: { offerId: string; option: number } }
    | { type: 'setPolicy'; args: { policy: PickPolicy } }
    | { type: 'runStart'; args: { env: number } }
    | { type: 'runChoose'; args: { option: number } }
    | { type: 'runPick'; args: { option: number } }
    | { type: 'runBuy'; args: { item: number; perkId?: string } }
    | { type: 'runCoffee'; args: { action: 'payDebt' | 'espresso' | 'leave' } }
    | { type: 'runSkipFight'; args: Record<string, never> }
    | { type: 'runMemory'; args: { perkId: string | null } }
    | { type: 'runAbandon'; args: Record<string, never> }
    | { type: 'claim'; args: Record<string, never> }
    | { type: 'devAdvance'; args: { minutes: number } }
  )

export type CommandType = Command['type']

export type AccountState = 'active' | 'inactive' | 'offline'

export interface Card {
  id: string
  school: School
  tier: number
}

export interface PerkView {
  id: string
  name: string
  desc: string
  school: School
  family: Family
  rarity: Rarity
}

export interface OfferView {
  id: string
  at: number
  options: PerkView[]
  recommended: number
  /** When the policy decides if nobody picks. */
  autoAt: number
}

export interface SetView {
  key: School | Family
  axis: 'school' | 'family'
  name: string
  desc: string
  count: number
  active: boolean
}

export interface WeaponView {
  harness: string
  minutes: number
  todayMinutes: number
  level: number
  /** Minutes the current level takes, and how many of them remain. */
  levelMinutes: number
  nextLevelMinutes: number
}

export interface PowerBreakdown {
  base: number
  proficiency: number
  cards: number
  variety: number
  synergyMode?: 'variety' | 'specialization' | 'none'
  agents: number
  /** Base power with proficiency, cards, variety and agents. */
  total: number
  /** What the build is worth in battle, upgrades included; it decides which stages can be pushed. */
  effective: number
}

export interface StageView {
  chapter: number
  stage: number
  kills: number
  killsNeeded: number
  required: number
  stuck: boolean
  bossReady: boolean
  bossDefeated: boolean
}

export interface ReportView {
  from: number
  to: number
  xp: number
  compute: number
  bonusXp: number
  kills: number
  stagesCleared: number
  drops: string[]
  picks: string[]
  minutesByState: Record<AccountState, number>
}

export interface BattleView {
  monster: { name: string; hp: number; maxHp: number; elite: boolean; push: boolean } | null
  boss: { hp: number; maxHp: number; phase: string; startedAt: number; enrageAt: number } | null
  ult: number
  ultMax: number
  ultManual: boolean
}

export interface BossResult {
  won: boolean
  power: number
  required: number
  durationMs: number
  bossHp: number
  damageDealt: number
  perfect: number
  advice: string[]
}

export interface GameStateView {
  v: number
  revision: number
  serverNow: number
  hero: {
    name: string
    level: number
    version: string
    xp: number
    xpNext: number
    compute: number
  }
  account: {
    state: AccountState
    online: boolean
    lastActivityAt: number | null
    activeUntil: number | null
    offlineSince: number | null
    offlineCapAt: number | null
  }
  power: PowerBreakdown
  main: string | null
  slots: (Card | null)[]
  slotCount: number
  cards: Card[]
  materials: Record<Material, number>
  weapons: WeaponView[]
  stage: StageView
  perks: PerkView[]
  sets: SetView[]
  offers: OfferView[]
  policy: PickPolicy
  battle: BattleView
  lastBoss: BossResult | null
  hackathon: HackathonView
  today: { todoRewards: number; todoCap: number }
  craftCost?: { random: number; targeted: number }
  titles?: string[]
  watermark: number
  pendingReport: ReportView
  flagged: boolean
}

/** One thing that happened in a battle, at its game time. */
export type NodeKind = 'fight' | 'elite' | 'market' | 'coffee' | 'boss'

export interface CurseView {
  id: string
  name: string
  desc: string
}

export interface RunRewardView {
  id: string
  /** Upgrades to choose from; a cursed deal carries the curse it costs. */
  options: (PerkView & { curse?: CurseView })[]
  skipCredits: number
}

export interface MarketItemView {
  kind: 'perk' | 'remove'
  perk?: PerkView
  price: number
  sold: boolean
}

export interface RunResultView {
  won: boolean
  nodesCleared: number
  compute: number
  materials: Record<Material, number>
  card: Card | null
  dailyFactor: number
  curseBonus: number
  memoryChoices: PerkView[]
}

export interface RunView {
  env: number
  envName: string
  leg: number
  legs: number
  step: number
  steps: number
  status: 'choosing' | 'fighting' | 'reward' | 'market' | 'coffee' | 'ended'
  node: NodeKind | null
  paths: NodeKind[]
  credits: number
  perks: PerkView[]
  curses: CurseView[]
  sets: SetView[]
  power: number
  reward: RunRewardView | null
  market: MarketItemView[]
  espresso: boolean
  fight: { remaining: number; total: number; deadline: number; startedAt: number } | null
  boss: { hp: number; maxHp: number; phase: string; enrageAt: number; name: string } | null
  result: RunResultView | null
  startedAt: number
  expiresAt: number
}

export interface HackathonView {
  envs: { name: string; unlocked: boolean }[]
  runsToday: number
  fullRuns: number
  memory: PerkView | null
  run: RunView | null
}

export interface BattleEvent {
  at: number
  kind:
    | 'spawn'
    | 'hit'
    | 'tool'
    | 'double'
    | 'ult'
    | 'kill'
    | 'stageClear'
    | 'offer'
    | 'pick'
    | 'bossStart'
    | 'bossPhase'
    | 'bossEnd'
    | 'miss'
    | 'waveStart'
    | 'waveEnd'
  damage?: number
  crit?: boolean
  perfect?: boolean
  hp?: number
  maxHp?: number
  monster?: string
  elite?: boolean
  push?: boolean
  /** Which battle: the mainline or a Hackathon run. */
  lane?: 'main' | 'run'
  /** The ultimate's charge after this event. */
  ult?: number
  text?: string
  result?: BossResult
}

export type CommandResult =
  | { ok: true; state: GameStateView; report?: ReportView; note?: string }
  | { ok: false; error: string; state?: GameStateView }

/** Frames the server sends on the stream. */
export type ServerFrame =
  | { type: 'hello'; v: number; role: 'daemon' | 'viewer'; state: GameStateView }
  | { type: 'state'; state: GameStateView }
  | { type: 'battle'; events: BattleEvent[] }
  | { type: 'notice'; key: string; text: string }
  | { type: 'factsResult'; batch: string; result: FactBatchResult }
  | { type: 'commandResult'; actionId: string; result: CommandResult }
  | { type: 'error'; error: string }

/** Frames a client sends on the stream. */
export type ClientFrame =
  { type: 'facts'; batch: FactBatch } | { type: 'command'; command: Command } | { type: 'ping' }

const MAX_ID = 128
const MAX_HARNESS = 64
const MAX_MODEL = 200
const MAX_INTERVALS = 500
const MAX_MODELS = 32
const MAX_FACTS = 500

function isObj(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function isId(value: unknown, max = MAX_ID): value is string {
  return typeof value === 'string' && value.length > 0 && value.length <= max
}

function isCount(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0
}

function isTime(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value > 0
}

/** The fact's shape alone; the rules decide whether it counts. */
export function parseFact(raw: unknown): GameFact | string {
  if (!isObj(raw)) return 'not an object'
  const { id, at, seq, sessionRef, harness, nightLocal, type } = raw
  if (!isId(id)) return 'bad id'
  if (!isTime(at)) return 'bad at'
  if (!isCount(seq)) return 'bad seq'
  if (!isId(sessionRef)) return 'bad sessionRef'
  if (!isId(harness, MAX_HARNESS)) return 'bad harness'
  if (typeof nightLocal !== 'boolean') return 'bad nightLocal'
  const base = { id, at, seq, sessionRef, harness, nightLocal }
  if (type === 'todo') {
    const { planRef, planVersion, stepIndex } = raw
    if (!isId(planRef)) return 'bad planRef'
    if (!isCount(planVersion)) return 'bad planVersion'
    if (!isCount(stepIndex) || stepIndex > 10_000) return 'bad stepIndex'
    return { ...base, type, planRef, planVersion, stepIndex }
  }
  if (type !== 'turn') return 'bad type'
  const { ok, intervals, workSeconds, models } = raw
  if (typeof ok !== 'boolean') return 'bad ok'
  if (!Array.isArray(intervals) || intervals.length === 0 || intervals.length > MAX_INTERVALS) {
    return 'bad intervals'
  }
  const parsedIntervals: WorkInterval[] = []
  for (const item of intervals) {
    if (!isObj(item)) return 'bad interval'
    const { start, end, state } = item
    if (!isTime(start) || !isTime(end) || end <= start) return 'bad interval'
    if (state !== 'work' && state !== 'waiting') return 'bad interval state'
    parsedIntervals.push({ start, end, state })
  }
  if (!isObj(workSeconds)) return 'bad workSeconds'
  const parsedWork = {} as Record<WorkKind, number>
  for (const kind of WORK_KINDS) {
    const seconds = workSeconds[kind]
    if (!isCount(seconds)) return 'bad workSeconds'
    parsedWork[kind] = seconds
  }
  if (!Array.isArray(models) || models.length > MAX_MODELS) return 'bad models'
  const parsedModels: TurnFact['models'] = []
  for (const item of models) {
    if (!isObj(item) || !isId(item.model, MAX_MODEL) || !isObj(item.tokens)) return 'bad model'
    const t = item.tokens
    if (
      !isCount(t.input) ||
      !isCount(t.output) ||
      !isCount(t.thought) ||
      !isCount(t.cacheRead) ||
      !isCount(t.cacheWrite)
    ) {
      return 'bad tokens'
    }
    parsedModels.push({
      model: item.model,
      tokens: {
        input: t.input,
        output: t.output,
        thought: t.thought,
        cacheRead: t.cacheRead,
        cacheWrite: t.cacheWrite,
      },
    })
  }
  return {
    ...base,
    type,
    ok,
    intervals: parsedIntervals,
    workSeconds: parsedWork,
    models: parsedModels,
  }
}

export function parseBatch(raw: unknown): FactBatch | string {
  if (!isObj(raw)) return 'not an object'
  if (raw.v !== GAME_PROTOCOL_VERSION) return 'unsupported version'
  if (!isId(raw.batch)) return 'bad batch'
  if (!isId(raw.daemonVersion, 64)) return 'bad daemonVersion'
  if (!Array.isArray(raw.facts) || raw.facts.length > MAX_FACTS) return 'bad facts'
  return {
    v: raw.v,
    batch: raw.batch,
    daemonVersion: raw.daemonVersion,
    facts: raw.facts as GameFact[],
  }
}

export function parseCommand(raw: unknown): Command | string {
  if (!isObj(raw)) return 'not an object'
  if (raw.v !== GAME_PROTOCOL_VERSION) return 'unsupported version'
  if (!isId(raw.actionId)) return 'bad actionId'
  if (raw.actor !== 'player' && raw.actor !== 'agent') return 'bad actor'
  if (raw.expectedRevision !== undefined && !isCount(raw.expectedRevision)) {
    return 'bad expectedRevision'
  }
  const args = isObj(raw.args) ? raw.args : {}
  const base = {
    v: raw.v,
    actionId: raw.actionId,
    actor: raw.actor,
    ...(raw.expectedRevision === undefined ? {} : { expectedRevision: raw.expectedRevision }),
  } as CommandBase
  switch (raw.type) {
    case 'equipMain':
      if (!isId(args.harness, MAX_HARNESS)) return 'bad harness'
      return { ...base, type: 'equipMain', args: { harness: args.harness } }
    case 'equipCard':
      if (!isId(args.cardId) || !isCount(args.slot) || args.slot > 8) return 'bad args'
      return { ...base, type: 'equipCard', args: { cardId: args.cardId, slot: args.slot } }
    case 'unequipCard':
      if (!isCount(args.slot) || args.slot > 8) return 'bad args'
      return { ...base, type: 'unequipCard', args: { slot: args.slot } }
    case 'merge': {
      const ids = args.cardIds
      if (!Array.isArray(ids) || ids.length !== 3 || !ids.every((id) => isId(id))) {
        return 'bad cardIds'
      }
      return { ...base, type: 'merge', args: { cardIds: ids as string[] } }
    }
    case 'craftCard': {
      if (args.school !== undefined && !SCHOOLS.includes(args.school as School)) {
        return 'bad school'
      }
      return {
        ...base,
        type: 'craftCard',
        args: args.school === undefined ? {} : { school: args.school as School },
      }
    }
    case 'challengeBoss':
      return { ...base, type: 'challengeBoss', args: {} }
    case 'castUlt':
      return { ...base, type: 'castUlt', args: {} }
    case 'setUltMode':
      if (typeof args.manual !== 'boolean') return 'bad manual'
      return { ...base, type: 'setUltMode', args: { manual: args.manual } }
    case 'pick':
      if (!isId(args.offerId) || !isCount(args.option) || args.option > 8) return 'bad args'
      return { ...base, type: 'pick', args: { offerId: args.offerId, option: args.option } }
    case 'runStart':
      if (!isCount(args.env) || args.env > 8) return 'bad env'
      return { ...base, type: 'runStart', args: { env: args.env } }
    case 'runChoose':
    case 'runPick':
      if (!isCount(args.option) || args.option > 8) return 'bad option'
      return { ...base, type: raw.type, args: { option: args.option } }
    case 'runBuy':
      if (!isCount(args.item) || args.item > 8) return 'bad item'
      if (args.perkId !== undefined && !isId(args.perkId, 64)) return 'bad perkId'
      return {
        ...base,
        type: 'runBuy',
        args:
          args.perkId === undefined
            ? { item: args.item }
            : { item: args.item, perkId: args.perkId },
      }
    case 'runCoffee':
      if (args.action !== 'payDebt' && args.action !== 'espresso' && args.action !== 'leave') {
        return 'bad action'
      }
      return { ...base, type: 'runCoffee', args: { action: args.action } }
    case 'runSkipFight':
      return { ...base, type: 'runSkipFight', args: {} }
    case 'runMemory':
      if (args.perkId !== null && !isId(args.perkId, 64)) return 'bad perkId'
      return { ...base, type: 'runMemory', args: { perkId: args.perkId } }
    case 'runAbandon':
      return { ...base, type: 'runAbandon', args: {} }
    case 'setPolicy': {
      const policy = parsePolicy(args.policy)
      if (!policy) return 'bad policy'
      return { ...base, type: 'setPolicy', args: { policy } }
    }
    case 'claim':
      return { ...base, type: 'claim', args: {} }
    case 'devAdvance':
      if (!isCount(args.minutes) || args.minutes > 7 * 24 * 60) return 'bad minutes'
      return { ...base, type: 'devAdvance', args: { minutes: args.minutes } }
    default:
      return 'bad type'
  }
}

function parsePolicy(raw: unknown): PickPolicy | null {
  if (!isObj(raw)) return null
  if (raw.kind === 'recommended') return { kind: 'recommended' }
  if (raw.kind === 'school' && SCHOOLS.includes(raw.value as School)) {
    return { kind: 'school', value: raw.value as School }
  }
  if (raw.kind === 'family' && FAMILIES.includes(raw.value as Family)) {
    return { kind: 'family', value: raw.value as Family }
  }
  return null
}
