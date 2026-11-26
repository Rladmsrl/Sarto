import AppKit
import SartoProtocol
import PrismDesign
import SwiftUI

// MARK: - Hover Preview Payload

struct SidebarHoverPreview: Equatable {
    let hostId: String
    let hostName: String?
    let node: SidebarSessionNode
    let rowMidY: CGFloat
}

/// Per-host session index caches stored outside SwiftUI value state so body passes stay O(1)
/// when a host's session list has not changed.
@MainActor
private final class MultiHostSidebarIndexCache {
    private var byHost: [String: SidebarSessionIndexCache] = [:]

    func index(for hostId: String, sessions: [SessionSummary]) -> SidebarSessionIndex {
        let cache: SidebarSessionIndexCache
        if let existing = byHost[hostId] {
            cache = existing
        } else {
            cache = SidebarSessionIndexCache()
            byHost[hostId] = cache
        }
        return cache.index(for: sessions)
    }
}

/// One computer's part of the multi-host sidebar. It reads only its own host's snapshot, so it
/// redraws as that host changes. Its content comes from the sidebar as a closure, never as a copy
/// of the sidebar view: SwiftUI would give a copied view's `@State` storage of its own here, and
/// the sidebar's alerts and folds would stop seeing what the rows set.
private struct MacSidebarHostLeaf<Content: View>: View {
    let state: SartoState
    let hostId: String
    @ViewBuilder let content: (UnifiedHostSnapshot) -> Content

    var body: some View {
        if let host = state.sidebarHostSnapshot(hostId) {
            content(host)
        }
    }
}

// MARK: - Main macOS Sidebar

