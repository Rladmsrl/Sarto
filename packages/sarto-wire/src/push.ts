// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Zhengru
//
// The push gateway's request, written from PROTOCOL.md section 2: what a host posts, what it
// signs and what the gateway checks. The gateway never opens `sealed`.

import { isObject, readJsonObject, toBase64Url } from './codec'
import type { HostSigner } from './relay'

export const pushEndpoint = '/v1/push'

export const pushHeader = { hostKey: 'Sarto-Host-Key', signature: 'Sarto-Signature' } as const

export const pushSigningLabel = 'sarto-push-request/1'

export const pushLimit = {
  bodyBytes: 8192,
  sealedLength: 3000,
  clockSkewMs: 5 * 60_000,
} as const

/** The status each refusal answers with. */
export const pushRefusal = {
  malformed: 400,
  unauthorized: 401,
  signed_out: 403,
  unregistered: 410,
  too_big: 413,
  too_many: 429,
  apns: 502,
  unavailable: 503,
} as const

export type PushRefusalReason = keyof typeof pushRefusal

const APNS_TARGETS = ['production', 'sandbox'] as const

export type ApnsTarget = (typeof APNS_TARGETS)[number]

interface Sealed {
  sealed: string
}

export interface AlertPush extends Sealed {
  type: 'alert'
  collapse: string
}

export interface BackgroundPush extends Sealed {
  type: 'background'
}

export interface ActivityStart extends Sealed {
  type: 'liveactivity'
  event: 'start'
  attributes: string
}

export interface ActivityChange extends Sealed {
  type: 'liveactivity'
  event: 'update' | 'end'
}

export type PushPayload = AlertPush | BackgroundPush | ActivityStart | ActivityChange

export interface PushSubmission {
  time: number
  token: string
  environment: ApnsTarget
  push: PushPayload
}

/** What a push signature covers besides the label. */
export interface PushSubject {
  origin: string
  hostId: string
  body: string
}

const DEVICE_TOKEN_HEX = /^(?:[0-9a-f]{2}){16,200}$/
const COLLAPSE_ID = /^[A-Za-z0-9_-]{1,64}$/
const ENVELOPE_TEXT = /^[A-Za-z0-9_-]+$/

const matches = (value: unknown, pattern: RegExp): value is string =>
  typeof value === 'string' && pattern.test(value)

const isEnvelopeText = (value: unknown): value is string =>
  matches(value, ENVELOPE_TEXT) && value.length <= pushLimit.sealedLength

type PayloadCheck = (fields: Record<string, unknown>, sealed: string) => PushPayload | null

const payloadChecks = new Map<unknown, PayloadCheck>([
  [
    'alert',
    ({ collapse }, sealed) =>
      matches(collapse, COLLAPSE_ID) ? { type: 'alert', sealed, collapse } : null,
  ],
  ['background', (_fields, sealed) => ({ type: 'background', sealed })],
  [
    'liveactivity',
    ({ event, attributes }, sealed) => {
      if (event === 'update' || event === 'end') return { type: 'liveactivity', event, sealed }
      const starts = event === 'start' && isEnvelopeText(attributes)
      return starts ? { type: 'liveactivity', event: 'start', sealed, attributes } : null
    },
  ],
])

function asPayload(value: unknown): PushPayload | null {
  if (!isObject(value) || !isEnvelopeText(value.sealed)) return null
  return payloadChecks.get(value.type)?.(value, value.sealed) ?? null
}

/** The request a host posted, or null for a body the gateway refuses as malformed. */
export function readPushSubmission(body: unknown): PushSubmission | null {
  const fields = readJsonObject(body, pushLimit.bodyBytes)
  if (!fields) return null
  const { time, token, environment } = fields
  if (!Number.isSafeInteger(time) || (time as number) < 0) return null
  if (!matches(token, DEVICE_TOKEN_HEX)) return null
  const target = APNS_TARGETS.find((known) => known === environment)
  const push = target ? asPayload(fields.push) : null
  return target && push ? { time: time as number, token, environment: target, push } : null
}

/** The bytes a host signs for a push: four lines joined by newlines, the last the body. */
export function pushSigningBytes(subject: PushSubject): Uint8Array {
  const lines = [pushSigningLabel, subject.origin, subject.hostId, subject.body]
  return new TextEncoder().encode(lines.join('\n'))
}

/** The headers a host posts a push with. */
export async function signedPushHeaders(
  signer: HostSigner,
  subject: PushSubject,
  accessToken: string,
): Promise<Record<string, string>> {
  const signature = await signer.sign(pushSigningBytes(subject))
  return {
    Authorization: `Bearer ${accessToken}`,
    'Content-Type': 'application/json',
    [pushHeader.hostKey]: toBase64Url(signer.publicKey),
    [pushHeader.signature]: toBase64Url(signature),
  }
}
