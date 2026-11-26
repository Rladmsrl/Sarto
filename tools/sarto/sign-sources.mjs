// @ts-check
// Signs Sarto's list of download sources (sources.json) with the sources key.
// The app tries the sources in order and the official source always last, takes a
// list only under its sources keys, and never one whose serial is below the one it kept:
//
//   SARTO_SOURCES_SIGNING_KEY="$(cat sources-current.pem)" \
//     node tools/sarto/sign-sources.mjs list.json > sources.json
//
// list.json: { "serial": 2, "sources": [{ "id": "mirror", "url": "https://…" }],
//              "connectTimeoutSeconds": 10, "stallSeconds": 15 }

import { readFileSync } from 'node:fs'
import { signerFrom } from './signing.mjs'

const SOURCE_ID = /^[a-z0-9-]{1,32}$/
const isTimeout = (/** @type {unknown} */ value) =>
  Number.isInteger(value) &&
  /** @type {number} */ (value) >= 1 &&
  /** @type {number} */ (value) <= 120

/** The same rules the app reads a list by (SartoUpdate's UpdateSources.readList). */
function check(/** @type {any} */ list) {
  if (!Number.isSafeInteger(list?.serial) || list.serial < 1)
    return 'serial is not a positive integer'
  if (!Array.isArray(list.sources) || list.sources.length < 1 || list.sources.length > 8) {
    return 'sources holds none or more than 8'
  }
  for (const source of list.sources) {
    if (typeof source?.id !== 'string' || !SOURCE_ID.test(source.id))
      return 'a source has no valid id'
    const url = typeof source.url === 'string' ? URL.parse(source.url) : null
    if (
      !url ||
      url.protocol !== 'https:' ||
      url.username ||
      url.password ||
      /[\s\\?#]|\p{Cc}/u.test(source.url) ||
      source.url.endsWith('/')
    ) {
      return `source ${source.id} has no https URL without a query, fragment or credentials`
    }
  }
  if (!isTimeout(list.connectTimeoutSeconds) || !isTimeout(list.stallSeconds)) {
    return 'its timeouts are not whole seconds from 1 to 120'
  }
  return null
}

const file = process.argv[2]
if (!file) {
  console.error('Usage: sign-sources.mjs <list.json>')
  process.exit(2)
}
const list = JSON.parse(readFileSync(file, 'utf8'))
const problem = check(list)
if (problem) {
  console.error(`${file}: ${problem}`)
  process.exit(1)
}
const payload = Buffer.from(JSON.stringify(list), 'utf8')
const signature = signerFrom('sources', 'SARTO_SOURCES_SIGNING_KEY')(payload)
process.stdout.write(
  `${JSON.stringify({ payload: payload.toString('base64url'), signature: signature.toString('base64url') })}\n`,
)
