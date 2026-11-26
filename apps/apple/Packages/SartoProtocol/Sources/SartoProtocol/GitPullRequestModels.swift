import Foundation

// MARK: - Git status details, pull requests and tools (src/shared/git.ts)
//
// Every enum here decodes a value it does not know to a fallback instead of failing, so a newer
// host that adds a state never breaks the status a client already shows.

/// A GitHub repository a remote or a push target points at.
public struct GitHubRepoRef: Codable, Sendable, Equatable, Hashable {
    public let owner: String
    public let repo: String

    public init(owner: String, repo: String) {
        self.owner = owner
        self.repo = repo
    }
}

/// The repository's remote, as `GitStatus.remote` and `GitRemote` name it.
public struct GitRemoteInfo: Codable, Sendable, Equatable {
    public let name: String
    public let url: String
    public let github: GitHubRepoRef?

    public init(name: String, url: String, github: GitHubRepoRef? = nil) {
        self.name = name
        self.url = url
        self.github = github
    }
}

/// The operation git stopped in the middle of (`GitStatus.operation`).
public struct GitStoppedOperation: Codable, Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case merge
        case rebase
        case cherryPick = "cherry-pick"
        case revert
    }

    /// The raw kind, kept as the host wrote it.
    public let kind: String
    /// `[current, total]` for an operation that walks several commits, such as a rebase.
    public let step: [Int]?

    public init(kind: String, step: [Int]? = nil) {
        self.kind = kind
        self.step = step
    }

    public var knownKind: Kind? { Kind(rawValue: kind) }

    /// The command that carries the operation on once its conflicts are resolved.
    public var continueCommand: String? {
        knownKind.map { "git \($0.rawValue) --continue" }
    }
}

/// The remote side of `PushTarget` when the branch can be pushed somewhere.
public struct GitRemotePushTarget: Codable, Sendable, Equatable {
    public let remote: String
    public let github: GitHubRepoRef?
    /// The branch on the remote, without `refs/heads/`.
    public let branch: String
    /// The branch has no upstream yet, so the push sets one.
    public let setUpstream: Bool

    public init(remote: String, github: GitHubRepoRef? = nil, branch: String, setUpstream: Bool = false) {
        self.remote = remote
        self.github = github
        self.branch = branch
        self.setUpstream = setUpstream
    }
}

/// Where Push sends the branch, by git's own rules (`GitStatus.push`).
public enum GitPushTarget: Codable, Sendable, Equatable {
    case remote(GitRemotePushTarget)
    /// The repository has no remote at all.
    case noRemote
    /// Several remotes and nothing says which one.
    case unknownRemote
    /// The upstream is a branch of this repository.
    case localUpstream
    /// `push.default` refuses an upstream of another name.
    case otherName(upstream: String)
    /// A kind this client does not know yet; nothing is pushed for it.
    case unsupported(kind: String)

    private enum CodingKeys: String, CodingKey {
        case kind, remote, github, branch, setUpstream, upstream
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "remote":
            self = .remote(GitRemotePushTarget(
                remote: try c.decode(String.self, forKey: .remote),
                github: try c.decodeIfPresent(GitHubRepoRef.self, forKey: .github),
                branch: try c.decode(String.self, forKey: .branch),
                setUpstream: try c.decodeIfPresent(Bool.self, forKey: .setUpstream) ?? false
            ))
        case "noRemote": self = .noRemote
        case "unknownRemote": self = .unknownRemote
        case "localUpstream": self = .localUpstream
        case "otherName":
            self = .otherName(upstream: try c.decodeIfPresent(String.self, forKey: .upstream) ?? "")
        default: self = .unsupported(kind: kind)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .remote(let target):
            try c.encode("remote", forKey: .kind)
            try c.encode(target.remote, forKey: .remote)
            try c.encode(target.github, forKey: .github)
            try c.encode(target.branch, forKey: .branch)
            try c.encode(target.setUpstream, forKey: .setUpstream)
        case .noRemote: try c.encode("noRemote", forKey: .kind)
        case .unknownRemote: try c.encode("unknownRemote", forKey: .kind)
        case .localUpstream: try c.encode("localUpstream", forKey: .kind)
        case .otherName(let upstream):
            try c.encode("otherName", forKey: .kind)
            try c.encode(upstream, forKey: .upstream)
        case .unsupported(let kind): try c.encode(kind, forKey: .kind)
        }
    }

    public var remoteTarget: GitRemotePushTarget? {
        if case .remote(let target) = self { return target }
        return nil
    }
}

