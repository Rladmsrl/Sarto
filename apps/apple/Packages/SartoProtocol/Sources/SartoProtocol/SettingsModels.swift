import Foundation

// MARK: - Daemon Control Socket Models (src/daemon/control.ts)

public struct DaemonHostProcessStatus: Codable, Sendable, Equatable {
    public let state: String
    public let pid: Int?
    public let restarts: Int

    public init(state: String = "idle", pid: Int? = nil, restarts: Int = 0) {
        self.state = state
        self.pid = pid
        self.restarts = restarts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.state = try c.decodeIfPresent(String.self, forKey: .state) ?? "idle"
        self.pid = try c.decodeIfPresent(Int.self, forKey: .pid)
        self.restarts = try c.decodeIfPresent(Int.self, forKey: .restarts) ?? 0
    }
}

public struct DaemonHostsMap: Codable, Sendable, Equatable {
    public let agent: DaemonHostProcessStatus
    public let terminal: DaemonHostProcessStatus
    public let remote: DaemonHostProcessStatus

    public init(
        agent: DaemonHostProcessStatus = .init(),
        terminal: DaemonHostProcessStatus = .init(),
        remote: DaemonHostProcessStatus = .init()
    ) {
        self.agent = agent
        self.terminal = terminal
        self.remote = remote
    }
}

public struct DirectListenerStatus: Codable, Sendable, Equatable {
    public let state: String
    public let port: Int?
    public let addresses: [DirectAddress]
    public let error: String?

    public init(state: String = "off", port: Int? = nil, addresses: [DirectAddress] = [], error: String? = nil) {
        self.state = state
        self.port = port
        self.addresses = addresses
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.state = try c.decodeIfPresent(String.self, forKey: .state) ?? "off"
        self.port = try c.decodeIfPresent(Int.self, forKey: .port)
        self.addresses = try c.decodeIfPresent([DirectAddress].self, forKey: .addresses) ?? []
        self.error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

public struct DirectReportInfo: Codable, Sendable, Equatable {
    public let port: Int?
    public let own: [DirectAddress]
    public let status: DirectListenerStatus?

    public init(port: Int? = nil, own: [DirectAddress] = [], status: DirectListenerStatus? = nil) {
        self.port = port
        self.own = own
        self.status = status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.port = try c.decodeIfPresent(Int.self, forKey: .port)
        self.own = try c.decodeIfPresent([DirectAddress].self, forKey: .own) ?? []
        self.status = try c.decodeIfPresent(DirectListenerStatus.self, forKey: .status)
    }
}

public struct DaemonStatusInfo: Codable, Sendable, Equatable {
    public let version: String
    public let build: String?
    public let channel: String?
    public let commit: String?
    public let origin: String?
    public let pid: Int
    public let startedAt: Double
    public let stopping: Bool
    public let dataPath: String
    public let service: Bool
    public let hosts: DaemonHostsMap
    public let connectedDevices: Int?
    public let direct: DirectListenerStatus?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decodeIfPresent(String.self, forKey: .version) ?? "0.0.0"
        self.build = try c.decodeIfPresent(String.self, forKey: .build)
        self.channel = try c.decodeIfPresent(String.self, forKey: .channel)
        self.commit = try c.decodeIfPresent(String.self, forKey: .commit)
        self.origin = try c.decodeIfPresent(String.self, forKey: .origin)
        self.pid = try c.decodeIfPresent(Int.self, forKey: .pid) ?? 0
        self.startedAt = try c.decodeIfPresent(Double.self, forKey: .startedAt) ?? 0
        self.stopping = try c.decodeIfPresent(Bool.self, forKey: .stopping) ?? false
        self.dataPath = try c.decodeIfPresent(String.self, forKey: .dataPath) ?? ""
        self.service = try c.decodeIfPresent(Bool.self, forKey: .service) ?? false
        self.hosts = try c.decodeIfPresent(DaemonHostsMap.self, forKey: .hosts) ?? DaemonHostsMap()
        self.connectedDevices = try c.decodeIfPresent(Int.self, forKey: .connectedDevices)
        self.direct = try c.decodeIfPresent(DirectListenerStatus.self, forKey: .direct)
    }
}

public struct PairedDeviceSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let kind: String
    public let platform: String
    public let connected: Bool
    public let lastConnectedAt: Double?

    public init(
        id: String,
        name: String,
        kind: String,
        platform: String,
        connected: Bool,
        lastConnectedAt: Double?
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.platform = platform
        self.connected = connected
        self.lastConnectedAt = lastConnectedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Device"
        self.kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "mobile"
        self.platform = try c.decodeIfPresent(String.self, forKey: .platform) ?? "ios"
        self.connected = try c.decodeIfPresent(Bool.self, forKey: .connected) ?? false
        self.lastConnectedAt = try c.decodeIfPresent(Double.self, forKey: .lastConnectedAt)
    }
}

public struct ReportBuildResultInfo: Codable, Sendable, Equatable {
    public let ok: Bool?
    public let file: String?
    public let path: String?
    public let size: Int?
    public let redactionCount: Int?
    public let reason: String?
    public let message: String?

    public var resolvedPath: String? { file ?? path }
}

public struct ReportDraftResultInfo: Codable, Sendable, Equatable {
    public let draft: String?
    public let agent: String?

    public init(draft: String?, agent: String?) {
        self.draft = draft
        self.agent = agent
    }
}

public struct ReportFileInfo: Codable, Sendable, Equatable, Identifiable {
    public let path: String
    public let size: Int
    /// `"text"` | `"image"` | `"binary"`
    public let kind: String

    public var id: String { path }

    public var isSensitive: Bool {
        path.hasPrefix("messages/") || path.hasPrefix("logs/verbose-") || path.hasPrefix("crash/")
    }

    public init(path: String, size: Int, kind: String) {
        self.path = path
        self.size = size
        self.kind = kind
    }
}

public struct PreparedReportInfo: Codable, Sendable, Equatable {
    public let ok: Bool
    public let id: String?
    public let files: [ReportFileInfo]?
    public let size: Int?
    public let redactionCount: Int?
    public let reason: String?
    public let message: String?
}

