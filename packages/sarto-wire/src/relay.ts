// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Zhengru
//
// Relay protocol 1, written from PROTOCOL.md section 1; each part names the subsection it follows.
// Uses only Web Crypto and the globals Node.js and browsers share.

import { fromBase64Url, isObject, readJsonObject, toBase64Url } from './codec'

type Fields = Record<string, unknown>

// ---- 1.1 Discovery ----

export const relayService = { name: 'sarto', protocol: 1, path: '/v1' } as const

export const relayFeature = {
  hosts: 'hosts',
  drain: 'drain',
  relayTokens: 'relay-tokens',
} as const

export const relayLimit = {
  messageBytes: 65_536,
  devicesPerHost: 16,
  listedHosts: 64,
  profileNameUnits: 64,
  regionsRead: 8,
  featuresKept: 8,
  featureLength: 32,
  accessTokenLength: 4096,
} as const

export const relayTimeoutMs = {
  signIn: 10_000,
  connect: 10_000,
  accept: 10_000,
  tokenGrace: 5 * 60_000,
} as const

export interface Region {
  id: string
  url: string
}

export interface Discovery {
  relay: typeof relayService.name
  protocol: typeof relayService.protocol
  regions: Region[]
  features: string[]
}

/** The origin of an http or https URL that carries no credentials, or null. */
export function httpOrigin(url: string): string | null {
  let parsed: URL
  try {
    parsed = new URL(url)
  } catch {
    return null
  }
  const web = parsed.protocol === 'http:' || parsed.protocol === 'https:'
  return web && parsed.username === '' && parsed.password === '' ? parsed.origin : null
}

/** The socket URL for a path on an origin: `https` becomes `wss`, `http` becomes `ws`. */
export function socketAddress(origin: string, path: string): string {
  return origin.replace(/^http/, 'ws') + path
}

const sized = (value: unknown, most: number): value is string =>
  typeof value === 'string' && value.length >= 1 && value.length <= most

function featureList(listed: unknown[]): string[] {
  return listed
    .slice(0, relayLimit.featuresKept)
    .filter((feature): feature is string => sized(feature, relayLimit.featureLength))
}

const REGION_NAME = /^[a-z0-9][a-z0-9-]{0,31}$/

function asRegion(value: unknown): Region | null {
  if (!isObject(value) || typeof value.id !== 'string' || typeof value.url !== 'string') return null
  const url = REGION_NAME.test(value.id) ? httpOrigin(value.url) : null
  return url === null ? null : { id: value.id, url }
}

/** What `GET /v1` answered, or null when it is not this relay and protocol. */
export function readDiscovery(answer: unknown): Discovery | null {
  if (!isObject(answer) || !Array.isArray(answer.regions)) return null
  if (answer.relay !== relayService.name || answer.protocol !== relayService.protocol) return null
  const regions: Region[] = []
  for (const candidate of answer.regions.slice(0, relayLimit.regionsRead)) {
    const region = asRegion(candidate)
    if (region) regions.push(region)
  }
  return {
    relay: relayService.name,
    protocol: relayService.protocol,
    regions,
    features: Array.isArray(answer.features) ? featureList(answer.features) : [],
  }
}

// ---- 1.2 Identities ----

const SIGNING_KEY_BYTES = 32
const SIGNATURE_BYTES = 64
const CHANNEL_KEY_BYTES = 32
const HOST_ID = /^[a-z2-7]{26}$/
const ISSUED_TOKEN = /^[A-Za-z0-9_-]{16,128}$/
const BASE32_DIGITS = 'abcdefghijklmnopqrstuvwxyz234567'

/** A copy Web Crypto takes whatever buffer backs the bytes. */
const owned = (bytes: Uint8Array): Uint8Array<ArrayBuffer> => new Uint8Array(bytes)

function base32(bytes: Uint8Array): string {
  let text = ''
  let held = 0
  let width = 0
  for (const byte of bytes) {
    held = (held << 8) | byte
    width += 8
    while (width >= 5) {
      width -= 5
      text += BASE32_DIGITS.charAt((held >>> width) & 31)
    }
    held &= (1 << width) - 1
  }
  return width === 0 ? text : text + BASE32_DIGITS.charAt((held << (5 - width)) & 31)
}

/** A host's relay id for its raw Ed25519 public key. */
export async function hostIdFor(publicKey: Uint8Array): Promise<string> {
  if (publicKey.byteLength !== SIGNING_KEY_BYTES) {
    throw new RangeError(`A raw Ed25519 public key is ${SIGNING_KEY_BYTES} bytes`)
  }
  const hash = await crypto.subtle.digest('SHA-256', owned(publicKey))
  return base32(new Uint8Array(hash, 0, 16))
}

export const isHostId = (value: unknown): value is string =>
  typeof value === 'string' && HOST_ID.test(value)

