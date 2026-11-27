// `sarto update`: moves a daemon the install script installed to the latest release on its channel
// by verifying a signed daemon manifest (or falling back to the legacy `/latest` redirect on
// older release servers) and running that release's signed install script.

import path from 'node:path'
import { verifySignature } from '../core/signature'
import {
  compareVersions,
  isBetaVersion,
  isChannelVersion,
  type UpdateChannel,
} from '../core/versions'
import KEYS from '../../tools/sarto/update-keys.json'

/** Names the one place to download releases from, laid out as GitHub's, as for install.sh. */
export const RELEASES_ENV = 'SARTO_RELEASES_URL'
/** Sarto's release source, served by the official Sarto server. */
export const DOWNLOADS = 'https://sarto.1o.ink/releases'
/** Sarto's release signing keys (current and next) from update-keys.json. */
export const RELEASE_KEYS: readonly string[] = [KEYS.release.current, KEYS.release.next]

/** Signed daemon manifest filenames per release channel. */
export const DAEMON_MANIFEST_NAME: Record<UpdateChannel, string> = {
  stable: 'latest-daemon.json',
  beta: 'beta-daemon.json',
}

// The latest release's manifest, redirect and install script are small; a place this slow is down.
const REQUEST_TIMEOUT_MS = 20_000
const MAX_MANIFEST_BYTES = 64 * 1024
const MAX_SCRIPT_BYTES = 1024 * 1024
const MAX_SIGNATURE_BYTES = 1024
const BASE64_RE = /^[A-Za-z0-9+/]+=*$/
const BUILD_RE = /^[1-9]\d{0,17}$/
const TAG_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/
const FILE_NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/
const SHA256_RE = /^[0-9a-f]{64}$/
/** The most packages one release lists: one per system and processor it ships for. */
const MAX_MANIFEST_FILES = 16
const utf8 = new TextDecoder('utf-8', { fatal: true })

/** One of a release's daemon packages, as its signed manifest names it. */
export interface DaemonReleaseFile {
  name: string
  /** The package's SHA-256, in lowercase hexadecimal. */
  sha256: string
}

export interface DaemonReleaseManifest {
  version: string
  channel: UpdateChannel
  build?: string
  tag: string
  /**
   * The release's packages. The install script takes its package only when it is one of these, so
   * the signature on the manifest covers the package too; absent from manifests that list none.
   */
  files?: DaemonReleaseFile[]
}

/** Message signed for an update file, matching tools/sarto/signing.mjs byte for byte. */
export function updateFileMessage(name: string, file: Uint8Array): Buffer {
  return Buffer.concat([Buffer.from(`${name}\n`, 'utf8'), file])
}

async function readBoundedBytes(response: Response, maxBytes: number): Promise<Uint8Array> {
  const lengthHeader = response.headers.get('content-length')
  if (lengthHeader !== null) {
    const declared = Number(lengthHeader)
    if (Number.isFinite(declared) && declared > maxBytes) {
      throw new Error(`response exceeds ${maxBytes} bytes`)
    }
  }
  if (!response.body) {
    const buf = new Uint8Array(await response.arrayBuffer())
    if (buf.byteLength > maxBytes) throw new Error(`response exceeds ${maxBytes} bytes`)
    return buf
  }
  const reader = response.body.getReader()
  const chunks: Uint8Array[] = []
  let total = 0
  for (;;) {
    const { done, value } = await reader.read()
    if (done) break
    total += value.byteLength
    if (total > maxBytes) {
      await reader.cancel().catch(() => {})
      throw new Error(`response exceeds ${maxBytes} bytes`)
    }
    chunks.push(value)
  }
  const out = new Uint8Array(total)
  let offset = 0
  for (const chunk of chunks) {
    out.set(chunk, offset)
    offset += chunk.byteLength
  }
  return out
}

function parseSignatureBytes(text: string): Uint8Array | null {
  const trimmed = text.trim()
  if (!trimmed || !BASE64_RE.test(trimmed)) return null
  const bytes = Buffer.from(trimmed, 'base64')
  return bytes.length === 64 ? new Uint8Array(bytes) : null
}

