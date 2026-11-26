// The themes folder in the data folder: every file read and checked in full, installing from a
// file, replacing and removing them, and the chosen theme. The desktop app's dialogs
// for it are in theme-dialogs.ts, so the daemon keeps themes too.

import { createHash, randomUUID } from 'node:crypto'
import { open, readdir, rm } from 'node:fs/promises'
import { join } from 'node:path'
import type { HostThemes } from '@shared/remote/host-admin'
import {
  BUILTIN_THEME_ID,
  parseColor,
  parseThemeFile,
  THEME_ID,
  THEME_MAX_BYTES,
  themeSlug,
  toHex,
  type InstalledTheme,
  type Rgba,
  type Theme,
  type ThemeColors,
  type ThemeFileError,
  type ThemeInstallResult,
  type ThemeLoadFailure,
  type ThemeMode,
  type ThemesState,
} from '@shared/themes'
import { writeFileAtomic } from './json-file'
import { createLogger, describeError } from './log'

const log = createLogger('themes')

// Fatal, so a file that is not UTF-8 is refused rather than read with replacement characters.
const UTF8 = new TextDecoder('utf-8', { fatal: true })

/** The id a theme's name gives, or `theme-` and a hash of the name when no ASCII is left. */
export function themeId(name: string): string {
  return themeSlug(name) || `theme-${createHash('sha256').update(name).digest('hex').slice(0, 8)}`
}

export type ThemeReadResult =
  | { ok: true; theme: Theme; ignored: string[]; text: string }
  | { ok: false; error: ThemeFileError | { code: 'unreadable' } }

/** The file's bytes, or null when it holds more than `max`. */
async function readCapped(path: string, max: number): Promise<Buffer | null> {
  const handle = await open(path, 'r')
  try {
    const buffer = Buffer.alloc(max + 1)
    let length = 0
    while (length < buffer.length) {
      const { bytesRead } = await handle.read(buffer, length, buffer.length - length, length)
      if (bytesRead === 0) break
      length += bytesRead
    }
    return length > max ? null : buffer.subarray(0, length)
  } finally {
    await handle.close()
  }
}

/** Reads a theme file and checks all of it; `text` is what an install writes. */
export async function readThemeFile(path: string): Promise<ThemeReadResult> {
  let data: Buffer | null
  try {
    data = await readCapped(path, THEME_MAX_BYTES)
  } catch (error) {
    log.warn(`Could not read ${path}: ${describeError(error)}`)
    return { ok: false, error: { code: 'unreadable' } }
  }
  if (!data) return { ok: false, error: { code: 'too-large' } }
  return checkThemeBytes(data)
}

/** Checks a theme file's text as a device sent it, held to a file's size. */
export function checkThemeText(text: string): ThemeReadResult {
  const data = Buffer.from(text, 'utf8')
  if (data.length > THEME_MAX_BYTES) return { ok: false, error: { code: 'too-large' } }
  return checkThemeBytes(data)
}

/** Checks a theme file's bytes, from disk or the catalog. */
function checkThemeBytes(
  data: Buffer,
): Exclude<ThemeReadResult, { ok: false }> | { ok: false; error: ThemeFileError } {
  let text: string
  try {
    text = UTF8.decode(data)
  } catch {
    return { ok: false, error: { code: 'not-json' } }
  }
  const result = parseThemeFile(text)
  return result.ok ? { ...result, text } : result
}

function describeFailure(failure: ThemeLoadFailure): string {
  if (failure.code !== 'invalid') return failure.code
  const { error } = failure
  if ('path' in error) return `${error.code} (${error.path})`
  if ('variant' in error) return `${error.code} (${error.variant})`
  return error.code
}

/** What the folder holds: the themes that pass the check, by name, and why the others fail. */
export interface ThemeFolder {
  installed: InstalledTheme[]
  failed: Map<string, ThemeLoadFailure>
}