// MARK: - Pull requests

public enum GitPullRequestState: String, Codable, Sendable, Equatable {
    case open, draft, merged, closed

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = GitPullRequestState(rawValue: raw) ?? .open
    }
}

public enum GitChecksState: String, Codable, Sendable, Equatable {
    case none, pending, passing, failing

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = GitChecksState(rawValue: raw) ?? .none
    }
}

public enum GitCheckOutcome: String, Codable, Sendable, Equatable {
    case passed, failed, pending

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = GitCheckOutcome(rawValue: raw) ?? .pending
    }
}

public enum GitReviewState: String, Codable, Sendable, Equatable {
    case approved
    case changesRequested = "changes_requested"
    case reviewRequired = "review_required"
    case other

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = GitReviewState(rawValue: raw) ?? .other
    }
}

public enum GitMergeableState: String, Codable, Sendable, Equatable {
    case clean, conflicting, blocked, unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = GitMergeableState(rawValue: raw) ?? .unknown
    }
}

public struct GitCheckRun: Codable, Sendable, Equatable {
    public let name: String
    public let outcome: GitCheckOutcome
    /// An https:// link to the run's page.
    public let url: String?
    public let startedAt: Double?
    public let completedAt: Double?

    public init(name: String, outcome: GitCheckOutcome, url: String? = nil, startedAt: Double? = nil, completedAt: Double? = nil) {
        self.name = name
        self.outcome = outcome
        self.url = url
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

public struct GitPullRequestChecks: Codable, Sendable, Equatable {
    public let state: GitChecksState
    public let passed: Int
    public let failed: Int
    public let pending: Int
    /// Failing first, then pending, then passed, each by name.
    public let runs: [GitCheckRun]

    public init(state: GitChecksState = .none, passed: Int = 0, failed: Int = 0, pending: Int = 0, runs: [GitCheckRun] = []) {
        self.state = state
        self.passed = passed
        self.failed = failed
        self.pending = pending
        self.runs = runs
    }

    private enum CodingKeys: String, CodingKey { case state, passed, failed, pending, runs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decodeIfPresent(GitChecksState.self, forKey: .state) ?? .none
        passed = try c.decodeIfPresent(Int.self, forKey: .passed) ?? 0
        failed = try c.decodeIfPresent(Int.self, forKey: .failed) ?? 0
        pending = try c.decodeIfPresent(Int.self, forKey: .pending) ?? 0
        runs = try c.decodeIfPresent([GitCheckRun].self, forKey: .runs) ?? []
    }
}

public struct GitPullRequestAuthor: Codable, Sendable, Equatable {
    /// A bot's as `<slug>[bot]`, its user name on GitHub.
    public let login: String
    public let name: String?
    public let bot: Bool

    public init(login: String, name: String? = nil, bot: Bool = false) {
        self.login = login
        self.name = name
        self.bot = bot
    }

    private enum CodingKeys: String, CodingKey { case login, name, bot }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        login = try c.decode(String.self, forKey: .login)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        bot = try c.decodeIfPresent(Bool.self, forKey: .bot) ?? false
    }
}

/// A GitHub pull request (`PullRequest`), as `git.currentPullRequest` and
/// `git.createPullRequest` answer. Fields older hosts lack decode to empty values.
public struct GitPullRequestInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { url }
    public let url: String
    public let owner: String
    public let repo: String
    public let number: Int
    public let title: String
    public let state: GitPullRequestState
    public let head: String
    public let base: String
    public let checks: GitPullRequestChecks
    public let review: GitReviewState?
    public let mergeable: GitMergeableState
    public let updatedAt: Double
    /// Nil for a deleted account.
    public let author: GitPullRequestAuthor?
    public let createdAt: Double
    public let mergedAt: Double?
    public let closedAt: Double?
    public let additions: Int
    public let deletions: Int
    public let changedFiles: Int

