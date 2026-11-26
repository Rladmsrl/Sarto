// Bidirectional path mapping and tool-card normalization for own-account remote Claude Code:
// maps the remote shadow root <-> local project path, enforces local symlink-safe path boundaries,
// and restores `mcp__sarto_exec__*` tool entries to native Sarto tool cards.

import { lstat, readlink, realpath } from 'node:fs/promises'
import path from 'node:path'
import type { Platform } from '@shared/platform'
import { REMOTE_CLAUDE_EXEC_MCP } from '@shared/remote-claude'
import type { Patch, ToolEntry, ToolKind } from '@shared/thread'

const EXEC_PREFIX = `mcp__${REMOTE_CLAUDE_EXEC_MCP}__`
/** Links followed before a path counts as outside, as the system gives up on a loop. */
const MAX_LINK_HOPS = 40
/** What may follow a root in text for it to be the root, not the start of a longer name. */
const ROOT_END = `(?=$|[\\\\/\\s"'\\x60)\\]}:,;!?<>|&=])`
/** The rest of a path after the root, whose separators change with the platform. */
const PATH_REST = `((?:[\\\\/][^\\s"'\\x60<>|&;,:()\\[\\]{}]*)?)`

const TOOL_KIND_BY_NAME: Readonly<Record<string, ToolKind>> = {
  Read: 'read',
  Write: 'edit',
  Edit: 'edit',
  Glob: 'search',
  Grep: 'search',
  Bash: 'execute',
  BashOutput: 'execute',
  KillShell: 'execute',
}

function stripTrailingSep(value: string): string {
  if (value === '/' || /^[A-Za-z]:[\\/]?$/.test(value)) return value
  return value.replace(/[\\/]+$/, '')
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

function startsWithDir(target: string, root: string, caseInsensitive: boolean): string | null {
  const normRoot = stripTrailingSep(root)
  const cmpTarget = caseInsensitive ? target.toLowerCase() : target
  const cmpRoot = caseInsensitive ? normRoot.toLowerCase() : normRoot
  if (cmpTarget === cmpRoot) return ''
  if (!cmpTarget.startsWith(cmpRoot)) return null
  const boundary = target[normRoot.length]
  if (boundary !== '/' && boundary !== '\\') return null
  return target.slice(normRoot.length + 1)
}

export interface WorkspaceMapper {
  readonly localRoot: string
  readonly remoteRoot: string
  readonly localPlatform: Platform
  readonly remotePlatform: Platform
  /** Maps an agent-supplied path (virtual, relative, or local) to a resolved local path. */
  toLocalPath(inputPath: string): string
  /** Checks whether a resolved local path lies strictly inside `localRoot` (following symlinks). */
  isInsideLocalRoot(localPath: string): Promise<boolean>
  /** Replaces local project paths with virtual paths in text returned to the remote agent. */
  toRemoteText(text: string): string
  /** Replaces remote virtual paths with local paths in text/metadata displayed locally. */
  toLocalText(text: string): string
}

export function createWorkspaceMapper(options: {
  localRoot: string
  remoteRoot: string
  localPlatform: Platform
  remotePlatform: Platform
}): WorkspaceMapper {
  const localRoot = stripTrailingSep(path.resolve(options.localRoot))
  const remoteRoot = stripTrailingSep(options.remoteRoot)
  const localCaseInsensitive = options.localPlatform === 'win32'
  const remoteCaseInsensitive = options.remotePlatform === 'win32'
  const localSep = options.localPlatform === 'win32' ? '\\' : '/'
  const remoteSep = options.remotePlatform === 'win32' ? '\\' : '/'

  const localRegex = new RegExp(
    `${escapeRegExp(localRoot)}${ROOT_END}${PATH_REST}`,
    localCaseInsensitive ? 'gi' : 'g',
  )
  const remoteRegex = new RegExp(
    `${escapeRegExp(remoteRoot)}${ROOT_END}${PATH_REST}`,
    remoteCaseInsensitive ? 'gi' : 'g',
  )
  const contains = (text: string, root: string, caseInsensitive: boolean): boolean =>
    caseInsensitive ? text.toLowerCase().includes(root.toLowerCase()) : text.includes(root)

  return {
    localRoot,
    remoteRoot,
    localPlatform: options.localPlatform,
    remotePlatform: options.remotePlatform,

    toLocalPath(inputPath: string): string {
      if (inputPath.includes('\0')) throw new Error('Path contains null byte')
      const trimmed = inputPath.trim()
      if (!trimmed) return localRoot
      const fromRemote = startsWithDir(trimmed, remoteRoot, remoteCaseInsensitive)
      if (fromRemote !== null) {
        if (fromRemote === '') return localRoot
        const segments = fromRemote.split(/[\\/]+/).filter(Boolean)
        return path.resolve(localRoot, ...segments)
      }
      if (path.isAbsolute(trimmed)) {
        return path.resolve(trimmed)
      }
      return path.resolve(localRoot, ...trimmed.split(/[\\/]+/).filter(Boolean))
    },

    async isInsideLocalRoot(localPath: string): Promise<boolean> {
      const resolvedRoot = await realpath(localRoot).catch(() => localRoot)
      const resolvedTarget = await resolveDeepestExisting(path.resolve(localPath))
      const a = localCaseInsensitive ? resolvedRoot.toLowerCase() : resolvedRoot
      const b = localCaseInsensitive ? resolvedTarget.toLowerCase() : resolvedTarget
      const rel = path.relative(a, b)
      return rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel))
    },

    toRemoteText(text: string): string {
      if (!text || !contains(text, localRoot, localCaseInsensitive)) return text
      return text.replace(
        localRegex,
        (_match, rest: string) => remoteRoot + rest.replaceAll(localSep, remoteSep),
      )
    },

    toLocalText(text: string): string {
      if (!text || !contains(text, remoteRoot, remoteCaseInsensitive)) return text
      return text.replace(
        remoteRegex,
        (_match, rest: string) => localRoot + rest.replaceAll(remoteSep, localSep),
      )
    },
  }
}

