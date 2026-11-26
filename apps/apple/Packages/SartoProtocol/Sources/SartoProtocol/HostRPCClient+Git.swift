import Foundation

// MARK: - Git sync and pull request RPCs (src/shared/agent-host.ts HostContract)

extension SartoHostSession {
    /// The params of `git.pullRequestDraft`.
    static func pullRequestDraftParams(projectPath: String, base: String) -> JSONValue {
        .object([
            "projectPath": .string(projectPath),
            "base": .string(base),
        ])
    }

    /// The params of `git.createPullRequest`.
    static func createPullRequestParams(
        projectPath: String,
        title: String,
        body: String,
        base: String,
        draft: Bool
    ) -> JSONValue {
        .object([
            "projectPath": .string(projectPath),
            "title": .string(title),
            "body": .string(body),
            "base": .string(base),
            "draft": .bool(draft),
        ])
    }

    /// A pull request's title and description for the branch against `base`, written by the
    /// project's preferred agent from the branch's commits and files. Hosts that predate the
    /// method reject it as an unknown method.
    public func gitPullRequestDraft(projectPath: String, base: String) async throws -> GitPullRequestDraft {
        try await request(
            "git.pullRequestDraft",
            params: Self.pullRequestDraftParams(projectPath: projectPath, base: base),
            as: GitPullRequestDraft.self
        )
    }

    public func gitFetch(projectPath: String) async throws -> GitOperationResult {
        try await request("git.fetch", params: .object(["projectPath": .string(projectPath)]), as: GitOperationResult.self)
    }

    /// Pulls with `--ff-only`.
    public func gitPull(projectPath: String) async throws -> GitOperationResult {
        try await request("git.pull", params: .object(["projectPath": .string(projectPath)]), as: GitOperationResult.self)
    }

    /// Pushes the branch to `remote`'s `branch`; publishes it when it has no upstream.
    public func gitPush(projectPath: String, remote: String, branch: String) async throws -> GitOperationResult {
        try await request("git.push", params: .object([
            "projectPath": .string(projectPath),
            "remote": .string(remote),
            "branch": .string(branch),
        ]), as: GitOperationResult.self)
    }

    /// Pushes the branch, which has no upstream yet, to one of the remotes and tracks it.
    public func gitPublishBranch(projectPath: String, remote: String) async throws -> GitOperationResult {
        try await request("git.publishBranch", params: .object([
            "projectPath": .string(projectPath),
            "remote": .string(remote),
        ]), as: GitOperationResult.self)
    }

    public func gitCreatePullRequest(
        projectPath: String,
        title: String,
        body: String,
        base: String,
        draft: Bool
    ) async throws -> GitPullRequestInfo {
        try await request(
            "git.createPullRequest",
            params: Self.createPullRequestParams(
                projectPath: projectPath,
                title: title,
                body: body,
                base: base,
                draft: draft
            ),
            as: GitPullRequestInfo.self
        )
    }

    /// The pull request of the branch that is checked out, or nil when it has none.
    public func gitCurrentPullRequest(projectPath: String) async throws -> GitPullRequestInfo? {
        try await request(
            "git.currentPullRequest",
            params: .object(["projectPath": .string(projectPath)]),
            as: GitPullRequestInfo?.self
        )
    }

    public func gitTools() async throws -> GitToolsInfo {
        try await request("git.tools", params: .null, as: GitToolsInfo.self)
    }
}
