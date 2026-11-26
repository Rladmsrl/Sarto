import SartoProtocol
import PrismDesign
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Container for Obsidian Prism's collapsible M2 Workbench Drawer (Git Diff / Files / Terminal / Preview).
/// Shared across macOS split pane and iOS session detail tabs.
public struct WorkbenchDrawerView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    @Environment(\.prismMotionTier) private var motionTier
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Bindable public var workspace: WorkspaceController
    public var browser: PrismBrowserController?
    public var devices: PrismDeviceController?
    @Binding public var previewTarget: PreviewTargetMode
    public var sessionId: String?
    public var agentDisplayName: String
    @Binding public var activeTab: WorkbenchTab
    public var onClose: (() -> Void)?
    public var onPreviewHTML: ((String) -> Void)?
    public var onQuoteToComposer: ((String) -> Void)?

    public init(
        workspace: WorkspaceController,
        browser: PrismBrowserController? = nil,
        devices: PrismDeviceController? = nil,
        previewTarget: Binding<PreviewTargetMode> = .constant(.web),
        sessionId: String? = nil,
        agentDisplayName: String = "Agent",
        activeTab: Binding<WorkbenchTab>,
        onClose: (() -> Void)? = nil,
        onPreviewHTML: ((String) -> Void)? = nil,
        onQuoteToComposer: ((String) -> Void)? = nil
    ) {
        self.workspace = workspace
        self.browser = browser
        self.devices = devices
        self._previewTarget = previewTarget
        self.sessionId = sessionId
        self.agentDisplayName = agentDisplayName
        self._activeTab = activeTab
        self.onClose = onClose
        self.onPreviewHTML = onPreviewHTML
        self.onQuoteToComposer = onQuoteToComposer
    }

    public var body: some View {
        let previewHasActivity = (browser?.hasUnseenActivity(for: sessionId) ?? false)
            || (devices?.hasAnyActivity(sessionId: sessionId) ?? false)

        VStack(spacing: 0) {
            // Segmented obsidian header strip
            HStack(spacing: 6) {
                HStack(spacing: 2) {
                    ForEach(WorkbenchTab.allCases) { tab in
                        let selected = activeTab == tab
                        Button {
                            withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier, reduceMotion: reduceMotion)) {
                                activeTab = tab
                            }
                            Task {
                                switch tab {
                                case .git: await workspace.refreshGit()
                                case .files: await workspace.refreshFiles()
                                case .terminal: await workspace.ensureDefaultTerminal()
                                case .preview:
                                    browser?.markSeen(sessionId: sessionId)
                                    if previewTarget == .ios { devices?.markPlatformSeen(.ios) }
                                    if previewTarget == .android { devices?.markPlatformSeen(.android) }
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: tab.iconName)
                                    .font(.system(size: 10.5, weight: .medium))
                                Text(tab.localizedTitle(l10n))
                                    .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                                if tab == .git && !workspace.changedFiles.isEmpty {
                                    Text("\(workspace.changedFiles.count)")
                                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                        .foregroundStyle(selected ? tokens.primary : tokens.mutedForeground)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(selected ? tokens.primarySoft : tokens.surface2))
                                } else if tab == .preview && previewHasActivity && !selected {
                                    Circle()
                                        .fill(tokens.primary)
                                        .frame(width: 5.5, height: 5.5)
                                }
                            }
                            .foregroundStyle(selected ? tokens.foreground : tokens.mutedForeground)
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(Capsule().fill(selected ? tokens.surface2 : Color.clear))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(Capsule().fill(tokens.hoverWash))
                .overlay(Capsule().strokeBorder(tokens.borderEtched, lineWidth: 1))

                Spacer()

                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(tokens.mutedForeground)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(tokens.hoverWash))
                    }
                    .buttonStyle(.plain)
                    .help(l10n.tr("workbench.closeTooltip"))
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(tokens.sidebar.opacity(0.88))

            Rectangle().fill(tokens.borderEtched).frame(height: 1)

            // Active pane body
            Group {
                switch activeTab {
                case .git:
                    GitDiffWorkbenchView(workspace: workspace)
                case .files:
                    FilesWorkbenchView(
                        workspace: workspace,
                        onPreviewHTML: onPreviewHTML,
                        onQuoteToComposer: onQuoteToComposer
                    )
                case .terminal:
                    TerminalWorkbenchView(workspace: workspace)
                case .preview:
                    if let browser, let devices {
                        PreviewWorkbenchView(
                            browser: browser,
                            devices: devices,
                            targetMode: $previewTarget,
                            sessionId: sessionId,
                            agentDisplayName: agentDisplayName
                        )
                    } else if let browser {
                        BrowserWorkbenchView(
                            browser: browser,
                            sessionId: sessionId,
                            agentDisplayName: agentDisplayName
                        )
                    } else {
                        Color.clear
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(tokens.sidebar.opacity(0.95))
    }
}

// MARK: - 1. Native Git Diff Viewer & Commit Panel

public enum DiffLayoutMode: String, CaseIterable, Identifiable, Sendable {
    case unified
    case split

    public var id: String { rawValue }
}

public struct GitDiffWorkbenchView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    @Bindable public var workspace: WorkspaceController
    @FocusState private var commitMessageFocused: Bool
    @AppStorage("sarto.diff.layout") private var diffLayoutRaw: String = DiffLayoutMode.unified.rawValue

    private var diffLayout: DiffLayoutMode {
        DiffLayoutMode(rawValue: diffLayoutRaw) ?? .unified
    }

    public init(workspace: WorkspaceController) {
        self.workspace = workspace
    }

    public var body: some View {
        paneBody
            .sheet(isPresented: $workspace.isPullRequestDraftPresented) {
                GitPullRequestDraftSheet(workspace: workspace)
                    .environment(\.prismTokens, tokens)
                    .environment(\.prismL10n, l10n)
                    .environment(\.locale, l10n.language.resolvedLocale)
                    .preferredColorScheme(tokens.palette.colorScheme)
            }
    }

    @ViewBuilder
    private var gitFlowLead: some View {
        if let status = workspace.gitStatus, status.repo != nil, workspace.gitLoadError == nil {
            VStack(alignment: .leading, spacing: 6) {
                if status.stale {
                    Label(l10n.tr("git.pane.stale"), systemImage: "exclamationmark.arrow.circlepath")
                        .font(.system(size: 10.5))
                        .foregroundStyle(tokens.warning)
                        .labelStyle(.titleAndIcon)
                }
                GitNextStepCard(
                    workspace: workspace,
                    onFocusCommitMessage: { commitMessageFocused = true }
                )
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)
        }
    }

    private var paneBody: some View {
        VStack(spacing: 0) {
            // Branch & change metrics bar
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(tokens.prismCobalt)
                    Text(workspace.gitStatus?.head.branch ?? "detached")
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(tokens.foreground)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(Capsule().fill(tokens.surface1))
                .overlay(Capsule().strokeBorder(tokens.borderEtched, lineWidth: 1))

                if let status = workspace.gitStatus, status.repo != nil {
                    GitBranchSyncBadges(status: status, pullRequest: workspace.currentPullRequest)
                }

                if let changes = workspace.gitStatus?.changes {
                    DiffCountStatText(
                        insertions: changes.insertions,
                        deletions: changes.deletions,
                        fontSize: 11,
                        showZero: true
                    )
                }

                Spacer()

                if workspace.canDraftPullRequest {
                    Button {
                        workspace.presentPullRequestDraft()
                    } label: {
                        Image(systemName: "arrow.triangle.pull")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(tokens.mutedForeground)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(l10n.tr("git.toolbar.draftPr"))
                    .accessibilityLabel(l10n.tr("git.toolbar.draftPr"))
                }

                if workspace.canRunHostGit, workspace.gitStatus?.remote != nil {
                    Button {
                        Task { await workspace.fetchGit() }
                    } label: {
                        Group {
                            if workspace.runningGitActivity == .fetch {
                                ProgressView()
                                    .controlSize(.mini)
                                    .scaleEffect(0.7)
                            } else {
                                Image(systemName: "icloud.and.arrow.down")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(tokens.mutedForeground)
                            }
                        }
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(workspace.runningGitActivity != nil)
                    .help(l10n.tr("git.toolbar.fetch"))
                    .accessibilityLabel(l10n.tr("git.toolbar.fetch"))
                }

                Button {
                    Task { await workspace.refreshGit() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(tokens.mutedForeground)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Rectangle().fill(tokens.borderEtched).frame(height: 1)

            gitFlowLead

            if workspace.changedFiles.isEmpty, let loadError = workspace.gitLoadError {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 22))
                        .foregroundStyle(tokens.warning)
                    Text(l10n.tr("workbench.gitUnavailable"))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(tokens.secondaryForeground)
                    Text(loadError)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(tokens.mutedForeground)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .padding(.horizontal, 16)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if workspace.changedFiles.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 24))
                        .foregroundStyle(tokens.success.opacity(0.8))
                    Text(l10n.tr("workbench.gitClean"))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(tokens.secondaryForeground)
                    if let note = workspace.gitNotice {
                        Text(note)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(tokens.prismCobalt)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                // Compact changed files strip
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(workspace.changedFiles) { file in
                            let selected = workspace.selectedDiffPath == file.path
                            let checked = workspace.selectedForCommit.contains(file.path)
                            HStack(spacing: 7) {
                                Button {
                                    if checked { workspace.selectedForCommit.remove(file.path) }
                                    else { workspace.selectedForCommit.insert(file.path) }
                                } label: {
                                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(checked ? tokens.primary : tokens.placeholder)
                                }
                                .buttonStyle(.plain)

                                Text(file.status.shortCode)
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(statusColor(file.status))
                                    .frame(width: 14)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text((file.path as NSString).lastPathComponent)
                                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                                        .foregroundStyle(selected ? tokens.foreground : tokens.secondaryForeground)
                                        .lineLimit(1)
                                    Text(file.path)
                                        .font(.system(size: 9.5, design: .monospaced))
                                        .foregroundStyle(tokens.placeholder)
                                        .lineLimit(1)
                                }

                                Spacer()

                                if let ins = file.insertions, let del = file.deletions {
                                    DiffCountStatText(
                                        insertions: ins,
                                        deletions: del,
                                        fontSize: 10.5,
                                        showZero: true
                                    )
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5.5)
                            .background(
                                RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                                    .fill(selected ? tokens.activeWash : Color.clear)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                Task { await workspace.loadDiff(for: file.path) }
                            }
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 168)

                Rectangle().fill(tokens.borderEtched).frame(height: 1)

                // Diff layout header bar (selected file + Unified / Split toggle)
                HStack(spacing: 8) {
                    if let path = workspace.selectedDiffPath {
                        Text(path)
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(tokens.secondaryForeground)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 6)
                    diffLayoutToggle
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(tokens.codeHeaderBackground)

                Rectangle().fill(tokens.borderEtched).frame(height: 1)

                // Virtualized Unified / Split Diff Sunken Code Viewport
                UnifiedDiffView(
                    fileDiff: workspace.activeFileDiff,
                    computedDiff: workspace.computedDiff,
                    layout: diffLayout
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Rectangle().fill(tokens.borderEtched).frame(height: 1)

                // Commit Bar
                VStack(alignment: .leading, spacing: 6) {
                    if let note = workspace.gitNotice {
                        Text(note)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(tokens.prismCobalt)
                            .lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        TextField(l10n.tr("workbench.commitPlaceholder"), text: $workspace.commitMessage)
                            .focused($commitMessageFocused)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(tokens.foreground)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: tokens.rXS).fill(tokens.codeBackground))
                            .overlay(RoundedRectangle(cornerRadius: tokens.rXS).strokeBorder(tokens.borderEtched, lineWidth: 1))
                            .onSubmit {
                                Task { await workspace.commitSelectedChanges() }
                            }

                        Button {
                            Task { await workspace.generateCommitMessage() }
                        } label: {
                            Group {
                                if workspace.isGeneratingCommitMessage {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .scaleEffect(0.72)
                                } else {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundStyle(tokens.prismIris)
                                }
                            }
                            .frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: tokens.rXS).fill(tokens.hoverWash))
                            .overlay(RoundedRectangle(cornerRadius: tokens.rXS).strokeBorder(tokens.borderEtched, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(workspace.isGeneratingCommitMessage || workspace.changedFiles.isEmpty)
                        .opacity(workspace.isGeneratingCommitMessage || workspace.changedFiles.isEmpty ? 0.42 : 1.0)
                        .help(l10n.tr("workbench.commitAiTooltip"))

                        Button {
                            Task { await workspace.commitSelectedChanges() }
                        } label: {
                            Text(l10n.tr("workbench.commitButton"))
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(tokens.palette.isDark ? Color(hex: 0x0E0F14) : .white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(tokens.palette.isDark ? Color(hex: 0xF2F3F7) : Color(hex: 0x14151B)))
                        }
                        .buttonStyle(.plain)
                        .disabled(workspace.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .opacity(workspace.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.42 : 1.0)
                    }
                }
                .padding(10)
            }
        }
    }

    private var diffLayoutToggle: some View {
        HStack(spacing: 2) {
            ForEach(DiffLayoutMode.allCases) { mode in
                let selected = diffLayout == mode
                Button {
                    diffLayoutRaw = mode.rawValue
                } label: {
                    Text(l10n.tr(mode == .unified ? "diff.layout.unified" : "diff.layout.split"))
                        .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? tokens.foreground : tokens.mutedForeground)
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(Capsule().fill(selected ? tokens.surface2 : Color.clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(tokens.hoverWash))
        .overlay(Capsule().strokeBorder(tokens.borderEtched, lineWidth: 1))
    }

    private func statusColor(_ status: GitChangeStatus) -> Color {
        switch status {
        case .added, .untracked: return tokens.success
        case .deleted: return tokens.danger
        case .conflicted: return tokens.warning
        default: return tokens.prismCobalt
        }
    }
}

/// Virtualized 120fps Unified & Split Diff line viewer backed by `LazyVStack`.
public struct UnifiedDiffView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    public let fileDiff: FileDiffInfo?
    public let computedDiff: ComputedDiff
    public let layout: DiffLayoutMode

    @State private var splitHunks: [SplitDiffHunk] = []
    @State private var syncedHorizontalX: CGFloat = 0

    public init(
        fileDiff: FileDiffInfo?,
        computedDiff: ComputedDiff,
        layout: DiffLayoutMode = .unified
    ) {
        self.fileDiff = fileDiff
        self.computedDiff = computedDiff
        self.layout = layout
    }

    public var body: some View {
        Group {
            if let diff = fileDiff {
                if diff.binary {
                    diffPlaceholder(l10n.tr("workbench.binaryDiff"))
                } else if diff.tooLarge {
                    diffPlaceholder(l10n.tr("workbench.tooLargeDiff"))
                } else if computedDiff.hunks.isEmpty {
                    diffPlaceholder(l10n.tr("workbench.noTextDiff"))
                } else if layout == .split {
                    splitDiffBody
                } else {
                    unifiedDiffBody
                }
            } else {
                tokens.codeBackground
            }
        }
        .task(id: computedDiff) {
            let hunks = computedDiff.hunks
            let built = SplitDiffHunk.build(from: hunks)
            splitHunks = built
            syncedHorizontalX = 0
        }
    }

    private func diffPlaceholder(_ message: String) -> some View {
        ScrollView([.vertical, .horizontal]) {
            Text(message)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(tokens.mutedForeground)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(tokens.codeBackground)
    }

    private var unifiedDiffBody: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(computedDiff.hunks) { hunk in
                    Text(hunk.header)
                        .id("hunk-\(hunk.id)")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(tokens.prismCobalt)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(tokens.codeHeaderBackground)

                    ForEach(hunk.lines) { line in
                        HStack(spacing: 0) {
                            Text(line.oldLineNumber.map(String.init) ?? "")
                                .frame(width: 34, alignment: .trailing)
                                .foregroundStyle(tokens.placeholder)
                                .padding(.trailing, 6)
                            Text(line.newLineNumber.map(String.init) ?? "")
                                .frame(width: 34, alignment: .trailing)
                                .foregroundStyle(tokens.placeholder)
                                .padding(.trailing, 8)
                            Text(prefixSymbol(line.kind))
                                .foregroundStyle(lineColor(line.kind))
                                .frame(width: 14, alignment: .center)
                            Text(line.text)
                                .foregroundStyle(line.kind == .context ? tokens.secondaryForeground : tokens.foreground)
                                .textSelection(.enabled)
                            Spacer(minLength: 12)
                        }
                        .id("line-\(hunk.id)-\(line.id)")
                        .font(.system(size: 11.5, design: .monospaced))
                        .padding(.vertical, 1.5)
                        .background(lineBackground(line.kind))
                    }
                }
            }
            .frame(minWidth: 360, alignment: .leading)
        }
        .background(tokens.codeBackground)
    }

    private var splitDiffBody: some View {
        GeometryReader { geo in
            let halfWidth = max(160, (geo.size.width - 1) / 2)
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(splitHunks) { hunk in
                        Text(hunk.header)
                            .id("split-hunk-\(hunk.id)")
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(tokens.prismCobalt)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(tokens.codeHeaderBackground)

                        HStack(alignment: .top, spacing: 0) {
                            SplitDiffColumnView(
                                side: .left,
                                rows: hunk.rows,
                                minColumnWidth: halfWidth,
                                syncedHorizontalX: $syncedHorizontalX,
                                tokens: tokens
                            )
                            .frame(width: halfWidth)

                            Rectangle()
                                .fill(tokens.borderEtched)
                                .frame(width: 1)

                            SplitDiffColumnView(
                                side: .right,
                                rows: hunk.rows,
                                minColumnWidth: halfWidth,
                                syncedHorizontalX: $syncedHorizontalX,
                                tokens: tokens
                            )
                            .frame(width: halfWidth)
                        }
                    }
                }
            }
            .background(tokens.codeBackground)
        }
    }

    private func prefixSymbol(_ kind: DiffLineKind) -> String {
        switch kind {
        case .added: return "+"
        case .deleted: return "-"
        case .context: return " "
        }
    }

    private func lineColor(_ kind: DiffLineKind) -> Color {
        switch kind {
        case .added: return tokens.success
        case .deleted: return tokens.danger
        case .context: return tokens.placeholder
        }
    }

    private func lineBackground(_ kind: DiffLineKind) -> Color {
        switch kind {
        case .added: return tokens.success.opacity(tokens.palette.isDark ? 0.14 : 0.12)
        case .deleted: return tokens.danger.opacity(tokens.palette.isDark ? 0.14 : 0.12)
        case .context: return .clear
        }
    }
}

private enum SplitDiffSide: Sendable {
    case left
    case right
}

private struct SplitDiffRow: Identifiable, Sendable {
    let id: String
    let left: DiffLine?
    let right: DiffLine?
}

private struct SplitDiffHunk: Identifiable, Sendable {
    let id: Int
    let header: String
    let rows: [SplitDiffRow]

    static func build(from hunks: [DiffHunk]) -> [SplitDiffHunk] {
        hunks.map { hunk in
            var rows: [SplitDiffRow] = []
            let lines = hunk.lines
            var idx = 0
            while idx < lines.count {
                let line = lines[idx]
                if line.kind == .context {
                    rows.append(SplitDiffRow(
                        id: "ctx-\(hunk.id)-\(line.id)",
                        left: line,
                        right: line
                    ))
                    idx += 1
                    continue
                }
                var deleted: [DiffLine] = []
                while idx < lines.count, lines[idx].kind == .deleted {
                    deleted.append(lines[idx])
                    idx += 1
                }
                var added: [DiffLine] = []
                while idx < lines.count, lines[idx].kind == .added {
                    added.append(lines[idx])
                    idx += 1
                }
                let count = max(deleted.count, added.count)
                for offset in 0..<count {
                    let leftLine = offset < deleted.count ? deleted[offset] : nil
                    let rightLine = offset < added.count ? added[offset] : nil
                    rows.append(SplitDiffRow(
                        id: "chg-\(hunk.id)-\(leftLine?.id ?? -1)-\(rightLine?.id ?? -1)-\(offset)",
                        left: leftLine,
                        right: rightLine
                    ))
                }
            }
            return SplitDiffHunk(id: hunk.id, header: hunk.header, rows: rows)
        }
    }
}

private struct SplitDiffColumnView: View {
    let side: SplitDiffSide
    let rows: [SplitDiffRow]
    let minColumnWidth: CGFloat
    @Binding var syncedHorizontalX: CGFloat
    let tokens: PrismTokens

    @State private var scrollPosition = ScrollPosition(x: 0)
    @State private var currentHorizontalX: CGFloat = 0

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    SplitDiffLineCell(
                        side: side,
                        line: side == .left ? row.left : row.right,
                        tokens: tokens
                    )
                }
            }
            .frame(minWidth: minColumnWidth, alignment: .leading)
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.x
        } action: { _, nextX in
            currentHorizontalX = nextX
            if abs(nextX - syncedHorizontalX) > 1.0 {
                syncedHorizontalX = nextX
            }
        }
        .onChange(of: syncedHorizontalX) { _, targetX in
            if abs(targetX - currentHorizontalX) > 1.0 {
                scrollPosition.scrollTo(x: targetX)
            }
        }
    }
}

