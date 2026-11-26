import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { HostAdmin, type HostAdminDeps } from './host-admin'
import { SettingsStore } from './settings'

const DEVICE = 'a'.repeat(32)

let dir: string
let settings: SettingsStore
let admin: HostAdmin

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'sarto-host-admin-'))
  settings = await SettingsStore.load(dir)
  // Only the settings are reached by the calls these tests make.
  admin = new HostAdmin({
    settings,
    remoteAlwaysOn: true,
    send: () => {},
  } as unknown as HostAdminDeps)
})

afterEach(async () => {
  await rm(dir, { recursive: true, force: true })
})

const update = (remote: Record<string, unknown>, atThisComputer = false) =>
  admin.answer(DEVICE, 'settings.update', { patch: { remote } }, atThisComputer)

describe('what a device may change of remote access', () => {
  it('never turns the terminal on for devices', async () => {
    expect(settings.get().remote.terminal).toBe(false)
    const answer = await update({ terminal: true })
    expect(answer).toEqual({ error: { code: 'invalid_params', message: expect.any(String) } })
    expect(settings.get().remote.terminal).toBe(false)
  })

  it('never turns the terminal off either, nor with another setting beside it', async () => {
    settings.update({ remote: { terminal: true } })
    expect(await update({ terminal: false, name: 'Studio' })).toHaveProperty('error')
    expect(settings.get().remote.terminal).toBe(true)
    expect(settings.get().remote.name).toBeNull()
  })

  it('never turns off the relay or remote access, which would lock the owner out', async () => {
    settings.update({ remote: { relay: true } })
    expect(await update({ relay: false })).toHaveProperty('error')
    expect(await update({ enabled: false })).toHaveProperty('error')
    expect(settings.get().remote.relay).toBe(true)
  })

  it('still changes the rest of the host settings', async () => {
    expect(await update({ name: 'Studio', relay: true })).toHaveProperty('result')
    expect(settings.get().remote.name).toBe('Studio')
    expect(settings.get().remote.relay).toBe(true)
  })

  it('never lets a device change hosting Claude Code for other computers', async () => {
    expect(await update({ claude: { enabled: true } })).toHaveProperty('error')
    expect(await update({ claude: { maxConcurrent: 8 } })).toHaveProperty('error')
    expect(settings.get().remote.claude.enabled).toBe(false)
    expect(settings.get().remote.claude.maxConcurrent).toBe(3)
    expect(await update({ claude: { enabled: true } }, true)).toHaveProperty('result')
    expect(settings.get().remote.claude.enabled).toBe(true)
  })

  it('lets the owner at this computer turn the terminal on and the relay off', async () => {
    const answer = await update({ terminal: true, relay: false }, true)
    expect(answer).toHaveProperty('result')
    expect(settings.get().remote.terminal).toBe(true)
    expect(settings.get().remote.relay).toBe(false)
  })
})

describe('remote code-execution boundaries when remote terminal is off', () => {
  const stdioServer = {
    id: 'manual:0f8fad5b-d9cb-469f-a165-70867728950e',
    name: 'notes',
    title: 'Notes',
    source: 'manual',
    version: null,
    spec: {
      type: 'stdio',
      command: 'npx',
      args: ['-y', '@example/notes-mcp'],
      env: [],
    },
    agents: 'all',
    on: true,
  }

  it('forbids remote devices from setting agent binaries, shell path, agent env, or stdio MCP servers', async () => {
    expect(settings.get().remote.terminal).toBe(false)
    expect(
      await admin.answer(DEVICE, 'settings.setAgentBinary', {
        harnessId: 'claude-code',
        path: '/usr/bin/env',
      }),
    ).toEqual({ error: { code: 'forbidden', message: expect.any(String) } })
    expect(await admin.answer(DEVICE, 'settings.setShellPath', { path: '/bin/sh' })).toEqual({
      error: { code: 'forbidden', message: expect.any(String) },
    })
    expect(
      await admin.answer(DEVICE, 'marketplace.setAgentEnv', {
        agentId: 'claude-code',
        variable: 'FOO',
        value: 'bar',
      }),
    ).toEqual({ error: { code: 'forbidden', message: expect.any(String) } })
    expect(
      await admin.answer(DEVICE, 'settings.update', {
        patch: { marketplace: { mcp: [stdioServer] } },
      }),
    ).toEqual({ error: { code: 'forbidden', message: expect.any(String) } })
  })

  it('allows toggling an existing stdio MCP server on/off remotely but blocks altering its command or args', async () => {
    // Owner installs the stdio server locally.
    expect(
      await admin.answer(
        DEVICE,
        'settings.update',
        { patch: { marketplace: { mcp: [stdioServer] } } },
        true,
      ),
    ).toHaveProperty('result')
    // Remote device can toggle `on` without modifying spec.
    expect(
      await admin.answer(DEVICE, 'settings.update', {
        patch: { marketplace: { mcp: [{ ...stdioServer, on: false }] } },
      }),
    ).toHaveProperty('result')
    // Remote device cannot change command/args of the stdio server.
    expect(
      await admin.answer(DEVICE, 'settings.update', {
        patch: {
          marketplace: {
            mcp: [{ ...stdioServer, spec: { ...stdioServer.spec, command: '/bin/sh' } }],
          },
        },
      }),
    ).toEqual({ error: { code: 'forbidden', message: expect.any(String) } })
  })

  it('returns invalid_params for malformed marketplace.setAgentEnv requests', async () => {
    expect(
      await admin.answer(
        DEVICE,
        'marketplace.setAgentEnv',
        { agentId: 123, variable: 'FOO', value: 'bar' },
        true,
      ),
    ).toEqual({ error: { code: 'invalid_params', message: expect.any(String) } })
  })
})
