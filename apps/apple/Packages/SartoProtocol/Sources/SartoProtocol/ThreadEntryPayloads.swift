import Foundation

// MARK: - Full Sarto ThreadEntry Payloads (mirroring src/shared/thread.ts)

public struct GitCommitRef: Codable, Sendable, Equatable, Identifiable {
    public var id: String { oid }
    public let oid: String
    public let subject: String

    public init(oid: String, subject: String) {
        self.oid = oid
        self.subject = subject
    }
}

public struct GitEntryPayload: Codable, Sendable, Equatable {
    public let id: String
    public let event: String // "commit" | "push" | "branch" | "pull_request"
    public let commits: [GitCommitRef]
    public let more: Int
    public let upstream: String?
    public let count: Int?
    public let branch: String?
    public let url: String?

    public init(
        id: String,
        event: String,
        commits: [GitCommitRef] = [],
        more: Int = 0,
        upstream: String? = nil,
        count: Int? = nil,
        branch: String? = nil,
        url: String? = nil
    ) {
        self.id = id
        self.event = event
        self.commits = commits
        self.more = more
        self.upstream = upstream
        self.count = count
        self.branch = branch
        self.url = url
    }

    enum CodingKeys: String, CodingKey {
        case id, event, commits, more, upstream, count, branch, url
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.event = try c.decodeIfPresent(String.self, forKey: .event) ?? "commit"
        self.commits = (try? c.decode([GitCommitRef].self, forKey: .commits)) ?? []
        self.more = try c.decodeIfPresent(Int.self, forKey: .more) ?? 0
        self.upstream = try c.decodeIfPresent(String.self, forKey: .upstream)
        self.count = try c.decodeIfPresent(Int.self, forKey: .count)
        self.branch = try c.decodeIfPresent(String.self, forKey: .branch)
        self.url = try c.decodeIfPresent(String.self, forKey: .url)
    }
}

public struct ArtifactEntryPayload: Codable, Sendable, Equatable {
    public let id: String
    public let artifactId: String
    public let title: String
    public let action: String // "create" | "update" | "restore" | "delete"
    public let version: Int?
    public let writes: Int

    public init(
        id: String,
        artifactId: String,
        title: String,
        action: String,
        version: Int? = nil,
        writes: Int = 1
    ) {
        self.id = id
        self.artifactId = artifactId
        self.title = title
        self.action = action
        self.version = version
        self.writes = writes
    }

    enum CodingKeys: String, CodingKey {
        case id, artifactId, title, action, version, writes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.artifactId = try c.decodeIfPresent(String.self, forKey: .artifactId) ?? ""
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.action = try c.decodeIfPresent(String.self, forKey: .action) ?? "create"
        self.version = try c.decodeIfPresent(Int.self, forKey: .version)
        self.writes = try c.decodeIfPresent(Int.self, forKey: .writes) ?? 1
    }
}

public struct MemoryDraftPayload: Codable, Sendable, Equatable {
    public let title: String?
    public let description: String?
    public let body: String?

    public init(title: String? = nil, description: String? = nil, body: String? = nil) {
        self.title = title
        self.description = description
        self.body = body
    }
}

public struct MemoryWriteEntryPayload: Codable, Sendable, Equatable {
    public let id: String
    public let layer: String // "project" | "global"
    public let action: String // "remember" | "update" | "forget"
    public let memoryId: String?
    public let title: String
    public let status: String // "written" | "pending" | "accepted" | "declined" | "undone" | "expired" | ...
    public let undo: String?
    public let draft: MemoryDraftPayload?

    public init(
        id: String,
        layer: String,
        action: String,
        memoryId: String? = nil,
        title: String,
        status: String,
        undo: String? = nil,
        draft: MemoryDraftPayload? = nil
    ) {
        self.id = id
        self.layer = layer
        self.action = action
        self.memoryId = memoryId
        self.title = title
        self.status = status
        self.undo = undo
        self.draft = draft
    }

