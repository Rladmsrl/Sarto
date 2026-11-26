import SartoProtocol
import PrismDesign
import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

// The Git pane's lead: the branch's next step, its sync with the upstream and its pull request,
// and the pull request draft (upstream's next-step-card.tsx, pane-top.tsx and create-pr-form.tsx).

enum GitFlowClipboard {
    @MainActor
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = text
        #endif
    }
}

// MARK: - Wording

extension GitNextStep {
    /// Picks the `.one` or `.other` form of a key by `count`.
    fileprivate static func counted(_ l10n: PrismL10n, _ key: String, _ count: Int, _ args: CVarArg...) -> String {
        let format = l10n.tr(count == 1 ? "\(key).one" : "\(key).other")
        return String(format: format, locale: l10n.language.resolvedLocale, arguments: [count] + args)
    }

    fileprivate func operationName(_ l10n: PrismL10n) -> String {
        switch operation?.knownKind {
        case .merge: return l10n.tr("git.next.operation.merge")
        case .rebase: return l10n.tr("git.next.operation.rebase")
        case .cherryPick: return l10n.tr("git.next.operation.cherryPick")
        case .revert: return l10n.tr("git.next.operation.revert")
        case nil: return operation?.kind ?? ""
        }
    }

    var iconName: String {
        switch kind {
        case .conflicts: return "exclamationmark.triangle.fill"
        case .continueOperation: return "pause.circle"
        case .commit: return "square.and.pencil"
        case .noBranch: return "arrow.triangle.branch"
        case .publishRepo, .publishBranch: return "icloud.and.arrow.up"
        case .blocked: return "nosign"
        case .diverged: return "arrow.triangle.swap"
        case .pull: return "arrow.down.circle"
        case .push: return "arrow.up.circle"
        case .createPullRequest: return "arrow.triangle.pull"
        case .fixChecks: return "xmark.octagon"
        case .waiting: return "clock"
        case .merge: return "arrow.triangle.merge"
        case .merged: return "checkmark.seal"
        case .closed: return "xmark.circle"
        case .upToDate: return "checkmark.circle"
        }
    }

    func title(_ l10n: PrismL10n) -> String {
        switch kind {
        case .conflicts:
            if operation != nil {
                let format = l10n.tr(count == 1 ? "git.next.conflicts.title.one" : "git.next.conflicts.title.other")
                return String(format: format, locale: l10n.language.resolvedLocale, operationName(l10n), count)
            }
            return Self.counted(l10n, "git.next.conflicts.titleLoose", count)
        case .continueOperation: return l10n.tr("git.next.continue.title", operationName(l10n))
        case .commit: return Self.counted(l10n, "git.next.commit.title", count)
        case .noBranch:
            return l10n.tr(variant == .detached ? "git.next.noBranch.detached.title" : "git.next.noBranch.unborn.title")
        case .publishRepo: return l10n.tr("git.next.publishRepo.title")
        case .blocked: return l10n.tr("git.next.blocked.title")
        case .diverged: return l10n.tr("git.next.diverged.title", upstream)
        case .pull: return Self.counted(l10n, "git.next.pull.title", count)
        case .push: return Self.counted(l10n, "git.next.push.title", count, remote)
        case .publishBranch: return l10n.tr("git.next.publishBranch.title", remote)
        case .createPullRequest: return l10n.tr("git.next.createPr.title")
        case .fixChecks:
            return count == 1 && !checkName.isEmpty
                ? l10n.tr("git.next.fixChecks.title.one", checkName)
                : l10n.tr("git.next.fixChecks.title.other", count)
        case .waiting:
            let key = "git.next.waiting.\((variant ?? .blocked).rawValue).title"
            return variant == .conflicts ? l10n.tr(key, base) : l10n.tr(key)
        case .merge: return l10n.tr("git.next.merge.title")
        case .merged: return l10n.tr("git.next.merged.title", base)
        case .closed: return l10n.tr("git.next.closed.title")
        case .upToDate: return l10n.tr("git.next.upToDate.title")
        }
    }

