import AppKit
import SartoProtocol
import PrismDesign
import SwiftUI

// MARK: - 1. Permission Mode Popover

struct PermissionModePopoverView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    let modes: [PrismModeOption]
    let selectedModeID: String?
    let onSelect: (String) -> Void

    @State private var hoveredID: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(l10n.tr("popover.permissionMode"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(tokens.secondaryForeground)
                Spacer()
                if modes.count > 1 {
                    Text(l10n.tr("composer.modeCyclesHint"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(tokens.placeholder)
                }
            }
            .padding(.horizontal, 4)

            VStack(spacing: 3) {
                ForEach(Array(modes.enumerated()), id: \.element.id) { idx, mode in
                    let active = mode.id == selectedModeID
                    let hovered = hoveredID == mode.id
                    let isFull = mode.look == .full
                    Button {
                        onSelect(mode.id)
                    } label: {
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: mode.look.systemImage)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(
                                    isFull
                                        ? tokens.danger
                                        : (active ? tokens.primary : tokens.secondaryForeground)
                                )
                                .frame(width: 18)
                                .padding(.top, 1.5)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.name)
                                    .font(.system(size: 12.5, weight: active ? .semibold : .medium))
                                    .foregroundStyle(isFull ? tokens.danger : tokens.foreground)
                                    .lineLimit(1)

                                let desc = mode.description.isEmpty && isFull
                                    ? l10n.tr("composer.modeFullAccessWarning")
                                    : mode.description
                                if !desc.isEmpty {
                                    Text(desc)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(isFull ? tokens.danger.opacity(0.8) : tokens.mutedForeground)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }

                            Spacer(minLength: 6)

                            if active {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10.5, weight: .bold))
                                    .foregroundStyle(isFull ? tokens.danger : tokens.primary)
                                    .padding(.top, 2)
                            } else if idx < 9 {
                                Text("\(idx + 1)")
                                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(tokens.placeholder)
                                    .frame(width: 16, height: 16)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(tokens.hoverWash.opacity(0.8))
                                    )
                                    .padding(.top, 1)
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                                .fill(
                                    active
                                        ? (isFull ? tokens.dangerSoft : tokens.activeWash)
                                        : (hovered ? (isFull ? tokens.dangerSoft.opacity(0.65) : tokens.hoverWash) : Color.clear)
                                )
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in
                        hoveredID = inside ? mode.id : (hoveredID == mode.id ? nil : hoveredID)
                    }
                }
            }
        }
        .padding(11)
        .frame(width: 348)
        .background(tokens.surface1)
    }
}

// MARK: - 2. Project Picker Popover for New Session Tray

