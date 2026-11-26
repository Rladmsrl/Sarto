// Problem reports on the daemon: its own part of the bundle, which its agent host builds, or which
// the daemon builds from the log files alone while that host is down or the daemon is not running,
// plus submitting shelved bundles to Sarto Cloud with redaction on metadata fields.

import { readFile, readdir, rm } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { AccountNetworkError, AccountServiceError } from '@shared/account-api'
import { flushLog, logFolder, redactLogText } from '@shared/log/process-log'
import { writeReport, type ReportShelf } from '@shared/log/report-bundle'
import {
  REPORT_DESCRIPTION_MAX,
  REPORT_TITLE_MAX,
  reportConsoleUrl,
  reportIssueUrl,
  type ReportBuildResult,
  type ReportClientPayload,
  type ReportRequest,
  type ReportSubmitResult,
} from '@shared/report'
import type { SettingsFile } from '@shared/settings'
import type { BuildChannel, DaemonOrigin } from '../core/build-info'
import { computerName } from '../core/system-name'
import type { CloudAccount } from './cloud-account'
import type { HostName, HostStatus } from './control'
import type { Hosts } from './hosts'

/** Where bundles wait for the CLI, desktop app or a device to take them. */
export function reportsFolder(dataPath: string): string {
  return path.join(dataPath, 'reports')
}

export interface DaemonBuildMetadata {
  build?: string | null
  channel?: BuildChannel | null
  commit?: string | null
  origin?: DaemonOrigin | null
}

/** The daemon's own facts: versions, the system and its hosts' state. */
export function daemonPart(
  version: string,
  hosts: Record<HostName | 'remote', HostStatus> | null,
  metadata?: DaemonBuildMetadata,
): Record<string, unknown> {
  return {
    daemon: {
      version,
      ...(metadata?.build ? { build: metadata.build } : {}),
      ...(metadata?.channel ? { channel: metadata.channel } : {}),
      ...(metadata?.commit ? { commit: metadata.commit } : {}),
      ...(metadata?.origin ? { origin: metadata.origin } : {}),
      running: hosts !== null,
    },
    versions: { node: process.versions.node, v8: process.versions.v8 },
    platform: process.platform,
    arch: process.arch,
    osVersion: os.release(),
    environment: { PATH: process.env.PATH ?? null, SHELL: process.env.SHELL ?? null },
    hosts,
  }
}

/** Builds the bundle from the log files alone, into `dir`. */
export function logsOnlyReport(
  request: ReportRequest,
  parent: Record<string, unknown>,
  settings: SettingsFile | null,
  logDir: string | null,
  dir: string,
  client: ReportClientPayload | null = null,
): Promise<ReportBuildResult> {
  return writeReport(
    {
      request,
      now: Date.now(),
      parent,
      settings,
      host: null,
      logDir,
      crashDir: null,
      screenshot: null,
      client,
      redact: redactLogText,
    },
    dir,
  )
}

/** The running daemon's bundle, built by the agent host while it runs. */
export async function daemonReport(
  hosts: Pick<Hosts, 'status' | 'agentReady' | 'report'>,
  options: {
    version: string
    dataPath: string
    settings: SettingsFile
    metadata?: DaemonBuildMetadata
  },
  request: ReportRequest,
  client: ReportClientPayload | null = null,
): Promise<ReportBuildResult> {
  const hasScreenshot = Boolean(client?.screenshot)
  const asked = hasScreenshot
    ? request
    : { ...request, extras: request.extras.filter((extra) => extra !== 'screenshot') }
  const parent = daemonPart(options.version, hosts.status(), options.metadata)
  await flushLog()
  if (hosts.agentReady()) {
    return hosts.report({
      request: asked,
      parent,
      settings: options.settings,
      crashDir: null,
      screenshot: null,
      ...(client ? { client } : {}),
    })
  }
  return logsOnlyReport(
    asked,
    parent,
    options.settings,
    logFolder(),
    reportsFolder(options.dataPath),
    client,
  )
}

