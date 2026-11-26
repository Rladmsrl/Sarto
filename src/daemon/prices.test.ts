import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { createLogger } from '../core/log'
import { PriceUpdates } from './prices'

function snapshot(asOf: string, input = 0.000003) {
  const models: Record<
    string,
    { input: number; output: number; cacheRead: number; cacheWrite: number }
  > = {}
  for (let i = 0; i < 120; i++)
    models[`model-${i}`] = { input, output: 0.000015, cacheRead: 0, cacheWrite: 0 }
  return { asOf, models }
}

describe("the daemon's daily model prices", () => {
  let dir: string
  let file: string
  beforeEach(async () => {
    dir = await mkdtemp(path.join(os.tmpdir(), 'sarto-daemon-prices-'))
    file = path.join(dir, 'state', 'prices-server.json')
  })
  afterEach(async () => {
    await rm(dir, { recursive: true, force: true })
  })

  const updates = (fetch: (url: string, init: RequestInit) => Promise<Response>) =>
    new PriceUpdates({
      origin: () => 'https://sarto.example',
      fetch,
      file,
      log: createLogger('prices-test'),
    })

  it("keeps the server's snapshot with its tag, and asks with the tag next time", async () => {
    const seen: Array<{ url: string; headers: Record<string, string> }> = []
    const answers = [
      new Response(JSON.stringify(snapshot('2026-11-24')), {
        status: 200,
        headers: { etag: '"abc"' },
      }),
      new Response(null, { status: 304 }),
    ]
    const prices = updates(async (url, init) => {
      seen.push({ url, headers: init.headers as Record<string, string> })
      return answers.shift()!
    })
    expect(await prices.update()).toBe('updated')
    const kept = JSON.parse(await readFile(file, 'utf8')) as { asOf: string; etag: string }
    expect(kept.asOf).toBe('2026-11-24')
    expect(kept.etag).toBe('"abc"')

    expect(await prices.update()).toBe('unchanged')
    expect(seen[0]?.url).toBe('https://sarto.example/v1/prices')
    expect(seen[1]?.headers['if-none-match']).toBe('"abc"')
    // It names no one: no account or token goes with the request.
    expect(
      Object.keys(seen[0]?.headers ?? {}).some((h) => h.toLowerCase() === 'authorization'),
    ).toBe(false)
  })

  it('keeps what it has when the server is away, has no prices, or sends something odd', async () => {
    await writeFile(path.join(dir, 'placeholder'), '')
    const good = snapshot('2026-11-23')
    const answers: Array<() => Promise<Response>> = [
      async () => new Response(JSON.stringify(good), { status: 200 }),
      async () => {
        throw new Error('offline')
      },
      async () => new Response(JSON.stringify({ error: 'not_found' }), { status: 404 }),
      async () => new Response(JSON.stringify({ asOf: 'today', models: {} }), { status: 200 }),
      async () => new Response('{not json', { status: 200 }),
    ]
    const prices = updates(() => answers.shift()!())
    expect(await prices.update()).toBe('updated')
    for (let i = 0; i < 4; i++) expect(await prices.update()).toBe('failed')
    const kept = JSON.parse(await readFile(file, 'utf8')) as { asOf: string }
    expect(kept.asOf).toBe('2026-11-23')
  })
})
