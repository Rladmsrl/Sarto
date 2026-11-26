// The `sarto` command line: one command, `--help` and `--version`, anything else a usage error.

import { parseArgs } from 'node:util'
import type { LogLevel } from '@shared/log/process-log'
import type { ReportExtra, ReportRangeName } from '@shared/report'
import type { UpdateChannel } from '../core/versions'
import { LOG_LEVELS } from './logs'

export type Command =
  | { kind: 'help' }
  | { kind: 'version' }
  /** `debug`: this run opens the daemon's and its hosts' inspectors on 127.0.0.1. */
  | { kind: 'run'; debug: boolean }
  /** Restarts the service; `debug` makes the next run a debug run. */
  | { kind: 'restart'; debug: boolean }
  | { kind: 'status' }
  | { kind: 'devices' }
  | { kind: 'devices-remove'; id: string }
  | { kind: 'terminal' }
  | { kind: 'terminal-set'; allowed: boolean }
  | { kind: 'service-install' }
  | { kind: 'service-uninstall' }
  | { kind: 'update'; channel: UpdateChannel | null }
  | { kind: 'login' }
  | { kind: 'logout' }
  /** `request`: the JSON the desktop app sends, or null for none. */
  | { kind: 'ssh-setup'; request: string | null }
  /** `description`: null to ask for it; `output`: null for a file in the current folder. */
  | {
      kind: 'report'
      description: string | null
      range: ReportRangeName
      extras: ReportExtra[]
      output: string | null
      submit: boolean
    }
  /** The times as given, a span ago or a date, read against the clock when the logs are. */
  | {
      kind: 'logs'
      process: string | null
      level: LogLevel | null
      op: string | null
      since: string | null
      until: string | null
      follow: boolean
    }
  | { kind: 'verbose'; on: boolean }
  /** What was wrong with the command line, in a short sentence. */
  | { kind: 'usage'; message: string }

export const HELP = `Usage: sarto <command>

Runs Sarto's hosts on this computer, for Sarto's clients to connect to.

Commands:
  run                          Run the daemon in the foreground
  restart                      Restart the service, which sarto service install set up
  status                       Say whether the daemon is running, with its details
  devices                      List the devices paired with this computer
  devices remove <id>          Remove a paired device and close its sessions
  terminal                     Say whether devices may use this computer's terminal
  terminal on                  Let devices use the terminal, which runs any command
  terminal off                 Stop it; devices' terminals close but keep running here
  service install              Run the daemon as a service that starts with the computer
  service uninstall            Stop the service and remove it
  update                       Update to the latest release, and the service with it
  login                        Sign in to a Sarto account, confirmed in a browser on any device
  logout                       Sign out of the Sarto account
  report                       Save a problem report: the logs and settings, in a zip
  logs                         Show the logs, filtered by the options below
  verbose on                   Turn on detailed records for 24 hours; they hold prompts and code
  verbose off                  Turn detailed records off
  ssh-setup [<request>]        Run by Sarto's desktop app when it adds this computer over SSH

Options:
  --debug                      With run or restart: open the daemon's and its hosts' Node.js
                               inspectors on 127.0.0.1 for that run only. They have no password,
                               so any program on this computer can run code in the daemon
  -m, --message <text>         sarto report: what happened; asked for when left out
  --range <range>              sarto report: the time the logs cover: hour (the default),
                               today or 2d
  --with <items>               sarto report: also add any of titles, messages, verbose and
                               dumps, comma-separated; messages, verbose and dumps may hold
                               prompts, code and keys
  -o, --output <file>          sarto report: where to save the zip
  --submit                     sarto report: upload the report to Sarto Cloud after saving
  --process <name>             sarto logs: one process's records, such as daemon or agent-host
  --level <level>              sarto logs: this level and above: debug, info, warn or error
  --op <id>                    sarto logs: one action's records
  --since <time>               sarto logs: from a time, or a span ago such as 30m, 2h or 1d
  --until <time>               sarto logs: up to a time, or a span ago
  -f, --follow                 sarto logs: keep showing new records
  --channel <name>             sarto update: release channel to check (stable or beta)
  -h, --help                   Show this help
  --version                    Show the version

Environment:
  SARTO_DAEMON_DATA            The data folder to use instead of the default
  SARTO_CLOUD_URL              The Sarto Cloud to sign in to and relay through instead of
                               https://sarto.1o.ink

sarto status and the devices, terminal and verbose commands exit with 3 when the daemon is not
running. sarto report without a running daemon saves the logs and settings alone.
`

