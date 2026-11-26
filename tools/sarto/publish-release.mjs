// @ts-check
// Publishes a release folder that tools/sarto/release.mjs built to the Sarto server's releases
// folder (SARTO_RELEASES_DIR), over SSH or locally: the release's files first, then channel
// manifests and pointers replaced atomically with a rename, so no client sees a manifest whose
// files are not on disk yet.
//
//   node tools/sarto/publish-release.mjs dist/release/v0.4.0 user@host:/srv/sarto/releases
//   node tools/sarto/publish-release.mjs dist/release/app-v0.4.0-beta.261125143512 user@host:/srv/sarto/releases
//   node tools/sarto/publish-release.mjs dist/release/daemon-v0.5.0 /local/releases/folder

import { execFile as execFileCb } from 'node:child_process'
import { existsSync } from 'node:fs'
import { copyFile, mkdir, readFile, rename, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { promisify } from 'node:util'
import { isValidTag } from './build-version.mjs'

const execFile = promisify(execFileCb)

/** @param {string} message @returns {never} */
function fail(message) {
  console.error(`sarto publish: ${message}`)
  process.exit(1)
}

/** Quotes a word for the remote shell. @param {string} word */
const quote = (word) => `'${word.replaceAll("'", "'\\''")}'`

const [folder, target] = process.argv.slice(2)
if (!folder || !target)
  fail('Usage: publish-release.mjs <release folder> <[user@host:]releases folder>')

const resolvedFolder = path.resolve(folder)
const tag = path.basename(resolvedFolder)
if (!isValidTag(tag) || !/^(?:v|app-v|daemon-v)/.test(tag)) {
  fail(`${folder} is not a release folder named v<ver>, app-v<ver> or daemon-v<ver>`)
}

const CHANNEL_MANIFESTS = [
  { file: 'latest-mac.json', pointer: 'latest-mac', requiresInstall: false },
  { file: 'beta-mac.json', pointer: 'beta-mac', requiresInstall: false },
  { file: 'latest-daemon.json', pointer: 'latest-daemon', requiresInstall: true },
  { file: 'beta-daemon.json', pointer: 'beta-daemon', requiresInstall: true },
]

const present = CHANNEL_MANIFESTS.filter(({ file }) => existsSync(path.join(resolvedFolder, file)))
if (present.length === 0) {
  fail(
    `${folder} has no signed manifest (expected latest-mac.json, beta-mac.json, latest-daemon.json or beta-daemon.json)`,
  )
}
for (const { file, requiresInstall } of present) {
  if (!existsSync(path.join(resolvedFolder, `${file}.sig`))) {
    fail(`${folder} has ${file} but no ${file}.sig`)
  }
  if (requiresInstall) {
    for (const needed of ['install.sh', 'install.sh.sig']) {
      if (!existsSync(path.join(resolvedFolder, needed))) {
        fail(`${folder} has ${file} but no ${needed}`)
      }
    }
  }
}

// The legacy `latest` pointer names the bare X.Y.Z of a stable `vX.Y.Z` folder. Older daemons follow
// it to `download/v<latest>/install.sh` and the install script to the daemon's package, so it moves
// only to a folder that carries the daemon too, never to an app-only one.
const legacyStableVersion =
  present.some((item) => item.file === 'latest-daemon.json') && /^v(\d+\.\d+\.\d+)$/.exec(tag)?.[1]

/** @param {string} file */
async function readManifestVersion(file) {
  try {
    const parsed = JSON.parse(await readFile(path.join(resolvedFolder, file), 'utf8'))
    return typeof parsed.version === 'string' ? parsed.version : tag
  } catch {
    return tag
  }
}

const hasHarnesses = existsSync(path.join(resolvedFolder, 'harnesses.json'))

const remote = /^([^/:]+):(\/.+)$/.exec(target)
if (remote) {
  const [, host, dir] = remote
  await execFile('ssh', [host, `mkdir -p ${quote(`${dir}/${tag}`)}`])
  await execFile('rsync', ['-a', `${resolvedFolder}/`, `${host}:${dir}/${tag}/`])

  /** @type {string[]} */
  const atomicMoves = []
  for (const { file, pointer } of present) {
    // Copy manifest & signature into releases root atomically so Sarto Cloud can serve
    // /releases/latest/download/<manifest> directly per channel.
    atomicMoves.push(
      `cp ${quote(`${dir}/${tag}/${file}`)} ${quote(`${dir}/${file}.tmp`)} && mv -f ${quote(`${dir}/${file}.tmp`)} ${quote(`${dir}/${file}`)}`,
      `cp ${quote(`${dir}/${tag}/${file}.sig`)} ${quote(`${dir}/${file}.sig.tmp`)} && mv -f ${quote(`${dir}/${file}.sig.tmp`)} ${quote(`${dir}/${file}.sig`)}`,
      `printf '%s\\n' ${quote(tag)} > ${quote(`${dir}/${pointer}.tmp`)} && mv -f ${quote(`${dir}/${pointer}.tmp`)} ${quote(`${dir}/${pointer}`)}`,
    )
  }
  if (hasHarnesses) {
    atomicMoves.push(
      `cp ${quote(`${dir}/${tag}/harnesses.json`)} ${quote(`${dir}/harnesses.json.tmp`)} && mv -f ${quote(`${dir}/harnesses.json.tmp`)} ${quote(`${dir}/harnesses.json`)}`,
    )
  }
  if (legacyStableVersion) {
    atomicMoves.push(
      `printf '%s\\n' ${quote(legacyStableVersion)} > ${quote(`${dir}/latest.tmp`)} && mv -f ${quote(`${dir}/latest.tmp`)} ${quote(`${dir}/latest`)}`,
    )
  }
  await execFile('ssh', [host, atomicMoves.join(' && ')])
} else {
  const dir = path.resolve(target)
  await mkdir(dir, { recursive: true })
  await execFile('rsync', ['-a', `${resolvedFolder}/`, `${path.join(dir, tag)}/`])
  for (const { file, pointer } of present) {
    await copyFile(path.join(resolvedFolder, file), path.join(dir, `${file}.tmp`))
    await rename(path.join(dir, `${file}.tmp`), path.join(dir, file))
    await copyFile(path.join(resolvedFolder, `${file}.sig`), path.join(dir, `${file}.sig.tmp`))
    await rename(path.join(dir, `${file}.sig.tmp`), path.join(dir, `${file}.sig`))
    await writeFile(path.join(dir, `${pointer}.tmp`), `${tag}\n`)
    await rename(path.join(dir, `${pointer}.tmp`), path.join(dir, pointer))
  }
  if (hasHarnesses) {
    await copyFile(
      path.join(resolvedFolder, 'harnesses.json'),
      path.join(dir, 'harnesses.json.tmp'),
    )
    await rename(path.join(dir, 'harnesses.json.tmp'), path.join(dir, 'harnesses.json'))
  }
  if (legacyStableVersion) {
    await writeFile(path.join(dir, 'latest.tmp'), `${legacyStableVersion}\n`)
    await rename(path.join(dir, 'latest.tmp'), path.join(dir, 'latest'))
  }
}

const summary = (
  await Promise.all(present.map(async ({ file }) => `${file}=${await readManifestVersion(file)}`))
).join(', ')
console.log(`Published ${tag} (${summary}) to ${target}`)
