// A Vite plugin that writes third-party-notices.txt into the build folder: every third-party
// package the build ships, each once, with its version, its license and the text of the license
// and notice files it ships.

import { existsSync, readdirSync, readFileSync, realpathSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import type { Plugin } from 'vite'

/** A shipped package as the notices list it. */
export interface Notice {
  name: string
  version: string
  /** Its package.json `license`, or null when it names none. */
  license: string | null
  /** Its license and notice files, by path from the package's folder, with their text. */
  files: { name: string; text: string }[]
  /** Extra notice lines printed under the license. */
  lines: string[]
}

const LICENSE_FILE = /^(?:licen[cs]e|copying|notice)(?:[-._].*)?$/i
const RULE = '='.repeat(80)
const FILE_RULE = '-'.repeat(80)

/** The folder of the package a bundled module comes from, or null for the app's own code. */
export function packageDirOf(id: string): string | null {
  const file = id
    .replace(/^\0/, '')
    .replace(/[?#].*$/, '')
    .replaceAll('\\', '/')
  const at = file.lastIndexOf('/node_modules/')
  if (at < 0) return null
  const [first, second] = file.slice(at + '/node_modules/'.length).split('/')
  const name = first?.startsWith('@') ? [first, second] : [first]
  if (name.some((part) => !part || part.startsWith('.'))) return null
  return `${file.slice(0, at)}/node_modules/${name.join('/')}`
}

/** The packages of the modules that have code in a bundle's chunks. */
export function bundledPackages(bundle: Record<string, unknown>): string[] {
  const dirs = new Set<string>()
  for (const output of Object.values(bundle) as BundleOutput[]) {
    if (output.type !== 'chunk') continue
    for (const [id, module] of Object.entries(output.modules)) {
      if (module.renderedLength === 0) continue
      const dir = packageDirOf(id)
      if (dir) dirs.add(dir)
    }
  }
  return [...dirs]
}

interface BundleOutput {
  type: string
  modules: Record<string, { renderedLength: number }>
}

interface PackageJson {
  name?: unknown
  version?: unknown
  license?: unknown
  licenses?: unknown
}

function readPackage(dir: string): PackageJson {
  return JSON.parse(readFileSync(path.join(dir, 'package.json'), 'utf8')) as PackageJson
}

/** Where Node finds `name` from `from`: the nearest `node_modules` up the tree that holds it. */
function locate(from: string, name: string): string | null {
  for (let dir = from; ; dir = path.dirname(dir)) {
    const candidate = path.join(dir, 'node_modules', name)
    if (existsSync(path.join(candidate, 'package.json'))) return realpathSync(candidate)
    if (path.dirname(dir) === dir) return null
  }
}

function licenseOf(pkg: PackageJson): string | null {
  if (typeof pkg.license === 'string' && pkg.license.trim()) return pkg.license.trim()
  if (isTyped(pkg.license)) return pkg.license.type
  if (Array.isArray(pkg.licenses)) {
    const types = pkg.licenses.filter(isTyped).map((license) => license.type)
    if (types.length > 0) return types.join(' OR ')
  }
  return null
}

function isTyped(value: unknown): value is { type: string } {
  return (
    typeof value === 'object' && value !== null && typeof Reflect.get(value, 'type') === 'string'
  )
}

/** A package's notice: its name, version, license and the license and notice files it ships. */
export function readNotice(dir: string): Notice {
  const pkg = readPackage(dir)
  const name = typeof pkg.name === 'string' ? pkg.name : path.basename(dir)
  const version = typeof pkg.version === 'string' ? pkg.version : 'unknown'
  const files = readdirSync(dir, { withFileTypes: true })
    .filter((entry) => entry.isFile() && LICENSE_FILE.test(entry.name))
    .map((entry) => entry.name)
    .sort()
    .map((file) => ({ name: file, text: readFileSync(path.join(dir, file), 'utf8').trim() }))
  const license = licenseOf(pkg)
  if (files.length === 0 && !license) {
    throw new Error(`${name}@${version} ships no license file and names no license`)
  }
  return { name, version, license, files, lines: [] }
}

/**
 * The notices for a standalone build: its bundled packages and the `external` ones it loads from
 * beside the bundle, each package once.
 */
export function standaloneNotices(
  root: string,
  bundled: Iterable<string>,
  external: readonly string[],
): Notice[] {
  const dirs = new Set([...bundled].map((dir) => realpathSync(dir)))
  for (const name of external) {
    const dir = locate(root, name)
    if (!dir) throw new Error(`${name}, which the build loads from beside it, is not installed`)
    dirs.add(dir)
  }
  return [...dirs].map(readNotice)
}

/** The text of third-party-notices.txt: the notices sorted by name, each package once. */
export function renderNotices(notices: Notice[]): string {
  const unique = new Map(notices.map((notice) => [`${notice.name}@${notice.version}`, notice]))
  const sorted = [...unique.values()].sort(
    (a, b) => compare(a.name, b.name) || compare(a.version, b.version),
  )
  const parts = [
    'Third-party notices for Sarto\n\n' +
      'Sarto ships the packages below. Each is listed with its version, its license and the ' +
      'license and notice files it ships.\n',
  ]
  for (const notice of sorted) {
    let entry = `${RULE}\n${notice.name} ${notice.version}\nLicense: ${notice.license ?? 'none named'}\n`
    for (const line of notice.lines) entry += `${line}\n`
    if (notice.files.length === 0) entry += 'It ships no license file.\n'
    for (const file of notice.files) entry += `${FILE_RULE}\n${file.name}\n\n${file.text}\n`
    parts.push(entry)
  }
  return parts.join('\n')
}

function compare(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0
}

/**
 * Vite plugin that writes third-party-notices.txt into the build's own output folder.
 */
export function standaloneThirdPartyNotices(
  root: string,
  external: string[] = [],
  extra: Notice[] = [],
): Plugin {
  const bundled = new Set<string>()
  let outDir = ''
  return {
    name: 'sarto:standalone-third-party-notices',
    apply: 'build',
    configResolved(config) {
      outDir = path.resolve(config.root, config.build.outDir)
    },
    generateBundle(_, bundle) {
      for (const dir of bundledPackages(bundle)) bundled.add(dir)
    },
    closeBundle() {
      writeFileSync(
        path.join(outDir, 'third-party-notices.txt'),
        renderNotices([...standaloneNotices(root, bundled, external), ...extra]),
      )
    },
  }
}
