// Non-invasive context breakdown and definition estimates for Google Antigravity (`agy`).
//
// Reads only small local metadata asynchronously (user & project instruction files, skill
// frontmatter, and configured MCP servers) and combines them with the session's live ACP
// `usage` (`used`/`size`) so Sarto's context popover shows meaningful layered strata and
// inspectable lists without running hidden prompts or mutating agy state.

import { open, readdir, stat } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import type {
  ContextBreakdown,
  ContextDefinitionEstimate,
  ContextEstimates,
  ContextList,
} from '@shared/context'
import type { McpServer } from '../connection'
import { frontmatter } from '../marketplace/frontmatter'

const UTF8_BYTES_PER_TOKEN = 4
const MAX_INSTRUCTION_BYTES = 2 * 1024 * 1024
const MAX_SKILL_MD_BYTES = 64 * 1024

const estimateTokens = (bytes: number): number => Math.ceil(bytes / UTF8_BYTES_PER_TOKEN)

function compactTokens(tokens: number): string {
  if (tokens >= 1_000_000) return `${(tokens / 1_000_000).toFixed(1)}M`
  if (tokens >= 1000) return `${(tokens / 1000).toFixed(1)}k`
  return String(tokens)
}

function shortPath(file: string, cwd: string, home: string): string {
  const under = (root: string): string | null => {
    if (!root) return null
    const rel = path.relative(root, file)
    return rel && rel !== '..' && !rel.startsWith(`..${path.sep}`) && !path.isAbsolute(rel)
      ? rel
      : null
  }
  const inProject = under(cwd)
  if (inProject) return inProject
  const inHome = under(home)
  return inHome ? `~${path.sep}${inHome}` : file
}

interface InstructionEntry {
  path: string
  display: string
  tokens: number
}

async function readInstructionFiles(cwd: string, home: string): Promise<InstructionEntry[]> {
  const candidates = [
    path.join(home, '.gemini', 'GEMINI.md'),
    path.join(home, '.gemini', 'AGENTS.md'),
    path.join(cwd, 'GEMINI.md'),
    path.join(cwd, 'AGENTS.md'),
    path.join(cwd, 'CLAUDE.md'),
  ]
  const seen = new Set<string>()
  const out: InstructionEntry[] = []
  for (const file of candidates) {
    const resolved = path.resolve(file)
    if (seen.has(resolved)) continue
    seen.add(resolved)
    try {
      const info = await stat(resolved)
      if (!info.isFile() || info.size <= 0 || info.size > MAX_INSTRUCTION_BYTES) continue
      out.push({
        path: resolved,
        display: shortPath(resolved, cwd, home),
        tokens: estimateTokens(info.size),
      })
    } catch {
      continue
    }
  }
  return out
}

async function scanSkillFolder(folder: string, out: Map<string, number>): Promise<void> {
  let entries
  try {
    entries = await readdir(folder, { withFileTypes: true })
  } catch {
    return
  }
  for (const entry of entries) {
    if (entry.name.startsWith('.')) continue
    if (!entry.isDirectory() && !entry.isSymbolicLink()) continue
    const skillFile = path.join(folder, entry.name, 'SKILL.md')
    try {
      const fh = await open(skillFile, 'r')
      let head: string
      try {
        const info = await fh.stat()
        if (!info.isFile()) continue
        const size = Math.min(info.size, MAX_SKILL_MD_BYTES)
        const buf = Buffer.allocUnsafe(size)
        const { bytesRead } = await fh.read(buf, 0, size, 0)
        head = buf.subarray(0, bytesRead).toString('utf8')
      } finally {
        await fh.close()
      }
      const fields = frontmatter(head)
      const name = fields.name?.trim() || entry.name
      if (out.has(name)) continue
      const description = fields.description?.trim() || ''
      const catalogLine = `- ${name} (${skillFile}): ${description}\n`
      out.set(name, estimateTokens(Buffer.byteLength(catalogLine, 'utf8')))
    } catch {
      continue
    }
  }
}

function bySize(a: ContextDefinitionEstimate, b: ContextDefinitionEstimate): number {
  return (b.tokens ?? -1) - (a.tokens ?? -1) || a.name.localeCompare(b.name)
}

