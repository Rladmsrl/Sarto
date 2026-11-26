import { mkdir, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { WebSocketServer, type WebSocket } from 'ws'
import type { HostEvent } from '@shared/agent-host'
import type { WorkFact } from '@shared/work-facts'
import { createLogger, type Logger } from '../../core/log'
import { GameLink, type GameLinkOptions } from './link'

function sampleTurn(id: string): WorkFact {
  return {
    kind: 'turn.completed',
    id,
    sessionId: 'sess-1',
    agentId: 'codex',
    at: Date.now(),
    start: Date.now() - 5_000,
    end: Date.now(),
    ok: true,
    workSeconds: { think: 2, scan: 1, command: 1, edit: 1 },
    waits: [],
    models: [
      {
        model: 'gpt-5.5',
        tokens: { input: 10, output: 5, thought: 0, cacheRead: 0, cacheWrite: 0 },
      },
    ],
  }
}

interface FactsFrame {
  type: string
  batch?: { batch: string; facts: { id: string }[] }
}

/** Answers every facts frame with `answer`, or not at all when it returns null. */
function answerFacts(
  wss: WebSocketServer,
  answer: (frame: Required<FactsFrame>['batch'], count: number) => object | null,
): { count(): number } {
  let count = 0
  wss.on('connection', (ws) => {
    ws.on('message', (raw) => {
      const msg = JSON.parse(String(raw)) as FactsFrame
      if (msg.type !== 'facts' || !msg.batch) return
      count += 1
      const reply = answer(msg.batch, count)
      if (reply) ws.send(JSON.stringify(reply))
    })
  })
  return { count: () => count }
}

function accepted(batch: Required<FactsFrame>['batch']): object {
  return {
    type: 'factsResult',
    batch: batch.batch,
    result: { accepted: batch.facts.length, duplicates: 0, rejected: [] },
  }
}

describe('GameLink', () => {
  let dir: string
  let server: http.Server
  let wss: WebSocketServer
  let port: number

  function makeLink(overrides: Partial<GameLinkOptions> = {}): {
    link: GameLink
    emit: (facts: WorkFact[]) => void
    /** How often the link began following work facts, and how many it follows now. */
    subscriptions: () => { total: number; active: number }
  } {
    let listener: (event: HostEvent | null) => void = () => {}
    let total = 0
    let active = 0
    const link = new GameLink({
      dataPath: dir,
      env: { SARTO_GAME_URL: `http://127.0.0.1:${port}` },
      account: () => ({ id: 'acc-1' }),
      onHostEvent: (cb) => {
        listener = cb
        total += 1
        active += 1
        return () => {
          active -= 1
        }
      },
      knownModels: async () => new Set(['gpt-5.5']),
      log: createLogger('test'),
      onFrame: () => {},
      onStatus: () => {},
      retryMs: 20,
      saveDelayMs: 5,
      ...overrides,
    })
    return {
      link,
      emit: (facts) => listener({ type: 'work.facts', facts }),
      subscriptions: () => ({ total, active }),
    }
  }

  beforeEach(async () => {
    dir = await mkdtemp(path.join(os.tmpdir(), 'sarto-game-link-'))
    server = http.createServer()
    wss = new WebSocketServer({ server })
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
    port = (server.address() as { port: number }).port
  })

  afterEach(async () => {
    for (const client of wss.clients) client.terminate()
    wss.close()
    await new Promise<void>((resolve) => server.close(() => resolve()))
    await rm(dir, { recursive: true, force: true })
  })

  async function queuedOnDisk(): Promise<number> {
    try {
      const saved = JSON.parse(
        await readFile(path.join(dir, 'state', 'game-queue.json'), 'utf8'),
      ) as { accounts: Record<string, { queue: unknown[] }> }
      return Object.values(saved.accounts).reduce((sum, a) => sum + a.queue.length, 0)
    } catch {
      return 0
    }
  }

  it('stays dormant until opted in: reads no game file, follows no work, opens no socket', async () => {
    let connections = 0
    wss.on('connection', () => {
      connections += 1
    })
    const stateDir = path.join(dir, 'state')
    await mkdir(stateDir, { recursive: true })
    const leftover = JSON.stringify({ accounts: { 'acc-1': { seq: 3, queue: [] } } })
    await writeFile(path.join(stateDir, 'game-queue.json'), leftover)
    const { link, subscriptions } = makeLink()

    await link.start()
    await new Promise((r) => setTimeout(r, 100))

    expect(subscriptions().total).toBe(0)
    expect(connections).toBe(0)
    expect(link.status()).toMatchObject({
      available: true,
      optedIn: false,
      enabled: false,
      connected: false,
      queued: 0,
    })
    await link.stop()
    // No secret was made and the queue was left as it was.
    expect(await readdir(stateDir)).toEqual(['game-queue.json'])
    expect(await readFile(path.join(stateDir, 'game-queue.json'), 'utf8')).toBe(leftover)

    const unconfigured = makeLink({ env: {} })
    await unconfigured.link.start()
    expect(unconfigured.link.status()).toMatchObject({ available: false, enabled: false })
    await unconfigured.link.stop()
  })

  it('connects once opted in, and remembers the choice', async () => {
    const tokens: string[] = []
    wss.on('connection', (_ws, req) => {
      tokens.push(new URL(req.url ?? '/', 'http://127.0.0.1').searchParams.get('token') ?? '')
    })
    const first = makeLink()
    await first.link.start()
    expect(first.link.status().optedIn).toBe(false)

    const status = await first.link.setEnabled(true)
    expect(status).toMatchObject({ available: true, optedIn: true, enabled: true })
    await viWait(() => first.link.status().connected)
    expect(tokens).toEqual(['dev.acc-1.daemon'])
    await first.link.stop()

    const second = makeLink()
    await second.link.start()
    expect(second.link.status().optedIn).toBe(true)
    await viWait(() => second.link.status().connected)
    await second.link.stop()
  })

  it('turning the game off stops following work, closes the sockets and deletes unsent facts', async () => {
    const seqs: number[] = []
    wss.on('connection', (ws) => {
      ws.on('message', (raw) => {
        const msg = JSON.parse(String(raw)) as {
          type: string
          batch?: { facts: { seq: number }[] }
        }
        if (msg.type === 'facts') seqs.push(...(msg.batch?.facts ?? []).map((f) => f.seq))
      })
    })
    const { link, emit, subscriptions } = makeLink()
    await link.start()
    await link.setEnabled(true)
    expect(subscriptions()).toEqual({ total: 1, active: 1 })
    await viWait(() => link.status().connected)
    emit([sampleTurn('turn-1'), sampleTurn('turn-2')])
    await viWait(() => link.status().queued === 2 && seqs.length === 2)
    await new Promise((r) => setTimeout(r, 50))
    expect(await queuedOnDisk()).toBe(2)

    const status = await link.setEnabled(false)
    expect(status).toMatchObject({ optedIn: false, enabled: false, connected: false, queued: 0 })
    expect(subscriptions().active).toBe(0)
    expect(await queuedOnDisk()).toBe(0)
    await viWait(() => wss.clients.size === 0)
    emit([sampleTurn('turn-3')])
    expect(link.status().queued).toBe(0)

    // Back on, the counter goes on from where it was, so the service sees no replay.
    await link.setEnabled(true)
    await viWait(() => link.status().connected)
    emit([sampleTurn('turn-4')])
    await viWait(() => seqs.length === 3)
    expect(seqs).toEqual([1, 2, 3])
    await link.stop()

    // The record of what left the computer stays.
    const uploads = await readFile(path.join(dir, 'state', 'game-uploads.jsonl'), 'utf8')
    expect(uploads.trim().split('\n')).toHaveLength(2)
  })

  it('reconnects the viewer socket when it drops while the daemon socket stays open', async () => {
    const viewerSockets: WebSocket[] = []
    wss.on('connection', (ws, req) => {
      const url = new URL(req.url ?? '/', 'http://127.0.0.1')
      const token = url.searchParams.get('token') ?? ''
      if (token.endsWith('.app')) viewerSockets.push(ws)
    })

    const link = new GameLink({
      dataPath: dir,
      env: { SARTO_GAME_URL: `http://127.0.0.1:${port}` },
      account: () => ({ id: 'acc-1' }),
      onHostEvent: () => () => {},
      knownModels: async () => new Set(['gpt-5.5']),
      log: createLogger('test'),
      onFrame: () => {},
      onStatus: () => {},
      retryMs: 40,
    })

    link.watch(1)
    await link.start()
    await link.setEnabled(true)
    await viWait(() => viewerSockets.length === 1)
    viewerSockets[0]!.close()
    await viWait(() => viewerSockets.length >= 2)
    await link.stop()
  })

  it('backs off a rejected batch and drops it after repeated rejections', async () => {
    const sentAt: number[] = []
    const server = answerFacts(wss, () => {
      sentAt.push(Date.now())
      return { type: 'error', error: 'bad facts' }
    })
    const warnings: string[] = []
    const log: Logger = { ...createLogger('test'), warn: (message) => warnings.push(message) }
    const { link, emit } = makeLink({ log })

    await link.start()
    await link.setEnabled(true)
    await viWait(() => link.status().connected)
    emit([sampleTurn('turn-1')])
    await viWait(() => link.status().queued === 0, 3_000)

    expect(server.count()).toBe(5)
    for (let i = 1; i < sentAt.length; i++) {
      // 20 ms, then twice as long after every rejection; a timer may fire a millisecond early.
      expect(sentAt[i]! - sentAt[i - 1]!).toBeGreaterThanOrEqual(20 * 2 ** (i - 1) - 2)
    }
    expect(warnings.some((w) => w.includes('bad facts') && w.includes('1 fact'))).toBe(true)
    expect(warnings.join('\n')).not.toContain('turn-1')

    // Once dropped, the batch is not sent again, and the next facts still go.
    await new Promise((r) => setTimeout(r, 150))
    expect(server.count()).toBe(5)
    await link.stop()
  })

  it('sends a batch again when the game service does not answer it', async () => {
    const server = answerFacts(wss, (batch, count) => (count === 1 ? null : accepted(batch)))
    const { link, emit } = makeLink({ batchTimeoutMs: 60 })

    await link.start()
    await link.setEnabled(true)
    await viWait(() => link.status().connected)
    emit([sampleTurn('turn-1')])
    await viWait(() => link.status().queued === 0)
    expect(server.count()).toBe(2)
    await link.stop()
  })

  it('keeps unsent facts on disk across a restart, without a partial file', async () => {
    answerFacts(wss, () => null)
    const first = makeLink({ saveDelayMs: 10_000 })
    await first.link.start()
    await first.link.setEnabled(true)
    await viWait(() => first.link.status().connected)
    first.emit([sampleTurn('turn-1'), sampleTurn('turn-2')])
    await viWait(() => first.link.status().queued === 2)
    await first.link.stop()

    const stateDir = path.join(dir, 'state')
    const saved = JSON.parse(await readFile(path.join(stateDir, 'game-queue.json'), 'utf8')) as {
      accounts: Record<string, { queue: unknown[] }>
    }
    expect(saved.accounts['acc-1']?.queue).toHaveLength(2)
    expect((await readdir(stateDir)).filter((name) => name.includes('.tmp'))).toEqual([])

    wss.removeAllListeners('connection')
    const server = answerFacts(wss, (batch) => accepted(batch))
    const second = makeLink()
    await second.link.start()
    await viWait(() => second.link.status().queued === 0)
    expect(server.count()).toBe(1)
    await second.link.stop()
  })

  it('rotates the upload log to one older file instead of emptying it', async () => {
    const stateDir = path.join(dir, 'state')
    await mkdir(stateDir, { recursive: true })
    const uploads = path.join(stateDir, 'game-uploads.jsonl')
    const old = `${JSON.stringify({ at: 1, batch: 'old', facts: [] })}\n`
    await writeFile(uploads, old.repeat(Math.ceil((1024 * 1024) / old.length) + 1))
    answerFacts(wss, (batch) => accepted(batch))
    const { link, emit } = makeLink()

    await link.start()
    await link.setEnabled(true)
    await viWait(() => link.status().connected)
    emit([sampleTurn('turn-1')])
    await viWait(() => link.status().queued === 0)
    await link.stop()

    const rotated = await readFile(`${uploads}.1`, 'utf8')
    expect(rotated.startsWith(old)).toBe(true)
    const current = (await readFile(uploads, 'utf8')).trim().split('\n')
    expect(current).toHaveLength(1)
    expect(JSON.parse(current[0]!).facts).toHaveLength(1)
  })

  it('clears inFlight and isolates queued facts per account across account switches', async () => {
    const receivedByToken = new Map<string, number>()
    let answerBatches = false
    wss.on('connection', (ws, req) => {
      const token = new URL(req.url ?? '/', 'http://127.0.0.1').searchParams.get('token') ?? ''
      ws.on('message', (raw) => {
        const msg = JSON.parse(String(raw)) as {
          type: string
          batch?: { batch: string; facts: unknown[] }
        }
        if (msg.type === 'facts' && msg.batch) {
          receivedByToken.set(token, (receivedByToken.get(token) ?? 0) + msg.batch.facts.length)
          if (answerBatches) {
            ws.send(
              JSON.stringify({
                type: 'factsResult',
                batch: msg.batch.batch,
                result: { accepted: msg.batch.facts.length, duplicates: 0, rejected: [] },
              }),
            )
          }
        }
      })
    })

    let currentAccount: { id: string } | null = { id: 'acc-a' }
    let emitHost: (event: HostEvent | null) => void = () => {}
    const link = new GameLink({
      dataPath: dir,
      env: { SARTO_GAME_URL: `http://127.0.0.1:${port}` },
      account: () => currentAccount,
      onHostEvent: (cb) => {
        emitHost = cb
        return () => {}
      },
      knownModels: async () => new Set(['gpt-5.5']),
      log: createLogger('test'),
      onFrame: () => {},
      onStatus: () => {},
      retryMs: 40,
    })

    await link.start()
    await link.setEnabled(true)
    await viWait(() => link.status().connected)

    // Account A sends a batch that stays unacknowledged when switching to Account B.
    emitHost({ type: 'work.facts', facts: [sampleTurn('turn-a')] })
    await viWait(() => (receivedByToken.get('dev.acc-a.daemon') ?? 0) === 1)

    answerBatches = true
    currentAccount = { id: 'acc-b' }
    link.accountChanged()
    await viWait(() => link.status().connected)

    // Account B must not receive Account A's queued turn, and must still flush its own turn.
    emitHost({ type: 'work.facts', facts: [sampleTurn('turn-b')] })
    await viWait(() => (receivedByToken.get('dev.acc-b.daemon') ?? 0) === 1)
    expect(receivedByToken.get('dev.acc-b.daemon')).toBe(1)
    await link.stop()
  })
})

async function viWait(check: () => boolean, timeoutMs = 2_000): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (check()) return
    await new Promise((r) => setTimeout(r, 15))
  }
  throw new Error('Condition did not hold in time')
}