/// Obsidian Prism left sidebar for macOS:
/// - Collapsible Zen Rail (`56pt`) or resizable full sidebar (`200...360pt`)
/// - Pinned group (pinned project folders + pinned sessions)
/// - Project folders with `+ Add Project`, hover `+ New Session` / `•••` / right-click menu,
///   disambiguated duplicate names, `No project` scratch group, and 5-row cap + "Show N more"
///   (while keeping running, waiting, and active sessions in sight)
/// - Parent/child session trees with `TreeLine` connectors; agent subagents folded into compact
///   row badges with interactive popover lists
/// - Compact single-line rows with Agent brand mark (desaturated when prompt cache expired),
///   priority status slot, inline double-click rename, full right-click actions, and floating hover card
struct MacSidebarView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    @Environment(\.prismMotionTier) private var motionTier

    @Bindable var state: SartoState
    @Binding var isCollapsed: Bool
    let onOpenNewSession: (String?, String?, Bool, String?) -> Void
    let onOpenSettings: () -> Void
    let onOpenAccountSettings: () -> Void
    let onOpenRemoteSettings: () -> Void
    let onOpenProjectTerminal: (String, String) -> Void
    let onClosePopovers: () -> Void
    let onHoverPreviewChanged: (SidebarHoverPreview?) -> Void

    @State private var collapsedHosts: Set<String> = []
    @State private var collapsedGroups: Set<String> = []
    @State private var expandedAllGroups: Set<String> = []
    @State private var expandedArchivedHosts: Set<String> = []
    @State private var expandedParents: [String: Bool] = [:]
    @State private var showFinishedSubagents = false
    @State private var inlineRenamingKey: String? = nil
    @State private var inlineRenameDraft: String = ""
    @State private var pendingDeleteTarget: (hostId: String, session: SessionSummary)? = nil
    @State private var pendingRemoveTarget: (hostId: String, project: ProjectInfo)? = nil
    @State private var addProjectHovered = false
    @State private var indexCachePool = MultiHostSidebarIndexCache()

    private static let pinnedGroupKey = "__pinned__"
    private static let noProjectGroupKey = "__no_project__"

    private var shownSessionID: String? {
        state.showStudioHome ? nil : state.selectedSessionSummary?.id
    }

    private func scopedKey(hostId: String, _ raw: String) -> String {
        state.hasMultipleHosts ? "\(hostId)::\(raw)" : raw
    }

    var body: some View {
        let nowMs = Date().timeIntervalSince1970 * 1000.0
        let multiHost = state.hasMultipleHosts

        VStack(spacing: 0) {
            sidebarHeader()

            VStack(spacing: 2) {
                sidebarNavButton(
                    title: l10n.tr("sidebar.newChat"),
                    icon: "square.and.pencil",
                    shortcut: "⌘N",
                    isActive: state.showStudioHome
                ) {
                    onHoverPreviewChanged(nil)
                    withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier)) {
                        onClosePopovers()
                        onOpenNewSession(state.activeHostID, nil, false, nil)
                    }
                }

                sidebarNavButton(
                    title: l10n.tr("sidebar.searchSessions"),
                    icon: "magnifyingglass",
                    shortcut: "⌘K",
                    isActive: state.showGlobalSearchSheet
                ) {
                    onHoverPreviewChanged(nil)
                    onClosePopovers()
                    state.showGlobalSearchSheet = true
                }

                sidebarNavButton(
                    title: l10n.tr("sidebar.importCli"),
                    icon: "square.and.arrow.down",
                    shortcut: nil,
                    isActive: state.showImportSessionsSheet
                ) {
                    onHoverPreviewChanged(nil)
                    onClosePopovers()
                    state.showImportSessionsSheet = true
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 10)

            Rectangle().fill(tokens.borderEtched).frame(height: 1).padding(.horizontal, 12)

            ScrollView {
                if isCollapsed {
                    collapsedZenRailList(multiHost: multiHost, nowMs: nowMs)
                } else if multiHost {
                    // Each computer's part is a view of its own that reads only its host, so one
                    // host's sessions changing redraws its part alone.
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(state.unifiedHostIDs.enumerated()), id: \.element) { idx, hostId in
                            MacSidebarHostLeaf(state: state, hostId: hostId) { host in
                                hostSectionView(
                                    host: host,
                                    isFirst: idx == 0,
                                    nowMs: Date().timeIntervalSince1970 * 1000.0
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.top, 8)
                    .padding(.bottom, 14)
                } else {
                    singleHostTreeContent(host: state.activeHostSnapshot, nowMs: nowMs)
                        .padding(.horizontal, 7)
                        .padding(.top, 8)
                        .padding(.bottom, 14)
                }
            }
            .scrollIndicators(.hidden)

            Spacer(minLength: 0)

            Rectangle().fill(tokens.borderEtched).frame(height: 1)

            sidebarFooter()
        }
        .alert(
            l10n.tr(
                "sidebar.deleteConfirmTitle",
                pendingDeleteTarget?.session.title ?? l10n.tr("sidebar.untitledSession")
            ),
            isPresented: Binding(
                get: { pendingDeleteTarget != nil },
                set: { if !$0 { pendingDeleteTarget = nil } }
            )
        ) {
            Button(l10n.tr("sidebar.cancel"), role: .cancel) {
                pendingDeleteTarget = nil
            }
            Button(l10n.tr("sidebar.confirmDelete"), role: .destructive) {
                if let target = pendingDeleteTarget {
                    pendingDeleteTarget = nil
                    Task { await state.deleteSession(id: target.session.id, onHost: target.hostId) }
                }
            }
        } message: {
            Text(l10n.tr("sidebar.deleteConfirmMessage"))
        }
        .alert(
            l10n.tr("sidebar.projectRemoveTitle", pendingRemoveTarget?.project.name ?? ""),
            isPresented: Binding(
                get: { pendingRemoveTarget != nil },
                set: { if !$0 { pendingRemoveTarget = nil } }
            )
        ) {
            Button(l10n.tr("sidebar.cancel"), role: .cancel) {
                pendingRemoveTarget = nil
            }
            Button(l10n.tr("sidebar.confirmRemove"), role: .destructive) {
                if let target = pendingRemoveTarget {
                    pendingRemoveTarget = nil
                    Task { await state.removeProject(path: target.project.path, onHost: target.hostId) }
                }
            }
        } message: {
            Text(l10n.tr("sidebar.projectRemoveMessage"))
        }
    }

    // MARK: - Single-Host & Unified Multi-Host Tree Builders

    @ViewBuilder
    private func singleHostTreeContent(host: UnifiedHostSnapshot, nowMs: Double) -> some View {
        let index = indexCachePool.index(for: host.id, sessions: host.sessions)
        let allProjects = host.projects + index.orphanProjects(knownProjects: host.projects)
        let nameHints = SidebarTreeBuilder.projectNameHints(for: allProjects)
        let hasNoProject = index.hasNoProject
        let noProjectPinned = host.noProjectInfo.pinnedAt != nil
        let pinnedProjects = allProjects.filter(\.isPinned)
        let regularProjects = allProjects.filter { !$0.isPinned }
        let pinnedSessions = index.pinned
        let hasPinnedContent = !pinnedProjects.isEmpty || (noProjectPinned && hasNoProject) || !pinnedSessions.isEmpty
        let archivedList = index.archived

        LazyVStack(alignment: .leading, spacing: 2) {
            if hasPinnedContent {
                pinnedSectionView(
                    host: host,
                    index: index,
                    pinnedProjects: pinnedProjects,
                    noProjectPinned: noProjectPinned && hasNoProject,
                    nameHints: nameHints,
                    nowMs: nowMs
                )
            }

            projectsSectionHeader()

            if regularProjects.isEmpty && (!hasNoProject || noProjectPinned) && !hasPinnedContent {
                Text(l10n.tr("sidebar.emptyProjects"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(tokens.placeholder)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }

            if hasNoProject && !noProjectPinned {
                projectFolderSection(
                    host: host,
                    project: nil,
                    hint: nil,
                    nodes: index.scratch,
                    nowMs: nowMs
                )
            }

            ForEach(regularProjects) { project in
                projectFolderSection(
                    host: host,
                    project: project,
                    hint: nameHints[project.path],
                    nodes: index.nodes(forProject: project.path),
                    nowMs: nowMs
                )
            }

            if !archivedList.isEmpty {
                archivedSectionView(host: host, archived: archivedList, nowMs: nowMs)
            }
        }
    }

    @ViewBuilder
    private func hostSectionView(host: UnifiedHostSnapshot, isFirst: Bool, nowMs: Double) -> some View {
        let isOpen = !collapsedHosts.contains(host.id)
        let isActiveHost = state.activeHostID == host.id
        let index = indexCachePool.index(for: host.id, sessions: host.sessions)
        let allProjects = host.projects + index.orphanProjects(knownProjects: host.projects)
        let nameHints = SidebarTreeBuilder.projectNameHints(for: allProjects)
        let hasNoProject = index.hasNoProject
        let noProjectPinned = host.noProjectInfo.pinnedAt != nil
        let pinnedProjects = allProjects.filter(\.isPinned)
        let regularProjects = allProjects.filter { !$0.isPinned }
        let pinnedSessions = index.pinned
        let hasPinnedContent = !pinnedProjects.isEmpty || (noProjectPinned && hasNoProject) || !pinnedSessions.isEmpty
        let archivedList = index.archived

        if !isFirst {
            Rectangle()
                .fill(tokens.borderEtched)
                .frame(height: 1)
                .padding(.horizontal, 8)
                .padding(.top, 7)
                .padding(.bottom, 5)
        }

        MacSidebarHostHeaderRow(
            host: host,
            isOpen: isOpen,
            isActiveHost: isActiveHost,
            onToggle: { toggleHost(host.id) },
            onNewSession: host.isOnline ? {
                onHoverPreviewChanged(nil)
                onClosePopovers()
                onOpenNewSession(host.id, nil, false, nil)
            } : nil,
            onAddProject: host.isLocal ? {
                presentAddProjectPanel(forHost: host.id)
            } : nil,
            onManageDevices: {
                onHoverPreviewChanged(nil)
                onClosePopovers()
                onOpenRemoteSettings()
            }
        )

        if isOpen {
            if !host.isOnline && host.sessions.isEmpty && host.projects.isEmpty {
                HStack(spacing: 6) {
                    if host.isConnecting {
                        PrismTurnDotsView(phase: .thinking, size: 10)
                        Text(l10n.tr("sidebar.host.connecting"))
                            .font(.system(size: 11))
                            .foregroundStyle(tokens.placeholder)
                    } else {
                        Text(host.error ?? l10n.tr("sidebar.host.offlineEmpty"))
                            .font(.system(size: 11))
                            .foregroundStyle(tokens.placeholder)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .padding(.horizontal, 14)
                .frame(height: 26)
            } else if host.isOnline && !host.isLoaded && host.sessions.isEmpty && host.projects.isEmpty {
                HStack(spacing: 6) {
                    PrismTurnDotsView(phase: .thinking, size: 10)
                    Text(l10n.tr("sidebar.host.loading"))
                        .font(.system(size: 11))
                        .foregroundStyle(tokens.placeholder)
                    Spacer(minLength: 4)
                }
                .padding(.horizontal, 14)
                .frame(height: 26)
            } else {
                if hasPinnedContent {
                    pinnedSectionView(
                        host: host,
                        index: index,
                        pinnedProjects: pinnedProjects,
                        noProjectPinned: noProjectPinned && hasNoProject,
                        nameHints: nameHints,
                        nowMs: nowMs
                    )
                }

                if regularProjects.isEmpty && (!hasNoProject || noProjectPinned) && !hasPinnedContent {
                    Text(l10n.tr("sidebar.emptyProjects"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokens.placeholder)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                }

                if hasNoProject && !noProjectPinned {
                    projectFolderSection(
                        host: host,
                        project: nil,
                        hint: nil,
                        nodes: index.scratch,
                        nowMs: nowMs
                    )
                }

                ForEach(regularProjects, id: \.path) { project in
                    projectFolderSection(
                        host: host,
                        project: project,
                        hint: nameHints[project.path],
                        nodes: index.nodes(forProject: project.path),
                        nowMs: nowMs
                    )
                    .id("\(host.id)::proj::\(project.path)")
                }

                if !archivedList.isEmpty {
                    archivedSectionView(host: host, archived: archivedList, nowMs: nowMs)
                }
            }
        }
    }

    // MARK: - Header & Top Nav

    private func sidebarHeader() -> some View {
        HStack(spacing: 8) {
            if !isCollapsed {
                HStack(spacing: 7) {
                    SartoSpectrumEmblem(size: 19)
                    Text(SartoBrand.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(tokens.foreground)
                        .lineLimit(1)
                }
                Spacer()
            } else {
                Spacer()
            }

            Button {
                onHoverPreviewChanged(nil)
                withAnimation(PrismSpringSpec.default.animation(tier: motionTier)) {
                    isCollapsed.toggle()
                }
            } label: {
                Image(systemName: isCollapsed ? "sidebar.right" : "sidebar.left")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(tokens.mutedForeground)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                            .fill(tokens.hoverWash.opacity(0.6))
                    )
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? l10n.tr("sidebar.expandTooltip") : l10n.tr("sidebar.collapseTooltip"))

            if isCollapsed {
                Spacer()
            }
        }
        .padding(.horizontal, isCollapsed ? 0 : 12)
        .padding(.top, 38)
        .padding(.bottom, 10)
    }

    private func sidebarNavButton(
        title: String,
        icon: String,
        shortcut: String?,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(isActive ? tokens.primary : tokens.mutedForeground)
                    .frame(width: 18)
                if !isCollapsed {
                    Text(title)
                        .font(.system(size: 12.5, weight: isActive ? .semibold : .medium))
                        .foregroundStyle(isActive ? tokens.foreground : tokens.secondaryForeground)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let shortcut {
                        Text(shortcut)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(tokens.placeholder)
                    }
                }
            }
            .padding(.horizontal, isCollapsed ? 0 : 9)
            .frame(maxWidth: .infinity, alignment: isCollapsed ? .center : .leading)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                    .fill(isActive ? tokens.activeWash : Color.clear)
            )
            .overlay(alignment: .leading) {
                if isActive && !isCollapsed {
                    Capsule()
                        .fill(tokens.primary)
                        .frame(width: 2.5, height: 15)
                        .shadow(color: tokens.primary.opacity(0.6), radius: 4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
    }

    // MARK: - Pinned & Projects Sections

    @ViewBuilder
    private func pinnedSectionView(
        host: UnifiedHostSnapshot,
        index: SidebarSessionIndex,
        pinnedProjects: [ProjectInfo],
        noProjectPinned: Bool,
        nameHints: [String: String],
        nowMs: Double
    ) -> some View {
        let pinKey = scopedKey(hostId: host.id, Self.pinnedGroupKey)
        let isOpen = !collapsedGroups.contains(pinKey)

        Button {
            toggleGroup(pinKey)
        } label: {
            HStack(spacing: 5) {
                Text(l10n.tr("sidebar.pinnedSection"))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(tokens.placeholder)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(tokens.placeholder.opacity(0.8))
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                Spacer()
            }
            .padding(.horizontal, 9)
            .padding(.top, 4)
            .padding(.bottom, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if isOpen {
            if noProjectPinned {
                projectFolderSection(host: host, project: nil, hint: nil, nodes: index.scratch, nowMs: nowMs)
            }
            ForEach(pinnedProjects, id: \.path) { project in
                projectFolderSection(
                    host: host,
                    project: project,
                    hint: nameHints[project.path],
                    nodes: index.nodes(forProject: project.path),
                    nowMs: nowMs
                )
                .id("\(host.id)::pinproj::\(project.path)")
            }
            ForEach(index.pinned) { node in
                sessionTreeNodeView(host: host, node: node, indent: false, nowMs: nowMs)
                    .id("\(host.id)::pinsess::\(node.id)")
            }
            Spacer().frame(height: 6)
        }
    }

    private func projectsSectionHeader() -> some View {
        HStack(spacing: 6) {
            Text(l10n.tr("sidebar.projectsSection"))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(tokens.placeholder)
            Spacer()
            Button {
                presentAddProjectPanel(forHost: state.activeHostID)
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(addProjectHovered ? tokens.foreground : tokens.mutedForeground)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(addProjectHovered ? tokens.hoverWash : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { addProjectHovered = $0 }
            .help(l10n.tr("sidebar.addProject"))
        }
        .padding(.horizontal, 9)
        .padding(.top, 4)
        .padding(.bottom, 3)
    }

    @ViewBuilder
    private func projectFolderSection(
        host: UnifiedHostSnapshot,
        project: ProjectInfo?,
        hint: String?,
        nodes: [SidebarSessionNode],
        nowMs: Double
    ) -> some View {
        let rawGroupKey = project?.path ?? Self.noProjectGroupKey
        let groupKey = scopedKey(hostId: host.id, rawGroupKey)
        let isOpen = !collapsedGroups.contains(groupKey)
        let showAll = expandedAllGroups.contains(groupKey)
        let activeShownInHost: String? = (host.id == state.activeHostID) ? shownSessionID : nil
        let limited = SidebarTreeBuilder.limitRows(nodes, showAll: showAll, shownSessionID: activeShownInHost)
        let isPinned = project?.isPinned ?? (host.noProjectInfo.pinnedAt != nil)

        MacSidebarProjectHeaderRow(
            project: project,
            hint: hint,
            isOpen: isOpen,
            isPinned: isPinned,
            sessionCount: nodes.count,
            onToggle: { toggleGroup(groupKey) },
            onNewSession: {
                onHoverPreviewChanged(nil)
                onClosePopovers()
                withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier)) {
                    onOpenNewSession(host.id, project?.path, project == nil, nil)
                }
            },
            onTogglePin: {
                Task { await state.pinProject(path: project?.path, pinned: !isPinned, onHost: host.id) }
            },
            onRevealInFinder: host.isLocal ? project.map { proj in
                {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: proj.path)
                }
            } : nil,
            onOpenTerminal: host.allowsTerminal ? project.map { proj in
                {
                    onOpenProjectTerminal(host.id, proj.path)
                }
            } : nil,
            onRemove: project.map { proj in
                {
                    pendingRemoveTarget = (host.id, proj)
                }
            }
        )

        if isOpen && !nodes.isEmpty {
            ForEach(limited.visible) { node in
                sessionTreeNodeView(host: host, node: node, indent: true, nowMs: nowMs)
                    .id("\(host.id)::sess::\(node.id)")
            }

            if limited.hiddenCount > 0 || (showAll && nodes.count > SidebarTreeBuilder.rowsShownPerProject) {
                Button {
                    withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier)) {
                        if showAll {
                            expandedAllGroups.remove(groupKey)
                        } else {
                            expandedAllGroups.insert(groupKey)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(
                            showAll
                                ? l10n.tr("sidebar.showLessRows")
                                : l10n.tr("sidebar.showMoreRows", limited.hiddenCount)
                        )
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(tokens.placeholder)
                        Spacer()
                    }
                    .padding(.leading, 30)
                    .padding(.trailing, 8)
                    .frame(height: 25)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Session Tree Node (Parent + Collapsible User Sub-Sessions)

    private func sessionTreeNodeView(
        host: UnifiedHostSnapshot,
        node: SidebarSessionNode,
        indent: Bool,
        nowMs: Double
    ) -> AnyView {
        let hasChildren = !node.children.isEmpty
        let childActive = node.children.contains { $0.totalRunning || $0.totalWaiting > 0 }
        let parentKey = scopedKey(hostId: host.id, node.id)
        let isExpanded = hasChildren && (expandedParents[parentKey] ?? childActive)

        return AnyView(
            VStack(alignment: .leading, spacing: 1) {
                singleSessionRow(
                    host: host,
                    node: node,
                    indent: indent,
                    branch: nil,
                    hasChildren: hasChildren,
                    isExpanded: isExpanded,
                    onToggleExpand: hasChildren ? {
                        withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier)) {
                            expandedParents[parentKey] = !isExpanded
                        }
                    } : nil,
                    nowMs: nowMs
                )

                if isExpanded {
                    ForEach(Array(node.children.enumerated()), id: \.element.id) { idx, child in
                        let branch: SidebarTreeBranch = (idx == node.children.count - 1) ? .last : .middle
                        singleSessionRow(
                            host: host,
                            node: child,
                            indent: indent,
                            branch: branch,
                            hasChildren: false,
                            isExpanded: false,
                            onToggleExpand: nil,
                            nowMs: nowMs
                        )
                    }
                }
            }
        )
    }

    private func singleSessionRow(
        host: UnifiedHostSnapshot,
        node: SidebarSessionNode,
        indent: Bool,
        branch: SidebarTreeBranch?,
        hasChildren: Bool,
        isExpanded: Bool,
        onToggleExpand: (() -> Void)?,
        nowMs: Double
    ) -> some View {
        let summary = node.summary
        let isHostActive = host.id == state.activeHostID
        let isSelected = isHostActive && shownSessionID != nil
            && (shownSessionID == summary.id || node.subagents.contains(where: { $0.id == shownSessionID }))
        let status = node.rowStatus(rolledUp: hasChildren && !isExpanded, nowMs: nowMs)
        let canFork = summary.parentId == nil
            && summary.origin != "subagent"
            && host.agents.first(where: { $0.id == summary.agentId })?.capabilities?.forkSession == true
        let renameKey = "\(host.id)::\(summary.id)"
        let isRenaming = inlineRenamingKey == renameKey
        let previewHostName: String? = (state.hasMultipleHosts && !host.isLocal) ? host.name : nil

        return MacSidebarCompactSessionRow(
            hostId: host.id,
            hostName: previewHostName,
            node: node,
            status: status,
            isSelected: isSelected,
            indent: indent,
            branch: branch,
            hasChildren: hasChildren,
            isExpanded: isExpanded,
            canFork: canFork,
            isRenaming: isRenaming,
            renameText: $inlineRenameDraft,
            showFinishedSubagents: $showFinishedSubagents,
            onToggleExpand: onToggleExpand,
            onSelect: {
                onHoverPreviewChanged(nil)
                onClosePopovers()
                Task { await state.selectSession(summary.id, onHost: host.id) }
            },
            onOpenSubagent: { sid in
                onHoverPreviewChanged(nil)
                onClosePopovers()
                Task { await state.selectSession(sid, onHost: host.id) }
            },
            onStartInlineRename: {
                onHoverPreviewChanged(nil)
                inlineRenameDraft = summary.title ?? ""
                inlineRenamingKey = renameKey
            },
            onCommitInlineRename: {
                let targetId = summary.id
                let targetHost = host.id
                let next = inlineRenameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                inlineRenamingKey = nil
                Task { await state.renameSession(id: targetId, title: next.isEmpty ? nil : next, onHost: targetHost) }
            },
            onCancelInlineRename: {
                inlineRenamingKey = nil
            },
            onStop: {
                Task { await state.cancelTurn(sessionId: summary.id, onHost: host.id) }
            },
            onRetry: {
                Task { await state.retryTurn(sessionId: summary.id, onHost: host.id) }
            },
            onTogglePin: {
                Task { await state.pinSession(id: summary.id, pinned: summary.pinnedAt == nil, onHost: host.id) }
            },
            onToggleUnread: {
                Task { await state.markSessionUnread(id: summary.id, unread: summary.attention != "unread", onHost: host.id) }
            },
            onFork: {
                Task { await state.forkSession(id: summary.id, onHost: host.id) }
            },
            onNewSubSession: {
                onHoverPreviewChanged(nil)
                onClosePopovers()
                withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier)) {
                    onOpenNewSession(
                        host.id,
                        summary.scratch == true ? nil : summary.projectPath,
                        summary.scratch == true,
                        summary.parentId ?? summary.id
                    )
                }
            },
            onRevealInFinder: (host.isLocal && !summary.projectPath.isEmpty) ? {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: summary.projectPath)
            } : nil,
            onCopyResume: SidebarTreeBuilder.resumeCommand(for: summary).map { cmd in
                {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(cmd, forType: .string)
                }
            },
            onExportMarkdown: {
                Task { await state.exportSessionMarkdown(sessionId: summary.id, onHost: host.id) }
            },
            onToggleArchive: {
                Task {
                    if summary.archivedAt != nil {
                        await state.unarchiveSession(id: summary.id, onHost: host.id)
                    } else {
                        await state.archiveSession(id: summary.id, onHost: host.id)
                    }
                }
            },
            onRequestDelete: {
                pendingDeleteTarget = (host.id, summary)
            },
            onHoverPreview: onHoverPreviewChanged
        )
    }

    // MARK: - Archived Section

    @ViewBuilder
    private func archivedSectionView(host: UnifiedHostSnapshot, archived: [SessionSummary], nowMs: Double) -> some View {
        let isArchivedOpen = state.hasMultipleHosts
            ? expandedArchivedHosts.contains(host.id)
            : state.showArchivedSessions

        Spacer().frame(height: 6)
        Button {
            // The rows come in without an animation: in the lazy stack, everything below them
            // would slide over them as they fade in, and every row of the list would be animated.
            withTransaction(Transaction(animation: nil)) {
                if state.hasMultipleHosts {
                    if expandedArchivedHosts.contains(host.id) {
                        expandedArchivedHosts.remove(host.id)
                    } else {
                        expandedArchivedHosts.insert(host.id)
                    }
                } else {
                    state.showArchivedSessions.toggle()
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "archivebox")
                    .font(.system(size: 10.5))
                Text(
                    isArchivedOpen
                        ? l10n.tr("sidebar.hideArchived")
                        : l10n.tr("sidebar.showArchived", archived.count)
                )
                .font(.system(size: 11, weight: .medium))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .semibold))
                    .rotationEffect(.degrees(isArchivedOpen ? 90 : 0))
                    .animation(PrismSpringSpec.snappy.animation(tier: motionTier), value: isArchivedOpen)
            }
            .foregroundStyle(tokens.placeholder)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if isArchivedOpen {
            ForEach(archived) { summary in
                let node = SidebarSessionNode(
                    summary: summary,
                    children: [],
                    subagents: [],
                    ownWaiting: summary.permissionCount,
                    ownRunning: summary.status == .running,
                    totalWaiting: summary.permissionCount,
                    totalRunning: summary.status == .running
                )
                singleSessionRow(
                    host: host,
                    node: node,
                    indent: false,
                    branch: nil,
                    hasChildren: false,
                    isExpanded: false,
                    onToggleExpand: nil,
                    nowMs: nowMs
                )
                .id("\(host.id)::arch::\(summary.id)")
                .opacity(0.68)
            }
        }
    }

    // MARK: - Collapsed Zen Rail

    private func collapsedZenRailList(multiHost: Bool, nowMs: Double) -> some View {
        LazyVStack(spacing: 4) {
            if multiHost {
                // A computer's part reads its host alone, as the expanded tree's do.
                ForEach(Array(state.unifiedHostIDs.enumerated()), id: \.element) { idx, hostId in
                    MacSidebarHostLeaf(state: state, hostId: hostId) { host in
                        collapsedHostRail(
                            host: host,
                            isFirst: idx == 0,
                            multiHost: true,
                            nowMs: Date().timeIntervalSince1970 * 1000.0
                        )
                    }
                }
            } else {
                collapsedHostRail(host: state.activeHostSnapshot, isFirst: true, multiHost: false, nowMs: nowMs)
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func collapsedHostRail(
        host: UnifiedHostSnapshot,
        isFirst: Bool,
        multiHost: Bool,
        nowMs: Double
    ) -> some View {
        let index = indexCachePool.index(for: host.id, sessions: host.sessions)
        let allProjects = host.projects + index.orphanProjects(knownProjects: host.projects)
        let maxPerHost = multiHost ? 8 : 16
        let flatRecent: [SidebarSessionNode] = {
            var list = index.pinned
            var seen = Set(list.map(\.id))
            let projectNodes = allProjects.flatMap { index.nodes(forProject: $0.path) }
            let scratchNodes = index.hasNoProject ? index.scratch : []
            let rest = (projectNodes + scratchNodes)
                .filter { seen.insert($0.id).inserted }
                .sorted { $0.summary.updatedAt > $1.summary.updatedAt }
            list.append(contentsOf: rest.prefix(maxPerHost))
            return list
        }()

        if multiHost {
            if !isFirst {
                Rectangle()
                    .fill(tokens.borderEtched)
                    .frame(width: 20, height: 1)
                    .padding(.vertical, 4)
            }
            Button {
                onClosePopovers()
                guard host.isOnline || host.isLocal else {
                    onOpenRemoteSettings()
                    return
                }
                Task { _ = await state.switchActiveHost(to: host.id) }
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: host.deviceSymbolName)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(
                            state.activeHostID == host.id
                                ? tokens.foreground
                                : (host.isOnline ? tokens.mutedForeground : tokens.placeholder)
                        )
                        .frame(width: 30, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                                .fill(state.activeHostID == host.id ? tokens.activeWash : Color.clear)
                        )
                    Circle()
                        .fill(
                            host.isOnline
                                ? (host.isLocal ? tokens.success : tokens.prismCobalt)
                                : (host.isConnecting ? tokens.warning : tokens.placeholder.opacity(0.6))
                        )
                        .frame(width: 5, height: 5)
                        .offset(x: -3, y: -2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(host.name)
        }

        ForEach(flatRecent) { node in
            let isSelected = state.activeHostID == host.id && shownSessionID == node.id
            let status = node.rowStatus(rolledUp: true, nowMs: nowMs)
            let stillRunning = (!status.running && !status.starting)
                ? SidebarStillRunning.effective(for: node, rolledUp: true)
                : nil
            Button {
                onClosePopovers()
                Task { await state.selectSession(node.id, onHost: host.id) }
            } label: {
                ZStack(alignment: .topTrailing) {
                    SidebarAgentMarkView(
                        agentId: node.summary.agentId,
                        dimmed: status.cacheExpired,
                        size: 18
                    )
                    .frame(width: 34, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                            .fill(isSelected ? tokens.activeWash : Color.clear)
                    )
                    if status.waiting > 0 {
                        Circle()
                            .fill(tokens.warning)
                            .frame(width: 6.5, height: 6.5)
                            .offset(x: -3, y: 3)
                    } else if status.running || status.starting {
                        PrismTurnDotsView(phase: status.running ? .working : .thinking, size: 10)
                            .offset(x: -2, y: 2)
                    } else if status.failed {
                        Circle()
                            .fill(tokens.danger)
                            .frame(width: 5.5, height: 5.5)
                            .offset(x: -3, y: 3)
                    } else if stillRunning != nil {
                        PrismStepPulseDot(size: 8)
                            .offset(x: -2.5, y: 2.5)
                    } else if status.unread {
                        Circle()
                            .fill(tokens.primary)
                            .frame(width: 5.5, height: 5.5)
                            .offset(x: -3, y: 3)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(railHelp(node: node, host: multiHost ? host : nil, status: status, stillRunning: stillRunning, nowMs: nowMs))
            .id("\(host.id)::rail-sess::\(node.id)")
        }
    }

    /// The rail's tooltip: the title, optional host name, still-running work, and how the last turn ended.
    private func railHelp(
        node: SidebarSessionNode,
        host: UnifiedHostSnapshot?,
        status: SidebarRowStatus,
        stillRunning: StillRunningInfo?,
        nowMs: Double
    ) -> String {
        let baseTitle = node.summary.title ?? l10n.tr("sidebar.untitledSession")
        let title = host.map { "\(baseTitle) · \($0.name)" } ?? baseTitle
        guard status.waiting == 0, !status.running, !status.starting else {
            return title
        }
        var lines = [title]
        if let stillRunning, stillRunning.hasWork {
            lines.append(SidebarStillRunning.description(stillRunning, l10n: l10n))
        }
        if let ending = status.ending {
            lines.append(ending.summaryLine(l10n: l10n, nowMs: nowMs))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Footer

    private func sidebarFooter() -> some View {
        MacSidebarFooterView(
            state: state,
            isCollapsed: isCollapsed,
            onOpenAccountSettings: {
                onHoverPreviewChanged(nil)
                onClosePopovers()
                onOpenAccountSettings()
            },
            onOpenSettings: {
                onHoverPreviewChanged(nil)
                onClosePopovers()
                onOpenSettings()
            }
        )
    }

    // MARK: - Helpers

    private func toggleHost(_ hostId: String) {
        withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier)) {
            if collapsedHosts.contains(hostId) {
                collapsedHosts.remove(hostId)
            } else {
                collapsedHosts.insert(hostId)
            }
        }
    }

    private func toggleGroup(_ key: String) {
        withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier)) {
            if collapsedGroups.contains(key) {
                collapsedGroups.remove(key)
            } else {
                collapsedGroups.insert(key)
            }
        }
    }

    private func presentAddProjectPanel(forHost hostId: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.resolvesAliases = true
        panel.prompt = l10n.tr("sidebar.addProject")
        if panel.runModal() == .OK, let url = panel.url {
            Task { await state.addProject(path: url.path, onHost: hostId) }
        }
    }
}

// MARK: - Sidebar Footer Leaf View

private struct MacSidebarFooterButtonStyle: ButtonStyle {
    let tokens: PrismTokens
    let isHovered: Bool
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        configuration.isPressed
                            ? tokens.activeWash
                            : (isHovered ? tokens.hoverWash : Color.clear)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct MacSidebarFooterView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    @Bindable var state: SartoState
    let isCollapsed: Bool
    let onOpenAccountSettings: () -> Void
    let onOpenSettings: () -> Void

    @State private var isAccountHovered = false
    @State private var isSettingsHovered = false

    private var accountState: CloudAccountStateInfo {
        state.cloudAccountStatus.account
    }

    private var displayName: String {
        let profile = accountState.account
        if let name = profile?.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let email = profile?.email.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
            return email
        }
        return "Sarto"
    }

    private var avatarInitial: String {
        String(displayName.prefix(1)).uppercased()
    }

    private var relayDotColor: Color {
        if let ms = state.relayLatencyMs {
            if ms < 150 { return tokens.success }
            if ms <= 350 { return tokens.warning }
            return tokens.danger
        }
        if state.relayLatencyFailed {
            return tokens.danger
        }
        return state.connectionMode.isLive ? tokens.success : tokens.warning
    }

    private var relayLatencyLabel: String {
        if let ms = state.relayLatencyMs {
            return l10n.tr("sidebar.footer.relayLatency", ms)
        }
        if state.relayLatencyFailed {
            return l10n.tr("sidebar.footer.relayOffline")
        }
        return l10n.tr("sidebar.footer.relayProbing")
    }

    private var relayLatencyColor: Color {
        if let ms = state.relayLatencyMs {
            if ms < 150 { return tokens.mutedForeground }
            if ms <= 350 { return tokens.warning }
            return tokens.danger
        }
        if state.relayLatencyFailed {
            return tokens.danger
        }
        return tokens.placeholder
    }

    private var onlineDevicesLabel: String {
        let count = state.onlineDevicesCount
        if count > 0 {
            return l10n.tr("sidebar.host.onlineCount", count)
        }
        return l10n.tr("sidebar.host.offline")
    }

    private var accountHelpText: String {
        if accountState.isSignedIn {
            let email = accountState.account?.email.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let identity = (!email.isEmpty && email != displayName) ? "\(displayName) (\(email))" : displayName
            return "\(identity)\n\(relayLatencyLabel) · \(onlineDevicesLabel)"
        }
        if accountState.isSigningIn {
            return l10n.tr("sidebar.footer.signingIn")
        }
        return l10n.tr("sidebar.footer.signIn")
    }

    var body: some View {
        if isCollapsed {
            collapsedFooter
        } else {
            expandedFooter
        }
    }

    private var expandedFooter: some View {
        HStack(spacing: 4) {
            Button(action: onOpenAccountSettings) {
                HStack(spacing: 9) {
                    accountBadge(size: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        if accountState.isSignedIn {
                            Text(displayName)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(tokens.foreground)
                                .lineLimit(1)
                                .truncationMode(.tail)

                            HStack(spacing: 4) {
                                Text(relayLatencyLabel)
                                    .foregroundStyle(relayLatencyColor)
                                Text("·")
                                    .foregroundStyle(tokens.placeholder)
                                Text(onlineDevicesLabel)
                                    .foregroundStyle(
                                        state.onlineDevicesCount > 0 ? tokens.mutedForeground : tokens.placeholder
                                    )
                            }
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .lineLimit(1)
                            .minimumScaleFactor(0.86)
                        } else if accountState.isSigningIn {
                            Text(l10n.tr("sidebar.footer.signingIn"))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(tokens.foreground)
                                .lineLimit(1)
                            Text(l10n.tr("sidebar.footer.signingInSub"))
                                .font(.system(size: 10))
                                .foregroundStyle(tokens.placeholder)
                                .lineLimit(1)
                        } else {
                            Text(l10n.tr("sidebar.footer.signIn"))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(tokens.foreground)
                                .lineLimit(1)
                            Text(
                                state.connectionMode.isLive
                                    ? l10n.tr("sidebar.footer.signInSub")
                                    : l10n.tr("sidebar.footer.daemonOffline")
                            )
                            .font(.system(size: 10))
                            .foregroundStyle(state.connectionMode.isLive ? tokens.placeholder : tokens.warning)
                            .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 2)

                    if !accountState.isSignedIn && !accountState.isSigningIn {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(isAccountHovered ? tokens.secondaryForeground : tokens.placeholder)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            }
            .buttonStyle(MacSidebarFooterButtonStyle(tokens: tokens, isHovered: isAccountHovered, cornerRadius: tokens.rSM))
            .onHover { isAccountHovered = $0 }
            .help(accountHelpText)

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSettingsHovered ? tokens.foreground : tokens.mutedForeground)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(MacSidebarFooterButtonStyle(tokens: tokens, isHovered: isSettingsHovered, cornerRadius: tokens.rSM))
            .onHover { isSettingsHovered = $0 }
            .help(l10n.tr("sidebar.footer.settingsTooltip"))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }

    private var collapsedFooter: some View {
        VStack(spacing: 4) {
            Button(action: onOpenAccountSettings) {
                accountBadge(size: 22)
                    .frame(width: 34, height: 32)
            }
            .buttonStyle(MacSidebarFooterButtonStyle(tokens: tokens, isHovered: isAccountHovered, cornerRadius: tokens.rSM))
            .onHover { isAccountHovered = $0 }
            .help(accountHelpText)

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSettingsHovered ? tokens.foreground : tokens.mutedForeground)
                    .frame(width: 34, height: 28)
            }
            .buttonStyle(MacSidebarFooterButtonStyle(tokens: tokens, isHovered: isSettingsHovered, cornerRadius: tokens.rSM))
            .onHover { isSettingsHovered = $0 }
            .help(l10n.tr("sidebar.footer.settingsTooltip"))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func accountBadge(size: CGFloat) -> some View {
        if accountState.isSignedIn {
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(tokens.primarySoft)
                    .overlay(
                        Circle()
                            .strokeBorder(tokens.primary.opacity(0.22), lineWidth: 1)
                    )
                    .frame(width: size, height: size)
                    .overlay(
                        Text(avatarInitial)
                            .font(.system(size: size * 0.46, weight: .semibold))
                            .foregroundStyle(tokens.primary)
                    )

                Circle()
                    .fill(relayDotColor)
                    .frame(width: 7, height: 7)
                    .overlay(
                        Circle()
                            .strokeBorder(tokens.sidebar, lineWidth: 1.5)
                    )
                    .offset(x: 1, y: 1)
            }
            .frame(width: size, height: size)
        } else if accountState.isSigningIn {
            Circle()
                .fill(tokens.primarySoft)
                .frame(width: size, height: size)
                .overlay(PrismTurnDotsView(phase: .thinking, size: 11))
        } else {
            Circle()
                .fill(isAccountHovered ? tokens.primarySoft : tokens.surface2)
                .overlay(
                    Circle()
                        .strokeBorder(
                            isAccountHovered ? tokens.primary.opacity(0.24) : tokens.borderEtched,
                            lineWidth: 1
                        )
                )
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: size * 0.56, weight: .medium))
                        .foregroundStyle(isAccountHovered ? tokens.primary : tokens.secondaryForeground)
                )
        }
    }
}

// MARK: - Unified Tree Computer Section Header Row

private struct MacSidebarHostHeaderRow: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    let host: UnifiedHostSnapshot
    let isOpen: Bool
    let isActiveHost: Bool
    let onToggle: () -> Void
    let onNewSession: (() -> Void)?
    let onAddProject: (() -> Void)?
    let onManageDevices: () -> Void

    @State private var isHovered = false

    private var statusColor: Color {
        if host.isOnline {
            return host.isLocal ? tokens.success : tokens.prismCobalt
        }
        return host.isConnecting ? tokens.warning : tokens.placeholder.opacity(0.55)
    }

    private var routeLabel: String {
        if host.isLocal { return l10n.tr("sidebar.host.thisMac") }
        if host.isOnline { return host.viaRelay ? l10n.tr("sidebar.host.relay") : l10n.tr("sidebar.host.direct") }
        if host.isConnecting { return l10n.tr("sidebar.host.connecting") }
        return l10n.tr("sidebar.host.offline")
    }

    private var menuItems: [SidebarRowMenuItem] {
        var list: [SidebarRowMenuItem] = []
        if let onNewSession {
            list.append(SidebarRowMenuItem(
                title: l10n.tr("sidebar.host.newSession"),
                symbolName: "square.and.pencil",
                action: onNewSession
            ))
        }
        if let onAddProject {
            list.append(SidebarRowMenuItem(
                title: l10n.tr("sidebar.addProject"),
                symbolName: "folder.badge.plus",
                action: onAddProject
            ))
        }
        list.append(SidebarRowMenuItem(
            title: l10n.tr("sidebar.host.manageDevices"),
            symbolName: "slider.horizontal.3",
            isSeparatorBefore: !list.isEmpty,
            action: onManageDevices
        ))
        return list
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 5.5, height: 5.5)

            Image(systemName: host.deviceSymbolName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(
                    !host.isOnline && !host.isLocal
                        ? tokens.placeholder
                        : (isActiveHost ? tokens.secondaryForeground : tokens.mutedForeground)
                )
                .frame(width: 14)

            Text(host.name)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(
                    !host.isOnline && !host.isLocal
                        ? tokens.placeholder
                        : (isActiveHost ? tokens.foreground : tokens.secondaryForeground)
                )
                .lineLimit(1)
                .truncationMode(.tail)

            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(tokens.placeholder)
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .opacity(isHovered ? 0.9 : 0.45)

            Spacer(minLength: 4)

            if isHovered {
                HStack(spacing: 2) {
                    Menu {
                        if let onNewSession {
                            Button(action: onNewSession) {
                                Label(l10n.tr("sidebar.host.newSession"), systemImage: "square.and.pencil")
                            }
                        }
                        if let onAddProject {
                            Button(action: onAddProject) {
                                Label(l10n.tr("sidebar.addProject"), systemImage: "folder.badge.plus")
                            }
                        }
                        if onNewSession != nil || onAddProject != nil {
                            Divider()
                        }
                        Button(action: onManageDevices) {
                            Label(l10n.tr("sidebar.host.manageDevices"), systemImage: "slider.horizontal.3")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(tokens.secondaryForeground)
                            .frame(width: 20, height: 20)
                            .background(RoundedRectangle(cornerRadius: 4.5, style: .continuous).fill(tokens.surface2.opacity(0.85)))
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()

                    if let onAddProject {
                        Button(action: onAddProject) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(tokens.secondaryForeground)
                                .frame(width: 20, height: 20)
                                .background(RoundedRectangle(cornerRadius: 4.5, style: .continuous).fill(tokens.surface2.opacity(0.85)))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(l10n.tr("sidebar.addProject"))
                    }

                    if let onNewSession {
                        Button(action: onNewSession) {
                            Image(systemName: "plus")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(tokens.secondaryForeground)
                                .frame(width: 20, height: 20)
                                .background(RoundedRectangle(cornerRadius: 4.5, style: .continuous).fill(tokens.surface2.opacity(0.85)))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(l10n.tr("sidebar.host.newSession"))
                    }
                }
            } else if !isOpen && host.waitingCount > 0 {
                HStack(spacing: 3) {
                    Circle()
                        .fill(tokens.warning)
                        .frame(width: 6, height: 6)
                    Text("\(host.waitingCount)")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(tokens.warning)
                }
            } else if !isOpen && host.runningCount > 0 {
                PrismTurnDotsView(phase: .working, size: 10)
            } else {
                Text(routeLabel)
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(tokens.placeholder)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                .fill(isHovered ? tokens.hoverWash.opacity(0.55) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        .onHover { isHovered = $0 }
        .overlay {
            SidebarRowRightClickOverlay(items: menuItems)
        }
        .help("\(host.fullName) · \(routeLabel)")
    }
}

/// Holds a row's last measured position outside SwiftUI's state, read only when its hover card opens.
@MainActor
private final class SidebarRowGeometry {
    var midY: CGFloat = 0
}

// MARK: - Project Folder Header Row

private struct MacSidebarProjectHeaderRow: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    let project: ProjectInfo?
    let hint: String?
    let isOpen: Bool
    let isPinned: Bool
    let sessionCount: Int
    let onToggle: () -> Void
    let onNewSession: () -> Void
    let onTogglePin: () -> Void
    let onRevealInFinder: (() -> Void)?
    let onOpenTerminal: (() -> Void)?
    let onRemove: (() -> Void)?

    @State private var isHovered = false

    private var title: String {
        project?.name ?? l10n.tr("sidebar.noProject")
    }

    private var isMissing: Bool {
        project?.isMissing == true
    }

    private var menuItems: [SidebarRowMenuItem] {
        var list: [SidebarRowMenuItem] = []
        if !isMissing {
            list.append(SidebarRowMenuItem(
                title: l10n.tr("sidebar.projectNewSession"),
                symbolName: "square.and.pencil",
                action: onNewSession
            ))
        }
        list.append(SidebarRowMenuItem(
            title: isPinned ? l10n.tr("sidebar.projectUnpin") : l10n.tr("sidebar.projectPin"),
            symbolName: isPinned ? "pin.slash" : "pin",
            action: onTogglePin
        ))
        if let onOpenTerminal, !isMissing {
            list.append(SidebarRowMenuItem(
                title: l10n.tr("sidebar.projectOpenTerminal"),
                symbolName: "terminal",
                isSeparatorBefore: true,
                action: onOpenTerminal
            ))
        }
        if let onRevealInFinder, !isMissing {
            list.append(SidebarRowMenuItem(
                title: l10n.tr("sidebar.projectShowInFinder"),
                symbolName: "folder",
                isSeparatorBefore: onOpenTerminal == nil,
                action: onRevealInFinder
            ))
        }
        if let onRemove {
            list.append(SidebarRowMenuItem(
                title: l10n.tr("sidebar.projectRemove"),
                symbolName: "folder.badge.minus",
                isDestructive: true,
                isSeparatorBefore: true,
                action: onRemove
            ))
        }
        return list
    }

    var body: some View {
        HStack(spacing: 6.5) {
            Image(systemName: project == nil ? "tray" : (isOpen ? "folder.fill" : "folder"))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(
                    isMissing ? tokens.placeholder
                        : (isOpen ? tokens.secondaryForeground : tokens.mutedForeground)
                )
                .frame(width: 16)

            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(isMissing ? tokens.placeholder : tokens.foreground.opacity(0.92))
                    .lineLimit(1)

                if let hint, !hint.isEmpty {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(tokens.placeholder)
                        .lineLimit(1)
                }

                if isMissing {
                    Text(l10n.tr("sidebar.projectMissing"))
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(tokens.warning)
                }
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(tokens.placeholder)
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .opacity(isHovered ? 0.9 : 0.45)

            Spacer(minLength: 4)

            if isHovered {
                HStack(spacing: 2) {
                    Menu {
                        if !isMissing {
                            Button(action: onNewSession) {
                                Label(l10n.tr("sidebar.projectNewSession"), systemImage: "square.and.pencil")
                            }
                        }
                        Button(action: onTogglePin) {
                            Label(
                                isPinned ? l10n.tr("sidebar.projectUnpin") : l10n.tr("sidebar.projectPin"),
                                systemImage: isPinned ? "pin.slash" : "pin"
                            )
                        }
                        if onOpenTerminal != nil || onRevealInFinder != nil {
                            Divider()
                            if let onOpenTerminal, !isMissing {
                                Button(action: onOpenTerminal) {
                                    Label(l10n.tr("sidebar.projectOpenTerminal"), systemImage: "terminal")
                                }
                            }
                            if let onRevealInFinder, !isMissing {
                                Button(action: onRevealInFinder) {
                                    Label(l10n.tr("sidebar.projectShowInFinder"), systemImage: "folder")
                                }
                            }
                        }
                        if let onRemove {
                            Divider()
                            Button(role: .destructive, action: onRemove) {
                                Label(l10n.tr("sidebar.projectRemove"), systemImage: "folder.badge.minus")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(tokens.secondaryForeground)
                            .frame(width: 20, height: 20)
                            .background(RoundedRectangle(cornerRadius: 4.5, style: .continuous).fill(tokens.surface2.opacity(0.85)))
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()

                    if !isMissing {
                        Button(action: onNewSession) {
                            Image(systemName: "plus")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(tokens.secondaryForeground)
                                .frame(width: 20, height: 20)
                                .background(RoundedRectangle(cornerRadius: 4.5, style: .continuous).fill(tokens.surface2.opacity(0.85)))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(l10n.tr("sidebar.projectNewSession"))
                    }
                }
            } else if !isOpen && sessionCount > 0 {
                Text("\(sessionCount)")
                    .font(.system(size: 10, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(tokens.placeholder)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 29)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                .fill(isHovered ? tokens.hoverWash.opacity(0.65) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        .onHover { isHovered = $0 }
        .overlay {
            SidebarRowRightClickOverlay(items: menuItems)
        }
        .help(project?.path ?? l10n.tr("sidebar.noProject"))
    }
}

// MARK: - Compact Single-Line Session Row (Sarto Fidelity)

enum SidebarTreeBranch {
    case middle
    case last
}

private struct MacSidebarCompactSessionRow: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    let hostId: String
    let hostName: String?
    let node: SidebarSessionNode
    let status: SidebarRowStatus
    let isSelected: Bool
    let indent: Bool
    let branch: SidebarTreeBranch?
    let hasChildren: Bool
    let isExpanded: Bool
    let canFork: Bool
    let isRenaming: Bool
    @Binding var renameText: String
    @Binding var showFinishedSubagents: Bool
    let onToggleExpand: (() -> Void)?
    let onSelect: () -> Void
    let onOpenSubagent: (String) -> Void
    let onStartInlineRename: () -> Void
    let onCommitInlineRename: () -> Void
    let onCancelInlineRename: () -> Void
    let onStop: () -> Void
    let onRetry: () -> Void
    let onTogglePin: () -> Void
    let onToggleUnread: () -> Void
    let onFork: () -> Void
    let onNewSubSession: () -> Void
    let onRevealInFinder: (() -> Void)?
    let onCopyResume: (() -> Void)?
    let onExportMarkdown: () -> Void
    let onToggleArchive: () -> Void
    let onRequestDelete: () -> Void
    let onHoverPreview: (SidebarHoverPreview?) -> Void

    @State private var isHovered = false
    @State private var rowGeometry = SidebarRowGeometry()
    @State private var hoverPreviewTask: Task<Void, Never>? = nil
    @State private var lastClickAt: CFTimeInterval = 0
    @FocusState private var renameFocused: Bool

    private var summary: SessionSummary { node.summary }
    private var isPinned: Bool { summary.pinnedAt != nil }
    private var isArchived: Bool { summary.archivedAt != nil }
    private var isTopLevel: Bool { summary.parentId == nil }
    private var isLiveRunning: Bool {
        summary.status == .running || summary.status == .awaitingPermission
    }

    private var leadingPad: CGFloat {
        let base: CGFloat = indent ? 22 : 8
        return branch != nil ? base + 18 : base
    }

    private var menuItems: [SidebarRowMenuItem] {
        var list: [SidebarRowMenuItem] = []

        if isLiveRunning {
            list.append(SidebarRowMenuItem(
                title: l10n.tr("sidebar.stopTurn"),
                symbolName: "stop.circle",
                action: onStop
            ))
        } else if summary.status == .failed || summary.status == .authRequired {
            list.append(SidebarRowMenuItem(
                title: l10n.tr("sidebar.retryTurn"),
                symbolName: "arrow.clockwise",
                action: onRetry
            ))
        }

        let needSepBeforeCore = !list.isEmpty
        if isTopLevel && !isArchived {
            list.append(SidebarRowMenuItem(
                title: isPinned ? l10n.tr("sidebar.unpin") : l10n.tr("sidebar.pin"),
                symbolName: isPinned ? "pin.slash" : "pin",
                isSeparatorBefore: needSepBeforeCore,
                action: onTogglePin
            ))
        }
        if !isArchived {
            let isUnread = summary.attention == "unread"
            list.append(SidebarRowMenuItem(
                title: isUnread ? l10n.tr("sidebar.markRead") : l10n.tr("sidebar.markUnread"),
                symbolName: isUnread ? "checkmark.circle" : "circle.fill",
                isSeparatorBefore: !isTopLevel && needSepBeforeCore,
                action: onToggleUnread
            ))
            list.append(SidebarRowMenuItem(
                title: l10n.tr("sidebar.rename"),
                symbolName: "pencil",
                action: onStartInlineRename
            ))
        }

        if !isArchived {
            var addedBranchGroup = false
            if canFork {
                list.append(SidebarRowMenuItem(
                    title: l10n.tr("sidebar.fork"),
                    symbolName: "arrow.triangle.branch",
                    isSeparatorBefore: true,
                    action: onFork
                ))
                addedBranchGroup = true
            }
            list.append(SidebarRowMenuItem(
                title: l10n.tr("sidebar.newSubSession"),
                symbolName: "arrow.turn.down.right",
                isSeparatorBefore: !addedBranchGroup,
                action: onNewSubSession
            ))
        }

        var addedSystemGroup = false
        if let onCopyResume {
            list.append(SidebarRowMenuItem(
                title: l10n.tr("sidebar.copyResumeCommand"),
                symbolName: "terminal",
                isSeparatorBefore: true,
                action: onCopyResume
            ))
            addedSystemGroup = true
        }
        if let onRevealInFinder, !summary.projectPath.isEmpty {
            list.append(SidebarRowMenuItem(
                title: l10n.tr("sidebar.showInFinder"),
                symbolName: "folder",
                isSeparatorBefore: !addedSystemGroup,
                action: onRevealInFinder
            ))
            addedSystemGroup = true
        }
        list.append(SidebarRowMenuItem(
            title: l10n.tr("session.exportMarkdown"),
            symbolName: "square.and.arrow.up",
            isSeparatorBefore: !addedSystemGroup,
            action: onExportMarkdown
        ))

        if isTopLevel {
            list.append(SidebarRowMenuItem(
                title: isArchived ? l10n.tr("sidebar.unarchive") : l10n.tr("sidebar.archive"),
                symbolName: isArchived ? "tray.and.arrow.up" : "archivebox",
                isSeparatorBefore: true,
                action: onToggleArchive
            ))
        }

        list.append(SidebarRowMenuItem(
            title: l10n.tr("sidebar.delete"),
            symbolName: "trash",
            isDestructive: true,
            isSeparatorBefore: !isTopLevel,
            action: onRequestDelete
        ))
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ZStack(alignment: .leading) {
                if let branch {
                    SidebarTreeLineView(
                        isLast: branch == .last,
                        leftX: (indent ? 22 : 8) + 7,
                        color: tokens.borderStrong
                    )
                }

                HStack(spacing: 6) {
                    if hasChildren, let onToggleExpand {
                        Button(action: onToggleExpand) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(tokens.placeholder)
                                .frame(width: 13, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, -14)
                    }

                    SidebarAgentMarkView(
                        agentId: summary.agentId,
                        dimmed: status.cacheExpired,
                        size: 15
                    )

                    if isRenaming {
                        TextField(l10n.tr("sidebar.untitledSession"), text: $renameText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(tokens.foreground)
                            .focused($renameFocused)
                            .onSubmit { onCommitInlineRename() }
                            .onExitCommand { onCancelInlineRename() }
                            .onAppear { renameFocused = true }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(tokens.codeBackground)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .strokeBorder(tokens.primaryBorder, lineWidth: 1)
                            )
                    } else {
                        Text(summary.title ?? l10n.tr("sidebar.untitledSession"))
                            .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(
                                isArchived ? tokens.mutedForeground
                                    : (isSelected ? tokens.foreground : tokens.secondaryForeground)
                            )
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if !node.subagents.isEmpty {
                            SidebarSubagentBadgeView(
                                subagents: node.subagents,
                                showFinished: $showFinishedSubagents,
                                onOpenSubagent: onOpenSubagent,
                                onPopoverOpen: { cancelHoverPreview() }
                            )
                        }

                        if summary.worktree != nil {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(tokens.placeholder)
                        }

                        if hasChildren && !isExpanded {
                            Text("\(node.children.count)")
                                .font(.system(size: 10, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(tokens.placeholder)
                        }

                        Spacer(minLength: 4)

                        // Trailing fixed-width status / hover tool slot (zero layout shift on hover)
                        let stillRunning = (!status.running && !status.starting)
                            ? SidebarStillRunning.effective(for: node, rolledUp: hasChildren && !isExpanded)
                            : nil
                        ZStack(alignment: .trailing) {
                            SidebarPriorityStatusSlot(status: status, stillRunning: stillRunning)
                                .opacity(isHovered ? 0 : 1)

                            if isHovered {
                                HStack(spacing: 2) {
                                    Menu {
                                        swiftUIMenuBody()
                                    } label: {
                                        Image(systemName: "ellipsis")
                                            .font(.system(size: 10.5, weight: .semibold))
                                            .foregroundStyle(tokens.secondaryForeground)
                                            .frame(width: 20, height: 20)
                                            .background(
                                                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                                    .fill(tokens.surface2.opacity(0.9))
                                            )
                                            .contentShape(Rectangle())
                                    }
                                    .menuStyle(.borderlessButton)
                                    .menuIndicator(.hidden)
                                    .fixedSize()

                                    if isTopLevel && !isArchived {
                                        Button(action: onTogglePin) {
                                            Image(systemName: isPinned ? "pin.slash" : "pin")
                                                .font(.system(size: 9.5, weight: .medium))
                                                .foregroundStyle(isPinned ? tokens.prismCobalt : tokens.mutedForeground)
                                                .frame(width: 20, height: 20)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                                        .fill(tokens.surface2.opacity(0.9))
                                                )
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .help(isPinned ? l10n.tr("sidebar.unpin") : l10n.tr("sidebar.pin"))
                                    }
                                }
                            }
                        }
                        .frame(minWidth: 16, alignment: .trailing)
                    }
                }
                .padding(.leading, leadingPad)
                .padding(.trailing, 7)
                .frame(height: 30)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                        .fill(
                            isSelected ? tokens.activeWash
                                : (isHovered ? tokens.hoverWash.opacity(0.6) : tokens.sidebar.opacity(0.001))
                        )
                    if status.running {
                        RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [tokens.prismCobalt.opacity(0.09), tokens.prismIris.opacity(0.04), Color.clear],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    }
                }
            )
            .overlay(alignment: .leading) {
                if status.running {
                    PrismRunningRowBar()
                        .frame(height: 18)
                } else if isSelected {
                    Capsule()
                        .fill(tokens.primary)
                        .frame(width: 2.5, height: 16)
                        .shadow(color: tokens.primary.opacity(0.55), radius: 4)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isRenaming else { return }
                let now = CACurrentMediaTime()
                if isSelected && !isArchived && (now - lastClickAt) < 0.34 {
                    lastClickAt = 0
                    onStartInlineRename()
                } else {
                    lastClickAt = now
                    onSelect()
                }
            }
            .onHover { hovering in
                isHovered = hovering
                if hovering && !isRenaming {
                    scheduleHoverPreview()
                } else {
                    cancelHoverPreview()
                }
            }
            .onGeometryChange(for: Int.self) { proxy in
                Int((proxy.frame(in: .named("workbench-root")).midY / 4.0).rounded()) * 4
            } action: { _, midY in
                // A plain reference write: scrolling must not re-render the visible rows.
                rowGeometry.midY = CGFloat(midY)
            }
            .overlay {
                if !isRenaming {
                    SidebarRowRightClickOverlay(items: menuItems)
                }
            }
            .onDisappear {
                hoverPreviewTask?.cancel()
            }

            if isRenaming {
                Text(l10n.tr("sidebar.renameHint"))
                    .font(.system(size: 9.5))
                    .foregroundStyle(tokens.placeholder)
                    .padding(.leading, leadingPad + 20)
                    .padding(.bottom, 2)
            }
        }
    }

    @ViewBuilder
    private func swiftUIMenuBody() -> some View {
        if isLiveRunning {
            Button(action: onStop) {
                Label(l10n.tr("sidebar.stopTurn"), systemImage: "stop.circle")
            }
            Divider()
        } else if summary.status == .failed || summary.status == .authRequired {
            Button(action: onRetry) {
                Label(l10n.tr("sidebar.retryTurn"), systemImage: "arrow.clockwise")
            }
            Divider()
        }

        if isTopLevel && !isArchived {
            Button(action: onTogglePin) {
                Label(
                    isPinned ? l10n.tr("sidebar.unpin") : l10n.tr("sidebar.pin"),
                    systemImage: isPinned ? "pin.slash" : "pin"
                )
            }
        }
        if !isArchived {
            let isUnread = summary.attention == "unread"
            Button(action: onToggleUnread) {
                Label(
                    isUnread ? l10n.tr("sidebar.markRead") : l10n.tr("sidebar.markUnread"),
                    systemImage: isUnread ? "checkmark.circle" : "circle.fill"
                )
            }
            Button(action: onStartInlineRename) {
                Label(l10n.tr("sidebar.rename"), systemImage: "pencil")
            }
            Divider()
            if canFork {
                Button(action: onFork) {
                    Label(l10n.tr("sidebar.fork"), systemImage: "arrow.triangle.branch")
                }
            }
            Button(action: onNewSubSession) {
                Label(l10n.tr("sidebar.newSubSession"), systemImage: "arrow.turn.down.right")
            }
        }

        Divider()
        if let onCopyResume {
            Button(action: onCopyResume) {
                Label(l10n.tr("sidebar.copyResumeCommand"), systemImage: "terminal")
            }
        }
        if let onRevealInFinder, !summary.projectPath.isEmpty {
            Button(action: onRevealInFinder) {
                Label(l10n.tr("sidebar.showInFinder"), systemImage: "folder")
            }
        }
        Button(action: onExportMarkdown) {
            Label(l10n.tr("session.exportMarkdown"), systemImage: "square.and.arrow.up")
        }

        Divider()
        if isTopLevel {
            Button(action: onToggleArchive) {
                Label(
                    isArchived ? l10n.tr("sidebar.unarchive") : l10n.tr("sidebar.archive"),
                    systemImage: isArchived ? "tray.and.arrow.up" : "archivebox"
                )
            }
        }
        Button(role: .destructive, action: onRequestDelete) {
            Label(l10n.tr("sidebar.delete"), systemImage: "trash")
        }
    }

    private func scheduleHoverPreview() {
        hoverPreviewTask?.cancel()
        hoverPreviewTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(520))
            guard !Task.isCancelled, isHovered, !isRenaming else { return }
            onHoverPreview(
                SidebarHoverPreview(
                    hostId: hostId,
                    hostName: hostName,
                    node: node,
                    rowMidY: rowGeometry.midY
                )
            )
        }
    }

    private func cancelHoverPreview() {
        hoverPreviewTask?.cancel()
        hoverPreviewTask = nil
        onHoverPreview(nil)
    }
}

// MARK: - Priority Status Slot

private enum SidebarStillRunning {
    /// Background commands and sub-agents running after a session's turn ended.
    /// Rolls up non-running child sessions when a parent row is collapsed.
    static func effective(for node: SidebarSessionNode, rolledUp: Bool) -> StillRunningInfo? {
        var commands = 0
        var subagents = 0
        var reportsBack = false

        func accumulate(_ summary: SessionSummary) {
            guard summary.status != .running,
                  summary.status != .starting,
                  let still = summary.stillRunning,
                  still.hasWork
            else { return }
            commands += still.commands
            subagents += still.subagents
            reportsBack = reportsBack || still.reportsBack
        }

        accumulate(node.summary)
        if rolledUp {
            for child in node.children {
                accumulate(child.summary)
            }
        }
        guard commands > 0 || subagents > 0 else { return nil }
        return StillRunningInfo(commands: commands, subagents: subagents, reportsBack: reportsBack)
    }

    static func description(_ still: StillRunningInfo, l10n: PrismL10n) -> String {
        if still.commands > 0 && still.subagents > 0 {
            return l10n.tr("session.stillRunning.both", still.commands, still.subagents)
        } else if still.commands > 0 {
            return still.commands == 1
                ? l10n.tr("session.stillRunning.commands", 1)
                : l10n.tr("session.stillRunning.commandsPlural", still.commands)
        } else {
            return still.subagents == 1
                ? l10n.tr("session.stillRunning.subagents", 1)
                : l10n.tr("session.stillRunning.subagentsPlural", still.subagents)
        }
    }

    static func tooltip(_ still: StillRunningInfo, l10n: PrismL10n) -> String {
        let detail = description(still, l10n: l10n)
        if still.reportsBack {
            return "\(detail)\n\(l10n.tr("session.stillRunning.reportsBack"))"
        }
        return detail
    }
}

private struct SidebarPriorityStatusSlot: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    let status: SidebarRowStatus
    let stillRunning: StillRunningInfo?

    var body: some View {
        Group {
            if status.waiting > 0 {
                HStack(spacing: 3) {
                    Circle()
                        .fill(tokens.warning)
                        .frame(width: 7, height: 7)
                        .shadow(color: tokens.warning.opacity(0.65), radius: 4)
                    if status.waiting > 1 {
                        Text("\(status.waiting)")
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(tokens.warning)
                    }
                }
            } else if status.failed {
                // A limit that refused the turn reads as the limit, anything else as a failure.
                let ending = status.ending.flatMap { $0.isError ? $0 : nil }
                let (symbol, color) = ending.map {
                    SidebarTurnEndingMark.appearance($0, unseen: true, nowMs: 0, tokens: tokens)
                } ?? ("exclamationmark.triangle.fill", tokens.danger)
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(color)
                    .accessibilityLabel(ending.map { $0.title(l10n: l10n) } ?? l10n.tr("sidebar.cardFailed"))
            } else if status.running || status.starting {
                PrismTurnDotsView(phase: status.running ? .working : .thinking, size: 12)
            } else if let still = stillRunning, still.hasWork {
                HStack(spacing: 4) {
                    PrismStepPulseDot(size: 8)
                    Text(l10n.tr("sidebar.stillRunningBadge"))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(tokens.primary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 5.5)
                .padding(.vertical, 2)
                .background(Capsule().fill(tokens.primarySoft))
                .overlay(Capsule().strokeBorder(tokens.primaryBorder, lineWidth: 0.75))
                .fixedSize()
                .help(SidebarStillRunning.tooltip(still, l10n: l10n))
                .accessibilityLabel(SidebarStillRunning.tooltip(still, l10n: l10n))
            } else if let mins = status.cacheExpiringMinutes {
                Text("\(mins)m")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(tokens.warning)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(tokens.warningSoft))
            } else if status.unread {
                Circle()
                    .fill(tokens.primary)
                    .frame(width: 6, height: 6)
            } else if let ending = status.ending {
                SidebarTurnEndingMark(ending: ending)
            } else {
                Color.clear.frame(width: 14, height: 14)
            }
        }
    }
}

/// The quiet mark a seen session keeps for how its last turn ended, until its next turn starts.
private struct SidebarTurnEndingMark: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    let ending: SidebarTurnEnding

    var body: some View {
        let nowMs = Date().timeIntervalSince1970 * 1000.0
        let (symbol, color) = Self.appearance(ending, unseen: false, nowMs: nowMs, tokens: tokens)
        Image(systemName: symbol)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 14, height: 14)
            .accessibilityLabel(ending.title(l10n: l10n))
    }

    /// An unseen error ending is drawn as loudly as a failure; a seen one, or a stop reason, quietly.
    static func appearance(
        _ ending: SidebarTurnEnding,
        unseen: Bool,
        nowMs: Double,
        tokens: PrismTokens
    ) -> (String, Color) {
        switch ending.kind {
        case .failed:
            return unseen
                ? ("exclamationmark.triangle.fill", tokens.danger)
                : ("exclamationmark.triangle", tokens.danger.opacity(0.8))
        case .limit:
            if unseen { return ("hourglass", tokens.danger) }
            return ("hourglass", ending.limitHolds(nowMs: nowMs) ? tokens.warning : tokens.placeholder)
        case .cancelled: return ("stop.circle", tokens.placeholder)
        case .maxTokens: return ("scissors", tokens.placeholder)
        case .maxTurnRequests: return ("gauge.with.dots.needle.100percent", tokens.placeholder)
        case .refusal: return ("hand.raised", tokens.placeholder)
        }
    }
}

// MARK: - Agent Brand Mark (Desaturates When Prompt Cache Expired)

struct SidebarAgentMarkView: View {
    @Environment(\.prismTokens) private var tokens

    let agentId: String
    let dimmed: Bool
    let size: CGFloat

    private var brandColor: Color {
        switch agentId {
        case "antigravity", "gemini": return Color(hex: 0x4C8DF6)
        case "claude-code": return Color(hex: 0xD97757)
        case "codex": return Color(hex: 0x669DF6)
        case "opencode": return Color(hex: 0x9B72CB)
        case "pi": return Color(hex: 0x50A37B)
        default: return tokens.success
        }
    }

    /// Every agent shows the first letter of its name; the brand color tells apart two that share one.
    private var monogram: String {
        String(agentId.prefix(1)).uppercased()
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: max(3.5, size * 0.28), style: .continuous)
                .fill(brandColor.opacity(dimmed ? 0.12 : 0.20))
                .overlay(
                    RoundedRectangle(cornerRadius: max(3.5, size * 0.28), style: .continuous)
                        .strokeBorder(brandColor.opacity(dimmed ? 0.22 : 0.45), lineWidth: 0.75)
                )

            Text(monogram)
                .font(.system(size: size * 0.60, weight: .bold, design: .rounded))
                .foregroundStyle(brandColor)
        }
        .frame(width: size, height: size)
        .saturation(dimmed ? 0.18 : 1.0)
        .opacity(dimmed ? 0.48 : 1.0)
    }
}

// MARK: - Subagent Compact Badge + Interactive Popover (Mirrors subagent-badge.tsx)

private struct SidebarSubagentBadgeView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    let subagents: [SessionSummary]
    @Binding var showFinished: Bool
    let onOpenSubagent: (String) -> Void
    let onPopoverOpen: () -> Void

    @State private var isPopoverOpen = false

    private var runningSubagents: [SessionSummary] {
        subagents.filter {
            $0.status == .running || $0.status == .starting || $0.status == .awaitingPermission || $0.permissionCount > 0
        }
    }

    private var displayedSubagents: [SessionSummary] {
        showFinished ? subagents : (runningSubagents.isEmpty ? subagents : runningSubagents)
    }

    var body: some View {
        let runningCount = runningSubagents.count
        let badgeCount = runningCount > 0 ? runningCount : subagents.count

        Button {
            onPopoverOpen()
            isPopoverOpen.toggle()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "cpu")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(runningCount > 0 ? tokens.prismCobalt : tokens.placeholder)
                Text("\(badgeCount)")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(runningCount > 0 ? tokens.foreground : tokens.mutedForeground)
                if runningCount > 0 {
                    PrismTurnDotsView(phase: .working, size: 9)
                }
            }
            .padding(.horizontal, 5)
            .frame(height: 17)
            .background(Capsule().fill(runningCount > 0 ? tokens.primarySoft : tokens.surface2.opacity(0.75)))
            .overlay(
                Capsule().strokeBorder(
                    runningCount > 0 ? tokens.primaryBorder : tokens.borderEtched,
                    lineWidth: 0.75
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPopoverOpen, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(l10n.tr("sidebar.subagentsTitle"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tokens.mutedForeground)
                    Spacer()
                    if runningCount > 0 {
                        Text(l10n.tr("sidebar.subagentsRunning", runningCount))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(tokens.prismCobalt)
                    }
                }
                .padding(.horizontal, 4)

                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(displayedSubagents) { child in
                            let isWaiting = child.permissionCount > 0 || child.status == .awaitingPermission
                            let isRunning = !isWaiting && (child.status == .running || child.status == .starting)
                            let isFailed = child.status == .failed || child.attention == "error"

                            Button {
                                isPopoverOpen = false
                                onOpenSubagent(child.id)
                            } label: {
                                HStack(spacing: 8) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .fill(tokens.surface2)
                                            .frame(width: 22, height: 22)
                                        Image(systemName: "cpu")
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(tokens.secondaryForeground)
                                    }

                                    VStack(alignment: .leading, spacing: 1.5) {
                                        Text(child.title ?? child.id)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(tokens.foreground)
                                            .lineLimit(1)
                                        if let desc = child.description, !desc.isEmpty {
                                            Text(desc)
                                                .font(.system(size: 10.5))
                                                .foregroundStyle(tokens.mutedForeground)
                                                .lineLimit(1)
                                        }
                                    }

                                    Spacer(minLength: 4)

                                    if isWaiting {
                                        Circle().fill(tokens.warning).frame(width: 7, height: 7)
                                    } else if isRunning {
                                        PrismTurnDotsView(phase: .working, size: 11)
                                    } else if isFailed {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .font(.system(size: 10))
                                            .foregroundStyle(tokens.danger)
                                    } else {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(tokens.success.opacity(0.85))
                                    }
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                                        .fill(tokens.hoverWash.opacity(0.45))
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 220)

                if runningCount > 0 && subagents.count > runningCount {
                    Rectangle().fill(tokens.borderEtched).frame(height: 1)
                    Toggle(l10n.tr("sidebar.subagentsShowFinished"), isOn: $showFinished)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokens.secondaryForeground)
                        .padding(.horizontal, 4)
                }
            }
            .padding(10)
            .frame(width: 280)
            .background(tokens.surface1)
            .focusEffectDisabled()
        }
    }
}

// MARK: - Child Session Tree Connector Line

private struct SidebarTreeLineView: View {
    let isLast: Bool
    let leftX: CGFloat
    let color: Color

    var body: some View {
        GeometryReader { geo in
            Path { path in
                let midY = geo.size.height * 0.5
                if isLast {
                    path.move(to: CGPoint(x: leftX, y: 0))
                    path.addLine(to: CGPoint(x: leftX, y: max(0, midY - 4)))
                    path.addQuadCurve(
                        to: CGPoint(x: leftX + 4, y: midY),
                        control: CGPoint(x: leftX, y: midY)
                    )
                    path.addLine(to: CGPoint(x: leftX + 9, y: midY))
                } else {
                    path.move(to: CGPoint(x: leftX, y: 0))
                    path.addLine(to: CGPoint(x: leftX, y: geo.size.height))
                    path.move(to: CGPoint(x: leftX, y: midY))
                    path.addLine(to: CGPoint(x: leftX + 9, y: midY))
                }
            }
            .stroke(color.opacity(0.75), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Floating Hover Preview Card

struct SidebarSessionHoverCardView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    let preview: SidebarHoverPreview
    let agentDisplayName: String
    let onLoadOutputs: (String) async -> SessionOutputsInfo?

    @State private var outputs: SessionOutputsInfo? = nil

    private var summary: SessionSummary { preview.node.summary }

    var body: some View {
        let nowMs = Date().timeIntervalSince1970 * 1000.0
        let status = preview.node.rowStatus(rolledUp: true, nowMs: nowMs)

        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(summary.title ?? l10n.tr("sidebar.untitledSession"))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(tokens.foreground)
                    .lineLimit(3)

                HStack(spacing: 6) {
                    SidebarAgentMarkView(agentId: summary.agentId, dimmed: false, size: 14)

                    Text(
                        summary.model.map { "\(agentDisplayName) · \($0)" } ?? agentDisplayName
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.mutedForeground)
                    .lineLimit(1)

                    if let branch = summary.branch, !branch.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 9.5))
                                .foregroundStyle(tokens.placeholder)
                            Text(branch)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(tokens.mutedForeground)
                                .lineLimit(1)
                        }
                    }

                    if let hostName = preview.hostName, !hostName.isEmpty {
                        Spacer(minLength: 4)
                        Text(hostName)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(tokens.prismCobalt)
                            .lineLimit(1)
                    }
                }

                if summary.agentId == "claude-code", let modelHost = summary.modelHost {
                    HStack(spacing: 4) {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 9.5, weight: .medium))
                        Text(l10n.tr("remoteClaude.sidebarModelOn", SartoState.cleanHostDisplayName(modelHost.hostName)))
                            .font(.system(size: 10.5, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(tokens.prismCobalt)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 11)
            .padding(.bottom, 9)

            if let outputs, let reply = outputs.reply {
                let clean = SidebarTreeBuilder.plainPreviewExcerpt(reply)
                if !clean.isEmpty {
                    Text(clean)
                        .font(.system(size: 11.5))
                        .lineSpacing(3)
                        .foregroundStyle(tokens.secondaryForeground)
                        .lineLimit(3)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                }
            }

            Rectangle().fill(tokens.borderEtched).frame(height: 1)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    stateFooter(status: status, nowMs: nowMs)
                    Spacer(minLength: 6)
                    cacheFooter(nowMs: nowMs)
                }
                if status.waiting == 0, !status.running, !status.starting,
                   let still = SidebarStillRunning.effective(for: preview.node, rolledUp: true)
                {
                    HStack(spacing: 5) {
                        PrismStepPulseDot(size: 9)
                        Text(SidebarStillRunning.description(still, l10n: l10n))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(tokens.secondaryForeground)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                if status.waiting == 0, !status.running, !status.starting,
                   let ending = status.ending,
                   let detail = ending.detail(l10n: l10n, nowMs: nowMs)
                {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(ending.kind == .failed ? tokens.danger : tokens.mutedForeground)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7.5)
        }
        .frame(width: 312, alignment: .leading)
        .prismSurface(elevation: .popover, cornerRadius: tokens.rMD)
        .overlay(
            RoundedRectangle(cornerRadius: tokens.rMD, style: .continuous)
                .strokeBorder(tokens.borderStrong, lineWidth: 1)
        )
        .allowsHitTesting(false)
        .task(id: summary.id) {
            outputs = nil
            outputs = await onLoadOutputs(summary.id)
        }
    }

    @ViewBuilder
    private func stateFooter(status: SidebarRowStatus, nowMs: Double) -> some View {
        if status.waiting > 0 {
            HStack(spacing: 5) {
                Circle().fill(tokens.warning).frame(width: 6.5, height: 6.5)
                Text(l10n.tr("sidebar.cardWaiting", status.waiting))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(tokens.warning)
            }
        } else if status.running || status.starting {
            HStack(spacing: 5) {
                PrismTurnDotsView(phase: status.running ? .working : .thinking, size: 10.5)
                Text(l10n.tr(status.running ? "sidebar.cardRunning" : "sidebar.cardStarting"))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(tokens.prismCobalt)
            }
        } else {
            // An unseen failure the ending does not explain still reads as a plain failure.
            let ending = status.failed && status.ending?.isError != true ? nil : status.ending
            let endedAt = ending.map(\.endedAt).flatMap { $0 > 0 ? $0 : nil } ?? summary.updatedAt
            let rel = SidebarTreeBuilder.relativeTimeLabel(updatedAtMs: endedAt, nowMs: nowMs, l10n: l10n)
            let failed = status.failed || ending?.isError == true
            let tookStr: String? = (!failed ? outputs?.turnMs : nil).map {
                l10n.tr("sidebar.cardTook", ThreadTimelineBuilder.formatDuration($0))
            }
            let (symbol, color): (String, Color) = ending.map {
                SidebarTurnEndingMark.appearance($0, unseen: status.failed, nowMs: nowMs, tokens: tokens)
            } ?? (status.failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill", status.failed ? tokens.danger : tokens.success)
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10.5))
                    .foregroundStyle(color)
                Text(
                    [ending?.title(l10n: l10n) ?? l10n.tr(status.failed ? "sidebar.cardFailed" : "sidebar.cardDone"), rel, tookStr]
                        .compactMap { $0 }
                        .joined(separator: " · ")
                )
                .font(.system(size: 10.5))
                .foregroundStyle(tokens.mutedForeground)
                .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func cacheFooter(nowMs: Double) -> some View {
        if let cache = summary.cache {
            if let exp = cache.expiresAt {
                let remMs = exp - nowMs
                HStack(spacing: 4) {
                    Text(l10n.tr("sidebar.cardCache"))
                        .foregroundStyle(tokens.placeholder)
                    if remMs <= 0 {
                        Text(l10n.tr("sidebar.cardCacheExpired"))
                            .foregroundStyle(tokens.mutedForeground)
                    } else {
                        let mins = max(1, Int(ceil(remMs / 60_000.0)))
                        Text(l10n.tr("sidebar.cardCacheLeft", mins))
                            .foregroundStyle(remMs <= 5 * 60_000 ? tokens.warning : tokens.secondaryForeground)
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
            }
        }
    }
}

// MARK: - Native AppKit Right-Click Menu Overlay

struct SidebarRowMenuItem {
    let title: String
    let symbolName: String
    var isDestructive: Bool = false
    var isSeparatorBefore: Bool = false
    let action: () -> Void
}

/// Transparent AppKit hit-test overlay that claims ONLY right-click & Control-click events
/// to present a native `NSMenu`, passing all left-clicks, hovers, and scroll events untouched to SwiftUI.
struct SidebarRowRightClickOverlay: NSViewRepresentable {
    let items: [SidebarRowMenuItem]

    func makeNSView(context: Context) -> SidebarRightClickNSView {
        let view = SidebarRightClickNSView()
        view.items = items
        return view
    }

    func updateNSView(_ nsView: SidebarRightClickNSView, context: Context) {
        nsView.items = items
    }
}

@MainActor
final class SidebarRightClickNSView: NSView {
    var items: [SidebarRowMenuItem] = []
    private var actionHandlers: [() -> Void] = []

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        let isRightClick = event.type == .rightMouseDown
        let isCtrlClick = event.type == .leftMouseDown && event.modifierFlags.contains(.control)
        guard isRightClick || isCtrlClick else { return nil }
        return super.hitTest(point)
    }

    override func rightMouseDown(with event: NSEvent) {
        popUpMenu(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            popUpMenu(with: event)
            return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        buildMenu()
    }

    private func popUpMenu(with event: NSEvent) {
        let menu = buildMenu()
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        actionHandlers = []

        for spec in items {
            if spec.isSeparatorBefore {
                menu.addItem(.separator())
            }
            let tagIndex = actionHandlers.count
            actionHandlers.append(spec.action)

            let menuItem = NSMenuItem(
                title: spec.title,
                action: #selector(handleMenuItem(_:)),
                keyEquivalent: ""
            )
            menuItem.target = self
            menuItem.tag = tagIndex
            menuItem.isEnabled = true

            if let baseImage = NSImage(systemSymbolName: spec.symbolName, accessibilityDescription: spec.title) {
                if spec.isDestructive {
                    let config = NSImage.SymbolConfiguration(hierarchicalColor: .systemRed)
                    menuItem.image = baseImage.withSymbolConfiguration(config) ?? baseImage
                } else {
                    menuItem.image = baseImage
                }
            }
            if spec.isDestructive {
                menuItem.attributedTitle = NSAttributedString(
                    string: spec.title,
                    attributes: [.foregroundColor: NSColor.systemRed]
                )
            }
            menu.addItem(menuItem)
        }
        return menu
    }

    @objc private func handleMenuItem(_ sender: NSMenuItem) {
        guard actionHandlers.indices.contains(sender.tag) else { return }
        actionHandlers[sender.tag]()
    }
}