    enum CodingKeys: String, CodingKey {
        case id, layer, action, memoryId, title, status, undo, draft
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.layer = try c.decodeIfPresent(String.self, forKey: .layer) ?? "project"
        self.action = try c.decodeIfPresent(String.self, forKey: .action) ?? "remember"
        self.memoryId = try c.decodeIfPresent(String.self, forKey: .memoryId)
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.status = try c.decodeIfPresent(String.self, forKey: .status) ?? "written"
        self.undo = try c.decodeIfPresent(String.self, forKey: .undo)
        self.draft = try? c.decodeIfPresent(MemoryDraftPayload.self, forKey: .draft)
    }
}

public struct SettingChangeValueText: Codable, Sendable, Equatable {
    public let value: JSONValue?
    public let text: String

    public init(value: JSONValue? = nil, text: String) {
        self.value = value
        self.text = text
    }

    enum CodingKeys: String, CodingKey { case value, text }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.value = try? c.decodeIfPresent(JSONValue.self, forKey: .value)
        self.text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
    }
}

public struct SettingChangeItemPayload: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let place: String
    public let name: String
    public let from: SettingChangeValueText
    public let to: SettingChangeValueText
    public let warning: String?

    public init(
        id: String,
        place: String,
        name: String,
        from: SettingChangeValueText,
        to: SettingChangeValueText,
        warning: String? = nil
    ) {
        self.id = id
        self.place = place
        self.name = name
        self.from = from
        self.to = to
        self.warning = warning
    }

    enum CodingKeys: String, CodingKey { case id, place, name, from, to, warning }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.place = try c.decodeIfPresent(String.self, forKey: .place) ?? ""
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.from = (try? c.decode(SettingChangeValueText.self, forKey: .from)) ?? SettingChangeValueText(text: "")
        self.to = (try? c.decode(SettingChangeValueText.self, forKey: .to)) ?? SettingChangeValueText(text: "")
        self.warning = try c.decodeIfPresent(String.self, forKey: .warning)
    }
}

public struct SettingsChangeOutcomePayload: Codable, Sendable, Equatable {
    public let kind: String // "changed" | "declined" | "expired" | "ended" | "failed"
    public let undone: Bool?
    public let stale: Bool?
    public let message: String?

    public init(kind: String, undone: Bool? = nil, stale: Bool? = nil, message: String? = nil) {
        self.kind = kind
        self.undone = undone
        self.stale = stale
        self.message = message
    }
}

public struct SettingsChangeEntryPayload: Codable, Sendable, Equatable {
    public let id: String
    public let items: [SettingChangeItemPayload]
    public let asked: Bool
    public let expiresAt: Double?
    public let outcome: SettingsChangeOutcomePayload?

    public init(
        id: String,
        items: [SettingChangeItemPayload] = [],
        asked: Bool = true,
        expiresAt: Double? = nil,
        outcome: SettingsChangeOutcomePayload? = nil
    ) {
        self.id = id
        self.items = items
        self.asked = asked
        self.expiresAt = expiresAt
        self.outcome = outcome
    }

    enum CodingKeys: String, CodingKey { case id, items, asked, expiresAt, outcome }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.items = (try? c.decode([SettingChangeItemPayload].self, forKey: .items)) ?? []
        self.asked = try c.decodeIfPresent(Bool.self, forKey: .asked) ?? false
        self.expiresAt = try c.decodeIfPresent(Double.self, forKey: .expiresAt)
        self.outcome = try? c.decodeIfPresent(SettingsChangeOutcomePayload.self, forKey: .outcome)
    }
}

public struct BrowserOriginEntryPayload: Codable, Sendable, Equatable {
    public let id: String
    public let requestId: Int
    public let origin: String
    public let decision: String?

    public init(id: String, requestId: Int = 0, origin: String, decision: String? = nil) {
        self.id = id
        self.requestId = requestId
        self.origin = origin
        self.decision = decision
    }

