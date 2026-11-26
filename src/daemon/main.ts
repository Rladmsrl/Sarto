// Entry of the `sarto` CLI under Node.js, built into out/daemon/main.cjs beside the hosts' bundles.

import { logProcessFailures, openProcessLog, redactLogText } from '@shared/log/process-log'
import { execFile, spawn } from 'node:child_process'
import { constants } from 'node:fs'
import { access, copyFile, mkdtemp, readFile, realpath, rm, writeFile } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import {
  parseReportRequest,
  reportIssueUrl,
  type ReportBuildResult,
  type ReportRequest,
  type ReportSubmitResult,
} from '@shared/report'
import { version } from '../../package.json'
import { DAEMON_BUILD_INFO, detectDaemonOrigin } from '../core/build-info'
import { AccountApi, clientInfo } from '../core/account/service'
import { accountFile, readAccount } from '../core/account/store'
import { readJsonFile } from '../core/json-file'
import { parseSettingsFile } from '../core/settings-schema'
import { computerName, nodeSystemReleaseForRun } from '../core/system-name'
import { accountLine, login, logout } from './account'
import { HELP, parseCommand, type Command } from './args'
import { resolveCloudOrigin } from './cloud-account'
import { createKeychainCipher } from './keychain'
import { callControl, ControlError, NotRunning, type DaemonStatus } from './control'
import { AlreadyRunning, SERVICE_ENV, startDaemon } from './daemon'
import { markDebugRun, unmarkDebugRun } from './debug'
import { prepareDataFolder, privateFolder } from './key'
import { followLogs, parseTime, readLogs, type LogFilter } from './logs'
import { daemonPart, logsOnlyReport, mapSubmitError } from './problem-report'
import { proxiedFetch } from './proxy'
import { controlSocketPath, DATA_ENV, dataPath, logFolderPath } from './paths'
import { terminalQuestions } from './questions'
import { devicesReport, runningReport, stoppedReport, terminalReport } from './report'
import {
  installService,
  restartService,
  serviceCommand,
  ServiceError,
  serviceFile,
  uninstallService,
  type CommandResult,
  type ServiceDeps,
} from './service'
import { daemonUserAgent, RELEASES_ENV, releaseSources, update, UpdateError } from './update'

const SUPPORTED: readonly NodeJS.Platform[] = ['darwin', 'linux']
const START_WAIT_MS = 20_000
const STOP_WAIT_MS = 15_000

/** A failure the CLI reports in a line of its own, without a stack. */
class Failure extends Error {
  constructor(
    message: string,
    readonly code = 1,
  ) {
    super(message)
  }
}

/** The exit code of a command that needs the daemon when none runs, as `sarto status` exits. */
const NOT_RUNNING = 3

const out = (text: string): void => void process.stdout.write(text)
const delay = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms))

/** The login name; none where the uid has no passwd entry, as in some containers. */
function systemUser(): string | undefined {
  try {
    return os.userInfo().username
  } catch {
    return undefined
  }
}

function runTool(command: string, args: string[]): Promise<CommandResult> {
  return new Promise((resolve) => {
    execFile(command, args, { timeout: 30_000 }, (error, stdout, stderr) => {
      const code = error ? (typeof error.code === 'number' ? error.code : 127) : 0
      resolve({ code, stdout, stderr: stderr || (error && code === 127 ? error.message : '') })
    })
  })
}

/** The daemon's status, or null when it is not running. */
async function statusOf(socket: string): Promise<DaemonStatus | null> {
  try {
    return await callControl(socket, 'status', undefined)
  } catch (error) {
    if (error instanceof NotRunning) return null
    throw error
  }
}

