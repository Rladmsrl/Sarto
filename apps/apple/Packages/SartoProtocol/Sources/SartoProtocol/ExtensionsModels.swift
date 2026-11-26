import Foundation

// MARK: - Global Full-Text Search Models (src/shared/agent-host.ts)

public struct ConversationHitInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(sessionId)::\(entryId)" }
    public let sessionId: String
    public let pos: Int
    public let entryId: String
    public let role: String
    public let snippet: String
    public let matches: Int?

    public init(
        sessionId: String,
        pos: Int,
        entryId: String,
        role: String,
        snippet: String,
        matches: Int? = nil
    ) {
        self.sessionId = sessionId
        self.pos = pos
        self.entryId = entryId
        self.role = role
        self.snippet = snippet
        self.matches = matches
    }
}

public struct SearchIndexingInfo: Codable, Sendable, Equatable {
    public let done: Int
    public let total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }
}

public struct SessionSearchResultInfo: Codable, Sendable, Equatable {
    public let hits: [ConversationHitInfo]
    public let indexing: SearchIndexingInfo?

    public init(hits: [ConversationHitInfo] = [], indexing: SearchIndexingInfo? = nil) {
        self.hits = hits
        self.indexing = indexing
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.hits = try c.decodeIfPresent([ConversationHitInfo].self, forKey: .hits) ?? []
        self.indexing = try c.decodeIfPresent(SearchIndexingInfo.self, forKey: .indexing)
    }
}

// MARK: - Context Breakdown & Estimates (src/shared/context.ts)

public struct ContextCategoryInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let tokens: Double
    public let share: Double?

    public init(name: String, tokens: Double, share: Double? = nil) {
        self.name = name
        self.tokens = tokens
        self.share = share
    }
}

public struct ContextListItemInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(name)::\(detail ?? "")::\(tokens)" }
    public let name: String
    public let detail: String?
    public let tokens: String
}

public struct ContextListInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let items: [ContextListItemInfo]
}

public struct ContextBreakdownInfo: Codable, Sendable, Equatable {
    public let model: String?
    public let used: Double
    public let size: Double
    public let categories: [ContextCategoryInfo]
    public let lists: [ContextListInfo]
    public let observedAt: Double

    public init(
        model: String? = nil,
        used: Double,
        size: Double,
        categories: [ContextCategoryInfo] = [],
        lists: [ContextListInfo] = [],
        observedAt: Double = 0
    ) {
        self.model = model
        self.used = used
        self.size = size
        self.categories = categories
        self.lists = lists
        self.observedAt = observedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.model = try c.decodeIfPresent(String.self, forKey: .model)
        self.used = try c.decodeIfPresent(Double.self, forKey: .used) ?? 0
        self.size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 0
        self.categories = try c.decodeIfPresent([ContextCategoryInfo].self, forKey: .categories) ?? []
        self.lists = try c.decodeIfPresent([ContextListInfo].self, forKey: .lists) ?? []
        self.observedAt = try c.decodeIfPresent(Double.self, forKey: .observedAt) ?? 0
    }
}

public struct ContextDefinitionEstimateInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let tokens: Double?
}

public struct ContextEstimatesInfo: Codable, Sendable, Equatable {
    public let skills: [ContextDefinitionEstimateInfo]?
    public let mcpServers: [ContextDefinitionEstimateInfo]?
}

// MARK: - External CLI Session Import Models (src/shared/agent-host.ts)

public struct ImportableSessionInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { acpSessionId }
    public let acpSessionId: String
    public let title: String?
    public let updatedAt: String?
    public let imported: Bool
    public let held: Bool?

    public init(
        acpSessionId: String,
        title: String? = nil,
        updatedAt: String? = nil,
        imported: Bool = false,
        held: Bool? = nil
    ) {
        self.acpSessionId = acpSessionId
        self.title = title
        self.updatedAt = updatedAt
        self.imported = imported
        self.held = held
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.acpSessionId = try c.decode(String.self, forKey: .acpSessionId)
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
        self.updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        self.imported = try c.decodeIfPresent(Bool.self, forKey: .imported) ?? false
        self.held = try c.decodeIfPresent(Bool.self, forKey: .held)
    }
}

