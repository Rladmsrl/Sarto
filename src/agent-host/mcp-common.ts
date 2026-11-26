// Shared caller metadata and text helpers for Sarto's built-in MCP tools.

/**
 * The session a call is from, and its project or scratch folder: all it reaches, and the working
 * directory its sources are read from.
 */
export interface Caller {
  sessionId: string
  project: string
  /** The folder the session works in when it is not its project's, such as its worktree. */
  folder?: string
  /** The call came from a subagent that runs under the session instead of being a session. */
  subagent?: boolean
}

/** Lowercase, without accents, for matching titles. */
export function folded(text: string): string {
  return text.normalize('NFD').replace(/\p{M}/gu, '').toLowerCase()
}
