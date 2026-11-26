import { afterEach, describe, expect, it } from 'vitest'
import type { PortChannel } from '@shared/port-channel'
import type { PortDevice } from '@shared/remote/device'
import { DEFAULT_SETTINGS } from '@shared/settings'
import { hostSettings } from '../core/settings-schema'
import { DEVICE_RUNNING, DEVICE_WAITING, PortHub, type Handlers, type Validators } from './rpc'
import { startTestHost, type TestHost } from './testing/harness'

const DEVICE: PortDevice = { id: 'a'.repeat(32), name: 'Phone' }

interface Answer {
  type: string
  id: number
  result?: unknown
  error?: { code: string }
}

class FakePort implements PortChannel<unknown> {
  readonly sent: Answer[] = []
  private listener: ((data: unknown) => void) | null = null
  send(message: unknown): void {
    this.sent.push(message as Answer)
  }
  onMessage(listener: (data: unknown) => void): void {
    this.listener = listener
  }
  onClose(): void {}
  close(): void {}
  request(id: number, method: string, params: unknown): void {
    this.listener?.({ type: 'request', id, method, params })
  }
  answer(id: number): Answer | undefined {
    return this.sent.find((message) => message.id === id)
  }
}

/** A handler per method that waits until released, counting its calls. */
function hub(): {
  hub: PortHub
  calls: { method: string; params: unknown }[]
  release: (index?: number) => void
} {
  const calls: { method: string; params: unknown }[] = []
  const waiting: (() => void)[] = []
  const handler = (method: string) => (params: unknown) => {
    calls.push({ method, params })
    return new Promise((resolve) =>
      waiting.push(() => resolve({ method, params, n: calls.length })),
    )
  }
  const handlers = new Proxy({} as Handlers, { get: (_, method: string) => handler(method) })
  const validators = new Proxy({} as Validators, { get: () => (params: unknown) => params })
  return {
    hub: new PortHub({ handlers, validators, closed: () => {}, log: () => {} }),
    calls,
    release: (index = 0) => waiting.splice(index, 1)[0]?.(),
  }
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 0))

const SUMMARY = { dayStarts: [1, 2, 3], from: 1, to: 4, scope: 'computer' }

