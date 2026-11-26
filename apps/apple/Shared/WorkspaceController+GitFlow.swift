import Foundation
import SartoProtocol
import PrismDesign

/// A pull request being written: the base it goes into, its text and how drafting it went.
public struct PullRequestDraftForm: Equatable, Sendable {
    public let projectPath: String
    /// The branch the pull request is from.
    public let head: String
    public var base: String
    public var title: String = ""
    public var body: String = ""
    /// The user typed into the field, so a draft that lands later leaves it alone.
    public var titleEdited = false
    public var bodyEdited = false
    /// The base the last draft was asked for, so each base is drafted once.
    public var draftedFor: String?
    public var isDrafting = false
    public var draftError: String?
    public var openAsDraft = false
    public var isCreating = false
    public var createError: String?

    public init(projectPath: String, head: String, base: String) {
        self.projectPath = projectPath
        self.head = head
        self.base = base
    }

    /// The agent's draft is what the fields hold.
    public var isDrafted: Bool {
        draftedFor == base && !isDrafting && draftError == nil && !title.isEmpty
    }
}

/// A git write running through the host, one at a time.
public enum GitFlowActivity: Equatable, Sendable {
    case fetch
    case step(GitNextStep.Action)
}

// Git writes past a commit (fetch, pull, push, switch) and pull requests. They all go through the
// host and never fall back to this Mac's git: a remote workspace's paths name another disk, and a
// local one without a host has no gh.
extension WorkspaceController {
    /// The one step the branch leads with, or nil outside a repository.
    public var gitNextStep: GitNextStep? {
        guard let status = gitStatus, status.repo != nil else { return nil }
        return status.nextStep(pullRequest: currentPullRequest, gh: gitTools?.gh.state)
    }

    /// Git writes past a commit need the host.
    public var canRunHostGit: Bool { hostSession != nil }

    /// A pull request can be drafted from a branch other than the default one.
    public var canDraftPullRequest: Bool {
        guard hostSession != nil, let status = gitStatus, status.repo != nil, status.isOnBranch,
              let base = status.defaultBranch
        else { return false }
        return status.head.branch != base
    }

    func resetGitFlowState(keepTools: Bool) {
        currentPullRequest = nil
        if !keepTools { gitTools = nil }
        runningGitActivity = nil
        gitFlowError = nil
        pullRequestForm = nil
        isPullRequestDraftPresented = false
        pullRequestBaseChoices = []
    }

    /// Reads the branch's pull request and gh's state after a status, without holding the status up.
    func schedulePullRequestRefresh(for status: GitStatusInfo, generation: UInt64) {
        guard let host = hostSession else { return }
        let projectPath = activeProjectPath
        Task { [weak self] in
            let tools = try? await host.gitTools()
            let wantsPullRequest = status.remote?.github != nil && status.isOnBranch
            var pullRequest: GitPullRequestInfo?
            var pullRequestFailed = false
            if wantsPullRequest {
                do {
                    pullRequest = try await host.gitCurrentPullRequest(projectPath: projectPath)
                } catch {
                    pullRequestFailed = true
                }
            }
            guard let self, self.projectGeneration == generation, self.activeProjectPath == projectPath else { return }
            if let tools, tools != self.gitTools { self.gitTools = tools }
            if pullRequestFailed {
                // gh failing now says nothing about a pull request already known for this branch.
                if self.currentPullRequest?.head != status.head.branch { self.currentPullRequest = nil }
            } else if pullRequest != self.currentPullRequest {
                self.currentPullRequest = pullRequest
            }
        }
    }

    // MARK: Sync

    public func fetchGit() async {
        await runHostGitWrite(.fetch, notice: l10n.tr("git.notice.fetched")) { host, path in
            try await host.gitFetch(projectPath: path)
        }
    }

    public func pullGit() async {
        let notice = l10n.tr("git.notice.pulled", gitStatus?.upstream?.name ?? "")
        await runHostGitWrite(.step(.pull), notice: notice) { host, path in
            try await host.gitPull(projectPath: path)
        }
    }

    /// Pushes the branch, or publishes it to where push goes when it has no upstream yet.
    public func pushGit() async {
        guard let target = gitStatus?.remotePushTarget else {
            gitFlowError = l10n.tr("git.next.blocked.title")
            return
        }
        if target.setUpstream {
            let notice = l10n.tr("git.notice.published", target.remote)
            await runHostGitWrite(.step(.publishBranch), notice: notice) { host, path in
                try await host.gitPublishBranch(projectPath: path, remote: target.remote)
            }
        } else {
            let notice = l10n.tr("git.notice.pushed", target.remote)
            await runHostGitWrite(.step(.push), notice: notice) { host, path in
                try await host.gitPush(projectPath: path, remote: target.remote, branch: target.branch)
            }
        }
    }

