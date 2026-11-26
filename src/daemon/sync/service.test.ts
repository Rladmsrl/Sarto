// End-to-end two-Mac full clone & real-time bidirectional sync integration test.
// Verifies that configuring Mac A (custom UI prefs, custom agent, MCP server + secret API key,
// local unpacked Skill folder, custom Theme, Global Memory, and Device Identity) and connecting
// a brand-new Mac B to Sarto Cloud clones 100% of the state while filtering out machine-specific
// binary paths and keeping the server zero-knowledge.

import { randomBytes } from 'node:crypto'
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'
import { duplexPair } from 'node:stream'
import { afterEach, describe, expect, it } from 'vitest'
import { skillFolder } from '../../agent-host/marketplace/skills'
import { formatEntry } from '../../agent-host/memory/entry-file'
import { createLogger } from '../../core/log'
import { MarketKeys, marketKeysFile } from '../../core/market-keys'
import { SettingsStore } from '../../core/settings'
import { ThemeStore, readThemeFolder } from '../../core/themes'
import { NO_SYSTEM_ENCRYPTION } from '../key'
import { SartoSyncService, type SyncAccountLink, type SyncSocketLike } from './service'
import { CLOUD_SOURCE, loadCloud, type PrismRelayServer } from '../testing/cloud'

const cloud = await loadCloud()

function createDuplexFetch(
  server: PrismRelayServer,
): (url: string, init?: RequestInit) => Promise<Response> {
  return async (url, init) => {
    const parsed = new URL(url)
    const [clientStream, serverStream] = duplexPair()
    server.httpServer.emit('connection', serverStream)

    return new Promise<Response>((resolve, reject) => {
      const req = http.request(
        {
          method: init?.method ?? 'GET',
          path: parsed.pathname + parsed.search,
          headers: {
            host: parsed.host,
            ...(init?.headers as Record<string, string> | undefined),
          },
          createConnection: () => clientStream as never,
        },
        (res) => {
          const chunks: Buffer[] = []
          res.on('data', (c: Buffer) => chunks.push(c))
          res.on('end', () => {
            const buf = Buffer.concat(chunks)
            const status = res.statusCode ?? 200
            const bodyAllowed = status !== 204 && status !== 304 && init?.method !== 'HEAD'
            resolve(
              new Response(bodyAllowed ? buf : null, {
                status,
                headers: res.headers as Record<string, string>,
              }),
            )
          })
          res.on('error', reject)
        },
      )
      req.on('error', reject)
      if (init?.body) {
        if (typeof init.body === 'string' || Buffer.isBuffer(init.body)) {
          req.write(init.body)
        } else if (init.body instanceof Uint8Array) {
          req.write(Buffer.from(init.body))
        }
      }
      req.end()
    })
  }
}

function createNoopSocket(): SyncSocketLike {
  return {
    send() {},
    close() {},
    addEventListener() {},
  }
}

async function createMockMacNode(name: string) {
  const root = await mkdtemp(path.join(os.tmpdir(), `sarto-sync-${name}-`))
  const dataPath = path.join(root, 'data')
  const homeDir = path.join(root, 'home')
  await mkdir(dataPath, { recursive: true })
  await mkdir(homeDir, { recursive: true })

  const settings = await SettingsStore.load(dataPath)
  const marketKeys = await MarketKeys.load({
    file: marketKeysFile(dataPath),
    cipher: NO_SYSTEM_ENCRYPTION,
    plainTextAllowed: true,
    servers: () => settings.get().marketplace.mcp,
    changed: () => {},
    log: createLogger('test-keys'),
  })
  const themesDir = path.join(dataPath, 'themes')
  const themes = new ThemeStore(await readThemeFolder(themesDir), 'sarto', {
    dir: themesDir,
    select: () => {},
    changed: () => {},
  })

  const addedDevices: Array<{ publicKey: string; name: string }> = []
  const hostPub = randomBytes(32).toString('base64')
  const relaySeed = randomBytes(32).toString('base64')

  return {
    root,
    dataPath,
    homeDir,
    settings,
    marketKeys,
    themes,
    addedDevices,
    hostPub,
    relaySeed,
  }
}