function firstLineTitle(description: string): string {
  const line =
    description
      .split('\n')
      .map((item) => item.trim())
      .find((item) => item.length > 0) ?? 'Problem report'
  return line.replace(/\s+/g, ' ').slice(0, REPORT_TITLE_MAX)
}

function defaultPlatformLabel(): string {
  return `${process.platform} ${os.release()} ${process.arch}`
}

/** Submits a shelved bundle to Sarto Cloud, redacting title and description before upload. */
export async function submitShelvedReport(
  shelf: ReportShelf,
  id: string,
  options: {
    cloud: Pick<CloudAccount, 'origin' | 'submitReport'> | null
    version: string
    settings: SettingsFile
    allowAnonymous?: boolean
  },
): Promise<ReportSubmitResult> {
  if (!options.cloud) {
    return { ok: false, reason: 'cloud_off', message: 'Cloud services are unavailable' }
  }
  const shelved = shelf.get(id)
  if (!shelved) {
    return {
      ok: false,
      reason: 'not_found',
      message: 'The prepared report expired; rebuild it and try again',
    }
  }
  if (path.dirname(path.resolve(shelved.file)) !== path.resolve(shelf.dir)) {
    return { ok: false, reason: 'failed', message: 'The prepared report path is invalid' }
  }
  const bytes = await readFile(shelved.file).catch(() => null)
  if (!bytes) {
    return { ok: false, reason: 'not_found', message: 'The prepared report file is missing' }
  }

  const rawDescription = shelved.request?.description ?? 'Problem report'
  const redactedDescription = redactLogText(rawDescription).trim().slice(0, REPORT_DESCRIPTION_MAX)
  const description = redactedDescription || 'Problem report'
  const title = firstLineTitle(description)
  const version = shelved.clientMeta?.version?.trim() || options.version
  const platform = shelved.clientMeta?.platform?.trim() || defaultPlatformLabel()
  const deviceName = options.settings.remote.name?.trim() || (await computerName())

  try {
    const submitted = await options.cloud.submitReport({
      title,
      description,
      version,
      platform,
      deviceName,
      bundle: { filename: 'sarto-report.zip', bytes: new Uint8Array(bytes) },
      ...(options.allowAnonymous !== undefined ? { allowAnonymous: options.allowAnonymous } : {}),
    })
    shelf.drop(id)
    const origin = options.cloud.origin()
    return {
      ok: true,
      id: submitted.id,
      anonymous: submitted.anonymous,
      consoleUrl: submitted.anonymous ? null : reportConsoleUrl(origin, submitted.id),
      issueUrl: reportIssueUrl({
        reportId: submitted.id,
        version,
        os: platform,
        summary: description.slice(0, 600),
      }),
    }
  } catch (error) {
    return mapSubmitError(error)
  }
}

export function mapSubmitError(error: unknown): Extract<ReportSubmitResult, { ok: false }> {
  if (error instanceof AccountNetworkError) {
    return { ok: false, reason: 'network', message: error.message }
  }
  if (error instanceof AccountServiceError) {
    switch (error.code) {
      case 'report_too_large':
        return { ok: false, reason: 'too_large', message: error.message }
      case 'rate_limited':
        return {
          ok: false,
          reason: 'rate_limited',
          message: error.message,
          ...(error.retryAfter !== null ? { retryAfter: error.retryAfter } : {}),
        }
      case 'report_limit_reached':
        return { ok: false, reason: 'limit_reached', message: error.message }
      case 'invalid_bundle':
        return { ok: false, reason: 'invalid_bundle', message: error.message }
      case 'invalid_description':
        return { ok: false, reason: 'invalid_description', message: error.message }
      default:
        return { ok: false, reason: 'service', message: error.message }
    }
  }
  return {
    ok: false,
    reason: 'failed',
    message: error instanceof Error ? error.message : String(error),
  }
}

/** Bundles a run before left behind, which nobody takes any more. */
export async function clearReports(dataPath: string): Promise<void> {
  const dir = reportsFolder(dataPath)
  const names = await readdir(dir).catch(() => [] as string[])
  await Promise.all(names.map((name) => rm(path.join(dir, name), { force: true }).catch(() => {})))
}
