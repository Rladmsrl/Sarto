import { rm } from 'node:fs/promises'
import { afterEach, expect, it, vi } from 'vitest'
import type { ThreadEntry } from '@shared/thread'
import { startTestHost, type TestHost } from './testing/harness'
import { tempFolder } from './testing/temp'

// A host starts and restarts; a busy machine takes longer than the 5 s default.
vi.setConfig({ testTimeout: 60_000 })

const hosts: TestHost[] = []
let dir: string | null = null

afterEach(async () => {
  for (const host of hosts.splice(0)) await host.stop()
  if (dir) await rm(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 })
  dir = null
})

const users = (entries: ThreadEntry[]) =>
  entries.flatMap((entry) =>
    entry.kind === 'user' && entry.content[0]?.type === 'text'
      ? [[entry.content[0].text, entry.sarto] as const]
      : [],
  )

it("stores Sarto's own message as Sarto's, across a restart", async () => {
  dir = await tempFolder('sarto-messages-')
  const first = await startTestHost({ userDataPath: dir, sessionTimings: { checkpointMs: 10 } })
  hosts.push(first)
  const window = first.connect()
  const { id } = await window.request('sessions.create', {
    agentId: 'fake-agent',
    projectPath: first.project,
  })
  await window.open(id)
  await window.untilStatus(id, 'ready')
  await first.host.sessions.sendFromSarto(id, 'Continue where you left off.')
  await window.untilStatus(id, 'running')
  await window.untilStatus(id, 'ready')
  await window.request('sessions.prompt', {
    sessionId: id,
    content: [{ type: 'text', text: 'Use the staging branch.' }],
  })
  await window.untilStatus(id, 'running')
  await window.untilStatus(id, 'ready')
  const expected = [
    ['Continue where you left off.', true],
    ['Use the staging branch.', undefined],
  ]
  expect(users(window.entries(id))).toEqual(expected)
  await first.stop()
  hosts.splice(0)

  const second = await startTestHost({ userDataPath: dir, sessionTimings: { checkpointMs: 10 } })
  hosts.push(second)
  const opened = await second.connect().open(id)
  expect(users(opened.entries)).toEqual(expected)
})

it("gives no failed message of Sarto's back to the composer", async () => {
  const host = await startTestHost()
  hosts.push(host)
  const window = host.connect()
  const { id } = await window.request('sessions.create', {
    agentId: 'fake-agent',
    projectPath: host.project,
  })
  await window.open(id)
  await window.untilStatus(id, 'ready')
  await host.host.sessions.sendFromSarto(id, '/error --silent')
  await window.untilEntry(id, (entry) => entry.kind === 'notice' && entry.cause === 'turn_failed')
  expect(await window.request('sessions.takeReturned', { sessionId: id })).toEqual([])
  expect(window.events.some((event) => event.type === 'session.returned')).toBe(false)
})

it("gives no failed message from another session back to the user's composer", async () => {
  const host = await startTestHost()
  hosts.push(host)
  const window = host.connect()
  const { id } = await window.request('sessions.create', {
    agentId: 'fake-agent',
    projectPath: host.project,
  })
  await window.open(id)
  await window.untilStatus(id, 'ready')
  const from = { sessionId: 'sender', title: 'Review' }
  await host.host.sessions.sendFromTool(id, '/error --silent', from, false)
  await window.untilEntry(id, (entry) => entry.kind === 'notice' && entry.cause === 'turn_failed')
  expect(await window.request('sessions.takeReturned', { sessionId: id })).toEqual([])
  expect(window.events.some((event) => event.type === 'session.returned')).toBe(false)
})