public struct ReportFileViewInfo: Codable, Sendable, Equatable {
    /// `"text"` | `"image"` | `"binary"`
    public let kind: String
    public let text: String?
    public let truncated: Bool?
    public let dataUrl: String?
}

public struct ReportSaveResultInfo: Codable, Sendable, Equatable {
    public let ok: Bool
    public let path: String
}

public struct ReportSubmitResultInfo: Codable, Sendable, Equatable {
    public let ok: Bool
    public let id: String?
    public let anonymous: Bool?
    public let consoleUrl: String?
    public let issueUrl: String?
    public let reason: String?
    public let message: String?
    public let retryAfter: Int?
}

public struct DeviceReportInfo: Codable, Sendable, Equatable {
    public let ok: Bool
    public let zip: String?
    public let files: [ReportFileInfo]?
    public let size: Int?
    public let ref: String?
    public let redactionCount: Int?
    public let reason: String?
}

public struct ReportClientCrashPayload: Sendable, Equatable {
    public let name: String
    public let content: String

    public init(name: String, content: String) {
        self.name = name
        self.content = content
    }
}

public struct ReportClientPayloadInfo: Sendable, Equatable {
    public let appVersion: String?
    public let appBuild: String?
    public let osVersion: String?
    public let hardware: String?
    public let display: String?
    public let clientLog: String?
    public let crashReports: [ReportClientCrashPayload]
    public let screenshotBase64: String?

    public init(
        appVersion: String? = nil,
        appBuild: String? = nil,
        osVersion: String? = nil,
        hardware: String? = nil,
        display: String? = nil,
        clientLog: String? = nil,
        crashReports: [ReportClientCrashPayload] = [],
        screenshotBase64: String? = nil
    ) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.osVersion = osVersion
        self.hardware = hardware
        self.display = display
        self.clientLog = clientLog
        self.crashReports = crashReports
        self.screenshotBase64 = screenshotBase64
    }

    public func toJSONValue() -> JSONValue {
        var obj: [String: JSONValue] = [:]
        if let appVersion, !appVersion.isEmpty { obj["appVersion"] = .string(appVersion) }
        if let appBuild, !appBuild.isEmpty { obj["appBuild"] = .string(appBuild) }
        if let osVersion, !osVersion.isEmpty { obj["osVersion"] = .string(osVersion) }
        if let hardware, !hardware.isEmpty { obj["hardware"] = .string(hardware) }
        if let display, !display.isEmpty { obj["display"] = .string(display) }
        if let clientLog, !clientLog.isEmpty { obj["clientLog"] = .string(clientLog) }
        if !crashReports.isEmpty {
            obj["crashReports"] = .array(crashReports.map {
                .object(["name": .string($0.name), "content": .string($0.content)])
            })
        }
        if let screenshotBase64, !screenshotBase64.isEmpty {
            obj["screenshot"] = .string(screenshotBase64)
        }
        return .object(obj)
    }
}

public struct CloudReportSummaryInfo: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let description: String
    public let version: String
    public let platform: String
    public let deviceName: String?
    /// `"submitted"` | `"investigating"` | `"confirmed"` | `"fixed"` | `"wont_fix"` | `"closed"`
    public let status: String
    public let issueUrl: String?
    public let fixedInVersion: String?
    public let hasBundle: Bool
    public let bundleSize: Int
    public let commentCount: Int
    public let createdAt: Double
    public let updatedAt: Double
    public let anonymous: Bool?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        self.platform = try c.decodeIfPresent(String.self, forKey: .platform) ?? ""
        self.deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName)
        self.status = try c.decodeIfPresent(String.self, forKey: .status) ?? "submitted"
        self.issueUrl = try c.decodeIfPresent(String.self, forKey: .issueUrl)
        self.fixedInVersion = try c.decodeIfPresent(String.self, forKey: .fixedInVersion)
        self.hasBundle = try c.decodeIfPresent(Bool.self, forKey: .hasBundle) ?? false
        self.bundleSize = try c.decodeIfPresent(Int.self, forKey: .bundleSize) ?? 0
        self.commentCount = try c.decodeIfPresent(Int.self, forKey: .commentCount) ?? 0
        self.createdAt = try c.decodeIfPresent(Double.self, forKey: .createdAt) ?? 0
        self.updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0
        self.anonymous = try c.decodeIfPresent(Bool.self, forKey: .anonymous)
    }
}

public struct CloudReportListInfo: Codable, Sendable, Equatable {
    public let signedIn: Bool
    public let origin: String
    public let reports: [CloudReportSummaryInfo]
    public let total: Int
    public let countsByStatus: [String: Int]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.signedIn = try c.decodeIfPresent(Bool.self, forKey: .signedIn) ?? false
        self.origin = try c.decodeIfPresent(String.self, forKey: .origin) ?? ""
        self.reports = try c.decodeIfPresent([CloudReportSummaryInfo].self, forKey: .reports) ?? []
        self.total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
        self.countsByStatus = try c.decodeIfPresent([String: Int].self, forKey: .countsByStatus) ?? [:]
    }
}

// MARK: - Host Settings Snapshot (src/shared/remote/host-admin.ts, src/shared/settings.ts, src/shared/idle-release.ts)

public struct HostSettingsSnapshot: Sendable, Equatable {
    public var defaultAgent: String?
    public var sessionTitles: Bool
    public var promptSuggestions: Bool
    /// `"small"` | `"session"` | `"pinned"`
    public var lightModelMode: String
    public var lightModelAgentId: String?
    public var lightModelId: String?
    public var disabledAgents: [String]
    public var startModes: [String: String]
    public var agentBinaryPaths: [String: String]
    public var proxyMode: String
    public var proxyUrl: String
    public var proxyNoProxy: String
    public var terminalShellPath: String?
    public var gitBackgroundFetch: Bool
    public var gitWorktreeRoot: String?
    /// `"auto"` | `"custom"` | `"never"` (matching `IdleReleaseMode` in `src/shared/idle-release.ts`)
    public var idleRelease: String
    public var idleOutOfView: Int
    public var idleInView: Int
    public var idleLimit: Int?
    public var usageFromComputer: Bool
    public var remoteName: String?
    public var remoteTerminal: Bool
    public var remoteClaudeEnabled: Bool
    public var remoteClaudeMaxConcurrent: Int
    public var remoteClaudeIdleMinutes: Int
    public var remoteDirectEnabled: Bool
    public var remoteDirectPort: Int?
    public var verboseUntil: Double?
    /// Agents for which Sarto's built-in `sarto` MCP server is turned off (`mcp.sarto.off`).
    public var mcpSartoOff: [String]
    /// User-managed MCP servers distributed to agents (`marketplace.mcp`).
    public var marketplaceMcp: [MarketServerInfo]