struct ProjectPickerPopoverView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    let projects: [ProjectInfo]
    let selectedPath: String?
    let isScratch: Bool
    let onSelectProject: (String) -> Void
    let onSelectNoProject: () -> Void
    let onOpenFolderPicker: () -> Void

    @State private var query: String = ""
    @State private var hoveredKey: String? = nil

    var body: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hints = SidebarTreeBuilder.projectNameHints(for: projects)
        let filtered = projects.filter { proj in
            guard !trimmed.isEmpty else { return true }
            return proj.name.lowercased().contains(trimmed)
                || proj.path.lowercased().contains(trimmed)
        }

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.placeholder)
                TextField(l10n.tr("newSession.searchProjects"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(tokens.foreground)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(tokens.placeholder)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8.5)
            .padding(.vertical, 5.5)
            .background(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).fill(tokens.surface2.opacity(0.65)))
            .overlay(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).strokeBorder(tokens.borderEtched, lineWidth: 1))

            ScrollView {
                VStack(alignment: .leading, spacing: 2.5) {
                    // No project (scratch folder)
                    if trimmed.isEmpty || l10n.tr("sidebar.noProject").lowercased().contains(trimmed) || "scratch".contains(trimmed) {
                        Button(action: onSelectNoProject) {
                            HStack(spacing: 8.5) {
                                Image(systemName: "square.dashed")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(isScratch ? tokens.primary : tokens.mutedForeground)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(l10n.tr("sidebar.noProject"))
                                        .font(.system(size: 12, weight: isScratch ? .semibold : .medium))
                                        .foregroundStyle(tokens.foreground)
                                    Text(l10n.tr("newSession.noProjectDesc"))
                                        .font(.system(size: 10))
                                        .foregroundStyle(tokens.placeholder)
                                }
                                Spacer()
                                if isScratch {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10.5, weight: .bold))
                                        .foregroundStyle(tokens.primary)
                                }
                            }
                            .padding(.horizontal, 8.5)
                            .padding(.vertical, 6.5)
                            .background(
                                RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                                    .fill(isScratch ? tokens.activeWash : (hoveredKey == "__scratch__" ? tokens.hoverWash : Color.clear))
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { hoveredKey = $0 ? "__scratch__" : (hoveredKey == "__scratch__" ? nil : hoveredKey) }
                    }

                    if !filtered.isEmpty {
                        Rectangle().fill(tokens.borderEtched).frame(height: 1).padding(.vertical, 3)

                        ForEach(filtered) { project in
                            let active = !isScratch && selectedPath == project.path
                            let hovered = hoveredKey == project.path
                            Button {
                                onSelectProject(project.path)
                            } label: {
                                HStack(spacing: 8.5) {
                                    Image(systemName: project.isMissing ? "folder.badge.questionmark" : "folder.fill")
                                        .font(.system(size: 12))
                                        .foregroundStyle(project.isMissing ? tokens.danger : (active ? tokens.primary : tokens.secondaryForeground))
                                        .frame(width: 16)
                                    VStack(alignment: .leading, spacing: 1) {
                                        HStack(spacing: 5) {
                                            Text(project.name)
                                                .font(.system(size: 12, weight: active ? .semibold : .medium))
                                                .foregroundStyle(project.isMissing ? tokens.danger : tokens.foreground)
                                                .lineLimit(1)
                                            if let hint = hints[project.path] {
                                                Text(hint)
                                                    .font(.system(size: 10, design: .monospaced))
                                                    .foregroundStyle(tokens.placeholder)
                                                    .lineLimit(1)
                                            }
                                            if project.isMissing {
                                                Text(l10n.tr("sidebar.projectMissing"))
                                                    .font(.system(size: 9.5, weight: .semibold))
                                                    .foregroundStyle(tokens.danger)
                                            }
                                        }
                                        Text(abbreviateHome(project.path))
                                            .font(.system(size: 9.5, design: .monospaced))
                                            .foregroundStyle(tokens.placeholder)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Spacer(minLength: 4)
                                    if active {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10.5, weight: .bold))
                                            .foregroundStyle(tokens.primary)
                                    }
                                }
                                .padding(.horizontal, 8.5)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                                        .fill(active ? tokens.activeWash : (hovered ? tokens.hoverWash : Color.clear))
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { hoveredKey = $0 ? project.path : (hoveredKey == project.path ? nil : hoveredKey) }
                        }
                    } else if !trimmed.isEmpty {
                        Text(l10n.tr("newSession.noProjectsMatch"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(tokens.placeholder)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                }
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: 240)

            Rectangle().fill(tokens.borderEtched).frame(height: 1)

            Button(action: onOpenFolderPicker) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(tokens.prismCobalt)
                        .frame(width: 16)
                    Text(l10n.tr("newSession.openProjectFolder"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(tokens.foreground)
                    Spacer()
                }
                .padding(.horizontal, 8.5)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                        .fill(hoveredKey == "__open__" ? tokens.hoverWash : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveredKey = $0 ? "__open__" : (hoveredKey == "__open__" ? nil : hoveredKey) }
        }
        .padding(10)
        .frame(width: 316)
        .background(tokens.surface1)
    }

    private func abbreviateHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - 3. Worktree Picker Popover for New Session Tray

struct WorktreePickerPopoverView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    let projectPath: String
    let gitStatus: GitStatusInfo
    let branches: BranchListInfo?
    let isLoadingBranches: Bool
    let draft: SartoState.WorktreeDraftChoice
    let onUpdateMode: (SartoState.WorktreeLocationMode) -> Void
    let onUpdateBase: (String?) -> Void
    let onUpdateBranchName: (String) -> Void
    let onLoadBranches: () -> Void

    @State private var branchFilter: String = ""
    @State private var pickingBase: Bool = false

    private var currentBranchLabel: String {
        if let b = gitStatus.head.branch, !b.isEmpty { return b }
        if let oid = gitStatus.head.oid, !oid.isEmpty { return String(oid.prefix(7)) }
        return gitStatus.defaultBranch ?? "main"
    }

    private var effectiveBase: String {
        draft.baseBranch ?? currentBranchLabel
    }

    private var branchNameValid: Bool {
        SartoState.isValidGitBranchName(draft.customBranch)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Local vs New Worktree segmented control
            HStack(spacing: 3) {
                modeSegment(.local, title: l10n.tr("worktree.local"), icon: "folder")
                modeSegment(.worktree, title: l10n.tr("worktree.new"), icon: "arrow.triangle.branch")
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).fill(tokens.surface2.opacity(0.7)))
            .overlay(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).strokeBorder(tokens.borderEtched, lineWidth: 1))

            if draft.mode == .local {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 11))
                            .foregroundStyle(tokens.prismCobalt)
                        Text(l10n.tr("worktree.localWorks", currentBranchLabel))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(tokens.foreground)
                    }
                    Text(l10n.tr("worktree.localHint"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(tokens.mutedForeground)
                    if gitStatus.changes.totalChanged > 0 {
                        Text(l10n.tr("worktree.uncommittedCount", gitStatus.changes.totalChanged))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(tokens.warning)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 2)
            } else {
                // Base branch picker
                VStack(alignment: .leading, spacing: 6) {
                    Text(l10n.tr("worktree.baseBranch"))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(tokens.placeholder)

                    Button {
                        pickingBase.toggle()
                        if pickingBase && branches == nil {
                            onLoadBranches()
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 11))
                                .foregroundStyle(tokens.prismCobalt)
                            Text(effectiveBase)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(tokens.foreground)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: pickingBase ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(tokens.placeholder)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).fill(tokens.surface2.opacity(0.65)))
                        .overlay(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).strokeBorder(tokens.borderEtched, lineWidth: 1))
                    }
                    .buttonStyle(.plain)

                    if pickingBase {
                        baseBranchList()
                    }
                }

                // Custom new branch name
                VStack(alignment: .leading, spacing: 5) {
                    Text(l10n.tr("worktree.branchName"))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(tokens.placeholder)

                    TextField(
                        l10n.tr("worktree.branchPlaceholder", draft.branchTemplate),
                        text: Binding(
                            get: { draft.customBranch },
                            set: { onUpdateBranchName($0) }
                        )
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(tokens.foreground)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).fill(tokens.surface2.opacity(0.65)))
                    .overlay(
                        RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                            .strokeBorder(branchNameValid ? tokens.borderEtched : tokens.danger, lineWidth: 1)
                    )

                    if !branchNameValid {
                        Text(l10n.tr("worktree.branchInvalid"))
                            .font(.system(size: 10))
                            .foregroundStyle(tokens.danger)
                    } else {
                        Text(l10n.tr("worktree.newHint"))
                            .font(.system(size: 10))
                            .foregroundStyle(tokens.mutedForeground)
                    }
                }
            }
        }
        .padding(11)
        .frame(width: 332)
        .background(tokens.surface1)
        .onAppear {
            if draft.mode == .worktree && branches == nil {
                onLoadBranches()
            }
        }
    }

    private func modeSegment(_ mode: SartoState.WorktreeLocationMode, title: String, icon: String) -> some View {
        let active = draft.mode == mode
        return Button {
            onUpdateMode(mode)
            if mode == .worktree && branches == nil {
                onLoadBranches()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 11.5, weight: active ? .semibold : .medium))
            }
            .foregroundStyle(active ? tokens.foreground : tokens.mutedForeground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                    .fill(active ? tokens.surface1 : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func baseBranchList() -> some View {
        VStack(alignment: .leading, spacing: 5) {
            TextField(l10n.tr("branch.searchPlaceholder"), text: $branchFilter)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .padding(.horizontal, 8)
                .padding(.vertical, 4.5)
                .background(RoundedRectangle(cornerRadius: tokens.rXS).fill(tokens.hoverWash.opacity(0.6)))

            if isLoadingBranches && branches == nil {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6)
                    Text(l10n.tr("branch.loading"))
                        .font(.system(size: 11))
                        .foregroundStyle(tokens.mutedForeground)
                }
                .padding(.vertical, 6)
            } else {
                let q = branchFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let allNames = (branches?.branches ?? [])
                    .map(\.name)
                    .filter { q.isEmpty || $0.lowercased().contains(q) }

                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(allNames, id: \.self) { name in
                            let selected = effectiveBase == name
                            Button {
                                onUpdateBase(name == currentBranchLabel ? nil : name)
                                pickingBase = false
                            } label: {
                                HStack(spacing: 6) {
                                    Text(name)
                                        .font(.system(size: 11.5, weight: selected ? .semibold : .regular, design: .monospaced))
                                        .foregroundStyle(selected ? tokens.foreground : tokens.secondaryForeground)
                                        .lineLimit(1)
                                    Spacer()
                                    if selected {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(tokens.primary)
                                    }
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4.5)
                                .background(
                                    RoundedRectangle(cornerRadius: tokens.rXS)
                                        .fill(selected ? tokens.activeWash : Color.clear)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 132)
            }
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: tokens.rSM).fill(tokens.surface1.opacity(0.75)))
        .overlay(RoundedRectangle(cornerRadius: tokens.rSM).strokeBorder(tokens.borderEtched, lineWidth: 1))
    }
}

