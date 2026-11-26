import { access, constants, stat } from 'node:fs/promises'

/** Whether a path picked in a file dialog is an executable program. */
export async function isExecutableFile(path: string): Promise<boolean> {
  try {
    if (!(await stat(path)).isFile()) return false
    await access(path, constants.X_OK)
    return true
  } catch {
    return false
  }
}