    enum CodingKeys: String, CodingKey { case id, requestId, origin, decision }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.requestId = try c.decodeIfPresent(Int.self, forKey: .requestId) ?? 0
        self.origin = try c.decodeIfPresent(String.self, forKey: .origin) ?? ""
        self.decision = try c.decodeIfPresent(String.self, forKey: .decision)
    }
}

public struct ControlAskEntryPayload: Codable, Sendable, Equatable {
    public let id: String
    public let surface: String
    public let step: String // "sign_in" | "code" | "check" | "other"
    public let target: String?
    public let reason: String
    public let outcome: String? // "done" | "skip" | "ended" | nil

    public init(
        id: String,
        surface: String = "browser",
        step: String = "other",
        target: String? = nil,
        reason: String = "",
        outcome: String? = nil
    ) {
        self.id = id
        self.surface = surface
        self.step = step
        self.target = target
        self.reason = reason
        self.outcome = outcome
    }

    enum CodingKeys: String, CodingKey { case id, surface, step, target, reason, outcome }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.surface = try c.decodeIfPresent(String.self, forKey: .surface) ?? "browser"
        self.step = try c.decodeIfPresent(String.self, forKey: .step) ?? "other"
        self.target = try c.decodeIfPresent(String.self, forKey: .target)
        self.reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        self.outcome = try c.decodeIfPresent(String.self, forKey: .outcome)
    }
}

public struct ControlNoteEntryPayload: Codable, Sendable, Equatable {
    public let id: String
    public let surface: String
    public let event: String // "handed_back" | "paused" | "used"
    public let durationMs: Double?
    public let app: String?
    public let name: String?

    public init(
        id: String,
        surface: String = "browser",
        event: String = "handed_back",
        durationMs: Double? = nil,
        app: String? = nil,
        name: String? = nil
    ) {
        self.id = id
        self.surface = surface
        self.event = event
        self.durationMs = durationMs
        self.app = app
        self.name = name
    }

    enum CodingKeys: String, CodingKey { case id, surface, event, durationMs, app, name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.surface = try c.decodeIfPresent(String.self, forKey: .surface) ?? "browser"
        self.event = try c.decodeIfPresent(String.self, forKey: .event) ?? "handed_back"
        self.durationMs = try c.decodeIfPresent(Double.self, forKey: .durationMs)
        self.app = try c.decodeIfPresent(String.self, forKey: .app)
        self.name = try c.decodeIfPresent(String.self, forKey: .name)
    }
}

public struct DeviceAccessEntryPayload: Codable, Sendable, Equatable {
    public let id: String
    public let deviceId: String
    public let deviceName: String
    public let decision: String?
    public let expiresAt: Double?
    public let revoked: Bool?

    public init(
        id: String,
        deviceId: String,
        deviceName: String,
        decision: String? = nil,
        expiresAt: Double? = nil,
        revoked: Bool? = nil
    ) {
        self.id = id
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.decision = decision
        self.expiresAt = expiresAt
        self.revoked = revoked
    }

    enum CodingKeys: String, CodingKey { case id, deviceId, deviceName, decision, expiresAt, revoked }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.deviceId = try c.decodeIfPresent(String.self, forKey: .deviceId) ?? ""
        self.deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName) ?? ""
        self.decision = try c.decodeIfPresent(String.self, forKey: .decision)
        self.expiresAt = try c.decodeIfPresent(Double.self, forKey: .expiresAt)
        self.revoked = try c.decodeIfPresent(Bool.self, forKey: .revoked)
    }
}

public struct SurfaceAccessEntryPayload: Codable, Sendable, Equatable {
    public let id: String
    public let surface: String // "terminal" | "browser"
    public let targetId: String
    public let targetName: String
    public let readOnly: Bool?
    public let rename: String?
    public let decision: String?
    public let expiresAt: Double?
    public let revoked: Bool?