    /// Commits the ticked files, then pushes them when the commit went through.
    public func commitAndPush() async {
        guard runningGitActivity == nil else { return }
        runningGitActivity = .step(.commitAndPush)
        let committed = await commitSelectedChanges()
        if runningGitActivity == .step(.commitAndPush) { runningGitActivity = nil }
        guard committed else { return }
        await pushGit()
    }

    public func switchToDefaultBranch() async {
        guard let base = gitStatus?.defaultBranch else { return }
        await runHostGitWrite(.step(.switchToDefault), notice: l10n.tr("git.notice.switched", base)) { host, path in
            try await host.gitSwitchBranch(projectPath: path, branch: base, create: false)
        }
    }

    /// Runs one write through the host and refreshes after it; a failure is shown with the next step.
    private func runHostGitWrite(
        _ activity: GitFlowActivity,
        notice: String,
        _ body: @MainActor (SartoHostSession, String) async throws -> GitOperationResult
    ) async {
        guard let host = hostSession else {
            gitFlowError = notConnectedNote
            return
        }
        guard runningGitActivity == nil else { return }
        let generation = projectGeneration
        let projectPath = activeProjectPath
        runningGitActivity = activity
        gitFlowError = nil
        defer {
            if projectGeneration == generation { runningGitActivity = nil }
        }
        do {
            let result = try await body(host, projectPath)
            guard projectGeneration == generation else { return }
            gitStatus = result.status
            gitNotice = notice
        } catch {
            guard projectGeneration == generation else { return }
            gitFlowError = error.localizedDescription
            return
        }
        await refreshGit()
    }

    // MARK: Pull requests

    /// Opens the pull request draft for the checked-out branch, and asks the agent to write it.
    public func presentPullRequestDraft() {
        guard let status = gitStatus, status.repo != nil else { return }
        let head = status.head.branch ?? ""
        if pullRequestForm?.projectPath != activeProjectPath || pullRequestForm?.head != head {
            pullRequestForm = PullRequestDraftForm(
                projectPath: activeProjectPath,
                head: head,
                base: status.defaultBranch ?? ""
            )
        }
        pullRequestForm?.createError = nil
        isPullRequestDraftPresented = true
        Task { [weak self] in await self?.loadPullRequestBaseChoices() }
        Task { [weak self] in await self?.draftPullRequest() }
    }

    public func setPullRequestBase(_ base: String) {
        guard var form = pullRequestForm, form.base != base else { return }
        form.base = base
        form.createError = nil
        pullRequestForm = form
        Task { [weak self] in await self?.draftPullRequest() }
    }

    public func setPullRequestTitle(_ title: String) {
        guard pullRequestForm != nil, pullRequestForm?.title != title else { return }
        pullRequestForm?.title = title
        pullRequestForm?.titleEdited = true
    }

    public func setPullRequestBody(_ body: String) {
        guard pullRequestForm != nil, pullRequestForm?.body != body else { return }
        pullRequestForm?.body = body
        pullRequestForm?.bodyEdited = true
    }

    /// Asks the agent for a title and description once for each base; `again` replaces what the
    /// fields hold, the user's typing included.
    public func draftPullRequest(again: Bool = false) async {
        guard var form = pullRequestForm else { return }
        let base = form.base
        let branch = gitStatus?.head.branch
        guard !base.isEmpty, base != branch else { return }
        if !again && form.draftedFor == base { return }
        guard let host = hostSession else {
            form.draftError = notConnectedNote
            pullRequestForm = form
            return
        }
        form.draftedFor = base
        form.isDrafting = true
        form.draftError = nil
        if again {
            form.titleEdited = false
            form.bodyEdited = false
        }
        pullRequestForm = form
        let projectPath = form.projectPath
        // The form outlives the sheet, so only one that still drafts this base takes the answer.
        func current() -> PullRequestDraftForm? {
            guard let now = pullRequestForm, now.projectPath == projectPath, now.draftedFor == base else { return nil }
            return now
        }
        do {
            let draft = try await host.gitPullRequestDraft(projectPath: projectPath, base: base)
            guard var now = current() else { return }
            if !now.titleEdited { now.title = draft.title }
            if !now.bodyEdited { now.body = draft.body }
            now.isDrafting = false
            pullRequestForm = now
        } catch {
            guard var now = current() else { return }
            now.isDrafting = false
            now.draftError = error.localizedDescription
            pullRequestForm = now
        }
    }

