// A problem report: what the user asks for, and the bundle a host builds from it. Shared by the
// window, main, the hosts and the daemon, so it holds types and checks only.

import {
  DEFAULT_REPORT_ISSUE_REPO,
  REPORT_ANONYMOUS_ACCOUNT_ID,
  REPORT_DESCRIPTION_MAX,
  REPORT_DEVICE_NAME_MAX,
  REPORT_ID_RE,
  REPORT_MAX_BUNDLE_BYTES,
  REPORT_MAX_ZIP_ENTRIES,
  REPORT_MAX_ZIP_NAME_LENGTH,
  REPORT_PLATFORM_MAX,
  REPORT_STATUSES,
  REPORT_TITLE_MAX,
  REPORT_VERSION_MAX,
  isReportId,
  isReportStatus,
  parseSubmitReportResponse,
  reportConsoleUrl,
  reportIssueUrl,
  type ReportApiErrorCode,
  type ReportAuthorRole,
  type ReportBundleFile,
  type ReportComment,
  type ReportDetail,
  type ReportEvent,
  type ReportEventKind,
  type ReportIssueUrlOptions,
  type ReportListResponse,
  type ReportStatus,
  type ReportSummary,
  type SubmitReportResponse,
} from '../../packages/sarto-wire/src/reports'

export {
  DEFAULT_REPORT_ISSUE_REPO,
  REPORT_ANONYMOUS_ACCOUNT_ID,
  REPORT_DESCRIPTION_MAX,
  REPORT_DEVICE_NAME_MAX,
  REPORT_ID_RE,
  REPORT_MAX_BUNDLE_BYTES,
  REPORT_MAX_ZIP_ENTRIES,
  REPORT_MAX_ZIP_NAME_LENGTH,
  REPORT_PLATFORM_MAX,
  REPORT_STATUSES,
  REPORT_TITLE_MAX,
  REPORT_VERSION_MAX,
  isReportId,
  isReportStatus,
  parseSubmitReportResponse,
  reportConsoleUrl,
  reportIssueUrl,
}
export type {
  ReportApiErrorCode,
  ReportAuthorRole,
  ReportBundleFile,
  ReportComment,
  ReportDetail,
  ReportEvent,
  ReportEventKind,
  ReportIssueUrlOptions,
  ReportListResponse,
  ReportStatus,
  ReportSummary,
  SubmitReportResponse,
}

export const REPORT_RANGES = ['hour', 'today', 'twoDays'] as const
export type ReportRangeName = (typeof REPORT_RANGES)[number]

/** A named range ending now, or the span a recording of steps to reproduce covered. */
export type ReportRange = { kind: ReportRangeName } | { kind: 'span'; from: number; to: number }

/** What the user may add, each off unless chosen. */
export const REPORT_EXTRAS = ['titles', 'messages', 'verbose', 'dumps', 'screenshot'] as const
export type ReportExtra = (typeof REPORT_EXTRAS)[number]

/** Where the dialog was opened from an error: the session or agent it was about, and the error. */
export interface ReportContext {
  sessionId: string | null
  agentId: string | null
  error: string | null
}

/** What the dialog was opened from, which a draft of the description starts from. */
export const REPORT_ORIGINS = [
  'turn',
  'error',
  'artifact',
  'usage',
  'host',
  'crash',
  'recording',
] as const
export type ReportOrigin = (typeof REPORT_ORIGINS)[number]

export interface ReportRequest {
  description: string
  range: ReportRange
  extras: ReportExtra[]
  context: ReportContext | null
}

export type ReportFileKind = 'text' | 'image' | 'binary'

export interface ReportFileInfo {
  path: string
  size: number
  kind: ReportFileKind
}

/** A bundle built and kept until it is saved, submitted or dropped. */
export interface PreparedReport {
  id: string
  files: ReportFileInfo[]
  /** The zip's size in bytes. */
  size: number
  /** Count of secrets and home paths masked while building the bundle. */
  redactionCount?: number
}

/** A host's answer to a request for a bundle: where it wrote the zip, and what is in it. */
export type ReportBuildResult =
  | { ok: true; file: string; files: ReportFileInfo[]; size: number; redactionCount?: number }
  | { ok: false; reason: 'too_large' | 'failed'; message: string }

/** Native client crash report text (.ips / .crash) supplied by the desktop app. */
export interface ReportClientCrash {
  name: string
  content: string
}

/** Optional diagnostics captured by the native desktop app for the local report bundle. */
export interface ReportClientPayload {
  appVersion?: string | null
  appBuild?: string | null
  osVersion?: string | null
  hardware?: string | null
  display?: string | null
  clientLog?: string | null
  crashReports?: ReportClientCrash[]
  /** Window PNG screenshot encoded in base64. */
  screenshot?: string | null
}