/** Discovers skills loaded by agy (user, project, and built-in) with frontmatter token estimates. */
export async function estimateAgySkills(
  cwd: string,
  home = os.homedir(),
): Promise<ContextDefinitionEstimate[]> {
  const byName = new Map<string, number>()
  const roots = [
    path.join(cwd, '.agents', 'skills'),
    path.join(home, '.agents', 'skills'),
    path.join(home, '.gemini', 'antigravity-cli', 'skills'),
    path.join(home, '.gemini', 'antigravity-cli', 'builtin', 'skills'),
  ]
  for (const root of roots) {
    await scanSkillFolder(root, byName)
  }
  return [...byName.entries()].map(([name, tokens]) => ({ name, tokens })).sort(bySize)
}

/** Lists MCP servers active on an agy session. */
export function estimateAgyMcpServers(
  servers: readonly McpServer[] | undefined,
): ContextDefinitionEstimate[] {
  const seen = new Set<string>()
  const out: ContextDefinitionEstimate[] = []
  for (const server of servers ?? []) {
    if (seen.has(server.name)) continue
    seen.add(server.name)
    out.push({ name: server.name, tokens: null })
  }
  return out.sort(bySize)
}

export async function readAgyContextEstimates(
  cwd: string,
  servers: readonly McpServer[] | undefined,
  home = os.homedir(),
): Promise<ContextEstimates> {
  const skills = await estimateAgySkills(cwd, home)
  const mcpServers = estimateAgyMcpServers(servers)
  return {
    skills: skills.length > 0 ? skills : null,
    mcpServers: mcpServers.length > 0 ? mcpServers : null,
  }
}

export interface AgyContextInput {
  cwd: string
  home?: string
  model: string | null
  used: number
  size: number
  servers?: readonly McpServer[]
  now?: number
}

/** Builds a non-invasive `ContextBreakdown` combining live ACP usage with local metadata sizes. */
export async function buildAgyContextBreakdown(input: AgyContextInput): Promise<ContextBreakdown> {
  const home = input.home ?? os.homedir()
  const now = input.now ?? Date.now()
  const [instructions, skills] = await Promise.all([
    readInstructionFiles(input.cwd, home),
    estimateAgySkills(input.cwd, home),
  ])
  const mcpServers = estimateAgyMcpServers(input.servers)

  const instructionTokens = instructions.reduce((sum, item) => sum + item.tokens, 0)
  const skillTokens = skills.reduce((sum, item) => sum + (item.tokens ?? 0), 0)
  const used = Math.max(0, input.used)
  const size = Math.max(0, input.size)
  const share = (tokens: number): number | null => (size > 0 ? tokens / size : null)

  const categories: ContextBreakdown['categories'] = []
  if (used > 0) {
    // Cap static estimates so they never exceed the actual reported context window usage.
    const shownInstructions = Math.min(instructionTokens, used)
    const remainingAfterInstructions = Math.max(0, used - shownInstructions)
    const shownSkills = Math.min(skillTokens, remainingAfterInstructions)
    const conversation = Math.max(0, remainingAfterInstructions - shownSkills)

    if (shownInstructions > 0) {
      categories.push({
        name: 'Memory & Instructions',
        tokens: shownInstructions,
        share: share(shownInstructions),
      })
    }
    if (shownSkills > 0) {
      categories.push({
        name: 'Skills',
        tokens: shownSkills,
        share: share(shownSkills),
      })
    }
    if (conversation > 0) {
      categories.push({
        name: 'Messages',
        tokens: conversation,
        share: share(conversation),
      })
    }
  }

  const lists: ContextList[] = []
  if (instructions.length > 0) {
    lists.push({
      name: 'Memory Files',
      items: instructions.map((item) => ({
        name: item.display,
        detail: null,
        tokens: compactTokens(item.tokens),
      })),
    })
  }
  if (skills.length > 0) {
    lists.push({
      name: 'Skills',
      items: skills.map((item) => ({
        name: item.name,
        detail: null,
        tokens: item.tokens !== null ? compactTokens(item.tokens) : '',
      })),
    })
  }
  if (mcpServers.length > 0) {
    lists.push({
      name: 'MCP Servers',
      items: mcpServers.map((item) => ({
        name: item.name,
        detail: null,
        tokens: item.tokens !== null ? compactTokens(item.tokens) : '',
      })),
    })
  }

  return {
    model: input.model,
    used,
    size,
    categories,
    lists,
    observedAt: now,
  }
}