private struct SplitDiffLineCell: View {
    let side: SplitDiffSide
    let line: DiffLine?
    let tokens: PrismTokens

    var body: some View {
        HStack(spacing: 0) {
            if let line {
                let lineNumber = side == .left ? line.oldLineNumber : line.newLineNumber
                Text(lineNumber.map(String.init) ?? "")
                    .frame(width: 34, alignment: .trailing)
                    .foregroundStyle(tokens.placeholder)
                    .padding(.trailing, 6)
                Text(prefixSymbol(line.kind))
                    .foregroundStyle(prefixColor(line.kind))
                    .frame(width: 14, alignment: .center)
                Text(line.text)
                    .foregroundStyle(line.kind == .context ? tokens.secondaryForeground : tokens.foreground)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .textSelection(.enabled)
                Spacer(minLength: 10)
            } else {
                Spacer(minLength: 10)
            }
        }
        .font(.system(size: 11.5, design: .monospaced))
        .frame(maxWidth: .infinity, minHeight: 19, maxHeight: 19, alignment: .leading)
        .background(cellBackground)
    }

    private func prefixSymbol(_ kind: DiffLineKind) -> String {
        switch kind {
        case .added: return "+"
        case .deleted: return "-"
        case .context: return " "
        }
    }

    private func prefixColor(_ kind: DiffLineKind) -> Color {
        switch kind {
        case .added: return tokens.success
        case .deleted: return tokens.danger
        case .context: return tokens.placeholder
        }
    }

