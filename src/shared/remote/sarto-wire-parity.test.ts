// The Sarto server speaks relay protocol 1 and the push gateway's request through
// packages/sarto-wire, an implementation of its own. These checks hold it to the remote host's on
// the same inputs, so the two keep interoperating as either changes.

import { describe, expect, it } from 'vitest'
import * as wireCodec from '../../../packages/sarto-wire/src/codec'
import * as wirePrices from '../../../packages/sarto-wire/src/prices'
import * as wirePush from '../../../packages/sarto-wire/src/push'
import * as wireRelay from '../../../packages/sarto-wire/src/relay'
import * as hostPrices from '../usage-prices'
import * as hostPush from './push'
import * as hostRelay from './relay'

const key32 = (fill: number): Uint8Array => new Uint8Array(32).fill(fill)
const b64 = (bytes: Uint8Array): string => hostRelay.encodeRelayBytes(bytes)

describe('sarto-wire relay matches the remote host', () => {
  it('has the same constants', () => {
    const { relayService, keepalive, relayTimeoutMs, relayLimit, relayFeature } = wireRelay
    const close = wireRelay.relayClose
    expect({
      RELAY_PROTOCOL: relayService.protocol,
      PING: keepalive.ask,
      PONG: keepalive.answer,
      SIGN_IN_TIMEOUT_MS: relayTimeoutMs.signIn,
      CONNECT_TIMEOUT_MS: relayTimeoutMs.connect,
      ACCEPT_TIMEOUT_MS: relayTimeoutMs.accept,
      TOKEN_GRACE_MS: relayTimeoutMs.tokenGrace,
      MAX_RELAY_MESSAGE: relayLimit.messageBytes,
      MAX_DEVICE_CONNECTIONS: relayLimit.devicesPerHost,
      MAX_LISTED_HOSTS: relayLimit.listedHosts,
      MAX_PROFILE_NAME: relayLimit.profileNameUnits,
      HOSTS_FEATURE: relayFeature.hosts,
      DRAIN_FEATURE: relayFeature.drain,
      RELAY_TOKENS_FEATURE: relayFeature.relayTokens,
      SIGN_IN_CONTEXT: wireRelay.signInLabel,
      RELAY_CLOSE: {
        malformed: close.malformed,
        unauthorized: close.unauthorized,
        forbidden: close.forbidden,
        offline: close.offline,
        timeout: close.timeout,
        replaced: close.replaced,
        tooBig: close.too_big,
        tooMany: close.too_many,
      },
    }).toEqual({
      RELAY_PROTOCOL: hostRelay.RELAY_PROTOCOL,
      PING: hostRelay.PING,
      PONG: hostRelay.PONG,
      SIGN_IN_TIMEOUT_MS: hostRelay.SIGN_IN_TIMEOUT_MS,
      CONNECT_TIMEOUT_MS: hostRelay.CONNECT_TIMEOUT_MS,
      ACCEPT_TIMEOUT_MS: hostRelay.ACCEPT_TIMEOUT_MS,
      TOKEN_GRACE_MS: hostRelay.TOKEN_GRACE_MS,
      MAX_RELAY_MESSAGE: hostRelay.MAX_RELAY_MESSAGE,
      MAX_DEVICE_CONNECTIONS: hostRelay.MAX_DEVICE_CONNECTIONS,
      MAX_LISTED_HOSTS: hostRelay.MAX_LISTED_HOSTS,
      MAX_PROFILE_NAME: hostRelay.MAX_PROFILE_NAME,
      HOSTS_FEATURE: hostRelay.HOSTS_FEATURE,
      DRAIN_FEATURE: hostRelay.DRAIN_FEATURE,
      RELAY_TOKENS_FEATURE: hostRelay.RELAY_TOKENS_FEATURE,
      SIGN_IN_CONTEXT: hostRelay.SIGN_IN_CONTEXT,
      RELAY_CLOSE: hostRelay.RELAY_CLOSE,
    })
  })

  it('encodes and decodes bytes the same way', () => {
    for (let length = 0; length < 70; length++) {
      const bytes = Uint8Array.from({ length }, (_, i) => (i * 37 + length) & 0xff)
      expect(wireCodec.toBase64Url(bytes)).toBe(hostRelay.encodeRelayBytes(bytes))
    }
    for (const text of ['', 'A', 'AB', 'ABC', 'ABCD', 'ab-_', 'a+b/', 'AAAA=', '!!']) {
      expect(wireCodec.fromBase64Url(text)).toEqual(hostRelay.decodeRelayBytes(text))
    }
  })

  it('derives host ids, sign-in text and paths the same way', async () => {
    for (let fill = 0; fill < 8; fill++) {
      const key = key32(fill * 31)
      expect(await wireRelay.hostIdFor(key)).toBe(await hostRelay.relayHostId(key))
    }
    expect(
      wireRelay.signInBytes({ origin: 'https://r.example', hostId: 'abc', nonce: 'nonce' }),
    ).toEqual(hostRelay.signInText('https://r.example', 'abc', 'nonce'))
    expect(wireRelay.relayPath.control('x')).toBe(hostRelay.hostSocketPath('x'))
    expect(wireRelay.relayPath.connect('x')).toBe(hostRelay.connectSocketPath('x'))
    expect(wireRelay.relayPath.accept('x', 't')).toBe(hostRelay.acceptSocketPath('x', 't'))
    for (const url of ['https://a.b:8443/x?y', 'http://a', 'ws://a', 'https://u:p@a', 'nope']) {
      expect(wireRelay.httpOrigin(url)).toBe(hostRelay.relayOrigin(url))
    }
    expect(wireRelay.socketAddress('https://a.b', '/v1')).toBe(
      hostRelay.relaySocketUrl('https://a.b', '/v1'),
    )
  })

  it('signs and verifies interchangeably', async () => {
    const seed = await hostRelay.newRelaySeed()
    const hostKey = await hostRelay.importRelayKey(seed)
    const wireKey = await wireRelay.signerFromSeed(seed)
    expect(wireKey.publicKey).toEqual(hostKey.publicKey)
    const data = new TextEncoder().encode('hello')
    const signature = await hostKey.sign(data)
    expect(await wireRelay.verifyHostSignature(hostKey.publicKey, signature, data)).toBe(true)
    expect(
      await hostRelay.verifyRelaySignature(wireKey.publicKey, await wireKey.sign(data), data),
    ).toBe(true)
    expect(await wireRelay.verifyHostSignature(hostKey.publicKey, signature, key32(1))).toBe(false)
    const fresh = await wireRelay.signerFromSeed(wireRelay.newSeed())
    expect(fresh.publicKey).toHaveLength(32)
    const subject = { origin: 'https://r', hostId: 'id', nonce: 'n' }
    expect(await wireRelay.hostSignIn(wireKey, subject, 't')).toEqual(
      await hostRelay.signInMessage(hostKey, 'https://r', 'id', 'n', 't'),
    )
  })

  it('builds host profiles the same way', () => {
    for (const name of [
      'Mac',
      '  padded  ',
      'a\u0000b\u0007c',
      '\u0085\u009f',
      '',
      '   ',
      'x'.repeat(80),
      '😀'.repeat(40),
      `${'y'.repeat(63)}😀`,
      ' a ' + 'b'.repeat(62) + ' c',
    ]) {
      for (const platform of ['darwin', 'Darwin', 'win32', '']) {
        expect(wireRelay.profileFor(key32(2), name, platform), `${name}/${platform}`).toEqual(
          hostRelay.hostProfile(key32(2), name, platform),
        )
      }
    }
    expect(wireRelay.profileFor(new Uint8Array(31), 'Mac', 'darwin')).toBeNull()
  })

  const profile = { key: b64(key32(3)), name: 'Mac', platform: 'darwin' }
  const hostMessages: unknown[] = [
    { type: 'sign-in', publicKey: b64(key32(1)), signature: b64(new Uint8Array(64)), token: 't' },
    { type: 'sign-in', publicKey: b64(key32(1)), signature: b64(new Uint8Array(63)), token: 't' },
    { type: 'sign-in', publicKey: b64(new Uint8Array(31)), signature: b64(new Uint8Array(64)) },
    { type: 'sign-in', publicKey: 1, signature: 2, token: 't' },
    { type: 'token', token: 'x' },
    { type: 'token', token: '' },
    { type: 'token', token: 'x'.repeat(4097) },
    { type: 'profile', profile: null },
    { type: 'profile', profile },
    { type: 'profile', profile: { ...profile, name: ' Mac' } },
    { type: 'profile', profile: { ...profile, name: 'a\u0001' } },
    { type: 'profile', profile: { ...profile, platform: 'Mac OS' } },
    { type: 'profile', profile: { ...profile, key: b64(key32(1)).slice(1) } },
    { type: 'profile' },
    { type: 'challenge', nonce: 'a'.repeat(16) },
    { type: 'challenge', nonce: 'a'.repeat(15) },
    { type: 'challenge', nonce: 'a'.repeat(129) },
    { type: 'incoming', token: 'b'.repeat(43) },
    { type: 'incoming', token: 'b+'.repeat(10) },
    { type: 'ready' },
    { type: 'replaced' },
    { type: 'drain' },
    { type: 'joined' },
    { type: 'connect', token: 't' },
    { type: 'connect', token: 't', features: ['drain', '', 'x'.repeat(33), 3, 'a'] },
    { type: 'connect', token: 't', features: [] },
    { type: 'connect', token: 't', features: 'drain' },
    { type: 'connect', token: 't', features: Array.from({ length: 12 }, (_, i) => `f${i}`) },
    { type: 'connect' },
    [],
    null,
  ]
  const texts: unknown[] = [
    ...hostMessages.map((message) => JSON.stringify(message)),
    'not json',
    '42',
    JSON.stringify({ type: 'token', token: 'x'.repeat(70_000) }),
    7,
  ]

  it('parses every message the same way', () => {
    for (const text of texts) {
      const label = String(text).slice(0, 80)
      expect(wireRelay.readFromHost(text), label).toEqual(hostRelay.parseHostToRelay(text))
      expect(wireRelay.readToHost(text), label).toEqual(hostRelay.parseRelayToHost(text))
      expect(wireRelay.readConnect(text), label).toEqual(hostRelay.parseDeviceToRelay(text))
    }
    expect(wireRelay.connectRequest('t')).toEqual(hostRelay.connectMessage('t'))
  })

  it('parses relay info and host lists the same way', () => {
    const infos: unknown[] = [
      { relay: 'sarto', protocol: 1, regions: [], features: ['hosts'] },
      {
        relay: 'sarto',
        protocol: 1,
        regions: [
          { id: 'main', url: 'https://r.example/path' },
          { id: 'Bad', url: 'https://x' },
          { id: 'eu', url: 'ftp://x' },
          null,
          ...Array.from({ length: 10 }, (_, i) => ({ id: `r${i}`, url: `https://r${i}.x` })),
        ],
        features: ['hosts', '', 'x'.repeat(40), 5, 'drain'],
      },
      { relay: 'sarto', protocol: 1, regions: [] },
      { relay: 'sarto', protocol: 2, regions: [] },
      { relay: 'other', protocol: 1, regions: [] },
      { relay: 'sarto', protocol: 1 },
      null,
    ]
    for (const info of infos) {
      expect(wireRelay.readDiscovery(info)).toEqual(hostRelay.parseRelayInfo(info))
    }
    const id = 'a'.repeat(26)
    const lists: unknown[] = [
      { hosts: [] },
      { hosts: [{ id, ...profile }] },
      { hosts: [{ id: 'A'.repeat(26), ...profile }] },
      { hosts: [{ id, ...profile, name: '' }] },
      { hosts: Array.from({ length: 65 }, () => ({ id, ...profile })) },
      { hosts: 'x' },
      {},
    ]
    for (const list of lists) {
      expect(wireRelay.readHostList(list)).toEqual(hostRelay.parseRelayHosts(list))
    }
  })
})