    public init(
        id: String,
        surface: String = "terminal",
        targetId: String = "",
        targetName: String = "",
        readOnly: Bool? = nil,
        rename: String? = nil,
        decision: String? = nil,
        expiresAt: Double? = nil,
        revoked: Bool? = nil
    ) {
        self.id = id
        self.surface = surface
        self.targetId = targetId
        self.targetName = targetName
        self.readOnly = readOnly
        self.rename = rename
        self.decision = decision
        self.expiresAt = expiresAt
        self.revoked = revoked
    }

    enum CodingKeys: String, CodingKey {
        case id, surface, targetId, targetName, readOnly, rename, decision, expiresAt, revoked
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.surface = try c.decodeIfPresent(String.self, forKey: .surface) ?? "terminal"
        self.targetId = try c.decodeIfPresent(String.self, forKey: .targetId) ?? ""
        self.targetName = try c.decodeIfPresent(String.self, forKey: .targetName) ?? ""
        self.readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly)
        self.rename = try c.decodeIfPresent(String.self, forKey: .rename)
        self.decision = try c.decodeIfPresent(String.self, forKey: .decision)
        self.expiresAt = try c.decodeIfPresent(Double.self, forKey: .expiresAt)
        self.revoked = try c.decodeIfPresent(Bool.self, forKey: .revoked)
    }
}

public struct ComputerAppEntryPayload: Codable, Sendable, Equatable {
    public let id: String
    public let requestId: Int
    public let appId: String
    public let appName: String
    public let decision: String?

    public init(id: String, requestId: Int = 0, appId: String = "", appName: String = "", decision: String? = nil) {
        self.id = id
        self.requestId = requestId
        self.appId = appId
        self.appName = appName
        self.decision = decision
    }

    enum CodingKeys: String, CodingKey { case id, requestId, appId, appName, decision }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.requestId = try c.decodeIfPresent(Int.self, forKey: .requestId) ?? 0
        self.appId = try c.decodeIfPresent(String.self, forKey: .appId) ?? ""
        self.appName = try c.decodeIfPresent(String.self, forKey: .appName) ?? ""
        self.decision = try c.decodeIfPresent(String.self, forKey: .decision)
    }
}

public struct ComputerSetupEntryPayload: Codable, Sendable, Equatable {
    public let id: String
    public let requestId: Int
    public let steps: [String]
    public let done: [String]
    public let outcome: String?

    public init(id: String, requestId: Int = 0, steps: [String] = [], done: [String] = [], outcome: String? = nil) {
        self.id = id
        self.requestId = requestId
        self.steps = steps
        self.done = done
        self.outcome = outcome
    }

    enum CodingKeys: String, CodingKey { case id, requestId, steps, done, outcome }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.requestId = try c.decodeIfPresent(Int.self, forKey: .requestId) ?? 0
        self.steps = (try? c.decode([String].self, forKey: .steps)) ?? []
        self.done = (try? c.decode([String].self, forKey: .done)) ?? []
        self.outcome = try c.decodeIfPresent(String.self, forKey: .outcome)
    }
}

public struct DeclaredMcpServerPayload: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(name)::\(target)" }
    public let name: String
    public let target: String

    public init(name: String, target: String) {
        self.name = name
        self.target = target
    }
}

public struct ProjectMcpEntryPayload: Codable, Sendable, Equatable {
    public let id: String
    public let servers: [DeclaredMcpServerPayload]
    public let decision: String?

    public init(id: String, servers: [DeclaredMcpServerPayload] = [], decision: String? = nil) {
        self.id = id
        self.servers = servers
        self.decision = decision
    }

    enum CodingKeys: String, CodingKey { case id, servers, decision }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.servers = (try? c.decode([DeclaredMcpServerPayload].self, forKey: .servers)) ?? []
        self.decision = try c.decodeIfPresent(String.self, forKey: .decision)
    }
}

public struct DeclaredHookPayload: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(event)::\(target)" }
    public let event: String
    public let target: String

    public init(event: String, target: String) {
        self.event = event
        self.target = target
    }
}