describe("a paired device's requests", () => {
  it('share one answer while the same read with the same params is in flight', async () => {
    const { hub: h, calls, release } = hub()
    const port = new FakePort()
    h.add(port, DEVICE)
    for (let id = 1; id <= 25; id++) port.request(id, 'usage.summary', SUMMARY)
    await settle()
    expect(calls).toHaveLength(1)
    release()
    await settle()
    expect(port.sent).toHaveLength(25)
    const first = port.answer(1)!.result
    for (let id = 1; id <= 25; id++) {
      expect(port.answer(id)).toMatchObject({ type: 'response', id, result: first })
    }
    // Once answered, the same read runs again.
    port.request(26, 'usage.summary', SUMMARY)
    await settle()
    expect(calls).toHaveLength(2)
  })

  it('run apart when their params differ, and actions always run', async () => {
    const { hub: h, calls } = hub()
    const port = new FakePort()
    h.add(port, DEVICE)
    port.request(1, 'usage.summary', SUMMARY)
    port.request(2, 'usage.summary', { ...SUMMARY, to: 5 })
    port.request(3, 'sessions.rename', { sessionId: 's', title: 't' })
    port.request(4, 'sessions.rename', { sessionId: 's', title: 't' })
    await settle()
    expect(calls.map((call) => call.method)).toEqual([
      'usage.summary',
      'usage.summary',
      'sessions.rename',
      'sessions.rename',
    ])
  })

  it('run at most a bounded number at once, the rest in the order they came', async () => {
    const { hub: h, calls, release } = hub()
    const port = new FakePort()
    h.add(port, DEVICE)
    for (let id = 1; id <= DEVICE_RUNNING + 3; id++) {
      port.request(id, 'usage.summary', { ...SUMMARY, to: 10 + id })
    }
    await settle()
    expect(calls).toHaveLength(DEVICE_RUNNING)
    release()
    await settle()
    expect(calls).toHaveLength(DEVICE_RUNNING + 1)
    expect(calls.at(-1)!.params).toMatchObject({ to: 10 + DEVICE_RUNNING + 1 })
    expect(port.answer(1)).toMatchObject({ type: 'response' })
  })

  it('leave long operations out of the bound, so they never hold the rest back', async () => {
    const { hub: h, calls } = hub()
    const port = new FakePort()
    h.add(port, DEVICE)
    for (let id = 1; id <= DEVICE_RUNNING; id++) {
      port.request(id, 'agents.install', { harnessId: 'codex', id })
    }
    port.request(100, 'usage.summary', SUMMARY)
    await settle()
    expect(calls).toHaveLength(DEVICE_RUNNING + 1)
    expect(calls.at(-1)!.method).toBe('usage.summary')
  })

  it('are refused as busy past the bound of those waiting, with the code clients know', async () => {
    const { hub: h } = hub()
    const port = new FakePort()
    h.add(port, DEVICE)
    const total = DEVICE_RUNNING + DEVICE_WAITING + 2
    for (let id = 1; id <= total; id++) port.request(id, 'usage.summary', { ...SUMMARY, to: id })
    await settle()
    const busy = port.sent.filter((message) => message.error?.code === 'busy')
    expect(busy.map((message) => message.id)).toEqual([total - 1, total])
  })

  it("leave a window's requests as they are", async () => {
    const { hub: h, calls } = hub()
    const port = new FakePort()
    h.add(port)
    for (let id = 1; id <= DEVICE_RUNNING + 5; id++) port.request(id, 'usage.summary', SUMMARY)
    await settle()
    expect(calls).toHaveLength(DEVICE_RUNNING + 5)
  })

  it('do not hold back another device', async () => {
    const { hub: h, calls } = hub()
    const phone = new FakePort()
    const tablet = new FakePort()
    h.add(phone, DEVICE)
    h.add(tablet, { id: 'b'.repeat(32), name: 'Tablet' })
    for (let id = 1; id <= DEVICE_RUNNING + 2; id++) {
      phone.request(id, 'usage.summary', { ...SUMMARY, to: id })
    }
    tablet.request(1, 'usage.summary', SUMMARY)
    await settle()
    expect(calls).toHaveLength(DEVICE_RUNNING + 1)
  })
})

describe('work facts', () => {
  it('reach only a window port that selected them, never a device that asked', () => {
    const { hub: h } = hub()
    const window = new FakePort()
    const game = new FakePort()
    const device = new FakePort()
    h.add(window)
    h.selectEvents(h.add(game), ['work.facts'])
    h.selectEvents(h.add(device, DEVICE), ['work.facts', 'session.removed'])
    h.broadcast({ type: 'work.facts', facts: [] })
    h.broadcast({ type: 'session.removed', sessionId: 's1' })
    const removed = { type: 'event', event: { type: 'session.removed', sessionId: 's1' } }
    expect(game.sent).toEqual([{ type: 'event', event: { type: 'work.facts', facts: [] } }])
    expect(window.sent).toEqual([removed])
    expect(device.sent).toEqual([removed])
  })
})

