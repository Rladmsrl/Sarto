import { afterEach, describe, expect, it, vi } from 'vitest'
import type { CallToolResult } from '@modelcontextprotocol/sdk/types.js'
import type { SettingFacts, SettingsSnapshot } from '@shared/host-control'
import { DEFAULT_SETTINGS, type SettingsFile, type SettingsPatch } from '@shared/settings'
import type { SettingChangeItem, SettingsChangeOutcome } from '@shared/thread'
import { setLocale, tSettings, tSettingsEnglish } from '../i18n'
import { mergeSettings, validateSettingsPatch } from '../../core/settings-schema'
import {
  CHANGE_SETTINGS,
  FIND_SETTINGS,
  OPEN_SETTINGS,
  SettingsTools,
  StaleUndo,
  type LocalFacts,
  type SettingsAnswer,
  type SettingsAsk,
} from './tools'

const CALLER = { sessionId: 's1', project: '/p' }
const SECRET = 'sk-live-0123456789abcdef'

function text(result: CallToolResult): string {
  return result.content.map((part) => ('text' in part ? part.text : '')).join('\n')
}

function harness(
  options: { fullAccess?: boolean; file?: Partial<SettingsFile>; facts?: SettingFacts } = {},
) {
  let file: SettingsFile = { ...structuredClone(DEFAULT_SETTINGS), ...options.file }
  const applied: SettingsPatch[] = []
  const asked: SettingsAsk[] = []
  const recorded: SettingChangeItem[][] = []
  const settled: SettingsChangeOutcome[] = []
  let answer: (given: SettingsAnswer) => void = () => {}
  const snapshot = (): SettingsSnapshot => ({
    file,
    facts: { ...options.facts },
  })
  const local: LocalFacts = {
    agents: [{ id: 'codex', name: 'Codex', harnessId: 'codex' }],
    harnesses: [{ id: 'codex', name: 'Codex' }],
    modes: { codex: [{ value: 'agent', name: 'Auto' }] },
    // The host itself only ever sends whether a key is set; a string here must not leak either.
    facts: { 'agents.api-key:codex': SECRET },
  }
  const tools = new SettingsTools({
    platform: 'darwin',
    read: async () => snapshot(),
    apply: async (patch) => {
      // The same checks as the Settings page.
      file = mergeSettings(file, validateSettingsPatch(patch))
      applied.push(patch)
      return snapshot()
    },
    local: async () => local,
    fullAccess: () => options.fullAccess === true,
    ask: (_, ask) => {
      asked.push(ask)
      return { entryId: 'e1', answer: new Promise((resolve) => (answer = resolve)) }
    },
    recorded: (_, items) => {
      recorded.push(items)
      return 'e2'
    },
    settle: (_, __, outcome) => settled.push(outcome),
    open: () => false,
    words: tSettings,
    english: tSettingsEnglish,
  })
  return {
    tools,
    applied,
    asked,
    recorded,
    settled,
    file: () => file,
    answer: (given: SettingsAnswer) => answer(given),
  }
}

const change = (tools: SettingsTools, changes: { id: string; value: unknown }[]) =>
  tools.call(CALLER, CHANGE_SETTINGS, { changes })

afterEach(() => {
  setLocale('en')
  vi.useRealTimers()
})

describe('find_settings', () => {
  it('finds rows by English and Chinese words, with their values', async () => {
    const { tools } = harness()
    const found = await tools.call(CALLER, FIND_SETTINGS, { query: 'idle' })
    expect(text(found)).toContain('agents.idle-release')
    expect(text(found)).toContain('value: Auto')
    setLocale('zh-CN')
    const zh = await tools.call(CALLER, FIND_SETTINGS, { query: '空闲' })
    expect(text(zh)).toContain('agents.idle-release')
    expect(text(zh)).toContain('释放空闲会话的智能体 (Release idle sessions’ agents)')
  })

  it('lists the rows of each agent by its id', async () => {
    const { tools } = harness()
    const all = text(await tools.call(CALLER, FIND_SETTINGS, {}))
    expect(all).toContain('agents.start-mode:codex')
    expect(all).toContain('harnesses.auto-update:codex')
  })

  it('never gives a secret’s value, only whether it is set', async () => {
    const { tools } = harness()
    const all = await tools.call(CALLER, FIND_SETTINGS, {})
    const key = await tools.call(CALLER, FIND_SETTINGS, { query: 'key codex' })
    for (const result of [all, key]) {
      expect(JSON.stringify(result)).not.toContain(SECRET)
    }
    expect(text(key)).toContain('agents.api-key:codex')
  })

  it('hides a proxy’s password and refuses to change a proxy that has one', async () => {
    const proxy = {
      mode: 'custom' as const,
      url: 'http://me:hunter2@proxy.example:8080',
      noProxy: '',
    }
    const { tools, applied } = harness({ fullAccess: true, file: { proxy } })
    const found = await tools.call(CALLER, FIND_SETTINGS, { query: 'proxy' })
    expect(JSON.stringify(found)).not.toContain('hunter2')
    const result = await change(tools, [{ id: 'advanced.proxy', value: 'http://other:3128' }])
    expect(result.isError).toBe(true)
    expect(applied).toEqual([])
  })
})