public struct ImportableSessionsPageInfo: Codable, Sendable, Equatable {
    public let sessions: [ImportableSessionInfo]
    public let nextCursor: String?

    public init(sessions: [ImportableSessionInfo] = [], nextCursor: String? = nil) {
        self.sessions = sessions
        self.nextCursor = nextCursor
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sessions = try c.decodeIfPresent([ImportableSessionInfo].self, forKey: .sessions) ?? []
        self.nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
    }
}

// MARK: - MCP Status, Hub & OAuth Proxy Models (src/shared/marketplace.ts & agent-host.ts)

public struct McpToolSummaryInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let description: String
    public let group: String
    public let asks: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.group = try c.decodeIfPresent(String.self, forKey: .group) ?? "sessions"
        self.asks = try c.decodeIfPresent(Bool.self, forKey: .asks) ?? false
    }
}

public struct McpBuiltinServerInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let title: String
    public let builtIn: Bool
    public let running: Bool
    public let error: String?
    public let tools: [McpToolSummaryInfo]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? name
        self.builtIn = try c.decodeIfPresent(Bool.self, forKey: .builtIn) ?? true
        self.running = try c.decodeIfPresent(Bool.self, forKey: .running) ?? false
        self.error = try c.decodeIfPresent(String.self, forKey: .error)
        self.tools = try c.decodeIfPresent([McpToolSummaryInfo].self, forKey: .tools) ?? []
    }
}

public struct McpAgentPlaceInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { agentId }
    public let agentId: String
    public let path: String
    public let exists: Bool
    public let env: String?
    public let chosen: Bool
    public let project: String
    public let listCommand: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.agentId = try c.decode(String.self, forKey: .agentId)
        self.path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        self.exists = try c.decodeIfPresent(Bool.self, forKey: .exists) ?? false
        self.env = try c.decodeIfPresent(String.self, forKey: .env)
        self.chosen = try c.decodeIfPresent(Bool.self, forKey: .chosen) ?? false
        self.project = try c.decodeIfPresent(String.self, forKey: .project) ?? ""
        self.listCommand = try c.decodeIfPresent(String.self, forKey: .listCommand)
    }
}

public struct McpStatusInfo: Codable, Sendable, Equatable {
    public let servers: [McpBuiltinServerInfo]
    public let places: [McpAgentPlaceInfo]

    public init(servers: [McpBuiltinServerInfo] = [], places: [McpAgentPlaceInfo] = []) {
        self.servers = servers
        self.places = places
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.servers = try c.decodeIfPresent([McpBuiltinServerInfo].self, forKey: .servers) ?? []
        self.places = try c.decodeIfPresent([McpAgentPlaceInfo].self, forKey: .places) ?? []
    }
}

public struct McpOAuthInfo: Codable, Sendable, Equatable {
    public let flow: String

    public init(flow: String) {
        self.flow = flow
    }

    public func toJSONValue() -> JSONValue {
        .object(["flow": .string(flow)])
    }
}