    public init(
        defaultAgent: String? = nil,
        sessionTitles: Bool = true,
        promptSuggestions: Bool = true,
        lightModelMode: String = "small",
        lightModelAgentId: String? = nil,
        lightModelId: String? = nil,
        disabledAgents: [String] = [],
        startModes: [String: String] = [:],
        agentBinaryPaths: [String: String] = [:],
        proxyMode: String = "environment",
        proxyUrl: String = "",
        proxyNoProxy: String = "",
        terminalShellPath: String? = nil,
        gitBackgroundFetch: Bool = false,
        gitWorktreeRoot: String? = nil,
        idleRelease: String = "auto",
        idleOutOfView: Int = 15,
        idleInView: Int = 30,
        idleLimit: Int? = nil,
        usageFromComputer: Bool = false,
        remoteName: String? = nil,
        remoteTerminal: Bool = false,
        remoteClaudeEnabled: Bool = false,
        remoteClaudeMaxConcurrent: Int = 3,
        remoteClaudeIdleMinutes: Int = 10,
        remoteDirectEnabled: Bool = true,
        remoteDirectPort: Int? = nil,
        verboseUntil: Double? = nil,
        mcpSartoOff: [String] = [],
        marketplaceMcp: [MarketServerInfo] = []
    ) {
        self.defaultAgent = defaultAgent
        self.sessionTitles = sessionTitles
        self.promptSuggestions = promptSuggestions
        self.lightModelMode = lightModelMode
        self.lightModelAgentId = lightModelAgentId
        self.lightModelId = lightModelId
        self.disabledAgents = disabledAgents
        self.startModes = startModes
        self.agentBinaryPaths = agentBinaryPaths
        self.proxyMode = proxyMode
        self.proxyUrl = proxyUrl
        self.proxyNoProxy = proxyNoProxy
        self.terminalShellPath = terminalShellPath
        self.gitBackgroundFetch = gitBackgroundFetch
        self.gitWorktreeRoot = gitWorktreeRoot
        self.idleRelease = idleRelease
        self.idleOutOfView = idleOutOfView
        self.idleInView = idleInView
        self.idleLimit = idleLimit
        self.usageFromComputer = usageFromComputer
        self.remoteName = remoteName
        self.remoteTerminal = remoteTerminal
        self.remoteClaudeEnabled = remoteClaudeEnabled
        self.remoteClaudeMaxConcurrent = remoteClaudeMaxConcurrent
        self.remoteClaudeIdleMinutes = remoteClaudeIdleMinutes
        self.remoteDirectEnabled = remoteDirectEnabled
        self.remoteDirectPort = remoteDirectPort
        self.verboseUntil = verboseUntil
        self.mcpSartoOff = mcpSartoOff
        self.marketplaceMcp = marketplaceMcp
    }

    public static func from(json: JSONValue) -> HostSettingsSnapshot {
        guard let root = json.objectValue else { return HostSettingsSnapshot() }
        var s = HostSettingsSnapshot()

        if let gen = root["general"]?.objectValue {
            s.defaultAgent = gen["defaultAgent"]?.stringValue
            if let v = gen["sessionTitles"]?.boolValue { s.sessionTitles = v }
            if let v = gen["promptSuggestions"]?.boolValue { s.promptSuggestions = v }
            if let lm = gen["lightModel"]?.objectValue {
                if let mode = lm["mode"]?.stringValue {
                    s.lightModelMode = mode
                }
                s.lightModelAgentId = lm["agentId"]?.stringValue
                s.lightModelId = lm["model"]?.stringValue
            }
        }
        if let arr = root["disabledAgents"]?.arrayValue {
            s.disabledAgents = arr.compactMap(\.stringValue)
        }
        if let modes = root["startModes"]?.objectValue {
            var map: [String: String] = [:]
            for (k, v) in modes {
                if let str = v.stringValue { map[k] = str }
            }
            s.startModes = map
        }
        if let agents = root["agents"]?.objectValue {
            var bins: [String: String] = [:]
            for (k, v) in agents {
                if let bp = v.objectValue?["binaryPath"]?.stringValue, !bp.isEmpty {
                    bins[k] = bp
                }
            }
            s.agentBinaryPaths = bins
        }
        if let proxy = root["proxy"]?.objectValue {
            if let mode = proxy["mode"]?.stringValue { s.proxyMode = mode }
            if let url = proxy["url"]?.stringValue { s.proxyUrl = url }
            if let np = proxy["noProxy"]?.stringValue { s.proxyNoProxy = np }
        }
        if let term = root["terminal"]?.objectValue {
            s.terminalShellPath = term["shellPath"]?.stringValue
        }
        if let git = root["git"]?.objectValue {
            if let f = git["backgroundFetch"]?.boolValue { s.gitBackgroundFetch = f }
            s.gitWorktreeRoot = git["worktreeRoot"]?.stringValue
        }
        if let idle = root["idleSessions"]?.objectValue {
            if let release = idle["release"]?.stringValue { s.idleRelease = release }
            if let out = idle["outOfView"]?.doubleValue.flatMap(Int.wholePart(of:)) { s.idleOutOfView = out }
            if let inV = idle["inView"]?.doubleValue.flatMap(Int.wholePart(of:)) { s.idleInView = inV }
            if let limVal = idle["limit"] {
                s.idleLimit = limVal.doubleValue.flatMap(Int.wholePart(of:))
            }
        }
        if let usage = root["usage"]?.objectValue {
            if let fc = usage["fromComputer"]?.boolValue { s.usageFromComputer = fc }
        }
        if let remote = root["remote"]?.objectValue {
            s.remoteName = remote["name"]?.stringValue
            if let t = remote["terminal"]?.boolValue { s.remoteTerminal = t }
            if let c = remote["claude"]?.objectValue {
                if let en = c["enabled"]?.boolValue { s.remoteClaudeEnabled = en }
                if let mc = c["maxConcurrent"]?.doubleValue.flatMap(Int.wholePart(of:)) {
                    s.remoteClaudeMaxConcurrent = mc
                }
                if let im = c["idleMinutes"]?.doubleValue.flatMap(Int.wholePart(of:)) {
                    s.remoteClaudeIdleMinutes = im
                }
            }
            if let d = remote["direct"]?.objectValue {
                if let en = d["enabled"]?.boolValue { s.remoteDirectEnabled = en }
                if let p = d["port"]?.doubleValue.flatMap(Int.wholePart(of:)) { s.remoteDirectPort = p }
            }
        }
        if let diag = root["diagnostics"]?.objectValue {
            s.verboseUntil = diag["verboseUntil"]?.doubleValue
        }
        if let mcp = root["mcp"]?.objectValue,
           let sarto = mcp["sarto"]?.objectValue,
           let off = sarto["off"]?.arrayValue {
            s.mcpSartoOff = off.compactMap(\.stringValue)
        }
        if let market = root["marketplace"]?.objectValue,
           let mcpVal = market["mcp"],
           let decoded = try? mcpVal.decode([MarketServerInfo].self) {
            s.marketplaceMcp = decoded
        }
        return s
    }
}

