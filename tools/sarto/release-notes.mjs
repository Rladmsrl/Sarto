// @ts-check
// A release's highlights for the updater: the bullets under "What changed" in English and under "中文" in
// Chinese, at most five each, one sentence, without issue links. Sarto signs them into the update
// file, so the app shows them without fetching a page.

const MAX_HIGHLIGHTS = 5
const MAX_HIGHLIGHT = 120

/** @type {Record<string, string>} */
const ENTITIES = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ' }

/** @param {string} html */
function plainText(html) {
  return html.replace(/<[^>]*>/g, '').replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (entity, name) => {
    if (!name.startsWith('#')) return ENTITIES[name.toLowerCase()] ?? entity
    const code = /^#x/i.test(name) ? parseInt(name.slice(2), 16) : Number(name.slice(1))
    return code <= 0x10ffff ? String.fromCodePoint(code) : entity
  })
}

/** A bullet as the app shows it: plain text, its first sentence, without issue links. */
function highlight(/** @type {string} */ item, /** @type {boolean} */ chinese) {
  const text = plainText(item)
    .replace(/`/g, '')
    .replace(/\*\*|__/g, '')
    .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/\s*\((?:#\d+(?:,\s*)?)+\)/g, '')
    .replace(/\s+/g, ' ')
    .trim()
  const end = chinese ? text.indexOf('。') + 1 : text.search(/[.!?](?:\s|$)/) + 1
  // A highlight is a list item, so it drops its full stop.
  const sentence = (end > 0 ? text.slice(0, end) : text).replace(/[.。]$/, '')
  return sentence.length > MAX_HIGHLIGHT ? `${sentence.slice(0, MAX_HIGHLIGHT - 1)}…` : sentence
}

/**
 * The highlights of a release's notes, in Markdown or HTML, by the app's language codes.
 *
 * @param {string} notes
 * @returns {{ en?: string[], 'zh-Hans'?: string[] }}
 */
export function releaseHighlights(notes) {
  /** @type {{ en?: string[], 'zh-Hans'?: string[] }} */
  const out = {}
  /** @type {'en' | 'zh-Hans' | null} */
  let section = null
  const token =
    /<h[1-6][^>]*>([\s\S]*?)<\/h[1-6]>|<li[^>]*>([\s\S]*?)<\/li>|^#{1,6}\s+(.+)$|^\s*[-*]\s+(.+)$/gim
  for (const match of notes.matchAll(token)) {
    const heading = match[1] ?? match[3]
    if (heading !== undefined) {
      const title = plainText(heading).trim()
      section = /^what changed$/i.test(title) ? 'en' : title === '中文' ? 'zh-Hans' : null
      continue
    }
    const item = match[2] ?? match[4]
    if (!section || item === undefined) continue
    const list = (out[section] ??= [])
    if (list.length < MAX_HIGHLIGHTS) {
      const line = highlight(item, section === 'zh-Hans')
      if (line) list.push(line)
    }
  }
  return out
}