public struct McpValueSpec: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let value: String?
    public let isInput: Bool
    public let secret: Bool
    public let required: Bool
    public let description: String?
    public let prefix: String?
    public let title: String?
    public let kind: String?
    public let defaultValue: String?

    enum CodingKeys: String, CodingKey {
        case name, value, secret, required, description, prefix, title, kind
        case isInput = "input"
        case defaultValue = "default"
    }

    public init(
        name: String,
        value: String? = nil,
        isInput: Bool = false,
        secret: Bool = false,
        required: Bool = false,
        description: String? = nil,
        prefix: String? = nil,
        title: String? = nil,
        kind: String? = nil,
        defaultValue: String? = nil
    ) {
        self.name = name
        self.value = value
        self.isInput = isInput
        self.secret = secret
        self.required = required
        self.description = description
        self.prefix = prefix
        self.title = title
        self.kind = kind
        self.defaultValue = defaultValue
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.value = try c.decodeIfPresent(String.self, forKey: .value)
        self.isInput = try c.decodeIfPresent(Bool.self, forKey: .isInput) ?? false
        self.secret = try c.decodeIfPresent(Bool.self, forKey: .secret) ?? false
        self.required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? false
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.prefix = try c.decodeIfPresent(String.self, forKey: .prefix)
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
        self.kind = try c.decodeIfPresent(String.self, forKey: .kind)
        self.defaultValue = try c.decodeIfPresent(String.self, forKey: .defaultValue)
    }

    public func toJSONValue() -> JSONValue {
        if isInput {
            var obj: [String: JSONValue] = [
                "name": .string(name),
                "input": .bool(true),
                "secret": .bool(secret),
                "required": .bool(required),
            ]
            if let description { obj["description"] = .string(description) }
            if let prefix { obj["prefix"] = .string(prefix) }
            if let title { obj["title"] = .string(title) }
            if let kind { obj["kind"] = .string(kind) }
            if let defaultValue { obj["default"] = .string(defaultValue) }
            return .object(obj)
        }
        return .object([
            "name": .string(name),
            "value": .string(value ?? ""),
        ])
    }
}

public struct McpSpecInfo: Codable, Sendable, Equatable {
    public let type: String
    public let transport: String?
    public let url: String?
    public let headers: [McpValueSpec]
    public let oauth: McpOAuthInfo?
    public let command: String?
    public let args: [String]
    public let env: [McpValueSpec]
    public let runtime: String?

    public init(
        type: String,
        transport: String? = nil,
        url: String? = nil,
        headers: [McpValueSpec] = [],
        oauth: McpOAuthInfo? = nil,
        command: String? = nil,
        args: [String] = [],
        env: [McpValueSpec] = [],
        runtime: String? = nil
    ) {
        self.type = type
        self.transport = transport
        self.url = url
        self.headers = headers
        self.oauth = oauth
        self.command = command
        self.args = args
        self.env = env
        self.runtime = runtime
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try c.decodeIfPresent(String.self, forKey: .type) ?? "http"
        self.transport = try c.decodeIfPresent(String.self, forKey: .transport)
        self.url = try c.decodeIfPresent(String.self, forKey: .url)
        self.headers = try c.decodeIfPresent([McpValueSpec].self, forKey: .headers) ?? []
        self.oauth = try c.decodeIfPresent(McpOAuthInfo.self, forKey: .oauth)
        self.command = try c.decodeIfPresent(String.self, forKey: .command)
        self.args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        self.env = try c.decodeIfPresent([McpValueSpec].self, forKey: .env) ?? []
        self.runtime = try c.decodeIfPresent(String.self, forKey: .runtime)
    }

    public var inputs: [McpValueSpec] {
        (type == "http" ? headers : env).filter(\.isInput)
    }

    public var summaryText: String {
        if type == "http" {
            return url ?? ""
        }
        return ([command ?? ""] + args).filter { !$0.isEmpty }.joined(separator: " ")
    }

    public func toJSONValue() -> JSONValue {
        if type == "http" {
            var obj: [String: JSONValue] = [
                "type": .string("http"),
                "transport": .string(transport ?? "streamable-http"),
                "url": .string(url ?? ""),
                "headers": .array(headers.map { $0.toJSONValue() }),
            ]
            if let oauth { obj["oauth"] = oauth.toJSONValue() }
            return .object(obj)
        }
        var obj: [String: JSONValue] = [
            "type": .string("stdio"),
            "command": .string(command ?? ""),
            "args": .array(args.map(JSONValue.string)),
            "env": .array(env.map { $0.toJSONValue() }),
        ]
        if let runtime { obj["runtime"] = .string(runtime) }
        return .object(obj)
    }
}