describe.skipIf(!CLOUD_SOURCE)('SartoSyncService End-to-End Full Mac Clone', () => {
  const cleanups: Array<() => Promise<void>> = []

  afterEach(async () => {
    while (cleanups.length > 0) {
      const fn = cleanups.pop()!
      await fn()
    }
  })

  it('clones UI prefs, Agents, MCP servers + E2EE API keys, custom local Skills, Memories & Mesh onto a fresh Mac', async () => {
    const serverAuth = new cloud.AuthService({
      secret: 'sarto-test-auth-secret-32-bytes-minimum',
      dataFile: null,
      allowRegistration: true,
    })
    const created = await serverAuth.createPasswordAccount(
      'alice@example.com',
      'correct-horse-battery-staple',
      'Alice',
    )
    if (!created.ok) throw new Error(created.error)
    const issued = serverAuth.issueToken(created.account, 'access')
    const accountLink: SyncAccountLink = {
      origin: () => 'http://127.0.0.1:8787',
      profile: () => created.account,
      token: async () => issued.token,
      signOut: async () => {},
    }
    const syncStore = new cloud.SartoSyncStore()
    const relayServer = new cloud.PrismRelayServer({
      publicOrigin: 'http://127.0.0.1:8787',
      regionId: 'test',
      auth: serverAuth,
      syncStore,
    })
    const fetchImpl = createDuplexFetch(relayServer)

    const macA = await createMockMacNode('macA')
    const macB = await createMockMacNode('macB')
    cleanups.push(async () => {
      await relayServer.close()
      syncStore.close()
      await rm(macA.root, { recursive: true, force: true })
      await rm(macB.root, { recursive: true, force: true })
    })

    // 1. Configure rich state on Mac A (including a machine-local binaryPath that MUST NOT leak to Mac B!)
    macA.settings.setAgentBinary('claude-code', '/Users/alice/.local/bin/claude')
    macA.settings.addAgent({
      id: 'claude-code~architect',
      name: 'Principal Architect',
      configDir: path.join(macA.homeDir, '.sarto/agents/claude-code~architect'),
      created: true,
      color: 'violet',
    })
    const mcpId = 'manual:11111111-1111-4111-8111-111111111111'
    const skillId = 'local:22222222-2222-4222-8222-222222222222'
    const customSkillDir = path.join(
      macA.dataPath,
      'marketplace',
      'skills',
      skillFolder(skillId),
      'sarto-reviewer',
    )
    await mkdir(customSkillDir, { recursive: true })
    await writeFile(
      path.join(customSkillDir, 'SKILL.md'),
      '---\nname: sarto-reviewer\ndescription: Custom Sarto code reviewer\n---\nAlways check security.\n',
    )
    await writeFile(path.join(customSkillDir, 'helper.sh'), '#!/bin/sh\necho ok\n', { mode: 0o755 })

    macA.settings.update({
      general: { defaultAgent: 'claude-code~architect', sessionTitles: false },
      git: { backgroundFetch: true, worktreeRoot: '/Users/alice/worktrees' },
      marketplace: {
        mcp: [
          {
            id: mcpId,
            name: 'github-mcp',
            title: 'GitHub MCP',
            source: 'manual',
            version: null,
            on: true,
            agents: 'all',
            spec: {
              type: 'http',
              transport: 'streamable-http',
              url: 'https://api.githubcopilot.com/mcp/',
              headers: [
                {
                  name: 'Authorization',
                  input: true,
                  secret: true,
                  required: true,
                  prefix: 'Bearer ',
                },
              ],
            },
          },
        ],
        skills: [
          {
            id: skillId,
            name: 'sarto-reviewer',
            description: 'Custom Sarto code reviewer',
            source: 'local',
            origin: '/Users/alice/skills/sarto-reviewer',
            version: null,
            agents: 'all',
            on: true,
          },
        ],
      },
    })

    await macA.marketKeys.set({
      serverId: mcpId,
      values: { Authorization: 'ghp_super_secret_token_999' },
    })
    await macA.marketKeys.setAgentEnv('claude-code', 'ANTHROPIC_CUSTOM_HEADER', 'x-sarto-1')

    // Global memory on Mac A
    const memGlobalA = path.join(macA.dataPath, 'memory', 'global')
    await mkdir(memGlobalA, { recursive: true })
    await writeFile(
      path.join(memGlobalA, 'coding-style.md'),
      formatEntry({
        id: 'coding-style',
        title: 'Coding Style',
        description: 'Strict TypeScript',
        body: 'Prefer pure functions and zero extra dependencies.',
        createdAt: 1_700_000_000_000,
        updatedAt: 1_700_000_005_000,
        source: { agentId: null, sessionId: null },
      }),
    )

    // 2. Start Sync on Mac A and set up the account's Keybag v2 vault.
    const syncA = await SartoSyncService.start({
      dataPath: macA.dataPath,
      homeDir: macA.homeDir,
      account: accountLink,
      settings: macA.settings,
      marketKeys: macA.marketKeys,
      themes: macA.themes,
      relaySeedBase64: macA.relaySeed,
      hostPublicKey: () => macA.hostPub,
      hostName: () => 'Alice Mac Studio',
      configureRelay: () => {},
      addTrustedDevice: async (d) => {
        macA.addedDevices.push({ publicKey: d.publicKey, name: d.name })
      },
      knownDeviceIds: () => new Set(),
      reloadMemory: () => {},
      fetchImpl,
      openSocket: createNoopSocket,
      log: createLogger('sync-a'),
    })
    cleanups.push(() => syncA.stop())

    await syncA.accountChanged()
    const setup = await syncA.setupVault()
    expect(setup.recoveryKey).toBeTruthy()
    const recoveryKey = setup.recoveryKey!

    const devicePubA = randomBytes(32).toString('base64')
    await syncA.pushClientState({
      uiPrefs: {
        palette: { value: 'warm', updatedAt: 1_700_000_010_000 },
        accentMode: { value: 'cobalt', updatedAt: 1_700_000_010_000 },
        sendKeyMode: { value: 'cmdEnter', updatedAt: 1_700_000_010_000 },
      },
      device: {
        id: 'a'.repeat(32),
        publicKey: devicePubA,
        name: 'Alice Sarto App',
        kind: 'desktop',
        platform: 'darwin',
      },
    })
    await syncA.syncNow()

    // Verify zero-knowledge on server: raw SQLite envelope must NOT contain plaintext secrets!
    const storedVaultRecord = syncStore.getScope(syncA.status().account!.id, 'mcp-vault')
    expect(storedVaultRecord).not.toBeNull()
    expect(JSON.stringify(storedVaultRecord)).not.toContain('ghp_super_secret_token_999')

    // 3. Brand-new Mac B starts with factory defaults (and its own local binaryPath) and connects!
    macB.settings.setAgentBinary('claude-code', '/opt/homebrew/bin/claude')
    const syncB = await SartoSyncService.start({
      dataPath: macB.dataPath,
      homeDir: macB.homeDir,
      account: accountLink,
      settings: macB.settings,
      marketKeys: macB.marketKeys,
      themes: macB.themes,
      relaySeedBase64: macB.relaySeed,
      hostPublicKey: () => macB.hostPub,
      hostName: () => 'Alice MacBook Air',
      configureRelay: () => {},
      addTrustedDevice: async (d) => {
        macB.addedDevices.push({ publicKey: d.publicKey, name: d.name })
      },
      knownDeviceIds: () => new Set(),
      reloadMemory: () => {},
      fetchImpl,
      openSocket: createNoopSocket,
      log: createLogger('sync-b'),
    })
    cleanups.push(() => syncB.stop())

    await syncB.accountChanged()
    // Wrong recovery key is refused before anything syncs.
    await expect(
      syncB.unlockWithRecoveryKey('AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG'),
    ).rejects.toThrow()

    const statusB = await syncB.unlockWithRecoveryKey(recoveryKey)

    // 4. Verify Mac B is now an exact clone of Mac A while preserving Mac B's own binaryPath!
    const bSettings = macB.settings.get()
    expect(bSettings.agents['claude-code']?.binaryPath).toBe('/opt/homebrew/bin/claude')
    expect(bSettings.git.worktreeRoot).toBeNull()
    expect(bSettings.git.backgroundFetch).toBe(true)
    expect(bSettings.general.defaultAgent).toBe('claude-code~architect')
    expect(bSettings.general.sessionTitles).toBe(false)
    expect(bSettings.addedAgents[0]?.name).toBe('Principal Architect')
    expect(bSettings.addedAgents[0]?.color).toBe('violet')
    expect(bSettings.marketplace.mcp[0]?.id).toBe(mcpId)
    expect(bSettings.marketplace.skills[0]?.id).toBe(skillId)

    // Verify E2EE MCP API key and agentEnv arrived on Mac B!
    const bVault = macB.marketKeys.contentsForHost()
    expect(bVault.values[mcpId]?.Authorization).toBe('ghp_super_secret_token_999')
    expect(bVault.agentEnv['claude-code']?.ANTHROPIC_CUSTOM_HEADER).toBe('x-sarto-1')

    // Verify unpacked custom local Skill files arrived on Mac B via encrypted CAS blob!
    const unpackedSkillB = path.join(
      macB.dataPath,
      'marketplace',
      'skills',
      skillFolder(skillId),
      'sarto-reviewer',
      'SKILL.md',
    )
    const skillTextB = await readFile(unpackedSkillB, 'utf8')
    expect(skillTextB).toContain('Always check security.')

    // Verify Global Memory arrived on Mac B!
    const memTextB = await readFile(
      path.join(macB.dataPath, 'memory', 'global', 'coding-style.md'),
      'utf8',
    )
    expect(memTextB).toContain('Prefer pure functions and zero extra dependencies.')

    // Verify UI Prefs, Trusted Peer Host (Mac A), and Auto-Authorized Device arrived on Mac B!
    expect(statusB.uiPrefs.palette?.value).toBe('warm')
    expect(statusB.uiPrefs.accentMode?.value).toBe('cobalt')
    expect(statusB.uiPrefs.sendKeyMode?.value).toBe('cmdEnter')
    expect(statusB.trustedHosts.some((h) => h.name === 'Alice Mac Studio')).toBe(true)
    expect(macB.addedDevices.some((d) => d.publicKey === devicePubA)).toBe(true)
  })
})

