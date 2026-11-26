import Foundation

// MARK: - The next step for a branch (src/renderer/src/features/git/next-step.ts and sync.ts)
//
// Pure, so the order of the steps is tested on its own. The steps that hand work to an agent
// upstream (resolve conflicts, rebase, fix checks) carry no button here; publishing a whole
// repository has none either, since it needs a name and a visibility the client does not ask for.

/// Why a sync button cannot run.
public enum GitSyncReason: String, Sendable, Equatable {
    case noBranch
    case operation
    case noRemote
    case noUpstream
    case nothingToPush
    case diverged
    case ghMissing
    case ghSignedOut
    case unknownRemote
    case localUpstream
    case otherName
    /// The host did not say where a push goes.
    case unknownTarget
}

public enum GitSyncOperation: String, Sendable, Equatable {
    case pull, push, publishBranch, publishRepo
}

public struct GitSyncButton: Sendable, Equatable {
    public var kind: GitSyncOperation
    public var count: Int
    public var enabled: Bool
    /// The next step, which takes the default look.
    public var isNext: Bool
    public var reason: GitSyncReason?

    static func off(_ kind: GitSyncOperation, _ reason: GitSyncReason, count: Int = 0) -> GitSyncButton {
        GitSyncButton(kind: kind, count: count, enabled: false, isNext: false, reason: reason)
    }

    static func on(_ kind: GitSyncOperation, count: Int, isNext: Bool = true) -> GitSyncButton {
        GitSyncButton(kind: kind, count: count, enabled: true, isNext: isNext, reason: nil)
    }
}

/// What Pull and Push offer for a repository's state.
public struct GitSyncPlan: Sendable, Equatable {
    public var pull: GitSyncButton
    public var push: GitSyncButton
}

public struct GitNextStep: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case conflicts
        case continueOperation
        case commit
        case noBranch
        case publishRepo
        case blocked
        case diverged
        case pull
        case push
        case publishBranch
        case createPullRequest
        case fixChecks
        case waiting
        case merge
        case merged
        case closed
        case upToDate
    }

    /// Picks the wording where one kind says more than one thing.
    public enum Variant: String, Sendable, Equatable {
        // commit
        case publish
        // noBranch
        case detached, unborn
        // blocked
        case unknownRemote, localUpstream, otherName, unknownTarget
        // push
        case pullRequest, updatesPullRequest
        // createPullRequest
        case signedOut, noGh
        // waiting
        case draft, conflicts, checks, review, changesRequested, blocked
        // upToDate
        case synced, empty
    }

    /// What the line under a commit step adds.
    public enum Context: String, Sendable, Equatable {
        case checks, unpublished
    }

    public enum Tone: String, Sendable, Equatable {
        case primary, danger, warning, success, merged, quiet
    }

    public enum Action: String, Sendable, Equatable {
        case commit
        case commitAndPush
        case copyContinue
        case pull
        case push
        case publishBranch
        /// Opens the pull request draft, which can create it or open GitHub's compare page.
        case draftPullRequest
        case openCompare
        case openPullRequest
        case mergeOnGitHub
        case switchToDefault
    }

    public struct Button: Sendable, Equatable {
        public var action: Action
        public var enabled: Bool
        public var reason: GitSyncReason?
        /// A count the label names, such as the commits a push sends.
        public var count: Int

        public init(_ action: Action, enabled: Bool = true, reason: GitSyncReason? = nil, count: Int = 0) {
            self.action = action
            self.enabled = enabled
            self.reason = reason
            self.count = count
        }
    }

    public var kind: Kind
    public var tone: Tone
    public var variant: Variant?
    public var context: Context?
    /// The operation a stop or a conflict belongs to.
    public var operation: GitStoppedOperation?
    public var primary: Button?
    public var secondary: Button?

    // The values the wording names; each kind sets the ones it uses.
    public var count: Int = 0
    public var insertions: Int = 0
    public var deletions: Int = 0
    public var upstream: String = ""
    public var remote: String = ""
    public var base: String = ""
    public var branch: String = ""
    public var number: Int = 0
    /// A failing check's name.
    public var checkName: String = ""
    public var approved: Bool = false

    public init(
        kind: Kind,
        tone: Tone,
        variant: Variant? = nil,
        context: Context? = nil,
        operation: GitStoppedOperation? = nil,
        primary: Button? = nil,
        secondary: Button? = nil
    ) {
        self.kind = kind
        self.tone = tone
        self.variant = variant
        self.context = context
        self.operation = operation
        self.primary = primary
        self.secondary = secondary
    }
}

