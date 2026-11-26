// Whether a terminal's program waits for a password. Programs that read one (sudo, ssh, git) turn
// the terminal's echo off and keep canonical input on, while full-screen programs and the shell's
// own line editor turn both off; this is how iTerm2 tells a password prompt too.

import { execFile } from 'node:child_process'
import type { Platform } from '@shared/platform'

export interface TtyModes {
  echo: boolean
  icanon: boolean
}

/** The echo and canonical input flags in `stty -a` output, or null when it names neither. */
export function parseTtyModes(output: string): TtyModes | null {
  const flags = new Set(output.split(/\s+/))
  const flag = (name: string): boolean | null =>
    flags.has(name) ? true : flags.has(`-${name}`) ? false : null
  const echo = flag('echo')
  const icanon = flag('icanon')
  return echo === null || icanon === null ? null : { echo, icanon }
}

export function readsPassword(modes: TtyModes): boolean {
  return !modes.echo && modes.icanon
}

const STTY_TIMEOUT_MS = 1000

/** Reads a pty's modes from its device with `stty`; null when it cannot be read. */
export function readTtyModes(platform: Platform, device: string): Promise<TtyModes | null> {
  if (!device.startsWith('/dev/')) return Promise.resolve(null)
  const deviceFlag = platform === 'darwin' ? '-f' : '-F'
  return new Promise((resolve) => {
    execFile(
      'stty',
      ['-a', deviceFlag, device],
      // A Dock-started app may lack these on its PATH.
      {
        timeout: STTY_TIMEOUT_MS,
        env: { ...process.env, PATH: `${process.env.PATH ?? ''}:/bin:/usr/bin` },
      },
      (error, stdout) => resolve(error ? null : parseTtyModes(String(stdout))),
    )
  })
}
