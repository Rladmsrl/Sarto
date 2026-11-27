import { mkdtemp, mkdir, readFile, rm, symlink, writeFile } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import {
  DEFAULT_REMOTE_CLAUDE_SETTINGS,
  HOSTED_CLAUDE_DISALLOWED_TOOLS,
  HOSTED_CLAUDE_TOOLS,
  REMOTE_CLAUDE_EXEC_MCP,
  REMOTE_CLAUDE_MAX_OUTPUT_CHARS,
  type RemoteClaudeSettings,
} from '@shared/remote-claude'
import { forbiddenToDevices } from '@shared/remote/allow-list'
import type { PortDevice } from '@shared/remote/device'
import { DEFAULT_SETTINGS } from '@shared/settings'
import type { ThreadState } from '@shared/thread'
import { mergeSettings, parseSettingsFile, validateSettingsPatch } from '../../core/settings-schema'
import { portPair } from '../../remote-host/host-sockets'
import type {
  AgentConnection,
  AgentInit,
  McpServer,
  OpenedSession,
  PromptResult,
  SessionOptions,
  SessionTarget,
} from '../connection'
import { writeBranchSlug } from '../session-titles'
import { newTurnScope } from '../session-updates'
import { createValidators } from '../validate'
import { LocalExecMcp } from './executor'
import { closeGlobWorker } from './glob-worker'
import { RemoteClaudeHost } from './host'
import { collectProjectSnapshot, RemoteClaudeConnection, RemoteHostPeer } from './client'
import { normalizeSnapshotPath, prepareShadowWorkspace, sanitizeSnapshotFiles } from './shadow'
import { createRunTunnel } from './tunnel'
import { createWorkspaceMapper, normalizeHostedPatches } from './workspace'

const temps: string[] = []

async function makeTempDir(prefix = 'sarto-rc-'): Promise<string> {
  const dir = await mkdtemp(path.join(os.tmpdir(), prefix))
  temps.push(dir)
  return dir
}

afterEach(async () => {
  await closeGlobWorker()
  await Promise.all(temps.splice(0).map((dir) => rm(dir, { recursive: true, force: true })))
})

describe('remote Claude security boundaries: allow-list, validate, and settings', () => {
  it('forbids local-only remoteClaude methods from paired devices', () => {
    expect(forbiddenToDevices('remoteClaude.hosts', undefined)).toBe(true)
    expect(forbiddenToDevices('remoteClaude.active', undefined)).toBe(true)
    expect(forbiddenToDevices('remoteClaude.disconnectAll', undefined)).toBe(true)
    expect(forbiddenToDevices('remoteClaude.status', undefined)).toBe(false)
    expect(forbiddenToDevices('remoteClaude.open', {})).toBe(false)
  })

  it('rejects modelHostId on non-Claude agents and malformed host ids', () => {
    const validators = createValidators('darwin')
    const validHost = '0123456789abcdef0123456789abcdef'
    expect(() =>
      validators['sessions.create']({
        agentId: 'codex',
        projectPath: '/tmp/p',
        modelHostId: validHost,
      }),
    ).toThrow(/Claude Code/)
    expect(() =>
      validators['sessions.create']({
        agentId: 'claude-code',
        projectPath: '/tmp/p',
        modelHostId: 'not-a-host-id',
      }),
    ).toThrow(/modelHostId/)
    expect(
      validators['sessions.create']({
        agentId: 'claude-code',
        projectPath: '/tmp/p',
        modelHostId: validHost,
      }),
    ).toMatchObject({ agentId: 'claude-code', modelHostId: validHost })
  })

  it('rejects non-Claude agents on remoteClaude.open and invalid status on mcpAnswer', () => {
    const validators = createValidators('darwin')
    expect(() =>
      validators['remoteClaude.open']({
        runId: 'r1',
        sessionId: 's1',
        agentId: 'codex',
        localProjectPath: '/tmp/p',
        localPlatform: 'darwin',
      }),
    ).toThrow(/Claude Code/)
    expect(() =>
      validators['remoteClaude.mcpAnswer']({
        runId: 'r1',
        callId: 1,
        status: 999,
        headers: [],
        body: '{}',
      }),
    ).toThrow(/status/)
  })

  it('defaults remote.claude.enabled to false and validates bounds', () => {
    expect(DEFAULT_SETTINGS.remote.claude).toEqual(DEFAULT_REMOTE_CLAUDE_SETTINGS)
    expect(DEFAULT_SETTINGS.remote.claude.enabled).toBe(false)

    const patch = validateSettingsPatch({
      remote: { claude: { enabled: true, maxConcurrent: 4, idleMinutes: 15 } },
    })
    const applied = mergeSettings(DEFAULT_SETTINGS, patch)
    expect(applied.remote.claude).toEqual({ enabled: true, maxConcurrent: 4, idleMinutes: 15 })

    expect(() => validateSettingsPatch({ remote: { claude: { maxConcurrent: 99 } } })).toThrow(
      /maxConcurrent/,
    )
    expect(() => validateSettingsPatch({ remote: { claude: { idleMinutes: 0 } } })).toThrow(
      /idleMinutes/,
    )

    const parsed = parseSettingsFile({
      version: 1,
      remote: { claude: { enabled: true, maxConcurrent: 2, idleMinutes: 5 } },
    })
    expect(parsed.settings.remote.claude).toEqual({
      enabled: true,
      maxConcurrent: 2,
      idleMinutes: 5,
    })
  })
})