/** Parses a daemon manifest JSON after signature verification, enforcing channel and tag rules. */
export function parseDaemonManifest(
  bytes: Uint8Array,
  expectedChannel: UpdateChannel,
): DaemonReleaseManifest {
  let raw: unknown
  try {
    raw = JSON.parse(utf8.decode(bytes))
  } catch (error) {
    throw new UpdateError(`Invalid daemon manifest JSON: ${(error as Error).message}`)
  }
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
    throw new UpdateError('Daemon manifest is not a JSON object')
  }
  const obj = raw as Record<string, unknown>
  const version = typeof obj.version === 'string' ? obj.version : ''
  if (!isChannelVersion(version, expectedChannel)) {
    throw new UpdateError(
      `Daemon manifest version '${version}' is not valid for ${expectedChannel}`,
    )
  }
  let declaredChannel: UpdateChannel = expectedChannel
  if (obj.channel !== undefined && obj.channel !== null) {
    if (obj.channel !== 'stable' && obj.channel !== 'beta') {
      throw new UpdateError('Daemon manifest channel must be stable or beta')
    }
    if (expectedChannel === 'stable' && obj.channel !== 'stable') {
      throw new UpdateError('A stable daemon manifest cannot declare channel beta')
    }
    declaredChannel = obj.channel
  }
  let build: string | undefined
  if (obj.build !== undefined && obj.build !== null) {
    if (typeof obj.build !== 'string' || !BUILD_RE.test(obj.build)) {
      throw new UpdateError('Daemon manifest build number is not valid')
    }
    build = obj.build
  }
  let tag = `v${version}`
  if (obj.tag !== undefined && obj.tag !== null) {
    if (typeof obj.tag !== 'string' || !TAG_RE.test(obj.tag) || obj.tag.includes('..')) {
      throw new UpdateError('Daemon manifest tag is not valid')
    }
    tag = obj.tag
  }
  let files: DaemonReleaseFile[] | undefined
  if (obj.files !== undefined && obj.files !== null) {
    if (!Array.isArray(obj.files) || obj.files.length > MAX_MANIFEST_FILES) {
      throw new UpdateError('Daemon manifest files are not valid')
    }
    files = obj.files.map((entry: unknown) => {
      const file = (typeof entry === 'object' && entry !== null ? entry : {}) as Record<
        string,
        unknown
      >
      if (
        typeof file.name !== 'string' ||
        !FILE_NAME_RE.test(file.name) ||
        typeof file.sha256 !== 'string' ||
        !SHA256_RE.test(file.sha256)
      ) {
        throw new UpdateError('Daemon manifest files are not valid')
      }
      return { name: file.name, sha256: file.sha256 }
    })
  }
  return {
    version,
    channel: declaredChannel,
    ...(build ? { build } : {}),
    tag,
    ...(files && files.length > 0 ? { files } : {}),
  }
}

/** Sarto's release source, or only the place `pinned` names. */
export function releaseSources(pinned: string | undefined): string[] {
  const one = pinned?.trim()
  return one ? [one] : [DOWNLOADS]
}

/** What `sarto update`'s requests say they are, which tells the service an update from a download. */
export function daemonUserAgent(version: string, platform: string, arch: string): string {
  return `Sarto-daemon/${version} (${platform}; ${arch})`
}

/**
 * The versions folder of a package the install script installed, which runs from
 * `<versions>/<version>/daemon`; null for a daemon run from a build, such as a checkout's out/.
 */
export function installedVersions(bundleDir: string): string | null {
  const versions = path.dirname(path.dirname(bundleDir))
  return path.basename(bundleDir) === 'daemon' && path.basename(versions) === 'versions'
    ? versions
    : null
}

/** The version of the release page an address names, as GitHub's latest release redirects. */
export function releaseVersion(location: string): string | null {
  return /\/tag\/v(\d+\.\d+\.\d+)\/?$/.exec(location)?.[1] ?? null
}

/** Whether version `a` comes after `b` according to SemVer 2.0.0 precedence. */
export function isNewer(a: string, b: string): boolean {
  const order = compareVersions(a, b)
  return Number.isFinite(order) && order > 0
}

export class UpdateError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'UpdateError'
  }
}

export interface UpdateDeps {
  /** The version running. */
  version: string
  /** Release channel to follow; defaults to beta for beta builds, stable otherwise. */
  channel?: UpdateChannel
  /** Current host OS and CPU architecture used to pin the matching package checksum. */
  platform?: NodeJS.Platform
  arch?: string
  /** The folder of the running daemon's bundle. */
  bundleDir: string
  /** The places to try in order, laid out as GitHub's releases. */
  releases: string[]
  userAgent: string
  fetch: typeof fetch
  /** Whether the daemon's service is installed, so the install sets it up again. */
  service: boolean
  /** Whether a daemon runs in the foreground, outside the service, which the update leaves be. */
  foreground: boolean
  /** Runs the downloaded install script with `args` and resolves to its exit code. */
  install(script: string, args: string[]): Promise<number>
  write(text: string): void
}