/**
 * Resolves symlinks on the deepest existing ancestor so new files cannot escape via symlinked dirs.
 * A link whose target is missing resolves to that target, where writing through it would land.
 */
async function resolveDeepestExisting(target: string): Promise<string> {
  const tail: string[] = []
  let current = target
  let hops = 0
  while (true) {
    try {
      const real = await realpath(current)
      return tail.length > 0 ? path.join(real, ...tail.reverse()) : real
    } catch {
      const link = await lstat(current).catch(() => null)
      if (link?.isSymbolicLink()) {
        // A loop, or one too long, is nowhere a file can be written.
        if (++hops > MAX_LINK_HOPS) return path.parse(current).root
        current = path.resolve(path.dirname(current), await readlink(current))
        continue
      }
      const parent = path.dirname(current)
      if (parent === current) return target
      tail.push(path.basename(current))
      current = parent
    }
  }
}

function unprojectValue(value: unknown, mapper: WorkspaceMapper): unknown {
  if (typeof value === 'string') return mapper.toLocalText(value)
  if (Array.isArray(value)) return value.map((item) => unprojectValue(item, mapper))
  if (value && typeof value === 'object') {
    const out: Record<string, unknown> = {}
    for (const [k, v] of Object.entries(value)) {
      out[k] = unprojectValue(v, mapper)
    }
    return out
  }
  return value
}

function normalizeToolFields<T extends { title?: string; toolKind?: ToolKind }>(
  fields: T,
  mapper: WorkspaceMapper,
): T {
  const next = unprojectValue(fields, mapper) as T
  if (typeof next.title !== 'string') return next
  if (next.title.startsWith(EXEC_PREFIX)) {
    const rawName = next.title.slice(EXEC_PREFIX.length)
    const toolKind = TOOL_KIND_BY_NAME[rawName]
    return {
      ...next,
      title: rawName,
      ...(toolKind ? { toolKind } : {}),
    }
  }
  const dashPrefix = `${REMOTE_CLAUDE_EXEC_MCP} - `
  if (next.title.startsWith(dashPrefix)) {
    const rawName = next.title.slice(dashPrefix.length)
    const toolKind = TOOL_KIND_BY_NAME[rawName]
    return {
      ...next,
      title: rawName,
      ...(toolKind ? { toolKind } : {}),
    }
  }
  return next
}

/**
 * Unprojects remote shadow paths back to local paths and restores `sarto_exec` tool cards to
 * native Sarto tool kinds/titles.
 */
export function normalizeHostedPatches(
  patches: readonly Patch[],
  mapper: WorkspaceMapper,
): Patch[] {
  return patches.map((patch): Patch => {
    if (patch.op === 'entry.add' && patch.entry.kind === 'tool') {
      return { ...patch, entry: normalizeToolFields(patch.entry as ToolEntry, mapper) }
    }
    if (patch.op === 'entry.update') {
      const changes = normalizeToolFields(
        patch.changes as Record<string, unknown> & { title?: string; toolKind?: ToolKind },
        mapper,
      )
      return {
        ...patch,
        changes: changes as Patch & { op: 'entry.update' } extends { changes: infer C } ? C : never,
      }
    }
    return unprojectValue(patch, mapper) as Patch
  })
}