describe('change_settings', () => {
  it('asks in a card outside Full access, and changes only on Change', async () => {
    const { tools, applied, asked, settled, answer, file } = harness()
    vi.useFakeTimers()
    const pending = change(tools, [{ id: 'agents.idle-release', value: 'never' }])
    await vi.waitFor(() => expect(asked).toHaveLength(1))
    expect(applied).toEqual([])
    expect(asked[0]!.items[0]).toMatchObject({
      id: 'agents.idle-release',
      from: { value: 'auto', text: 'Auto' },
      to: { value: 'never', text: 'Never' },
    })
    answer({ decision: 'change' })
    const result = await pending
    expect(result.isError).toBeUndefined()
    expect(file().idleSessions.release).toBe('never')
    expect(settled).toEqual([{ kind: 'changed' }])
  })

  it("changes nothing on Don't change", async () => {
    const { tools, applied, asked, answer } = harness()
    const pending = change(tools, [{ id: 'general.session-titles', value: false }])
    await vi.waitFor(() => expect(asked).toHaveLength(1))
    answer({ decision: 'keep' })
    expect(text(await pending)).toContain("Don't change")
    expect(applied).toEqual([])
  })

  it('returns within a minute, and the same call again waits on the same card', async () => {
    vi.useFakeTimers()
    const { tools, asked, answer } = harness()
    const first = change(tools, [{ id: 'general.session-titles', value: false }])
    await vi.advanceTimersByTimeAsync(60_000)
    expect(text(await first)).toContain('has not answered')
    const second = change(tools, [{ id: 'general.session-titles', value: false }])
    await vi.advanceTimersByTimeAsync(0)
    answer({ decision: 'change' })
    expect(text(await second)).toContain('Changed')
    expect(asked).toHaveLength(1)
  })

  it('changes at once in Full access and leaves a line', async () => {
    const { tools, asked, recorded, file } = harness({ fullAccess: true })
    const result = await change(tools, [
      { id: 'agents.idle-release', value: 'never' },
      { id: 'git.fetch', value: true },
    ])
    expect(result.isError).toBeUndefined()
    expect(asked).toEqual([])
    expect(recorded[0]!.map((item) => item.id)).toEqual(['agents.idle-release', 'git.fetch'])
    expect(file().idleSessions.release).toBe('never')
    expect(file().git.backgroundFetch).toBe(true)
  })

  it('still asks in Full access for a row that widens access, with its warning', async () => {
    const { tools, asked, recorded } = harness({ fullAccess: true })
    void change(tools, [{ id: 'remote.terminal', value: true }])
    await vi.waitFor(() => expect(asked).toHaveLength(1))
    expect(recorded).toEqual([])
    expect(asked[0]!.items[0]!.warning).toContain('run any command')
  })

  it('still asks in Full access before agents may type passwords', async () => {
    const { tools, asked, applied, recorded } = harness({ fullAccess: true })
    void change(tools, [{ id: 'general.agent-passwords', value: true }])
    await vi.waitFor(() => expect(asked).toHaveLength(1))
    expect(applied).toEqual([])
    expect(recorded).toEqual([])
    expect(asked[0]!.items[0]!.warning).toContain('type passwords and codes')
  })

  it('never changes secrets, paths or actions', async () => {
    const { tools, applied, asked } = harness({ fullAccess: true })
    for (const id of [
      'agents.api-key:codex',
      'terminal.shell',
      'harnesses.program:codex',
      'git.worktree-root',
      'advanced.remove-sessions',
      'harnesses.install:codex',
      'agents.remove:codex',
    ]) {
      const result = await change(tools, [{ id, value: '/tmp/x' }])
      expect(result.isError, id).toBe(true)
      expect(JSON.stringify(result)).not.toContain(SECRET)
    }
    expect(applied).toEqual([])
    expect(asked).toEqual([])
  })

  it('refuses a value the row does not take, listing those it does, and changes none', async () => {
    const { tools, applied } = harness({ fullAccess: true })
    const result = await change(tools, [
      { id: 'general.session-titles', value: false },
      { id: 'agents.idle-release', value: 'sometimes' },
    ])
    expect(result.isError).toBe(true)
    expect(text(result)).toContain('"auto", "custom", "never"')
    expect(applied).toEqual([])
  })

  it('refuses a row the host does not have, such as a window’s on another host', async () => {
    const { tools, applied } = harness({ fullAccess: true })
    expect((await change(tools, [{ id: 'agents.enabled:nobody', value: true }])).isError).toBe(true)
    expect((await change(tools, [{ id: 'appearance.nothing', value: true }])).isError).toBe(true)
    expect(applied).toEqual([])
  })
})

describe('open_settings', () => {
  it('says where the row is when no window shows the session', async () => {
    const { tools } = harness()
    const result = await tools.call(CALLER, OPEN_SETTINGS, { id: 'agents.idle-release' })
    expect(text(result)).toContain(
      'Settings › Agents › Idle sessions › Release idle sessions’ agents',
    )
  })
})

describe('undo', () => {
  it('sets the rows back, unless one changed again since', async () => {
    const { tools, recorded, file } = harness({ fullAccess: true })
    await change(tools, [{ id: 'agents.idle-release', value: 'never' }])
    await tools.undo(recorded[0]!)
    expect(file().idleSessions.release).toBe('auto')
    await change(tools, [{ id: 'agents.idle-release', value: 'custom' }])
    await change(tools, [{ id: 'agents.idle-release', value: 'never' }])
    await expect(tools.undo(recorded[1]!)).rejects.toBeInstanceOf(StaleUndo)
  })
})