/** Reads every `<id>.json` in the folder; a missing folder holds no themes. */
export async function readThemeFolder(dir: string): Promise<ThemeFolder> {
  const folder: ThemeFolder = { installed: [], failed: new Map() }
  let names: string[]
  try {
    names = await readdir(dir)
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') {
      log.warn(`Could not read ${dir}: ${describeError(error)}`)
    }
    return folder
  }
  const ids = names.flatMap((name) => {
    if (!name.endsWith('.json')) return []
    const id = name.slice(0, -'.json'.length)
    if (THEME_ID.test(id) && id !== BUILTIN_THEME_ID) return [id]
    log.warn(`Skipped themes/${name}: its name is not a theme id`)
    return []
  })
  const results = await Promise.all(ids.map((id) => readThemeFile(join(dir, `${id}.json`))))
  ids.forEach((id, i) => {
    const result = results[i]!
    if (result.ok) {
      folder.installed.push({ id, theme: result.theme, ignored: result.ignored })
      return
    }
    const failure: ThemeLoadFailure =
      result.error.code === 'unreadable'
        ? { code: 'unreadable' }
        : { code: 'invalid', error: result.error }
    folder.failed.set(id, failure)
    log.warn(`Skipped themes/${id}.json: ${describeFailure(failure)}`)
  })
  folder.installed.sort(
    (a, b) => a.theme.name.localeCompare(b.theme.name) || a.id.localeCompare(b.id),
  )
  return folder
}

const snapshot = (folder: ThemeFolder) => JSON.stringify([folder.installed, [...folder.failed]])

export interface ThemeStoreDeps {
  /** `themes/` in the data folder. */
  dir: string
  /** Makes `id` the setting; the change comes back through `choose`. */
  select(id: string): void
  /** After an install, a removal, a change found on disk or another theme chosen. */
  changed(state: ThemesState, chosen: Theme | null): void
}

/** Makes an installed theme the one that shows: the setting's, or a device's own. */
export type ThemeSelect = (id: string) => void

/** Owns the themes folder; the setting, `appearance.colorTheme`, says which theme shows. */
export class ThemeStore {
  // A checked file that an install answer offered to put in place of an installed theme.
  private pending: {
    token: string
    id: string
    text: string
    ignored: string[]
    select: ThemeSelect
  } | null = null
  // Changes to the folder, one at a time, so two installs never write the same file at once.
  private queue: Promise<unknown> = Promise.resolve()

  constructor(
    private folder: ThemeFolder,
    private chosen: string,
    private readonly deps: ThemeStoreDeps,
  ) {
    this.logFailure()
  }

  state(): ThemesState {
    const { chosen, folder } = this
    const failure: ThemeLoadFailure | null =
      chosen === BUILTIN_THEME_ID || this.find(chosen)
        ? null
        : (folder.failed.get(chosen) ?? { code: 'missing' })
    return { installed: folder.installed, chosen, failed: failure && { id: chosen, failure } }
  }

  /** What a device lists: every theme the folder holds, whichever one this host shows. */
  hostThemes(): HostThemes {
    const failed = [...this.folder.failed].map(([id, failure]) => ({ id, failure }))
    return { installed: this.state().installed, failed }
  }

  /** The chosen theme, or null while the built-in one shows. */
  chosenTheme(): Theme | null {
    return this.find(this.chosen)?.theme ?? null
  }

  /** The setting changed, perhaps to another theme. */
  choose(id: string): void {
    if (id === this.chosen) return
    this.chosen = id
    this.logFailure()
    this.publish()
  }

  /** `themes:get`: reads the folder again, so a file changed by hand shows. */
  async refresh(): Promise<ThemesState> {
    const before = snapshot(this.folder)
    this.folder = await readThemeFolder(this.deps.dir)
    if (snapshot(this.folder) !== before) this.publish()
    return this.state()
  }

  /**
   * Installs a checked file, or names the installed theme it would replace; `file` names it in a
   * failure. Installing shows the theme through `select`, a device's own when a device installs it.
   */
  async add(
    file: string,
    read: ThemeReadResult,
    select: ThemeSelect = this.deps.select,
  ): Promise<ThemeInstallResult> {
    this.pending = null
    if (!read.ok) return { status: 'failed', file, error: read.error }
    const id = themeId(read.theme.name)
    this.folder = await readThemeFolder(this.deps.dir)
    const installed = this.find(id)
    if (installed || this.folder.failed.has(id)) {
      const token = randomUUID()
      this.pending = { token, id, text: read.text, ignored: read.ignored, select }
      return {
        status: 'conflict',
        token,
        name: read.theme.name,
        installedName: installed?.theme.name ?? id,
      }
    }
    return this.write(id, read.text, read.ignored, true, select)
  }

