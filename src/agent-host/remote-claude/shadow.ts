// Shadow workspace on the remote model host: gives a hosted Claude Code process a clean,
// empty working directory of its own while validating the controller's instruction snapshot
// (CLAUDE.md and .claude/rules/**/*.md) for injection through systemPromptAppend, never writing
// untrusted files onto the host computer or letting Claude Code expand @path imports there.

import { createHash } from 'node:crypto'
import { mkdir, rm } from 'node:fs/promises'
import path from 'node:path'
import {
  REMOTE_CLAUDE_MAX_SNAPSHOT_FILE_BYTES,
  REMOTE_CLAUDE_MAX_SNAPSHOT_FILES,
  REMOTE_CLAUDE_MAX_SNAPSHOT_TOTAL_BYTES,
  type RemoteClaudeSnapshotFile,
} from '@shared/remote-claude'

const SHADOW_ROOT_DIR = 'remote-claude'

const INSTRUCTION_FILES = new Set(['CLAUDE.md', 'CLAUDE.local.md', '.claude/CLAUDE.md'])

/**
 * Safe relative path inside the shadow workspace: POSIX-style, no traversal, no null bytes, and
 * only an instruction file. The hosted run reads the folder's project settings, so a settings
 * file, `.mcp.json`, agent or command from a device would run as the host's own.
 */
export function normalizeSnapshotPath(raw: string): string | null {
  if (!raw || raw.length > 512 || raw.includes('\0') || raw.includes('\\')) return null
  if (raw.startsWith('/') || /^[A-Za-z]:/.test(raw)) return null
  const parts = raw.split('/')
  if (parts.some((part) => part === '' || part === '.' || part === '..')) return null
  const rule = parts.length > 2 && parts[0] === '.claude' && parts[1] === 'rules'
  if (!INSTRUCTION_FILES.has(raw) && !(rule && raw.endsWith('.md'))) return null
  return parts.join('/')
}

/** Validates and bounds snapshot files sent by the controller before touching disk. */
export function sanitizeSnapshotFiles(
  files: readonly RemoteClaudeSnapshotFile[] | undefined,
): RemoteClaudeSnapshotFile[] {
  if (!files || files.length === 0) return []
  const kept: RemoteClaudeSnapshotFile[] = []
  const seen = new Set<string>()
  let totalBytes = 0
  for (const file of files) {
    if (kept.length >= REMOTE_CLAUDE_MAX_SNAPSHOT_FILES) break
    const normalized = normalizeSnapshotPath(file.relativePath)
    if (!normalized || seen.has(normalized)) continue
    const bytes = Buffer.byteLength(file.content, 'utf8')
    if (bytes > REMOTE_CLAUDE_MAX_SNAPSHOT_FILE_BYTES) continue
    if (totalBytes + bytes > REMOTE_CLAUDE_MAX_SNAPSHOT_TOTAL_BYTES) break
    seen.add(normalized)
    totalBytes += bytes
    kept.push({ relativePath: normalized, content: file.content })
  }
  return kept
}

function scopeHash(value: string): string {
  return createHash('sha256').update(value).digest('hex').slice(0, 16)
}

export interface ShadowWorkspace {
  readonly baseDir: string
  readonly virtualRoot: string
  cleanup(): Promise<void>
}

/**
 * Creates a clean, empty shadow directory for one hosted session under
 * `<userDataPath>/remote-claude/<deviceHash>/<sessionHash>/fs`.
 */
export async function prepareShadowWorkspace(
  userDataPath: string,
  deviceId: string,
  sessionId: string,
): Promise<ShadowWorkspace> {
  const root = path.resolve(userDataPath, SHADOW_ROOT_DIR)
  const baseDir = path.resolve(root, scopeHash(deviceId), scopeHash(sessionId))
  const relBase = path.relative(root, baseDir)
  if (relBase.startsWith('..') || path.isAbsolute(relBase)) {
    throw new Error('Shadow workspace escaped base directory')
  }
  const virtualRoot = path.join(baseDir, 'fs')
  await rm(virtualRoot, { recursive: true, force: true })
  await mkdir(virtualRoot, { recursive: true, mode: 0o700 })

  return {
    baseDir,
    virtualRoot,
    async cleanup() {
      await rm(baseDir, { recursive: true, force: true }).catch(() => {})
    },
  }
}

/** Removes leftover shadow workspaces from earlier daemon runs. */
export async function clearShadowWorkspaces(userDataPath: string): Promise<void> {
  const root = path.resolve(userDataPath, SHADOW_ROOT_DIR)
  await rm(root, { recursive: true, force: true }).catch(() => {})
}