describe('AgentHost authorization boundaries', () => {
  const hosts: TestHost[] = []

  afterEach(async () => {
    for (const host of hosts.splice(0)) await host.stop()
  })

  it('scopes surfaces referenced in sessions.create to the created session and cleans up on close', async () => {
    const testHost = await startTestHost()
    hosts.push(testHost)
    const window = testHost.connect()

    const first = await window.request('sessions.create', {
      agentId: 'fake-agent',
      projectPath: testHost.project,
      prompt: [
        { type: 'text', text: 'check terminal' },
        { type: 'ref', ref: { kind: 'terminal', terminalId: 'term-1', name: 'zsh' } },
        { type: 'ref', ref: { kind: 'page', tabId: 'tab-1', name: 'App' } },
        { type: 'ref', ref: { kind: 'device', deviceId: 'dev-1', name: 'Sim' } },
      ],
    })
    const second = await window.request('sessions.create', {
      agentId: 'fake-agent',
      projectPath: testHost.project,
    })

    const sharedTerminals = (
      testHost.host as unknown as { sharedTerminals: Map<string, Set<string>> }
    ).sharedTerminals
    const sharedTabs = (testHost.host as unknown as { sharedTabs: Map<string, Set<string>> })
      .sharedTabs
    const sharedDevices = (testHost.host as unknown as { sharedDevices: Map<string, Set<string>> })
      .sharedDevices

    expect(sharedTerminals.get('term-1')?.has(first.id)).toBe(true)
    expect(sharedTerminals.get('term-1')?.has(second.id)).toBe(false)
    expect(sharedTabs.get('tab-1')?.has(first.id)).toBe(true)
    expect(sharedTabs.get('tab-1')?.has(second.id)).toBe(false)
    expect(sharedDevices.get('dev-1')?.has(first.id)).toBe(true)
    expect(sharedDevices.get('dev-1')?.has(second.id)).toBe(false)

    await window.request('sessions.close', { sessionId: first.id })
    expect(sharedTerminals.has('term-1')).toBe(false)
    expect(sharedTabs.has('tab-1')).toBe(false)
    expect(sharedDevices.has('dev-1')).toBe(false)
  })

  it('enforces remote.terminal for paired devices calling projects.setWorktreeSettings', async () => {
    const testHost = await startTestHost()
    hosts.push(testHost)
    await testHost.host.projects.add(testHost.project)
    const device = testHost.connect(DEVICE)

    const worktreeSettings = {
      branchTemplate: 'sarto/{slug}',
      copy: [],
      setup: 'echo hi',
      waitForSetup: false,
    }
    await expect(
      device.request('projects.setWorktreeSettings', {
        path: testHost.project,
        settings: worktreeSettings,
      }),
    ).rejects.toMatchObject({ code: 'forbidden' })

    await testHost.host.updateSettings({
      ...hostSettings(DEFAULT_SETTINGS, 'en'),
      remoteTerminal: true,
    })
    await expect(
      device.request('projects.setWorktreeSettings', {
        path: testHost.project,
        settings: worktreeSettings,
      }),
    ).resolves.toBeUndefined()
  })

  it('allows local desktop browser ports to sign in and configure worktrees while blocking paired remote devices', async () => {
    const testHost = await startTestHost({ agentEnv: { FAKE_AGENT_AUTH: 'required' } })
    hosts.push(testHost)
    await testHost.host.projects.add(testHost.project)

    const remoteDesktop: PortDevice = { id: 'a'.repeat(32), name: 'Remote Mac', browser: true }
    const localDesktop: PortDevice = {
      id: 'b'.repeat(32),
      name: 'Sarto',
      local: true,
      browser: true,
      imageRefs: true,
      toolDigests: true,
    }
    const remote = testHost.connect(remoteDesktop)
    const local = testHost.connect(localDesktop)

    await expect(
      remote.request('agents.authenticate', { agentId: 'fake-agent', methodId: 'fake-login' }),
    ).rejects.toMatchObject({ code: 'forbidden' })
    await expect(
      local.request('agents.authenticate', { agentId: 'fake-agent', methodId: 'fake-login' }),
    ).resolves.toBeUndefined()

    const worktreeSettings = {
      branchTemplate: 'sarto/{slug}',
      copy: [],
      setup: 'echo hi',
      waitForSetup: false,
    }
    await expect(
      remote.request('projects.setWorktreeSettings', {
        path: testHost.project,
        settings: worktreeSettings,
      }),
    ).rejects.toMatchObject({ code: 'forbidden' })
    await expect(
      local.request('projects.setWorktreeSettings', {
        path: testHost.project,
        settings: worktreeSettings,
      }),
    ).resolves.toBeUndefined()
  })
})