describe('sarto-wire push matches the remote host', () => {
  it('has the same constants and signed text', () => {
    expect({
      PUSH_PATH: wirePush.pushEndpoint,
      HOST_KEY_HEADER: wirePush.pushHeader.hostKey,
      SIGNATURE_HEADER: wirePush.pushHeader.signature,
      REQUEST_CONTEXT: wirePush.pushSigningLabel,
      MAX_CLOCK_SKEW_MS: wirePush.pushLimit.clockSkewMs,
      MAX_SEALED: wirePush.pushLimit.sealedLength,
      MAX_PUSH_BODY: wirePush.pushLimit.bodyBytes,
    }).toEqual({
      PUSH_PATH: hostPush.PUSH_PATH,
      HOST_KEY_HEADER: hostPush.HOST_KEY_HEADER,
      SIGNATURE_HEADER: hostPush.SIGNATURE_HEADER,
      REQUEST_CONTEXT: hostPush.REQUEST_CONTEXT,
      MAX_CLOCK_SKEW_MS: hostPush.MAX_CLOCK_SKEW_MS,
      MAX_SEALED: hostPush.MAX_SEALED,
      MAX_PUSH_BODY: hostPush.MAX_PUSH_BODY,
    })
    expect(
      wirePush.pushSigningBytes({ origin: 'https://p', hostId: 'id', body: '{"a":1}' }),
    ).toEqual(hostPush.pushRequestText('https://p', 'id', '{"a":1}'))
  })

  it('signs request headers the same way', async () => {
    const seed = await hostRelay.newRelaySeed()
    const hostKey = await hostRelay.importRelayKey(seed)
    const wireKey = await wireRelay.signerFromSeed(seed)
    const subject = { origin: 'https://p', hostId: 'id', body: '{}' }
    expect(await wirePush.signedPushHeaders(wireKey, subject, 'tok')).toEqual(
      await hostPush.pushRequestHeaders(hostKey, 'https://p', 'id', '{}', 'tok'),
    )
  })

  it('parses requests the same way', () => {
    const token = 'ab'.repeat(32)
    const base = { time: 1, token, environment: 'production' }
    const pushes: unknown[] = [
      { type: 'alert', sealed: 'abc', collapse: 'tag-1' },
      { type: 'alert', sealed: 'abc', collapse: '' },
      { type: 'alert', sealed: 'abc' },
      { type: 'alert', sealed: 'a'.repeat(3001), collapse: 'x' },
      { type: 'alert', sealed: 'a=b', collapse: 'x' },
      { type: 'background', sealed: 'abc' },
      { type: 'background', sealed: '' },
      { type: 'liveactivity', event: 'start', sealed: 'a', attributes: 'b' },
      { type: 'liveactivity', event: 'start', sealed: 'a' },
      { type: 'liveactivity', event: 'update', sealed: 'a' },
      { type: 'liveactivity', event: 'end', sealed: 'a' },
      { type: 'liveactivity', event: 'pause', sealed: 'a' },
      { type: 'other', sealed: 'a' },
      null,
    ]
    const bodies: unknown[] = [
      ...pushes.map((push) => JSON.stringify({ ...base, push })),
      JSON.stringify({ ...base, time: -1, push: pushes[0] }),
      JSON.stringify({ ...base, time: 1.5, push: pushes[0] }),
      JSON.stringify({ ...base, token: 'AB'.repeat(32), push: pushes[0] }),
      JSON.stringify({ ...base, token: 'ab'.repeat(15), push: pushes[0] }),
      JSON.stringify({ ...base, environment: 'dev', push: pushes[0] }),
      JSON.stringify({ ...base, environment: 'sandbox', push: pushes[5] }),
      JSON.stringify({ ...base, push: pushes[0], pad: 'x'.repeat(9000) }),
      '[]',
      'nope',
      3,
    ]
    for (const body of bodies) {
      expect(wirePush.readPushSubmission(body), String(body).slice(0, 80)).toEqual(
        hostPush.parsePushRequest(body),
      )
    }
  })
})

