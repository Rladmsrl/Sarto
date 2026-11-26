// The agent host's process: main's messages in over the control channel, the host's out, and each
// client's port as it connects. node-main.ts runs it under Node.js.

import { join } from 'node:path'
import { Worker } from 'node:worker_threads'
import type { HostEvent } from '@shared/agent-host'
import { setLogLevel, setVerboseRecords, writeLog } from '@shared/log/process-log'
import type { AttachmentGrant } from '@shared/attachments'
import type { HostToMain, MainToHost } from '@shared/host-control'
import type { ControlChannel, PortChannel } from '@shared/port-channel'
import type { FromPort } from '@shared/port-rpc'
import type { PortDevice } from '@shared/remote/device'
import type { SyncedUsageSelf } from '@shared/sync/protocol'
import { createGitService } from './git'
import { AgentHost } from './host'
import { nodeThreadWorker } from './threads/store'
import { nodeUsageWorker } from './usage/store'

export interface StartedAgentHost {
  /**
   * A window's port, or a paired device's when `device` names it; it is served once the host has
   * started, and closed if it never was.
   */
  connect(port: PortChannel<FromPort<HostEvent>>, device: PortDevice | null): void
}

function isGrant(value: unknown): value is AttachmentGrant {
  if (typeof value !== 'object' || value === null) return false
  const { grantId, path, kind } = value as Record<string, unknown>
  return (
    typeof grantId === 'string' &&
    typeof path === 'string' &&
    (kind === 'file' || kind === 'folder')
  )
}

function isHostDecision(value: unknown): value is 'session' | 'project' | 'deny' | 'timeout' {
  return value === 'session' || value === 'project' || value === 'deny' || value === 'timeout'
}

