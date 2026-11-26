// @ts-check
// A delta from one Sarto.app to the next, which the app's updater applies to itself in place of
// downloading the whole zip (SartoUpdate's UpdateDelta). Each file of the new app comes from the
// running one unchanged, as a patch of its file at the same path, or whole:
//
//   "SARTODELTA1\n"  u32 big-endian manifest length  manifest JSON  payload
//
// The manifest lists every directory, file and link of the new app in path order. A file names its
// mode, size and SHA-256 and where it comes from: `old` (a file of the old app, by path), `patch`
// (ops on the old file at its path: [0, offset, length] copies from it, [1, length] takes the next
// bytes of the file's literal data) or `data` (its bytes). Literal data and whole files are raw
// DEFLATE chunks in the payload, at [offset, length]. Patches match blocks of the old file at any
// offset, rsync's way, so a Mach-O that was only signed again costs little more than its signature.
//
//   node tools/sarto/delta.mjs <old Sarto.app> <new Sarto.app> --from X.Y.Z --to X.Y.Z --out <file>

import { createHash } from 'node:crypto'
import { lstatSync, readFileSync, readdirSync, readlinkSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseArgs } from 'node:util'
import { deflateRawSync } from 'node:zlib'

const MAGIC = Buffer.from('SARTODELTA1\n', 'ascii')
const MOD = 65536

/**
 * @typedef {{ path: string, kind: 'dir' } | { path: string, kind: 'link', target: string } |
 *   { path: string, kind: 'file', mode: number, size: number, sha256: string, source: Source }} Entry
 * @typedef {{ type: 'old', path: string } |
 *   { type: 'patch', path: string, ops: number[][], data: number[] } |
 *   { type: 'data', data: number[] }} Source
 */

/** Every entry under `root`, in path order, so a folder comes before what it holds. */
function walk(/** @type {string} */ root) {
  /** @type {string[]} */
  const out = []
  const visit = (/** @type {string} */ dir) => {
    for (const name of readdirSync(dir).sort()) {
      const full = path.join(dir, name)
      out.push(path.relative(root, full))
      if (lstatSync(full).isDirectory()) visit(full)
    }
  }
  visit(root)
  return out.sort((a, b) => (a < b ? -1 : a > b ? 1 : 0))
}

const sha256 = (/** @type {Buffer} */ bytes) => createHash('sha256').update(bytes).digest('hex')

/** rsync's weak checksum of `length` bytes from `start`. */
function weak(
  /** @type {Buffer} */ buffer,
  /** @type {number} */ start,
  /** @type {number} */ length,
) {
  let a = 0
  let b = 0
  for (let i = 0; i < length; i++) {
    a = (a + buffer[start + i]) % MOD
    b = (b + (length - i) * buffer[start + i]) % MOD
  }
  return { a, b }
}

/**
 * The ops that build `next` from `old`, and the literal bytes they take, matching blocks of `old`
 * at any offset of `next`.
 *
 * @param {Buffer} old
 * @param {Buffer} next
 * @param {number} block
 */
export function diff(old, next, block) {
  const strong = (/** @type {Buffer} */ buffer, /** @type {number} */ start) =>
    createHash('sha1')
      .update(buffer.subarray(start, start + block))
      .digest('hex')
  /** @type {Map<number, number[]>} */
  const blocks = new Map()
  for (let offset = 0; offset + block <= old.length; offset += block) {
    const { a, b } = weak(old, offset, block)
    const key = a + b * MOD
    const list = blocks.get(key) ?? []
    list.push(offset)
    blocks.set(key, list)
  }
  /** @type {number[][]} */
  const ops = []
  /** @type {Buffer[]} */
  const literals = []
  const literal = (/** @type {number} */ from, /** @type {number} */ to) => {
    if (to <= from) return
    literals.push(next.subarray(from, to))
    const last = ops.at(-1)
    if (last && last[0] === 1) last[1] += to - from
    else ops.push([1, to - from])
  }
  const copy = (/** @type {number} */ offset) => {
    const last = ops.at(-1)
    if (last && last[0] === 0 && last[1] + last[2] === offset) last[2] += block
    else ops.push([0, offset, block])
  }
  let position = 0
  let literalFrom = 0
  let { a, b } = next.length >= block ? weak(next, 0, block) : { a: 0, b: 0 }
  while (position + block <= next.length) {
    const candidates = blocks.get(a + b * MOD)
    let hit = -1
    if (candidates) {
      const want = strong(next, position)
      hit = candidates.find((offset) => strong(old, offset) === want) ?? -1
    }
    if (hit >= 0) {
      literal(literalFrom, position)
      copy(hit)
      position += block
      literalFrom = position
      if (position + block <= next.length) ({ a, b } = weak(next, position, block))
    } else {
      const leaving = next[position]
      const entering = position + block < next.length ? next[position + block] : 0
      a = (a - leaving + entering + MOD) % MOD
      b = (b - block * leaving + a + MOD * block) % MOD
      position++
    }
  }
  literal(literalFrom, next.length)
  return { ops, literal: Buffer.concat(literals) }
}