    private var cellBackground: Color {
        guard let line else {
            return tokens.surface1.opacity(0.45)
        }
        switch line.kind {
        case .added: return tokens.success.opacity(tokens.palette.isDark ? 0.14 : 0.12)
        case .deleted: return tokens.danger.opacity(tokens.palette.isDark ? 0.14 : 0.12)
        case .context: return .clear
        }
    }
}

// MARK: - 2. Native File Browser & Code Editor

private enum FileTreeRowKind: Equatable {
    case folder(isExpanded: Bool)
    case file
    case loading
    case emptyIgnored
}

private struct FileTreeRow: Identifiable, Equatable {
    let id: String
    let path: String
    let name: String
    let depth: Int
    let isIgnored: Bool
    let kind: FileTreeRowKind
}

private final class FileTreeBuilderNode {
    let name: String
    let path: String
    var isFolder: Bool
    var isIgnored: Bool
    var children: [String: FileTreeBuilderNode] = [:]
    private var sortedCache: [FileTreeBuilderNode]? = nil

    init(name: String, path: String, isFolder: Bool, isIgnored: Bool) {
        self.name = name
        self.path = path
        self.isFolder = isFolder
        self.isIgnored = isIgnored
    }

    func sortedChildren() -> [FileTreeBuilderNode] {
        if let sortedCache { return sortedCache }
        let sorted = children.values.sorted { lhs, rhs in
            if lhs.isFolder != rhs.isFolder {
                return lhs.isFolder && !rhs.isFolder
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        sortedCache = sorted
        return sorted
    }
}

/// Caches the built file tree trie and flattened visible rows so SwiftUI body re-evaluations
/// (hover, editor typing, file selection) never rebuild a 50k-node trie on the main actor.
@MainActor
private final class FileTreeRowsCache {
    private var treeKey: (generation: UInt64, revision: UInt64)? = nil
    private var rootNode = FileTreeBuilderNode(name: "", path: "", isFolder: true, isIgnored: false)
    private var rowsKey: (generation: UInt64, revision: UInt64, expanded: Set<String>, loadingLabel: String, emptyLabel: String)? = nil
    private var cachedRows: [FileTreeRow] = []

    func rows(
        workspace: WorkspaceController,
        expandedFolders: Set<String>,
        loadingLabel: String,
        emptyLabel: String
    ) -> [FileTreeRow] {
        let gen = workspace.projectGeneration
        let rev = workspace.fileTreeRevision
        if let rowsKey,
           rowsKey.generation == gen,
           rowsKey.revision == rev,
           rowsKey.expanded == expandedFolders,
           rowsKey.loadingLabel == loadingLabel,
           rowsKey.emptyLabel == emptyLabel {
            return cachedRows
        }

        if treeKey?.generation != gen || treeKey?.revision != rev {
            rootNode = Self.buildTree(workspace: workspace)
            treeKey = (gen, rev)
        }

        var rows: [FileTreeRow] = []

        func appendChildren(of node: FileTreeBuilderNode, depth: Int) {
            for child in node.sortedChildren() {
                if child.isFolder {
                    let expanded = expandedFolders.contains(child.path)
                    rows.append(FileTreeRow(
                        id: "dir:\(child.path)",
                        path: child.path,
                        name: child.name,
                        depth: depth,
                        isIgnored: child.isIgnored,
                        kind: .folder(isExpanded: expanded)
                    ))
                    if expanded {
                        if workspace.loadingIgnoredFolders.contains(child.path) {
                            rows.append(FileTreeRow(
                                id: "loading:\(child.path)",
                                path: child.path,
                                name: loadingLabel,
                                depth: depth + 1,
                                isIgnored: true,
                                kind: .loading
                            ))
                        } else if child.children.isEmpty,
                                  child.isIgnored,
                                  workspace.loadedIgnoredFolders[child.path] != nil {
                            rows.append(FileTreeRow(
                                id: "empty:\(child.path)",
                                path: child.path,
                                name: emptyLabel,
                                depth: depth + 1,
                                isIgnored: true,
                                kind: .emptyIgnored
                            ))
                        } else {
                            appendChildren(of: child, depth: depth + 1)
                        }
                    }
                } else {
                    rows.append(FileTreeRow(
                        id: "file:\(child.path)",
                        path: child.path,
                        name: child.name,
                        depth: depth,
                        isIgnored: child.isIgnored,
                        kind: .file
                    ))
                }
            }
        }

        appendChildren(of: rootNode, depth: 0)
        cachedRows = rows
        rowsKey = (gen, rev, expandedFolders, loadingLabel, emptyLabel)
        return rows
    }

    private static func buildTree(workspace: WorkspaceController) -> FileTreeBuilderNode {
        let root = FileTreeBuilderNode(name: "", path: "", isFolder: true, isIgnored: false)

        func insert(path rawPath: String, isFolder: Bool, isIgnored: Bool) {
            let parts = rawPath.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { return }
            var current = root
            var builtPath = ""
            for (index, part) in parts.enumerated() {
                builtPath = builtPath.isEmpty ? part : "\(builtPath)/\(part)"
                let isLast = index == parts.count - 1
                let nodeIsFolder = isLast ? isFolder : true
                let nodeIgnored = isIgnored && (isLast || workspace.isIgnored(path: builtPath))
                if let existing = current.children[part] {
                    if nodeIsFolder { existing.isFolder = true }
                    if !nodeIgnored { existing.isIgnored = false }
                    current = existing
                } else {
                    let child = FileTreeBuilderNode(
                        name: part,
                        path: builtPath,
                        isFolder: nodeIsFolder,
                        isIgnored: nodeIgnored
                    )
                    current.children[part] = child
                    current = child
                }
            }
        }

        for path in workspace.filePaths {
            insert(path: path, isFolder: false, isIgnored: false)
        }
        for folder in workspace.folderPaths {
            insert(path: folder, isFolder: true, isIgnored: false)
        }
        if workspace.showIgnoredFiles {
            for path in workspace.ignoredPaths {
                insert(path: path, isFolder: false, isIgnored: true)
            }
            for folder in workspace.ignoredFolders {
                insert(path: folder, isFolder: true, isIgnored: true)
            }
        }
        return root
    }
}

private final class DroppedFileURLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func append(_ url: URL) {
        lock.withLock { urls.append(url) }
    }

    func snapshot() -> [URL] {
        lock.withLock { urls }
    }
}

public enum MarkdownPreviewMode: String, CaseIterable, Identifiable, Sendable {
    case preview
    case source

    public var id: String { rawValue }
}

public struct FilesWorkbenchView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    @Bindable public var workspace: WorkspaceController
    public var onPreviewHTML: ((String) -> Void)?
    public var onQuoteToComposer: ((String) -> Void)?

    @AppStorage("sarto.files.markdownMode") private var markdownModeRaw: String = MarkdownPreviewMode.preview.rawValue
    @State private var expandedFolders: Set<String> = []
    @State private var treeRowsCache = FileTreeRowsCache()
    @State private var isRootDropTargeted: Bool = false
    @State private var dropTargetedFolder: String? = nil
    @State private var selectedPreviewPassage: String = ""
    @State private var previewImageItem: PrismImagePreviewItem? = nil

    private var markdownMode: MarkdownPreviewMode {
        MarkdownPreviewMode(rawValue: markdownModeRaw) ?? .preview
    }
    @State private var selectedPreviewLineRange: ClosedRange<Int>? = nil
    @State private var editorSelection: TextSelection? = nil

    public init(
        workspace: WorkspaceController,
        onPreviewHTML: ((String) -> Void)? = nil,
        onQuoteToComposer: ((String) -> Void)? = nil
    ) {
        self.workspace = workspace
        self.onPreviewHTML = onPreviewHTML
        self.onQuoteToComposer = onQuoteToComposer
    }

