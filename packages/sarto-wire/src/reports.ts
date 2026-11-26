// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Zhengru
//
// The Problem Reports contract shared by Sarto Cloud and its clients: report IDs, limits,
// response shapes, console URLs and GitHub issue URL prefilling. Imports nothing so the server
// runs it directly under Node's type-stripping runtime and shared client code stays portable.

export const REPORT_ID_RE = /^SR-[A-Z0-9]{6}$/
export const REPORT_ANONYMOUS_ACCOUNT_ID = 'anonymous'

export const REPORT_MAX_BUNDLE_BYTES = 50 * 1024 * 1024
export const REPORT_MULTIPART_OVERHEAD_BYTES = 256 * 1024
export const REPORT_MAX_ZIP_ENTRIES = 500
export const REPORT_MAX_ZIP_NAME_LENGTH = 260

export const REPORT_DESCRIPTION_MAX = 10_000
export const REPORT_TITLE_MAX = 140
export const REPORT_VERSION_MAX = 64
export const REPORT_PLATFORM_MAX = 128
export const REPORT_DEVICE_NAME_MAX = 100
export const REPORT_COMMENT_MAX = 4_000
export const REPORT_NOTE_MAX = 1_000
export const REPORT_ISSUE_URL_MAX = 512
export const REPORT_MAX_COMMENTS = 100

export const DEFAULT_REPORT_ISSUE_REPO = 'Rladmsrl/Sarto'
export const REPORT_ISSUE_URL_MAX_LENGTH = 4_500

export const REPORT_STATUSES = [
  'submitted',
  'investigating',
  'confirmed',
  'fixed',
  'wont_fix',
  'closed',
] as const

export type ReportStatus = (typeof REPORT_STATUSES)[number]

export type ReportAuthorRole = 'reporter' | 'maintainer'

export type ReportEventKind = 'created' | 'status_changed' | 'updated' | 'bundle_expired'

export type ReportApiErrorCode =
  | 'unauthorized'
  | 'forbidden'
  | 'not_found'
  | 'invalid_description'
  | 'invalid_field'
  | 'invalid_bundle'
  | 'invalid_multipart'
  | 'invalid_json'
  | 'invalid_content_type'
  | 'report_too_large'
  | 'rate_limited'
  | 'report_limit_reached'
  | 'anonymous_disabled'

export interface ReportBundleFile {
  name: string
  compressedSize: number
  uncompressedSize: number
}

export interface ReportSummary {
  id: string
  accountId: string
  anonymous: boolean
  reporterEmail: string
  reporterName: string
  title: string
  description: string
  version: string
  platform: string
  deviceName: string | null
  status: ReportStatus
  issueUrl: string | null
  fixedInVersion: string | null
  hasBundle: boolean
  bundleFilename: string | null
  bundleSize: number
  bundleSha256: string | null
  bundleFileCount: number
  bundleExpiredAt: number | null
  commentCount: number
  createdAt: number
  updatedAt: number
}

export interface ReportEvent {
  id: number
  reportId: string
  kind: ReportEventKind
  actorRole: ReportAuthorRole | 'system'
  actorName: string
  fromStatus: ReportStatus | null
  toStatus: ReportStatus | null
  note: string | null
  createdAt: number
}

export interface ReportComment {
  id: string
  reportId: string
  authorAccountId: string
  authorName: string
  authorRole: ReportAuthorRole
  body: string
  createdAt: number
}

export interface ReportDetail {
  report: ReportSummary
  bundleFiles: ReportBundleFile[]
  timeline: ReportEvent[]
  comments: ReportComment[]
}

export interface ReportListResponse {
  reports: ReportSummary[]
  total: number
  countsByStatus: Record<ReportStatus, number>
  isMaintainer?: boolean
}

export interface SubmitReportResponse {
  id: string
  anonymous: boolean
}

export function isReportId(value: unknown): value is string {
  return typeof value === 'string' && REPORT_ID_RE.test(value)
}

export function isReportStatus(value: unknown): value is ReportStatus {
  return typeof value === 'string' && (REPORT_STATUSES as readonly string[]).includes(value)
}

export function parseSubmitReportResponse(value: unknown): SubmitReportResponse | null {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return null
  const record = value as Record<string, unknown>
  if (!isReportId(record.id)) return null
  const reportObj =
    typeof record.report === 'object' && record.report !== null && !Array.isArray(record.report)
      ? (record.report as Record<string, unknown>)
      : null
  const anonymous =
    typeof record.anonymous === 'boolean'
      ? record.anonymous
      : reportObj?.anonymous === true || reportObj?.accountId === REPORT_ANONYMOUS_ACCOUNT_ID
  return { id: record.id, anonymous }
}

/** Deep-link URL to a specific report in the Sarto Cloud web console. */
export function reportConsoleUrl(origin: string, id: string): string {
  const base = origin.replace(/\/+$/, '')
  return isReportId(id) ? `${base}/console/#reports/${id}` : `${base}/console/#reports`
}

export interface ReportIssueUrlOptions {
  repo?: string
  reportId?: string | null
  version?: string | null
  os?: string | null
  summary?: string | null
}

/**
 * Builds a GitHub bug-report Issue Form URL prefilled with the private Sarto report id and brief
 * metadata. Bounds the total URL length so browsers and GitHub do not truncate query parameters.
 */
export function reportIssueUrl(options: ReportIssueUrlOptions): string {
  const repo = options.repo?.trim() || DEFAULT_REPORT_ISSUE_REPO
  const base = `https://github.com/${repo}/issues/new`
  const params = new URLSearchParams()
  params.set('template', 'bug.yml')
  if (options.reportId && isReportId(options.reportId)) {
    params.set('report-id', options.reportId)
  }
  if (options.version?.trim()) {
    params.set('version', options.version.trim().slice(0, REPORT_VERSION_MAX))
  }
  if (options.os?.trim()) {
    params.set('os', options.os.trim().slice(0, REPORT_PLATFORM_MAX))
  }

  const build = (summaryText: string | null): string => {
    const next = new URLSearchParams(params.toString())
    if (summaryText) next.set('what-happened', summaryText)
    return `${base}?${next.toString()}`
  }

  const rawSummary = options.summary?.trim() ?? ''
  if (!rawSummary) return build(null)

  let summary = rawSummary.slice(0, 1_500)
  let url = build(summary)
  while (url.length > REPORT_ISSUE_URL_MAX_LENGTH && summary.length > 40) {
    summary = summary.slice(0, Math.floor(summary.length * 0.7)).trimEnd()
    url = build(`${summary}...`)
  }
  return url.length <= REPORT_ISSUE_URL_MAX_LENGTH ? url : build(null)
}
