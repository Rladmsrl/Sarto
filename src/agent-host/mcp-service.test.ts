import { afterEach, describe, expect, it } from 'vitest'
import type { CallToolResult, Tool } from '@modelcontextprotocol/sdk/types.js'
import { PLAN_PROMPT } from './plan-tool'
import { CORE_TOOLS, declared, GATEWAY_TOOL } from './tool-gateway'
import { McpService, type AgentProcess, type McpServiceDeps } from './mcp-service'

const services: McpService[] = []

async function started(): Promise<McpService> {
  const deps = { log: () => {}, plan: {}, sessions: {} } as unknown as McpServiceDeps
  const service = new McpService(deps)
  services.push(service)
  await service.start()
  return service
}

afterEach(async () => {
  await Promise.all(services.splice(0).map((service) => service.stop()))
})

describe('the servers a session attaches with', () => {
  // An agent that writes its servers onto a command line would show the token to every user.
  it('mark the token as a secret', async () => {
    const service = await started()
    const process = { closed: new Promise<void>(() => {}) } as AgentProcess
    const servers = [
      ...service.servers('s1', '/repo'),
      ...service.folderServers(process, '/repo', 's2'),
    ]
    expect(servers).toHaveLength(2)
    for (const server of servers) expect(server.secret).toBe(true)
  })

  // Allowed tools run without asking the user, so none may reach past Sarto's own data.
  it("allow without asking only Sarto's plan, report, memory, session, Marketplace and settings tools, its guide, listing, reading and naming terminals and reading pages", async () => {
    const service = await started()
    const process = { closed: new Promise<void>(() => {}) } as AgentProcess
    const expected = [
      'set_plan',
      // A terminal of the user's asks them in Sarto's own card before these reach it.
      'terminal_list',
      'terminal_read',
      'terminal_wait',
      'terminal_rename',
      'browser_snapshot',
      'browser_take_screenshot',
      'browser_wait_for',
      'browser_console_messages',
      'browser_network_requests',
      'device_list',
      'device_snapshot',
      'device_screenshot',
      'device_logs',
      'computer_list_apps',
      'report_problem',
      'suggest_next_message',
      'list_memories',
      'read_memory',
      'remember',
      'update_memory',
      'forget_memory',
      'list_agents',
      'list_sessions',
      'get_session',
      'rename_session',
      'archive_session',
      'start_session',
      'read_session_history',
      'send_message',
      'find_settings',
      'open_settings',
      'change_settings',
      'read_sarto_guide',
    ]
    for (const server of [
      ...service.servers('s1', '/repo'),
      ...service.folderServers(process, '/repo', 's2'),
    ]) {
      expect(server.type === 'stdio' ? [] : [...(server.autoAllow ?? [])].sort()).toEqual(
        [...expected].sort(),
      )
    }
  })
})

/**
 * What the service answers a request of an agent's, as a session's token reaches it; `gateway` for
 * an agent given the short list.
 */
async function answer<T>(
  service: McpService,
  method: string,
  params: unknown,
  gateway = false,
  suggests = false,
): Promise<{ result?: T; error?: { message: string } }> {
  const [server] = service.servers('s1', '/repo', gateway, suggests)
  if (!server || server.type !== 'http') throw new Error('No server')
  const response = await fetch(server.url, {
    method: 'POST',
    headers: {
      ...Object.fromEntries(server.headers.map((header) => [header.name, header.value])),
      'Content-Type': 'application/json',
      Accept: 'application/json, text/event-stream',
    },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
  })
  return (await response.json()) as { result?: T; error?: { message: string } }
}

async function rpc<T>(service: McpService, method: string, params: unknown): Promise<T> {
  return (await answer<T>(service, method, params)).result!
}

/** A call of the gateway from a session given the short list. */
async function viaGateway(service: McpService, args: unknown): Promise<CallToolResult> {
  const body = await answer<CallToolResult>(
    service,
    'tools/call',
    { name: GATEWAY_TOOL, arguments: args },
    true,
  )
  if (!body.result) throw new Error(body.error?.message ?? 'No result')
  return body.result
}

const texts = (result: CallToolResult): string =>
  result.content.map((block) => (block.type === 'text' ? block.text : '')).join('\n')

const INITIALIZE = {
  protocolVersion: '2025-06-18',
  capabilities: {},
  clientInfo: { name: 'test', version: '1' },
}

/** A service with memory and computer use on. */
async function everythingOn(): Promise<McpService> {
  const deps = {
    log: () => {},
    plan: {},
    sessions: {},
    suggest: { note: () => true },
    memory: { service: { enabled: true } },
    computer: { call: () => Promise.reject(new Error('not in this test')) },
  } as unknown as McpServiceDeps
  const service = new McpService(deps)
  services.push(service)
  await service.start()
  return service
}

describe("the service's instructions", () => {
  // Claude Code keeps only the first 4096 characters of a server's instructions.
  it('stay within 4096 characters with memory, the Marketplace and computer use on', async () => {
    const service = await everythingOn()
    const { instructions } = await rpc<{ instructions?: string }>(service, 'initialize', INITIALIZE)
    expect(instructions).toBeTypeOf('string')
    expect(instructions!.length).toBeLessThanOrEqual(4096)
  })
})

