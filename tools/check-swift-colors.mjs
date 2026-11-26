// @ts-check
// Fails when a Swift file outside PrismDesign gains a raw `Color(hex:` color. The apps take their
// colors from PrismTokens; the files below predate the rule and may only lose theirs. Lower an
// entry as a file drops colors, and remove it at 0; a file not listed may have none.
//
// Usage: node tools/check-swift-colors.mjs

import { readdir, readFile } from 'node:fs/promises'
import { dirname, join, relative, sep } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const EXEMPT = 'apps/apple/Packages/PrismDesign'
const SKIPPED_DIRS = new Set([
  '.build',
  '.cache',
  '.git',
  '.swiftpm',
  '.worktrees',
  'DerivedData',
  'dist',
  'node_modules',
  'out',
])
const PATTERN = /(?<!\w)Color\(hex:/g

/** @type {Record<string, number>} */
const ALLOWED = {
  'apps/apple/Shared/GitFlowViews.swift': 6,
  'apps/apple/Shared/NewSessionSheet.swift': 3,
  'apps/apple/Shared/SartoState.swift': 9,
  'apps/apple/Shared/ThreadRichContentViews.swift': 10,
  'apps/apple/Shared/WorkbenchPanes.swift': 9,
  'apps/apple/macOS/ComposerPopoversView.swift': 2,
  'apps/apple/macOS/DynamicIsland/IslandSignals.swift': 9,
  'apps/apple/macOS/MacSidebarView.swift': 5,
  'apps/apple/macOS/MacWorkbenchView.swift': 10,
  'apps/apple/macOS/NewSessionStageView.swift': 8,
  'apps/apple/macOS/RunningSessionsRail.swift': 4,
  'apps/apple/macOS/Settings/SettingsClientSectionsView.swift': 10,
}

/**
 * @param {string} dir
 * @returns {AsyncGenerator<string>}
 */
async function* swiftFiles(dir) {
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name)
    if (entry.isDirectory()) {
      if (SKIPPED_DIRS.has(entry.name)) continue
      if (relative(ROOT, path).split(sep).join('/') === EXEMPT) continue
      yield* swiftFiles(path)
    } else if (entry.isFile() && entry.name.endsWith('.swift')) {
      yield path
    }
  }
}

/** @type {Map<string, number>} */
const counts = new Map()
for await (const path of swiftFiles(ROOT)) {
  const count = ((await readFile(path, 'utf8')).match(PATTERN) ?? []).length
  if (count > 0) counts.set(relative(ROOT, path).split(sep).join('/'), count)
}

const over = []
for (const [file, count] of counts) {
  const allowed = ALLOWED[file] ?? 0
  if (count > allowed) over.push(`  ${file}: ${count} raw Color(hex:) colors, ${allowed} allowed`)
}
for (const [file, allowed] of Object.entries(ALLOWED)) {
  const count = counts.get(file) ?? 0
  if (count < allowed) {
    console.warn(
      `${file} has ${count} raw Color(hex:) colors; lower its entry in ${relative(ROOT, fileURLToPath(import.meta.url))} to ${count}.`,
    )
  }
}

if (over.length > 0) {
  console.error('Swift files outside PrismDesign must take their colors from PrismTokens:')
  console.error(over.join('\n'))
  process.exitCode = 1
}