  /** `themes:replace`: installs the file the last install answer named. */
  async replace(token: unknown): Promise<ThemeInstallResult> {
    const pending = this.pending
    if (!pending || token !== pending.token) throw new Error('No theme is waiting to be installed')
    this.pending = null
    return this.write(pending.id, pending.text, pending.ignored, true, pending.select)
  }

  /** `themes:remove`: deletes the file; removing the chosen theme brings back the built-in one. */
  async remove(id: unknown): Promise<void> {
    const file = this.fileOf(id)
    await this.serial(async () => {
      await rm(file, { force: true })
      this.folder = await readThemeFolder(this.deps.dir)
    })
    if (id === this.chosen) this.deps.select(BUILTIN_THEME_ID)
    else this.publish()
  }

  /** The name of the theme in a file the renderer built to export, checked in full. */
  exportName(text: unknown): string {
    if (typeof text !== 'string') throw new Error('A theme file must be text')
    const parsed = parseThemeFile(text)
    if (!parsed.ok) throw new Error(`Not a theme file: ${parsed.error.code}`)
    return parsed.theme.name
  }

  private find(id: string): InstalledTheme | undefined {
    return this.folder.installed.find((theme) => theme.id === id)
  }

  /** The file of a theme the folder holds, for an id from a window or a device. */
  fileOf(id: unknown): string {
    if (typeof id !== 'string' || !(this.find(id) || this.folder.failed.has(id))) {
      throw new Error('Not an installed theme')
    }
    return join(this.deps.dir, `${id}.json`)
  }

  /** Installs a checked file, and applies the theme unless `choose` is false. */
  private async write(
    id: string,
    text: string,
    ignored: string[],
    choose = true,
    select: ThemeSelect = this.deps.select,
  ): Promise<{ status: 'installed'; id: string; ignored: string[] }> {
    await this.serial(async () => {
      await writeFileAtomic(join(this.deps.dir, `${id}.json`), text)
      this.folder = await readThemeFolder(this.deps.dir)
    })
    if (choose && select !== this.deps.select) {
      select(id)
      this.publish()
    } else if (choose && id !== this.chosen) {
      // Through the setting, unless the theme is the chosen one already.
      select(id)
    } else this.publish()
    return { status: 'installed', id, ignored }
  }

  private serial<T>(task: () => Promise<T>): Promise<T> {
    const run = this.queue.then(task, task)
    this.queue = run.catch(() => undefined)
    return run
  }

  private publish(): void {
    this.deps.changed(this.state(), this.chosenTheme())
  }

  private logFailure(): void {
    const { failed } = this.state()
    if (failed) {
      log.warn(`The theme ${failed.id} could not load (${describeFailure(failed.failure)})`)
    }
  }
}

export interface WindowColors {
  background: string
  symbol: string
}

const WHITE: Rgba = { r: 1, g: 1, b: 1, a: 1 }
const BLACK: Rgba = { r: 0, g: 0, b: 0, a: 1 }

/**
 * A variant's window colors in hex, which Electron takes: its desk, `bg-sidebar`, laid over white
 * in light and black in dark, and its `text-primary` over that; `fallback` for what it leaves out.
 */
export function windowColors(
  colors: ThemeColors,
  mode: ThemeMode,
  fallback: WindowColors,
): WindowColors {
  const color = (token: 'bg-sidebar' | 'text-primary') => {
    const value = colors[token]
    return value === undefined ? null : parseColor(value)
  }
  const bg = color('bg-sidebar')
  const background = bg ? toHex(bg, mode === 'light' ? WHITE : BLACK) : fallback.background
  const fg = color('text-primary')
  return { background, symbol: fg ? toHex(fg, parseColor(background)!) : fallback.symbol }
}
