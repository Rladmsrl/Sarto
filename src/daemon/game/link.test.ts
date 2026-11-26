import { mkdtemp, rm } from 'node:fs/promises'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { WebSocketServer, type WebSocket } from 'ws'
import type { HostEvent } from '@shared/agent-host'
import type { WorkFact } from '@shared/work-facts'
import { createLogger } from '../../core/log'
import { GameLink } from './link'

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

describe('GameLink', () => {
  let dir: string
  let server: http.Server
  let wss: WebSocketServer
  let port: number

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
    await viWait(() => viewerSockets.length === 1)
    viewerSockets[0]!.close()
    await viWait(() => viewerSockets.length >= 2)
    link.stop()
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
    link.stop()
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