public struct MarketServerInfo: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var title: String
    public let source: String
    public let version: String?
    public var spec: McpSpecInfo
    public var agentsAll: Bool
    public var agentIds: [String]
    public var on: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, title, source, version, spec, agents, on
    }

    public init(
        id: String,
        name: String,
        title: String,
        source: String,
        version: String? = nil,
        spec: McpSpecInfo,
        agentsAll: Bool = true,
        agentIds: [String] = [],
        on: Bool = true
    ) {
        self.id = id
        self.name = name
        self.title = title
        self.source = source
        self.version = version
        self.spec = spec
        self.agentsAll = agentsAll
        self.agentIds = agentIds
        self.on = on
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? name
        self.source = try c.decodeIfPresent(String.self, forKey: .source) ?? "manual"
        self.version = try c.decodeIfPresent(String.self, forKey: .version)
        self.spec = try c.decode(McpSpecInfo.self, forKey: .spec)
        if let str = try? c.decode(String.self, forKey: .agents), str == "all" {
            self.agentsAll = true
            self.agentIds = []
        } else if let arr = try? c.decode([String].self, forKey: .agents) {
            self.agentsAll = false
            self.agentIds = arr
        } else {
            self.agentsAll = true
            self.agentIds = []
        }
        self.on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(title, forKey: .title)
        try c.encode(source, forKey: .source)
        try c.encode(version, forKey: .version)
        try c.encode(spec, forKey: .spec)
        if agentsAll {
            try c.encode("all", forKey: .agents)
        } else {
            try c.encode(agentIds, forKey: .agents)
        }
        try c.encode(on, forKey: .on)
    }

    public func toJSONValue() -> JSONValue {
        .object([
            "id": .string(id),
            "name": .string(name),
            "title": .string(title),
            "source": .string(source),
            "version": version.map(JSONValue.string) ?? .null,
            "spec": spec.toJSONValue(),
            "agents": agentsAll ? .string("all") : .array(agentIds.map(JSONValue.string)),
            "on": .bool(on),
        ])
    }

    /// Generates a safe unique agent-facing name for a server (matching `serverName` in `src/shared/marketplace.ts`).
    public static func suggestedName(from rawId: String, existing: [MarketServerInfo]) -> String {
        let last = rawId.split(separator: "/").last.map(String.init) ?? rawId
        let lower = last.lowercased()
            .replacingOccurrences(of: #"^mcp[-_]?(server)?[-_]?|[-_]?mcp([-_]?server)?$"#, with: "", options: .regularExpression)
        let cleaned = (lower.isEmpty ? last.lowercased() : lower)
            .replacingOccurrences(of: #"[^a-z0-9_-]+"#, with: "-", options: .regularExpression)
            .replacingOccurrences(of: #"-{2,}"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        let base = String((cleaned.isEmpty ? "server" : cleaned).prefix(40))
        var taken = Set(existing.map(\.name))
        taken.insert("sarto")
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }
}

public struct CatalogServerInfo: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let publisher: String
    public let official: Bool
    public let description: String
    public let version: String
    public let updated: String?
    public let repository: String?
    public let website: String?
    public let brand: String?
    public let spec: McpSpecInfo

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
        self.publisher = try c.decodeIfPresent(String.self, forKey: .publisher) ?? ""
        self.official = try c.decodeIfPresent(Bool.self, forKey: .official) ?? false
        self.description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        self.updated = try c.decodeIfPresent(String.self, forKey: .updated)
        self.repository = try c.decodeIfPresent(String.self, forKey: .repository)
        self.website = try c.decodeIfPresent(String.self, forKey: .website)
        self.brand = try c.decodeIfPresent(String.self, forKey: .brand)
        self.spec = try c.decode(McpSpecInfo.self, forKey: .spec)
    }
}

