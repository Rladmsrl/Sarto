import Foundation

// MARK: - Git Models (src/shared/git.ts)

public struct GitRepoRef: Codable, Sendable, Equatable {
    public let root: String
    public let gitDir: String

    public init(root: String, gitDir: String) {
        self.root = root
        self.gitDir = gitDir
    }
}

public struct GitHeadInfo: Codable, Sendable, Equatable {
    public let branch: String?
    public let oid: String?
    public let detached: Bool

    public init(branch: String?, oid: String?, detached: Bool = false) {
        self.branch = branch
        self.oid = oid
        self.detached = detached
    }
}

public struct GitUpstreamInfo: Codable, Sendable, Equatable {
    public let name: String
    public let ahead: Int
    public let behind: Int

    public init(name: String, ahead: Int, behind: Int) {
        self.name = name
        self.ahead = ahead
        self.behind = behind
    }
}

public struct GitChangesSummary: Codable, Sendable, Equatable {
    public let staged: Int
    public let unstaged: Int
    public let untracked: Int
    public let conflicted: Int
    public let insertions: Int
    public let deletions: Int

    public init(
        staged: Int = 0,
        unstaged: Int = 0,
        untracked: Int = 0,
        conflicted: Int = 0,
        insertions: Int = 0,
        deletions: Int = 0
    ) {
        self.staged = staged
        self.unstaged = unstaged
        self.untracked = untracked
        self.conflicted = conflicted
        self.insertions = insertions
        self.deletions = deletions
    }

    public var totalChanged: Int {
        staged + unstaged + untracked + conflicted
    }
}

public struct GitCommitSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String { oid }
    public let oid: String
    public let subject: String
    public let authoredAt: Double
    public let pushed: Bool

    public init(oid: String, subject: String, authoredAt: Double, pushed: Bool = false) {
        self.oid = oid
        self.subject = subject
        self.authoredAt = authoredAt
        self.pushed = pushed
    }
}

public struct GitStatusInfo: Codable, Sendable, Equatable {
    public let projectPath: String
    public let repo: GitRepoRef?
    public let head: GitHeadInfo
    public let upstream: GitUpstreamInfo?
    public let changes: GitChangesSummary
    public let commits: [GitCommitSummary]
    public let defaultBranch: String?
    public let updatedAt: Double
    public let stale: Bool
    // Nil from hosts that predate them; `push` is also nil when HEAD is not on a branch with a commit.
    /// The branch against the default branch's remote tracking ref.
    public let base: GitUpstreamInfo?
    public let operation: GitStoppedOperation?
    public let remote: GitRemoteInfo?
    public let push: GitPushTarget?
    public let lastFetchedAt: Double?

    public init(
        projectPath: String,
        repo: GitRepoRef?,
        head: GitHeadInfo,
        upstream: GitUpstreamInfo? = nil,
        changes: GitChangesSummary = GitChangesSummary(),
        commits: [GitCommitSummary] = [],
        defaultBranch: String? = "main",
        updatedAt: Double = Date().timeIntervalSince1970 * 1000,
        stale: Bool = false,
        base: GitUpstreamInfo? = nil,
        operation: GitStoppedOperation? = nil,
        remote: GitRemoteInfo? = nil,
        push: GitPushTarget? = nil,
        lastFetchedAt: Double? = nil
    ) {
        self.projectPath = projectPath
        self.repo = repo
        self.head = head
        self.upstream = upstream
        self.changes = changes
        self.commits = commits
        self.defaultBranch = defaultBranch
        self.updatedAt = updatedAt
        self.stale = stale
        self.base = base
        self.operation = operation
        self.remote = remote
        self.push = push
        self.lastFetchedAt = lastFetchedAt
    }
}

public enum GitChangeStatus: String, Codable, Sendable, Equatable {
    case added
    case modified
    case deleted
    case renamed
    case copied
    case typechange
    case untracked
    case conflicted

    public var shortCode: String {
        switch self {
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .typechange: return "T"
        case .untracked: return "U"
        case .conflicted: return "!"
        }
    }
}

