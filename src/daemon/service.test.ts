import { mkdtemp, readFile, rm } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { describe, expect, it, vi } from 'vitest'
import {
  installService,
  restartService,
  ServiceError,
  SYSTEMD_UNIT,
  systemdUnit,
  uninstallService,
  type CommandResult,
  type ServiceDeps,
} from './service'

const OK: CommandResult = { code: 0, stdout: '', stderr: '' }

describe('Linux systemd user service management', () => {
  it('writes TimeoutStopSec=25 and escapes unit words', () => {
    const unit = systemdUnit({
      program: '/home/u/.local/share/sarto/node/bin/node',
      args: ['/home/u/.local/share/sarto/daemon/main.cjs', 'run'],
      env: { SARTO_DAEMON_SERVICE: '1' },
    })
    expect(unit).toContain('TimeoutStopSec=25')
    expect(unit).toContain('KillMode=mixed')
    expect(unit).toContain('Restart=always')
  })

  it('fails with a clear ServiceError when systemd is not running', async () => {
    const dir = await mkdtemp(path.join(os.tmpdir(), 'sarto-service-test-'))
    try {
      const run = vi.fn(async () => OK)
      const deps: ServiceDeps = {
        platform: 'linux',
        home: dir,
        env: { USER: 'alice' },
        uid: 1000,
        dir,
        run,
        pathExists: async () => false,
      }
      await expect(
        installService(
          deps,
          {
            program: '/bin/node',
            args: ['/app/main.cjs', 'run'],
            env: { SARTO_DAEMON_SERVICE: '1' },
          },
          path.join(dir, 'data'),
        ),
      ).rejects.toThrow(ServiceError)
      expect(run).not.toHaveBeenCalled()
    } finally {
      await rm(dir, { recursive: true, force: true })
    }
  })

  it('populates XDG_RUNTIME_DIR and DBUS_SESSION_BUS_ADDRESS when omitted in headless shells', async () => {
    const dir = await mkdtemp(path.join(os.tmpdir(), 'sarto-service-test-'))
    try {
      const seenEnvs: Array<NodeJS.ProcessEnv | undefined> = []
      const run = vi.fn(async (command: string, _args: string[], env?: NodeJS.ProcessEnv) => {
        seenEnvs.push(env)
        if (command === 'loginctl') {
          return { code: 1, stdout: '', stderr: 'Interactive authentication required.' }
        }
        return OK
      })
      const existing = new Set(['/run/systemd/system', '/run/user/1001', '/run/user/1001/bus'])
      const deps: ServiceDeps = {
        platform: 'linux',
        home: dir,
        env: { USER: 'alice' },
        uid: 1001,
        dir,
        run,
        pathExists: async (file) => existing.has(file),
      }
      const installed = await installService(
        deps,
        {
          program: '/bin/node',
          args: ['/app/main.cjs', 'run'],
          env: { SARTO_DAEMON_SERVICE: '1' },
        },
        path.join(dir, 'data'),
      )

      expect(installed.file).toBe(path.join(dir, SYSTEMD_UNIT))
      expect(installed.warning).toContain('sudo loginctl enable-linger alice')
      const content = await readFile(installed.file, 'utf8')
      expect(content).toContain('TimeoutStopSec=25')
      expect(seenEnvs).toHaveLength(4)
      for (const env of seenEnvs) {
        expect(env?.XDG_RUNTIME_DIR).toBe('/run/user/1001')
        expect(env?.DBUS_SESSION_BUS_ADDRESS).toBe('unix:path=/run/user/1001/bus')
      }

      expect(await restartService(deps)).toBe(true)
      expect(await uninstallService(deps)).toBe(true)
      expect(await uninstallService(deps)).toBe(false)
    } finally {
      await rm(dir, { recursive: true, force: true })
    }
  })

  it('preserves explicit XDG_RUNTIME_DIR and DBUS_SESSION_BUS_ADDRESS values', async () => {
    const dir = await mkdtemp(path.join(os.tmpdir(), 'sarto-service-test-'))
    try {
      const seenEnvs: Array<NodeJS.ProcessEnv | undefined> = []
      const deps: ServiceDeps = {
        platform: 'linux',
        home: dir,
        env: {
          USER: 'bob',
          XDG_RUNTIME_DIR: '/custom/runtime',
          DBUS_SESSION_BUS_ADDRESS: 'unix:path=/custom/bus',
        },
        uid: 1002,
        dir,
        run: async (_cmd, _args, env) => {
          seenEnvs.push(env)
          return OK
        },
        pathExists: async (file) => file === '/run/systemd/system',
      }
      const installed = await installService(
        deps,
        {
          program: '/bin/node',
          args: ['/app/main.cjs', 'run'],
          env: { SARTO_DAEMON_SERVICE: '1' },
        },
        path.join(dir, 'data'),
      )
      expect(installed.warning).toBeNull()
      for (const env of seenEnvs) {
        expect(env?.XDG_RUNTIME_DIR).toBe('/custom/runtime')
        expect(env?.DBUS_SESSION_BUS_ADDRESS).toBe('unix:path=/custom/bus')
      }
    } finally {
      await rm(dir, { recursive: true, force: true })
    }
  })
})