public extension GitStatusInfo {
    /// Files with changes in the working tree, conflicts included.
    var changeCount: Int { changes.totalChanged }

    /// Where a push or a branch publish goes, when it goes anywhere.
    var remotePushTarget: GitRemotePushTarget? { push?.remoteTarget }

    /// The commits only this computer has: those past the upstream, or all of an unpublished branch.
    var unpushedCount: Int { upstream?.ahead ?? commits.count }

    /// HEAD is on a branch with a commit.
    var isOnBranch: Bool {
        !head.detached && head.branch != nil && head.oid != nil
    }

    /// The pull request's head as gh and GitHub name it, `owner:branch` from a fork, or nil when
    /// the branch is not on GitHub yet or is the base itself.
    var pullRequestHead: String? {
        guard let github = remote?.github,
              let target = remotePushTarget,
              !target.setUpstream,
              let targetRepo = target.github
        else { return nil }
        let sameRepo = targetRepo.owner == github.owner && targetRepo.repo == github.repo
        if sameRepo && target.branch == defaultBranch { return nil }
        return sameRepo ? target.branch : "\(targetRepo.owner):\(target.branch)"
    }

    /// GitHub's page for opening a pull request from the branch into `base` (the default branch
    /// when nil), or nil when the branch is not on GitHub. A title and body prefill the page.
    func compareURL(base: String? = nil, title: String? = nil, body: String? = nil) -> URL? {
        guard let github = remote?.github,
              let head = pullRequestHead,
              let into = base ?? defaultBranch,
              !into.isEmpty
        else { return nil }
        let headPath = head.split(separator: ":", omittingEmptySubsequences: false)
            .map { Self.pathComponent(String($0)) }
            .joined(separator: ":")
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.percentEncodedPath = "/\(Self.pathComponent(github.owner))/\(Self.pathComponent(github.repo))"
            + "/compare/\(Self.pathComponent(into))...\(headPath)"
        var query = [URLQueryItem(name: "expand", value: "1")]
        if let title, !title.isEmpty { query.append(URLQueryItem(name: "title", value: title)) }
        if let body, !body.isEmpty { query.append(URLQueryItem(name: "body", value: body)) }
        components.queryItems = query
        // `+` reads as a space in a query, so it is spelled out like the other reserved marks.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    /// What Pull and Push offer, as upstream's branch popover table says.
    func syncPlan(gh: GitHubCLIState?) -> GitSyncPlan {
        if operation != nil || changes.conflicted > 0 {
            return GitSyncPlan(pull: .off(.pull, .operation), push: .off(.push, .operation))
        }
        guard isOnBranch else {
            return GitSyncPlan(pull: .off(.pull, .noBranch), push: .off(.push, .noBranch))
        }
        guard let push else {
            return GitSyncPlan(pull: Self.pullButton(upstream), push: .off(.push, .unknownTarget))
        }
        let pull = Self.pullButton(upstream)
        switch push {
        case .noRemote:
            if gh != .ready {
                let reason: GitSyncReason = gh == .signedOut ? .ghSignedOut : .ghMissing
                return GitSyncPlan(pull: .off(.pull, .noRemote), push: .off(.publishRepo, reason))
            }
            return GitSyncPlan(pull: .off(.pull, .noRemote), push: .on(.publishRepo, count: 0))
        case .unknownRemote:
            return GitSyncPlan(pull: pull, push: .off(.push, .unknownRemote))
        case .localUpstream:
            return GitSyncPlan(pull: pull, push: .off(.push, .localUpstream))
        case .otherName:
            return GitSyncPlan(pull: pull, push: .off(.push, .otherName))
        case .unsupported:
            return GitSyncPlan(pull: pull, push: .off(.push, .unknownTarget))
        case .remote(let target):
            if target.setUpstream {
                return GitSyncPlan(pull: pull, push: .on(.publishBranch, count: commits.count))
            }
            guard let upstream, upstream.name == "\(target.remote)/\(target.branch)" else {
                // A push past the upstream, to a fork: nothing tells how far ahead it is.
                return GitSyncPlan(pull: pull, push: .on(.push, count: 0, isNext: false))
            }
            if upstream.ahead > 0 && upstream.behind > 0 {
                return GitSyncPlan(pull: pull, push: .off(.push, .diverged, count: upstream.ahead))
            }
            if upstream.behind > 0 { return GitSyncPlan(pull: pull, push: .off(.push, .nothingToPush)) }
            if upstream.ahead > 0 { return GitSyncPlan(pull: pull, push: .on(.push, count: upstream.ahead)) }
            return GitSyncPlan(pull: pull, push: .off(.push, .nothingToPush))
        }
    }

    /// The one step to take, by the order of upstream's branch popover: the first that applies.
    func nextStep(pullRequest pr: GitPullRequestInfo?, gh: GitHubCLIState?) -> GitNextStep {
        let plan = syncPlan(gh: gh)

        if changes.conflicted > 0 || operation != nil {
            if changes.conflicted > 0 {
                var step = GitNextStep(
                    kind: .conflicts,
                    tone: .danger,
                    operation: operation,
                    secondary: operation?.continueCommand != nil ? .init(.copyContinue) : nil
                )
                step.count = changes.conflicted
                return step
            }
            return GitNextStep(
                kind: .continueOperation,
                tone: .warning,
                operation: operation,
                primary: operation?.continueCommand != nil ? .init(.copyContinue) : nil
            )
        }

        let dirty = changeCount
        if dirty > 0 {
            let target = remotePushTarget
            let diverged = plan.push.reason == .diverged
            var step = GitNextStep(
                kind: .commit,
                tone: .primary,
                variant: target?.setUpstream == true ? .publish : nil,
                context: pr.map { $0.state == .open && $0.checks.state == .failing } == true
                    ? .checks
                    : (target?.setUpstream == true ? .unpublished : nil),
                primary: .init(.commit),
                secondary: target.map { _ in
                    .init(.commitAndPush, enabled: !diverged, reason: diverged ? .diverged : nil)
                }
            )
            step.count = dirty
            step.insertions = changes.insertions
            step.deletions = changes.deletions
            step.checkName = pr?.failingCheckNames.first ?? ""
            return step
        }

        guard isOnBranch else {
            return GitNextStep(kind: .noBranch, tone: .quiet, variant: head.detached ? .detached : .unborn)
        }

        if plan.push.kind == .publishRepo {
            return GitNextStep(kind: .publishRepo, tone: .primary)
        }

        if let upstream, upstream.ahead > 0, upstream.behind > 0 {
            // Pull only fast-forwards and push never forces, so neither can run.
            var step = GitNextStep(kind: .diverged, tone: .warning)
            step.upstream = upstream.name
            return step
        }
        if let upstream, upstream.behind > 0 {
            var step = GitNextStep(
                kind: .pull,
                tone: .primary,
                primary: .init(.pull, enabled: plan.pull.enabled, reason: plan.pull.reason, count: upstream.behind)
            )
            step.count = upstream.behind
            step.upstream = upstream.name
            return step
        }

        if let variant = Self.blockedVariant(plan.push.reason) {
            // Several remotes, a local upstream or another name: git has nowhere to push.
            guard unpushedCount > 0 else { return afterSync(pullRequest: pr, gh: gh) }
            var step = GitNextStep(kind: .blocked, tone: .warning, variant: variant)
            step.count = unpushedCount
            step.upstream = upstream?.name ?? ""
            if case .otherName(let name) = push, !name.isEmpty { step.upstream = name }
            return step
        }

        if plan.push.kind == .publishBranch {
            if commits.isEmpty { return afterSync(pullRequest: pr, gh: gh) }
            var step = GitNextStep(
                kind: .publishBranch,
                tone: .primary,
                primary: .init(.publishBranch, enabled: plan.push.enabled, reason: plan.push.reason)
            )
            step.count = commits.count
            step.remote = remotePushTarget?.remote ?? ""
            return step
        }

        if let upstream, upstream.ahead > 0 {
            let offerPullRequest = pr == nil
                && remote?.github != nil
                && defaultBranch != nil
                && head.branch != defaultBranch
            let updatesPullRequest = pr.map { $0.state == .open || $0.state == .draft } ?? false
            var step = GitNextStep(
                kind: .push,
                tone: .primary,
                variant: offerPullRequest ? .pullRequest : (updatesPullRequest ? .updatesPullRequest : nil),
                primary: .init(.push, enabled: plan.push.enabled, reason: plan.push.reason, count: upstream.ahead),
                // The draft pushes the branch before it creates the pull request.
                secondary: offerPullRequest ? .init(.draftPullRequest) : nil
            )
            step.count = upstream.ahead
            step.remote = remotePushTarget?.remote ?? ""
            step.number = pr?.number ?? 0
            return step
        }

        return afterSync(pullRequest: pr, gh: gh)
    }

    private func afterSync(pullRequest pr: GitPullRequestInfo?, gh: GitHubCLIState?) -> GitNextStep {
        if let pr {
            let open = GitNextStep.Button(.openPullRequest)
            switch pr.state {
            case .merged:
                let onBase = defaultBranch != nil && head.branch == defaultBranch
                var step = GitNextStep(
                    kind: .merged,
                    tone: .merged,
                    primary: defaultBranch != nil && !onBase ? .init(.switchToDefault) : open,
                    secondary: defaultBranch != nil && !onBase ? open : nil
                )
                step.base = defaultBranch ?? pr.base
                step.number = pr.number
                return step
            case .closed:
                var step = GitNextStep(kind: .closed, tone: .quiet, primary: open)
                step.number = pr.number
                return step
            case .open, .draft:
                break
            }
            if pr.checks.state == .failing {
                var step = GitNextStep(kind: .fixChecks, tone: .danger, primary: open)
                step.number = pr.number
                step.count = pr.checks.failed
                step.checkName = pr.failingCheckNames.first ?? ""
                return step
            }
            if pr.isReadyToMerge {
                var step = GitNextStep(kind: .merge, tone: .success, primary: .init(.mergeOnGitHub))
                step.base = pr.base
                step.number = pr.number
                step.count = pr.checks.passed
                step.approved = pr.review == .approved
                return step
            }
            var step = GitNextStep(kind: .waiting, tone: .quiet, variant: Self.waitingVariant(pr), primary: open)
            step.base = pr.base
            step.number = pr.number
            return step
        }

        if remote?.github != nil, pullRequestHead != nil, let base = defaultBranch {
            var step = GitNextStep(
                kind: .createPullRequest,
                tone: .primary,
                variant: gh == .ready ? nil : (gh == .signedOut ? .signedOut : .noGh),
                primary: .init(.draftPullRequest),
                secondary: .init(.openCompare)
            )
            step.base = base
            return step
        }
        var step = GitNextStep(kind: .upToDate, tone: .success, variant: upstream != nil ? .synced : .empty)
        step.upstream = upstream?.name ?? ""
        step.branch = head.branch ?? ""
        return step
    }

    /// Why an open pull request cannot merge yet, in the fewest words.
    private static func waitingVariant(_ pr: GitPullRequestInfo) -> GitNextStep.Variant {
        if pr.state == .draft { return .draft }
        if pr.mergeable == .conflicting { return .conflicts }
        if pr.checks.state == .pending { return .checks }
        if pr.review == .reviewRequired { return .review }
        if pr.review == .changesRequested { return .changesRequested }
        return .blocked
    }

    /// The wording of a push git has nowhere to send, or nil when the push can go somewhere.
    private static func blockedVariant(_ reason: GitSyncReason?) -> GitNextStep.Variant? {
        switch reason {
        case .unknownRemote: return .unknownRemote
        case .localUpstream: return .localUpstream
        case .otherName: return .otherName
        case .unknownTarget: return .unknownTarget
        default: return nil
        }
    }

    /// Pull, by the upstream alone. It stays on with nothing known to pull, since a pull fetches
    /// first and may find more than the last fetch did.
    private static func pullButton(_ upstream: GitUpstreamInfo?) -> GitSyncButton {
        guard let upstream else { return .off(.pull, .noUpstream) }
        if upstream.ahead > 0 && upstream.behind > 0 { return .off(.pull, .diverged, count: upstream.behind) }
        if upstream.behind == 0 { return .on(.pull, count: 0, isNext: false) }
        return .on(.pull, count: upstream.behind)
    }

    private static func pathComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