describe('RunTunnel loopback security', () => {
  it('enforces Origin, Host, Bearer token, route, method, and error sanitization', async () => {
    const tunnel = await createRunTunnel(async (req) => {
      if (req.body.includes('boom')) {
        throw new Error('Internal failure at /Users/secret-host/private.key')
      }
      return {
        status: 200,
        headers: [['content-type', 'application/json']],
        body: JSON.stringify({ ok: true, server: req.server }),
      }
    })
    try {
      const execUrl = `${tunnel.url}/mcp/${REMOTE_CLAUDE_EXEC_MCP}`
      // Missing auth -> 401
      const noAuth = await fetch(execUrl, { method: 'POST', body: '{}' })
      expect(noAuth.status).toBe(401)

      // Browser Origin header -> 403
      const withOrigin = await fetch(execUrl, {
        method: 'POST',
        headers: {
          authorization: `Bearer ${tunnel.token}`,
          origin: 'https://evil.example',
        },
        body: '{}',
      })
      expect(withOrigin.status).toBe(403)

      // Unknown route -> 404
      const unknown = await fetch(`${tunnel.url}/mcp/other`, {
        method: 'POST',
        headers: { authorization: `Bearer ${tunnel.token}` },
        body: '{}',
      })
      expect(unknown.status).toBe(404)

      // GET -> 405
      const getReq = await fetch(execUrl, {
        method: 'GET',
        headers: { authorization: `Bearer ${tunnel.token}` },
      })
      expect(getReq.status).toBe(405)

      // Valid POST -> 200
      const ok = await fetch(execUrl, {
        method: 'POST',
        headers: { authorization: `Bearer ${tunnel.token}`, 'content-type': 'application/json' },
        body: '{}',
      })
      expect(ok.status).toBe(200)
      expect(await ok.json()).toEqual({ ok: true, server: 'sarto_exec' })

      // Error must not leak host paths
      const err = await fetch(execUrl, {
        method: 'POST',
        headers: { authorization: `Bearer ${tunnel.token}` },
        body: 'boom',
      })
      expect(err.status).toBe(502)
      const errText = await err.text()
      expect(errText).not.toContain('/Users/secret-host')
    } finally {
      await tunnel.close()
    }
  })
})