const OPTIONS = {
  help: { type: 'boolean', short: 'h' },
  version: { type: 'boolean' },
  debug: { type: 'boolean' },
  message: { type: 'string', short: 'm' },
  range: { type: 'string' },
  with: { type: 'string' },
  output: { type: 'string', short: 'o' },
  submit: { type: 'boolean' },
  process: { type: 'string' },
  level: { type: 'string' },
  op: { type: 'string' },
  since: { type: 'string' },
  until: { type: 'string' },
  follow: { type: 'boolean', short: 'f' },
  channel: { type: 'string' },
} as const

type OptionName = keyof typeof OPTIONS

/** The command each option is for; help and version go with any. */
const OPTION_COMMAND: Partial<Record<OptionName, Command['kind']>> = {
  message: 'report',
  range: 'report',
  with: 'report',
  output: 'report',
  submit: 'report',
  process: 'logs',
  level: 'logs',
  op: 'logs',
  since: 'logs',
  until: 'logs',
  follow: 'logs',
  channel: 'update',
}

const RANGES: Record<string, ReportRangeName> = { hour: 'hour', today: 'today', '2d': 'twoDays' }
const CLI_EXTRAS: readonly ReportExtra[] = ['titles', 'messages', 'verbose', 'dumps']

const quote = (value: string): string => `'${value}'`

type Given = Map<OptionName, { raw: string; value: string | undefined }>

export function parseCommand(argv: readonly string[]): Command {
  const { tokens } = parseArgs({
    args: [...argv],
    options: OPTIONS,
    allowPositionals: true,
    strict: false,
    tokens: true,
  })
  const given: Given = new Map()
  const words: string[] = []
  for (const token of tokens) {
    if (token.kind === 'positional') {
      words.push(token.value)
    } else if (token.kind === 'option') {
      if (!Object.hasOwn(OPTIONS, token.name)) {
        return { kind: 'usage', message: `Unknown option ${quote(token.rawName)}` }
      }
      const name = token.name as OptionName
      if (OPTIONS[name].type === 'boolean' && token.value !== undefined) {
        return { kind: 'usage', message: `${quote(token.rawName)} takes no value` }
      }
      if (OPTIONS[name].type === 'string' && token.value === undefined) {
        return { kind: 'usage', message: `${quote(token.rawName)} takes a value` }
      }
      if (given.has(name)) {
        return { kind: 'usage', message: `${quote(token.rawName)} is given twice` }
      }
      given.set(name, { raw: token.rawName, value: token.value })
    }
  }
  if (given.has('help')) return { kind: 'help' }
  if (given.has('version')) return { kind: 'version' }

  const command = parseWords(words)
  if (command.kind === 'usage') return command
  for (const [name, { raw }] of given) {
    const kind = OPTION_COMMAND[name]
    if (kind && kind !== command.kind) {
      return { kind: 'usage', message: `${quote(raw)} is only for sarto ${kind}` }
    }
  }
  const debug = given.has('debug')
  if (command.kind === 'run' || command.kind === 'restart') return { ...command, debug }
  if (debug) return { kind: 'usage', message: "'--debug' is only for sarto run and sarto restart" }
  if (command.kind === 'report') return reportCommand(given)
  if (command.kind === 'logs') return logsCommand(given)
  if (command.kind === 'update') return updateCommand(given)
  return command
}

function updateCommand(given: Given): Command {
  const raw = given.get('channel')?.value ?? null
  if (raw !== null && raw !== 'stable' && raw !== 'beta') {
    return { kind: 'usage', message: `The channel is stable or beta, not ${quote(raw)}` }
  }
  return { kind: 'update', channel: raw }
}