export type ReportSubmitFailure =
  | 'cloud_off'
  | 'too_large'
  | 'rate_limited'
  | 'limit_reached'
  | 'invalid_bundle'
  | 'invalid_description'
  | 'network'
  | 'service'
  | 'not_found'
  | 'failed'

export type ReportSubmitResult =
  | {
      ok: true
      id: string
      anonymous: boolean
      consoleUrl: string | null
      issueUrl: string
    }
  | {
      ok: false
      reason: ReportSubmitFailure
      message: string
      retryAfter?: number
    }

/** A file of a prepared bundle, as the dialog shows it. */
export type ReportFileView =
  | { kind: 'text'; text: string; truncated: boolean }
  | { kind: 'image'; dataUrl: string }
  | { kind: 'binary' }

/** A description an agent drafts for the user keeps this many characters at most. */
export const REPORT_DRAFT_MAX = 1_500
/** The most a bundle may hold, which is also what the service takes. */
export const REPORT_MAX_BYTES = REPORT_MAX_BUNDLE_BYTES
/** The longest a recording of steps to reproduce runs before it stops by itself. */
export const RECORDING_MAX_MS = 30 * 60 * 1000
/** A bundle another host sends travels as base64 in one message of its channel. */
export const REMOTE_REPORT_MAX_BYTES = 20 * 1024 * 1024

const MAX_CLIENT_LOG_CHARS = 512 * 1024
const MAX_CLIENT_CRASH_COUNT = 5
const MAX_CLIENT_CRASH_CHARS = 512 * 1024
const MAX_CLIENT_SCREENSHOT_B64 = 14 * 1024 * 1024

const HOUR_MS = 60 * 60 * 1000
const MAX_SPAN_MS = 2 * 24 * HOUR_MS
const ID_MAX = 200
/** The error an error screen hands the report, which keeps its start. */
export const REPORT_ERROR_MAX = 4_000

/** The times a range covers, in Unix milliseconds; `today` starts at local midnight. */
export function rangeBounds(range: ReportRange, now: number): { from: number; to: number } {
  switch (range.kind) {
    case 'hour':
      return { from: now - HOUR_MS, to: now }
    case 'today': {
      const midnight = new Date(now)
      midnight.setHours(0, 0, 0, 0)
      return { from: midnight.getTime(), to: now }
    }
    case 'twoDays':
      return { from: now - 2 * 24 * HOUR_MS, to: now }
    case 'span':
      return { from: range.from, to: range.to }
  }
}

export class ReportRequestError extends Error {}

function fail(message: string): never {
  throw new ReportRequestError(message)
}

function record(value: unknown, what: string): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value))
    fail(`${what} is not an object`)
  return value as Record<string, unknown>
}

function optionalText(value: unknown, max: number, what: string): string | null {
  if (value === null || value === undefined) return null
  if (typeof value !== 'string' || value.length > max) fail(`${what} is not text of at most ${max}`)
  return value
}

function parseRange(value: unknown): ReportRange {
  const range = record(value, 'The range')
  if ((REPORT_RANGES as readonly unknown[]).includes(range.kind)) {
    return { kind: range.kind as ReportRangeName }
  }
  if (range.kind !== 'span') fail('The range is not one the dialog offers')
  const { from, to } = range
  if (
    typeof from !== 'number' ||
    typeof to !== 'number' ||
    !Number.isFinite(from) ||
    !Number.isFinite(to) ||
    from > to ||
    to - from > MAX_SPAN_MS
  ) {
    fail('The span is not a range of times')
  }
  return { kind: 'span', from, to }
}

/** A request as it came over IPC, a device's channel or the daemon's socket, checked. */
export function parseReportRequest(value: unknown): ReportRequest {
  const request = record(value, 'The request')
  const description = request.description
  if (typeof description !== 'string' || description.trim() === '') {
    fail('Describe what happened')
  }
  if (description.length > REPORT_DESCRIPTION_MAX) {
    fail(`The description is longer than ${REPORT_DESCRIPTION_MAX} characters`)
  }
  if (!Array.isArray(request.extras)) fail('The extras are not a list')
  const extras = [...new Set(request.extras as unknown[])]
  for (const extra of extras) {
    if (!(REPORT_EXTRAS as readonly unknown[]).includes(extra)) fail('An extra is not one offered')
  }
  let context: ReportContext | null = null
  if (request.context !== null && request.context !== undefined) {
    const raw = record(request.context, 'The context')
    context = {
      sessionId: optionalText(raw.sessionId, ID_MAX, 'The session id'),
      agentId: optionalText(raw.agentId, ID_MAX, 'The agent id'),
      error: optionalText(raw.error, REPORT_ERROR_MAX, 'The error'),
    }
  }
  return {
    description: description.trim(),
    range: parseRange(request.range),
    extras: extras as ReportExtra[],
    context,
  }
}