describe('Shadow workspace and WorkspaceMapper path boundaries', () => {
  it('blocks path traversal in snapshot files', async () => {
    expect(normalizeSnapshotPath('../etc/passwd')).toBeNull()
    expect(normalizeSnapshotPath('/etc/passwd')).toBeNull()
    expect(normalizeSnapshotPath('a\\b')).toBeNull()
    expect(normalizeSnapshotPath('.claude/rules/style.md')).toBe('.claude/rules/style.md')

    const kept = sanitizeSnapshotFiles([
      { relativePath: '../escape.md', content: 'bad' },
      { relativePath: 'CLAUDE.md', content: '# Project' },
    ])
    expect(kept).toEqual([{ relativePath: 'CLAUDE.md', content: '# Project' }])

    const dataDir = await makeTempDir('sarto-shadow-')
    const shadow = await prepareShadowWorkspace(dataDir, 'dev1', 'sess1')
    try {
      await expect(readFile(path.join(shadow.virtualRoot, 'CLAUDE.md'), 'utf8')).rejects.toThrow()
    } finally {
      await shadow.cleanup()
    }
  })

  it('takes only instruction files, never settings, MCP servers, agents or commands', () => {
    for (const allowed of [
      'CLAUDE.md',
      'CLAUDE.local.md',
      '.claude/CLAUDE.md',
      '.claude/rules/style.md',
      '.claude/rules/web/react.md',
    ]) {
      expect(normalizeSnapshotPath(allowed)).toBe(allowed)
    }
    for (const planted of [
      '.claude/settings.json',
      '.claude/settings.local.json',
      '.mcp.json',
      '.claude/agents/evil.md',
      '.claude/commands/run.md',
      '.claude/skills/x/SKILL.md',
      '.claude/rules/run.sh',
      'src/CLAUDE.md',
      'claude.md',
    ]) {
      expect(normalizeSnapshotPath(planted)).toBeNull()
    }
    expect(
      sanitizeSnapshotFiles([
        { relativePath: '.claude/settings.json', content: '{"apiKeyHelper":"curl evil"}' },
        { relativePath: '.mcp.json', content: '{}' },
        { relativePath: 'CLAUDE.md', content: '# Project' },
      ]),
    ).toEqual([{ relativePath: 'CLAUDE.md', content: '# Project' }])
  })

  it('sends no instruction file that links outside the project', async () => {
    const localRoot = await makeTempDir('sarto-snap-')
    const outsideDir = await makeTempDir('sarto-snap-out-')
    await writeFile(path.join(outsideDir, 'id_rsa'), 'PRIVATE KEY')
    await writeFile(path.join(localRoot, 'AGENTS.md'), '# Shared')
    await symlink(path.join(outsideDir, 'id_rsa'), path.join(localRoot, 'CLAUDE.md'))
    await symlink(path.join(localRoot, 'AGENTS.md'), path.join(localRoot, 'CLAUDE.local.md'))
    expect(await collectProjectSnapshot(localRoot)).toEqual([
      { relativePath: 'CLAUDE.local.md', content: '# Shared' },
    ])
  })

  it('maps virtual paths, detects symlink escapes, and normalizes hosted tool cards', async () => {
    const localRoot = await makeTempDir('sarto-local-')
    const outsideDir = await makeTempDir('sarto-outside-')
    await writeFile(path.join(outsideDir, 'secret.txt'), 'top-secret')
    await symlink(outsideDir, path.join(localRoot, 'escape-link'))

    const mapper = createWorkspaceMapper({
      localRoot,
      remoteRoot: '/remote/shadow/fs',
      localPlatform: 'darwin',
      remotePlatform: 'darwin',
    })

    expect(mapper.toLocalPath('/remote/shadow/fs/src/index.ts')).toBe(
      path.join(localRoot, 'src', 'index.ts'),
    )
    expect(await mapper.isInsideLocalRoot(path.join(localRoot, 'src', 'index.ts'))).toBe(true)
    expect(await mapper.isInsideLocalRoot(path.join(localRoot, 'escape-link', 'secret.txt'))).toBe(
      false,
    )
    expect(await mapper.isInsideLocalRoot(path.join(outsideDir, 'secret.txt'))).toBe(false)
    // A dangling link inside the project that points outside is outside, as writing it would be.
    await symlink(path.join(outsideDir, 'planted.plist'), path.join(localRoot, 'dangling'))
    expect(await mapper.isInsideLocalRoot(path.join(localRoot, 'dangling'))).toBe(false)

    const patches = normalizeHostedPatches(
      [
        {
          op: 'entry.add',
          entry: {
            kind: 'tool',
            id: 't1',
            title: `mcp__${REMOTE_CLAUDE_EXEC_MCP}__Read`,
            toolKind: 'other',
            status: 'completed',
            content: [{ type: 'markdown', markdown: 'Read /remote/shadow/fs/app.ts' }],
            locations: [{ path: '/remote/shadow/fs/app.ts' }],
            permission: null,
            permissionResult: null,
          },
        },
      ],
      mapper,
    )
    const added = patches[0]
    expect(added?.op).toBe('entry.add')
    if (added?.op === 'entry.add' && added.entry.kind === 'tool') {
      expect(added.entry.title).toBe('Read')
      expect(added.entry.toolKind).toBe('read')
      expect(added.entry.locations[0]?.path).toBe(path.join(localRoot, 'app.ts'))
    }
  })
})

