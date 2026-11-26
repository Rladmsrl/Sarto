import Foundation
import Testing
@testable import SartoProtocol

private actor RecordingPortTransport: SartoPortTransport {
    private let handler: @Sendable (String, JSONValue) -> String
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private(set) var requests: [(method: String, params: JSONValue)] = []

    /// `handler` answers a method and its params with the JSON text of the result.
    init(handler: @escaping @Sendable (String, JSONValue) -> String) {
        self.handler = handler
        var cont: AsyncThrowingStream<Data, Error>.Continuation!
        self.stream = AsyncThrowingStream { cont = $0 }
        self.continuation = cont
    }

    nonisolated var messages: AsyncThrowingStream<Data, Error> { stream }

    func sendJSON(_ data: Data) async throws {
        try await sendJSON(data, buffers: [])
    }

    func sendJSON(_ data: Data, buffers: [PortBuffer]) async throws {
        let request = try JSONDecoder().decode(JSONValue.self, from: data).objectValue ?? [:]
        let id = Int(request["id"]?.doubleValue ?? 0)
        let method = request["method"]?.stringValue ?? ""
        let params = request["params"] ?? .null
        requests.append((method, params))
        let result = handler(method, params)
        continuation.yield(Data("{\"type\":\"response\",\"id\":\(id),\"result\":\(result)}".utf8))
    }

    func close() async {
        continuation.finish()
    }
}

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

private let github = GitHubRepoRef(owner: "acme", repo: "app")

private func status(
    head: GitHeadInfo = GitHeadInfo(branch: "feat/x", oid: "a1", detached: false),
    upstream: GitUpstreamInfo? = GitUpstreamInfo(name: "origin/feat/x", ahead: 0, behind: 0),
    changes: GitChangesSummary = GitChangesSummary(),
    commits: [GitCommitSummary] = [],
    defaultBranch: String? = "main",
    operation: GitStoppedOperation? = nil,
    remote: GitRemoteInfo? = GitRemoteInfo(name: "origin", url: "git@github.com:acme/app.git", github: github),
    push: GitPushTarget? = .remote(GitRemotePushTarget(remote: "origin", github: github, branch: "feat/x"))
) -> GitStatusInfo {
    GitStatusInfo(
        projectPath: "/p",
        repo: GitRepoRef(root: "/p", gitDir: "/p/.git"),
        head: head,
        upstream: upstream,
        changes: changes,
        commits: commits,
        defaultBranch: defaultBranch,
        updatedAt: 0,
        stale: false,
        base: GitUpstreamInfo(name: "origin/main", ahead: 0, behind: 0),
        operation: operation,
        remote: remote,
        push: push,
        lastFetchedAt: nil
    )
}

private func run(_ name: String, _ outcome: GitCheckOutcome) -> GitCheckRun {
    GitCheckRun(name: name, outcome: outcome, url: nil, startedAt: 1, completedAt: outcome == .pending ? nil : 2)
}

private func pr(
    state: GitPullRequestState = .open,
    checks: GitPullRequestChecks = GitPullRequestChecks(state: .passing, passed: 2, runs: [run("a", .passed)]),
    review: GitReviewState? = .approved,
    mergeable: GitMergeableState = .clean,
    mergedAt: Double? = nil
) -> GitPullRequestInfo {
    GitPullRequestInfo(
        url: "https://github.com/acme/app/pull/7",
        owner: "acme",
        repo: "app",
        number: 7,
        title: "feat: x",
        state: state,
        head: "feat/x",
        base: "main",
        checks: checks,
        review: review,
        mergeable: mergeable,
        mergedAt: mergedAt
    )
}

private let failing = pr(checks: GitPullRequestChecks(
    state: .failing,
    passed: 1,
    failed: 1,
    runs: [run("lint", .failed), run("test", .passed)]
))

private let dirty = GitChangesSummary(staged: 0, unstaged: 3, untracked: 0, conflicted: 0, insertions: 9, deletions: 2)

@Suite("Git status details, pull requests and the next step")
struct GitPullRequestTests {
    // MARK: Decoding