/** `sarto terminal`, with `on` or `off` to change it, through the running daemon. */
async function terminal(
  socket: string,
  command: Extract<Command, { kind: 'terminal' | 'terminal-set' }>,
): Promise<number> {
  try {
    const report =
      command.kind === 'terminal'
        ? await callControl(socket, 'terminal.get', undefined)
        : await callControl(socket, 'terminal.set', { allowed: command.allowed })
    out(terminalReport(report.allowed))
    return 0
  } catch (error) {
    if (error instanceof NotRunning) throw new Failure(error.message, NOT_RUNNING)
    if (error instanceof ControlError) throw new Failure(error.message)
    throw error
  }
}

/** Runs an install script with its output on this terminal, and resolves to its exit code. */
async function runInstallScript(script: string, args: string[]): Promise<number> {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'sarto-update-'))
  try {
    const file = path.join(dir, 'install.sh')
    await writeFile(file, script)
    return await new Promise<number>((resolve, reject) => {
      spawn('/bin/sh', [file, ...args], { stdio: 'inherit' })
        .once('error', reject)
        .once('exit', (code, signal) => resolve(code ?? (signal ? 128 : 1)))
    })
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
}

/**
 * `sarto ssh-setup`: what the desktop app connects with when it adds this computer over SSH, as
 * one line of JSON, once the device its request names is added. The login it came over proves the
 * device is the owner's, as pairing would.
 */
async function sshSetup(socket: string, request: string | null): Promise<number> {
  let params: unknown = {}
  if (request !== null) {
    try {
      params = JSON.parse(request)
    } catch {
      throw new Failure('The request is not JSON', 2)
    }
  }
  const started = Date.now()
  for (;;) {
    try {
      const setup = await callControl(socket, 'ssh.setup', params as { device: null })
      out(`${JSON.stringify(setup)}\n`)
      return 0
    } catch (error) {
      if (error instanceof NotRunning) throw new Failure(error.message, NOT_RUNNING)
      // A daemon the install just started may not take channels yet.
      const starting = error instanceof ControlError && error.code === 'unavailable'
      if (starting && Date.now() - started < START_WAIT_MS) {
        await delay(500)
        continue
      }
      if (error instanceof ControlError) throw new Failure(error.message)
      throw error
    }
  }
}

/** The settings as the daemon last wrote them, read and never written. */
async function readSettings(data: string) {
  const read = await readJsonFile(path.join(data, 'settings.json'))
  return parseSettingsFile(read.kind === 'ok' ? read.value : { version: 1 }).settings
}