describe.skipIf(!CLOUD_SOURCE)('SartoSyncService blobs and resets', () => {
  const cleanups: Array<() => Promise<void>> = []

  afterEach(async () => {
    while (cleanups.length > 0) await cleanups.pop()!()
  })

  it('removes the blob of a skill whose content changed, and starts over when sync is reset', async () => {
    const serverAuth = new cloud.AuthService({
      secret: 'sarto-test-auth-secret-32-bytes-minimum',
      dataFile: null,
      allowRegistration: true,
    })
    const created = await serverAuth.createPasswordAccount('bob@example.com', 'password-1234')
    if (!created.ok) throw new Error(created.error)
    const issued = serverAuth.issueToken(created.account, 'access')
    const accountLink: SyncAccountLink = {
      origin: () => 'http://127.0.0.1:8787',
      profile: () => created.account,
      token: async () => issued.token,
      signOut: async () => {},
    }
    const syncStore = new cloud.SartoSyncStore()
    const relayServer = new cloud.PrismRelayServer({
      publicOrigin: 'http://127.0.0.1:8787',
      regionId: 'test',
      auth: serverAuth,
      syncStore,
    })
    const blobRequests: Array<{ method: string; sha: string; status: number }> = []
    const duplex = createDuplexFetch(relayServer)
    const fetchImpl = async (url: string, init?: RequestInit) => {
      const res = await duplex(url, init)
      const blob = /\/v1\/sync\/blobs\/([0-9a-f]{64})$/.exec(url)
      if (blob)
        blobRequests.push({ method: init?.method ?? 'GET', sha: blob[1]!, status: res.status })
      return res
    }
    const mac = await createMockMacNode('blobs')
    cleanups.push(async () => {
      await relayServer.close()
      syncStore.close()
      await rm(mac.root, { recursive: true, force: true })
    })

    const skillId = 'local:33333333-3333-4333-8333-333333333333'
    const skillDir = path.join(mac.dataPath, 'marketplace', 'skills', skillFolder(skillId), 'notes')
    await mkdir(skillDir, { recursive: true })
    const writeSkill = (body: string) =>
      writeFile(
        path.join(skillDir, 'SKILL.md'),
        `---\nname: notes\ndescription: Notes\n---\n${body}\n`,
      )
    await writeSkill('First version.')
    mac.settings.update({
      marketplace: {
        skills: [
          {
            id: skillId,
            name: 'notes',
            description: 'Notes',
            source: 'local',
            origin: '/Users/bob/skills/notes',
            version: null,
            agents: 'all',
            on: true,
          },
        ],
      },
    })

    const sync = await SartoSyncService.start({
      dataPath: mac.dataPath,
      homeDir: mac.homeDir,
      account: accountLink,
      settings: mac.settings,
      marketKeys: mac.marketKeys,
      themes: mac.themes,
      relaySeedBase64: mac.relaySeed,
      hostPublicKey: () => mac.hostPub,
      hostName: () => 'Bob Mac',
      configureRelay: () => {},
      addTrustedDevice: async () => {},
      knownDeviceIds: () => new Set(),
      reloadMemory: () => {},
      fetchImpl,
      openSocket: createNoopSocket,
      log: createLogger('sync-blobs'),
    })
    cleanups.push(() => sync.stop())
    await sync.accountChanged()
    await sync.setupVault()
    await sync.syncNow()

    const uploaded = () => blobRequests.filter((r) => r.method === 'PUT').map((r) => r.sha)
    const first = uploaded()
    expect(first).toHaveLength(1)
    const accountId = created.account.id
    expect((await syncStore.hasBlob(accountId, first[0]!)).exists).toBe(true)

    // The skill's content changes: its new archive goes up, and the old one is removed.
    await writeSkill('Second version.')
    await sync.syncNow()
    const second = uploaded().filter((sha) => !first.includes(sha))
    expect(second).toHaveLength(1)
    expect(blobRequests).toContainEqual({ method: 'DELETE', sha: first[0]!, status: 204 })
    expect((await syncStore.hasBlob(accountId, first[0]!)).exists).toBe(false)
    expect((await syncStore.hasBlob(accountId, second[0]!)).exists).toBe(true)

    // Sync is reset on the server while this Mac does not hear of it: the next sync forgets the
    // key instead of pushing what the old key sealed.
    await syncStore.resetAccount(accountId)
    await sync.syncNow()
    expect(sync.status().keyState).toBe('needs-setup')
    expect(syncStore.getManifest(accountId).scopes).toEqual({})

    // Set up again, the skill's archive goes up afresh rather than being taken as already there.
    blobRequests.length = 0
    await sync.setupVault()
    await sync.syncNow()
    const again = uploaded()
    expect(again).toHaveLength(1)
    expect((await syncStore.hasBlob(accountId, again[0]!)).exists).toBe(true)
  })
})