    @Test("GitStatus decodes base, operation, remote, push and lastFetchedAt as the host sends them")
    func statusDecodesNewFields() throws {
        let json = """
        {
          "projectPath": "/Users/dev/app",
          "repo": { "root": "/Users/dev/app", "gitDir": "/Users/dev/app/.git" },
          "head": { "branch": "feat/x", "oid": "abc1234", "detached": false },
          "upstream": { "name": "origin/feat/x", "ahead": 2, "behind": 1 },
          "base": { "name": "origin/main", "ahead": 5, "behind": 0 },
          "changes": { "staged": 0, "unstaged": 1, "untracked": 0, "conflicted": 1, "insertions": 3, "deletions": 1 },
          "operation": { "kind": "rebase", "step": [2, 5] },
          "commits": [{ "oid": "abc1234", "subject": "feat: x", "authoredAt": 1700000000000, "pushed": false }],
          "remote": { "name": "origin", "url": "git@github.com:acme/app.git", "github": { "owner": "acme", "repo": "app" } },
          "defaultBranch": "main",
          "push": { "kind": "remote", "remote": "fork", "github": { "owner": "me", "repo": "app" }, "branch": "feat/x", "setUpstream": true },
          "lastFetchedAt": 1700000000500,
          "updatedAt": 1700000001000,
          "stale": false
        }
        """
        let status = try decode(GitStatusInfo.self, json)
        #expect(status.base == GitUpstreamInfo(name: "origin/main", ahead: 5, behind: 0))
        #expect(status.operation?.knownKind == .rebase)
        #expect(status.operation?.step == [2, 5])
        #expect(status.operation?.continueCommand == "git rebase --continue")
        #expect(status.remote?.github == github)
        #expect(status.push == .remote(GitRemotePushTarget(
            remote: "fork",
            github: GitHubRepoRef(owner: "me", repo: "app"),
            branch: "feat/x",
            setUpstream: true
        )))
        #expect(status.lastFetchedAt == 1_700_000_000_500)
    }

    @Test("GitStatus from a host that predates the fields decodes them as nil")
    func statusFromOlderHost() throws {
        let json = """
        {
          "projectPath": "/p",
          "repo": null,
          "head": { "branch": null, "oid": null, "detached": false },
          "upstream": null,
          "changes": { "staged": 0, "unstaged": 0, "untracked": 0, "conflicted": 0, "insertions": 0, "deletions": 0 },
          "commits": [],
          "defaultBranch": null,
          "updatedAt": 1,
          "stale": true
        }
        """
        let status = try decode(GitStatusInfo.self, json)
        #expect(status.base == nil)
        #expect(status.operation == nil)
        #expect(status.remote == nil)
        #expect(status.push == nil)
        #expect(status.lastFetchedAt == nil)
    }

    @Test("Every PushTarget kind decodes, an unknown one without failing, and round-trips")
    func pushTargetKinds() throws {
        #expect(try decode(GitPushTarget.self, #"{"kind":"noRemote"}"#) == .noRemote)
        #expect(try decode(GitPushTarget.self, #"{"kind":"unknownRemote"}"#) == .unknownRemote)
        #expect(try decode(GitPushTarget.self, #"{"kind":"localUpstream"}"#) == .localUpstream)
        #expect(try decode(GitPushTarget.self, #"{"kind":"otherName","upstream":"origin/main"}"#) == .otherName(upstream: "origin/main"))
        #expect(try decode(GitPushTarget.self, #"{"kind":"someday"}"#) == .unsupported(kind: "someday"))
        let target = GitPushTarget.remote(GitRemotePushTarget(remote: "origin", github: nil, branch: "x", setUpstream: false))
        let data = try JSONEncoder().encode(target)
        #expect(try JSONDecoder().decode(GitPushTarget.self, from: data) == target)
        #expect(try decode(GitStatusInfo.self, """
        {"projectPath":"/p","repo":null,"head":{"branch":"x","oid":"a","detached":false},"upstream":null,
         "changes":{"staged":0,"unstaged":0,"untracked":0,"conflicted":0,"insertions":0,"deletions":0},
         "commits":[],"defaultBranch":"main","push":null,"updatedAt":1,"stale":false}
        """).push == nil)
    }

    @Test("PullRequest decodes the host's full shape")
    func pullRequestDecodes() throws {
        let json = """
        {
          "url": "https://github.com/acme/app/pull/7",
          "owner": "acme",
          "repo": "app",
          "number": 7,
          "title": "feat: x",
          "state": "draft",
          "head": "feat/x",
          "base": "main",
          "checks": {
            "state": "failing", "passed": 1, "failed": 1, "pending": 0,
            "runs": [
              { "name": "lint", "outcome": "failed", "url": "https://github.com/acme/app/actions/runs/1", "startedAt": 1, "completedAt": 2 },
              { "name": "test", "outcome": "passed", "url": null, "startedAt": null, "completedAt": null }
            ]
          },
          "review": "changes_requested",
          "mergeable": "conflicting",
          "updatedAt": 1700000000000,
          "author": { "login": "sarto-builder[bot]", "name": null, "bot": true },
          "createdAt": 1690000000000,
          "mergedAt": null,
          "closedAt": null,
          "additions": 120,
          "deletions": 4,
          "changedFiles": 6
        }
        """
        let pr = try decode(GitPullRequestInfo.self, json)
        #expect(pr.number == 7)
        #expect(pr.state == .draft)
        #expect(pr.checks.state == .failing)
        #expect(pr.checks.runs.count == 2)
        #expect(pr.checks.runs[0].url == "https://github.com/acme/app/actions/runs/1")
        #expect(pr.failingCheckNames == ["lint"])
        #expect(pr.review == .changesRequested)
        #expect(pr.mergeable == .conflicting)
        #expect(pr.author == GitPullRequestAuthor(login: "sarto-builder[bot]", name: nil, bot: true))
        #expect(pr.additions == 120)
        #expect(pr.changedFiles == 6)
        #expect(pr.isReadyToMerge == false)
    }

    @Test("PullRequest tolerates missing fields and states it does not know")
    func pullRequestTolerant() throws {
        let pr = try decode(GitPullRequestInfo.self, """
        { "url": "https://github.com/acme/app/pull/8", "number": 8, "title": "x", "state": "queued",
          "checks": { "state": "skipped" }, "review": "dismissed", "mergeable": "behind" }
        """)
        #expect(pr.state == .open)
        #expect(pr.checks.state == .none)
        #expect(pr.review == .other)
        #expect(pr.mergeable == .unknown)
        #expect(pr.author == nil)
        #expect(pr.additions == 0)
    }

    @Test("GitTools decodes gh's states")
    func toolsDecode() throws {
        let tools = try decode(GitToolsInfo.self, """
        { "git": { "found": true, "version": "2.47.0" },
          "gh": { "state": "signed-out", "version": "2.60.0", "account": null } }
        """)
        #expect(tools.git.found)
        #expect(tools.gh.state == .signedOut)
        #expect(try decode(GitHubCLIState.self, #""not-installed""#) == .notInstalled)
        #expect(try decode(GitHubCLIState.self, #""ready""#) == .ready)
    }

    // MARK: RPCs

    @Test("git.pullRequestDraft sends projectPath and base and decodes the title and body")
    func pullRequestDraftRPC() async throws {
        let transport = RecordingPortTransport { method, _ in
            switch method {
            case "git.pullRequestDraft":
                return #"{"title":"feat(git): add a Git pane","body":"The pane lists the changes.\n\nMore."}"#
            case "git.createPullRequest":
                return #"{"url":"https://github.com/acme/app/pull/9","owner":"acme","repo":"app","number":9,"title":"t","state":"open","head":"feat/x","base":"main","checks":{"state":"none","passed":0,"failed":0,"pending":0,"runs":[]},"review":null,"mergeable":"unknown","updatedAt":1,"author":null,"createdAt":1,"mergedAt":null,"closedAt":null,"additions":0,"deletions":0,"changedFiles":0}"#
            case "git.currentPullRequest":
                return "null"
            default:
                return "null"
            }
        }
        let session = SartoHostSession(transport: transport)
        let draft = try await session.gitPullRequestDraft(projectPath: "/Users/dev/app", base: "main")
        #expect(draft == GitPullRequestDraft(title: "feat(git): add a Git pane", body: "The pane lists the changes.\n\nMore."))

        let created = try await session.gitCreatePullRequest(
            projectPath: "/Users/dev/app",
            title: "t",
            body: "",
            base: "main",
            draft: true
        )
        #expect(created.number == 9)
        #expect(try await session.gitCurrentPullRequest(projectPath: "/Users/dev/app") == nil)

        let requests = await transport.requests
        #expect(requests.map(\.method) == ["git.pullRequestDraft", "git.createPullRequest", "git.currentPullRequest"])
        #expect(requests[0].params == .object(["projectPath": .string("/Users/dev/app"), "base": .string("main")]))
        #expect(requests[1].params == .object([
            "projectPath": .string("/Users/dev/app"),
            "title": .string("t"),
            "body": .string(""),
            "base": .string("main"),
            "draft": .bool(true),
        ]))
        await session.close()
    }

    @Test("The pull request draft's params encode to the exact JSON the host validates")
    func pullRequestDraftParamsEncoding() throws {
        let params = SartoHostSession.pullRequestDraftParams(projectPath: "/p", base: "feat/a-b")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let text = String(decoding: try encoder.encode(params), as: UTF8.self)
        #expect(text == #"{"base":"feat\/a-b","projectPath":"\/p"}"#)
    }

    // MARK: The next step

    @Test("A stopped operation with conflicts comes before everything else")
    func conflictsFirst() {
        let step = status(
            upstream: GitUpstreamInfo(name: "origin/feat/x", ahead: 1, behind: 3),
            changes: GitChangesSummary(unstaged: 3, conflicted: 2, insertions: 9, deletions: 2),
            operation: GitStoppedOperation(kind: "rebase", step: [2, 5])
        ).nextStep(pullRequest: failing, gh: .ready)
        #expect(step.kind == .conflicts)
        #expect(step.operation?.knownKind == .rebase)
        #expect(step.count == 2)
        #expect(step.secondary?.action == .copyContinue)
    }

    @Test("An operation whose conflicts are resolved asks to continue")
    func continueOperation() {
        let step = status(operation: GitStoppedOperation(kind: "merge")).nextStep(pullRequest: nil, gh: .ready)
        #expect(step.kind == .continueOperation)
        #expect(step.primary?.action == .copyContinue)
    }

    @Test("A commit comes before a diverged branch, which then cannot push")
    func commitBeforeDiverged() {
        let step = status(
            upstream: GitUpstreamInfo(name: "origin/feat/x", ahead: 1, behind: 3),
            changes: dirty
        ).nextStep(pullRequest: nil, gh: .ready)
        #expect(step.kind == .commit)
        #expect(step.count == 3)
        #expect(step.primary?.action == .commit)
        #expect(step.secondary == GitNextStep.Button(.commitAndPush, enabled: false, reason: .diverged))
    }

    @Test("A commit on an unpublished branch publishes it")
    func commitPublishes() {
        let step = status(
            upstream: nil,
            changes: dirty,
            push: .remote(GitRemotePushTarget(remote: "origin", github: github, branch: "feat/x", setUpstream: true))
        ).nextStep(pullRequest: nil, gh: .ready)
        #expect(step.variant == .publish)
        #expect(step.context == .unpublished)
    }

    @Test("A diverged branch neither pulls nor pushes")
    func diverged() {
        let step = status(upstream: GitUpstreamInfo(name: "origin/feat/x", ahead: 1, behind: 3))
            .nextStep(pullRequest: nil, gh: .ready)
        #expect(step.kind == .diverged)
        #expect(step.upstream == "origin/feat/x")
        #expect(step.primary == nil)
    }

    @Test("A branch that is only behind pulls")
    func pull() {
        let step = status(upstream: GitUpstreamInfo(name: "origin/feat/x", ahead: 0, behind: 2))
            .nextStep(pullRequest: nil, gh: .ready)
        #expect(step.kind == .pull)
        #expect(step.primary == GitNextStep.Button(.pull, count: 2))
    }

    @Test("A push comes before the pull request, which the draft offers")
    func pushThenPullRequest() {
        let step = status(upstream: GitUpstreamInfo(name: "origin/feat/x", ahead: 2, behind: 0))
            .nextStep(pullRequest: nil, gh: .ready)
        #expect(step.kind == .push)
        #expect(step.variant == .pullRequest)
        #expect(step.primary == GitNextStep.Button(.push, count: 2))
        #expect(step.secondary?.action == .draftPullRequest)
        #expect(step.remote == "origin")

        let updates = status(upstream: GitUpstreamInfo(name: "origin/feat/x", ahead: 1, behind: 0))
            .nextStep(pullRequest: pr(), gh: .ready)
        #expect(updates.variant == .updatesPullRequest)
        #expect(updates.secondary == nil)
    }

    @Test("An unpublished branch with commits publishes, and one without waits")
    func publishBranch() {
        let unpublished = GitPushTarget.remote(GitRemotePushTarget(remote: "origin", github: github, branch: "feat/x", setUpstream: true))
        let commit = GitCommitSummary(oid: "c1", subject: "s", authoredAt: 0, pushed: false)
        let step = status(upstream: nil, commits: [commit], push: unpublished).nextStep(pullRequest: nil, gh: .ready)
        #expect(step.kind == .publishBranch)
        #expect(step.primary?.action == .publishBranch)
        #expect(step.count == 1)
        #expect(status(upstream: nil, push: unpublished).nextStep(pullRequest: nil, gh: .ready).kind == .upToDate)
    }

    @Test("A pushed branch offers the pull request, through GitHub when gh cannot")
    func createPullRequest() {
        let ready = status().nextStep(pullRequest: nil, gh: .ready)
        #expect(ready.kind == .createPullRequest)
        #expect(ready.primary?.action == .draftPullRequest)
        #expect(ready.secondary?.action == .openCompare)
        #expect(ready.base == "main")
        #expect(status().nextStep(pullRequest: nil, gh: .signedOut).variant == .signedOut)
        #expect(status().nextStep(pullRequest: nil, gh: nil).variant == .noGh)
    }

    @Test("The default branch has no pull request to offer")
    func noPullRequestOnDefault() {
        let onMain = status(
            head: GitHeadInfo(branch: "main", oid: "a1", detached: false),
            push: .remote(GitRemotePushTarget(remote: "origin", github: github, branch: "main"))
        )
        #expect(onMain.nextStep(pullRequest: nil, gh: .ready).kind == .upToDate)
        #expect(onMain.compareURL() == nil)
    }

    @Test("Failing checks open the pull request")
    func fixChecks() {
        let step = status().nextStep(pullRequest: failing, gh: .ready)
        #expect(step.kind == .fixChecks)
        #expect(step.primary?.action == .openPullRequest)
        #expect(step.checkName == "lint")
        #expect(step.number == 7)
    }

    @Test("A pull request that cannot merge yet waits, and says why")
    func waiting() {
        let pending = pr(checks: GitPullRequestChecks(state: .pending, passed: 1, pending: 1, runs: [run("a", .pending)]))
        #expect(status().nextStep(pullRequest: pending, gh: .ready).kind == .waiting)
        #expect(status().nextStep(pullRequest: pending, gh: .ready).variant == .checks)
        #expect(status().nextStep(pullRequest: pr(state: .draft), gh: .ready).variant == .draft)
        #expect(status().nextStep(pullRequest: pr(review: .reviewRequired), gh: .ready).variant == .review)
        #expect(status().nextStep(pullRequest: pr(mergeable: .conflicting), gh: .ready).variant == .conflicts)
    }

    @Test("A passing, approved pull request with no conflicts merges on GitHub")
    func merge() {
        let step = status().nextStep(pullRequest: pr(), gh: .ready)
        #expect(step.kind == .merge)
        #expect(step.primary?.action == .mergeOnGitHub)
        #expect(step.approved)
    }

    @Test("After a merge the next step goes back to the default branch")
    func merged() {
        let merged = pr(state: .merged, mergedAt: 5)
        let step = status().nextStep(pullRequest: merged, gh: .ready)
        #expect(step.kind == .merged)
        #expect(step.primary?.action == .switchToDefault)
        #expect(step.secondary?.action == .openPullRequest)
        let onMain = status(head: GitHeadInfo(branch: "main", oid: "a1", detached: false))
        #expect(onMain.nextStep(pullRequest: merged, gh: .ready).primary?.action == .openPullRequest)
    }

    @Test("A repository with no remote asks to be published, with no button here")
    func publishRepo() {
        let none = status(upstream: nil, remote: nil, push: .noRemote)
        #expect(none.nextStep(pullRequest: nil, gh: .ready).kind == .publishRepo)
        #expect(none.syncPlan(gh: .ready).push == GitSyncButton(kind: .publishRepo, count: 0, enabled: true, isNext: true, reason: nil))
        #expect(none.syncPlan(gh: .signedOut).push.reason == .ghSignedOut)
    }

    @Test("A detached head has nothing to do")
    func detached() {
        let step = status(head: GitHeadInfo(branch: nil, oid: "a1", detached: true)).nextStep(pullRequest: nil, gh: nil)
        #expect(step.kind == .noBranch)
        #expect(step.variant == .detached)
        #expect(step.primary == nil)
    }

    @Test("Commits git has nowhere to push are blocked, and nothing to push is not")
    func blocked() {
        let ahead = GitUpstreamInfo(name: "origin/feat/x", ahead: 2, behind: 0)
        let several = status(upstream: ahead, push: .unknownRemote).nextStep(pullRequest: nil, gh: .ready)
        #expect(several.kind == .blocked)
        #expect(several.variant == .unknownRemote)
        let other = status(upstream: ahead, push: .otherName(upstream: "origin/main")).nextStep(pullRequest: nil, gh: .ready)
        #expect(other.variant == .otherName)
        #expect(other.upstream == "origin/main")
        #expect(status(push: .localUpstream).nextStep(pullRequest: nil, gh: .ready).kind == .upToDate)
    }

    @Test("A host that does not say where push goes still commits and pulls, and never pushes")
    func olderHost() {
        let old = status(upstream: GitUpstreamInfo(name: "origin/feat/x", ahead: 2, behind: 0), remote: nil, push: nil)
        let step = old.nextStep(pullRequest: nil, gh: nil)
        #expect(step.kind == .blocked)
        #expect(step.variant == .unknownTarget)
        let behind = status(upstream: GitUpstreamInfo(name: "origin/feat/x", ahead: 0, behind: 1), remote: nil, push: nil)
        #expect(behind.nextStep(pullRequest: nil, gh: nil).kind == .pull)
        let commitOnly = status(changes: dirty, remote: nil, push: nil).nextStep(pullRequest: nil, gh: nil)
        #expect(commitOnly.kind == .commit)
        #expect(commitOnly.secondary == nil)
    }

    @Test("The compare URL names the base and the head, a fork's as owner:branch, and prefills the text")
    func compareURL() {
        #expect(status().compareURL()?.absoluteString == "https://github.com/acme/app/compare/main...feat%2Fx?expand=1")
        let fork = status(push: .remote(GitRemotePushTarget(
            remote: "fork",
            github: GitHubRepoRef(owner: "me", repo: "app"),
            branch: "feat/x"
        )))
        #expect(fork.compareURL(base: "release/1")?.absoluteString
            == "https://github.com/acme/app/compare/release%2F1...me:feat%2Fx?expand=1")
        let prefilled = status().compareURL(title: "feat: a+b & c", body: "Why?\nBecause.")
        #expect(prefilled?.absoluteString
            == "https://github.com/acme/app/compare/main...feat%2Fx?expand=1&title=feat:%20a%2Bb%20%26%20c&body=Why?%0ABecause.")
        let unpublished = status(push: .remote(GitRemotePushTarget(remote: "origin", github: github, branch: "feat/x", setUpstream: true)))
        #expect(unpublished.compareURL() == nil)
    }
}