public struct ChangedFileInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let path: String
    public let oldPath: String?
    public let status: GitChangeStatus
    public let insertions: Int?
    public let deletions: Int?

    public init(
        path: String,
        oldPath: String? = nil,
        status: GitChangeStatus,
        insertions: Int? = nil,
        deletions: Int? = nil
    ) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.insertions = insertions
        self.deletions = deletions
    }
}

public struct FileDiffInfo: Codable, Sendable, Equatable {
    public let path: String
    public let oldText: String?
    public let newText: String?
    public let binary: Bool
    public let tooLarge: Bool

    public init(
        path: String,
        oldText: String?,
        newText: String?,
        binary: Bool = false,
        tooLarge: Bool = false
    ) {
        self.path = path
        self.oldText = oldText
        self.newText = newText
        self.binary = binary
        self.tooLarge = tooLarge
    }
}

public struct BranchInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let oid: String?
    public let committedAt: Double?
    public let current: Bool
    public let worktree: String?

    public init(name: String, oid: String? = nil, committedAt: Double? = nil, current: Bool = false, worktree: String? = nil) {
        self.name = name
        self.oid = oid
        self.committedAt = committedAt
        self.current = current
        self.worktree = worktree
    }
}

public struct BranchListInfo: Codable, Sendable, Equatable {
    public let branches: [BranchInfo]

    public init(branches: [BranchInfo]) {
        self.branches = branches
    }
}

public struct GitOperationResult: Codable, Sendable, Equatable {
    public let status: GitStatusInfo
    public let log: String

    public init(status: GitStatusInfo, log: String) {
        self.status = status
        self.log = log
    }
}

// MARK: - Files Models (src/shared/files.ts)

public struct ProjectFileList: Codable, Sendable, Equatable {
    public let paths: [String]
    public let folders: [String]
    public let ignored: [String]
    public let ignoredFolders: [String]
    public let truncated: Bool

    public init(
        paths: [String],
        folders: [String] = [],
        ignored: [String] = [],
        ignoredFolders: [String] = [],
        truncated: Bool = false
    ) {
        self.paths = paths
        self.folders = folders
        self.ignored = ignored
        self.ignoredFolders = ignoredFolders
        self.truncated = truncated
    }

    enum CodingKeys: String, CodingKey {
        case paths, folders, ignored, ignoredFolders, truncated
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.paths = try c.decodeIfPresent([String].self, forKey: .paths) ?? []
        self.folders = try c.decodeIfPresent([String].self, forKey: .folders) ?? []
        self.ignored = try c.decodeIfPresent([String].self, forKey: .ignored) ?? []
        self.ignoredFolders = try c.decodeIfPresent([String].self, forKey: .ignoredFolders) ?? []
        self.truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
}

public struct ProjectFolderList: Codable, Sendable, Equatable {
    public let paths: [String]
    public let folders: [String]
    public let truncated: Bool

    public init(paths: [String], folders: [String] = [], truncated: Bool = false) {
        self.paths = paths
        self.folders = folders
        self.truncated = truncated
    }

    enum CodingKeys: String, CodingKey {
        case files, paths, folders, truncated
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let files = try c.decodeIfPresent([String].self, forKey: .files) {
            self.paths = files
        } else {
            self.paths = try c.decodeIfPresent([String].self, forKey: .paths) ?? []
        }
        self.folders = try c.decodeIfPresent([String].self, forKey: .folders) ?? []
        self.truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(paths, forKey: .files)
        try c.encode(folders, forKey: .folders)
        try c.encode(truncated, forKey: .truncated)
    }
}

public enum ProjectFileContent: Codable, Sendable, Equatable {
    case text(path: String, size: Int, text: String, version: String, editable: Bool)
    case binary(path: String, size: Int)
    case tooLarge(path: String, size: Int, limit: Int)
    case media(path: String)