type Requests = Pick<UpdateDeps, 'userAgent' | 'fetch'>
type Releases = Requests & { releases: string }

function request(deps: Requests, url: string, init: RequestInit = {}): Promise<Response> {
  return deps.fetch(url, {
    ...init,
    headers: { 'User-Agent': deps.userAgent },
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
  })
}

export async function latestVersion(deps: Releases) {
  const url = `${deps.releases}/latest`
  let location: string | null
  try {
    location = (await request(deps, url, { redirect: 'manual' })).headers.get('location')
  } catch (error) {
    throw new UpdateError(`Could not reach ${url}: ${(error as Error).message}`)
  }
  const version = location ? releaseVersion(location) : null
  if (!version) throw new UpdateError(`${url} names no release`)
  return version
}

/**
 * Downloads and verifies a signed daemon channel manifest from `<releases>/latest/download/<name>`.
 * Returns `null` only when the server returns 404 (e.g. channel not published yet or legacy server).
 * The manifest and its signature follow redirects, as a place laid out as GitHub's sends
 * `latest/download` to the release's own folder; the signature over the file's name and bytes is
 * what makes them trusted, wherever they came from.
 */
async function fetchSignedManifest(
  deps: Releases,
  channel: UpdateChannel,
  releaseKeys: readonly string[],
): Promise<DaemonReleaseManifest | null> {
  const name = DAEMON_MANIFEST_NAME[channel]
  const url = `${deps.releases}/latest/download/${name}`
  const sigUrl = `${url}.sig`
  let response: Response
  try {
    response = await request(deps, url, { redirect: 'follow' })
  } catch (error) {
    throw new UpdateError(`Could not download ${url}: ${(error as Error).message}`)
  }
  if (response.status === 404) return null
  if (!response.ok) {
    throw new UpdateError(`Could not download ${url}: it answered ${response.status}`)
  }
  const manifestBytes = await readBoundedBytes(response, MAX_MANIFEST_BYTES)

  let sigText: string
  try {
    const sigResponse = await request(deps, sigUrl, { redirect: 'follow' })
    if (!sigResponse.ok) throw new Error(`it answered ${sigResponse.status}`)
    sigText = utf8.decode(await readBoundedBytes(sigResponse, MAX_SIGNATURE_BYTES))
  } catch (error) {
    throw new UpdateError(`Could not download ${sigUrl}: ${(error as Error).message}`)
  }
  const sigBytes = parseSignatureBytes(sigText)
  if (
    !sigBytes ||
    !verifySignature(updateFileMessage(name, manifestBytes), sigBytes, releaseKeys)
  ) {
    throw new UpdateError(`Signature verification failed for ${url}`)
  }
  return parseDaemonManifest(manifestBytes, channel)
}

/**
 * Resolves the latest release candidate on `channel` from one release source.
 * On `beta`, checks both `beta-daemon.json` and `latest-daemon.json` and chooses the newer SemVer
 * so beta installations naturally graduate onto stable releases. On `stable`, checks
 * `latest-daemon.json` first and falls back to the legacy `/latest` redirect when 404.
 */
async function latestManifestForSource(
  deps: Releases,
  channel: UpdateChannel,
  releaseKeys: readonly string[],
): Promise<DaemonReleaseManifest> {
  if (channel === 'beta') {
    const candidates: DaemonReleaseManifest[] = []
    let firstError: unknown = null
    for (const target of ['beta', 'stable'] as const) {
      try {
        const found = await fetchSignedManifest(deps, target, releaseKeys)
        if (found) candidates.push(found)
      } catch (error) {
        firstError ??= error
      }
    }
    if (candidates.length === 0) {
      if (firstError) throw firstError
      throw new UpdateError(`${deps.releases} offers no signed daemon release for beta`)
    }
    return candidates.reduce((best, item) => (isNewer(item.version, best.version) ? item : best))
  }

  const signed = await fetchSignedManifest(deps, 'stable', releaseKeys)
  if (signed) return signed
  const version = await latestVersion(deps)
  return { version, channel: 'stable', tag: `v${version}` }
}

/**
 * The latest release, with its install script when it is newer than the one running, from the
 * first place that answers with both. A place whose latest is older than the one running lags
 * behind, so the next is asked, and only when every place that answered has nothing newer is
 * there no update.
 */