    public init(
        url: String,
        owner: String = "",
        repo: String = "",
        number: Int,
        title: String,
        state: GitPullRequestState = .open,
        head: String = "",
        base: String = "",
        checks: GitPullRequestChecks = GitPullRequestChecks(),
        review: GitReviewState? = nil,
        mergeable: GitMergeableState = .unknown,
        updatedAt: Double = 0,
        author: GitPullRequestAuthor? = nil,
        createdAt: Double = 0,
        mergedAt: Double? = nil,
        closedAt: Double? = nil,
        additions: Int = 0,
        deletions: Int = 0,
        changedFiles: Int = 0
    ) {
        self.url = url
        self.owner = owner
        self.repo = repo
        self.number = number
        self.title = title
        self.state = state
        self.head = head
        self.base = base
        self.checks = checks
        self.review = review
        self.mergeable = mergeable
        self.updatedAt = updatedAt
        self.author = author
        self.createdAt = createdAt
        self.mergedAt = mergedAt
        self.closedAt = closedAt
        self.additions = additions
        self.deletions = deletions
        self.changedFiles = changedFiles
    }

    private enum CodingKeys: String, CodingKey {
        case url, owner, repo, number, title, state, head, base, checks, review, mergeable
        case updatedAt, author, createdAt, mergedAt, closedAt, additions, deletions, changedFiles
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        number = try c.decode(Int.self, forKey: .number)
        owner = try c.decodeIfPresent(String.self, forKey: .owner) ?? ""
        repo = try c.decodeIfPresent(String.self, forKey: .repo) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        state = try c.decodeIfPresent(GitPullRequestState.self, forKey: .state) ?? .open
        head = try c.decodeIfPresent(String.self, forKey: .head) ?? ""
        base = try c.decodeIfPresent(String.self, forKey: .base) ?? ""
        checks = try c.decodeIfPresent(GitPullRequestChecks.self, forKey: .checks) ?? GitPullRequestChecks()
        review = try c.decodeIfPresent(GitReviewState.self, forKey: .review)
        mergeable = try c.decodeIfPresent(GitMergeableState.self, forKey: .mergeable) ?? .unknown
        updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0
        author = try c.decodeIfPresent(GitPullRequestAuthor.self, forKey: .author)
        createdAt = try c.decodeIfPresent(Double.self, forKey: .createdAt) ?? 0
        mergedAt = try c.decodeIfPresent(Double.self, forKey: .mergedAt)
        closedAt = try c.decodeIfPresent(Double.self, forKey: .closedAt)
        additions = try c.decodeIfPresent(Int.self, forKey: .additions) ?? 0
        deletions = try c.decodeIfPresent(Int.self, forKey: .deletions) ?? 0
        changedFiles = try c.decodeIfPresent(Int.self, forKey: .changedFiles) ?? 0
    }

    /// The names of the checks that failed, as the pull request lists them.
    public var failingCheckNames: [String] {
        checks.runs.filter { $0.outcome == .failed }.map(\.name)
    }

    /// Open, with nothing failing, nothing pending, no conflicts and no review that blocks it.
    public var isReadyToMerge: Bool {
        state == .open
            && (checks.state == .passing || checks.state == .none)
            && mergeable == .clean
            && review != .reviewRequired
            && review != .changesRequested
    }
}

/// A pull request's title and description an agent wrote (`git.pullRequestDraft`).
public struct GitPullRequestDraft: Codable, Sendable, Equatable {
    public let title: String
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }

    private enum CodingKeys: String, CodingKey { case title, body }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
    }
}

// MARK: - Tools

public enum GitHubCLIState: String, Codable, Sendable, Equatable {
    case notInstalled = "not-installed"
    case signedOut = "signed-out"
    case ready

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = GitHubCLIState(rawValue: raw) ?? .notInstalled
    }
}

/// Whether git and the GitHub CLI are usable on the host (`GitTools`).
public struct GitToolsInfo: Codable, Sendable, Equatable {
    public struct Git: Codable, Sendable, Equatable {
        public let found: Bool
        public let version: String?

        public init(found: Bool, version: String? = nil) {
            self.found = found
            self.version = version
        }
    }

    public struct GitHubCLI: Codable, Sendable, Equatable {
        public let state: GitHubCLIState
        public let version: String?
        public let account: String?

        public init(state: GitHubCLIState, version: String? = nil, account: String? = nil) {
            self.state = state
            self.version = version
            self.account = account
        }
    }

    public let git: Git
    public let gh: GitHubCLI

    public init(git: Git, gh: GitHubCLI) {
        self.git = git
        self.gh = gh
    }
}