public struct CatalogSectionInfo: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let items: [CatalogServerInfo]
}

public struct MarketCatalogInfo: Codable, Sendable, Equatable {
    public let sections: [CatalogSectionInfo]
    public let fetchedAt: Double?
    public let error: String?
    public let stale: Bool?

    public init(
        sections: [CatalogSectionInfo] = [],
        fetchedAt: Double? = nil,
        error: String? = nil,
        stale: Bool? = nil
    ) {
        self.sections = sections
        self.fetchedAt = fetchedAt
        self.error = error
        self.stale = stale
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sections = try c.decodeIfPresent([CatalogSectionInfo].self, forKey: .sections) ?? []
        self.fetchedAt = try c.decodeIfPresent(Double.self, forKey: .fetchedAt)
        self.error = try c.decodeIfPresent(String.self, forKey: .error)
        self.stale = try c.decodeIfPresent(Bool.self, forKey: .stale)
    }
}

public struct MarketSearchInfo: Codable, Sendable, Equatable {
    public let query: String
    public let items: [CatalogServerInfo]
    public let error: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.query = try c.decodeIfPresent(String.self, forKey: .query) ?? ""
        self.items = try c.decodeIfPresent([CatalogServerInfo].self, forKey: .items) ?? []
        self.error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

public struct MarketConnectionInfo: Codable, Sendable, Equatable {
    public let state: String
    public let account: String?
    public let reason: String?
    public let message: String?

    public init(
        state: String = "disconnected",
        account: String? = nil,
        reason: String? = nil,
        message: String? = nil
    ) {
        self.state = state
        self.account = account
        self.reason = reason
        self.message = message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.state = try c.decodeIfPresent(String.self, forKey: .state) ?? "disconnected"
        self.account = try c.decodeIfPresent(String.self, forKey: .account)
        self.reason = try c.decodeIfPresent(String.self, forKey: .reason)
        self.message = try c.decodeIfPresent(String.self, forKey: .message)
    }
}

public struct ConnectStartInfo: Codable, Sendable, Equatable {
    public let loginId: String
    public let kind: String
    public let url: String?
    public let userCode: String?
    public let verificationUri: String?
    public let expiresAt: Double?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.loginId = try c.decodeIfPresent(String.self, forKey: .loginId) ?? ""
        self.kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "open"
        self.url = try c.decodeIfPresent(String.self, forKey: .url)
        self.userCode = try c.decodeIfPresent(String.self, forKey: .userCode)
        self.verificationUri = try c.decodeIfPresent(String.self, forKey: .verificationUri)
        self.expiresAt = try c.decodeIfPresent(Double.self, forKey: .expiresAt)
    }
}

// MARK: - Agent Plugins Models (Claude Code & Codex, src/shared/marketplace.ts)

public struct CatalogPluginInfo: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let harness: String
    public let name: String
    public let title: String
    public let description: String
    public let publisher: String?
    public let official: Bool
    public let marketplace: String
    public let category: String?
    public let homepage: String?
    public let installs: Int?
    public let version: String?
    public let featured: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.harness = try c.decodeIfPresent(String.self, forKey: .harness) ?? "claude-code"
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? name
        self.description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.publisher = try c.decodeIfPresent(String.self, forKey: .publisher)
        self.official = try c.decodeIfPresent(Bool.self, forKey: .official) ?? false
        self.marketplace = try c.decodeIfPresent(String.self, forKey: .marketplace) ?? ""
        self.category = try c.decodeIfPresent(String.self, forKey: .category)
        self.homepage = try c.decodeIfPresent(String.self, forKey: .homepage)
        self.installs = try c.decodeIfPresent(Int.self, forKey: .installs)
        self.version = try c.decodeIfPresent(String.self, forKey: .version)
        self.featured = try c.decodeIfPresent(Bool.self, forKey: .featured) ?? false
    }
}

