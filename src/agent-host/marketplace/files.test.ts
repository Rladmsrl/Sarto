import { describe, expect, it } from 'vitest'
import { modeOf, safeFilePath } from './files'

describe('safeFilePath', () => {
  it('takes the relative paths a version holds', () => {
    for (const ok of ['SKILL.md', 'scripts/run.sh', 'a/b/c.txt', '.claude-plugin/plugin.json']) {
      expect(safeFilePath(ok)).toBe(true)
    }
  })

  it('refuses every path that could leave the install folder', () => {
    for (const bad of [
      '',
      '/etc/passwd',
      '../outside',
      'a/../../b',
      'a/./b',
      'a//b',
      'a\\..\\b',
      'C:/Windows/x',
      'c:x',
      '.git/config',
      'a/.git/hooks/pre-commit',
      'name.',
      'name ',
      'a\nb',
      `a/${'x'.repeat(600)}`,
    ]) {
      expect(safeFilePath(bad), bad).toBe(false)
    }
  })
})

describe('modeOf', () => {
  it('gives a script its run bit and any other file none', () => {
    expect(modeOf(Buffer.from('#!/bin/sh\n'))).toBe(0o755)
    expect(modeOf(Buffer.from('# Title\n'))).toBe(0o644)
    expect(modeOf(Buffer.alloc(0))).toBe(0o644)
  })
})