    private var hasActiveFilter: Bool {
        !workspace.fileFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var totalDisplayedFileCount: Int {
        if workspace.showIgnoredFiles {
            return workspace.filePaths.count + workspace.ignoredPaths.count
        }
        return workspace.filePaths.count
    }

    private var visibleTreeRows: [FileTreeRow] {
        treeRowsCache.rows(
            workspace: workspace,
            expandedFolders: expandedFolders,
            loadingLabel: l10n.tr("files.loadingFolder"),
            emptyLabel: l10n.tr("files.ignoredEmpty")
        )
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Search filter & actions bar
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.placeholder)
                TextField(l10n.tr("workbench.filterFiles"), text: $workspace.fileFilter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(tokens.foreground)
                Text("\(totalDisplayedFileCount)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(tokens.placeholder)

                Button {
                    workspace.showIgnoredFiles.toggle()
                } label: {
                    Image(systemName: workspace.showIgnoredFiles ? "eye" : "eye.slash")
                        .font(.system(size: 10.5))
                        .foregroundStyle(workspace.showIgnoredFiles ? tokens.secondaryForeground : tokens.placeholder)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                                .fill(workspace.showIgnoredFiles ? tokens.hoverWash : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(l10n.tr(workspace.showIgnoredFiles ? "files.hideIgnored" : "files.showIgnored"))

                #if os(macOS)
                Button {
                    presentUploadPanel(intoFolder: "")
                } label: {
                    Group {
                        if workspace.isUploadingFiles {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.68)
                        } else {
                            Image(systemName: "arrow.up.doc")
                                .font(.system(size: 10.5))
                                .foregroundStyle(tokens.mutedForeground)
                        }
                    }
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(workspace.isUploadingFiles)
                .help(l10n.tr("files.uploadFiles"))
                #endif

                Button {
                    Task { await workspace.refreshFiles() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10.5))
                        .foregroundStyle(tokens.mutedForeground)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(tokens.codeBackground.opacity(0.6))

            Rectangle().fill(tokens.borderEtched).frame(height: 1)

            // File tree (hierarchical when unfiltered, flat when searching) + drop target
            ZStack {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1.5) {
                        if hasActiveFilter {
                            ForEach(workspace.filteredFilePaths, id: \.self) { path in
                                filteredFileRow(path: path)
                            }
                        } else {
                            ForEach(visibleTreeRows) { row in
                                treeRowView(row)
                            }
                        }
                    }
                    .padding(6)
                }

                if isRootDropTargeted && dropTargetedFolder == nil {
                    RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                        .fill(tokens.primarySoft)
                        .overlay(
                            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                                .strokeBorder(tokens.primaryBorder, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        )
                        .overlay(
                            Label(l10n.tr("files.uploadDropHint"), systemImage: "arrow.up.doc")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(tokens.primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(tokens.surface1))
                        )
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 120, maxHeight: 220)
            .onDrop(of: [.fileURL], isTargeted: $isRootDropTargeted) { providers in
                handleFileDrop(providers, intoFolder: "")
            }
            .onChange(of: workspace.projectGeneration) { _, _ in
                expandedFolders.removeAll()
                dropTargetedFolder = nil
                clearSelectionState()
            }
            .onChange(of: workspace.selectedFilePath) { _, _ in
                clearSelectionState()
            }
            .onChange(of: workspace.isEditingFile) { _, _ in
                clearSelectionState()
            }

            Rectangle().fill(tokens.borderEtched).frame(height: 1)

            // Code header bar
            HStack(spacing: 6) {
                if workspace.isOpenFileFromAgentFolder {
                    HStack(spacing: 3.5) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9, weight: .semibold))
                        Text(l10n.tr("workbench.agentFileBadge"))
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    .foregroundStyle(tokens.prismIris)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(tokens.hoverWash))
                    .overlay(Capsule().strokeBorder(tokens.borderEtched, lineWidth: 0.75))
                    .fixedSize(horizontal: true, vertical: false)
                } else if workspace.openFileIsExternal {
                    HStack(spacing: 3.5) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 9, weight: .semibold))
                        Text(l10n.tr("workbench.externalFileBadge"))
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    .foregroundStyle(tokens.mutedForeground)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(tokens.hoverWash))
                    .overlay(Capsule().strokeBorder(tokens.borderEtched, lineWidth: 0.75))
                    .fixedSize(horizontal: true, vertical: false)
                }
                Text(workspace.openFileDisplayName ?? l10n.tr("workbench.noFileSelected"))
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(tokens.secondaryForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(workspace.selectedFilePath ?? "")
                if workspace.isFileDirty {
                    Circle().fill(tokens.warning).frame(width: 6, height: 6)
                }
                Spacer(minLength: 4)
                if let note = workspace.openFileStatusNote {
                    Text(note)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(tokens.prismCobalt)
                        .lineLimit(1)
                }
                if let path = workspace.selectedFilePath {
                    if WorkspaceController.isMarkdownPath(path) && !workspace.isEditingFile {
                        markdownModeToggle
                    }

                    #if os(macOS)
                    if let localURL = workspace.openFileLocalURL, !workspace.isRemoteWorkspace {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([localURL])
                        } label: {
                            Image(systemName: "folder")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(tokens.secondaryForeground)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(tokens.hoverWash))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(l10n.tr("contextMenu.revealInFinder"))
                    }
                    #endif

                    if let onPreviewHTML,
                       WorkspaceController.isHTMLPath(path),
                       !workspace.isRemoteWorkspace {
                        Button {
                            onPreviewHTML(path)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "safari")
                                    .font(.system(size: 10, weight: .medium))
                                Text(l10n.tr("files.previewInBrowser"))
                                    .font(.system(size: 10.5, weight: .medium))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(tokens.primary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(tokens.primarySoft))
                            .overlay(Capsule().strokeBorder(tokens.primaryBorder, lineWidth: 1))
                            .fixedSize(horizontal: true, vertical: false)
                        }
                        .buttonStyle(.plain)
                        .help(l10n.tr("files.previewInBrowser"))
                    }

