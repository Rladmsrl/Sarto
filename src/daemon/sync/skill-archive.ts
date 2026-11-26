// Deterministic packer and atomic unpacker for Marketplace / Local Skill folders.
// Used by SartoSyncService to seal unpacked skills into Content-Addressed Storage (CAS) blobs
// so custom and local skills clone seamlessly onto any newly connected computer.

import { createHash, randomUUID } from 'node:crypto'
import { lstat, mkdir, readdir, readFile, rename, rm, stat, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { promisify } from 'node:util'
import { gunzip, gzip } from 'node:zlib'
import { skillFolder } from '../../agent-host/marketplace/skills'

const gzipAsync = promisify(gzip)
const gunzipAsync = promisify(gunzip)

const MAX_FILES = 1_000
const MAX_TOTAL_BYTES = 50 * 1024 * 1024

interface PackedSkillFile {
  path: string
  mode: number
  data: string
}

interface PackedSkillPayload {
  v: 1
  name: string
  files: PackedSkillFile[]
}

function isSafeRelativePath(rel: string): boolean {
  if (!rel || rel.length > 512 || rel.startsWith('/') || rel.includes('\0') || rel.includes('\\')) {
    return false
  }
  const parts = rel.split('/')
  return parts.every((seg) => seg.length > 0 && seg !== '.' && seg !== '..')
}

export async function packSkillDirectory(
  userDataPath: string,
  skillId: string,
  skillName: string,
): Promise<{ compressed: Uint8Array; contentHash: string } | null> {
  if (!isSafeRelativePath(skillName) || skillName.includes('/')) return null
  const root = path.join(userDataPath, 'marketplace', 'skills', skillFolder(skillId), skillName)
  const rootInfo = await stat(root).catch(() => null)
  if (!rootInfo?.isDirectory()) return null

  const files: PackedSkillFile[] = []
  let totalBytes = 0

  const walk = async (dir: string, prefix: string): Promise<void> => {
    const entries = await readdir(dir, { withFileTypes: true })
    entries.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0))
    for (const entry of entries) {
      if (entry.isSymbolicLink()) continue
      const rel = prefix ? `${prefix}/${entry.name}` : entry.name
      const full = path.join(dir, entry.name)
      if (entry.isDirectory()) {
        await walk(full, rel)
        continue
      }
      if (!entry.isFile()) continue
      const info = await lstat(full)
      totalBytes += info.size
      if (files.length >= MAX_FILES || totalBytes > MAX_TOTAL_BYTES) {
        throw new Error(`Skill "${skillName}" exceeds sync archive limits`)
      }
      const raw = await readFile(full)
      files.push({
        path: rel,
        mode: info.mode & 0o777,
        data: raw.toString('base64'),
      })
    }
  }

  await walk(root, '')
  if (files.length === 0) return null

  const canonicalJson = JSON.stringify({
    v: 1,
    name: skillName,
    files,
  } satisfies PackedSkillPayload)
  const contentHash = createHash('sha256').update(canonicalJson, 'utf8').digest('hex')
  const compressedBuf = await gzipAsync(Buffer.from(canonicalJson, 'utf8'), { level: 6 })
  const compressed = new Uint8Array(
    compressedBuf.buffer,
    compressedBuf.byteOffset,
    compressedBuf.byteLength,
  )
  return { compressed, contentHash }
}

export async function unpackSkillDirectory(
  userDataPath: string,
  skillId: string,
  expectedSkillName: string,
  compressed: Uint8Array,
): Promise<void> {
  const rawBuf = await gunzipAsync(
    Buffer.from(compressed.buffer, compressed.byteOffset, compressed.byteLength),
    {
      maxOutputLength: MAX_TOTAL_BYTES * 2,
    },
  )
  const rawJson = rawBuf.toString('utf8')
  const parsed = JSON.parse(rawJson) as Partial<PackedSkillPayload>
  if (parsed.v !== 1 || !Array.isArray(parsed.files) || parsed.files.length > MAX_FILES) {
    throw new Error('Invalid packed skill payload')
  }
  const skillName =
    typeof parsed.name === 'string' && isSafeRelativePath(parsed.name) && !parsed.name.includes('/')
      ? parsed.name
      : expectedSkillName
  if (!isSafeRelativePath(skillName) || skillName.includes('/')) {
    throw new Error('Unsafe skill folder name')
  }

  const storeRoot = path.join(userDataPath, 'marketplace', 'skills')
  await mkdir(storeRoot, { recursive: true })
  const dir = skillFolder(skillId)
  const partial = path.join(storeRoot, `.partial-sync-${randomUUID()}`)
  const targetSkillRoot = path.join(partial, skillName)

  let totalBytes = 0
  try {
    await mkdir(targetSkillRoot, { recursive: true })
    for (const file of parsed.files) {
      if (
        typeof file?.path !== 'string' ||
        !isSafeRelativePath(file.path) ||
        typeof file.data !== 'string'
      ) {
        throw new Error('Invalid file entry in skill archive')
      }
      const bytes = Buffer.from(file.data, 'base64')
      totalBytes += bytes.byteLength
      if (totalBytes > MAX_TOTAL_BYTES) {
        throw new Error('Unpacked skill exceeds maximum allowed size')
      }
      const dest = path.join(targetSkillRoot, ...file.path.split('/'))
      await mkdir(path.dirname(dest), { recursive: true })
      const mode = typeof file.mode === 'number' && (file.mode & 0o111) !== 0 ? 0o755 : 0o644
      await writeFile(dest, bytes, { mode })
    }
    const finalDir = path.join(storeRoot, dir)
    await rm(finalDir, { recursive: true, force: true })
    await rename(partial, finalDir)
  } catch (error) {
    await rm(partial, { recursive: true, force: true }).catch(() => {})
    throw error
  }
}

/**
 * What the skills folder holds, as each file's path, size and time of change: a cheap look that
 * says whether packing the skills again may find a change.
 */
export async function skillsFolderFingerprint(userDataPath: string): Promise<string> {
  const root = path.join(userDataPath, 'marketplace', 'skills')
  const hash = createHash('sha256')
  let seen = 0
  const walk = async (dir: string, prefix: string): Promise<void> => {
    const entries = await readdir(dir, { withFileTypes: true }).catch(() => [])
    entries.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0))
    for (const entry of entries) {
      if (++seen > MAX_FILES * 20) return
      const rel = prefix ? `${prefix}/${entry.name}` : entry.name
      const full = path.join(dir, entry.name)
      if (entry.isDirectory()) {
        await walk(full, rel)
      } else if (entry.isFile()) {
        const info = await lstat(full).catch(() => null)
        if (info) hash.update(`${rel}\0${info.size}\0${info.mtimeMs}\n`)
      }
    }
  }
  await walk(root, '')
  return hash.digest('hex')
}

export async function hasUnpackedSkill(
  userDataPath: string,
  skillId: string,
  skillName: string,
): Promise<boolean> {
  if (!isSafeRelativePath(skillName) || skillName.includes('/')) return false
  const skillMd = path.join(
    userDataPath,
    'marketplace',
    'skills',
    skillFolder(skillId),
    skillName,
    'SKILL.md',
  )
  const info = await stat(skillMd).catch(() => null)
  return Boolean(info?.isFile())
}