/** A token or nonce as the relay hands them out. */
export function mintToken(): string {
  return toBase64Url(crypto.getRandomValues(new Uint8Array(32)))
}

const isIssuedToken = (value: unknown): value is string =>
  typeof value === 'string' && ISSUED_TOKEN.test(value)

const isBearerToken = (value: unknown): value is string =>
  sized(value, relayLimit.accessTokenLength)

const holdsBytes = (value: unknown, count: number): value is string =>
  typeof value === 'string' && fromBase64Url(value)?.byteLength === count

// ---- 1.3 Sockets and paths ----

export const relayPath = {
  hosts: '/v1/hosts',
  control: (hostId: string): string => `/v1/hosts/${hostId}`,
  connect: (hostId: string): string => `/v1/hosts/${hostId}/connect`,
  accept: (hostId: string, token: string): string => `/v1/hosts/${hostId}/accept/${token}`,
} as const

export const keepalive = { ask: 'ping', answer: 'pong' } as const

// ---- 1.4 Host sign-in ----

export const signInLabel = 'sarto-relay/1'

export interface HostSigner {
  publicKey: Uint8Array
  sign(data: Uint8Array): Promise<Uint8Array>
}

/** What a sign-in signature covers besides the label. */
export interface SignInSubject {
  origin: string
  hostId: string
  nonce: string
}

export interface HostProfile {
  key: string
  name: string
  platform: string
}

export interface SignInMessage {
  type: 'sign-in'
  publicKey: string
  signature: string
  token: string
}

export interface TokenRenewal {
  type: 'token'
  token: string
}

export interface ProfileUpdate {
  type: 'profile'
  profile: HostProfile | null
}

export type FromHost = SignInMessage | TokenRenewal | ProfileUpdate

export interface Challenge {
  type: 'challenge'
  nonce: string
}

export interface Incoming {
  type: 'incoming'
  token: string
}

export interface HostNotice {
  type: 'ready' | 'replaced' | 'drain'
}

export type ToHost = Challenge | Incoming | HostNotice

export function newSeed(): Uint8Array {
  return crypto.getRandomValues(new Uint8Array(SIGNING_KEY_BYTES))
}

/** RFC 8410's PKCS #8 framing of an Ed25519 private key, up to the seed itself. */
const PKCS8_BEFORE_SEED = '302e020100300506032b657004220420'

/** A signer for a 32-byte Ed25519 seed. */
export async function signerFromSeed(seed: Uint8Array): Promise<HostSigner> {
  if (seed.byteLength !== SIGNING_KEY_BYTES) {
    throw new RangeError(`An Ed25519 seed is ${SIGNING_KEY_BYTES} bytes`)
  }
  const framing = PKCS8_BEFORE_SEED.match(/../g) ?? []
  const pkcs8 = Uint8Array.from([...framing.map((pair) => Number.parseInt(pair, 16)), ...seed])
  const key = await crypto.subtle.importKey('pkcs8', pkcs8, 'Ed25519', true, ['sign'])
  const { x } = await crypto.subtle.exportKey('jwk', key)
  const publicKey = typeof x === 'string' ? fromBase64Url(x) : null
  if (publicKey?.byteLength !== SIGNING_KEY_BYTES) {
    throw new Error('The runtime did not give the Ed25519 public key')
  }
  return {
    publicKey,
    sign: async (data) => new Uint8Array(await crypto.subtle.sign('Ed25519', key, owned(data))),
  }
}

/** Whether an Ed25519 signature over the data verifies under a raw public key. */
export async function verifyHostSignature(
  publicKey: Uint8Array,
  signature: Uint8Array,
  data: Uint8Array,
): Promise<boolean> {
  const shaped =
    publicKey.byteLength === SIGNING_KEY_BYTES && signature.byteLength === SIGNATURE_BYTES
  if (!shaped) return false
  try {
    const key = await crypto.subtle.importKey('raw', owned(publicKey), 'Ed25519', false, ['verify'])
    return await crypto.subtle.verify('Ed25519', key, owned(signature), owned(data))
  } catch {
    return false
  }
}

/** The bytes a host signs to sign in: four lines joined by newlines. */
export function signInBytes(subject: SignInSubject): Uint8Array {
  const lines = [signInLabel, subject.origin, subject.hostId, subject.nonce]
  return new TextEncoder().encode(lines.join('\n'))
}

/** A host's answer to the relay's challenge. */
export async function hostSignIn(
  signer: HostSigner,
  subject: SignInSubject,
  token: string,
): Promise<SignInMessage> {
  return {
    type: 'sign-in',
    publicKey: toBase64Url(signer.publicKey),
    signature: toBase64Url(await signer.sign(signInBytes(subject))),
    token,
  }
}