                    if onQuoteToComposer != nil {
                        let activeQuote = currentSelectedPassage()
                        let hasSelection = activeQuote != nil
                        Button {
                            quoteCurrentToComposer()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "text.quote")
                                    .font(.system(size: 9.5, weight: .medium))
                                Text(l10n.tr(hasSelection ? "files.quoteSelection" : "files.quoteFile"))
                                    .font(.system(size: 10.5, weight: .medium))
                                    .lineLimit(1)
                                if let range = activeQuote?.lineRange {
                                    Text(range.lowerBound == range.upperBound
                                        ? "L\(range.lowerBound)"
                                        : "L\(range.lowerBound)-\(range.upperBound)")
                                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                        .opacity(0.85)
                                }
                            }
                            .foregroundStyle(hasSelection ? tokens.primary : tokens.secondaryForeground)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(hasSelection ? tokens.primarySoft : tokens.hoverWash))
                            .overlay(
                                Capsule().strokeBorder(
                                    hasSelection ? tokens.primaryBorder : Color.clear,
                                    lineWidth: 1
                                )
                            )
                            .fixedSize(horizontal: true, vertical: false)
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut("l", modifiers: [.command, .shift])
                        .help(l10n.tr(hasSelection ? "files.quoteSelection" : "files.quoteHint"))
                    }
                }
                if workspace.openFileEditable && workspace.selectedFilePath != nil {
                    Button(workspace.isEditingFile ? l10n.tr("workbench.preview") : l10n.tr("workbench.edit")) {
                        workspace.isEditingFile.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(tokens.secondaryForeground)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(tokens.hoverWash))
                    .fixedSize(horizontal: true, vertical: false)

                    if workspace.isFileDirty {
                        Button(l10n.tr("workbench.save")) {
                            Task { await workspace.saveOpenFile() }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(tokens.palette.isDark ? Color(hex: 0x0E0F14) : .white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(tokens.palette.isDark ? Color(hex: 0xF2F3F7) : Color(hex: 0x14151B)))
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(tokens.codeHeaderBackground)

            Rectangle().fill(tokens.borderEtched).frame(height: 1)

            if workspace.openFileHasSaveConflict {
                saveConflictBanner
                Rectangle().fill(tokens.borderEtched).frame(height: 1)
            }

            // Code Editor / Rendered Markdown Preview / Line-Numbered Source Preview
            if workspace.isEditingFile && workspace.openFileEditable {
                TextEditor(
                    text: Binding(
                        get: { workspace.openFileText },
                        set: { next in
                            workspace.openFileText = next
                            if !workspace.isFileDirty {
                                workspace.isFileDirty = true
                            }
                        }
                    ),
                    selection: $editorSelection
                )
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(tokens.codeBackground)
                .foregroundStyle(tokens.foreground)
                .padding(8)
                .background(tokens.codeBackground)
            } else if let imageData = workspace.openFileImageData,
                      let path = workspace.selectedFilePath {
                ImageFilePreviewPane(
                    data: imageData,
                    title: workspace.openFileDisplayName ?? (path as NSString).lastPathComponent,
                    localURL: workspace.openFileLocalURL,
                    onPreviewImage: { item in previewImageItem = item }
                )
            } else if workspace.openFileIsExternal,
                      workspace.openFileText.isEmpty,
                      let localURL = workspace.openFileLocalURL {
                ExternalFileNoticePane(fileURL: localURL)
            } else if let path = workspace.selectedFilePath,
                      WorkspaceController.isMarkdownPath(path),
                      markdownMode == .preview,
                      !workspace.openFileText.isEmpty {
                MarkdownFilePreviewPane(
                    workspace: workspace,
                    filePath: path,
                    onPreviewImage: { item in previewImageItem = item }
                )
            } else {
                FilePreviewPane(
                    workspace: workspace,
                    selectedPassage: $selectedPreviewPassage,
                    selectedLineRange: $selectedPreviewLineRange,
                    onQuoteSelection: onQuoteToComposer != nil ? { quoteCurrentToComposer() } : nil
                )
            }
        }
        .sheet(item: $previewImageItem) { item in
            PrismImageLightboxView(item: item)
                .environment(\.prismTokens, tokens)
                .environment(\.prismL10n, l10n)
                .preferredColorScheme(tokens.palette.colorScheme)
        }
    }

    private var markdownModeToggle: some View {
        HStack(spacing: 2) {
            ForEach(MarkdownPreviewMode.allCases) { mode in
                let selected = markdownMode == mode
                Button {
                    markdownModeRaw = mode.rawValue
                } label: {
                    Text(l10n.tr(mode == .preview ? "workbench.preview" : "workbench.source"))
                        .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? tokens.foreground : tokens.mutedForeground)
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(Capsule().fill(selected ? tokens.surface2 : Color.clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(tokens.hoverWash))
        .overlay(Capsule().strokeBorder(tokens.borderEtched, lineWidth: 1))
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func treeRowView(_ row: FileTreeRow) -> some View {
        let indent = CGFloat(row.depth) * 14
        switch row.kind {
        case .folder(let isExpanded):
            let isDropTarget = dropTargetedFolder == row.path
            Button {
                toggleFolder(row.path)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(tokens.placeholder)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 11)
                    Image(systemName: isExpanded ? "folder.fill" : "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(row.isIgnored ? tokens.mutedForeground : tokens.prismCobalt)
                    Text(row.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(row.isIgnored ? tokens.mutedForeground : tokens.secondaryForeground)
                        .lineLimit(1)
                    Spacer()
                }
                .opacity(row.isIgnored ? 0.65 : 1.0)
                .padding(.leading, 8 + indent)
                .padding(.trailing, 10)
                .padding(.vertical, 4.5)
                .background(
                    RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                        .fill(isDropTarget ? tokens.primarySoft : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                        .strokeBorder(isDropTarget ? tokens.primaryBorder : Color.clear, lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .task(id: isExpanded && row.isIgnored && workspace.loadedIgnoredFolders[row.path] == nil) {
                if isExpanded && row.isIgnored { await workspace.loadIgnoredFolder(row.path) }
            }
            .contextMenu {
                #if os(macOS)
                Button {
                    presentUploadPanel(intoFolder: row.path)
                } label: {
                    Label(l10n.tr("files.uploadToFolder"), systemImage: "arrow.up.doc")
                }
                if !workspace.isRemoteWorkspace,
                   let folderURL = WorkspaceController.safeContainedFileURL(rootPath: workspace.activeProjectPath, path: row.path) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([folderURL])
                    } label: {
                        Label(l10n.tr("contextMenu.revealInFinder"), systemImage: "folder")
                    }
                }
                #endif
            }
            .onDrop(of: [.fileURL], isTargeted: Binding(
                get: { dropTargetedFolder == row.path },
                set: { targeted in
                    if targeted {
                        dropTargetedFolder = row.path
                    } else if dropTargetedFolder == row.path {
                        dropTargetedFolder = nil
                    }
                }
            )) { providers in
                handleFileDrop(providers, intoFolder: row.path)
            }

        case .file:
            let selected = workspace.selectedFilePath == row.path
            Button {
                Task { await workspace.openFile(path: row.path) }
            } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(row.isIgnored ? tokens.mutedForeground : fileAccentColor(row.path))
                        .frame(width: 5.5, height: 5.5)
                    Text(row.name)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(
                            row.isIgnored
                                ? tokens.mutedForeground
                                : (selected ? tokens.foreground : tokens.secondaryForeground)
                        )
                        .lineLimit(1)
                    if workspace.isFileModified(row.path) {
                        Circle()
                            .fill(tokens.warning)
                            .frame(width: 5, height: 5)
                            .help(l10n.tr("workbench.fileModified"))
                    }
                    Spacer()
                }
                .opacity(row.isIgnored ? 0.65 : 1.0)
                .padding(.leading, 20 + indent)
                .padding(.trailing, 10)
                .padding(.vertical, 4.5)
                .background(
                    RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                        .fill(selected ? tokens.activeWash : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            #if os(macOS)
            .contextMenu {
                if !workspace.isRemoteWorkspace,
                   let fileURL = WorkspaceController.safeContainedFileURL(rootPath: workspace.activeProjectPath, path: row.path) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                    } label: {
                        Label(l10n.tr("contextMenu.revealInFinder"), systemImage: "folder")
                    }
                }
            }
            #endif

        case .loading:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.68)
                Text(row.name)
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.mutedForeground)
                Spacer()
            }
            .opacity(0.65)
            .padding(.leading, 20 + indent)
            .padding(.trailing, 10)
            .padding(.vertical, 4)

        case .emptyIgnored:
            HStack(spacing: 6) {
                Text(row.name)
                    .font(.system(size: 11))
                    .italic()
                    .foregroundStyle(tokens.mutedForeground)
                Spacer()
            }
            .opacity(0.65)
            .padding(.leading, 20 + indent)
            .padding(.trailing, 10)
            .padding(.vertical, 4)
        }
    }

    private func filteredFileRow(path: String) -> some View {
        let selected = workspace.selectedFilePath == path
        let ignored = workspace.isIgnored(path: path)
        return Button {
            Task { await workspace.openFile(path: path) }
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(ignored ? tokens.mutedForeground : fileAccentColor(path))
                    .frame(width: 5.5, height: 5.5)
                Text((path as NSString).lastPathComponent)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(
                        ignored
                            ? tokens.mutedForeground
                            : (selected ? tokens.foreground : tokens.secondaryForeground)
                    )
                    .lineLimit(1)
                if workspace.isFileModified(path) {
                    Circle()
                        .fill(tokens.warning)
                        .frame(width: 5, height: 5)
                        .help(l10n.tr("workbench.fileModified"))
                }
                Spacer()
                Text((path as NSString).deletingLastPathComponent)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(tokens.placeholder)
                    .lineLimit(1)
            }
            .opacity(ignored ? 0.65 : 1.0)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                    .fill(selected ? tokens.activeWash : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .contextMenu {
            if !workspace.isRemoteWorkspace,
               let fileURL = WorkspaceController.safeContainedFileURL(rootPath: workspace.activeProjectPath, path: path) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                } label: {
                    Label(l10n.tr("contextMenu.revealInFinder"), systemImage: "folder")
                }
            }
        }
        #endif
    }

    private func clearSelectionState() {
        selectedPreviewPassage = ""
        selectedPreviewLineRange = nil
        editorSelection = nil
    }

    private func currentSelectedPassage() -> (passage: String, lineRange: ClosedRange<Int>?)? {
        if workspace.isEditingFile {
            guard let selection = editorSelection else { return nil }
            let text = workspace.openFileText
            switch selection.indices {
            case .selection(let range):
                guard range.lowerBound < range.upperBound,
                      range.lowerBound >= text.startIndex,
                      range.upperBound <= text.endIndex else {
                    return nil
                }
                let raw = String(text[range])
                guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                let lineRange = Self.lineRange(in: text, for: range)
                return (raw, lineRange)
            case .multiSelection(let rangeSet):
                guard let first = rangeSet.ranges.first,
                      first.lowerBound < first.upperBound,
                      first.lowerBound >= text.startIndex,
                      first.upperBound <= text.endIndex else {
                    return nil
                }
                let raw = String(text[first])
                guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                let lineRange = Self.lineRange(in: text, for: first)
                return (raw, lineRange)
            @unknown default:
                return nil
            }
        }
        guard !selectedPreviewPassage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return (selectedPreviewPassage, selectedPreviewLineRange)
    }

    private func quoteCurrentToComposer() {
        guard let onQuoteToComposer, let path = workspace.selectedFilePath else { return }
        if let selected = currentSelectedPassage() {
            let quote = WorkspaceController.formatPassageQuote(
                path: path,
                passage: selected.passage,
                lineRange: selected.lineRange
            )
            onQuoteToComposer(quote)
        } else {
            let quote = WorkspaceController.formatPassageQuote(
                path: path,
                passage: "",
                fullContent: nil
            )
            onQuoteToComposer(quote)
        }
    }

    private static func lineRange(in text: String, for range: Range<String.Index>) -> ClosedRange<Int>? {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper && text[lower] == "\n" {
            lower = text.index(after: lower)
        }
        while upper > lower && text[text.index(before: upper)] == "\n" {
            upper = text.index(before: upper)
        }
        guard lower < upper else { return nil }
        let startLine = text[..<lower].utf8.reduce(1) { $0 + ($1 == UInt8(ascii: "\n") ? 1 : 0) }
        let innerNewlines = text[lower..<upper].utf8.reduce(0) { $0 + ($1 == UInt8(ascii: "\n") ? 1 : 0) }
        return startLine...(startLine + innerNewlines)
    }

    private func toggleFolder(_ folderPath: String) {
        if expandedFolders.contains(folderPath) {
            expandedFolders.remove(folderPath)
        } else {
            expandedFolders.insert(folderPath)
        }
    }

    #if os(macOS)
    private func presentUploadPanel(intoFolder folder: String) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = l10n.tr("files.uploadFiles")
        let generation = workspace.projectGeneration
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            let urls = panel.urls
            Task { await workspace.uploadFiles(urls: urls, intoFolder: folder, generation: generation) }
        }
    }
    #endif

    private func handleFileDrop(_ providers: [NSItemProvider], intoFolder folder: String) -> Bool {
        let matching = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !matching.isEmpty else { return false }
        let collector = DroppedFileURLCollector()
        let group = DispatchGroup()
        let controller = workspace
        let generation = workspace.projectGeneration
        for provider in matching {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let resolvedURL: URL?
                if let data = item as? Data {
                    resolvedURL = URL(dataRepresentation: data, relativeTo: nil)
                } else if let url = item as? URL {
                    resolvedURL = url
                } else if let str = item as? String {
                    resolvedURL = URL(string: str)
                } else {
                    resolvedURL = nil
                }
                if let resolvedURL, resolvedURL.isFileURL {
                    collector.append(resolvedURL)
                }
            }
        }
        group.notify(queue: .main) {
            let urls = collector.snapshot()
            guard !urls.isEmpty else { return }
            Task { @MainActor in
                await controller.uploadFiles(urls: urls, intoFolder: folder, generation: generation)
            }
        }
        return true
    }

    private var saveConflictBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(tokens.warning)
            Text(l10n.tr("workbench.conflict.message"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tokens.foreground)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Button(l10n.tr("workbench.conflict.reload")) {
                Task { await workspace.reloadOpenFile() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(tokens.secondaryForeground)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tokens.hoverWash))
            Button(l10n.tr("workbench.conflict.overwrite")) {
                Task { await workspace.saveOpenFile(overwrite: true) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(tokens.danger)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tokens.danger.opacity(0.12)))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tokens.warningSoft)
    }

    private func fileAccentColor(_ path: String) -> Color {
        if path.hasSuffix(".swift") { return Color(hex: 0xF05138) }
        if path.hasSuffix(".ts") || path.hasSuffix(".tsx") { return Color(hex: 0x3178C6) }
        if path.hasSuffix(".metal") { return tokens.prismIris }
        if path.hasSuffix(".json") || path.hasSuffix(".yml") { return tokens.warning }
        if path.hasSuffix(".md") { return tokens.success }
        return tokens.mutedForeground
    }
}

/// Friendly notice for local files outside the active project & session folders, offering a safe
/// Reveal-in-Finder action instead of an empty code editor.
private struct ExternalFileNoticePane: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    let fileURL: URL

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 12)
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(tokens.mutedForeground)
            Text(fileURL.lastPathComponent)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tokens.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(fileURL.path)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(tokens.placeholder)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .truncationMode(.middle)
                .padding(.horizontal, 20)
            Text(l10n.tr("workbench.externalFileNote"))
                .font(.system(size: 11.5))
                .foregroundStyle(tokens.secondaryForeground)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            #if os(macOS)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                        .font(.system(size: 11, weight: .medium))
                    Text(l10n.tr("contextMenu.revealInFinder"))
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(tokens.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(tokens.primarySoft))
                .overlay(Capsule().strokeBorder(tokens.primaryBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            #endif
            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tokens.codeBackground)
    }
}