/**
 * Writes the delta from `oldApp` to `newApp` to `out`.
 *
 * @param {{ oldApp: string, newApp: string, from: string, to: string, out: string,
 *   block?: number, minPatch?: number }} options
 */
export function makeDelta({ oldApp, newApp, from, to, out, block = 16384, minPatch = 65536 }) {
  /** @type {Map<string, { size: number, hash?: string }>} */
  const oldFiles = new Map()
  for (const rel of walk(oldApp)) {
    const info = lstatSync(path.join(oldApp, rel))
    if (info.isFile()) oldFiles.set(rel, { size: info.size })
  }
  const oldHash = (/** @type {string} */ rel) => {
    const file = /** @type {{ size: number, hash?: string }} */ (oldFiles.get(rel))
    file.hash ??= sha256(readFileSync(path.join(oldApp, rel)))
    return file.hash
  }
  /** @type {Map<number, string[]>} The old files by size, to find one that moved. */
  const bySize = new Map()
  for (const [rel, file] of oldFiles) bySize.set(file.size, [...(bySize.get(file.size) ?? []), rel])

  /** @type {Buffer[]} */
  const payload = []
  let payloadLength = 0

  /** @type {Entry[]} */
  const entries = []
  for (const rel of walk(newApp)) {
    const full = path.join(newApp, rel)
    const info = lstatSync(full)
    if (info.isDirectory()) {
      entries.push({ path: rel, kind: 'dir' })
      continue
    }
    if (info.isSymbolicLink()) {
      const target = readlinkSync(full)
      // The updater takes only links that stay below their folder (UpdateDelta.linkStaysInside).
      if (path.isAbsolute(target) || target.split('/').includes('..')) {
        throw new Error(`${rel} links to ${target}, which the updater refuses in a delta`)
      }
      entries.push({ path: rel, kind: 'link', target })
      continue
    }
    const bytes = readFileSync(full)
    const hash = sha256(bytes)
    const mode = info.mode & 0o111 ? 0o755 : 0o644
    const file = {
      path: rel,
      kind: /** @type {const} */ ('file'),
      mode,
      size: bytes.length,
      sha256: hash,
    }
    if (oldFiles.has(rel) && oldHash(rel) === hash) {
      entries.push({ ...file, source: { type: 'old', path: rel } })
      continue
    }
    const moved = (bySize.get(bytes.length) ?? []).find((candidate) => oldHash(candidate) === hash)
    if (moved) {
      entries.push({ ...file, source: { type: 'old', path: moved } })
      continue
    }
    const whole = deflateRawSync(bytes, { level: 9 })
    if (oldFiles.has(rel) && bytes.length >= minPatch) {
      const patch = diff(readFileSync(path.join(oldApp, rel)), bytes, block)
      const literal = deflateRawSync(patch.literal, { level: 9 })
      if (literal.length < whole.length * 0.9) {
        payload.push(literal)
        payloadLength += literal.length
        const data = [payloadLength - literal.length, literal.length]
        entries.push({ ...file, source: { type: 'patch', path: rel, ops: patch.ops, data } })
        continue
      }
    }
    payload.push(whole)
    payloadLength += whole.length
    entries.push({
      ...file,
      source: { type: 'data', data: [payloadLength - whole.length, whole.length] },
    })
  }
  const manifest = Buffer.from(JSON.stringify({ from, to, entries }), 'utf8')
  const length = Buffer.alloc(4)
  length.writeUInt32BE(manifest.length)
  const body = Buffer.concat([MAGIC, length, manifest, ...payload])
  writeFileSync(out, body)
  return { size: body.length, files: entries.filter((entry) => entry.kind === 'file').length }
}

function main() {
  const { positionals, values } = parseArgs({
    allowPositionals: true,
    options: { from: { type: 'string' }, to: { type: 'string' }, out: { type: 'string' } },
  })
  const [oldApp, newApp] = positionals
  if (!oldApp || !newApp || !values.from || !values.to || !values.out) {
    console.error(
      'Usage: delta.mjs <old Sarto.app> <new Sarto.app> --from X.Y.Z --to X.Y.Z --out <file>',
    )
    process.exit(2)
  }
  const started = Date.now()
  const { size, files } = makeDelta({
    oldApp,
    newApp,
    from: values.from,
    to: values.to,
    out: values.out,
  })
  console.log(
    `${values.out}: ${(size / 1e6).toFixed(1)} MB for ${files} files, ${Date.now() - started} ms`,
  )
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) main()