// MARK: - Agents & Harnesses Extended Models (src/shared/agent-host.ts)

public struct AgentApiKeyInfo: Codable, Sendable, Equatable {
    public let set: Bool
    public let providers: Bool

    public init(set: Bool = false, providers: Bool = false) {
        self.set = set
        self.providers = providers
    }
}

public struct AgentAuthEnvVarInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let optional: Bool
    public let set: Bool

    public init(name: String, optional: Bool = false, set: Bool = false) {
        self.name = name
        self.optional = optional
        self.set = set
    }

    private enum CodingKeys: String, CodingKey {
        case name, optional, set
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.optional = (try? c.decodeIfPresent(Bool.self, forKey: .optional)) ?? false
        self.set = (try? c.decodeIfPresent(Bool.self, forKey: .set)) ?? false
    }
}

public struct AgentAuthMethodInfo: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let description: String?
    /// `"agent"`, `"terminal"`, or `"env"`. Defaults to `"agent"` when absent on older hosts.
    public let type: String
    public let command: String?
    public let delegated: Bool
    public let envVars: [AgentAuthEnvVarInfo]?

    public init(
        id: String,
        name: String,
        description: String? = nil,
        type: String = "agent",
        command: String? = nil,
        delegated: Bool = false,
        envVars: [AgentAuthEnvVarInfo]? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.type = type
        self.command = command
        self.delegated = delegated
        self.envVars = envVars
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, description, type, command, delegated, envVars
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.description = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? nil
        self.type = ((try? c.decodeIfPresent(String.self, forKey: .type)) ?? nil) ?? "agent"
        self.command = (try? c.decodeIfPresent(String.self, forKey: .command)) ?? nil
        self.delegated = ((try? c.decodeIfPresent(Bool.self, forKey: .delegated)) ?? nil) ?? false
        self.envVars = (try? c.decodeIfPresent([AgentAuthEnvVarInfo].self, forKey: .envVars)) ?? nil
    }
}

/// Matches `AgentUpdate` in `src/shared/agent-host.ts`: `{ adapterVersion: string, cliVersion: string | null }`.
public struct AgentUpdateInfo: Codable, Sendable, Equatable {
    public let adapterVersion: String
    public let cliVersion: String?

    public init(adapterVersion: String, cliVersion: String? = nil) {
        self.adapterVersion = adapterVersion
        self.cliVersion = cliVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.adapterVersion = try c.decodeIfPresent(String.self, forKey: .adapterVersion) ?? ""
        self.cliVersion = try c.decodeIfPresent(String.self, forKey: .cliVersion)
    }

    public var displayVersion: String? {
        if let cliVersion, !cliVersion.isEmpty { return cliVersion }
        return adapterVersion.isEmpty ? nil : adapterVersion
    }
}

public struct AgentCliUpdateInfo: Codable, Sendable, Equatable {
    public let version: String
    public let command: String
}

public struct AgentInstalledCliInfo: Codable, Sendable, Equatable {
    public let path: String
    public let version: String?
    public let variable: String?
    /// Why it cannot run; absent on older hosts.
    public let problem: InstalledCliProblem?

    public init(path: String, version: String? = nil, variable: String? = nil, problem: InstalledCliProblem? = nil) {
        self.path = path
        self.version = version
        self.variable = variable
        self.problem = problem
    }
}

/// Matches `AgentCli` in `src/shared/agent-host.ts`.
public struct AgentCliInfo: Codable, Sendable, Equatable {
    public let command: String
    public let installed: AgentInstalledCliInfo?
    public let method: String?
    public let update: AgentCliUpdateInfo?
    /// Whether its newer versions can be read, by how it was installed; absent on older hosts.
    public let checkable: Bool?

    public init(
        command: String,
        installed: AgentInstalledCliInfo? = nil,
        method: String? = nil,
        update: AgentCliUpdateInfo? = nil,
        checkable: Bool? = nil
    ) {
        self.command = command
        self.installed = installed
        self.method = method
        self.update = update
        self.checkable = checkable
    }

    public var canUpdate: Bool {
        update != nil
    }
}

/// Matches `AgentTask` in `src/shared/agent-host.ts`.
public struct AgentTaskInfo: Codable, Sendable, Equatable {
    public let kind: String
    public let state: String
    public let command: String?
    public let method: String?
    public let progress: [String]?
    public let error: String?

    public init(
        kind: String,
        state: String = "running",
        command: String? = nil,
        method: String? = nil,
        progress: [String]? = nil,
        error: String? = nil
    ) {
        self.kind = kind
        self.state = state
        self.command = command
        self.method = method
        self.progress = progress
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "update"
        self.state = try c.decodeIfPresent(String.self, forKey: .state) ?? "running"
        self.command = try c.decodeIfPresent(String.self, forKey: .command)
        self.method = try c.decodeIfPresent(String.self, forKey: .method)
        self.progress = try c.decodeIfPresent([String].self, forKey: .progress)
        self.error = try c.decodeIfPresent(String.self, forKey: .error)
    }

