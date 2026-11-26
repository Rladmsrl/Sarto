import { describe, expect, it, vi } from 'vitest'
import { createRedactor } from '@shared/log/redact'
import { REPORT_DRAFT_MAX } from '@shared/report'
import type { ConfigOption } from '@shared/thread'
import type { AgentConnection } from './connection'
import { pickMediumEffort } from './outline-titles'
import {
  cleanReportDraft,
  draftRecords,
  LISTED_RECORDS,
  RECORD_WINDOW_MS,
  reportDraftPrompt,
  writeReportDraft,
  type ReportDraftFacts,
} from './report-draft'

const NOW = Date.UTC(2026, 10, 19, 12, 0, 0)
const KEY = 'sk-abcdefghijklmnopqrstuvwx'
const redact = createRedactor({
  home: '/Users/ann',
  platform: 'darwin',
  secrets: () => ['held-pairing-code'],
})

function facts(over: Partial<ReportDraftFacts> = {}): ReportDraftFacts {
  return {
    origin: 'turn',
    language: 'zh-CN',
    agent: 'Claude Code',
    error: null,
    log: [],
    events: [],
    now: NOW,
    ...over,
  }
}

describe('reportDraftPrompt', () => {
  it('masks secrets and the home folder in the error before it reaches the model', () => {
    const prompt = reportDraftPrompt(
      facts({ error: `401 for ${KEY} reading /Users/ann/work/.env with held-pairing-code` }),
      redact,
    )
    expect(prompt).not.toContain(KEY)
    expect(prompt).not.toContain('/Users/ann')
    expect(prompt).not.toContain('held-pairing-code')
    expect(prompt).toContain('401 for <redacted> reading ~/work/.env with <redacted>')
  })

  it('masks the recent records too', () => {
    const prompt = reportDraftPrompt(
      facts({
        log: [{ at: NOW - 1_000, level: 'warn', message: `token=${KEY} refused` }],
        events: [{ at: NOW - 500, event: 'exited', detail: 'cwd /Users/ann/secret-project' }],
      }),
      redact,
    )
    expect(prompt).not.toContain(KEY)
    expect(prompt).not.toContain('/Users/ann')
    expect(prompt).toContain('warn: token=<redacted> refused')
    expect(prompt).toContain('agent exited: cwd ~/secret-project')
  })

  it('names where the report opened, the agent and the language', () => {
    const prompt = reportDraftPrompt(facts({ error: 'Weekly limit reached' }), redact)
    expect(prompt).toContain("a failed turn's error card")
    expect(prompt).toContain('<agent>\nClaude Code\n</agent>')
    expect(prompt).toContain('BCP 47 tag zh-CN')
    expect(prompt).toContain('<error>\nWeekly limit reached\n</error>')
  })

  it('gives no prompt without an error or a recent record', () => {
    const quiet = facts({
      origin: null,
      agent: null,
      log: [{ at: NOW - 1_000, level: 'info', message: 'started' }],
      events: [{ at: NOW - 1_000, event: 'ignored', detail: 'thinking' }],
    })
    expect(reportDraftPrompt(quiet, redact)).toBeNull()
    expect(reportDraftPrompt({ ...quiet, origin: 'crash' }, redact)).toBeNull()
    expect(reportDraftPrompt({ ...quiet, error: 'boom' }, redact)).not.toBeNull()
  })
})

describe('draftRecords', () => {
  it('keeps only recent warnings, errors and agent events, the latest ones', () => {
    const log = Array.from({ length: 12 }, (_, i) => ({
      at: NOW - (12 - i) * 1_000,
      level: 'error' as const,
      message: `failure ${i}`,
    }))
    const lines = draftRecords(
      facts({
        log: [
          { at: NOW - RECORD_WINDOW_MS - 1, level: 'error', message: 'old failure' },
          { at: NOW - 100, level: 'info', message: 'routine line' },
          ...log,
        ],
      }),
      redact,
    )
    expect(lines).toHaveLength(LISTED_RECORDS)
    expect(lines.join('\n')).not.toContain('old failure')
    expect(lines.join('\n')).not.toContain('routine line')
    expect(lines.at(-1)).toContain('failure 11')
  })

  it('cuts a long record', () => {
    const [line] = draftRecords(
      facts({ log: [{ at: NOW - 1, level: 'error', message: 'x'.repeat(5_000) }] }),
      redact,
    )
    expect(line!.length).toBeLessThan(500)
  })
})

