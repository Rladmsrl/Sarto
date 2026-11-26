import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { AccountApi, AccountServiceError } from '@shared/account-api'
import { setLogRedactorForTests } from '@shared/log/process-log'
import { createRedactor } from '@shared/log/redact'
import { ReportShelf, writeReport } from '@shared/log/report-bundle'
import { DEFAULT_SETTINGS } from '@shared/settings'
import { submitShelvedReport } from './problem-report'

const dirs: string[] = []

afterEach(async () => {
  for (const dir of dirs.splice(0)) await rm(dir, { recursive: true, force: true })
})

async function tempDir(): Promise<string> {
  const dir = await mkdtemp(path.join(tmpdir(), 'sarto-submit-report-'))
  dirs.push(dir)
  return dir
}

describe('AccountApi.submitReport and submitShelvedReport', () => {
  it('supports signed-in and anonymous submissions and parses retry-after on 429', async () => {
    const seenAuth: Array<string | null> = []
    const api = new AccountApi('https://cloud.example', async (_url, init) => {
      const headers = (init.headers ?? {}) as Record<string, string>
      seenAuth.push(headers.authorization ?? null)
      if (seenAuth.length === 3) {
        return new Response(JSON.stringify({ error: 'rate_limited', retry_after: 42 }), {
          status: 429,
          headers: { 'content-type': 'application/json', 'retry-after': '42' },
        })
      }
      const anonymous = !headers.authorization
      return new Response(JSON.stringify({ id: 'SR-7F3K2Q', anonymous }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      })
    })

    const signed = await api.submitReport({
      accessToken: 'tok_access_123',
      description: 'Signed in bug',
      version: '0.3.0',
      platform: 'macOS 15.4',
      bundle: { filename: 'sarto-report.zip', bytes: new Uint8Array([0x50, 0x4b, 0x05, 0x06]) },
    })
    expect(signed).toEqual({ id: 'SR-7F3K2Q', anonymous: false })
    expect(seenAuth[0]).toBe('Bearer tok_access_123')

    const anon = await api.submitReport({
      accessToken: null,
      description: 'Anonymous bug',
    })
    expect(anon).toEqual({ id: 'SR-7F3K2Q', anonymous: true })
    expect(seenAuth[1]).toBeNull()

    await expect(
      api.submitReport({ accessToken: null, description: 'Rate limited' }),
    ).rejects.toSatisfy(
      (err: unknown) =>
        err instanceof AccountServiceError && err.code === 'rate_limited' && err.retryAfter === 42,
    )
  })

  it('redacts title and description before uploading a shelved report and drops it on success', async () => {
    const dir = await tempDir()
    const key = 'sk-ant-api03-abcdefghijklmnopqrstuv'
    const redactor = createRedactor({ home: '/Users/ann', platform: 'darwin' })
    setLogRedactorForTests(redactor)

    const shelf = new ReportShelf(dir)
    const request = {
      description: `Crashed in /Users/ann/proj with ${key}\nDetails here`,
      range: { kind: 'hour' as const },
      extras: [],
      context: null,
    }
    const built = await writeReport(
      {
        request,
        now: Date.now(),
        parent: {},
        settings: DEFAULT_SETTINGS,
        host: null,
        logDir: null,
        crashDir: null,
        screenshot: null,
        redact: redactor,
      },
      dir,
    )
    expect(built.ok).toBe(true)
    if (!built.ok) return

    const id = shelf.put({
      file: built.file,
      files: built.files,
      size: built.size,
      request,
      clientMeta: { version: '0.3.0', platform: 'macOS 15.4 arm64' },
    })!

    const uploaded: Array<{ title?: string | null; description: string }> = []
    const outcome = await submitShelvedReport(shelf, id, {
      version: '0.3.0',
      settings: DEFAULT_SETTINGS,
      cloud: {
        origin: () => 'https://sarto.1o.ink',
        submitReport: async (input) => {
          uploaded.push({ title: input.title, description: input.description })
          return { id: 'SR-2B4C6D', anonymous: false }
        },
      },
    })

    expect(outcome.ok).toBe(true)
    if (!outcome.ok) return
    expect(outcome.id).toBe('SR-2B4C6D')
    expect(outcome.anonymous).toBe(false)
    expect(outcome.consoleUrl).toBe('https://sarto.1o.ink/console/#reports/SR-2B4C6D')
    expect(outcome.issueUrl).toContain('report-id=SR-2B4C6D')
    expect(uploaded[0]?.description).not.toContain(key)
    expect(uploaded[0]?.description).not.toContain('/Users/ann')
    expect(uploaded[0]?.title).not.toContain(key)
    expect(shelf.get(id)).toBeNull()
  })
})
