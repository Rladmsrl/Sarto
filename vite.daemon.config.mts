// The daemon's build: the `sarto` CLI and the hosts it forks, for Node.js, into out/daemon/.
// Every package is bundled except node-pty, which is native and loads from beside the bundle.

import { fileURLToPath } from 'node:url'
import { defineConfig, type Plugin } from 'vite'
import { standaloneThirdPartyNotices } from './tools/build/third-party-notices'
import {
  formatChannelVersion,
  generateBuildNumber,
  readDaemonBaseVersion,
  readGitCommit,
  resolveBuildChannel,
} from './tools/sarto/build-version.mjs'
import {
  BUILD_PLACEHOLDER,
  BUILT_AT_PLACEHOLDER,
  CHANNEL_PLACEHOLDER,
  COMMIT_PLACEHOLDER,
  VERSION_PLACEHOLDER,
} from './tools/sarto/runtime-fingerprint.mjs'

const root = fileURLToPath(new URL('.', import.meta.url))
const source = (file: string): string => fileURLToPath(new URL(file, import.meta.url))

interface BuildStamp {
  version: string
  build: string
  channel: string
  commit: string
  builtAt: string
}

function resolveBuildStamp(): BuildStamp {
  const placeholder =
    process.env.SARTO_BUILD_PLACEHOLDER === '1' ||
    process.env.SARTO_VERSION?.trim() === VERSION_PLACEHOLDER
  if (placeholder) {
    return {
      version: VERSION_PLACEHOLDER,
      build: BUILD_PLACEHOLDER,
      channel: CHANNEL_PLACEHOLDER,
      commit: COMMIT_PLACEHOLDER,
      builtAt: BUILT_AT_PLACEHOLDER,
    }
  }
  const rawVersion =
    process.env.SARTO_DAEMON_VERSION?.trim() ||
    process.env.SARTO_VERSION?.trim() ||
    readDaemonBaseVersion(root)
  const build = process.env.SARTO_BUILD_NUMBER?.trim() || generateBuildNumber()
  const channel = resolveBuildChannel(rawVersion, process.env.SARTO_BUILD_CHANNEL, 'dev')
  const version = formatChannelVersion(rawVersion, channel, build)
  const commit = process.env.SARTO_GIT_COMMIT?.trim() || readGitCommit(root) || ''
  const builtAt = process.env.SARTO_BUILT_AT?.trim() || new Date().toISOString()
  return { version, build, channel, commit, builtAt }
}

// Stamps the daemon's version into package.json imports and its build metadata into
// src/core/build-info.ts without mutating checked-in source files.
function sartoBuildInfo(stamp: BuildStamp): Plugin {
  const manifest = source('package.json')
  const buildInfo = source('src/core/build-info.ts')
  return {
    name: 'sarto:build-info',
    enforce: 'pre',
    transform(code, id) {
      const cleanId = id.split('?')[0]
      if (cleanId === manifest) {
        return {
          code: JSON.stringify({ ...JSON.parse(code), version: stamp.version }),
          map: null,
        }
      }
      if (cleanId === buildInfo) {
        let replaced = code
        for (const [constant, initial, value] of [
          ['RAW_BUILD', "''", stamp.build],
          ['RAW_CHANNEL', "'dev'", stamp.channel],
          ['RAW_COMMIT', "''", stamp.commit],
          ['RAW_BUILT_AT', "''", stamp.builtAt],
        ] as const) {
          const declaration = `const ${constant} = ${initial}`
          // A daemon whose metadata silently stayed unstamped would report a wrong build.
          if (!replaced.includes(declaration)) {
            throw new Error(`src/core/build-info.ts no longer declares ${declaration}`)
          }
          replaced = replaced.replace(declaration, `const ${constant} = ${JSON.stringify(value)}`)
        }
        return { code: replaced, map: null }
      }
      return null
    },
  }
}

export default defineConfig({
  root,
  resolve: { alias: { '@shared': source('src/shared') } },
  ssr: { noExternal: true },
  plugins: [sartoBuildInfo(resolveBuildStamp()), standaloneThirdPartyNotices(root, ['node-pty'])],
  build: {
    ssr: true,
    outDir: source('out/daemon'),
    emptyOutDir: true,
    minify: false,
    rolldownOptions: {
      input: {
        main: source('src/daemon/main.ts'),
        'agent-host': source('src/agent-host/node-main.ts'),
        'terminal-host': source('src/terminal-host/node-main.ts'),
        'device-host': source('src/device-host/node-main.ts'),
        'remote-host': source('src/remote-host/node-main.ts'),
        'thread-worker': source('src/agent-host/threads/worker.ts'),
        'usage-worker': source('src/agent-host/usage/worker.ts'),
        'session-router': source('src/agent-host/session-router/router.ts'),
        'cline-host': source('src/agent-host/cline/cline-host.ts'),
      },
      external: [/^node:/, 'node-pty'],
      output: {
        format: 'cjs',
        entryFileNames: '[name].cjs',
        chunkFileNames: 'chunks/[name]-[hash].cjs',
      },
    },
  },
})
