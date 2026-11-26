// The account service's interface as the daemon uses it: the shared client, with what takes
// Node.js and the random values a sign-in needs.

import { createHash, randomBytes } from 'node:crypto'

export * from '@shared/account-api'

export interface Pkce {
  verifier: string
  challenge: string
}

/** A code verifier of 43 characters and its S256 challenge (RFC 7636). */
export function newPkce(): Pkce {
  const verifier = randomBytes(32).toString('base64url')
  return { verifier, challenge: createHash('sha256').update(verifier).digest('base64url') }
}

export function newState(): string {
  return randomBytes(24).toString('base64url')
}