    public var isRunning: Bool {
        state == "running"
    }
}

public struct AgentConfigDirInfo: Codable, Sendable, Equatable {
    public let runs: String
    public let active: String?
    public let created: Bool
}

public struct AgentSartoServerInfo: Codable, Sendable, Equatable {
    public let runs: Bool
    public let active: Bool?
}

public struct AgentVersionWarningInfo: Codable, Sendable, Equatable {
    public let version: String
    public let broken: Bool
    public let supported: String?
    public let recommended: String?
}

public struct EnvironmentStatusInfo: Codable, Sendable, Equatable {
    public let source: String
    public let shell: String?
    public let resolvedAt: Double?
    public let durationMs: Double?
    public let warning: String?
    public let nodeVersion: String?
    public let npmPath: String?
}

public struct LightAgentInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { agentId }
    public let agentId: String
    public let name: String
}

public struct ClaudeCompactRowInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { model }
    public let model: String
    public let name: String?
    public let window: Int?
}

public struct ClaudeSettingsInfo: Codable, Sendable, Equatable {
    public let defaultWindow: Int?
    public let compact: [ClaudeCompactRowInfo]
    public let promptCacheTtl: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.defaultWindow = try c.decodeIfPresent(Int.self, forKey: .defaultWindow)
        self.compact = try c.decodeIfPresent([ClaudeCompactRowInfo].self, forKey: .compact) ?? []
        self.promptCacheTtl = try c.decodeIfPresent(String.self, forKey: .promptCacheTtl)
    }
}

public struct AutoCompactRowInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { model }
    public let model: String
    public let name: String?
    public let value: Int?
    public let other: String?
}

public struct AutoCompactSettingsInfo: Codable, Sendable, Equatable {
    public let unit: String
    public let min: Int
    public let max: Int
    public let all: Int?
    public let allOther: String?
    public let models: [AutoCompactRowInfo]?
    public let file: String?
}

// MARK: - Memory Management Models (src/shared/memory.ts)

public struct MemoryEntryInfo: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let description: String
    public let body: String
    public let createdAt: Double
    public let updatedAt: Double

    public init(
        id: String,
        title: String,
        description: String,
        body: String,
        createdAt: Double = 0,
        updatedAt: Double = 0
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
        self.description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        self.createdAt = try c.decodeIfPresent(Double.self, forKey: .createdAt) ?? 0
        self.updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0
    }
}

public struct MemoryProjectInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { project }
    public let project: String
    public let name: String
    public let count: Int
    public let entries: [MemoryEntryInfo]?

    enum CodingKeys: String, CodingKey {
        case path, project, name, count, entries
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let wirePath = try c.decodeIfPresent(String.self, forKey: .path)
        let legacyProject = try c.decodeIfPresent(String.self, forKey: .project)
        let projectPath = wirePath ?? legacyProject ?? ""
        self.project = projectPath
        self.name = try c.decodeIfPresent(String.self, forKey: .name)
            ?? (projectPath.isEmpty ? "Project" : URL(fileURLWithPath: projectPath).lastPathComponent)
        self.entries = try c.decodeIfPresent([MemoryEntryInfo].self, forKey: .entries)
        self.count = try c.decodeIfPresent(Int.self, forKey: .count) ?? (entries?.count ?? 0)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(project, forKey: .path)
        try c.encode(name, forKey: .name)
        try c.encode(count, forKey: .count)
        try c.encodeIfPresent(entries, forKey: .entries)
    }
}

public struct MemoryOverviewInfo: Codable, Sendable, Equatable {
    public let enabled: Bool
    public let global: [MemoryEntryInfo]
    public let projects: [MemoryProjectInfo]
    public let importable: Int

    public init(
        enabled: Bool = true,
        global: [MemoryEntryInfo] = [],
        projects: [MemoryProjectInfo] = [],
        importable: Int = 0
    ) {
        self.enabled = enabled
        self.global = global
        self.projects = projects
        self.importable = importable
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.global = try c.decodeIfPresent([MemoryEntryInfo].self, forKey: .global) ?? []
        self.projects = try c.decodeIfPresent([MemoryProjectInfo].self, forKey: .projects) ?? []
        self.importable = try c.decodeIfPresent(Int.self, forKey: .importable) ?? 0
    }
}

public struct MemoryImportEntryInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { key }
    public let key: String
    public let title: String
    public let description: String
    public let aboutUser: Bool
}

public struct MemoryImportSourceInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(agentId)::\(project)" }
    public let agentId: String
    public let agentName: String
    public let project: String
    public let projectName: String?
    public let entries: [MemoryImportEntryInfo]
}

public struct MemoryImportScanInfo: Codable, Sendable, Equatable {
    public let sources: [MemoryImportSourceInfo]
}

public struct MemoryImportResultInfo: Codable, Sendable, Equatable {
    public let imported: Int
    public let skipped: Int
    public let global: Int
}

// MARK: - Sarto E2EE Multi-Device Workspace Sync (src/shared/sync/protocol.ts)

public struct SartoSyncAccountInfo: Codable, Sendable, Equatable {
    public let id: String
    public let email: String
    public let name: String?

    public init(id: String, email: String, name: String? = nil) {
        self.id = id
        self.email = email
        self.name = name
    }
}

public struct SartoTrustedHostInfo: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let platform: String
    /// Standard Base64-encoded 32-byte X25519 static public key of the host.
    public let publicKey: String
    public let relayId: String?
    public let relayUrl: String?

    public init(
        id: String,
        name: String,
        platform: String,
        publicKey: String,
        relayId: String? = nil,
        relayUrl: String? = nil
    ) {
        self.id = id
        self.name = name
        self.platform = platform
        self.publicKey = publicKey
        self.relayId = relayId
        self.relayUrl = relayUrl
    }
}

public struct SartoTrustedDeviceInput: Codable, Sendable, Equatable {
    /// 32 lowercase hex digits: SHA-256(publicKeyBytes)[0..<16].
    public let id: String
    /// Standard Base64-encoded 32-byte X25519 static public key.
    public let publicKey: String
    public let name: String
    public let kind: String
    public let platform: String
    public let model: String?