// MARK: - 4. Git Branch Switcher Popover for In-Session Bottom Tray

struct GitBranchPopoverView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    let currentBranch: String?
    let branches: BranchListInfo?
    let isLoading: Bool
    let errorText: String?
    let onSwitchBranch: (String, Bool) -> Void
    /// The workspace of the same repository, whose next step the popover leads with.
    var workspace: WorkspaceController? = nil
    var onOpenGitPane: (() -> Void)? = nil

    @State private var query: String = ""
    @State private var hoveredBranch: String? = nil

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let qLower = q.lowercased()
        let allBranches = branches?.branches ?? []
        let locals = allBranches.filter { qLower.isEmpty || $0.name.lowercased().contains(qLower) }
        let exactExists = allBranches.contains(where: { $0.name == q })
        let canCreate = !q.isEmpty && !exactExists && SartoState.isValidGitBranchName(q)

        VStack(alignment: .leading, spacing: 8) {
            if let workspace, workspace.gitNextStep != nil {
                GitNextStepCard(workspace: workspace, compact: true, onOpenGitPane: onOpenGitPane)
            }

            Text(l10n.tr("branch.switchTitle"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tokens.secondaryForeground)
                .padding(.horizontal, 3)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.placeholder)
                TextField(l10n.tr("branch.searchPlaceholder"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(tokens.foreground)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(tokens.placeholder)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8.5)
            .padding(.vertical, 5.5)
            .background(RoundedRectangle(cornerRadius: tokens.rSM).fill(tokens.surface2.opacity(0.65)))
            .overlay(RoundedRectangle(cornerRadius: tokens.rSM).strokeBorder(tokens.borderEtched, lineWidth: 1))

            if let errorText, !errorText.isEmpty {
                Text(errorText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(tokens.danger)
                    .padding(.horizontal, 4)
            }

            if isLoading && branches == nil {
                HStack(spacing: 7) {
                    ProgressView().scaleEffect(0.65)
                    Text(l10n.tr("branch.loading"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokens.mutedForeground)
                }
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if canCreate {
                            Button {
                                onSwitchBranch(q, true)
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(tokens.prismCobalt)
                                    Text(l10n.tr("branch.createAction", q))
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundStyle(tokens.foreground)
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: tokens.rSM)
                                        .fill(tokens.primarySoft.opacity(0.6))
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }

                        ForEach(locals) { branch in
                            let isCurrent = branch.current || branch.name == currentBranch
                            let hovered = hoveredBranch == branch.name
                            Button {
                                if !isCurrent {
                                    onSwitchBranch(branch.name, false)
                                }
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: "arrow.triangle.branch")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(isCurrent ? tokens.primary : tokens.mutedForeground)
                                    Text(branch.name)
                                        .font(.system(size: 11.5, weight: isCurrent ? .semibold : .regular, design: .monospaced))
                                        .foregroundStyle(isCurrent ? tokens.foreground : tokens.secondaryForeground)
                                        .lineLimit(1)
                                    Spacer()
                                    if isCurrent {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(tokens.primary)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: tokens.rSM)
                                        .fill(isCurrent ? tokens.activeWash : (hovered ? tokens.hoverWash : Color.clear))
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { hoveredBranch = $0 ? branch.name : (hoveredBranch == branch.name ? nil : hoveredBranch) }
                        }
                    }
                }
                .scrollIndicators(.automatic)
                .frame(maxHeight: 220)
            }
        }
        .padding(10)
        .frame(width: 288)
        .background(tokens.surface1)
    }
}

