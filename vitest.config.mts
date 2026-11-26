import { resolve } from 'node:path'
import { defineConfig } from 'vitest/config'

export default defineConfig({
  resolve: {
    alias: [
      { find: '@shared', replacement: resolve('src/shared') },
      { find: '@sarto/wire', replacement: resolve('packages/sarto-wire/src') },
    ],
  },
  test: {
    environment: 'node',
    include: ['src/**/*.test.ts'],
  },
})