    public init(
        id: String,
        publicKey: String,
        name: String,
        kind: String,
        platform: String,
        model: String? = nil
    ) {
        self.id = id
        self.publicKey = publicKey
        self.name = name
        self.kind = kind
        self.platform = platform
        self.model = model
    }

    public func toJSONValue() -> JSONValue {
        var obj: [String: JSONValue] = [
            "id": .string(id),
            "publicKey": .string(publicKey),
            "name": .string(name),
            "kind": .string(kind),
            "platform": .string(platform),
        ]
        if let model, !model.isEmpty {
            obj["model"] = .string(model)
        }
        return .object(obj)
    }
}

public struct CloudAccountProfileInfo: Codable, Sendable, Equatable {
    public let id: String
    public let email: String
    public let name: String?
    public let avatar: String?

    public init(id: String, email: String, name: String? = nil, avatar: String? = nil) {
        self.id = id
        self.email = email
        self.name = name
        self.avatar = avatar
    }
}

public struct CloudAccountPlanInfo: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let maxDevices: Int
    public let storageBytes: Double

    public init(id: String, name: String, maxDevices: Int, storageBytes: Double) {
        self.id = id
        self.name = name
        self.maxDevices = maxDevices
        self.storageBytes = storageBytes
    }
}

public struct CloudAccountUsageInfo: Codable, Sendable, Equatable {
    public let devices: Int
    public let storageBytes: Double

    public init(devices: Int, storageBytes: Double) {
        self.devices = devices
        self.storageBytes = storageBytes
    }
}

public struct CloudAccountStateInfo: Codable, Sendable, Equatable {
    /// "signed-out" | "signing-in" | "signed-in"
    public let state: String
    public let reason: String?
    public let failure: String?
    public let devicesUrl: String?
    public let account: CloudAccountProfileInfo?
    public let subscription: String?
    public let plan: CloudAccountPlanInfo?
    public let usage: CloudAccountUsageInfo?
    public let points: Double?
    public let manageUrl: String?
    public let pointsUrl: String?
    public let plainText: Bool

    public var isSignedIn: Bool { state == "signed-in" }
    public var isSigningIn: Bool { state == "signing-in" }
    public var isSignedOut: Bool { state == "signed-out" }

    public init(
        state: String = "signed-out",
        reason: String? = nil,
        failure: String? = nil,
        devicesUrl: String? = nil,
        account: CloudAccountProfileInfo? = nil,
        subscription: String? = nil,
        plan: CloudAccountPlanInfo? = nil,
        usage: CloudAccountUsageInfo? = nil,
        points: Double? = nil,
        manageUrl: String? = nil,
        pointsUrl: String? = nil,
        plainText: Bool = false
    ) {
        self.state = state
        self.reason = reason
        self.failure = failure
        self.devicesUrl = devicesUrl
        self.account = account
        self.subscription = subscription
        self.plan = plan
        self.usage = usage
        self.points = points
        self.manageUrl = manageUrl
        self.pointsUrl = pointsUrl
        self.plainText = plainText
    }

    enum CodingKeys: String, CodingKey {
        case state, reason, failure, devicesUrl, account, subscription, plan, usage, points
        case manageUrl, pointsUrl, plainText
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.state = (try? c.decode(String.self, forKey: .state)) ?? "signed-out"
        self.reason = try? c.decodeIfPresent(String.self, forKey: .reason)
        self.failure = try? c.decodeIfPresent(String.self, forKey: .failure)
        self.devicesUrl = try? c.decodeIfPresent(String.self, forKey: .devicesUrl)
        self.account = try? c.decodeIfPresent(CloudAccountProfileInfo.self, forKey: .account)
        self.subscription = try? c.decodeIfPresent(String.self, forKey: .subscription)
        self.plan = try? c.decodeIfPresent(CloudAccountPlanInfo.self, forKey: .plan)
        self.usage = try? c.decodeIfPresent(CloudAccountUsageInfo.self, forKey: .usage)
        self.points = try? c.decodeIfPresent(Double.self, forKey: .points)
        self.manageUrl = try? c.decodeIfPresent(String.self, forKey: .manageUrl)
        self.pointsUrl = try? c.decodeIfPresent(String.self, forKey: .pointsUrl)
        self.plainText = (try? c.decode(Bool.self, forKey: .plainText)) ?? false
    }
}

public struct CloudAccountStatusInfo: Codable, Sendable, Equatable {
    public let origin: String
    public let fixedOrigin: Bool
    public let account: CloudAccountStateInfo
    public let authUrl: String?

    public init(
        origin: String = SartoSyncStatusInfo.defaultCloudURL,
        fixedOrigin: Bool = false,
        account: CloudAccountStateInfo = CloudAccountStateInfo(),
        authUrl: String? = nil
    ) {
        self.origin = origin
        self.fixedOrigin = fixedOrigin
        self.account = account
        self.authUrl = authUrl
    }

    enum CodingKeys: String, CodingKey {
        case origin, fixedOrigin, account, authUrl
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.origin = (try? c.decode(String.self, forKey: .origin)) ?? SartoSyncStatusInfo.defaultCloudURL
        self.fixedOrigin = (try? c.decode(Bool.self, forKey: .fixedOrigin)) ?? false
        self.account = (try? c.decode(CloudAccountStateInfo.self, forKey: .account)) ?? CloudAccountStateInfo()
        self.authUrl = try? c.decodeIfPresent(String.self, forKey: .authUrl)
    }
}

public struct CloudDeviceInfo: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: String
    public let name: String
    public let os: String
    public let arch: String
    public let version: String?
    public let user: String?
    public let createdAt: Double
    public let lastUsedAt: Double
    public let current: Bool

    public init(
        id: String,
        kind: String = "desktop",
        name: String,
        os: String = "",
        arch: String = "",
        version: String? = nil,
        user: String? = nil,
        createdAt: Double = 0,
        lastUsedAt: Double = 0,
        current: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.os = os
        self.arch = arch
        self.version = version
        self.user = user
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.current = current
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, name, os, arch, version, user, createdAt, lastUsedAt, current
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(String.self, forKey: .id)) ?? ""
        self.kind = (try? c.decode(String.self, forKey: .kind)) ?? "desktop"
        self.name = (try? c.decode(String.self, forKey: .name)) ?? "Device"
        self.os = (try? c.decode(String.self, forKey: .os)) ?? ""
        self.arch = (try? c.decode(String.self, forKey: .arch)) ?? ""
        self.version = try? c.decodeIfPresent(String.self, forKey: .version)
        self.user = try? c.decodeIfPresent(String.self, forKey: .user)
        self.createdAt = (try? c.decode(Double.self, forKey: .createdAt)) ?? 0
        self.lastUsedAt = (try? c.decode(Double.self, forKey: .lastUsedAt)) ?? 0
        self.current = (try? c.decode(Bool.self, forKey: .current)) ?? false
    }
}