    func note(_ l10n: PrismL10n) -> String? {
        switch kind {
        case .conflicts: return l10n.tr("git.next.conflicts.note")
        case .continueOperation: return l10n.tr("git.next.continue.note")
        case .commit:
            var parts = [l10n.tr("git.next.commit.note")]
            switch context {
            case .checks: parts.append(l10n.tr("git.next.commit.checks", checkName))
            case .unpublished: parts.append(l10n.tr("git.next.commit.unpublished"))
            case nil: break
            }
            return parts.joined(separator: " · ")
        case .noBranch:
            return l10n.tr(variant == .detached ? "git.next.noBranch.detached.note" : "git.next.noBranch.unborn.note")
        case .publishRepo: return l10n.tr("git.next.publishRepo.note")
        case .blocked:
            switch variant {
            case .unknownRemote: return l10n.tr("git.next.blocked.unknownRemote")
            case .localUpstream: return l10n.tr("git.next.blocked.localUpstream")
            case .otherName: return l10n.tr("git.next.blocked.otherName", upstream)
            default: return l10n.tr("git.next.blocked.unknownTarget")
            }
        case .diverged: return l10n.tr("git.next.diverged.note")
        case .pull: return l10n.tr("git.next.pull.note", upstream)
        case .push:
            switch variant {
            case .pullRequest: return l10n.tr("git.next.push.note.pr")
            case .updatesPullRequest: return l10n.tr("git.next.push.note.updatesPr", number)
            default: return l10n.tr("git.next.push.note.plain")
            }
        case .publishBranch: return Self.counted(l10n, "git.next.publishBranch.note", count)
        case .createPullRequest:
            switch variant {
            case .signedOut: return l10n.tr("git.next.createPr.note.signedOut", base)
            case .noGh: return l10n.tr("git.next.createPr.note.noGh", base)
            default: return l10n.tr("git.next.createPr.note.ready", base)
            }
        case .fixChecks: return l10n.tr("git.next.fixChecks.note", number)
        case .waiting: return l10n.tr("git.next.waiting.\((variant ?? .blocked).rawValue).note")
        case .merge:
            var parts: [String] = []
            if count > 0 { parts.append(Self.counted(l10n, "git.next.merge.checks", count)) }
            if approved { parts.append(l10n.tr("git.next.merge.approved")) }
            parts.append(l10n.tr("git.next.merge.clean", base))
            return parts.joined(separator: " · ")
        case .merged: return l10n.tr("git.next.merged.note", base)
        case .closed: return l10n.tr("git.next.closed.note")
        case .upToDate:
            if variant == .synced { return l10n.tr("git.next.upToDate.synced", upstream) }
            return branch.isEmpty ? nil : l10n.tr("git.next.upToDate.empty", branch)
        }
    }

    func label(for button: Button, _ l10n: PrismL10n) -> String {
        switch button.action {
        case .commit: return l10n.tr("git.next.action.commit")
        case .commitAndPush:
            return l10n.tr(variant == .publish ? "git.next.action.commitAndPublish" : "git.next.action.commitAndPush")
        case .copyContinue: return l10n.tr("git.next.action.copyContinue", operation?.continueCommand ?? "")
        case .pull: return l10n.tr("git.next.action.pull", button.count)
        case .push: return Self.counted(l10n, "git.next.action.push", button.count)
        case .publishBranch: return l10n.tr("git.next.action.publishBranch")
        case .draftPullRequest: return l10n.tr("git.next.action.draftPr")
        case .openCompare: return l10n.tr("git.next.action.openCompare")
        case .openPullRequest: return l10n.tr("git.next.action.openPr")
        case .mergeOnGitHub: return l10n.tr("git.next.action.mergeOnGitHub")
        case .switchToDefault: return l10n.tr("git.next.action.switchTo", base)
        }
    }

    func icon(for action: Action) -> String? {
        switch action {
        case .commit, .commitAndPush: return nil
        case .copyContinue: return "doc.on.doc"
        case .pull: return "arrow.down"
        case .push, .publishBranch: return "arrow.up"
        case .draftPullRequest: return "sparkles"
        case .openCompare, .openPullRequest, .mergeOnGitHub: return "arrow.up.right"
        case .switchToDefault: return "arrow.triangle.branch"
        }
    }
}