const CONTROL_CHARACTER = /[\u0000-\u001f\u007f-\u009f]/ // eslint-disable-line no-control-regex
const PLATFORM_NAME = /^[a-z0-9_-]{1,32}$/

function asProfile(value: unknown): HostProfile | null {
  if (!isObject(value)) return null
  const { key, name, platform } = value
  if (!holdsBytes(key, CHANNEL_KEY_BYTES)) return null
  if (!sized(name, relayLimit.profileNameUnits) || name !== name.trim()) return null
  if (CONTROL_CHARACTER.test(name)) return null
  return typeof platform === 'string' && PLATFORM_NAME.test(platform)
    ? { key, name, platform }
    : null
}

/**
 * The profile a host sends for its X25519 channel key, with its name made to fit; null when no
 * name is left or the key or platform is not one.
 */
export function profileFor(
  channelKey: Uint8Array,
  rawName: string,
  platform: string,
): HostProfile | null {
  if (channelKey.byteLength !== CHANNEL_KEY_BYTES || !PLATFORM_NAME.test(platform)) return null
  const printable = rawName.replace(new RegExp(CONTROL_CHARACTER, 'g'), '').trim()
  const whole: string[] = []
  let units = 0
  for (const character of printable) {
    units += character.length
    if (units > relayLimit.profileNameUnits) break
    whole.push(character)
  }
  const name = whole.join('').trim()
  return name === '' ? null : { key: toBase64Url(channelKey), name, platform }
}

/** A reader of one direction's text messages: each `type` has its own check. */
function messageReader<Message>(
  checks: Record<string, (fields: Fields) => Message | null>,
): (text: unknown) => Message | null {
  const byType = new Map(Object.entries(checks))
  return (text) => {
    const fields = readJsonObject(text, relayLimit.messageBytes)
    if (!fields || typeof fields.type !== 'string') return null
    return byType.get(fields.type)?.(fields) ?? null
  }
}

/** What a host sent on its control socket, or null for anything malformed. */
export const readFromHost = messageReader<FromHost>({
  'sign-in': ({ publicKey, signature, token }) =>
    holdsBytes(publicKey, SIGNING_KEY_BYTES) &&
    holdsBytes(signature, SIGNATURE_BYTES) &&
    isBearerToken(token)
      ? { type: 'sign-in', publicKey, signature, token }
      : null,
  token: ({ token }) => (isBearerToken(token) ? { type: 'token', token } : null),
  profile: ({ profile }) => {
    if (profile === null) return { type: 'profile', profile: null }
    const listed = asProfile(profile)
    return listed && { type: 'profile', profile: listed }
  },
})

/** What the relay sent a host on its control socket, or null. */
export const readToHost = messageReader<ToHost>({
  challenge: ({ nonce }) => (isIssuedToken(nonce) ? { type: 'challenge', nonce } : null),
  incoming: ({ token }) => (isIssuedToken(token) ? { type: 'incoming', token } : null),
  ready: () => ({ type: 'ready' }),
  replaced: () => ({ type: 'replaced' }),
  drain: () => ({ type: 'drain' }),
})

// ---- 1.5 Device connect ----

export interface DeviceConnect {
  type: 'connect'
  token: string
  features?: string[]
}

/** What a device sends to be joined to a host, asking to hear of a drain. */
export function connectRequest(token: string): DeviceConnect {
  return { type: 'connect', token, features: [relayFeature.drain] }
}

/** A device's connect message, or null; features the relay does not keep are dropped. */
export const readConnect = messageReader<DeviceConnect>({
  connect: ({ token, features }) => {
    if (!isBearerToken(token)) return null
    if (features === undefined) return { type: 'connect', token }
    if (!Array.isArray(features)) return null
    const kept = featureList(features)
    return kept.length === 0
      ? { type: 'connect', token }
      : { type: 'connect', token, features: kept }
  },
})

// ---- 1.6 Close codes ----

export const relayClose = {
  malformed: 4400,
  unauthorized: 4401,
  forbidden: 4403,
  offline: 4404,
  timeout: 4408,
  replaced: 4409,
  too_big: 1009,
  too_many: 4429,
} as const

// ---- 1.7 Host list ----

export interface ListedHost extends HostProfile {
  id: string
}

/** The hosts `GET /v1/hosts` answered, or null when any entry is invalid. */
export function readHostList(answer: unknown): ListedHost[] | null {
  if (!isObject(answer) || !Array.isArray(answer.hosts)) return null
  if (answer.hosts.length > relayLimit.listedHosts) return null
  const hosts: ListedHost[] = []
  for (const entry of answer.hosts) {
    const profile = asProfile(entry)
    const id = profile ? (entry as Fields).id : null
    if (!profile || !isHostId(id)) return null
    hosts.push({ id, ...profile })
  }
  return hosts
}