public struct InstalledPluginInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(agentId)::\(pluginId)::\(scope)::\(projectPath ?? "")" }
    public let pluginId: String
    public let harness: String
    public let agentId: String
    public let version: String?
    public let scope: String
    public let enabled: Bool
    public let projectPath: String?

    enum CodingKeys: String, CodingKey {
        case pluginId = "id"
        case harness, agentId, version, scope, enabled, projectPath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.pluginId = try c.decode(String.self, forKey: .pluginId)
        self.harness = try c.decodeIfPresent(String.self, forKey: .harness) ?? "claude-code"
        self.agentId = try c.decodeIfPresent(String.self, forKey: .agentId) ?? "claude-code"
        self.version = try c.decodeIfPresent(String.self, forKey: .version)
        self.scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? "user"
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.projectPath = try c.decodeIfPresent(String.self, forKey: .projectPath)
    }
}

public struct PluginMarketplaceInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(agentId)::\(name)" }
    public let harness: String
    public let agentId: String
    public let name: String
    public let source: String
    public let official: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.harness = try c.decodeIfPresent(String.self, forKey: .harness) ?? "claude-code"
        self.agentId = try c.decodeIfPresent(String.self, forKey: .agentId) ?? "claude-code"
        self.name = try c.decode(String.self, forKey: .name)
        self.source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        self.official = try c.decodeIfPresent(Bool.self, forKey: .official) ?? false
    }
}

public struct MarketPluginErrorInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(agentId)::\(message)" }
    public let agentId: String
    public let message: String
}

public struct MarketPluginsInfo: Codable, Sendable, Equatable {
    public let catalog: [CatalogPluginInfo]
    public let installed: [InstalledPluginInfo]
    public let marketplaces: [PluginMarketplaceInfo]
    public let errors: [MarketPluginErrorInfo]
    public let stale: Bool?

    public init(
        catalog: [CatalogPluginInfo] = [],
        installed: [InstalledPluginInfo] = [],
        marketplaces: [PluginMarketplaceInfo] = [],
        errors: [MarketPluginErrorInfo] = [],
        stale: Bool? = nil
    ) {
        self.catalog = catalog
        self.installed = installed
        self.marketplaces = marketplaces
        self.errors = errors
        self.stale = stale
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.catalog = try c.decodeIfPresent([CatalogPluginInfo].self, forKey: .catalog) ?? []
        self.installed = try c.decodeIfPresent([InstalledPluginInfo].self, forKey: .installed) ?? []
        self.marketplaces = try c.decodeIfPresent([PluginMarketplaceInfo].self, forKey: .marketplaces) ?? []
        self.errors = try c.decodeIfPresent([MarketPluginErrorInfo].self, forKey: .errors) ?? []
        self.stale = try c.decodeIfPresent(Bool.self, forKey: .stale)
    }
}

public struct PluginDetailsInfo: Codable, Sendable, Equatable {
    public let id: String
    public let agentId: String
    public let description: String?
    public let skills: [String]
    public let commands: [String]
    public let agents: [String]
    public let hooks: [String]
    public let mcpServers: [String]
    public let lspServers: [String]
    public let alwaysOnTokens: Int?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.agentId = try c.decodeIfPresent(String.self, forKey: .agentId) ?? ""
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.skills = try c.decodeIfPresent([String].self, forKey: .skills) ?? []
        self.commands = try c.decodeIfPresent([String].self, forKey: .commands) ?? []
        self.agents = try c.decodeIfPresent([String].self, forKey: .agents) ?? []
        self.hooks = try c.decodeIfPresent([String].self, forKey: .hooks) ?? []
        self.mcpServers = try c.decodeIfPresent([String].self, forKey: .mcpServers) ?? []
        self.lspServers = try c.decodeIfPresent([String].self, forKey: .lspServers) ?? []
        self.alwaysOnTokens = try c.decodeIfPresent(Int.self, forKey: .alwaysOnTokens)
    }
}