public struct CloudAccountPreferencesInfo: Codable, Sendable, Equatable {
    public let appTheme: String?
    public let appThemeUpdatedAt: Double?

    public init(
        appTheme: String? = nil,
        appThemeUpdatedAt: Double? = nil
    ) {
        self.appTheme = appTheme
        self.appThemeUpdatedAt = appThemeUpdatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.appTheme = try? c.decodeIfPresent(String.self, forKey: .appTheme)
        self.appThemeUpdatedAt = try? c.decodeIfPresent(Double.self, forKey: .appThemeUpdatedAt)
    }
}

public struct CloudRelayTokenInfo: Codable, Sendable, Equatable {
    public let token: String
    public let expiresAt: Double

    public init(token: String, expiresAt: Double) {
        self.token = token
        self.expiresAt = expiresAt
    }
}

public struct SyncPendingApprovalInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { deviceId }
    public let deviceId: String
    public let devicePublicKey: String
    public let deviceName: String
    public let platform: String
    public let code: String
    public let createdAt: Double
    public let expiresAt: Double

    public init(
        deviceId: String,
        devicePublicKey: String,
        deviceName: String,
        platform: String,
        code: String,
        createdAt: Double = 0,
        expiresAt: Double = 0
    ) {
        self.deviceId = deviceId
        self.devicePublicKey = devicePublicKey
        self.deviceName = deviceName
        self.platform = platform
        self.code = code
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

public struct SyncedUsageDeviceSummaryInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { deviceId }
    public let deviceId: String
    public let deviceName: String
    public let updatedAt: Double
    public let rev: Int
    public let hasIsland: Bool
    public let hasHost: Bool

    public init(
        deviceId: String,
        deviceName: String,
        updatedAt: Double,
        rev: Int = 0,
        hasIsland: Bool = false,
        hasHost: Bool = false
    ) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.updatedAt = updatedAt
        self.rev = rev
        self.hasIsland = hasIsland
        self.hasHost = hasHost
    }

    enum CodingKeys: String, CodingKey {
        case deviceId, deviceName, updatedAt, rev, hasIsland, hasHost
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.deviceId = (try? c.decode(String.self, forKey: .deviceId)) ?? ""
        self.deviceName = (try? c.decode(String.self, forKey: .deviceName)) ?? "Mac"
        self.updatedAt = (try? c.decode(Double.self, forKey: .updatedAt)) ?? 0
        if let d = try? c.decode(Double.self, forKey: .rev) {
            self.rev = Int.wholePart(of: d) ?? 0
        } else {
            self.rev = (try? c.decode(Int.self, forKey: .rev)) ?? 0
        }
        self.hasIsland = (try? c.decode(Bool.self, forKey: .hasIsland)) ?? false
        self.hasHost = (try? c.decode(Bool.self, forKey: .hasHost)) ?? false
    }
}

public struct SyncedIslandUsageSectionInfo: Codable, Sendable, Equatable {
    public let updatedAt: Double
    public let payload: JSONValue

    public init(updatedAt: Double, payload: JSONValue) {
        self.updatedAt = updatedAt
        self.payload = payload
    }
}

public struct SyncedUsageRecordInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { deviceId }
    public let v: Int
    public let deviceId: String
    public let deviceName: String
    public let updatedAt: Double
    public let island: SyncedIslandUsageSectionInfo?

    public init(
        v: Int = 1,
        deviceId: String,
        deviceName: String,
        updatedAt: Double,
        island: SyncedIslandUsageSectionInfo? = nil
    ) {
        self.v = v
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.updatedAt = updatedAt
        self.island = island
    }

    enum CodingKeys: String, CodingKey {
        case v, deviceId, deviceName, updatedAt, island
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.v = (try? c.decode(Int.self, forKey: .v)) ?? 1
        self.deviceId = (try? c.decode(String.self, forKey: .deviceId)) ?? ""
        self.deviceName = (try? c.decode(String.self, forKey: .deviceName)) ?? "Mac"
        self.updatedAt = (try? c.decode(Double.self, forKey: .updatedAt)) ?? 0
        self.island = try? c.decodeIfPresent(SyncedIslandUsageSectionInfo.self, forKey: .island)
    }
}

public struct SyncUsageSnapshotResult: Codable, Sendable, Equatable {
    public let ownDeviceId: String
    public let records: [SyncedUsageRecordInfo]

    public init(ownDeviceId: String = "", records: [SyncedUsageRecordInfo] = []) {
        self.ownDeviceId = ownDeviceId
        self.records = records
    }
}

public struct SyncVaultSetupResult: Codable, Sendable, Equatable {
    public let status: SartoSyncStatusInfo
    /// The one-time recovery key; nil when another Mac already set up the account's sync and this
    /// Mac now waits for its approval instead.
    public let recoveryKey: String?

    public init(status: SartoSyncStatusInfo, recoveryKey: String?) {
        self.status = status
        self.recoveryKey = recoveryKey
    }
}

public struct SartoSyncedUiPrefEntry: Codable, Sendable, Equatable {
    public let value: JSONValue
    public let updatedAt: Double
    public let by: String?

    public init(value: JSONValue, updatedAt: Double, by: String? = nil) {
        self.value = value
        self.updatedAt = updatedAt
        self.by = by
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.value = (try? c.decode(JSONValue.self, forKey: .value)) ?? .null
        self.updatedAt = (try? c.decode(Double.self, forKey: .updatedAt)) ?? 0
        self.by = try? c.decodeIfPresent(String.self, forKey: .by)
    }
}

