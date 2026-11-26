// String helpers shared across the host and packages.

/** Longer than `max` as JSON Schema counts length: in code points, not UTF-16 units. */
export function longer(text: string, max: number): boolean {
  if (text.length <= max) return false
  let n = 0
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i)
    if (c >= 0xd800 && c <= 0xdbff) i++
    if (++n > max) return true
  }
  return false
}
