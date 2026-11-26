import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { ProgramOptions, ProgramRun } from '../adapter-install'
import { TextRing } from '../ring'
import {
  agyPluginDetails,
  agyPluginId,
  agyPluginName,
  installAgyPlugin,
  listAgyPlugins,
  parseAgyPluginList,
  setAgyPluginEnabled,
  uninstallAgyPlugin,
  type AgyCli,
} from './agy-plugins'

describe('agy-plugins', () => {
  let dir: string

  beforeEach(async () => {
    dir = await mkdtemp(path.join(tmpdir(), 'sarto-agy-plugins-'))
  })

  afterEach(async () => {
    await rm(dir, { recursive: true, force: true })
  })

  it('parses agy plugin list --json and normalizes identifiers', () => {
    const stdout = JSON.stringify([
      {
        name: 'progress-narrator',
        enabled: true,
        path: '/Users/me/.gemini/config/plugins/progress-narrator',
        rules: ['AGENTS.md'],
      },
      {
        name: 'disabled-one',
        enabled: false,
        path: '/Users/me/.gemini/config/plugins/disabled-one',
      },
      {
        name: '../invalid',
        enabled: true,
      },
    ])
    const parsed = parseAgyPluginList(stdout)
    expect(parsed).toHaveLength(2)
    expect(parsed[0]!.name).toBe('progress-narrator')
    expect(parsed[0]!.enabled).toBe(true)
    expect(parsed[1]!.enabled).toBe(false)
    expect(agyPluginId('progress-narrator')).toBe('progress-narrator@antigravity')
    expect(agyPluginName('progress-narrator@antigravity')).toBe('progress-narrator')
    expect(() => agyPluginName('../bad@antigravity')).toThrow()
    expect(() => agyPluginName('progress-narrator@--flag')).toThrow()
    expect(() => agyPluginName('progress-narrator@../evil')).toThrow()
    expect(() => agyPluginName('progress-narrator@')).toThrow()
    expect(() => agyPluginName('progress-narrator@a@b')).toThrow()
  })

  it('invokes official agy plugin subcommands with safe argv arrays', async () => {
    const calls: (readonly string[])[] = []
    const listed = [
      {
        name: 'progress-narrator',
        enabled: true,
        path: path.join(dir, 'progress-narrator'),
        rules: ['AGENTS.md'],
      },
    ]
    const cli: AgyCli = {
      agentId: 'antigravity',
      program: '/usr/local/bin/agy',
      env: {},
      platform: 'darwin',
      run: async (options: ProgramOptions): Promise<ProgramRun> => {
        calls.push(options.args)
        const stdout = options.args[1] === 'list' ? JSON.stringify(listed) : ''
        return {
          code: 0,
          signal: null,
          timedOut: false,
          aborted: false,
          output: new TextRing(4096),
          stdout,
        }
      },
    }

    const result = await listAgyPlugins(cli)
    expect(result.installed).toEqual([
      {
        id: 'progress-narrator@antigravity',
        harness: 'antigravity',
        agentId: 'antigravity',
        version: null,
        scope: 'user',
        enabled: true,
        projectPath: null,
      },
    ])
    expect(result.paths['progress-narrator@antigravity']).toBe(path.join(dir, 'progress-narrator'))

    await setAgyPluginEnabled(cli, 'progress-narrator@antigravity', false)
    await setAgyPluginEnabled(cli, 'progress-narrator@antigravity', true)
    await installAgyPlugin(cli, 'progress-narrator@official-mp')
    await uninstallAgyPlugin(cli, 'progress-narrator@antigravity')

    expect(calls).toEqual([
      ['plugin', 'list', '--json'],
      ['plugin', 'disable', 'progress-narrator'],
      ['plugin', 'enable', 'progress-narrator'],
      ['plugin', 'install', 'progress-narrator@official-mp'],
      ['plugin', 'list', '--json'],
      ['plugin', 'uninstall', 'progress-narrator'],
    ])
  })

  it('reads plugin details from local plugin.json, rules, and skills directories', async () => {
    const pluginDir = path.join(dir, 'progress-narrator')
    await mkdir(path.join(pluginDir, 'rules'), { recursive: true })
    await mkdir(path.join(pluginDir, 'skills', 'demo-skill'), { recursive: true })
    await writeFile(
      path.join(pluginDir, 'plugin.json'),
      JSON.stringify({ name: 'progress-narrator', description: 'Live narration rule' }),
    )
    await writeFile(path.join(pluginDir, 'rules', 'AGENTS.md'), 'Always narrate progress clearly.')

    const details = await agyPluginDetails(
      'antigravity',
      'progress-narrator@antigravity',
      pluginDir,
    )
    expect(details.description).toBe('Live narration rule')
    expect(details.skills).toEqual(['demo-skill'])
    expect(details.hooks).toEqual(['AGENTS.md'])
    expect(details.alwaysOnTokens).toBeGreaterThan(0)
  })
})
