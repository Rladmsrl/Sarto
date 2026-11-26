// Per-run loopback HTTP tunnel on the remote model host: Claude Code connects here for
// `/mcp/sarto_exec` (local file/shell tools) and `/mcp/sarto` (local Sarto MCP tools). Each
// request is forwarded over the Noise channel to the controller computer and answered back.

import { randomBytes, timingSafeEqual } from 'node:crypto'
import http from 'node:http'
import type { AddressInfo, Socket } from 'node:net'
import { addLogSecret } from '@shared/log/process-log'
import { REMOTE_CLAUDE_EXEC_MCP, REMOTE_CLAUDE_MAX_MCP_BODY_BYTES } from '@shared/remote-claude'

const TOKEN_BYTES = 32
const FORWARD_REQUEST_HEADERS = new Set([
  'content-type',
  'accept',
  'mcp-session-id',
  'mcp-protocol-version',
  'last-event-id',
])
const FORWARD_RESPONSE_HEADERS = new Set(['content-type', 'mcp-session-id', 'mcp-protocol-version'])

export type TunnelServerName = 'sarto_exec' | 'sarto'

export interface TunnelRequest {
  server: TunnelServerName
  headers: [string, string][]
  body: string
}

export interface TunnelResponse {
  status: number
  headers: [string, string][]
  body: string
}

export interface RunTunnel {
  readonly url: string
  readonly token: string
  close(): Promise<void>
}

function bearerToken(header: string | undefined): string | null {
  const match = /^Bearer ([A-Za-z0-9_-]{1,256})$/.exec(header ?? '')
  return match ? match[1]! : null
}

function matchesToken(given: string | null, expected: string): boolean {
  if (!given) return false
  const a = Buffer.from(given)
  const b = Buffer.from(expected)
  return a.length === b.length && timingSafeEqual(a, b)
}

function routeServer(rawUrl: string | undefined): TunnelServerName | null {
  const path = (rawUrl ?? '').split('?')[0]!
  if (path === `/mcp/${REMOTE_CLAUDE_EXEC_MCP}`) return 'sarto_exec'
  if (path === '/mcp/sarto') return 'sarto'
  return null
}

function filterHeaders(
  headers: http.IncomingHttpHeaders,
  allow: ReadonlySet<string>,
): [string, string][] {
  const kept: [string, string][] = []
  for (const [name, value] of Object.entries(headers)) {
    const key = name.toLowerCase()
    if (!allow.has(key) || value === undefined) continue
    kept.push([key, Array.isArray(value) ? value.join(', ') : value])
  }
  return kept
}

function filterResponseHeaders(headers: readonly [string, string][]): Record<string, string> {
  const out: Record<string, string> = {}
  for (const [name, value] of headers) {
    const key = name.toLowerCase()
    if (!FORWARD_RESPONSE_HEADERS.has(key)) continue
    out[key] = value
  }
  return out
}

function readBody(req: http.IncomingMessage, maxBytes: number): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = []
    let size = 0
    let done = false
    const fail = (error: Error): void => {
      if (done) return
      done = true
      reject(error)
    }
    req.on('data', (chunk: Buffer) => {
      if (done) return
      size += chunk.length
      if (size > maxBytes) {
        req.destroy()
        fail(new Error('Request body exceeds limit'))
        return
      }
      chunks.push(chunk)
    })
    req.on('end', () => {
      if (done) return
      done = true
      resolve(Buffer.concat(chunks, size).toString('utf8'))
    })
    req.on('error', (error) => fail(error))
  })
}

function writeJson(
  res: http.ServerResponse,
  status: number,
  body: Record<string, unknown>,
  extraHeaders: Record<string, string> = {},
): void {
  if (res.destroyed || res.writableEnded) return
  res.writeHead(status, { 'content-type': 'application/json', ...extraHeaders })
  res.end(JSON.stringify(body))
}

/**
 * Starts a loopback-only HTTP tunnel bound to `127.0.0.1:0` with a per-run random bearer token.
 */
export async function createRunTunnel(
  handle: (request: TunnelRequest, signal: AbortSignal) => Promise<TunnelResponse>,
): Promise<RunTunnel> {
  const token = randomBytes(TOKEN_BYTES).toString('base64url')
  addLogSecret(token)
  const sockets = new Set<Socket>()
  let closed = false
  let port = 0

  const server = http.createServer((req, res) => {
    void (async () => {
      if (closed) return writeJson(res, 503, { error: 'Tunnel closed' })
      // Refuse browser requests and DNS rebinding, as McpService does.
      if (req.headers.origin !== undefined) {
        return writeJson(res, 403, { error: 'Requests from web pages are refused' })
      }
      if (req.headers.host !== `127.0.0.1:${port}`) {
        return writeJson(res, 403, { error: 'Unknown host' })
      }
      if (!matchesToken(bearerToken(req.headers.authorization), token)) {
        return writeJson(
          res,
          401,
          { error: 'Bearer token required' },
          { 'WWW-Authenticate': 'Bearer' },
        )
      }
      const target = routeServer(req.url)
      if (!target) return writeJson(res, 404, { error: 'Not found' })
      if (req.method !== 'POST') {
        return writeJson(res, 405, { error: 'Method not allowed' }, { Allow: 'POST' })
      }
      let body: string
      try {
        body = await readBody(req, REMOTE_CLAUDE_MAX_MCP_BODY_BYTES)
      } catch {
        return writeJson(res, 413, { error: 'Request body too large' })
      }
      const abort = new AbortController()
      res.once('close', () => {
        if (!res.writableEnded) abort.abort()
      })
      try {
        const reply = await handle(
          {
            server: target,
            headers: filterHeaders(req.headers, FORWARD_REQUEST_HEADERS),
            body,
          },
          abort.signal,
        )
        if (res.destroyed || res.writableEnded) return
        const responseHeaders = filterResponseHeaders(reply.headers)
        if (!responseHeaders['content-type']) responseHeaders['content-type'] = 'application/json'
        res.writeHead(reply.status, responseHeaders)
        res.end(reply.body)
      } catch (error) {
        // Never leak remote host paths or internal stacks back through the tunnel.
        const cancelled = abort.signal.aborted || /aborted|cancel/i.test(String(error))
        writeJson(res, cancelled ? 499 : 502, {
          error: cancelled
            ? 'The request was cancelled.'
            : 'The remote execution channel is unavailable.',
        })
      }
    })()
  })

  server.on('connection', (socket) => {
    sockets.add(socket)
    socket.on('close', () => sockets.delete(socket))
  })

  await new Promise<void>((resolve, reject) => {
    server.once('error', reject)
    server.listen(0, '127.0.0.1', () => {
      server.off('error', reject)
      port = (server.address() as AddressInfo).port
      resolve()
    })
  })

  return {
    url: `http://127.0.0.1:${port}`,
    token,
    async close() {
      if (closed) return
      closed = true
      for (const socket of sockets) socket.destroy()
      sockets.clear()
      await new Promise<void>((resolve) => server.close(() => resolve()))
    },
  }
}