/// Native image viewer for raster images opened in the Files workbench pane (both project files and
/// authenticated per-session agent files), with click-to-lightbox zoom and Finder reveal.
private struct ImageFilePreviewPane: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    let data: Data
    let title: String
    let localURL: URL?
    let onPreviewImage: (PrismImagePreviewItem) -> Void

    private var decodedImage: (image: Image, pixelSize: CGSize?)? {
        #if os(macOS)
        guard let nsImg = NSImage(data: data) else { return nil }
        let rep = nsImg.representations.first
        let size: CGSize? = rep.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) }
        return (Image(nsImage: nsImg), size)
        #else
        guard let uiImg = UIImage(data: data) else { return nil }
        return (Image(uiImage: uiImg), CGSize(width: uiImg.size.width * uiImg.scale, height: uiImg.size.height * uiImg.scale))
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let decoded = decodedImage {
                    Button {
                        onPreviewImage(PrismImagePreviewItem(title: title, data: data))
                    } label: {
                        decoded.image
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 520)
                            .clipShape(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                                    .strokeBorder(tokens.borderEtched, lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    #if os(macOS)
                    .contextMenu {
                        Button {
                            onPreviewImage(PrismImagePreviewItem(title: title, data: data))
                        } label: {
                            Label(l10n.tr("workbench.preview"), systemImage: "magnifyingglass")
                        }
                        if let localURL {
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([localURL])
                            } label: {
                                Label(l10n.tr("contextMenu.revealInFinder"), systemImage: "folder")
                            }
                        }
                    }
                    #endif

                    HStack(spacing: 8) {
                        if let size = decoded.pixelSize, size.width > 0, size.height > 0 {
                            Text("\(Int(size.width)) × \(Int(size.height))")
                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(tokens.mutedForeground)
                        }
                        Text(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(tokens.placeholder)
                        Spacer()
                        #if os(macOS)
                        if let localURL {
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([localURL])
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "folder")
                                        .font(.system(size: 10, weight: .medium))
                                    Text(l10n.tr("contextMenu.revealInFinder"))
                                        .font(.system(size: 10.5, weight: .medium))
                                }
                                .foregroundStyle(tokens.secondaryForeground)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3.5)
                                .background(Capsule().fill(tokens.hoverWash))
                                .overlay(Capsule().strokeBorder(tokens.borderEtched, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                        #endif
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .background(tokens.codeBackground)
    }
}

/// Rendered GitHub-Flavored Markdown + safe HTML preview for `.md` files in the Files workbench
/// pane (both project files and host-authenticated per-session agent files).
private struct MarkdownFilePreviewPane: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    let workspace: WorkspaceController
    let filePath: String
    let onPreviewImage: (PrismImagePreviewItem) -> Void

    @State private var rendered: GitHubMarkdownHTMLRenderer.Output? = nil
    @State private var allowRemoteImages: Bool = false

    private var allowedImageRoot: String? {
        guard !workspace.isRemoteWorkspace else { return nil }
        if let agentFolder = workspace.openFileAgentFolder, !agentFolder.isEmpty {
            return agentFolder
        }
        return workspace.activeProjectPath.isEmpty ? nil : workspace.activeProjectPath
    }

    private var baseDirectory: String? {
        guard let root = allowedImageRoot else { return nil }
        if filePath.hasPrefix("/") {
            return (filePath as NSString).deletingLastPathComponent
        }
        let full = URL(fileURLWithPath: root).appendingPathComponent(filePath)
        return full.deletingLastPathComponent().path
    }

    private struct RenderTrigger: Equatable {
        let revision: UInt64
        let filePath: String
        let allowedRoot: String?
        let allowRemoteImages: Bool
        let theme: MarkdownPreviewTheme
    }

    var body: some View {
        let theme = MarkdownPreviewTheme(tokens: tokens)
        let trigger = RenderTrigger(
            revision: workspace.openFileTextRevision,
            filePath: filePath,
            allowedRoot: allowedImageRoot,
            allowRemoteImages: allowRemoteImages,
            theme: theme
        )

        VStack(spacing: 0) {
            if let out = rendered, out.gatedRemoteImageCount > 0 && !allowRemoteImages {
                HStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 10.5))
                        .foregroundStyle(tokens.mutedForeground)
                    Text("\(out.gatedRemoteImageCount)")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(tokens.secondaryForeground)
                    Spacer()
                    Button(l10n.tr("thread.image.loadRemote")) {
                        allowRemoteImages = true
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(tokens.primary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(tokens.surface1)
                Rectangle().fill(tokens.borderEtched).frame(height: 1)
            }

            #if os(macOS)
            if let out = rendered {
                MarkdownDocumentWebView(
                    html: out.html,
                    isDark: tokens.palette.isDark,
                    onOpenLocalFile: { fullPath in
                        let rel = ThreadTimelineBuilder.relativeDisplayPath(fullPath, projectPath: workspace.activeProjectPath)
                        Task { await workspace.openFile(path: rel) }
                    },
                    onPreviewLocalImage: { index in
                        guard index >= 0 && index < out.localImages.count else { return }
                        let asset = out.localImages[index]
                        onPreviewImage(PrismImagePreviewItem(title: asset.title, data: asset.data))
                    }
                )
            } else {
                Color.clear
            }
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tokens.codeBackground)
        .onChange(of: filePath) { _, _ in
            allowRemoteImages = false
        }
        .task(id: trigger) {
            let text = workspace.openFileText
            let options = GitHubMarkdownHTMLRenderer.Options(
                allowedRoot: trigger.allowedRoot,
                baseDirectory: baseDirectory,
                activeProjectPath: workspace.activeProjectPath,
                allowRemoteImages: trigger.allowRemoteImages,
                theme: trigger.theme
            )
            let compiled = await Task.detached(priority: .userInitiated) {
                GitHubMarkdownHTMLRenderer.render(markdown: text, options: options)
            }.value
            guard !Task.isCancelled else { return }
            rendered = compiled
        }
    }
}

/// Lines of the open file for the read-only preview, split once per text change and off the main actor.
private struct FilePreviewLines: Sendable, Equatable {
    static let maxShownLines = 5_000
    static let empty = FilePreviewLines(lines: [], joinedText: "", totalLines: 0)

    var lines: [String]
    var joinedText: String
    var totalLines: Int

    static func split(_ text: String) -> FilePreviewLines {
        var lines: [String] = []
        var total = 0
        for slice in text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            total += 1
            guard lines.count < maxShownLines else { continue }
            let trimmed = slice.last == UInt8(ascii: "\r") ? slice.dropLast() : slice
            lines.append(String(decoding: trimmed, as: UTF8.self))
        }
        return FilePreviewLines(lines: lines, joinedText: lines.joined(separator: "\n"), totalLines: total)
    }
}

private struct FilePreviewPane: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    let workspace: WorkspaceController
    @Binding var selectedPassage: String
    @Binding var selectedLineRange: ClosedRange<Int>?
    var onQuoteSelection: (() -> Void)? = nil

    @State private var preview = FilePreviewLines.empty
    @State private var renderedRevision: UInt64 = 0

    var body: some View {
        VStack(spacing: 0) {
            if preview.totalLines > preview.lines.count {
                HStack(spacing: 8) {
                    Image(systemName: "text.badge.xmark")
                        .font(.system(size: 10.5))
                        .foregroundStyle(tokens.mutedForeground)
                    Text(l10n.tr("workbench.preview.truncated", preview.lines.count, preview.totalLines))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(tokens.secondaryForeground)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if workspace.openFileEditable {
                        Button(l10n.tr("workbench.preview.openInEditor")) {
                            workspace.isEditingFile = true
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(tokens.primary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(tokens.surface1)
                Rectangle().fill(tokens.borderEtched).frame(height: 1)
            }
            #if os(macOS)
            SelectableCodePreviewView(
                text: preview.joinedText,
                lineCount: preview.lines.count,
                revision: renderedRevision,
                tokens: tokens,
                quoteMenuTitle: l10n.tr("files.quoteSelection"),
                onSelectionChanged: { passage, lineRange in
                    if selectedPassage != passage {
                        selectedPassage = passage
                    }
                    if selectedLineRange != lineRange {
                        selectedLineRange = lineRange
                    }
                },
                onQuoteSelection: onQuoteSelection
            )
            #else
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 1.5) {
                    ForEach(preview.lines.indices, id: \.self) { idx in
                        HStack(spacing: 10) {
                            Text("\(idx + 1)")
                                .frame(width: 34, alignment: .trailing)
                                .foregroundStyle(tokens.placeholder)
                            Text(preview.lines[idx])
                                .foregroundStyle(tokens.secondaryForeground)
                                .textSelection(.enabled)
                            Spacer(minLength: 12)
                        }
                        .font(.system(size: 11.5, design: .monospaced))
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 8)
            }
            .background(tokens.codeBackground)
            #endif
        }
        .task(id: workspace.openFileTextRevision) {
            let text = workspace.openFileText
            let targetRevision = workspace.openFileTextRevision
            let next = await Task.detached(priority: .userInitiated) {
                FilePreviewLines.split(text)
            }.value
            guard !Task.isCancelled else { return }
            preview = next
            renderedRevision = targetRevision
        }
    }
}

#if os(macOS)
/// Read-only monospaced code viewer with a virtualized line-number gutter and native multi-line
/// text selection so users can quote exact passages into the composer.
private struct SelectableCodePreviewView: NSViewRepresentable {
    let text: String
    let lineCount: Int
    let revision: UInt64
    let tokens: PrismTokens
    let quoteMenuTitle: String
    let onSelectionChanged: (String, ClosedRange<Int>?) -> Void
    let onQuoteSelection: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onSelectionChanged: onSelectionChanged,
            onQuoteSelection: onQuoteSelection,
            quoteMenuTitle: quoteMenuTitle
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.clipsToBounds = true

        let textView = SelectableCodeTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator

        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true

        let ruler = CodeLineNumberRulerView(scrollView: scrollView, orientation: .verticalRuler)
        ruler.clientView = textView
        ruler.clipsToBounds = true
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        context.coordinator.textView = textView
        context.coordinator.rulerView = ruler
        context.coordinator.observeScroll(clipView: scrollView.contentView)

        applyAppearance(scrollView: scrollView, textView: textView, ruler: ruler)
        applyTextIfNeeded(textView: textView, ruler: ruler, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onSelectionChanged = onSelectionChanged
        context.coordinator.onQuoteSelection = onQuoteSelection
        context.coordinator.quoteMenuTitle = quoteMenuTitle

        guard let textView = context.coordinator.textView,
              let ruler = context.coordinator.rulerView else {
            return
        }
        applyAppearance(scrollView: scrollView, textView: textView, ruler: ruler)
        applyTextIfNeeded(textView: textView, ruler: ruler, coordinator: context.coordinator)
    }

    private func applyAppearance(
        scrollView: NSScrollView,
        textView: SelectableCodeTextView,
        ruler: CodeLineNumberRulerView
    ) {
        let bg = NSColor(tokens.codeBackground)
        let fg = NSColor(tokens.secondaryForeground)
        let gutterFg = NSColor(tokens.placeholder)
        let divider = NSColor(tokens.borderEtched)
        let selectionBg = NSColor(tokens.primarySoft)

        scrollView.backgroundColor = bg
        textView.backgroundColor = bg
        textView.textColor = fg
        textView.selectedTextAttributes = [
            .backgroundColor: selectionBg,
            .foregroundColor: NSColor(tokens.foreground),
        ]

        ruler.backgroundColor = bg
        ruler.textColor = gutterFg
        ruler.dividerColor = divider
        ruler.updateThickness(forLineCount: max(lineCount, 1))
        ruler.needsDisplay = true
    }

    private func applyTextIfNeeded(
        textView: SelectableCodeTextView,
        ruler: CodeLineNumberRulerView,
        coordinator: Coordinator
    ) {
        guard coordinator.lastRevision != revision || textView.string != text else { return }
        coordinator.isApplyingText = true
        let previousSelectedRange = textView.selectedRange()
        textView.string = text
        textView.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        textView.textColor = NSColor(tokens.secondaryForeground)
        let length = (text as NSString).length
        if coordinator.lastRevision == revision,
           previousSelectedRange.location + previousSelectedRange.length <= length {
            textView.setSelectedRange(previousSelectedRange)
        } else {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            if previousSelectedRange.length > 0 {
                let notify = coordinator.onSelectionChanged
                Task { @MainActor in
                    notify("", nil)
                }
            }
        }
        coordinator.lastRevision = revision
        coordinator.isApplyingText = false
        ruler.needsDisplay = true
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var onSelectionChanged: (String, ClosedRange<Int>?) -> Void
        var onQuoteSelection: (() -> Void)?
        var quoteMenuTitle: String
        var lastRevision: UInt64 = .max
        var isApplyingText: Bool = false
        weak var textView: SelectableCodeTextView?
        weak var rulerView: CodeLineNumberRulerView?
        nonisolated(unsafe) private var boundsObserver: NSObjectProtocol?

        init(
            onSelectionChanged: @escaping (String, ClosedRange<Int>?) -> Void,
            onQuoteSelection: (() -> Void)?,
            quoteMenuTitle: String
        ) {
            self.onSelectionChanged = onSelectionChanged
            self.onQuoteSelection = onQuoteSelection
            self.quoteMenuTitle = quoteMenuTitle
        }

        deinit {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
        }

        func observeScroll(clipView: NSClipView) {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.rulerView?.needsDisplay = true
                }
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplyingText, let textView = notification.object as? NSTextView else { return }
            let selected = textView.selectedRange()
            let fullString = textView.string as NSString
            guard selected.length > 0,
                  selected.location >= 0,
                  selected.location + selected.length <= fullString.length else {
                onSelectionChanged("", nil)
                return
            }
            let rawPassage = fullString.substring(with: selected)
            guard !rawPassage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                onSelectionChanged("", nil)
                return
            }
            let lineRange = Self.lineRange(in: fullString, for: selected)
            onSelectionChanged(rawPassage, lineRange)
        }

        @objc func quoteSelectionAction(_ sender: Any?) {
            onQuoteSelection?()
        }

        private static func lineRange(in fullString: NSString, for nsRange: NSRange) -> ClosedRange<Int>? {
            var loc = nsRange.location
            var end = nsRange.location + nsRange.length
            while loc < end && fullString.character(at: loc) == 0x0A {
                loc += 1
            }
            while end > loc && fullString.character(at: end - 1) == 0x0A {
                end -= 1
            }
            guard loc < end else { return nil }
            var startLine = 1
            var idx = 0
            while idx < loc {
                if fullString.character(at: idx) == 0x0A {
                    startLine += 1
                }
                idx += 1
            }
            var endLine = startLine
            idx = loc
            while idx < end {
                if fullString.character(at: idx) == 0x0A {
                    endLine += 1
                }
                idx += 1
            }
            return startLine...endLine
        }
    }
}

