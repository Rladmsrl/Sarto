import js from '@eslint/js'
import eslintConfigPrettier from 'eslint-config-prettier/flat'
import { defineConfig, globalIgnores } from 'eslint/config'
import globals from 'globals'
import tseslint from 'typescript-eslint'

const SDK_MESSAGE = 'Load the SDK with loadClaudeSdk from src/agent-host/claude/sdk.ts.'
const SDK_PATHS = [{ name: '@anthropic-ai/claude-agent-sdk', message: SDK_MESSAGE }]
const SDK_PATTERNS = [{ group: ['@anthropic-ai/claude-agent-sdk/*'], message: SDK_MESSAGE }]

export default defineConfig([
  globalIgnores(['out', 'dist', '.cache', '.worktrees', 'apps/apple', '**/dist']),
  {
    files: ['**/*.{ts,tsx,mts,mjs}'],
    extends: [js.configs.recommended, tseslint.configs.recommended],
  },
  {
    files: [
      'vitest.config.mts',
      'vite.daemon.config.mts',
      'src/core/**/*.ts',
      'src/agent-host/**/*.ts',
      'src/terminal-host/**/*.ts',
      'src/remote-host/**/*.ts',
      'src/device-host/**/*.ts',
      'src/daemon/**/*.ts',
      'tools/**/*.{ts,mjs}',
    ],
    languageOptions: { globals: globals.node },
  },
  {
    // The Claude Agent SDK's license grants no right to ship it, so Sarto installs it on first use
    // and loads it from there with its own types; an import would bundle it or need it installed.
    files: ['**/*.{ts,tsx,mts,mjs}'],
    rules: {
      'no-restricted-imports': ['error', { paths: SDK_PATHS, patterns: SDK_PATTERNS }],
    },
  },
  eslintConfigPrettier,
])