    enum CodingKeys: String, CodingKey {
        case kind, path, size, text, version, editable, limit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        let path = try c.decode(String.self, forKey: .path)
        switch kind {
        case "text":
            self = .text(
                path: path,
                size: try c.decodeIfPresent(Int.self, forKey: .size) ?? 0,
                text: try c.decode(String.self, forKey: .text),
                version: try c.decodeIfPresent(String.self, forKey: .version) ?? "",
                editable: try c.decodeIfPresent(Bool.self, forKey: .editable) ?? true
            )
        case "binary":
            self = .binary(path: path, size: try c.decodeIfPresent(Int.self, forKey: .size) ?? 0)
        case "too-large":
            self = .tooLarge(
                path: path,
                size: try c.decodeIfPresent(Int.self, forKey: .size) ?? 0,
                limit: try c.decodeIfPresent(Int.self, forKey: .limit) ?? 1_048_576
            )
        default:
            self = .media(path: path)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let path, let size, let text, let version, let editable):
            try c.encode("text", forKey: .kind)
            try c.encode(path, forKey: .path)
            try c.encode(size, forKey: .size)
            try c.encode(text, forKey: .text)
            try c.encode(version, forKey: .version)
            try c.encode(editable, forKey: .editable)
        case .binary(let path, let size):
            try c.encode("binary", forKey: .kind)
            try c.encode(path, forKey: .path)
            try c.encode(size, forKey: .size)
        case .tooLarge(let path, let size, let limit):
            try c.encode("too-large", forKey: .kind)
            try c.encode(path, forKey: .path)
            try c.encode(size, forKey: .size)
            try c.encode(limit, forKey: .limit)
        case .media(let path):
            try c.encode("media", forKey: .kind)
            try c.encode(path, forKey: .path)
        }
    }
}

public struct ProjectFileWritten: Codable, Sendable, Equatable {
    public let version: String
    public let size: Int

    public init(version: String, size: Int) {
        self.version = version
        self.size = size
    }
}

public struct ProjectFileMatch: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(path):\(line)" }
    public let path: String
    public let line: Int
    public let text: String

    public init(path: String, line: Int, text: String) {
        self.path = path
        self.line = line
        self.text = text
    }
}

public struct ProjectFileSearch: Codable, Sendable, Equatable {
    public let matches: [ProjectFileMatch]
    public let truncated: Bool

    public init(matches: [ProjectFileMatch], truncated: Bool = false) {
        self.matches = matches
        self.truncated = truncated
    }
}

// MARK: - Terminal Models (src/shared/terminal-host.ts & src/shared/control.ts)

public struct TerminalOwnerInfo: Codable, Sendable, Equatable {
    public let agentId: String
    public let sessionId: String
    public let fromReply: Bool?

    public init(agentId: String, sessionId: String, fromReply: Bool? = nil) {
        self.agentId = agentId
        self.sessionId = sessionId
        self.fromReply = fromReply
    }
}

public struct TerminalControlInfo: Codable, Sendable, Equatable {
    public let kind: String
    public let acting: Bool?
    public let since: Double?

    public static let idle = TerminalControlInfo(kind: "idle", acting: nil, since: nil)

    public init(kind: String = "idle", acting: Bool? = nil, since: Double? = nil) {
        self.kind = kind
        self.acting = acting
        self.since = since
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "idle"
        self.acting = try c.decodeIfPresent(Bool.self, forKey: .acting)
        self.since = try c.decodeIfPresent(Double.self, forKey: .since)
    }

    public var isAgent: Bool { kind == "agent" }
    public var isYou: Bool { kind == "you" }
}