describe('LocalExecMcp permissions and output bounds', () => {
  it('enforces plan mode, default write approval, auto unsafe command approval, and truncation', async () => {
    const localRoot = await makeTempDir('sarto-exec-')
    await writeFile(path.join(localRoot, 'hello.txt'), 'hello world\nsecond line')
    const big = 'x'.repeat(REMOTE_CLAUDE_MAX_OUTPUT_CHARS + 5000)
    await writeFile(path.join(localRoot, 'big.txt'), big)

    const mapper = createWorkspaceMapper({
      localRoot,
      remoteRoot: '/shadow/fs',
      localPlatform: 'darwin',
      remotePlatform: 'darwin',
    })
    let mode = 'plan'
    const asked: string[] = []
    let allowNext = false

    const exec = new LocalExecMcp({
      mapper,
      hostName: 'Mac Studio',
      permissionMode: () => mode,
      requestPermission: async (req) => {
        asked.push(req.toolEntryId)
        return allowNext ? { optionId: 'allow_once' } : { optionId: 'reject_once' }
      },
    })

    const callTool = async (name: string, args: Record<string, unknown>) => {
      const res = await exec.handle({
        runId: 'r1',
        callId: 1,
        server: 'sarto_exec',
        headers: [],
        body: JSON.stringify({
          jsonrpc: '2.0',
          id: 1,
          method: 'tools/call',
          params: { name, arguments: args },
        }),
      })
      return JSON.parse(res.body).result as { content: { text: string }[]; isError?: boolean }
    }

    // Plan mode allows read inside workspace, blocks Write
    const readRes = await callTool('Read', { file_path: '/shadow/fs/hello.txt' })
    expect(readRes.isError).toBeUndefined()
    expect(readRes.content[0]?.text).toContain('hello world')

    const planWrite = await callTool('Write', { file_path: '/shadow/fs/out.txt', content: 'hi' })
    expect(planWrite.isError).toBe(true)
    expect(asked).toHaveLength(0)

    // Default mode asks user for Write
    mode = 'default'
    allowNext = false
    const deniedWrite = await callTool('Write', { file_path: '/shadow/fs/out.txt', content: 'hi' })
    expect(deniedWrite.isError).toBe(true)
    expect(asked).toHaveLength(1)

    allowNext = true
    const allowedWrite = await callTool('Write', { file_path: '/shadow/fs/out.txt', content: 'hi' })
    expect(allowedWrite.isError).toBeUndefined()
    expect(await readFile(path.join(localRoot, 'out.txt'), 'utf8')).toBe('hi')

    // Auto mode asks user for unsafe shell commands
    mode = 'auto'
    allowNext = false
    const unsafeBash = await callTool('Bash', { command: 'rm -rf /' })
    expect(unsafeBash.isError).toBe(true)
    expect(asked).toHaveLength(3)

    // Truncates oversized reads to protect Relay bandwidth
    const bigRes = await callTool('Read', { file_path: '/shadow/fs/big.txt' })
    expect(bigRes.content[0]?.text).toContain('[truncated')
    expect(bigRes.content[0]!.text.length).toBeLessThanOrEqual(REMOTE_CLAUDE_MAX_OUTPUT_CHARS + 64)

    // Glob runs in worker thread and skips symbolic links
    await mkdir(path.join(localRoot, 'src'), { recursive: true })
    await writeFile(path.join(localRoot, 'src', 'real.ts'), 'export const x = 1')
    const outsideDir = await makeTempDir('sarto-outside-')
    const outsideFile = path.join(outsideDir, 'secret.ts')
    await writeFile(outsideFile, 'secret')
    await symlink(outsideFile, path.join(localRoot, 'src', 'linked.ts'))
    const globRes = await callTool('Glob', { pattern: '**/*.ts' })
    expect(globRes.isError).toBeUndefined()
    expect(globRes.content[0]?.text).toContain('/shadow/fs/src/real.ts')
    expect(globRes.content[0]?.text).not.toContain('linked.ts')

    exec.close()
  })

  it('never reads or writes through links that leave the project', async () => {
    const localRoot = await makeTempDir('sarto-exec-link-')
    const outsideDir = await makeTempDir('sarto-exec-out-')
    await writeFile(path.join(outsideDir, 'id_rsa'), 'PRIVATE KEY')
    await symlink(path.join(outsideDir, 'id_rsa'), path.join(localRoot, 'key'))
    await symlink(path.join(outsideDir, 'planted.txt'), path.join(localRoot, 'dangling'))
    await writeFile(path.join(localRoot, 'notes.txt'), 'PRIVATE notes')

    const asked: string[] = []
    const exec = new LocalExecMcp({
      mapper: createWorkspaceMapper({
        localRoot,
        remoteRoot: '/shadow/fs',
        localPlatform: 'darwin',
        remotePlatform: 'darwin',
      }),
      hostName: 'Mac Studio',
      permissionMode: () => 'acceptEdits',
      requestPermission: async (req) => {
        asked.push(req.toolEntryId)
        return { optionId: 'reject_once' }
      },
    })
    const callTool = async (name: string, args: Record<string, unknown>) => {
      const res = await exec.handle({
        runId: 'r1',
        callId: 1,
        server: 'sarto_exec',
        headers: [],
        body: JSON.stringify({
          jsonrpc: '2.0',
          id: 1,
          method: 'tools/call',
          params: { name, arguments: args },
        }),
      })
      return JSON.parse(res.body).result as { content: { text: string }[]; isError?: boolean }
    }

    const grep = await callTool('Grep', { pattern: 'PRIVATE', output_mode: 'content' })
    expect(grep.content[0]?.text).toContain('notes.txt')
    expect(grep.content[0]?.text).not.toContain('PRIVATE KEY')

    // Accept-edits allows edits inside the project only; the dangling link's target is outside.
    const write = await callTool('Write', { file_path: 'dangling', content: 'planted' })
    expect(write.isError).toBe(true)
    expect(asked).toHaveLength(1)
    await expect(readFile(path.join(outsideDir, 'planted.txt'), 'utf8')).rejects.toThrow()

    exec.close()
  })
})