    func loadPullRequestBaseChoices() async {
        guard let host = hostSession, let status = gitStatus else { return }
        let projectPath = activeProjectPath
        let generation = projectGeneration
        let head = status.head.branch
        let names = (try? await host.gitBranches(projectPath: projectPath))?.branches.map(\.name) ?? []
        guard projectGeneration == generation else { return }
        var seen = Set<String>()
        let ordered = ([status.defaultBranch].compactMap { $0 } + names)
            .filter { $0 != head && seen.insert($0).inserted }
        if ordered != pullRequestBaseChoices { pullRequestBaseChoices = ordered }
    }

    /// Unpublished, or with commits the remote does not have yet, the branch is pushed first.
    public var pullRequestPushesFirst: Bool {
        guard let status = gitStatus, let target = status.remotePushTarget else { return false }
        return target.setUpstream || (status.upstream?.ahead ?? 0) > 0
    }

    /// The host's gh can open the pull request from here.
    public var canCreatePullRequest: Bool {
        guard hostSession != nil, gitTools?.gh.state == .ready,
              let status = gitStatus, status.remote?.github != nil,
              let target = status.remotePushTarget, target.github != nil,
              let form = pullRequestForm, !form.isCreating
        else { return false }
        let base = form.base.trimmingCharacters(in: .whitespacesAndNewlines)
        return !form.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !base.isEmpty
            && base != status.head.branch
    }

    /// GitHub's compare page for the draft, prefilled with its text while the address stays short
    /// enough for a browser to open; nil until the branch is on GitHub.
    public var pullRequestCompareURL: URL? {
        guard let status = gitStatus else { return nil }
        let form = pullRequestForm
        let base = form.map { $0.base.isEmpty ? nil : $0.base } ?? nil
        let title = form?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = form?.body
        if let full = status.compareURL(base: base, title: title, body: body),
           full.absoluteString.utf8.count <= 6_000 {
            return full
        }
        return status.compareURL(base: base, title: title)
    }

    /// Pushes when it has to, then opens the pull request; its page's URL once it exists.
    public func createPullRequest() async -> URL? {
        guard var form = pullRequestForm, let host = hostSession, let status = gitStatus else { return nil }
        guard let target = status.remotePushTarget else {
            pullRequestForm?.createError = l10n.tr("git.prDraft.notOnGitHub")
            return nil
        }
        let projectPath = form.projectPath
        let generation = projectGeneration
        form.isCreating = true
        form.createError = nil
        pullRequestForm = form
        func fail(_ message: String) {
            guard projectGeneration == generation else { return }
            pullRequestForm?.isCreating = false
            pullRequestForm?.createError = message
        }
        do {
            var latest = status
            if target.setUpstream {
                latest = try await host.gitPublishBranch(projectPath: projectPath, remote: target.remote).status
            } else if (status.upstream?.ahead ?? 0) > 0 {
                latest = try await host.gitPush(projectPath: projectPath, remote: target.remote, branch: target.branch).status
            }
            guard projectGeneration == generation else { return nil }
            gitStatus = latest
            guard latest.pullRequestHead != nil else {
                fail(l10n.tr("git.prDraft.notOnGitHub"))
                return nil
            }
            let created = try await host.gitCreatePullRequest(
                projectPath: projectPath,
                title: form.title.trimmingCharacters(in: .whitespacesAndNewlines),
                body: form.body,
                base: form.base.trimmingCharacters(in: .whitespacesAndNewlines),
                draft: form.openAsDraft
            )
            guard projectGeneration == generation else { return nil }
            currentPullRequest = created
            pullRequestForm = nil
            isPullRequestDraftPresented = false
            gitNotice = l10n.tr("git.notice.prCreated", created.number)
            // No refresh here: the host polls gh for the new pull request in the background, and
            // asking before that lands would read the branch as having none.
            return URL(string: created.url)
        } catch {
            fail(error.localizedDescription)
            return nil
        }
    }

    /// Closes the sheet and forgets the draft.
    public func discardPullRequestDraft() {
        isPullRequestDraftPresented = false
        pullRequestForm = nil
    }
}
