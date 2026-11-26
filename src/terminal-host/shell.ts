import { access, constants, stat } from 'node:fs/promises'
import { posix } from 'node:path'
import { withLongPaths } from '@shared/git'
import type { Platform } from '@shared/platform'

export interface ShellSpec {
  file: string
  args: string[]
  name: string // the program name, such as "zsh" or "bash"
}

export type Environment = Record<string, string | undefined>

/** Finds a program on PATH, returning its full path; injected so tests need no real PATH. */
export type FindOnPath = (program: string) => Promise<string | null>

export function programName(file: string): string {
  return posix.basename(file)
}

/**
 * The shell a new terminal runs: the program picked in Settings, else `$SHELL` as a login shell
 * on macOS and Linux.
 */
export async function resolveShell(
  platform: Platform,
  env: Environment,
  override: string | null,
): Promise<ShellSpec> {
  if (override) return { file: override, args: ['-l'], name: programName(override) }
  const fallback = platform === 'darwin' ? '/bin/zsh' : '/bin/bash'
  const shell = env.SHELL && posix.isAbsolute(env.SHELL) ? env.SHELL : fallback
  return { file: shell, args: ['-l'], name: programName(shell) }
}

async function isFile(path: string): Promise<boolean> {
  try {
    if (!(await stat(path)).isFile()) return false
    await access(path, constants.X_OK)
    return true
  } catch {
    return false
  }
}

/** Looks a program up on PATH as the shell would, without running anything. */
export function pathLookup(env: Environment): FindOnPath {
  const entries = (env.PATH ?? '')
    .split(posix.delimiter)
    .map((entry) => entry.replace(/^"(.*)"$/, '$1'))
    .filter((entry) => entry.length > 0 && posix.isAbsolute(entry))
  return async (program) => {
    for (const entry of entries) {
      const candidate = posix.join(entry, program)
      if (await isFile(candidate)) return candidate
    }
    return null
  }
}

/**
 * The environment of a shell: main's own without Electron's variables, plus what terminal
 * programs look for. LANG is set on macOS when unset, as it is for apps started from the Dock,
 * so programs print UTF-8.
 */
export function shellEnvironment(
  base: Environment,
  platform: Platform,
  appVersion: string,
): Record<string, string> {
  const env: Record<string, string> = {}
  for (const [key, value] of Object.entries(base)) {
    if (value === undefined || key.toUpperCase().startsWith('ELECTRON_')) continue
    env[key] = value
  }
  env.TERM = 'xterm-256color'
  env.COLORTERM = 'truecolor'
  env.TERM_PROGRAM = 'Sarto'
  env.TERM_PROGRAM_VERSION = appVersion
  if (platform === 'darwin' && !env.LANG) env.LANG = 'en_US.UTF-8'
  return withLongPaths(env, platform)
}