extension GitSyncReason {
    func text(_ l10n: PrismL10n) -> String {
        switch self {
        case .diverged: return l10n.tr("git.next.reason.diverged")
        default: return l10n.tr("git.next.reason.unavailable")
        }
    }
}

// MARK: - Next step card

/// The one step the branch leads with, and the button that takes it.
public struct GitNextStepCard: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    @Environment(\.prismMotionTier) private var motionTier
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    @Bindable public var workspace: WorkspaceController
    /// Smaller, for the branch popover, where a commit or a draft opens the Git pane instead.
    public var compact: Bool
    /// Puts the cursor in the commit message, for a commit with no message yet.
    public var onFocusCommitMessage: (() -> Void)?
    /// Shows the Git pane, for steps the popover cannot take itself.
    public var onOpenGitPane: (() -> Void)?

    public init(
        workspace: WorkspaceController,
        compact: Bool = false,
        onFocusCommitMessage: (() -> Void)? = nil,
        onOpenGitPane: (() -> Void)? = nil
    ) {
        self.workspace = workspace
        self.compact = compact
        self.onFocusCommitMessage = onFocusCommitMessage
        self.onOpenGitPane = onOpenGitPane
    }

    public var body: some View {
        if let step = workspace.gitNextStep {
            card(step)
                .animation(PrismSpringSpec.snappy.animation(tier: motionTier, reduceMotion: reduceMotion), value: step.kind)
        }
    }

    private func card(_ step: GitNextStep) -> some View {
        let tone = toneColor(step.tone)
        return VStack(alignment: .leading, spacing: compact ? 8 : 9) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: step.iconName)
                    .font(.system(size: compact ? 11 : 12, weight: .semibold))
                    .foregroundStyle(tone)
                    .frame(width: compact ? 22 : 24, height: compact ? 22 : 24)
                    .background(Circle().fill(tone.opacity(tokens.palette.isDark ? 0.16 : 0.12)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title(l10n))
                        .font(.system(size: compact ? 12 : 12.5, weight: .semibold))
                        .foregroundStyle(tokens.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                    if let note = step.note(l10n) {
                        Text(note)
                            .font(.system(size: compact ? 10.5 : 11))
                            .foregroundStyle(tokens.mutedForeground)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if step.kind == .commit, step.insertions + step.deletions > 0 {
                    DiffCountStatText(insertions: step.insertions, deletions: step.deletions, fontSize: 10.5, showZero: false)
                }
            }
            .accessibilityElement(children: .combine)

            if step.primary != nil || step.secondary != nil {
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    if let secondary = step.secondary {
                        actionButton(secondary, in: step, prominent: step.primary == nil && secondary.enabled && step.kind != .conflicts)
                    }
                    if let primary = step.primary {
                        actionButton(primary, in: step, prominent: true)
                    }
                }
            }

            if let error = workspace.gitFlowError {
                Text(error)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(tokens.danger)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .padding(compact ? 9 : 10)
        .background(
            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                .fill(tokens.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                .strokeBorder(step.tone == .quiet ? tokens.borderEtched : tone.opacity(0.32), lineWidth: 1)
        )
    }

    private func actionButton(_ button: GitNextStep.Button, in step: GitNextStep, prominent: Bool) -> some View {
        let running = workspace.runningGitActivity == .step(button.action)
        let needsHost = Self.needsHost(button.action)
        let available = button.enabled
            && workspace.runningGitActivity == nil
            && (!needsHost || workspace.canRunHostGit)
        let fill = tokens.palette.isDark ? Color(hex: 0xF2F3F7) : Color(hex: 0x14151B)
        let onFill = tokens.palette.isDark ? Color(hex: 0x0E0F14) : Color.white
        return Button {
            perform(button.action, step: step)
        } label: {
            HStack(spacing: 4) {
                if running {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                        .frame(width: 10, height: 10)
                } else if let icon = step.icon(for: button.action) {
                    Image(systemName: icon)
                        .font(.system(size: 9.5, weight: .bold))
                }
                Text(step.label(for: button, l10n))
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(prominent ? onFill : tokens.secondaryForeground)
            .padding(.horizontal, 11)
            .padding(.vertical, 5.5)
            .background(Capsule().fill(prominent ? fill : tokens.hoverWash))
            .overlay(Capsule().strokeBorder(prominent ? Color.clear : tokens.borderEtched, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(available || running ? 1 : 0.45)
        .help(helpText(button, needsHost: needsHost))
    }

    private func helpText(_ button: GitNextStep.Button, needsHost: Bool) -> String {
        if needsHost && !workspace.canRunHostGit { return workspace.notConnectedNote }
        if !button.enabled, let reason = button.reason { return reason.text(l10n) }
        return ""
    }

    private static func needsHost(_ action: GitNextStep.Action) -> Bool {
        switch action {
        case .commit, .copyContinue, .openCompare, .openPullRequest, .mergeOnGitHub: return false
        case .commitAndPush, .pull, .push, .publishBranch, .draftPullRequest, .switchToDefault: return true
        }
    }

    private func perform(_ action: GitNextStep.Action, step: GitNextStep) {
        let hasMessage = !workspace.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch action {
        case .commit:
            if compact || !hasMessage {
                if compact { onOpenGitPane?() } else { onFocusCommitMessage?() }
            } else {
                Task { await workspace.commitSelectedChanges() }
            }
        case .commitAndPush:
            if compact || !hasMessage {
                if compact { onOpenGitPane?() } else { onFocusCommitMessage?() }
            } else {
                Task { await workspace.commitAndPush() }
            }
        case .copyContinue:
            if let command = step.operation?.continueCommand {
                GitFlowClipboard.copy(command)
                workspace.gitNotice = l10n.tr("git.notice.copied", command)
            }
        case .pull:
            Task { await workspace.pullGit() }
        case .push, .publishBranch:
            Task { await workspace.pushGit() }
        case .draftPullRequest:
            if compact, let onOpenGitPane {
                onOpenGitPane()
                // Lets the popover close before the sheet opens on the window under it.
                Task { @MainActor in
                    await Task.yield()
                    workspace.presentPullRequestDraft()
                }
            } else {
                workspace.presentPullRequestDraft()
            }
        case .openCompare:
            if let url = workspace.gitStatus?.compareURL() { openURL(url) }
        case .openPullRequest, .mergeOnGitHub:
            if let raw = workspace.currentPullRequest?.url, let url = URL(string: raw) { openURL(url) }
        case .switchToDefault:
            Task { await workspace.switchToDefaultBranch() }
        }
    }

    private func toneColor(_ tone: GitNextStep.Tone) -> Color {
        switch tone {
        case .primary: return tokens.primary
        case .danger: return tokens.danger
        case .warning: return tokens.warning
        case .success: return tokens.success
        case .merged: return tokens.prismIris
        case .quiet: return tokens.mutedForeground
        }
    }
}

// MARK: - Sync and pull request badges

/// How the branch stands against its upstream, and its pull request, for the pane's header.
public struct GitBranchSyncBadges: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    @Environment(\.openURL) private var openURL

    public let status: GitStatusInfo
    public let pullRequest: GitPullRequestInfo?

    public init(status: GitStatusInfo, pullRequest: GitPullRequestInfo?) {
        self.status = status
        self.pullRequest = pullRequest
    }

    public var body: some View {
        HStack(spacing: 5) {
            if status.isOnBranch {
                syncBadge
            }
            if let pullRequest {
                pullRequestChip(pullRequest)
            }
        }
    }

    @ViewBuilder
    private var syncBadge: some View {
        if let upstream = status.upstream {
            HStack(spacing: 4) {
                if upstream.ahead == 0 && upstream.behind == 0 {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(tokens.success)
                } else {
                    if upstream.ahead > 0 {
                        countLabel("arrow.up", upstream.ahead, color: tokens.primary)
                    }
                    if upstream.behind > 0 {
                        countLabel("arrow.down", upstream.behind, color: tokens.warning)
                    }
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(Capsule().fill(tokens.surface1))
            .overlay(Capsule().strokeBorder(tokens.borderEtched, lineWidth: 1))
            .help(syncText(upstream))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(syncText(upstream))
        } else if status.push != nil || status.remote != nil {
            Image(systemName: "icloud.slash")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(tokens.mutedForeground)
                .frame(width: 22, height: 20)
                .background(Capsule().fill(tokens.surface1))
                .overlay(Capsule().strokeBorder(tokens.borderEtched, lineWidth: 1))
                .help(notPublishedText)
                .accessibilityLabel(notPublishedText)
        }
    }

    private func countLabel(_ icon: String, _ count: Int, color: Color) -> some View {
        HStack(spacing: 1.5) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .bold))
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(color)
    }

    private var notPublishedText: String {
        if let remote = status.remotePushTarget?.remote ?? status.remote?.name {
            return l10n.tr("git.sync.notPublished", remote)
        }
        return l10n.tr("git.sync.notPublishedNoRemote")
    }

    private func syncText(_ upstream: GitUpstreamInfo) -> String {
        var lines: [String] = []
        if upstream.ahead > 0 && upstream.behind > 0 {
            lines.append(l10n.tr("git.sync.diverged", upstream.ahead, upstream.behind, upstream.name))
        } else if upstream.ahead > 0 {
            lines.append(counted("git.sync.toPush", upstream.ahead, upstream.name))
        } else if upstream.behind > 0 {
            lines.append(counted("git.sync.toPull", upstream.behind, upstream.name))
        } else {
            lines.append(l10n.tr("git.sync.inSync", upstream.name))
        }
        lines.append(fetchedText)
        return lines.joined(separator: " · ")
    }

    private var fetchedText: String {
        guard let fetched = status.lastFetchedAt else { return l10n.tr("git.sync.neverFetched") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = l10n.language.resolvedLocale
        formatter.unitsStyle = .short
        let when = formatter.localizedString(for: Date(timeIntervalSince1970: fetched / 1000), relativeTo: Date())
        return l10n.tr("git.sync.fetched", when)
    }

    private func counted(_ key: String, _ count: Int, _ name: String) -> String {
        let format = l10n.tr(count == 1 ? "\(key).one" : "\(key).other")
        return String(format: format, locale: l10n.language.resolvedLocale, count, name)
    }

    private func pullRequestChip(_ pr: GitPullRequestInfo) -> some View {
        let color = stateColor(pr)
        return Button {
            if let url = URL(string: pr.url) { openURL(url) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: stateIcon(pr.state))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(color)
                Text("#\(pr.number)")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tokens.foreground)
                if pr.state == .open || pr.state == .draft, let checks = checksColor(pr.checks.state) {
                    Circle()
                        .fill(checks)
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(Capsule().fill(color.opacity(tokens.palette.isDark ? 0.16 : 0.1)))
            .overlay(Capsule().strokeBorder(color.opacity(0.3), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(l10n.tr("git.pr.chipHelp", pr.number, stateText(pr.state), pr.title))
        .accessibilityLabel(l10n.tr("git.pr.chipHelp", pr.number, stateText(pr.state), pr.title))
    }

    private func stateIcon(_ state: GitPullRequestState) -> String {
        switch state {
        case .open: return "arrow.triangle.pull"
        case .draft: return "circle.dashed"
        case .merged: return "arrow.triangle.merge"
        case .closed: return "xmark.circle"
        }
    }

    private func stateText(_ state: GitPullRequestState) -> String {
        l10n.tr("git.pr.state.\(state.rawValue)")
    }

    private func stateColor(_ pr: GitPullRequestInfo) -> Color {
        switch pr.state {
        case .open: return tokens.success
        case .draft, .closed: return tokens.mutedForeground
        case .merged: return tokens.prismIris
        }
    }

    private func checksColor(_ state: GitChecksState) -> Color? {
        switch state {
        case .passing: return tokens.success
        case .failing: return tokens.danger
        case .pending: return tokens.warning
        case .none: return nil
        }
    }
}

// MARK: - Pull request draft

/// A pull request's title and description the agent drafts from the branch, for the user to edit,
/// copy, open on GitHub or create through the host's gh.
public struct GitPullRequestDraftSheet: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    @Environment(\.openURL) private var openURL

    @Bindable public var workspace: WorkspaceController
    @State private var copiedLabel: String?

    public init(workspace: WorkspaceController) {
        self.workspace = workspace
    }

    public var body: some View {
        let form = workspace.pullRequestForm
        VStack(alignment: .leading, spacing: 12) {
            header(form)
            branchRow(form)

            VStack(alignment: .leading, spacing: 5) {
                fieldLabel(l10n.tr("git.prDraft.titleField"))
                TextField(
                    form?.isDrafting == true ? l10n.tr("git.prDraft.drafting") : "",
                    text: Binding(
                        get: { workspace.pullRequestForm?.title ?? "" },
                        set: { workspace.setPullRequestTitle($0) }
                    )
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tokens.foreground)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).fill(tokens.codeBackground))
                .overlay(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).strokeBorder(tokens.borderStrong, lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 5) {
                fieldLabel(l10n.tr("git.prDraft.body"))
                ZStack(alignment: .topLeading) {
                    TextEditor(text: Binding(
                        get: { workspace.pullRequestForm?.body ?? "" },
                        set: { workspace.setPullRequestBody($0) }
                    ))
                    .font(.system(size: 12.5))
                    .scrollContentBackground(.hidden)
                    .foregroundStyle(tokens.foreground)
                    .padding(6)
                    if (form?.body ?? "").isEmpty, form?.isDrafting == true {
                        Text(l10n.tr("git.prDraft.drafting"))
                            .font(.system(size: 12.5))
                            .foregroundStyle(tokens.placeholder)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .frame(minHeight: 150, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).fill(tokens.codeBackground))
                .overlay(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).strokeBorder(tokens.borderStrong, lineWidth: 1))
            }

            copyRow(form)

            if workspace.gitTools?.gh.state == .ready {
                Toggle(isOn: Binding(
                    get: { workspace.pullRequestForm?.openAsDraft ?? false },
                    set: { workspace.pullRequestForm?.openAsDraft = $0 }
                )) {
                    Text(l10n.tr("git.prDraft.openAsDraft"))
                        .font(.system(size: 12))
                        .foregroundStyle(tokens.secondaryForeground)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
            }

            if let error = form?.createError {
                Text(error)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(tokens.danger)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            footer(form)
        }
        .padding(18)
        #if os(macOS)
        .frame(minWidth: 500, idealWidth: 560, minHeight: 500, idealHeight: 560)
        #endif
        .background(tokens.background)
        .onDisappear {
            copiedLabel = nil
        }
    }

    private func header(_ form: PullRequestDraftForm?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.pull")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(tokens.prismCobalt)
            Text(l10n.tr("git.prDraft.title"))
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(tokens.foreground)
            Spacer()
            draftState(form)
        }
    }

    @ViewBuilder
    private func draftState(_ form: PullRequestDraftForm?) -> some View {
        if form?.isDrafting == true {
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.72)
                    .frame(width: 12, height: 12)
                Text(l10n.tr("git.prDraft.drafting"))
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.mutedForeground)
            }
        } else {
            HStack(spacing: 8) {
                if form?.isDrafted == true {
                    Label(l10n.tr("git.prDraft.drafted"), systemImage: "sparkles")
                        .font(.system(size: 11))
                        .foregroundStyle(tokens.prismIris)
                        .labelStyle(.titleAndIcon)
                }
                Button {
                    Task { await workspace.draftPullRequest(again: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(tokens.mutedForeground)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(tokens.hoverWash))
                }
                .buttonStyle(.plain)
                .disabled(!workspace.canRunHostGit || (form?.base ?? "").isEmpty)
                .help(l10n.tr("git.prDraft.redraft"))
                .accessibilityLabel(l10n.tr("git.prDraft.redraft"))
            }
        }
    }

    private func branchRow(_ form: PullRequestDraftForm?) -> some View {
        let base = form?.base ?? ""
        let head = workspace.gitStatus?.remotePushTarget?.branch ?? workspace.gitStatus?.head.branch ?? ""
        let choices = workspace.pullRequestBaseChoices.isEmpty
            ? [base].filter { !$0.isEmpty }
            : workspace.pullRequestBaseChoices
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Menu {
                    ForEach(choices, id: \.self) { name in
                        Button(name) { workspace.setPullRequestBase(name) }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 10, weight: .semibold))
                        Text(base.isEmpty ? "—" : base)
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(tokens.placeholder)
                    }
                    .foregroundStyle(tokens.foreground)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(Capsule().fill(tokens.surface2))
                    .overlay(Capsule().strokeBorder(tokens.borderEtched, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(l10n.tr("git.prDraft.base"))
                .accessibilityLabel(l10n.tr("git.prDraft.base"))

                Image(systemName: "arrow.left")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tokens.placeholder)
                    .accessibilityHidden(true)
                Text(head)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(tokens.secondaryForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            if let error = form?.draftError {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(tokens.mutedForeground)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !base.isEmpty, base == workspace.gitStatus?.head.branch {
                Text(l10n.tr("git.prDraft.sameBranch"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(tokens.warning)
            }
        }
    }

    private func copyRow(_ form: PullRequestDraftForm?) -> some View {
        let title = form?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body = form?.body.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return HStack(spacing: 6) {
            copyButton(l10n.tr("git.prDraft.copyTitle"), text: title)
            copyButton(l10n.tr("git.prDraft.copyBody"), text: body)
            copyButton(l10n.tr("git.prDraft.copyAll"), text: body.isEmpty ? title : "\(title)\n\n\(body)")
            Spacer(minLength: 0)
            if let copiedLabel {
                Label(copiedLabel, systemImage: "checkmark")
                    .font(.system(size: 10.5))
                    .foregroundStyle(tokens.success)
                    .labelStyle(.titleAndIcon)
                    .transition(.opacity)
            }
        }
    }

    private func copyButton(_ label: String, text: String) -> some View {
        Button {
            GitFlowClipboard.copy(text)
            copiedLabel = l10n.tr("git.prDraft.copied")
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 9.5, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(tokens.secondaryForeground)
            .padding(.horizontal, 9)
            .padding(.vertical, 4.5)
            .background(Capsule().fill(tokens.hoverWash))
            .overlay(Capsule().strokeBorder(tokens.borderEtched, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(text.isEmpty)
        .opacity(text.isEmpty ? 0.45 : 1)
    }

    private func footer(_ form: PullRequestDraftForm?) -> some View {
        let canCreate = workspace.canCreatePullRequest
        let ghReady = workspace.gitTools?.gh.state == .ready
        let compareURL = workspace.pullRequestCompareURL
        let creating = form?.isCreating == true
        let fill = tokens.palette.isDark ? Color(hex: 0xF2F3F7) : Color(hex: 0x14151B)
        let onFill = tokens.palette.isDark ? Color(hex: 0x0E0F14) : Color.white
        return HStack(spacing: 8) {
            Text(footerHint(ghReady: ghReady, compareURL: compareURL))
                .font(.system(size: 10.5))
                .foregroundStyle(tokens.mutedForeground)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)

            Button(l10n.tr("git.prDraft.cancel")) {
                workspace.discardPullRequestDraft()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tokens.mutedForeground)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(tokens.hoverWash))
            .keyboardShortcut(.cancelAction)

            if let compareURL {
                Button {
                    openURL(compareURL)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9.5, weight: .bold))
                        Text(l10n.tr("git.prDraft.openCompare"))
                            .font(.system(size: 12, weight: ghReady ? .medium : .semibold))
                    }
                    .foregroundStyle(ghReady ? tokens.secondaryForeground : onFill)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(ghReady ? tokens.hoverWash : fill))
                    .overlay(Capsule().strokeBorder(ghReady ? tokens.borderEtched : Color.clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            if ghReady {
                Button {
                    Task {
                        if let url = await workspace.createPullRequest() { openURL(url) }
                    }
                } label: {
                    HStack(spacing: 5) {
                        if creating {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.7)
                                .frame(width: 10, height: 10)
                        }
                        Text(l10n.tr("git.prDraft.create"))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(onFill)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(fill))
                }
                .buttonStyle(.plain)
                .disabled(!canCreate)
                .opacity(canCreate || creating ? 1 : 0.42)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func footerHint(ghReady: Bool, compareURL: URL?) -> String {
        if !workspace.canRunHostGit { return workspace.notConnectedNote }
        if ghReady {
            return workspace.pullRequestPushesFirst ? l10n.tr("git.prDraft.pushesFirst") : ""
        }
        if compareURL == nil { return l10n.tr("git.prDraft.notOnGitHub") }
        return l10n.tr("git.prDraft.needsGh")
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tokens.mutedForeground)
    }
}