function sizeText(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`
}

function stamp(date: Date): string {
  const pad = (value: number): string => String(value).padStart(2, '0')
  return (
    `${date.getFullYear()}${pad(date.getMonth() + 1)}${pad(date.getDate())}-` +
    `${pad(date.getHours())}${pad(date.getMinutes())}${pad(date.getSeconds())}`
  )
}

/**
 * `sarto report`: the running daemon builds the bundle with its agents and sessions; without one,
 * it is the logs and settings alone. Either way the zip moves to where the owner said, and its
 * files are listed to look through before it is shared, then it is submitted with the daemon's
 * sign-in when the owner asks.
 */
async function report(
  socket: string,
  data: string,
  logs: string,
  command: Extract<Command, { kind: 'report' }>,
): Promise<number> {
  const questions =
    process.stdin.isTTY === true ? terminalQuestions(process.stdin, process.stdout) : null
  let built: ReportBuildResult | null = null
  let preparedId: string | null = null
  let scratch: string | null = null
  try {
    let description = command.description
    if (description === null) {
      if (!questions) throw new Failure('Say what happened with --message', 2)
      description = (await questions.ask('What happened? '))?.trim() || null
      if (description === null) throw new Failure('Say what happened to save a report', 2)
    }
    let request: ReportRequest
    try {
      request = parseReportRequest({
        description,
        range: { kind: command.range },
        extras: command.extras,
        context: null,
      })
    } catch (error) {
      throw new Failure((error as Error).message, 2)
    }
    const output = path.resolve(command.output ?? `sarto-report-${stamp(new Date())}.zip`)
    let files: { path: string; size: number }[]
    let size: number
    let redactionCount = 0
    try {
      // A bundle with recent messages or crash dumps takes a while to pack.
      const prepared = await callControl(socket, 'report.prepare', { request }, 180_000)
      if (!prepared.ok) {
        throw new Failure(
          prepared.reason === 'too_large'
            ? 'The report is too large; choose a shorter range or fewer extras'
            : `No report: ${prepared.message}`,
        )
      }
      preparedId = prepared.id
      files = prepared.files
      size = prepared.size
      redactionCount = prepared.redactionCount ?? 0
      await callControl(socket, 'report.save', { id: preparedId, destination: output }, 60_000)
    } catch (error) {
      if (error instanceof Failure) throw error
      if (error instanceof ControlError) throw new Failure(error.message)
      if (!(error instanceof NotRunning)) throw error
      process.stderr.write(
        'sarto: the daemon is not running, so the report holds the logs and settings alone\n',
      )
      scratch = await mkdtemp(path.join(os.tmpdir(), 'sarto-report-'))
      built = await logsOnlyReport(
        request,
        daemonPart(version, null, {
          build: DAEMON_BUILD_INFO.build,
          channel: DAEMON_BUILD_INFO.channel,
          commit: DAEMON_BUILD_INFO.commit,
          origin: detectDaemonOrigin(__dirname),
        }),
        await readSettings(data),
        logs,
        scratch,
      )
      if (!built.ok) {
        throw new Failure(
          built.reason === 'too_large'
            ? 'The report is too large; choose a shorter range or fewer extras'
            : `No report: ${built.message}`,
        )
      }
      if (path.dirname(path.resolve(built.file)) !== path.resolve(scratch)) {
        throw new Failure('The report builder put the report somewhere else')
      }
      try {
        await copyFile(built.file, output, constants.COPYFILE_EXCL)
      } catch (copyErr) {
        if ((copyErr as NodeJS.ErrnoException).code === 'EEXIST') {
          throw new Failure(`${output} already exists; name another file with --output`)
        }
        throw copyErr
      }
      files = built.files
      size = built.size
      redactionCount = built.redactionCount ?? 0
    }
    const width = Math.max(...files.map((file) => file.path.length))
    const redactionLine = redactionCount > 0 ? `Masked ${redactionCount} sensitive value(s).\n` : ''
    out(
      `Saved the report to ${output} (${sizeText(size)}). It holds:\n` +
        files.map((file) => `  ${file.path.padEnd(width)}  ${sizeText(file.size)}\n`).join('') +
        redactionLine +
        'Look through it before you share it: anyone can download a file attached to a public issue.\n',
    )

    let shouldSubmit = command.submit
    if (!shouldSubmit && questions) {
      const answer = (await questions.ask('Submit this report to Sarto Cloud? [y/N] '))
        ?.trim()
        .toLowerCase()
      shouldSubmit = answer === 'y' || answer === 'yes'
    }
    if (shouldSubmit) {
      let submitted: ReportSubmitResult
      if (preparedId) {
        submitted = await callControl(
          socket,
          'report.submit',
          { id: preparedId, allowAnonymous: true },
          310_000,
        )
        if (submitted.ok) preparedId = null
      } else {
        const bytes = await readFile(output)
        const settings = await readSettings(data)
        const origin = resolveCloudOrigin(process.env)
        const api = new AccountApi(
          origin,
          proxiedFetch(() => settings?.proxy ?? { mode: 'system' }, process.env),
        )
        const redacted = redactLogText(request.description).trim() || 'Problem report'
        const platform = `${process.platform} ${os.release()} ${process.arch}`
        try {
          const res = await api.submitReport({
            accessToken: null,
            description: redacted,
            version,
            platform,
            deviceName: settings?.remote.name?.trim() || (await computerName()),
            bundle: { filename: path.basename(output), bytes: new Uint8Array(bytes) },
          })
          submitted = {
            ok: true,
            id: res.id,
            anonymous: res.anonymous,
            consoleUrl: null,
            issueUrl: reportIssueUrl({
              reportId: res.id,
              version,
              os: platform,
              summary: redacted.slice(0, 600),
            }),
          }
        } catch (err) {
          submitted = mapSubmitError(err)
        }
      }
      if (!submitted.ok) {
        throw new Failure(`Could not submit report (${submitted.reason}): ${submitted.message}`)
      }
      out(
        `Submitted report ${submitted.id}${submitted.anonymous ? ' (anonymous)' : ''}.\n` +
          (submitted.consoleUrl ? `Track progress: ${submitted.consoleUrl}\n` : '') +
          `GitHub issue:   ${submitted.issueUrl}\n`,
      )
    }

    return 0
  } finally {
    questions?.close()
    if (preparedId) {
      await callControl(socket, 'report.drop', { id: preparedId }, 5_000).catch(() => {})
    }
    if (built?.ok) await rm(built.file, { force: true }).catch(() => {})
    if (scratch) await rm(scratch, { recursive: true, force: true }).catch(() => {})
  }
}

/** `sarto logs`: the records of the log folder, which need no running daemon. */
async function logs(dir: string, command: Extract<Command, { kind: 'logs' }>): Promise<number> {
  const now = Date.now()
  const time = (value: string | null, option: string): number | null => {
    if (value === null) return null
    const at = parseTime(value, now)
    if (at === null) {
      throw new Failure(`${option} takes a time, or a span ago such as 30m, 2h or 1d`, 2)
    }
    return at
  }
  const filter: LogFilter = {
    process: command.process,
    level: command.level,
    op: command.op,
    since: time(command.since, '--since'),
    until: time(command.until, '--until'),
  }
  for (const line of await readLogs(dir, filter)) out(line)
  if (!command.follow) return 0
  const stop = new AbortController()
  const abort = (): void => stop.abort()
  process.once('SIGINT', abort)
  try {
    await followLogs(dir, filter, out, stop.signal)
  } finally {
    process.off('SIGINT', abort)
  }
  return 0
}

/** `sarto verbose on` or `off`, through the running daemon, which writes the settings. */
async function verbose(socket: string, on: boolean): Promise<number> {
  try {
    const { until } = await callControl(socket, 'verbose.set', { on })
    out(
      until === null
        ? 'Detailed records are off.\n'
        : `Detailed records are on until ${new Date(until).toLocaleString()}. They hold the full\n` +
            'messages with agents: prompts, code and tool output. sarto verbose off turns them off.\n',
    )
    return 0
  } catch (error) {
    if (error instanceof NotRunning) throw new Failure(error.message, NOT_RUNNING)
    if (error instanceof ControlError) throw new Failure(error.message)
    throw error
  }
}

/** `sarto login` or `sarto logout`, which need no running daemon. */
async function account(kind: 'login' | 'logout', data: string): Promise<number> {
  const base = resolveCloudOrigin(process.env)
  // Read, never written: the running daemon alone writes its settings.
  const settings = await readSettings(data)
  const file = accountFile(data)
  await prepareDataFolder(data)
  await privateFolder(path.dirname(file))
  const cipher = await createKeychainCipher(data, { env: process.env })
  const stop = new AbortController()
  const abort = (): void => stop.abort()
  process.once('SIGINT', abort)
  try {
    const deps = {
      api: new AccountApi(
        base,
        proxiedFetch(() => settings.proxy, process.env),
      ),
      file,
      cipher,
      clientInfo: async () =>
        clientInfo({
          kind: 'daemon',
          name: settings.remote.name ?? (await computerName()),
          os: await nodeSystemReleaseForRun(),
          arch: process.arch,
          version,
          user: systemUser(),
        }),
      write: out,
      error: (message: string) => void process.stderr.write(`sarto: ${message}\n`),
      signal: stop.signal,
    }
    return await (kind === 'login' ? login(deps) : logout(deps))
  } finally {
    process.off('SIGINT', abort)
  }
}

/** The account line of `sarto status`. */
async function statusAccount(data: string): Promise<string> {
  const stored = await readAccount(accountFile(data), (message) =>
    process.stderr.write(`sarto: ${message}\n`),
  )
  return accountLine(stored)
}

async function until<T>(check: () => Promise<T | null>, ms: number): Promise<T | null> {
  const started = Date.now()
  for (;;) {
    const value = await check().catch(() => null)
    if (value !== null || Date.now() - started > ms) return value
    await delay(250)
  }
}

async function run(command: Exclude<Command, { kind: 'help' | 'version' | 'usage' }>) {
  const where = {
    platform: process.platform,
    home: os.homedir(),
    env: process.env,
    cwd: process.cwd(),
  }
  const data = dataPath(where)
  const logDir = logFolderPath(where)
  const service: ServiceDeps = {
    platform: process.platform,
    home: os.homedir(),
    env: process.env,
    uid: os.userInfo().uid,
    run: runTool,
  }
  const socket = controlSocketPath(data)
  if (!socket) {
    throw new Failure(`The data folder's path is too long for a socket; set a shorter ${DATA_ENV}`)
  }

  switch (command.kind) {
    case 'run': {
      openProcessLog({
        dir: logDir,
        name: 'daemon',
        // A service's output goes to the journal or launchd's file; the log file has it already.
        echo: process.stdout.isTTY === true,
        prune: true,
      })
      logProcessFailures({ rejections: false })
      const daemon = await startDaemon({
        dataPath: data,
        controlSocket: socket,
        version,
        buildInfo: DAEMON_BUILD_INFO,
        bundleDir: __dirname,
        env: process.env,
        debug: command.debug,
      })
      await new Promise<void>((resolve) => {
        const stop = (): void => void daemon.stop().then(resolve)
        process.on('SIGTERM', stop)
        process.on('SIGINT', stop)
        process.on('SIGHUP', stop)
      })
      return 0
    }

    case 'status': {
      const status = await statusOf(socket)
      const signedIn = await statusAccount(data)
      out(
        status
          ? runningReport(status, signedIn)
          : stoppedReport(version, data, signedIn, {
              ...DAEMON_BUILD_INFO,
              origin: detectDaemonOrigin(__dirname),
            }),
      )
      return status ? 0 : 3
    }

    case 'devices':
    case 'devices-remove': {
      try {
        if (command.kind === 'devices') {
          out(devicesReport(await callControl(socket, 'devices.list', undefined), Date.now()))
        } else {
          await callControl(socket, 'devices.remove', { id: command.id })
          out(`Removed the device ${command.id}.\n`)
        }
        return 0
      } catch (error) {
        if (error instanceof NotRunning) throw new Failure(error.message, NOT_RUNNING)
        if (error instanceof ControlError) throw new Failure(error.message)
        throw error
      }
    }

    case 'ssh-setup':
      return sshSetup(socket, command.request)

    case 'login':
    case 'logout': {
      const code = await account(command.kind, data)
      // A running daemon signs in to the relay, or out of it, with the new sign-in at once.
      await callControl(socket, 'account.reload', undefined, 5000).catch(() => null)
      return code
    }

    case 'terminal':
    case 'terminal-set':
      return terminal(socket, command)

    case 'report':
      return report(socket, data, logDir, command)

    case 'logs':
      return logs(logDir, command)

    case 'verbose':
      return verbose(socket, command.on)

    case 'service-install': {
      const running = await statusOf(socket)
      if (running && !running.service) {
        throw new Failure(
          `A Sarto daemon runs in the foreground on this data folder (pid ${running.pid}); ` +
            'stop it before installing the service',
        )
      }
      await prepareDataFolder(data)
      const script = await realpath(process.argv[1]!)
      const installed = await installService(
        service,
        serviceCommand(process.execPath, script, process.env, SERVICE_ENV),
        data,
      )
      const started = await until(async () => {
        const status = await statusOf(socket)
        return status && !status.stopping && status.pid !== running?.pid ? status : null
      }, START_WAIT_MS)
      const logs = installed.log ?? 'journalctl --user -u sarto'
      if (!started) {
        throw new Failure(`Installed ${installed.file}, but the daemon did not start; see ${logs}`)
      }
      out(
        `Installed ${installed.file}\nThe daemon is running (pid ${started.pid}); its log: ${logs}\n`,
      )
      if (installed.warning) {
        process.stderr.write(`sarto: ${installed.warning}\n`)
        return 1
      }
      return 0
    }

    case 'restart': {
      const running = await statusOf(socket)
      if (running && !running.service) {
        throw new Failure(
          `A Sarto daemon runs in the foreground on this data folder (pid ${running.pid}); ` +
            `stop it and start it again with sarto run${command.debug ? ' --debug' : ''}`,
        )
      }
      if (command.debug) await markDebugRun(data)
      let restarted: boolean
      try {
        restarted = await restartService(service)
      } catch (error) {
        if (command.debug) await unmarkDebugRun(data)
        throw error
      }
      if (!restarted) {
        if (command.debug) await unmarkDebugRun(data)
        throw new Failure(
          `No service is installed; run sarto service install, or sarto run${command.debug ? ' --debug' : ''} in the foreground`,
        )
      }
      // A debug run says so once its own inspector is open, a moment after the socket listens.
      const started = await until(async () => {
        const status = await statusOf(socket)
        const up = status && !status.stopping && status.pid !== running?.pid
        return up && (!command.debug || status.debug) ? status : null
      }, START_WAIT_MS)
      if (!started) throw new Failure('Restarted the service, but the daemon did not start')
      out(
        started.debug
          ? `The daemon runs in debug mode until its next restart (pid ${started.pid}); ` +
              'sarto status lists its inspectors.\n'
          : `The daemon is running again (pid ${started.pid}).\n`,
      )
      return 0
    }

    case 'service-uninstall': {
      if (!(await uninstallService(service))) {
        out('The service is not installed.\n')
        return 0
      }
      const stopped = await until(async () => {
        const status = await statusOf(socket)
        return status?.service ? null : true
      }, STOP_WAIT_MS)
      if (!stopped) throw new Failure('Removed the service, but its daemon is still running')
      out('Removed the service; its daemon has stopped.\n')
      return 0
    }

    case 'update': {
      const running = await statusOf(socket)
      const channel = command.channel ?? (DAEMON_BUILD_INFO.channel === 'beta' ? 'beta' : 'stable')
      return update({
        version,
        channel,
        bundleDir: __dirname,
        releases: releaseSources(process.env[RELEASES_ENV]),
        userAgent: daemonUserAgent(version, process.platform, process.arch),
        fetch,
        service: await access(serviceFile(service)).then(
          () => true,
          () => false,
        ),
        foreground: running !== null && !running.service,
        install: runInstallScript,
        write: out,
      })
    }
  }
}

async function main(argv: string[]): Promise<number> {
  const command = parseCommand(argv)
  if (command.kind === 'help') {
    out(HELP)
    return 0
  }
  if (command.kind === 'version') {
    out(`${version}\n`)
    return 0
  }
  if (command.kind === 'usage') {
    process.stderr.write(`sarto: ${command.message}. Run sarto --help for usage.\n`)
    return 2
  }
  if (!SUPPORTED.includes(process.platform)) {
    process.stderr.write('sarto: the daemon runs on macOS and Linux\n')
    return 1
  }
  try {
    return await run(command)
  } catch (error) {
    const known =
      error instanceof Failure ||
      error instanceof AlreadyRunning ||
      error instanceof ServiceError ||
      error instanceof UpdateError
    process.stderr.write(
      `sarto: ${known ? (error as Error).message : ((error as Error)?.stack ?? String(error))}\n`,
    )
    return error instanceof Failure ? error.code : 1
  }
}

void main(process.argv.slice(2)).then((code) => {
  process.exitCode = code
  // Whatever still holds the event loop, such as a host that would not die, does not hold the exit.
  setTimeout(() => process.exit(code), 2000).unref()
})