describe('what an agent reads before it searches its tools', () => {
  // Claude Code and Codex put a server's prompt into their own instructions.
  it("is Sarto's guide and the plan paragraph in the server's prompt", async () => {
    const service = await everythingOn()
    const [server] = service.servers('s1', '/repo')
    expect(server?.type === 'http' && server.prompt).toBe(
      `${service.guidePrompt(true)}\n\n${PLAN_PROMPT}`,
    )
  })

  // Claude Code defers MCP tools behind a search, so an entry tool it does not list goes unused.
  it('lists the plan tool and the entries to sessions and the browser from the start', async () => {
    const service = await everythingOn()
    const { tools } = await rpc<{ tools: Tool[] }>(service, 'tools/list', {})
    const loaded = tools
      .filter((tool) => tool._meta?.['anthropic/alwaysLoad'] === true)
      .map((tool) => tool.name)
    expect(loaded.sort()).toEqual(['browser_navigate', 'set_plan', 'start_session'].sort())
  })
})

describe('disabling problem reports', () => {
  it('omits report tools from tools/list and autoAllow', async () => {
    const deps = {
      log: () => {},
      plan: {},
      sessions: {},
      reports: false,
    } as unknown as McpServiceDeps
    const service = new McpService(deps)
    services.push(service)
    await service.start()
    const { tools } = await rpc<{ tools: Tool[] }>(service, 'tools/list', {})
    const toolNames = tools.map((tool) => tool.name)
    expect(toolNames).not.toContain('report_problem')
    expect(toolNames).toContain('start_session')
    expect(toolNames).toContain('terminal_run')
    const [server] = service.servers('s1', '/repo')
    expect(server?.type === 'http' ? server.autoAllow : []).not.toContain('report_problem')
  })
})

// agy drops the largest MCP tools past a budget of its own and cannot call a dropped one over ACP.
describe('an agent that drops tools past a budget of its own', () => {
  it('is listed the core tools and the gateway, within 16000 bytes, the gateway the smallest', async () => {
    const service = await everythingOn()
    const { result } = await answer<{ tools: Tool[] }>(service, 'tools/list', {}, true, true)
    const tools = result!.tools
    expect(tools.map((tool) => tool.name).sort()).toEqual([...CORE_TOOLS, GATEWAY_TOOL].sort())
    const size = (tool: Tool) => JSON.stringify(declared(tool)).length
    expect(tools.reduce((sum, tool) => sum + size(tool), 0)).toBeLessThanOrEqual(16000)
    const gateway = tools.find((tool) => tool.name === GATEWAY_TOOL)!
    for (const tool of tools) {
      if (tool !== gateway) expect(size(gateway)).toBeLessThan(size(tool))
    }
  })

  it("leaves every other agent's list as it is", async () => {
    const service = await everythingOn()
    const { result } = await answer<{ tools: Tool[] }>(service, 'tools/list', {}, false, true)
    const names = result!.tools.map((tool) => tool.name)
    expect(names).not.toContain(GATEWAY_TOOL)
    expect(names).toEqual(service.toolSummaries().map((tool) => tool.name))
  })

  it("runs only a tool of the session's full list", async () => {
    const service = await everythingOn()
    // A step's own tool, which a session outside a workflow step is not given.
    for (const tool of ['report_step', 'no_such_tool', GATEWAY_TOOL]) {
      const result = await viaGateway(service, { tool, arguments: {} })
      expect(result.isError).toBe(true)
      expect(texts(result)).toContain(`${tool} is not a Sarto tool this session can use`)
    }
    const odd = await viaGateway(service, { tool: 'list_agents', arguments: [] })
    expect(odd.isError).toBe(true)
  })

  it('describes a tool without running it when the call has no arguments', async () => {
    // Memory has no store here, so running a memory tool would fail.
    const service = await everythingOn()
    const result = await viaGateway(service, { tool: 'forget_memory' })
    expect(result.isError).toBeUndefined()
    expect(texts(result)).toContain('Arguments of forget_memory (JSON Schema): {')
  })

  it("runs a tool as a direct call does, and a topic lists its part's tools with their arguments", async () => {
    const service = await everythingOn()
    const result = await viaGateway(service, {
      tool: 'read_sarto_guide',
      arguments: { topic: 'devices' },
    })
    expect(result.isError).toBeUndefined()
    expect(texts(result)).toContain('### device_tap')
    expect(texts(result)).toContain('Arguments of device_tap (JSON Schema): {')
    // The harness may drop a core tool too, so the topic gives its arguments as well.
    const sessions = await viaGateway(service, {
      tool: 'read_sarto_guide',
      arguments: { topic: 'sessions' },
    })
    expect(texts(sessions)).toContain('Arguments of start_session (JSON Schema): {')
    expect(texts(sessions)).not.toContain(`### ${GATEWAY_TOOL}`)

    const direct = await rpc<CallToolResult>(service, 'tools/call', {
      name: 'read_sarto_guide',
      arguments: { topic: 'devices' },
    })
    expect(texts(direct)).not.toContain(GATEWAY_TOOL)
  })

  it('adds the arguments to a call that failed', async () => {
    const service = await everythingOn()
    const result = await viaGateway(service, {
      tool: 'read_sarto_guide',
      arguments: { topic: 'nope' },
    })
    expect(result.isError).toBe(true)
    expect(texts(result)).toContain('Arguments of read_sarto_guide (JSON Schema)')
  })

  it('is no tool for a session given the full list', async () => {
    const service = await everythingOn()
    const body = await answer(service, 'tools/call', {
      name: GATEWAY_TOOL,
      arguments: { tool: 'list_agents', arguments: {} },
    })
    expect(body.error?.message).toContain(`Unknown tool ${GATEWAY_TOOL}`)
  })
})