// MARK: - 5. Running-Turn Send / Queue / Steer Control

struct ComposerSendControlView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    let isRunning: Bool
    let isBusy: Bool
    let canSend: Bool
    let supportsSteering: Bool
    let onSendOrQueue: () -> Void
    let onSteerNow: () -> Void
    let onStop: () -> Void

    @State private var showSteerMenu: Bool = false

    var body: some View {
        if isRunning && !canSend {
            PrismSendStopButton(
                isRunning: true,
                canSend: false,
                onSend: onSendOrQueue,
                onStop: onStop
            )
            .help("Esc")
        } else if isBusy && canSend {
            HStack(spacing: 4) {
                Button(action: onSendOrQueue) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(tokens.palette.isDark ? Color(hex: 0x0E0F14) : Color(hex: 0xF8F9FC))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(tokens.primary))
                }
                .buttonStyle(.plain)
                .help("\(l10n.tr("composer.queueIt")) (↵)")

                if supportsSteering {
                    Button {
                        showSteerMenu.toggle()
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(tokens.secondaryForeground)
                            .frame(width: 20, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(showSteerMenu ? tokens.activeWash : tokens.surface2.opacity(0.65))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(tokens.borderEtched, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showSteerMenu, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 4) {
                            steerMenuRow(
                                icon: "clock",
                                title: l10n.tr("composer.queueIt"),
                                subtitle: l10n.tr("composer.queueItHint"),
                                shortcut: "↵",
                                tint: tokens.secondaryForeground
                            ) {
                                showSteerMenu = false
                                onSendOrQueue()
                            }

                            steerMenuRow(
                                icon: "arrow.up.circle.fill",
                                title: l10n.tr("composer.steerNow"),
                                subtitle: l10n.tr("composer.steerNowHint"),
                                shortcut: "⌘↵",
                                tint: tokens.prismCobalt
                            ) {
                                showSteerMenu = false
                                onSteerNow()
                            }
                        }
                        .padding(7)
                        .frame(width: 268)
                        .background(tokens.surface1)
                        .focusEffectDisabled()
                        .presentationBackground(tokens.surface1)
                        .environment(\.prismTokens, tokens)
                        .environment(\.prismL10n, l10n)
                    }
                }
            }
        } else {
            PrismSendStopButton(
                isRunning: false,
                canSend: canSend,
                onSend: onSendOrQueue,
                onStop: onStop
            )
        }
    }

    private func steerMenuRow(
        icon: String,
        title: String,
        subtitle: String,
        shortcut: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8.5) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 16)
                    .padding(.top, 1.5)
                VStack(alignment: .leading, spacing: 1.5) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tokens.foreground)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(tokens.mutedForeground)
                }
                Spacer(minLength: 6)
                Text(shortcut)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(tokens.placeholder)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
