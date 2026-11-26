import { describe, expect, it } from 'vitest'
import { listedTitle } from './session-titles'

describe('a title an agent lists', () => {
  const index = '<sarto-memory>\nSarto keeps this memory.\n</sarto-memory>'

  it('leaves out what Sarto sent ahead of the first prompt', () => {
    expect(listedTitle(`${index}\n\nFix the build`, 'Fix the build')).toBeNull()
    expect(listedTitle(`${index}\n\nFix login`, 'Fix the build')).toBe('Fix login')
    expect(listedTitle('<sarto-memory> Sarto keeps this memory…', 'Fix the build')).toBeNull()
  })

  it('keeps a plain title and drops an empty one', () => {
    expect(listedTitle(' Fix login ', 'Fix the build')).toBe('Fix login')
    expect(listedTitle('  ', null)).toBeNull()
  })
})