public struct ProjectHooksEntryPayload: Codable, Sendable, Equatable {
    public let id: String
    public let hooks: [DeclaredHookPayload]
    public let decision: String?

    public init(id: String, hooks: [DeclaredHookPayload] = [], decision: String? = nil) {
        self.id = id
        self.hooks = hooks
        self.decision = decision
    }

    enum CodingKeys: String, CodingKey { case id, hooks, decision }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.hooks = (try? c.decode([DeclaredHookPayload].self, forKey: .hooks)) ?? []
        self.decision = try c.decodeIfPresent(String.self, forKey: .decision)
    }
}

public struct ProblemReportOutcomePayload: Codable, Sendable, Equatable {
    public let kind: String // "sent" | "saved" | "skipped"
    public let reportId: String?

    public init(kind: String, reportId: String? = nil) {
        self.kind = kind
        self.reportId = reportId
    }
}

public struct ProblemReportEntryPayload: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let details: String
    public let error: String?
    public let at: Double
    public let outcome: ProblemReportOutcomePayload?

    public init(
        id: String,
        title: String,
        details: String = "",
        error: String? = nil,
        at: Double = 0,
        outcome: ProblemReportOutcomePayload? = nil
    ) {
        self.id = id
        self.title = title
        self.details = details
        self.error = error
        self.at = at
        self.outcome = outcome
    }

    enum CodingKeys: String, CodingKey { case id, title, details, error, at, outcome }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.details = try c.decodeIfPresent(String.self, forKey: .details) ?? ""
        self.error = try c.decodeIfPresent(String.self, forKey: .error)
        self.at = try c.decodeIfPresent(Double.self, forKey: .at) ?? 0
        self.outcome = try? c.decodeIfPresent(ProblemReportOutcomePayload.self, forKey: .outcome)
    }
}

public struct MarketPublishItemInfo: Codable, Sendable, Equatable {
    public let name: String
    public let slug: String
    public let kind: String
    public let description: String

    public init(name: String = "", slug: String = "", kind: String = "", description: String = "") {
        self.name = name
        self.slug = slug
        self.kind = kind
        self.description = description
    }

    enum CodingKeys: String, CodingKey { case name, slug, kind, description }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? ""
        self.kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        self.description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
    }
}

public struct MarketPublishOutcomePayload: Codable, Sendable, Equatable {
    public let kind: String
    public let handle: String?
    public let version: String?
    public let message: String?

    public init(kind: String, handle: String? = nil, version: String? = nil, message: String? = nil) {
        self.kind = kind
        self.handle = handle
        self.version = version
        self.message = message
    }
}

public struct MarketPublishEntryPayload: Codable, Sendable, Equatable {
    public let id: String
    public let action: String // "publish" | "unlist"
    public let item: MarketPublishItemInfo
    public let version: String?
    public let previous: String?
    public let visibility: String?
    public let notes: String?
    public let folder: String
    public let bytes: Int
    public let outcome: MarketPublishOutcomePayload?

    public init(
        id: String,
        action: String = "publish",
        item: MarketPublishItemInfo = MarketPublishItemInfo(),
        version: String? = nil,
        previous: String? = nil,
        visibility: String? = nil,
        notes: String? = nil,
        folder: String = "",
        bytes: Int = 0,
        outcome: MarketPublishOutcomePayload? = nil
    ) {
        self.id = id
        self.action = action
        self.item = item
        self.version = version
        self.previous = previous
        self.visibility = visibility
        self.notes = notes
        self.folder = folder
        self.bytes = bytes
        self.outcome = outcome
    }