describe('RemoteClaudeHost run ownership', () => {
  const base = {
    agentId: 'claude-code' as const,
    localProjectPath: '/work/app',
    localPlatform: 'darwin' as const,
  }
  const laptop: PortDevice = { id: 'a'.repeat(32), name: 'Laptop' }
  const phone: PortDevice = { id: 'b'.repeat(32), name: 'Phone' }

  async function hostWithFakeClaude(maxConcurrent = 4) {
    const remoteData = await makeTempDir('sarto-remote-own-')
    const resumed: string[] = []
    const byCwd = new Map<string, string[]>()
    let next = 0
    let release: (() => void) | null = null
    const connection = {
      isClosed: false,
      hold() {
        return new Promise<void>((resolve) => {
          release = resolve
        })
      },
      async newSession(cwd: string) {
        const id = `cc-${++next}`
        byCwd.set(cwd, [...(byCwd.get(cwd) ?? []), id])
        return { sessionId: id, config: [] }
      },
      async resumeSession(id: string) {
        resumed.push(id)
        return { config: [] }
      },
      async listSessions(cwd: string) {
        const ids = byCwd.get(cwd) ?? []
        return {
          sessions: ids.map((sessionId) => ({ sessionId, title: null, updatedAt: null, cwd })),
          nextCursor: null,
        }
      },
      register() {},
      unregister() {},
      async closeSession() {},
      async setConfigOption() {
        return []
      },
    }
    let gate: Promise<void> | null = null
    const host = new RemoteClaudeHost({
      userDataPath: remoteData,
      platform: 'darwin',
      agents: {
        ensureReady: async () => {
          if (gate) await gate
          return {
            agentId: 'claude-code',
            connection: connection as unknown as AgentConnection,
            init: {} as AgentInit,
            sarto: true,
          }
        },
        list: async () => [],
      },
      claudeOptions: () => [],
      settings: () => ({ enabled: true, maxConcurrent, idleMinutes: 5 }),
      sendToPort: () => {},
      onActiveChanged: () => {},
      log: () => {},
    })
    return {
      host,
      resumed,
      holdOpens() {
        gate = connection.hold()
      },
      releaseOpens() {
        gate = null
        release?.()
      },
    }
  }

  it('resumes only sessions the same device started for the same session on this computer', async () => {
    const { host, resumed } = await hostWithFakeClaude()
    const opened = await host.open('p1', laptop, { ...base, runId: 'r1', sessionId: 'local-1' })
    await host.close('p1', 'r1')
    // The owner's own sessions on this computer, and another device's, are not a device's to take.
    await expect(
      host.open('p1', laptop, {
        ...base,
        runId: 'r2',
        sessionId: 'local-1',
        resumeSessionId: 'owner-local-session',
      }),
    ).rejects.toMatchObject({ code: 'not_found' })
    await expect(
      host.open('p2', phone, {
        ...base,
        runId: 'r3',
        sessionId: 'local-1',
        resumeSessionId: opened.acpSessionId,
      }),
    ).rejects.toMatchObject({ code: 'not_found' })
    expect(resumed).toEqual([])
    expect(host.activeRuns()).toHaveLength(0)

    const again = await host.open('p1', laptop, {
      ...base,
      runId: 'r4',
      sessionId: 'local-1',
      resumeSessionId: opened.acpSessionId,
    })
    expect(again.virtualRoot).toBe(opened.virtualRoot)
    expect(resumed).toEqual([opened.acpSessionId])
    await host.shutdown()
  })

  it('counts runs still opening against the limit, refuses duplicate ids, and abandons opens when disabled or disconnected', async () => {
    const { host, holdOpens, releaseOpens } = await hostWithFakeClaude(1)
    holdOpens()
    const first = host.open('p1', laptop, { ...base, runId: 'r1', sessionId: 'local-1' })
    await expect(
      host.open('p1', laptop, { ...base, runId: 'r1', sessionId: 'local-2' }),
    ).rejects.toMatchObject({ code: 'conflict' })
    await expect(
      host.open('p1', laptop, { ...base, runId: 'r2', sessionId: 'local-2' }),
    ).rejects.toMatchObject({ code: 'busy' })
    releaseOpens()
    await first
    expect(host.activeRuns()).toHaveLength(1)
    await host.close('p1', 'r1')

    holdOpens()
    const disconnectedOpen = host.open('p1', laptop, { ...base, runId: 'r3', sessionId: 'local-3' })
    await new Promise((r) => setTimeout(r, 10))
    host.portClosed('p1')
    releaseOpens()
    await expect(disconnectedOpen).rejects.toMatchObject({ code: 'unavailable' })
    expect(host.activeRuns()).toHaveLength(0)

    holdOpens()
    const disabledOpen = host.open('p1', laptop, { ...base, runId: 'r4', sessionId: 'local-4' })
    await new Promise((r) => setTimeout(r, 10))
    await host.updateSettings({ enabled: false, maxConcurrent: 1, idleMinutes: 5 })
    releaseOpens()
    await expect(disabledOpen).rejects.toMatchObject({ code: 'unavailable' })
    expect(host.activeRuns()).toHaveLength(0)

    await host.shutdown()
  })
})