export function startAgentHost(control: ControlChannel<MainToHost, HostToMain>): StartedAgentHost {
  const send = (message: HostToMain): void => control.send(message)
  let host: Promise<AgentHost> | null = null

  function init(message: Extract<MainToHost, { type: 'host:init' }>): void {
    if (host) {
      writeLog('warn', 'host', 'host:init arrived twice; ignored')
      return
    }
    host = AgentHost.start({
      userDataPath: message.userDataPath,
      appVersion: message.appVersion,
      platform: message.platform,
      nodeRuntime: message.nodeRuntime,
      fakeAgentPath: message.fakeAgentPath,
      sessionRouterPath: message.sessionRouterPath,
      clineHostPath: message.clineHostPath,
      settings: message.settings,
      baseEnv: process.env,
      // A development run keeps its installs apart from the installed app's.
      ...(message.isPackaged ? {} : { harnessesDir: join(message.userDataPath, 'harnesses') }),
      computer: message.computer ?? null,
      ...(message.userAgent ? { userAgent: message.userAgent } : {}),
      ...(message.disableReports ? { disableReports: true } : {}),
      send,
      git: (deps) => createGitService(deps),
      mirrorTraffic: !message.isPackaged && process.env.SARTO_ACP_LOG === '1',
      threadWorker: (data) =>
        nodeThreadWorker(new Worker(message.threadWorkerPath, { workerData: data })),
      usageWorker: (file) =>
        nodeUsageWorker(
          new Worker(message.usageWorkerPath, {
            workerData: {
              file,
              prices: {
                override: join(message.userDataPath, 'model-prices.json'),
                server: join(message.userDataPath, 'state', 'prices-server.json'),
              },
            },
          }),
        ),
    })
    host.catch((error: unknown) => {
      // Without its state the host cannot run; main restarts it with backoff.
      console.error('Agent host failed to start:', error)
      process.exit(1)
    })
  }

  function withHost(run: (host: AgentHost) => unknown): boolean {
    if (!host) {
      writeLog('warn', 'host', 'A message arrived before host:init')
      return false
    }
    void host.then(run)
    return true
  }

  // A rejection must not end the host, which serves every session.
  process.on('unhandledRejection', (reason) => {
    writeLog('error', 'host', `Unhandled rejection: ${(reason as Error)?.stack ?? String(reason)}`)
  })

  control.onMessage((message) => {
    switch (message.type) {
      case 'host:init':
        init(message)
        break
      case 'host:settings':
        withHost((h) => h.updateSettings(message.settings))
        break
      case 'host:battery':
        if (typeof message.onBattery === 'boolean') {
          const { onBattery } = message
          withHost((h) => h.battery(onBattery))
        }
        break
      case 'host:market-keys':
        withHost((h) => h.setMarketKeys(message.values, message.oauth, message.agentEnv))
        break
      case 'settings-result':
        if (
          Number.isSafeInteger(message.callId) &&
          typeof message.answer === 'object' &&
          message.answer !== null
        ) {
          withHost((h) => h.settingsResult(message.callId, message.answer))
        }
        break
      case 'trash-result':
        if (
          Number.isSafeInteger(message.callId) &&
          (message.error === null || typeof message.error === 'string')
        ) {
          withHost((h) => h.trashResult(message.callId, message.error))
        }
        break
      case 'host:busy-request':
        withHost((h) => h.busy(message.requestId))
        break
      case 'host:report-request':
        if (Number.isSafeInteger(message.requestId)) withHost((h) => void h.report(message))
        break
      case 'host:grant':
        if (Array.isArray(message.grants)) {
          withHost((h) => h.grant(message.requestId, message.grants.filter(isGrant)))
        }
        break
      case 'browser-result':
        if (Number.isSafeInteger(message.callId)) {
          withHost((h) => h.browserResult(message.callId, message.result, message.error))
        }
        break
      case 'device-result':
        if (Number.isSafeInteger(message.callId) && typeof message.answer === 'object') {
          withHost((h) => h.deviceResult(message.callId, message.answer))
        }
        break
      case 'terminal-result':
        if (Number.isSafeInteger(message.callId) && typeof message.answer === 'object') {
          withHost((h) => h.terminalResult(message.callId, message.answer))
        }
        break
      case 'host:browser-waiting':
        if (Number.isSafeInteger(message.callId) && typeof message.waiting === 'boolean') {
          withHost((h) => h.browserWaiting(message.callId, message.waiting))
        }
        break
      case 'host:browser-origin-ask':
        if (Number.isSafeInteger(message.requestId)) {
          withHost((h) =>
            h.browserOriginAsked(message.requestId, message.sessionId, message.origin),
          )
        }
        break
      case 'host:browser-origin-answer':
        if (Number.isSafeInteger(message.requestId) && isHostDecision(message.decision)) {
          withHost((h) => h.browserOriginSettled(message.requestId, message.decision))
        }
        break
      case 'host:device-handed-back':
        if (
          typeof message.sessionId === 'string' &&
          Number.isSafeInteger(message.durationMs) &&
          message.durationMs >= 0
        ) {
          withHost((h) => h.deviceHandedBack(message.sessionId, message.durationMs))
        }
        break
      case 'host:terminal-handed-back':
        if (
          typeof message.sessionId === 'string' &&
          Number.isSafeInteger(message.durationMs) &&
          message.durationMs >= 0
        ) {
          withHost((h) => h.terminalHandedBack(message.sessionId, message.durationMs))
        }
        break
      case 'host:browser-handed-back':
        if (
          typeof message.sessionId === 'string' &&
          Number.isSafeInteger(message.durationMs) &&
          message.durationMs >= 0
        ) {
          withHost((h) => h.browserHandedBack(message.sessionId, message.durationMs))
        }
        break
      case 'host:power':
        withHost((h) => h.power(message.state))
        break
      case 'host:computer-control':
        if (
          typeof message.sessionId === 'string' &&
          (message.action === 'take-over' ||
            message.action === 'hand-back' ||
            message.action === 'stop')
        ) {
          withHost((h) => h.computerControl(message.sessionId, message.action))
        }
        break
      case 'host:computer-frame-request':
        if (Number.isSafeInteger(message.requestId)) {
          withHost((h) => h.computerFrame(message.requestId))
        }
        break
      case 'host:log-level':
        if (message.level === 'debug' || message.level === 'info') setLogLevel(message.level)
        if (typeof message.verbose === 'boolean') setVerboseRecords(message.verbose)
        break
      case 'host:memory-reload':
        withHost((h) => void h.reloadMemory())
        break
      case 'host:usage-export-request':
        if (Number.isSafeInteger(message.requestId)) {
          withHost((h) => void h.exportHostUsage(message.requestId))
        }
        break
      case 'host:remote-usage':
        if (typeof message.devices === 'object' && message.devices !== null) {
          const self = usageSelf(message.self)
          const present = Array.isArray(message.present)
            ? message.present.filter((id): id is string => typeof id === 'string')
            : undefined
          withHost((h) => void h.setRemoteUsage(message.devices, self, present))
        }
        break
      case 'host:hosts-socket':
        if (message.socketPath === null || typeof message.socketPath === 'string') {
          const { socketPath } = message
          withHost((h) => h.setHostsSocket(socketPath))
        }
        break
      case 'host:remote-hosts':
        if (Array.isArray(message.hosts)) {
          const { hosts } = message
          withHost((h) => h.setRemoteHosts(hosts))
        }
        break
      case 'host:permission-answer':
        if (
          typeof message.sessionId === 'string' &&
          typeof message.requestId === 'string' &&
          typeof message.optionId === 'string'
        ) {
          withHost((h) =>
            h.answerPermission(message.sessionId, message.requestId, message.optionId),
          )
        }
        break
      case 'host:shutdown':
        if (!host) {
          send({ type: 'host:stopped' })
          process.exit(0)
        }
        withHost(async (h) => {
          await h.shutdown()
          // Lets host:stopped leave before the process ends.
          setImmediate(() => process.exit(0))
        })
        break
    }
  })

  return {
    connect: (port, device) => {
      if (!withHost((h) => h.connect(port, device))) port.close()
    },
  }
}

/** This Mac as the sync names it, when the message carries one that fits; else null. */
function usageSelf(value: unknown): SyncedUsageSelf | null {
  if (typeof value !== 'object' || value === null) return null
  const { deviceId, deviceName, updatedAt } = value as Record<string, unknown>
  if (typeof deviceId !== 'string' || deviceId === '' || deviceId.length > 64) return null
  if (typeof deviceName !== 'string' || deviceName.length > 200) return null
  return {
    deviceId,
    deviceName,
    updatedAt: typeof updatedAt === 'number' && Number.isFinite(updatedAt) ? updatedAt : null,
  }
}