    enum CodingKeys: String, CodingKey {
        case id, action, item, version, previous, visibility, notes, folder, bytes, outcome
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.action = try c.decodeIfPresent(String.self, forKey: .action) ?? "publish"
        self.item = (try? c.decode(MarketPublishItemInfo.self, forKey: .item)) ?? MarketPublishItemInfo()
        self.version = try c.decodeIfPresent(String.self, forKey: .version)
        self.previous = try c.decodeIfPresent(String.self, forKey: .previous)
        self.visibility = try c.decodeIfPresent(String.self, forKey: .visibility)
        self.notes = try c.decodeIfPresent(String.self, forKey: .notes)
        self.folder = try c.decodeIfPresent(String.self, forKey: .folder) ?? ""
        self.bytes = try c.decodeIfPresent(Int.self, forKey: .bytes) ?? 0
        self.outcome = try? c.decodeIfPresent(MarketPublishOutcomePayload.self, forKey: .outcome)
    }
}

// MARK: - MCP Elicitation Payloads (Form / URL requests on ToolEntry)

public struct ElicitationFormChoice: Codable, Sendable, Equatable, Identifiable {
    public var id: String { value }
    public let value: String
    public let label: String

    public init(value: String, label: String) {
        self.value = value
        self.label = label
    }

    enum CodingKeys: String, CodingKey { case value, label, title }

    public init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            self.value = s
            self.label = s
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let v = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        self.value = v
        let lbl = try c.decodeIfPresent(String.self, forKey: .label)
        let ttl = try c.decodeIfPresent(String.self, forKey: .title)
        self.label = lbl ?? ttl ?? v
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(value, forKey: .value)
        try c.encode(label, forKey: .label)
    }
}

public struct ElicitationFormField: Codable, Sendable, Equatable, Identifiable {
    public var id: String { key }
    public let key: String
    public let title: String
    public let description: String?
    public let required: Bool
    public let type: String // "text" | "number" | "boolean" | "select" | "multi"
    public let choices: [ElicitationFormChoice]
    public let defaultValue: JSONValue?

    public init(
        key: String,
        title: String,
        description: String? = nil,
        required: Bool = false,
        type: String = "text",
        choices: [ElicitationFormChoice] = [],
        defaultValue: JSONValue? = nil
    ) {
        self.key = key
        self.title = title
        self.description = description
        self.required = required
        self.type = type
        self.choices = choices
        self.defaultValue = defaultValue
    }

    enum CodingKeys: String, CodingKey {
        case key, title, description, required, type, choices, options
        case defaultValue = "default"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let key = try c.decodeIfPresent(String.self, forKey: .key) ?? UUID().uuidString
        self.key = key
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? key
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? false
        self.type = try c.decodeIfPresent(String.self, forKey: .type) ?? "text"
        self.choices = (try? c.decode([ElicitationFormChoice].self, forKey: .choices))
            ?? (try? c.decode([ElicitationFormChoice].self, forKey: .options))
            ?? []
        self.defaultValue = try? c.decodeIfPresent(JSONValue.self, forKey: .defaultValue)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encode(required, forKey: .required)
        try c.encode(type, forKey: .type)
        if !choices.isEmpty { try c.encode(choices, forKey: .choices) }
        try c.encodeIfPresent(defaultValue, forKey: .defaultValue)
    }
}

public struct PendingElicitation: Codable, Sendable, Equatable {
    public let kind: String // "form" | "url"
    public let server: String
    public let message: String
    public let url: String?
    public let fields: [ElicitationFormField]

    public init(
        kind: String,
        server: String,
        message: String,
        url: String? = nil,
        fields: [ElicitationFormField] = []
    ) {
        self.kind = kind
        self.server = server
        self.message = message
        self.url = url
        self.fields = fields
    }

    enum CodingKeys: String, CodingKey { case kind, server, message, url, fields }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "form"
        self.server = try c.decodeIfPresent(String.self, forKey: .server) ?? ""
        self.message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        self.url = try c.decodeIfPresent(String.self, forKey: .url)
        self.fields = (try? c.decode([ElicitationFormField].self, forKey: .fields)) ?? []
    }
}

public struct ToolElicitationSummary: Codable, Sendable, Equatable {
    public let server: String
    public let kind: String // "form" | "url"
    public let url: String?

    public init(server: String, kind: String, url: String? = nil) {
        self.server = server
        self.kind = kind
        self.url = url
    }
}
