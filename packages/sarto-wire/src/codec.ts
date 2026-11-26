// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Zhengru
//
// Byte and JSON helpers the protocols share.

const BASE64URL_ONLY = /^[A-Za-z0-9_-]*$/

/** RFC 4648 base64url without padding. */
export function toBase64Url(bytes: Uint8Array): string {
  let binary = ''
  for (let i = 0; i < bytes.byteLength; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
  }
  return btoa(binary).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '')
}

/** The bytes of unpadded base64url, or null when the text is not that. */
export function fromBase64Url(text: string): Uint8Array | null {
  if (!BASE64URL_ONLY.test(text) || text.length % 4 === 1) return null
  const binary = atob(text.replaceAll('-', '+').replaceAll('_', '/'))
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
  return bytes
}

export const isObject = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value)

/** A JSON object no longer than `limit` characters, or null. */
export function readJsonObject(text: unknown, limit: number): Record<string, unknown> | null {
  if (typeof text !== 'string' || text.length > limit) return null
  try {
    const value: unknown = JSON.parse(text)
    return isObject(value) ? value : null
  } catch {
    return null
  }
}