describe('RemoteClaudeHost <-> RemoteClaudeConnection end-to-end hosted flow', () => {
  it('hosts Claude Code with disallowed local tools, executes tools locally over RunTunnel, and resumes after idle reclaim', async () => {
    const localProject = await makeTempDir('sarto-proj-')
    const remoteData = await makeTempDir('sarto-remote-data-')
    await writeFile(path.join(localProject, 'CLAUDE.md'), '# Local Instructions')
    await writeFile(path.join(localProject, 'note.txt'), 'initial-text')

    let hostSettings: RemoteClaudeSettings = { enabled: false, maxConcurrent: 1, idleMinutes: 5 }
    let nowMs = 1_700_000_000_000
    let openedCount = 0
    const receivedOptions: SessionOptions[] = []

    // Fake ClaudeConnection on remote host that verifies hosted isolation and calls RunTunnel MCP.
    const targets = new Map<string, SessionTarget>()
    const sessionMcp = new Map<string, { url: string; token: string }>()
    const sessionCwds = new Map<string, string>()
    // Claude Code connects a hosted run's MCP servers before its session opens, as
    // ClaudeConnection awaits them, and leaves out a server that does not answer in time.
    const handshakes: string[] = []
    const connectMcp = async (server: McpServer | undefined): Promise<void> => {
      if (server?.type !== 'http') return
      const auth = server.headers.find((h) => h.name === 'Authorization')?.value ?? ''
      const status = await fetch(server.url, {
        method: 'POST',
        headers: { authorization: auth, 'content-type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 0, method: 'initialize', params: {} }),
        signal: AbortSignal.timeout(1_000),
      }).then(
        (res) => String(res.status),
        (error: unknown) => (error as Error).name,
      )
      handshakes.push(status)
    }
    const fakeClaude: AgentConnection = {
      closed: new Promise(() => {}),
      isClosed: false,
      hiddenSessions: false,
      unpromptedSessions: false,
      close() {},
      async initialize(): Promise<AgentInit> {
        return {
          name: 'Claude Code',
          version: '2.0.0',
          capabilities: {
            loadSession: false,
            listSessions: false,
            resumeSession: true,
            closeSession: true,
            deleteSession: false,
            forkSession: false,
            forkAtMessage: false,
            ownTitles: null,
            logout: false,
            steering: false,
            mcpHttp: true,
            mcpSse: false,
            mcpStdio: false,
            prompt: { image: true, audio: false, embeddedContext: true },
          },
          authMethods: [],
          raw: {},
        }
      },
      async authenticate() {},
      async logout() {},
      async newSession(cwd, options = {}): Promise<OpenedSession> {
        openedCount += 1
        receivedOptions.push(options)
        const id = `cc-session-${openedCount}`
        sessionCwds.set(id, cwd)
        const execServer = options.mcpServers?.find(
          (s) => s.type === 'http' && s.name === REMOTE_CLAUDE_EXEC_MCP,
        )
        if (execServer && execServer.type === 'http') {
          const auth = execServer.headers.find((h) => h.name === 'Authorization')?.value ?? ''
          sessionMcp.set(id, { url: execServer.url, token: auth.replace(/^Bearer /, '') })
        }
        await connectMcp(execServer)
        return {
          sessionId: id,
          config: [
            {
              id: 'model',
              name: 'Model',
              category: 'model',
              type: 'select',
              value: 'claude-sonnet-4-6',
              choices: [{ value: 'claude-sonnet-4-6', name: 'Sonnet 4.6' }],
            },
            {
              id: 'mode',
              name: 'Mode',
              category: 'mode',
              type: 'select',
              value: 'default',
              choices: [
                { value: 'default', name: 'Ask' },
                { value: 'acceptEdits', name: 'Accept Edits' },
              ],
            },
          ],
        }
      },
      async loadSession(sessionId, cwd, options) {
        return this.resumeSession(sessionId, cwd, options)
      },
      async resumeSession(sessionId, _cwd, options = {}) {
        openedCount += 1
        receivedOptions.push(options)
        const execServer = options.mcpServers?.find(
          (s) => s.type === 'http' && s.name === REMOTE_CLAUDE_EXEC_MCP,
        )
        if (execServer && execServer.type === 'http') {
          const auth = execServer.headers.find((h) => h.name === 'Authorization')?.value ?? ''
          sessionMcp.set(sessionId, { url: execServer.url, token: auth.replace(/^Bearer /, '') })
        }
        await connectMcp(execServer)
        return { config: [] }
      },
      async forkSession() {
        throw new Error('unsupported')
      },
      async closeSession() {},
      async deleteSession() {},
      async listSessions(cwd) {
        const sessions = [...sessionCwds]
          .filter(([, at]) => at === cwd)
          .map(([sessionId]) => ({ sessionId, title: null, updatedAt: null, cwd }))
        return { sessions, nextCursor: null }
      },
      register(id, target) {
        targets.set(id, target)
      },
      unregister(id) {
        targets.delete(id)
      },
      reopen() {},
      rootOf: (id) => id,
      async prompt(sessionId: string): Promise<PromptResult> {
        const mcp = sessionMcp.get(sessionId)
        if (!mcp) {
          targets.get(sessionId)?.apply({
            patches: [
              {
                op: 'entry.add',
                entry: {
                  kind: 'agent',
                  id: `hidden-${openedCount}`,
                  markdown: '{"0":"fix-remote-branch"}',
                  attachments: [],
                  streaming: false,
                },
              },
            ],
            effects: [],
          })
          return { stopReason: 'end_turn', tokens: null, models: [] }
        }
        // Remote Claude reads a file on the controller via its loopback RunTunnel!
        const res = await fetch(mcp.url, {
          method: 'POST',
          headers: {
            authorization: `Bearer ${mcp.token}`,
            'content-type': 'application/json',
          },
          body: JSON.stringify({
            jsonrpc: '2.0',
            id: 42,
            method: 'tools/call',
            params: { name: 'Read', arguments: { file_path: 'note.txt' } },
          }),
        })
        const json = (await res.json()) as { result: { content: { text: string }[] } }
        const readText = json.result.content[0]?.text ?? ''
        targets.get(sessionId)?.apply({
          patches: [
            {
              op: 'entry.add',
              entry: {
                kind: 'agent',
                id: `msg-${openedCount}`,
                markdown: `Saw: ${readText}`,
                attachments: [],
                streaming: false,
              },
            },
          ],
          effects: [],
        })
        return { stopReason: 'end_turn', tokens: null, models: [] }
      },
      async collect() {
        return []
      },
      async steer() {
        return 'promptRequired'
      },
      async cancel() {},
      async setMode() {},
      async setConfigOption() {
        return []
      },
      async removeHidden() {},
    }

    const init = await fakeClaude.initialize('1.0.0')
    const [clientPort, hostPort] = portPair()
    const device: PortDevice = { id: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', name: 'MacBook Air' }
    const activeUpdates: number[] = []

    const host = new RemoteClaudeHost({
      userDataPath: remoteData,
      platform: 'darwin',
      agents: {
        ensureReady: async () => ({
          agentId: 'claude-code',
          connection: fakeClaude,
          init,
          sarto: true,
        }),
        list: async () => [],
      },
      claudeOptions: () => [],
      settings: () => hostSettings,
      sendToPort: (_portId, event) => {
        hostPort.send({ type: 'event', event })
      },
      onActiveChanged: (active) => activeUpdates.push(active.length),
      log: () => {},
      now: () => nowMs,
    })

    // Wire hostPort JSON-RPC requests straight to RemoteClaudeHost (simulating AgentHost RPC).
    hostPort.onMessage((raw) => {
      const msg = raw as { type?: string; id?: number; method?: string; params?: unknown }
      if (msg.type !== 'request' || typeof msg.id !== 'number') return
      const id = msg.id
      void (async () => {
        try {
          let result: unknown
          switch (msg.method) {
            case 'remoteClaude.status':
              result = await host.status()
              break
            case 'remoteClaude.open':
              result = await host.open('p1', device, msg.params as never)
              break
            case 'remoteClaude.prompt':
              result = await host.prompt('p1', msg.params as never)
              break
            case 'remoteClaude.close':
              result = await host.close('p1', (msg.params as { runId: string }).runId)
              break
            case 'remoteClaude.mcpAnswer':
              host.mcpAnswer('p1', msg.params as never)
              result = undefined
              break
            default:
              throw new Error(`Unknown method ${msg.method}`)
          }
          hostPort.send({ type: 'response', id, result })
        } catch (error) {
          hostPort.send({
            type: 'error',
            id,
            error: {
              code: (error as { code?: string }).code ?? 'internal',
              message: (error as Error).message,
            },
          })
        }
      })()
    })

    const peer = new RemoteHostPeer('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', clientPort, () => {}, true)
    const conn = new RemoteClaudeConnection(peer, 'Mac Studio', 'claude-code', 'darwin', () => {})

    // 1. Default off -> refused
    await expect(conn.newSession(localProject)).rejects.toThrow(/turned off/)

    // 2. Enable on remote host -> open succeeds with hosted isolation
    hostSettings = { enabled: true, maxConcurrent: 1, idleMinutes: 5 }
    const opened = await conn.newSession(localProject)
    expect(opened.sessionId).toBe('cc-session-1')
    expect(receivedOptions[0]?.hosted?.disallowedTools).toEqual([...HOSTED_CLAUDE_DISALLOWED_TOOLS])
    expect(receivedOptions[0]?.hosted?.disallowedTools).toContain('Agent')
    expect(receivedOptions[0]?.hosted?.disallowedTools).toContain('Task')
    expect(receivedOptions[0]?.hosted?.settingSources).toEqual([])
    expect(receivedOptions[0]?.hosted?.systemPromptAppend).toContain('# Local Instructions')
    expect(receivedOptions[0]?.hosted?.disableAllHooks).toBe(true)
    expect(receivedOptions[0]?.hosted?.inheritSignIn).toBe(true)
    expect(receivedOptions[0]?.hosted?.tools).toEqual([...HOSTED_CLAUDE_TOOLS])
    expect(receivedOptions[0]?.hosted?.tools).not.toContain('Agent')
    expect(host.activeRuns()).toHaveLength(1)

    // 3. Prompt triggers RunTunnel -> LocalExecMcp Read -> returns local file content!
    const receivedPatches: unknown[] = []
    const localThread: ThreadState = {
      session: {
        id: 'local-s1',
        agentId: 'claude-code',
        projectPath: localProject,
        acpSessionId: opened.sessionId,
        status: 'ready',
        title: null,
        config: [],
        commands: [],
        usage: null,
        error: null,
        turnStartedAt: null,
        turnStartUsed: null,
        createdAt: nowMs,
        updatedAt: nowMs,
        parentId: null,
        origin: 'user',
        subagent: null,
        queue: [],
        queuePaused: false,
      },
      byId: {},
      order: [],
    }
    conn.register(opened.sessionId, {
      context: () => ({
        thread: localThread,
        replaying: false,
        cancelling: false,
        scope: newTurnScope(),
        now: nowMs,
        nextId: () => 'e:1',
        sessionIdFor: () => null,
      }),
      apply: (out) => receivedPatches.push(...out.patches),
      requestPermission: async () => ({ optionId: 'allow_once' }),
      send: () => {},
      startMode: () => 'default',
    })

    const turn1 = await conn.prompt(opened.sessionId, [{ type: 'text', text: 'Read note.txt' }])
    expect(turn1.stopReason).toBe('end_turn')
    expect(JSON.stringify(receivedPatches)).toContain('initial-text')

    // 3b. Lightweight hidden queries (branch names, outline titles, drafts) run on the remote
    // host without touching local Claude Code and without consuming `maxConcurrent: 1` user slots.
    const slug = await writeBranchSlug(
      { connection: conn },
      {
        dir: localProject,
        model: { small: true, model: null },
        message: [{ type: 'text', text: 'Fix remote branch naming' }],
        log: () => {},
      },
    )
    expect(slug).toBe('fix-remote-branch')
    expect(host.activeRuns()).toHaveLength(1)
    expect(receivedOptions.at(-1)?.hidden).toBe('titles')
    expect(receivedOptions.at(-1)?.hosted?.tools).toEqual([])

    // 4. Advance clock past idleMinutes -> host reclaims idle run, controller transparently resumes!
    nowMs += 6 * 60_000
    host.sweepIdle()
    await new Promise((r) => setTimeout(r, 20))
    expect(host.activeRuns()).toHaveLength(0)

    await writeFile(path.join(localProject, 'note.txt'), 'updated-after-reclaim')
    const turn2 = await conn.prompt(opened.sessionId, [{ type: 'text', text: 'Read again' }])
    expect(turn2.stopReason).toBe('end_turn')
    expect(openedCount).toBe(3)
    expect(JSON.stringify(receivedPatches)).toContain('updated-after-reclaim')
    // The controller answered the handshake of the first run and of the one that resumed it.
    expect(handshakes).toEqual(['200', '200'])

    // 5. Turning setting off immediately disconnects active runs
    hostSettings = { ...hostSettings, enabled: false }
    await host.updateSettings(hostSettings)
    expect(host.activeRuns()).toHaveLength(0)
    expect(activeUpdates.at(-1)).toBe(0)

    conn.close()
    await host.shutdown()
  })

  it('skips ~/Library, .Trash and macOS bundle directories in Remote Claude Glob and Grep', async () => {
    const home = await makeTempDir('sarto-rc-home-')
    await mkdir(path.join(home, 'Library', 'Group Containers', 'app'), { recursive: true })
    await mkdir(path.join(home, '.Trash'), { recursive: true })
    await mkdir(path.join(home, 'Pictures', 'Photos Library.photoslibrary'), { recursive: true })
    await mkdir(path.join(home, 'proj'), { recursive: true })
    await writeFile(path.join(home, 'Library', 'Group Containers', 'app', 'secret.txt'), 'needle')
    await writeFile(path.join(home, '.Trash', 'gone.txt'), 'needle')
    await writeFile(
      path.join(home, 'Pictures', 'Photos Library.photoslibrary', 'meta.txt'),
      'needle',
    )
    await writeFile(path.join(home, 'proj', 'keep.txt'), 'needle')

    const exec = new LocalExecMcp({
      mapper: createWorkspaceMapper({
        localRoot: home,
        remoteRoot: '/shadow/fs',
        localPlatform: process.platform === 'win32' ? 'win32' : 'darwin',
        remotePlatform: 'darwin',
      }),
      hostName: 'Mac Studio',
      homeDir: home,
      platform: 'darwin',
      permissionMode: () => 'acceptEdits',
      requestPermission: async () => ({ optionId: 'allow_once' }),
    })

    const callTool = async (name: string, args: Record<string, unknown>) => {
      const res = await exec.handle({
        runId: 'r-home',
        callId: 1,
        server: 'sarto_exec',
        headers: [],
        body: JSON.stringify({
          jsonrpc: '2.0',
          id: 1,
          method: 'tools/call',
          params: { name, arguments: args },
        }),
      })
      return JSON.parse(res.body).result as { content: { text: string }[]; isError?: boolean }
    }

    const globRes = await callTool('Glob', { pattern: '**/*.txt' })
    expect(globRes.isError).toBeUndefined()
    expect(globRes.content[0]?.text).toBe('/shadow/fs/proj/keep.txt')

    const grepRes = await callTool('Grep', { pattern: 'needle', output_mode: 'files_with_matches' })
    expect(grepRes.isError).toBeUndefined()
    expect(grepRes.content[0]?.text).toBe('/shadow/fs/proj/keep.txt')
  })
})