public struct TerminalInfo: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let projectPath: String
    public let sessionId: String?
    public let shell: String
    public let title: String
    public let name: String?
    public let namedBy: String?
    public let busy: Bool
    public let exitCode: Int?
    public let createdAt: Double
    public let owner: TerminalOwnerInfo?
    public let agentAllowed: Bool
    public let agentAsks: Bool
    public let control: TerminalControlInfo
    public let waiting: String?

    public init(
        id: String,
        projectPath: String,
        sessionId: String? = nil,
        shell: String = "zsh",
        title: String = "zsh",
        name: String? = nil,
        namedBy: String? = nil,
        busy: Bool = false,
        exitCode: Int? = nil,
        createdAt: Double = Date().timeIntervalSince1970 * 1000,
        owner: TerminalOwnerInfo? = nil,
        agentAllowed: Bool = false,
        agentAsks: Bool = false,
        control: TerminalControlInfo = .idle,
        waiting: String? = nil
    ) {
        self.id = id
        self.projectPath = projectPath
        self.sessionId = sessionId
        self.shell = shell
        self.title = title
        self.name = name
        self.namedBy = namedBy
        self.busy = busy
        self.exitCode = exitCode
        self.createdAt = createdAt
        self.owner = owner
        self.agentAllowed = agentAllowed
        self.agentAsks = agentAsks
        self.control = control
        self.waiting = waiting
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.projectPath = try c.decodeIfPresent(String.self, forKey: .projectPath) ?? ""
        self.sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        self.shell = try c.decodeIfPresent(String.self, forKey: .shell) ?? "zsh"
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? shell
        self.name = try c.decodeIfPresent(String.self, forKey: .name)
        self.namedBy = try c.decodeIfPresent(String.self, forKey: .namedBy)
        self.busy = try c.decodeIfPresent(Bool.self, forKey: .busy) ?? false
        self.exitCode = try c.decodeIfPresent(Int.self, forKey: .exitCode)
        self.createdAt = try c.decodeIfPresent(Double.self, forKey: .createdAt) ?? 0
        self.owner = try c.decodeIfPresent(TerminalOwnerInfo.self, forKey: .owner)
        self.agentAllowed = try c.decodeIfPresent(Bool.self, forKey: .agentAllowed) ?? false
        self.agentAsks = try c.decodeIfPresent(Bool.self, forKey: .agentAsks) ?? false
        self.control = try c.decodeIfPresent(TerminalControlInfo.self, forKey: .control) ?? .idle
        self.waiting = try c.decodeIfPresent(String.self, forKey: .waiting)
    }

    public var displayTitle: String {
        if let name, !name.isEmpty { return name }
        return title.isEmpty ? shell : title
    }

    public var isWaitingForPassword: Bool {
        waiting == "password"
    }
}

public enum TerminalEvent: Sendable, Equatable {
    case data(id: String, data: String)
    case replay(id: String, replay: String)
    case info(TerminalInfo)
    case removed(id: String)
    case unknown(String)

    private struct EventProbe: Decodable {
        struct Inner: Decodable {
            let type: String
            let id: String?
            let data: String?
            let replay: String?
            let info: TerminalInfo?
        }
        let event: Inner
    }

    public static func decode(fromEnvelopeData data: Data) -> TerminalEvent? {
        guard let decoded = try? JSONDecoder().decode(EventProbe.self, from: data) else {
            return nil
        }
        let inner = decoded.event
        switch inner.type {
        case "terminal.data":
            if let id = inner.id, let chunk = inner.data {
                return .data(id: id, data: chunk)
            }
        case "terminal.replay":
            if let id = inner.id, let replay = inner.replay {
                return .replay(id: id, replay: replay)
            }
        case "terminal.info":
            if let info = inner.info {
                return .info(info)
            }
        case "terminal.removed":
            if let id = inner.id {
                return .removed(id: id)
            }
        default:
            break
        }
        return .unknown(inner.type)
    }

    public static func decode(from value: JSONValue) -> TerminalEvent {
        guard let obj = value.objectValue, let type = obj["type"]?.stringValue else {
            return .unknown("malformed")
        }
        switch type {
        case "terminal.data":
            if let id = obj["id"]?.stringValue, let data = obj["data"]?.stringValue {
                return .data(id: id, data: data)
            }
        case "terminal.replay":
            if let id = obj["id"]?.stringValue, let replay = obj["replay"]?.stringValue {
                return .replay(id: id, replay: replay)
            }
        case "terminal.info":
            if let infoVal = obj["info"], let info = try? infoVal.decode(TerminalInfo.self) {
                return .info(info)
            }
        case "terminal.removed":
            if let id = obj["id"]?.stringValue {
                return .removed(id: id)
            }
        default:
            break
        }
        return .unknown(type)
    }
}
