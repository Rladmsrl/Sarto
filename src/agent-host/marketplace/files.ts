// Files the Marketplace writes from an archive or a download: whether a path stays inside the
// folder it is written to, and the mode a file gets back.

const MAX_PATH = 512

/** A file to write, read and checked. */
export interface DownloadedFile {
  path: string
  data: Buffer
}

/**
 * Whether a path stays inside the folder it is written to on every system: one relative path with
 * `/` between its parts, none of them empty, `.`, `..` or `.git`, and no character Windows would
 * read as a drive, a stream or a device.
 */
export function safeFilePath(file: string): boolean {
  if (file.length === 0 || file.length > MAX_PATH) return false
  if (/[\\:*?"<>|#]/.test(file) || /\p{Cc}/u.test(file)) return false
  return file
    .split('/')
    .every(
      (part) =>
        part !== '' && part !== '.' && part !== '..' && part !== '.git' && !/[. ]$/.test(part),
    )
}

/** Archives and downloads keep no modes, so a script, which starts with `#!`, gets its run bit. */
export function modeOf(data: Buffer): number {
  return data[0] === 0x23 && data[1] === 0x21 ? 0o755 : 0o644
}