describe('cleanReportDraft', () => {
  it('takes the fenced block, and all of an unfenced reply', () => {
    expect(cleanReportDraft('Here it is:\n```text\nA turn failed.\n```\n')).toBe('A turn failed.')
    expect(cleanReportDraft('  A turn failed.  ')).toBe('A turn failed.')
  })

  it('is null for an empty block, which says there is nothing to describe', () => {
    expect(cleanReportDraft('```text\n```')).toBeNull()
    expect(cleanReportDraft('```text\n\n```')).toBeNull()
  })

  it('cuts a reply that runs on', () => {
    expect(Array.from(cleanReportDraft('a'.repeat(REPORT_DRAFT_MAX * 2))!).length).toBe(
      REPORT_DRAFT_MAX,
    )
  })
})

describe('pickMediumEffort and writeReportDraft effort override', () => {
  it('picks medium when available, otherwise middle active tier', () => {
    const codexEffort: ConfigOption = {
      id: 'reasoning_effort',
      name: 'Reasoning',
      category: 'thought_level',
      type: 'select',
      value: 'xhigh',
      choices: [
        { value: 'low', name: 'Low' },
        { value: 'medium', name: 'Medium' },
        { value: 'high', name: 'High' },
        { value: 'xhigh', name: 'Extra High' },
      ],
    }
    expect(pickMediumEffort([codexEffort])).toEqual({
      optionId: 'reasoning_effort',
      value: 'medium',
      current: 'xhigh',
    })

    const threeTier: ConfigOption = {
      id: 'reasoning_effort',
      name: 'Reasoning',
      category: 'thought_level',
      type: 'select',
      value: 'max',
      choices: [
        { value: 'low', name: 'Low' },
        { value: 'high', name: 'High' },
        { value: 'max', name: 'Max' },
      ],
    }
    expect(pickMediumEffort([threeTier])?.value).toBe('high')

    const onOff: ConfigOption = {
      id: 'thinking',
      name: 'Thinking',
      category: 'thought_level',
      type: 'select',
      value: 'off',
      choices: [
        { value: 'off', name: 'Off' },
        { value: 'on', name: 'On' },
      ],
    }
    expect(pickMediumEffort([onOff])?.value).toBe('on')
  })

  it('sets the selected model first and then forces medium thinking effort for report drafts', async () => {
    const initialConfig: ConfigOption[] = [
      {
        id: 'model',
        name: 'Model',
        category: 'model',
        type: 'select',
        value: 'default-model',
        choices: [
          { value: 'default-model', name: 'Default' },
          { value: 'gpt-6.2-sol', name: 'GPT 6.2 Sol' },
        ],
      },
      {
        id: 'reasoning_effort',
        name: 'Reasoning',
        category: 'thought_level',
        type: 'select',
        value: 'high',
        choices: [
          { value: 'low', name: 'Low' },
          { value: 'medium', name: 'Medium' },
          { value: 'high', name: 'High' },
        ],
      },
    ]
    const calls: Array<[string, string | boolean]> = []
    const connection = {
      hiddenSessions: true,
      newSession: vi.fn(async () => ({ sessionId: 'hidden-1', config: initialConfig })),
      setConfigOption: vi.fn(async (_sid: string, optionId: string, value: string | boolean) => {
        calls.push([optionId, value])
        return initialConfig.map((opt) => (opt.id === optionId ? { ...opt, value } : opt))
      }),
      collect: vi.fn(async () => ['```text\nThe turn failed with an error.\n```']),
      cancel: vi.fn(async () => {}),
      removeHidden: vi.fn(async () => {}),
    } as unknown as AgentConnection

    const draft = await writeReportDraft(
      { connection },
      {
        dir: '/tmp/reports',
        prompt: 'Write draft',
        model: { small: false, model: 'gpt-6.2-sol' },
        log: () => {},
      },
    )

    expect(draft).toBe('The turn failed with an error.')
    expect(calls).toEqual([
      ['model', 'gpt-6.2-sol'],
      ['reasoning_effort', 'medium'],
    ])
  })
})