describe('sarto-wire prices match the daemon', () => {
  it('derives the same keys and cut', () => {
    const names = [
      'claude-sonnet-4-5-20250929',
      'anthropic/claude-sonnet-4-5-20250929',
      'openrouter/anthropic/claude-sonnet-4-5',
      'gpt-5-2025-08-07',
      'openai/gpt-5/high',
      'gpt-5/high',
      'high',
      'Azure/GPT-4o[eu]',
      'vertex_ai/gemini-2.5-pro',
      'gemini-2.5-pro',
      'b/model-x',
      'a/model-x',
      'model-y',
      '  Model-Y  ',
      '/',
      '[x]',
    ]
    for (const name of names) {
      expect(wirePrices.priceKey(name), name).toBe(hostPrices.normalizePriceModel(name))
    }
    const list: Record<string, unknown> = {}
    names.forEach((name, i) => {
      list[name] = {
        mode: i % 5 === 4 ? 'embedding' : 'chat',
        input_cost_per_token: i === 3 ? '1' : i * 1e-6,
        output_cost_per_token: i * 2e-6,
        cache_read_input_token_cost: i % 2 ? i * 1e-7 : undefined,
        cache_creation_input_token_cost: i % 3 ? i * 3e-7 : Number.NaN,
        ...(i % 4 === 0 ? { cache_creation_input_token_cost_above_1hr: i * 4e-7 } : {}),
      }
    })
    list.broken = null
    expect(wirePrices.cutPriceSnapshot(list, '2026-11-24')).toEqual(
      hostPrices.cutPrices(list, '2026-11-24'),
    )
    expect(wirePrices.cutPriceSnapshot(null, '2026-11-24')).toEqual(
      hostPrices.cutPrices(null, '2026-11-24'),
    )
  })

  it('validates snapshots the same way', () => {
    const models = (
      count: number,
      prices: object = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    ) => Object.fromEntries(Array.from({ length: count }, (_, i) => [`m${i}`, prices]))
    const snapshots: unknown[] = [
      { asOf: '2026-11-24', models: models(100) },
      { asOf: '2026-11-24', models: models(99) },
      {
        asOf: '2026-11-24',
        models: models(100, { input: 0, output: 1, cacheRead: 0, cacheWrite: 0 }),
      },
      { asOf: '2026-11-24', models: models(100, { input: 0, output: 0, cacheRead: 0 }) },
      {
        asOf: '2026-11-24',
        models: models(100, { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cacheWrite1h: -1 }),
      },
      { asOf: '24-11-2026', models: models(100) },
      { asOf: '2026-11-24', models: [] },
      { asOf: '2026-11-24', models: { ...models(100), ['k'.repeat(201)]: models(1).m0 } },
      null,
    ]
    for (const snapshot of snapshots) {
      expect(wirePrices.isPriceSnapshot(snapshot)).toBe(hostPrices.isPriceSnapshot(snapshot))
    }
  })
})