/** Optional native app diagnostics as they arrive over the control socket, checked. */
export function parseReportClientPayload(value: unknown): ReportClientPayload | null {
  if (value === null || value === undefined) return null
  const raw = record(value, 'The client payload')
  const appVersion = optionalText(raw.appVersion, REPORT_VERSION_MAX, 'appVersion')
  const appBuild = optionalText(raw.appBuild, REPORT_VERSION_MAX, 'appBuild')
  const osVersion = optionalText(raw.osVersion, REPORT_PLATFORM_MAX, 'osVersion')
  const hardware = optionalText(raw.hardware, REPORT_PLATFORM_MAX, 'hardware')
  const display = optionalText(raw.display, REPORT_PLATFORM_MAX, 'display')
  const clientLog = optionalText(raw.clientLog, MAX_CLIENT_LOG_CHARS, 'clientLog')
  const screenshot = optionalText(raw.screenshot, MAX_CLIENT_SCREENSHOT_B64, 'screenshot')
  let crashReports: ReportClientCrash[] | undefined
  if (raw.crashReports !== undefined && raw.crashReports !== null) {
    if (!Array.isArray(raw.crashReports)) fail('crashReports is not a list')
    crashReports = []
    for (const item of raw.crashReports.slice(0, MAX_CLIENT_CRASH_COUNT)) {
      const entry = record(item, 'A crash report')
      const name = optionalText(entry.name, 160, 'crashReports[].name')
      const content = optionalText(entry.content, MAX_CLIENT_CRASH_CHARS, 'crashReports[].content')
      if (!name || !content) fail('A crash report needs a name and content')
      crashReports.push({ name, content })
    }
  }
  return {
    ...(appVersion !== null ? { appVersion } : {}),
    ...(appBuild !== null ? { appBuild } : {}),
    ...(osVersion !== null ? { osVersion } : {}),
    ...(hardware !== null ? { hardware } : {}),
    ...(display !== null ? { display } : {}),
    ...(clientLog !== null ? { clientLog } : {}),
    ...(crashReports !== undefined ? { crashReports } : {}),
    ...(screenshot !== null ? { screenshot } : {}),
  }
}

/** A bundle's file name in the zip: relative, forward slashes, no parent steps. */
export function isReportPath(path: unknown): path is string {
  return (
    typeof path === 'string' &&
    path.length > 0 &&
    path.length <= REPORT_MAX_ZIP_NAME_LENGTH &&
    !path.startsWith('/') &&
    !path.includes('\\') &&
    !path.split('/').some((part) => part === '' || part === '.' || part === '..')
  )
}

export function reportFileKind(path: string): ReportFileKind {
  if (/\.(?:json|log|txt|md|ips|crash)$/i.test(path)) return 'text'
  if (/\.png$/i.test(path)) return 'image'
  return 'binary'
}

function isFileInfo(value: unknown): value is ReportFileInfo {
  if (typeof value !== 'object' || value === null) return false
  const { path, size, kind } = value as Record<string, unknown>
  return (
    isReportPath(path) &&
    typeof size === 'number' &&
    Number.isSafeInteger(size) &&
    size >= 0 &&
    (kind === 'text' || kind === 'image' || kind === 'binary')
  )
}

/** A host's answer as it came over a process boundary, or a failure in its place. */
export function reportBuildResult(value: unknown): ReportBuildResult {
  const failed: ReportBuildResult = {
    ok: false,
    reason: 'failed',
    message: 'The host gave no bundle',
  }
  if (typeof value !== 'object' || value === null) return failed
  const answer = value as Record<string, unknown>
  if (answer.ok === false) {
    return {
      ok: false,
      reason: answer.reason === 'too_large' ? 'too_large' : 'failed',
      message: typeof answer.message === 'string' ? answer.message.slice(0, 2_000) : '',
    }
  }
  if (
    answer.ok !== true ||
    typeof answer.file !== 'string' ||
    !Array.isArray(answer.files) ||
    !answer.files.every(isFileInfo) ||
    typeof answer.size !== 'number'
  ) {
    return failed
  }
  const redactionCount =
    typeof answer.redactionCount === 'number' &&
    Number.isSafeInteger(answer.redactionCount) &&
    answer.redactionCount >= 0
      ? answer.redactionCount
      : undefined
  return {
    ok: true,
    file: answer.file,
    files: answer.files,
    size: answer.size,
    ...(redactionCount !== undefined ? { redactionCount } : {}),
  }
}
