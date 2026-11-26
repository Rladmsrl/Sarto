import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { buildAgyContextBreakdown, readAgyContextEstimates } from './agy-context'

describe('agy-context', () => {
  let root: string
  let home: string
  let cwd: string

  beforeEach(async () => {
    root = await mkdtemp(path.join(tmpdir(), 'sarto-agy-context-'))
    home = path.join(root, 'home')
    cwd = path.join(root, 'repo')
    await mkdir(path.join(home, '.gemini'), { recursive: true })
    await mkdir(path.join(home, '.agents', 'skills', 'demo-skill'), { recursive: true })
    await mkdir(cwd, { recursive: true })

    await writeFile(path.join(home, '.gemini', 'GEMINI.md'), 'Global instructions '.repeat(40))
    await writeFile(path.join(cwd, 'AGENTS.md'), 'Project instructions '.repeat(60))
    await writeFile(
      path.join(home, '.agents', 'skills', 'demo-skill', 'SKILL.md'),
      '---\nname: demo-skill\ndescription: A helpful skill for testing context estimates.\n---\nBody\n',
    )
  })

  afterEach(async () => {
    await rm(root, { recursive: true, force: true })
  })

  it('builds layered context breakdown and estimates without exceeding reported usage', async () => {
    const servers = [
      { type: 'http' as const, name: 'sarto', url: 'http://127.0.0.1:1/mcp', headers: [] },
    ]
    const breakdown = await buildAgyContextBreakdown({
      cwd,
      home,
      model: 'gemini-4-neon',
      used: 50_000,
      size: 1_000_000,
      servers,
      now: 1_700_000_000_000,
    })

    expect(breakdown.model).toBe('gemini-4-neon')
    expect(breakdown.used).toBe(50_000)
    expect(breakdown.size).toBe(1_000_000)
    expect(breakdown.categories.map((c) => c.name)).toEqual([
      'Memory & Instructions',
      'Skills',
      'Messages',
    ])
    const sum = breakdown.categories.reduce((acc, c) => acc + c.tokens, 0)
    expect(sum).toBe(50_000)
    expect(breakdown.lists.map((l) => l.name)).toEqual(['Memory Files', 'Skills', 'MCP Servers'])

    const estimates = await readAgyContextEstimates(cwd, servers, home)
    expect(estimates.skills?.some((s) => s.name === 'demo-skill' && (s.tokens ?? 0) > 0)).toBe(true)
    expect(estimates.mcpServers).toEqual([{ name: 'sarto', tokens: null }])
  })
})