public struct SartoSyncStatusInfo: Codable, Sendable, Equatable {
    public static let defaultCloudURL = "https://sarto.1o.ink"

    /// "off" | "account"
    public let mode: String
    public let serverUrl: String
    public let connected: Bool
    public let syncing: Bool
    public let lastSyncedAt: Double?
    public let error: String?
    public let account: SartoSyncAccountInfo?
    public let relayId: String?
    public let relayToken: String?
    public let needsKey: Bool
    /// "none" | "ready" | "needs-setup" | "awaiting-approval"
    public let keyState: String
    public let plainText: Bool
    public let syncDeviceId: String?
    public let approvalCode: String?
    /// While awaiting approval: "waiting" for a Mac to answer, "confirm" that the codes match,
    /// "confirmed" and waiting for that Mac to approve.
    public let approvalStage: String?
    /// The name the answering Mac gave, while awaiting approval.
    public let approverName: String?
    public let pendingApprovals: [SyncPendingApprovalInfo]
    public let usageDeviceId: String?
    public let usageDevices: [SyncedUsageDeviceSummaryInfo]
    public let hostPublicKey: String?
    public let revisions: [String: Int]
    public let uiPrefs: [String: SartoSyncedUiPrefEntry]
    public let trustedHosts: [SartoTrustedHostInfo]

    public var isVaultReady: Bool {
        if mode == "account" {
            return keyState == "ready"
        }
        return mode != "off" && !needsKey
    }

    public init(
        mode: String = "off",
        serverUrl: String = "",
        connected: Bool = false,
        syncing: Bool = false,
        lastSyncedAt: Double? = nil,
        error: String? = nil,
        account: SartoSyncAccountInfo? = nil,
        relayId: String? = nil,
        relayToken: String? = nil,
        needsKey: Bool = false,
        keyState: String = "none",
        plainText: Bool = false,
        syncDeviceId: String? = nil,
        approvalCode: String? = nil,
        approvalStage: String? = nil,
        approverName: String? = nil,
        pendingApprovals: [SyncPendingApprovalInfo] = [],
        usageDeviceId: String? = nil,
        usageDevices: [SyncedUsageDeviceSummaryInfo] = [],
        hostPublicKey: String? = nil,
        revisions: [String: Int] = [:],
        uiPrefs: [String: SartoSyncedUiPrefEntry] = [:],
        trustedHosts: [SartoTrustedHostInfo] = []
    ) {
        self.mode = mode
        self.serverUrl = serverUrl
        self.connected = connected
        self.syncing = syncing
        self.lastSyncedAt = lastSyncedAt
        self.error = error
        self.account = account
        self.relayId = relayId
        self.relayToken = relayToken
        self.needsKey = needsKey
        self.keyState = keyState
        self.plainText = plainText
        self.syncDeviceId = syncDeviceId
        self.approvalCode = approvalCode
        self.approvalStage = approvalStage
        self.approverName = approverName
        self.pendingApprovals = pendingApprovals
        self.usageDeviceId = usageDeviceId
        self.usageDevices = usageDevices
        self.hostPublicKey = hostPublicKey
        self.revisions = revisions
        self.uiPrefs = uiPrefs
        self.trustedHosts = trustedHosts
    }

    enum CodingKeys: String, CodingKey {
        case mode, serverUrl, connected, syncing, lastSyncedAt, error, account
        case relayId, relayToken, needsKey, keyState, plainText, syncDeviceId
        case approvalCode, approvalStage, approverName, pendingApprovals
        case usageDeviceId, usageDevices
        case hostPublicKey, revisions, uiPrefs, trustedHosts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.mode = (try? c.decode(String.self, forKey: .mode)) ?? "off"
        self.serverUrl = (try? c.decode(String.self, forKey: .serverUrl)) ?? ""
        self.connected = (try? c.decode(Bool.self, forKey: .connected)) ?? false
        self.syncing = (try? c.decode(Bool.self, forKey: .syncing)) ?? false
        self.lastSyncedAt = try? c.decodeIfPresent(Double.self, forKey: .lastSyncedAt)
        self.error = try? c.decodeIfPresent(String.self, forKey: .error)
        self.account = try? c.decodeIfPresent(SartoSyncAccountInfo.self, forKey: .account)
        self.relayId = try? c.decodeIfPresent(String.self, forKey: .relayId)
        self.relayToken = try? c.decodeIfPresent(String.self, forKey: .relayToken)
        self.needsKey = (try? c.decode(Bool.self, forKey: .needsKey)) ?? false
        self.keyState = (try? c.decode(String.self, forKey: .keyState)) ?? "none"
        self.plainText = (try? c.decode(Bool.self, forKey: .plainText)) ?? false
        self.syncDeviceId = try? c.decodeIfPresent(String.self, forKey: .syncDeviceId)
        self.approvalCode = try? c.decodeIfPresent(String.self, forKey: .approvalCode)
        self.approvalStage = try? c.decodeIfPresent(String.self, forKey: .approvalStage)
        self.approverName = try? c.decodeIfPresent(String.self, forKey: .approverName)
        self.pendingApprovals = (try? c.decode([SyncPendingApprovalInfo].self, forKey: .pendingApprovals)) ?? []
        self.usageDeviceId = try? c.decodeIfPresent(String.self, forKey: .usageDeviceId)
        self.usageDevices = (try? c.decode([SyncedUsageDeviceSummaryInfo].self, forKey: .usageDevices)) ?? []
        self.hostPublicKey = try? c.decodeIfPresent(String.self, forKey: .hostPublicKey)
        if let rawRevs = try? c.decode([String: Double].self, forKey: .revisions) {
            var parsedRevs: [String: Int] = [:]
            for (k, v) in rawRevs {
                if let whole = Int.wholePart(of: v) {
                    parsedRevs[k] = whole
                }
            }
            self.revisions = parsedRevs
        } else {
            self.revisions = (try? c.decode([String: Int].self, forKey: .revisions)) ?? [:]
        }
        self.uiPrefs = (try? c.decode([String: SartoSyncedUiPrefEntry].self, forKey: .uiPrefs)) ?? [:]
        self.trustedHosts = (try? c.decode([SartoTrustedHostInfo].self, forKey: .trustedHosts)) ?? []
    }
}