private final class SelectableCodeTextView: NSTextView {
    weak var coordinator: SelectableCodePreviewView.Coordinator?

    override func menu(for event: NSEvent) -> NSMenu? {
        let baseMenu = super.menu(for: event) ?? NSMenu()
        guard let coordinator, coordinator.onQuoteSelection != nil else {
            return baseMenu
        }
        let range = selectedRange()
        let content = string as NSString
        if range.length > 0,
           range.location + range.length <= content.length,
           !content.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let item = NSMenuItem(
                title: coordinator.quoteMenuTitle,
                action: #selector(SelectableCodePreviewView.Coordinator.quoteSelectionAction(_:)),
                keyEquivalent: ""
            )
            item.target = coordinator
            baseMenu.insertItem(item, at: 0)
            baseMenu.insertItem(.separator(), at: 1)
        }
        return baseMenu
    }
}

private final class CodeLineNumberRulerView: NSRulerView {
    var backgroundColor: NSColor = .clear
    var textColor: NSColor = .secondaryLabelColor
    var dividerColor: NSColor = .separatorColor

    private let gutterFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)

    func updateThickness(forLineCount count: Int) {
        let digits = max(3, String(count).count)
        let desired = CGFloat(digits) * 7.5 + 18
        if abs(ruleThickness - desired) > 0.5 {
            ruleThickness = desired
        }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        // On macOS 14+ AppKit passes an unclipped dirty rect that can extend outside `bounds`.
        // Always intersect with `bounds` so filling the gutter cannot paint over neighboring views.
        let drawRect = rect.intersection(bounds)
        guard !drawRect.isEmpty else { return }

        backgroundColor.setFill()
        drawRect.fill()

        dividerColor.setFill()
        NSRect(x: bounds.maxX - 1, y: drawRect.minY, width: 1, height: drawRect.height).fill()

        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let scrollView else {
            return
        }

        let content = textView.string as NSString
        let visibleRect = scrollView.contentView.bounds
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let visibleCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)

        var lineNumber = 1
        var scanIdx = 0
        while scanIdx < visibleCharRange.location {
            if content.character(at: scanIdx) == 0x0A {
                lineNumber += 1
            }
            scanIdx += 1
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: gutterFont,
            .foregroundColor: textColor,
        ]
        let insetY = textView.textContainerInset.height

        var charIdx = visibleCharRange.location
        let maxIdx = NSMaxRange(visibleCharRange)

        if content.length == 0 {
            let y = convert(NSPoint(x: 0, y: insetY), from: textView).y
            drawNumber(1, atY: y + 2, attrs: attrs)
            return
        }

        while charIdx <= maxIdx && charIdx < content.length {
            let lineRange = content.lineRange(for: NSRange(location: charIdx, length: 0))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: charIdx)
            if glyphIndex < layoutManager.numberOfGlyphs {
                let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
                let y = convert(NSPoint(x: 0, y: lineRect.minY + insetY), from: textView).y
                drawNumber(lineNumber, atY: y, attrs: attrs)
            }
            lineNumber += 1
            let nextIdx = NSMaxRange(lineRange)
            if nextIdx <= charIdx { break }
            charIdx = nextIdx
        }

        if content.length > 0 && content.character(at: content.length - 1) == 0x0A {
            let extraRect = layoutManager.extraLineFragmentRect
            if extraRect.height > 0 {
                let y = convert(NSPoint(x: 0, y: extraRect.minY + insetY), from: textView).y
                drawNumber(lineNumber, atY: y, attrs: attrs)
            }
        }
    }

    private func drawNumber(_ number: Int, atY y: CGFloat, attrs: [NSAttributedString.Key: Any]) {
        let label = "\(number)" as NSString
        let size = label.size(withAttributes: attrs)
        let drawPoint = NSPoint(x: ruleThickness - size.width - 8, y: y + 1)
        label.draw(at: drawPoint, withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            super.mouseDown(with: event)
            return
        }
        let textPoint = textView.convert(event.locationInWindow, from: nil)
        let textY = textPoint.y - textView.textContainerInset.height
        let glyphIndex = layoutManager.glyphIndex(
            for: NSPoint(x: 0, y: max(0, textY)),
            in: textContainer,
            fractionOfDistanceThroughGlyph: nil
        )
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        let content = textView.string as NSString
        guard content.length > 0, charIndex <= content.length else { return }
        let lineRange = content.lineRange(for: NSRange(location: min(charIndex, content.length - 1), length: 0))
        if event.modifierFlags.contains(.shift) {
            let existing = textView.selectedRange()
            if existing.length > 0 {
                let start = min(existing.location, lineRange.location)
                let end = max(NSMaxRange(existing), NSMaxRange(lineRange))
                textView.setSelectedRange(NSRange(location: start, length: end - start))
                textView.window?.makeFirstResponder(textView)
                return
            }
        }
        textView.setSelectedRange(lineRange)
        textView.window?.makeFirstResponder(textView)
    }
}
#endif

// MARK: - 3. Embedded Interactive ANSI PTY Terminal