async function latestRelease(
  deps: UpdateDeps,
  channel: UpdateChannel,
  releaseKeys: readonly string[],
): Promise<{ version: string; tag: string; script: string | null; files?: DaemonReleaseFile[] }> {
  let failure: unknown = new UpdateError('No place to download releases from')
  let stale: { version: string; tag: string } | null = null
  for (const [index, releases] of deps.releases.entries()) {
    try {
      const candidate = await latestManifestForSource({ ...deps, releases }, channel, releaseKeys)
      const { version, tag } = candidate
      if (isNewer(deps.version, version)) {
        stale = { version, tag }
        const next = deps.releases[index + 1]
        if (next)
          deps.write(`${releases} offers ${version}, older than ${deps.version}; trying ${next}\n`)
        continue
      }
      if (!isNewer(version, deps.version)) return { version, tag, script: null }
      const url = `${releases}/download/${encodeURIComponent(tag)}/install.sh`
      const sigUrl = `${releases}/download/${encodeURIComponent(tag)}/install.sh.sig`
      let scriptBytes: Uint8Array
      try {
        const response = await request(deps, url, { redirect: 'follow' })
        if (!response.ok) throw new Error(`it answered ${response.status}`)
        scriptBytes = await readBoundedBytes(response, MAX_SCRIPT_BYTES)
      } catch (error) {
        throw new UpdateError(`Could not download ${url}: ${(error as Error).message}`)
      }
      let sigText: string
      try {
        const sigResponse = await request(deps, sigUrl, { redirect: 'follow' })
        if (!sigResponse.ok) throw new Error(`it answered ${sigResponse.status}`)
        const sigRaw = await readBoundedBytes(sigResponse, MAX_SIGNATURE_BYTES)
        sigText = utf8.decode(sigRaw)
      } catch (error) {
        throw new UpdateError(`Could not download ${sigUrl}: ${(error as Error).message}`)
      }
      const sigBytes = parseSignatureBytes(sigText)
      if (
        !sigBytes ||
        !verifySignature(updateFileMessage('install.sh', scriptBytes), sigBytes, releaseKeys)
      ) {
        throw new UpdateError(`Signature verification failed for ${url}`)
      }
      let script: string
      try {
        script = utf8.decode(scriptBytes)
      } catch (error) {
        throw new UpdateError(`Invalid UTF-8 in ${url}: ${(error as Error).message}`)
      }
      return { version, tag, script, ...(candidate.files ? { files: candidate.files } : {}) }
    } catch (error) {
      failure = error
      const next = deps.releases[index + 1]
      if (next) deps.write(`${(error as Error).message}; trying ${next}\n`)
    }
  }
  if (stale) return { ...stale, script: null }
  throw failure
}

/** Updates to the latest release on the selected channel and resolves to the exit code. */
export async function update(
  deps: UpdateDeps,
  releaseKeys: readonly string[] = RELEASE_KEYS,
): Promise<number> {
  if (!installedVersions(deps.bundleDir)) {
    throw new UpdateError(
      'sarto update updates a daemon the install script installed; this one runs from ' +
        path.dirname(deps.bundleDir),
    )
  }
  const channel: UpdateChannel = deps.channel ?? (isBetaVersion(deps.version) ? 'beta' : 'stable')
  const { version: latest, tag, script, files } = await latestRelease(deps, channel, releaseKeys)
  if (script === null) {
    deps.write(`The Sarto daemon ${deps.version} is up to date.\n`)
    return 0
  }
  deps.write(`Updating the Sarto daemon from ${deps.version} to ${latest}\n`)
  // The script tries the same places in the same order for the package. The checksums it finds
  // beside the package are not signed, so it is given the ones the signed manifest lists and
  // takes a package only when it matches one of them.
  const expectedName =
    deps.platform && deps.arch ? `sarto-daemon-${deps.platform}-${deps.arch}.tar.gz` : null
  const matched = expectedName ? (files ?? []).filter((file) => file.name === expectedName) : []
  if (expectedName && files && files.length > 0 && matched.length === 0) {
    throw new UpdateError(
      `Release ${latest} includes no daemon package for ${deps.platform}-${deps.arch}`,
    )
  }
  const pinned = [...new Set((matched.length > 0 ? matched : (files ?? [])).map((f) => f.sha256))]
  const args = [
    '--version',
    latest,
    ...(tag !== `v${latest}` ? ['--tag', tag] : []),
    ...pinned.flatMap((sha256) => ['--sha256', sha256]),
    ...(deps.service ? [] : ['--no-service']),
  ]
  const code = await deps.install(script, args)
  if (code === 0 && deps.foreground) {
    deps.write(`The daemon running in the foreground runs ${latest} once you start it again.\n`)
  }
  return code
}