function reportCommand(given: Given): Command {
  const value = (name: OptionName): string | null => given.get(name)?.value ?? null
  const range = value('range') ?? 'hour'
  if (!Object.hasOwn(RANGES, range)) {
    return { kind: 'usage', message: `The range is hour, today or 2d, not ${quote(range)}` }
  }
  const extras: ReportExtra[] = []
  for (const item of (value('with') ?? '').split(',').map((part) => part.trim())) {
    if (item === '') continue
    if (!CLI_EXTRAS.includes(item as ReportExtra)) {
      return {
        kind: 'usage',
        message: `--with takes titles, messages, verbose and dumps, not ${quote(item)}`,
      }
    }
    if (!extras.includes(item as ReportExtra)) extras.push(item as ReportExtra)
  }
  const description = value('message')
  if (description !== null && description.trim() === '') {
    return { kind: 'usage', message: 'Say what happened in --message' }
  }
  return {
    kind: 'report',
    description,
    range: RANGES[range]!,
    extras,
    output: value('output'),
    submit: given.has('submit'),
  }
}

function logsCommand(given: Given): Command {
  const value = (name: OptionName): string | null => given.get(name)?.value ?? null
  const level = value('level')
  if (level !== null && !LOG_LEVELS.includes(level as LogLevel)) {
    return {
      kind: 'usage',
      message: `The level is debug, info, warn or error, not ${quote(level)}`,
    }
  }
  const follow = given.has('follow')
  if (follow && given.has('until')) {
    return { kind: 'usage', message: "'--until' does not go with '--follow'" }
  }
  return {
    kind: 'logs',
    process: value('process'),
    level: level as LogLevel | null,
    op: value('op'),
    since: value('since'),
    until: value('until'),
    follow,
  }
}

function parseWords(words: string[]): Command {
  const [name, ...rest] = words
  const extra = (at: number): Command | null =>
    rest.length > at ? { kind: 'usage', message: `Unexpected argument ${quote(rest[at]!)}` } : null
  switch (name) {
    case undefined:
    case 'help':
      return extra(0) ?? { kind: 'help' }
    case 'run':
      return extra(0) ?? { kind: 'run', debug: false }
    case 'restart':
      return extra(0) ?? { kind: 'restart', debug: false }
    case 'status':
      return extra(0) ?? { kind: 'status' }
    case 'update':
      return extra(0) ?? { kind: 'update', channel: null }
    case 'login':
      return extra(0) ?? { kind: 'login' }
    case 'logout':
      return extra(0) ?? { kind: 'logout' }
    case 'ssh-setup':
      return extra(1) ?? { kind: 'ssh-setup', request: rest[0] ?? null }
    // Their options are read once the command is known.
    case 'report':
      return (
        extra(0) ?? {
          kind: 'report',
          description: null,
          range: 'hour',
          extras: [],
          output: null,
          submit: false,
        }
      )
    case 'logs':
      return (
        extra(0) ?? {
          kind: 'logs',
          process: null,
          level: null,
          op: null,
          since: null,
          until: null,
          follow: false,
        }
      )
    case 'verbose':
      if (rest[0] !== 'on' && rest[0] !== 'off') {
        return {
          kind: 'usage',
          message:
            rest[0] === undefined ? 'Name on or off' : `Unknown verbose command ${quote(rest[0])}`,
        }
      }
      return extra(1) ?? { kind: 'verbose', on: rest[0] === 'on' }
    case 'devices':
      if (rest.length === 0) return { kind: 'devices' }
      if (rest[0] !== 'remove') {
        return { kind: 'usage', message: `Unknown devices command ${quote(rest[0]!)}` }
      }
      if (rest.length < 2) return { kind: 'usage', message: "Name the device's id to remove" }
      return extra(2) ?? { kind: 'devices-remove', id: rest[1]! }
    case 'terminal':
      if (rest[0] === undefined) return { kind: 'terminal' }
      if (rest[0] !== 'on' && rest[0] !== 'off') {
        return { kind: 'usage', message: `Unknown terminal command ${quote(rest[0])}` }
      }
      return extra(1) ?? { kind: 'terminal-set', allowed: rest[0] === 'on' }
    case 'service':
      if (rest[0] === 'install') return extra(1) ?? { kind: 'service-install' }
      if (rest[0] === 'uninstall') return extra(1) ?? { kind: 'service-uninstall' }
      if (rest[0] === undefined) return { kind: 'usage', message: 'Name install or uninstall' }
      return { kind: 'usage', message: `Unknown service command ${quote(rest[0])}` }
    default:
      return { kind: 'usage', message: `Unknown command ${quote(name)}` }
  }
}