public struct TerminalWorkbenchView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    @Bindable public var workspace: WorkspaceController

    @State private var renamingTabID: String? = nil
    @State private var renameDraft: String = ""

    public init(workspace: WorkspaceController) {
        self.workspace = workspace
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Terminal tab strip
            HStack(spacing: 5) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(workspace.terminals) { tab in
                            let selected = workspace.activeTerminal?.id == tab.id
                            let dotColor: Color = tab.info.isWaitingForPassword
                                ? tokens.warning
                                : (tab.info.control.isAgent || tab.info.owner != nil ? tokens.prismCobalt : (tab.isRemote ? tokens.prismIris : tokens.success))
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(dotColor)
                                    .frame(width: 5.5, height: 5.5)
                                if tab.info.isWaitingForPassword {
                                    Image(systemName: "lock.fill")
                                        .font(.system(size: 8.5, weight: .bold))
                                        .foregroundStyle(tokens.warning)
                                }
                                Text(tab.info.displayTitle)
                                    .font(.system(size: 11, weight: selected ? .semibold : .regular, design: .monospaced))
                                    .foregroundStyle(selected ? tokens.foreground : tokens.mutedForeground)
                                    .lineLimit(1)
                                if workspace.terminals.count > 1 {
                                    Button {
                                        Task { await workspace.closeTerminal(id: tab.id) }
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 8.5, weight: .bold))
                                            .foregroundStyle(tokens.placeholder)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(selected ? tokens.activeWash : Color.clear))
                            .overlay(Capsule().strokeBorder(selected ? tokens.border : Color.clear, lineWidth: 1))
                            .onTapGesture {
                                workspace.activeTerminalID = tab.id
                            }
                            .contextMenu {
                                Button(l10n.tr("workbench.terminal.rename")) {
                                    renameDraft = tab.info.name ?? tab.info.displayTitle
                                    renamingTabID = tab.id
                                }
                                if tab.isRemote {
                                    Button(l10n.tr("workbench.terminal.restart")) {
                                        Task { await workspace.restartTerminal(id: tab.id) }
                                    }
                                }
                                if tab.info.owner == nil && tab.info.agentAllowed {
                                    Button(l10n.tr("workbench.terminal.revokeAccess")) {
                                        Task { await workspace.revokeTerminalAccess(id: tab.id) }
                                    }
                                }
                                if workspace.terminals.count > 1 {
                                    Divider()
                                    Button(l10n.tr("workbench.terminal.close"), role: .destructive) {
                                        Task { await workspace.closeTerminal(id: tab.id) }
                                    }
                                }
                            }
                            .popover(isPresented: Binding(
                                get: { renamingTabID == tab.id },
                                set: { if !$0 { renamingTabID = nil } }
                            )) {
                                HStack(spacing: 6) {
                                    TextField(l10n.tr("workbench.terminal.renamePlaceholder"), text: $renameDraft)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 12))
                                        .foregroundStyle(tokens.foreground)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .frame(width: 170)
                                        .background(RoundedRectangle(cornerRadius: tokens.rXS).fill(tokens.codeBackground))
                                        .overlay(RoundedRectangle(cornerRadius: tokens.rXS).strokeBorder(tokens.borderEtched, lineWidth: 1))
                                        .onSubmit {
                                            let target = tab.id
                                            let next = renameDraft
                                            renamingTabID = nil
                                            Task { await workspace.renameTerminal(id: target, name: next) }
                                        }
                                    Button(l10n.tr("workbench.save")) {
                                        let target = tab.id
                                        let next = renameDraft
                                        renamingTabID = nil
                                        Task { await workspace.renameTerminal(id: target, name: next) }
                                    }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(tokens.primary)
                                }
                                .padding(10)
                                .background(tokens.surface1)
                            }
                        }
                    }
                }

                Button {
                    Task { await workspace.createTerminal() }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tokens.mutedForeground)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(tokens.hoverWash))
                }
                .buttonStyle(.plain)
                .help(l10n.tr("workbench.newTerminalTooltip"))

                Button("Ctrl+C") {
                    Task { await workspace.sendTerminalInput("\u{0003}") }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(tokens.warning)
                .padding(.horizontal, 7)
                .padding(.vertical, 3.5)
                .background(Capsule().fill(tokens.warningSoft))

                Button {
                    workspace.clearTerminal()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10.5))
                        .foregroundStyle(tokens.mutedForeground)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help(l10n.tr("workbench.clearTerminalTooltip"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tokens.codeHeaderBackground)

            if let activeInfo = workspace.activeTerminal?.info,
               activeInfo.isWaitingForPassword || activeInfo.control.isAgent || activeInfo.control.isYou || (activeInfo.owner == nil && activeInfo.agentAllowed) {
                Rectangle().fill(tokens.borderEtched).frame(height: 1)
                terminalCollaborationBanner(info: activeInfo)
            }

            Rectangle().fill(tokens.borderEtched).frame(height: 1)

            // Virtualized ANSI-colored PTY Output Stream (isolated from command input state)
            EmbeddedTerminalPane(tab: workspace.activeTerminal) { tabID, cols, rows in
                Task { await workspace.resizeTerminal(id: tabID, cols: cols, rows: rows) }
            }

            Rectangle().fill(tokens.borderEtched).frame(height: 1)

            // Isolated Command Input Strip (typing never invalidates terminal output lines)
            TerminalCommandInputBar { cmd in
                Task { await workspace.sendTerminalInput(cmd + "\n") }
            }
        }
        .task {
            await workspace.ensureDefaultTerminal()
        }
    }

    @ViewBuilder
    private func terminalCollaborationBanner(info: TerminalInfo) -> some View {
        HStack(spacing: 8) {
            if info.isWaitingForPassword {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(tokens.warning)
                Text(l10n.tr("workbench.terminal.waitingPassword"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tokens.warning)
                    .lineLimit(1)
            } else if info.control.isAgent {
                Image(systemName: "cpu")
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.prismCobalt)
                Text(l10n.tr("workbench.terminal.agentOperating"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tokens.foreground)
                    .lineLimit(1)
            } else if info.control.isYou {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.prismIris)
                Text(l10n.tr("workbench.terminal.youOperating"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tokens.foreground)
                    .lineLimit(1)
            } else if info.owner == nil && info.agentAllowed {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.success)
                Text(l10n.tr("workbench.terminal.agentAllowed"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tokens.secondaryForeground)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if info.control.isAgent {
                Button(l10n.tr("workbench.terminal.takeOver")) {
                    Task { await workspace.takeOverTerminal(id: info.id) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(tokens.prismCobalt)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(tokens.prismCobalt.opacity(0.14)))
            } else if info.control.isYou {
                Button(l10n.tr("workbench.terminal.handBack")) {
                    Task { await workspace.handBackTerminal(id: info.id) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(tokens.prismIris)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(tokens.prismIris.opacity(0.14)))
            }

            if info.owner == nil && info.agentAllowed {
                Button(l10n.tr("workbench.terminal.revokeAccess")) {
                    Task { await workspace.revokeTerminalAccess(id: info.id) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(tokens.danger)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(tokens.danger.opacity(0.12)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5.5)
        .background(info.isWaitingForPassword ? tokens.warningSoft : tokens.surface1)
    }
}

/// Columns and rows of terminal cells that fit a pane.
private struct TerminalGrid: Equatable, Sendable {
    // Padding and row spacing of `EmbeddedTerminalPane`'s stack.
    static let padding: CGFloat = 12
    static let trailingSpacer: CGFloat = 8
    static let rowSpacing: CGFloat = 2.5

    var cols: Int
    var rows: Int

    static func fitting(_ size: CGSize, cell: CGSize) -> TerminalGrid {
        let width = size.width - padding * 2
        let height = size.height - padding * 2 - trailingSpacer + rowSpacing
        let cols = Int((width / cell.width).rounded(.down))
        let rows = Int((height / (cell.height + rowSpacing)).rounded(.down))
        return TerminalGrid(cols: max(cols, 1), rows: max(rows, 1))
    }
}

/// Advance width and line height of one cell of the terminal font, cached per font.
@MainActor
private enum TerminalCellMetrics {
    private static var cache: [String: CGSize] = [:]

    static func cellSize(family: String, size: CGFloat) -> CGSize {
        let key = "\(family)|\(size)"
        if let hit = cache[key] { return hit }
        #if os(macOS)
        let font = (family.isEmpty ? nil : NSFont(name: family, size: size))
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let width = ("M" as NSString).size(withAttributes: [.font: font]).width
        let height = NSLayoutManager().defaultLineHeight(for: font)
        #else
        let font = (family.isEmpty ? nil : UIFont(name: family, size: size))
            ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let width = ("M" as NSString).size(withAttributes: [.font: font]).width
        let height = font.lineHeight
        #endif
        let cell = CGSize(width: max(width, 1), height: max(height, 1))
        cache[key] = cell
        return cell
    }
}

private struct TerminalResizeRequest: Equatable {
    var tabID: String
    var grid: TerminalGrid
}

private struct TerminalScrollMetrics: Equatable, Sendable {
    var visibleMinY: CGFloat
    var visibleMaxY: CGFloat
    var contentHeight: CGFloat
}

private struct EmbeddedTerminalPane: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismTypography) private var typography

    let tab: TerminalTabBuffer?
    let onResize: (_ tabID: String, _ cols: Int, _ rows: Int) -> Void

    @State private var grid: TerminalGrid?
    /// Off once the user scrolls up, so streaming output no longer drags the view to the bottom.
    @State private var followsOutput = true

    var body: some View {
        let cell = TerminalCellMetrics.cellSize(
            family: typography.terminalFontFamily,
            size: CGFloat(typography.terminalFontSize)
        )
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: TerminalGrid.rowSpacing) {
                    if let lines = tab?.renderedLines {
                        ForEach(lines) { line in
                            TerminalRenderedLineView(line: line, palette: tokens.palette, tokens: tokens)
                                .equatable()
                        }
                    }
                    Color.clear.frame(height: TerminalGrid.trailingSpacer).id("term-end")
                }
                .padding(TerminalGrid.padding)
            }
            .background(tokens.codeBackground)
            .onScrollGeometryChange(for: TerminalScrollMetrics.self) { geo in
                TerminalScrollMetrics(
                    visibleMinY: geo.visibleRect.minY,
                    visibleMaxY: geo.visibleRect.maxY,
                    contentHeight: geo.contentSize.height
                )
            } action: { old, new in
                if new.contentHeight - new.visibleMaxY <= 24 {
                    if !followsOutput { followsOutput = true }
                } else if new.visibleMinY < old.visibleMinY - 0.5 && new.contentHeight <= old.contentHeight + 0.5 {
                    // Moving up while the content did not grow is the user scrolling back.
                    if followsOutput { followsOutput = false }
                }
            }
            .onChange(of: tab?.outputRevision ?? 0) { _, _ in
                if followsOutput {
                    proxy.scrollTo("term-end", anchor: .bottom)
                }
            }
            .onChange(of: tab?.id) { _, _ in
                followsOutput = true
                proxy.scrollTo("term-end", anchor: .bottom)
            }
        }
        .onGeometryChange(for: TerminalGrid.self) { geo in
            TerminalGrid.fitting(geo.size, cell: cell)
        } action: { next in
            grid = next
        }
        .task(id: resizeRequest) {
            guard let request = resizeRequest else { return }
            // Debounce live window resizing into one PTY resize.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            onResize(request.tabID, request.grid.cols, request.grid.rows)
        }
    }

    private var resizeRequest: TerminalResizeRequest? {
        guard let tabID = tab?.id, let grid else { return nil }
        return TerminalResizeRequest(tabID: tabID, grid: grid)
    }
}

private struct TerminalRenderedLineView: View, Equatable {
    @Environment(\.prismTypography) private var typography
    let line: TerminalRenderedLine
    let palette: PrismPalette
    let tokens: PrismTokens

    nonisolated static func == (lhs: TerminalRenderedLineView, rhs: TerminalRenderedLineView) -> Bool {
        lhs.line == rhs.line && lhs.palette == rhs.palette
    }

    var body: some View {
        Text(renderLine())
            .font(typography.terminalFont())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func renderLine() -> AttributedString {
        guard !line.spans.isEmpty else {
            return AttributedString(" ")
        }
        var out = AttributedString()
        for span in line.spans {
            var part = AttributedString(span.text)
            part.foregroundColor = ansiColor(for: span.fgCode)
            if span.isBold {
                part.font = typography.terminalFont(weight: .bold)
            }
            out.append(part)
        }
        return out
    }

    private func ansiColor(for code: Int?) -> Color {
        guard let code else { return tokens.foreground.opacity(0.92) }
        switch code {
        case 30, 90: return tokens.mutedForeground
        case 31, 91: return tokens.danger
        case 32, 92: return tokens.success
        case 33, 93: return tokens.warning
        case 34, 94: return tokens.prismCobalt
        case 35, 95: return tokens.prismIris
        case 36, 96: return Color(hex: 0x5CC6FC)
        case 37, 97: return tokens.foreground
        default: return tokens.foreground
        }
    }
}

private struct TerminalCommandInputBar: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    @Environment(\.prismTypography) private var typography
    @State private var commandDraft: String = ""

    let onSubmitCommand: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("$")
                .font(typography.terminalFont(weight: .bold))
                .foregroundStyle(tokens.prismCobalt)
            TextField(l10n.tr("workbench.terminalPlaceholder"), text: $commandDraft)
                .textFieldStyle(.plain)
                .font(typography.terminalFont())
                .foregroundStyle(tokens.foreground)
                .onSubmit {
                    submit()
                }
            Button(action: submit) {
                Image(systemName: "return")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tokens.secondaryForeground)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(tokens.hoverWash))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tokens.surface1.opacity(0.65))
    }

    private func submit() {
        let cmd = commandDraft
        commandDraft = ""
        onSubmitCommand(cmd)
    }
}
