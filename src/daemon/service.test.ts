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
        // `su` without `-` keeps the caller's USER: linger goes to the account of the uid.
        env: { USER: 'root', LOGNAME: 'root' },
        uid: 1001,
        user: 'alice',
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
      expect(run).toHaveBeenCalledWith('loginctl', ['enable-linger', 'alice'], expect.any(Object))
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

  it('removes a disabled or broken systemd unit on uninstall unless still active', async () => {
    const dir = await mkdtemp(path.join(os.tmpdir(), 'sarto-service-test-'))
    try {
      // systemctl is-active: 0 active, 3 not active, 4 no such unit, 1 could not ask (no bus).
      const makeDeps = (activeCode: number): ServiceDeps => ({
        platform: 'linux',
        home: dir,
        env: { USER: 'alice', XDG_RUNTIME_DIR: '/run/user/1000' },
        uid: 1000,
        dir,
        run: async (command, args) => {
          if (command === 'systemctl' && args.includes('disable')) {
            return { code: 1, stdout: '', stderr: 'Unit sarto.service not loaded.' }
          }
          if (command === 'systemctl' && args.includes('is-active')) {
            return {
              code: activeCode,
              stdout: '',
              stderr: activeCode === 1 ? 'Failed to connect to bus: No medium found' : '',
            }
          }
          return OK
        },
        pathExists: async (file) => file === '/run/systemd/system',
      })
      const command = {
        program: '/bin/node',
        args: ['/app/main.cjs', 'run'],
        env: { SARTO_DAEMON_SERVICE: '1' },
      }
      const unit = path.join(dir, SYSTEMD_UNIT)
      await installService(makeDeps(3), command, path.join(dir, 'data'))
      await expect(uninstallService(makeDeps(0))).rejects.toThrow(ServiceError)
      await expect(uninstallService(makeDeps(1))).rejects.toThrow(ServiceError)
      // A unit whose state could not be read stays, as one still running would.
      await expect(readFile(unit, 'utf8')).resolves.toContain('ExecStart=')
      expect(await uninstallService(makeDeps(3))).toBe(true)
      expect(await uninstallService(makeDeps(3))).toBe(false)
      await installService(makeDeps(3), command, path.join(dir, 'data'))
      expect(await uninstallService(makeDeps(4))).toBe(true)
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
