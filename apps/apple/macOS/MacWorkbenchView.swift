import AppKit
import SartoProtocol
import PrismDesign
import SwiftUI
import UniformTypeIdentifiers

/// Authentic Obsidian Prism borderless 2-column Studio Workbench for macOS.
/// - Single-pass 60/120/144Hz GPU Metal backdrop (Volumetric 3-Lobe Nebula + Interactive ASCII Ripple Sea + Conversation Aura)
/// - Full i18n runtime localization (`@Environment(\.prismL10n)`) with instant language switching
/// - Collapsible Diff / Files / Terminal split workbench drawer (`⌘1`/`⌘2`/`⌘3`)
struct MacWorkbenchView: View {
    @Bindable var state: SartoState
    @Bindable var daemon: LocalDaemonManager
    @Bindable var island: PrismDynamicIslandCoordinator
    @Bindable var settingsRouter: PrismSettingsRouter
    @Environment(ProblemReportCoordinator.self) private var problemReport

    fileprivate enum ComposerPopoverKind: Equatable {
        case attach
        case mode
        case model
        case agentSwitcher
        /// The new session's run setup panel, led by the column of the pill that opened it.
        case runSetup(PrismRunSetupColumn)
        case project
        case worktree
        case branch
        case outputSpeed
        case promptCache
        case contextTelemetry
        case hostSwitcher
    }

    @State private var isSidebarCollapsed = false
    @State private var sidebarWidth: CGFloat = 256
    @State private var sidebarSplitterHovered = false
    @State private var sidebarHoverPreview: SidebarHoverPreview? = nil
    @State private var showWorkbenchDrawer = false
    @State private var activeWorkbenchTab: WorkbenchTab = .git
    @State private var workbenchWidth: CGFloat = 430
    @State private var splitterHovered = false
    @State private var renamingSession: SessionSummary? = nil
    @AppStorage("prism.threadWideWidth") private var threadWideWidth: Bool = false
    @AppStorage("sarto.runningRail.enabled") private var runningRailEnabled: Bool = true
    @AppStorage("sarto.runningRail.collapsed") private var runningRailCollapsed: Bool = false
    @State private var pasteKeyMonitor: Any? = nil
    @State private var splitterDragStartWidth: CGFloat? = nil
    @State private var sidebarDragStartWidth: CGFloat? = nil
    /// Composer, thread and find state lives in an observable object so a change re-renders
    /// only the leaf views that read it, never this whole body.
    @State private var ui = WorkbenchUIModel()

    private func popoverBinding(_ kind: ComposerPopoverKind) -> Binding<Bool> {
        let ui = ui
        return Binding(
            get: { ui.activePopover == kind },
            set: { shown in
                if shown {
                    ui.activePopover = kind
                } else if ui.activePopover == kind {
                    ui.activePopover = nil
                }
            }
        )
    }

    private var modelOrAgentPopoverBinding: Binding<Bool> {
        let ui = ui
        return Binding(
            get: { ui.activePopover == .model || ui.activePopover == .agentSwitcher },
            set: { shown in
                if !shown && (ui.activePopover == .model || ui.activePopover == .agentSwitcher) {
                    ui.activePopover = nil
                }
            }
        )
    }

    private var runSetupPopoverBinding: Binding<Bool> {
        let ui = ui
        return Binding(
            get: {
                if case .runSetup = ui.activePopover { return true }
                return false
            },
            set: { shown in
                if !shown, case .runSetup = ui.activePopover {
                    ui.activePopover = nil
                }
            }
        )
    }

    private var runSetupInitialFocus: PrismRunSetupColumn {
        if case .runSetup(let focus) = ui.activePopover { return focus }
        return .model
    }

    private var draftBinding: Binding<String> {
        let state = state
        return Binding(
            get: { state.activeDraftText },
            set: { state.activeDraftText = $0 }
        )
    }

    private func runningRailShowsPlan(for sessionId: String) -> Bool {
        guard runningRailEnabled, !runningRailCollapsed, !showWorkbenchDrawer else { return false }
        return RunningSessionsRail.rows(of: island.model).contains {
            $0.sessionId == sessionId && $0.plan != nil
        }
    }

    var body: some View {
        let tokens = state.tokens
        let l10n = state.l10n

        let effectiveSidebarWidth: CGFloat = isSidebarCollapsed ? 56 : sidebarWidth
        let previewItem = ui.previewImageItem

        // Decouple inner minWidth from the window's NSWindow.minSize so toggling the running rail,
        // workbench drawer, or top-bar pills never forces AppKit to widen and shift the window.
        Color.clear
            .overlay {
                ZStack(alignment: .topLeading) {
                    tokens.background.ignoresSafeArea()

                    HStack(spacing: 0) {
                        MacSidebarView(
                            state: state,
                            isCollapsed: $isSidebarCollapsed,
                            onOpenNewSession: { hostId, projectPath, isScratch, parentId in
                                openNewSessionStage(
                                    hostId: hostId,
                                    projectPath: projectPath,
                                    scratch: isScratch,
                                    parentId: parentId
                                )
                            },
                            onOpenSettings: { settingsRouter.open() },
                            onOpenAccountSettings: {
                                settingsRouter.open(section: .remoteAndCloud, rowID: "remote.sync")
                            },
                            onOpenRemoteSettings: {
                                settingsRouter.open(section: .remoteAndCloud, rowID: "remote.mesh")
                            },
                            onOpenProjectTerminal: { hostId, path in
                                Task {
                                    if hostId != state.activeHostID {
                                        let switched = await state.switchActiveHost(to: hostId)
                                        guard switched else { return }
                                    }
                                    await state.workspace.setProjectPath(path)
                                    withAnimation(PrismSpringSpec.default.animation(tier: state.motionTier)) {
                                        activeWorkbenchTab = .terminal
                                        showWorkbenchDrawer = true
                                    }
                                    await state.workspace.ensureDefaultTerminal()
                                }
                            },
                            onClosePopovers: { closeComposerPopovers() },
                            onHoverPreviewChanged: { preview in
                                withAnimation(.easeOut(duration: 0.14)) {
                                    sidebarHoverPreview = preview
                                }
                            }
                        )
                        .frame(width: effectiveSidebarWidth)
                        .background(tokens.sidebar.ignoresSafeArea())

                        if isSidebarCollapsed {
                            Rectangle()
                                .fill(tokens.borderEtched)
                                .frame(width: 1)
                                .ignoresSafeArea()
                        } else {
                            sidebarSplitter(tokens: tokens)
                        }

                        Color.clear
                            .overlay {
                                mainStage(tokens: tokens, l10n: l10n)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        if showWorkbenchDrawer {
                            workbenchSplitter(tokens: tokens)
                            DrawerLeaf(host: self, activeTab: $activeWorkbenchTab)
                                .frame(width: workbenchWidth)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }

                        RunningRailSlotLeaf(
                            host: self,
                            runningRailEnabled: runningRailEnabled,
                            runningRailCollapsed: $runningRailCollapsed,
                            showWorkbenchDrawer: $showWorkbenchDrawer
                        )
                    }

                    if let preview = sidebarHoverPreview, !isSidebarCollapsed {
                        let cardTop = min(max(46, preview.rowMidY - 46), max(46, ui.rootWindowHeight - 190))
                        SidebarSessionHoverCardView(
                            preview: preview,
                            agentDisplayName: agentDisplayName(for: preview.node.summary.agentId),
                            onLoadOutputs: { sid in await state.fetchSessionOutputs(sessionId: sid, onHost: preview.hostId) }
                        )
                        .padding(.leading, effectiveSidebarWidth + 10)
                        .padding(.top, cardTop)
                        .transition(.opacity.combined(with: .offset(x: -4)))
                        .zIndex(70)
                    }
                }
            }
            .background(ResponderProbe(role: .window, ui: ui))
        .coordinateSpace(name: "workbench-root")
        .onGeometryChange(for: CGFloat.self) { proxy in
            (proxy.size.height / 16.0).rounded() * 16.0
        } action: { _, h in
            if ui.rootWindowHeight != h { ui.rootWindowHeight = h }
        }
        .ignoresSafeArea(.container, edges: .top)
        .environment(\.prismTokens, tokens)
        .environment(\.prismL10n, l10n)
        .environment(\.locale, state.language.resolvedLocale)
        .environment(\.prismMotionTier, state.motionTier)
        .environment(\.prismTypography, PrismTypographyPrefs(
            textSizeDelta: state.textSize.pointDelta,
            proseFontFamily: state.proseFontFamily,
            codeFontFamily: state.codeFontFamily,
            terminalFontSize: state.terminalFontSize,
            terminalFontFamily: state.terminalFontFamily
        ))
        .preferredColorScheme(state.palette.colorScheme)
        .task {
            state.onReconnectLocalDaemon = { [daemon, state] in
                try await daemon.connectOrStartHosts(
                    daemonEntryPath: SartoState.resolveDaemonBundlePath(),
                    relayOrigin: state.relayOrigin
                )
            }
            await state.workspace.refreshGit()
            if !state.relayOrigin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await state.probeRelay()
            }
        }
        .onChange(of: state.selectedSessionID) { _, _ in
            ui.highlightedEntryID = nil
            ui.closeFindBar()
            ui.autocompleteIndex = 0
            ui.dismissedSlashStart = nil
            ui.dismissedMentionStart = nil
            ui.armedBlockedSend = nil
            ui.blockedSendReason = nil
            ui.deletedProjectMentions.removeAll()
            ui.attemptedFilesLoadProject = nil
            ui.editorController.clearPastedLinkToast()
            ui.activityDockExpandedOverride = nil
            ui.exitHistory()
            closeComposerPopovers()
        }
        .onChange(of: state.showStudioHome) { _, _ in
            ui.dismissedSlashStart = nil
            ui.dismissedMentionStart = nil
            ui.armedBlockedSend = nil
            ui.blockedSendReason = nil
            ui.deletedProjectMentions.removeAll()
            ui.attemptedFilesLoadProject = nil
            ui.editorController.clearPastedLinkToast()
            ui.exitHistory()
            closeComposerPopovers()
        }
        .onChange(of: state.hasUploadingAttachments) { _, _ in
            checkArmedBlockedSend()
        }
        .onChange(of: state.activeDraftAttachments.map(\.id)) { _, _ in
            checkArmedBlockedSend()
        }
        .onChange(of: state.pendingTerminalCommand) { _, next in
            guard let req = next else { return }
            state.pendingTerminalCommand = nil
            NSApp.activate(ignoringOtherApps: true)
            if let mainWindow = NSApp.windows.first(where: {
                $0.isVisible && $0.identifier?.rawValue != "settings" && !($0 is NSPanel)
            }) {
                mainWindow.makeKeyAndOrderFront(nil)
            }
            Task {
                withAnimation(PrismSpringSpec.default.animation(tier: state.motionTier)) {
                    activeWorkbenchTab = .terminal
                    showWorkbenchDrawer = true
                }
                await state.workspace.createTerminal(command: req.command, runCommand: req.run)
            }
        }
        .sheet(item: $renamingSession) { target in
            RenameSessionSheetView(
                initialTitle: target.title,
                onSave: { newTitle in
                    renamingSession = nil
                    Task { await state.renameSession(id: target.id, title: newTitle) }
                },
                onCancel: {
                    renamingSession = nil
                }
            )
            .focusEffectDisabled()
            .environment(\.prismTokens, tokens)
            .environment(\.prismL10n, l10n)
            .environment(\.locale, state.language.resolvedLocale)
            .preferredColorScheme(state.palette.colorScheme)
        }
        .sheet(item: Binding(get: { previewItem }, set: { ui.previewImageItem = $0 })) { item in
            PrismImageLightboxView(item: item)
                .focusEffectDisabled()
                .environment(\.prismTokens, tokens)
                .environment(\.prismL10n, l10n)
                .environment(\.locale, state.language.resolvedLocale)
                .preferredColorScheme(state.palette.colorScheme)
        }
        .sheet(item: Binding(get: { ui.previewTextAttachment }, set: { ui.previewTextAttachment = $0 })) { item in
            PrismTextAttachmentSheetView(
                item: item,
                loadText: { await state.readDraftAttachmentText(item) },
                onPasteAsText: { text in
                    ui.editorController.insertPlainText(text)
                    state.removeDraftAttachment(id: item.id)
                    ui.requestComposerFocus()
                }
            )
            .focusEffectDisabled()
            .environment(\.prismTokens, tokens)
            .environment(\.prismL10n, l10n)
            .environment(\.locale, state.language.resolvedLocale)
            .preferredColorScheme(state.palette.colorScheme)
        }
        .sheet(isPresented: $state.showGlobalSearchSheet) {
            GlobalSessionSearchSheet(state: state)
                .focusEffectDisabled()
                .environment(\.prismTokens, tokens)
                .environment(\.prismL10n, l10n)
                .environment(\.locale, state.language.resolvedLocale)
                .preferredColorScheme(state.palette.colorScheme)
        }
        .sheet(isPresented: $state.showImportSessionsSheet) {
            ImportCLISessionsSheet(state: state)
                .focusEffectDisabled()
                .environment(\.prismTokens, tokens)
                .environment(\.prismL10n, l10n)
                .environment(\.locale, state.language.resolvedLocale)
                .preferredColorScheme(state.palette.colorScheme)
        }
        .sheet(item: Bindable(problemReport).mainWindowRequest) { req in
            ProblemReportSheetView(
                request: req,
                state: state,
                daemon: daemon,
                coordinator: problemReport,
                onOpenSignIn: {
                    settingsRouter.open(section: .remoteAndCloud, rowID: "remote.sync")
                }
            )
            .focusEffectDisabled()
            .environment(\.prismTokens, tokens)
            .environment(\.prismL10n, l10n)
            .environment(\.locale, state.language.resolvedLocale)
            .environment(\.prismMotionTier, state.motionTier)
            .preferredColorScheme(state.palette.colorScheme)
        }
        .modifier(AgentAvailabilityPresenter(
            state: state,
            surface: .workbench,
            settings: .direct(state: state, daemon: daemon)
        ))
        .onAppear {
            installClipboardPasteMonitor()
        }
        .onChange(of: island.newSessionRequestToken) { _, _ in
            openNewSessionStage(projectPath: nil, scratch: false, parentId: nil)
        }
        .onChange(of: state.browserAutoOpenRequestToken) { _, _ in
            guard let targetSession = state.browserAutoOpenSessionID else { return }
            if targetSession == state.selectedSessionSummary?.id {
                withAnimation(PrismSpringSpec.default.animation(tier: state.motionTier)) {
                    activeWorkbenchTab = .preview
                    showWorkbenchDrawer = true
                    if workbenchWidth < 460 {
                        workbenchWidth = 520
                    }
                }
                state.browser.markSeen(sessionId: targetSession)
                if state.activePreviewTarget == .ios { state.devices.markPlatformSeen(.ios) }
                if state.activePreviewTarget == .android { state.devices.markPlatformSeen(.android) }
            }
        }
        .onDisappear {
            removeClipboardPasteMonitor()
        }
    }

    // MARK: - 1. Resizable Sidebar Divider

    private func sidebarSplitter(tokens: PrismTokens) -> some View {
        ZStack {
            Rectangle()
                .fill(sidebarSplitterHovered ? tokens.primary.opacity(0.65) : tokens.borderEtched)
                .frame(width: sidebarSplitterHovered ? 2 : 1)
                .ignoresSafeArea()
        }
        .frame(width: 5)
        .contentShape(Rectangle())
        .pointerStyle(.frameResize(position: .leading))
        .onHover { hovering in
            sidebarSplitterHovered = hovering
        }
        .onDisappear {
            // Collapsing while hovered never delivers the hover exit.
            sidebarSplitterHovered = false
        }
        .onTapGesture(count: 2) {
            withAnimation(PrismSpringSpec.snappy.animation(tier: state.motionTier)) {
                sidebarWidth = 256
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let startWidth: CGFloat
                    if let existing = sidebarDragStartWidth {
                        startWidth = existing
                    } else {
                        startWidth = sidebarWidth
                        sidebarDragStartWidth = startWidth
                    }
                    let proposed = startWidth + value.translation.width
                    sidebarWidth = max(200, min(360, proposed))
                }
                .onEnded { _ in
                    sidebarDragStartWidth = nil
                }
        )
    }

    // MARK: - 2. Expansive Open Main Stage (Single-Pass 60/120/144Hz GPU Metal Backdrop)

    private func openThreadProblemReport(payload: ProblemReportEntryPayload, summary: SessionSummary) {
        let isRemote = state.activeHostID != SartoState.localHostID
        let remoteName = isRemote
            ? state.otherHosts.first(where: { $0.id == state.activeHostID })?.name
            : nil
        let titlePart = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let detailsPart = payload.details.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts: [String] = [titlePart, detailsPart].filter { !$0.isEmpty }
        problemReport.open(
            target: .main,
            origin: nil,
            initialDescription: parts.joined(separator: "\n\n"),
            initialRange: "hour",
            sessionId: summary.id,
            agentId: summary.agentId,
            errorText: payload.error,
            threadEntryId: payload.id,
            remoteHostId: isRemote ? state.activeHostID : nil,
            remoteHostName: remoteName
        )
    }

    private func submitThreadProblemReport(payload: ProblemReportEntryPayload, summary: SessionSummary) async throws {
        let hostId = state.activeHostID
        let isRemote = hostId != SartoState.localHostID
        let titlePart = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let detailsPart = payload.details.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = [titlePart, detailsPart].filter { !$0.isEmpty }.joined(separator: "\n\n")

        let result: ReportSubmitResultInfo
        if isRemote {
            let remote = try await state.requestRemoteHostReport(
                description: description,
                rangeKind: "hour",
                extras: [],
                sessionId: summary.id,
                agentId: summary.agentId,
                error: payload.error,
                onHost: hostId
            )
            guard remote.ok, let ref = remote.ref else {
                throw NSError(
                    domain: "ProblemReport",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: remote.reason == "too_large"
                        ? state.l10n.tr("report.error.tooLarge")
                        : "Failed to build problem report on remote host"]
                )
            }
            result = try await state.submitRemoteHostReport(ref: ref, allowAnonymous: true, onHost: hostId)
        } else {
            let client = await ProblemReportCoordinator.collectClientDiagnostics(
                rangeKind: "hour",
                includeCrashReports: false,
                screenshotBase64: nil,
                recentDaemonManagerLogs: daemon.recentLogs
            )
            let built = try await daemon.prepareProblemReport(
                description: description,
                rangeKind: "hour",
                extras: [],
                sessionId: summary.id,
                agentId: summary.agentId,
                error: payload.error,
                client: client
            )
            guard built.ok, let id = built.id else {
                throw NSError(
                    domain: "ProblemReport",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: built.reason == "too_large"
                        ? state.l10n.tr("report.error.tooLarge")
                        : (built.message ?? "Failed to build problem report")]
                )
            }
            do {
                result = try await daemon.submitProblemReport(id: id, allowAnonymous: true)
            } catch {
                try? await daemon.dropProblemReport(id: id)
                throw error
            }
            if !result.ok {
                try? await daemon.dropProblemReport(id: id)
            }
        }

        guard result.ok else {
            let msg: String
            switch result.reason {
            case "too_large":
                msg = state.l10n.tr("report.error.tooLarge")
            case "rate_limited":
                msg = state.l10n.tr("report.error.rateLimited", result.retryAfter ?? 60)
            case "limit_reached":
                msg = state.l10n.tr("report.error.limitReached")
            case "network":
                msg = state.l10n.tr("report.error.network")
            default:
                msg = result.message ?? "Could not submit problem report"
            }
            throw NSError(domain: "ProblemReport", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        problemReport.notifyReportSubmitted()
        await state.answerProblemReport(
            sessionId: summary.id,
            entryId: payload.id,
            outcomeKind: "sent",
            reportId: result.id,
            onHost: hostId
        )
    }

    private func openTurnErrorReport(errorText: String, summary: SessionSummary) {
        let isRemote = state.activeHostID != SartoState.localHostID
        let remoteName = isRemote
            ? state.otherHosts.first(where: { $0.id == state.activeHostID })?.name
            : nil
        problemReport.open(
            target: .main,
            origin: "turn",
            initialDescription: "",
            initialRange: "hour",
            sessionId: summary.id,
            agentId: summary.agentId,
            errorText: errorText,
            remoteHostId: isRemote ? state.activeHostID : nil,
            remoteHostName: remoteName
        )
    }

    private func crashRecoveryBanner(tokens: PrismTokens, l10n: PrismL10n) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tokens.warning)
            Text(l10n.tr("report.crashBanner.title"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tokens.foreground)
            Spacer(minLength: 8)
            Button {
                problemReport.dismissCrashRecoveryBanner()
                problemReport.open(
                    target: .main,
                    origin: "crash",
                    initialRange: "today",
                    initialExtras: ["dumps"]
                )
            } label: {
                Text(l10n.tr("report.crashBanner.action"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(tokens.prismCobalt)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(tokens.prismCobalt.opacity(0.14)))
            }
            .buttonStyle(.plain)
            Button {
                withAnimation(PrismSpringSpec.snappy.animation(tier: state.motionTier)) {
                    problemReport.dismissCrashRecoveryBanner()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tokens.mutedForeground)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(tokens.warning.opacity(0.10))
        .overlay(alignment: .bottom) {
            Rectangle().fill(tokens.warning.opacity(0.25)).frame(height: 1)
        }
    }

    private func mainStage(tokens: PrismTokens, l10n: PrismL10n) -> some View {
        ZStack {
            // Layer 0: Isolated Metal backdrop leaf view so liftoff/aura updates never invalidate MacWorkbenchView.body
            StageBackdropHostView(state: state)
                .ignoresSafeArea()

            // Layer 1: Top bar + Stage content + Floating Glass Composer Dock. Each part is a leaf
            // view reading only its own state, so streaming tokens or typing never re-render this body.
            VStack(spacing: 0) {
                TopBarLeaf(
                    host: self,
                    drawerShown: showWorkbenchDrawer,
                    drawerTab: activeWorkbenchTab,
                    wideThread: threadWideWidth
                )
                .equatable()
                .zIndex(30)

                if problemReport.showCrashRecoveryBanner {
                    crashRecoveryBanner(tokens: tokens, l10n: l10n)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(25)
                }

                ZStack(alignment: .top) {
                    if state.showStudioHome {
                        NewSessionStageView(
                            state: state,
                            island: island,
                            greeting: timeAwareGreeting(l10n: l10n),
                            relayShortLabel: relayShortLabel(l10n: l10n),
                            agentDisplayName: { agentDisplayName(for: $0) },
                            onManageConnection: {
                                if state.connectionMode.isLive {
                                    settingsRouter.open(section: .remoteAndCloud)
                                } else {
                                    connectLocalDaemon()
                                }
                            },
                            onOpenAgentSettings: { settingsRouter.open(section: .agents, rowID: "agents.list") }
                        ) {
                            ComposerDockLeaf(host: self, isNewSessionStage: true, wideThread: threadWideWidth)
                                .equatable()
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.99)))
                    } else {
                        VStack(spacing: 0) {
                            ThreadStageLeaf(
                                host: self,
                                runningRailEnabled: runningRailEnabled,
                                runningRailCollapsed: runningRailCollapsed,
                                drawerShown: showWorkbenchDrawer
                            )
                            .equatable()
                            SessionFooterLeaf(host: self, wideThread: threadWideWidth)
                                .equatable()
                        }
                    }

                    FocusedAttentionNoticeLeaf(state: state)
                        .zIndex(60)
                }
            }
            .onDrop(of: [.fileURL, .image], isTargeted: Bindable(ui).isDropTargeted) { providers in
                handleDrop(providers)
            }
            .zIndex(1)
        }
    }

    // MARK: - Thread Stage (Transcript + Find Bar)

    private func makeCardActions(for summary: SessionSummary) -> ThreadEntryCardActions {
        var actions = ThreadEntryCardActions()
        actions.onAnswerMemory = { entryId, decision in
            Task { await state.answerMemory(sessionId: summary.id, entryId: entryId, decision: decision) }
        }
        actions.onUndoMemory = { entryId in
            Task { await state.undoMemory(sessionId: summary.id, entryId: entryId) }
        }
        actions.onAnswerSettingsChange = { entryId, decision in
            Task { await state.answerSettingsChange(sessionId: summary.id, entryId: entryId, decision: decision) }
        }
        actions.onUndoSettingsChange = { entryId in
            Task { await state.undoSettingsChange(sessionId: summary.id, entryId: entryId) }
        }
        actions.onAnswerBrowserOrigin = { entryId, decision in
            Task { await state.answerBrowserOrigin(sessionId: summary.id, entryId: entryId, decision: decision) }
        }
        actions.onAnswerControlAsk = { entryId, outcome in
            Task { await state.answerControlAsk(sessionId: summary.id, entryId: entryId, outcome: outcome) }
        }
        actions.onAnswerDeviceAccess = { entryId, decision in
            Task { await state.answerDeviceAccess(sessionId: summary.id, entryId: entryId, decision: decision) }
        }
        actions.onAnswerSurfaceAccess = { entryId, decision in
            Task { await state.answerSurfaceAccess(sessionId: summary.id, entryId: entryId, decision: decision) }
        }
        actions.onAnswerComputerApp = { entryId, decision in
            Task { await state.answerComputerApp(sessionId: summary.id, entryId: entryId, decision: decision) }
        }
        actions.onDeclineComputerSetup = { entryId in
            Task { await state.declineComputerSetup(sessionId: summary.id, entryId: entryId) }
        }
        actions.onAnswerProjectMcp = { entryId, decision in
            Task { await state.answerProjectMcp(sessionId: summary.id, entryId: entryId, decision: decision) }
        }
        actions.onAnswerProjectHooks = { entryId, decision in
            Task { await state.answerProjectHooks(sessionId: summary.id, entryId: entryId, decision: decision) }
        }
        actions.isCloudSignedIn = state.cloudAccountStatus.account.isSignedIn
        actions.onAnswerProblemReport = { entryId, outcomeKind in
            Task { await state.answerProblemReport(sessionId: summary.id, entryId: entryId, outcomeKind: outcomeKind) }
        }
        actions.onSubmitProblemReport = { payload in
            try await submitThreadProblemReport(payload: payload, summary: summary)
        }
        actions.onOpenProblemReport = { payload in
            Task { @MainActor in
                openThreadProblemReport(payload: payload, summary: summary)
            }
        }
        actions.onReportTurnError = { errorText in
            Task { @MainActor in
                openTurnErrorReport(errorText: errorText, summary: summary)
            }
        }
        actions.onAnswerMarketPublish = { entryId, decision in
            Task { await state.answerMarketPublish(sessionId: summary.id, entryId: entryId, decision: decision) }
        }
        actions.onRespondElicitation = { reqId, optId, values in
            Task {
                await state.respondPermission(
                    sessionId: summary.id,
                    requestId: reqId,
                    optionId: optId,
                    values: values
                )
            }
        }
        return actions
    }

    @ViewBuilder
    fileprivate func threadStage(tokens: PrismTokens) -> some View {
        if let replica = state.activeReplica, let summary = state.selectedSessionSummary {
            let cardActions = makeCardActions(for: summary)

            ZStack(alignment: .topTrailing) {
                SessionThreadView(
                    replica: replica,
                    onRespondPermission: { reqId, optId, note, answers in
                        Task {
                            await state.respondPermission(
                                sessionId: summary.id,
                                requestId: reqId,
                                optionId: optId,
                                note: note,
                                answers: answers
                            )
                        }
                    },
                    onLoadBlob: { hash in
                        await state.loadSessionBlob(sessionId: summary.id, hash: hash)
                    },
                    isLoadingOlder: state.isLoadingOlderPage,
                    onLoadOlder: {
                        Task { await state.loadOlderPage() }
                    },
                    onRetryTurn: {
                        Task { await state.retryActiveTurn() }
                    },
                    onSendTextReply: { text in
                        Task { await state.sendTextOnlyPrompt(text) }
                    },
                    canForkSession: state.canForkActiveSession,
                    canForkAtMessage: state.canForkActiveAtMessage,
                    onForkTurn: { entryId in
                        Task { await state.forkActiveSession(entryId: entryId) }
                    },
                    onSelectSession: { sid in
                        Task { await state.selectSession(sid) }
                    },
                    resolveSessionSummary: { sid in
                        state.sessionSummary(for: sid)
                    },
                    onOpenFileDiff: { relPath in
                        openWorkbenchDiff(path: relPath)
                    },
                    onOpenProjectFile: { relPath in
                        openWorkbenchFile(path: relPath)
                    },
                    onOpenURLInBrowser: { url in
                        state.browser.openUserTab(sessionId: summary.id, urlString: url.absoluteString)
                        state.activePreviewTarget = .web
                        withAnimation(PrismSpringSpec.default.animation(tier: state.motionTier)) {
                            activeWorkbenchTab = .preview
                            showWorkbenchDrawer = true
                        }
                        state.browser.markSeen(sessionId: summary.id)
                    },
                    onFindInSession: { seed in
                        if let seed, !seed.isEmpty {
                            ui.sessionFindQuery = seed
                        }
                        ui.showSessionFindBar = true
                    },
                    scrollTargetEntryID: ui.scrollTargetEntryID,
                    scrollTargetToken: ui.scrollTargetToken,
                    highlightedEntryID: ui.highlightedEntryID,
                    findQuery: ui.showSessionFindBar ? ui.sessionFindQuery : "",
                    forceScrollToBottomToken: ui.forceScrollToBottomToken,
                    outlineEntries: state.activeOutline,
                    onLoadThroughPos: { pos in
                        await state.loadThrough(pos: pos)
                    },
                    onQuoteReply: { quoted in
                        let prefixed = quoted
                            .split(separator: "\n", omittingEmptySubsequences: false)
                            .map { "> \($0)" }
                            .joined(separator: "\n")
                        let existing = state.activeDraftText.trimmingCharacters(in: .whitespacesAndNewlines)
                        let next = existing.isEmpty
                            ? "\(prefixed)\n\n"
                            : "\(prefixed)\n\n\(existing)"
                        state.activeDraftText = next
                        ui.editorController.setText(next, caretUTF16: (next as NSString).length, recordUndo: true)
                        ui.requestComposerFocus()
                    },
                    onAddPassageComment: { entryId, passage, note in
                        state.addReplyComment(entryId: entryId, passage: passage, comment: note)
                        ui.requestComposerFocus()
                    },
                    onRunCommandInTerminal: { cmd in
                        Task {
                            await state.workspace.setProjectPath(summary.projectPath)
                            withAnimation(PrismSpringSpec.default.animation(tier: state.motionTier)) {
                                activeWorkbenchTab = .terminal
                                showWorkbenchDrawer = true
                            }
                            await state.workspace.ensureDefaultTerminal()
                            await state.workspace.sendTerminalInput(cmd + "\n")
                        }
                    },
                    cardActions: cardActions,
                    isRemoteConnection: state.connectionMode.isRemote,
                    canEditFromMessage: state.canEditActiveFromMessage,
                    canRewindFiles: state.canRewindActiveFiles,
                    onEditFromMessage: { entryId in
                        Task {
                            if await state.editFromMessage(entryId: entryId) {
                                ui.requestComposerFocus()
                            }
                        }
                    },
                    showsPlanHeader: !runningRailShowsPlan(for: summary.id),
                    onLoadToolEntry: { entryId in
                        await state.hydrateToolEntry(sessionId: summary.id, entryId: entryId)
                    }
                )
                .id(replica.session.id)

                if ui.showSessionFindBar {
                    FindBarLeaf(host: self)
                        .equatable()
                        .padding(.top, 10)
                        .padding(.trailing, 18)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 18) {
                Spacer(minLength: 28)
                HStack {
                    Spacer()
                    RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                        .fill(tokens.surface2.opacity(0.65))
                        .frame(width: 240, height: 34)
                }
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(tokens.surface2.opacity(0.55))
                        .frame(maxWidth: 460, minHeight: 14, maxHeight: 14)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(tokens.surface2.opacity(0.45))
                        .frame(maxWidth: 540, minHeight: 14, maxHeight: 14)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(tokens.surface2.opacity(0.35))
                        .frame(maxWidth: 320, minHeight: 14, maxHeight: 14)
                }
                Spacer()
            }
            .frame(maxWidth: 760, maxHeight: .infinity)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Find-in-session matches, rescanned only when the transcript (`seq`) or the query changes.
    fileprivate func currentFindMatches() -> [String] {
        guard ui.showSessionFindBar, let replica = state.activeReplica else { return [] }
        return ui.findMatches(
            replica: replica,
            l10n: state.l10n,
            canForkSession: state.canForkActiveSession,
            canForkAtMessage: state.canForkActiveAtMessage,
            query: ui.sessionFindQuery
        )
    }

    fileprivate func stepFind(forward: Bool) {
        let matches = currentFindMatches()
        guard !matches.isEmpty else { return }
        let step = forward ? 1 : matches.count - 1
        ui.sessionFindIndex = (min(ui.sessionFindIndex, matches.count - 1) + step) % matches.count
        jumpToEntry(matches[ui.sessionFindIndex])
    }

    fileprivate func findQueryDidChange() {
        ui.sessionFindIndex = 0
        if let first = currentFindMatches().first {
            jumpToEntry(first)
        } else {
            ui.highlightedEntryID = nil
        }
    }

    // MARK: - Session Footer (Subagent Bar or Composer)

    @ViewBuilder
    fileprivate func sessionFooter(wideThread: Bool) -> some View {
        if state.isViewingSubagent, let summary = state.selectedSessionSummary {
            SubagentBarView(
                agentName: agentDisplayName(for: summary.agentId),
                parentTitle: state.parentSessionSummary?.title ?? state.parentSessionSummary?.id,
                isRunning: summary.status == .running || summary.status == .awaitingPermission,
                canCancel: state.activeReplica?.session.subagent?.canCancel ?? true,
                onStop: { Task { await state.cancelActiveTurn() } },
                onBackToParent: state.parentSessionSummary.map { parent in
                    { Task { await state.selectSession(parent.id) } }
                }
            )
        } else {
            ComposerDockLeaf(host: self, isNewSessionStage: false, wideThread: wideThread)
                .equatable()
        }
    }

    // MARK: - Minimal Floating Top Bar

    fileprivate func topTitleBar(
        tokens: PrismTokens,
        l10n: PrismL10n,
        drawerShown: Bool,
        drawerTab: WorkbenchTab,
        wideThread: Bool
    ) -> some View {
        // The parent and subagent checks read the summary, not the replica, so tokens streaming
        // into the replica never re-render the bar.
        let selectedSummary = state.showStudioHome ? nil : state.selectedSessionSummary
        let parentSummary = selectedSummary?.parentId.flatMap { state.sessionSummary(for: $0) }
        return HStack(spacing: 7) {
            if state.hasMultipleHosts {
                topBarHostCapsule(tokens: tokens, l10n: l10n)
            }

            if state.showStudioHome {
                Text(l10n.tr("newSession.title"))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tokens.secondaryForeground)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(tokens.surface1.opacity(0.75)))
                    .overlay(Capsule().strokeBorder(tokens.borderEtched, lineWidth: 1))

                let subtitle: String = {
                    if state.effectiveNewSessionIsScratch {
                        return l10n.tr("sidebar.noProject")
                    }
                    if let p = state.effectiveNewSessionProjectPath {
                        return state.projects.first(where: { $0.path == p })?.name
                            ?? (p as NSString).lastPathComponent
                    }
                    return l10n.tr("topbar.workspaceTitle")
                }()

                Text(subtitle)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(tokens.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if let summary = selectedSummary {
                if let parent = parentSummary {
                    Button {
                        Task { await state.selectSession(parent.id) }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 9.5, weight: .semibold))
                            Text(parent.title ?? l10n.tr("sidebar.untitledSession"))
                                .font(.system(size: 11.5, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .foregroundStyle(tokens.prismCobalt)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(tokens.primarySoft))
                    }
                    .buttonStyle(.plain)
                    .prismHoverTooltip(l10n.tr("topbar.parentBackTooltip", parent.title ?? parent.id), alignment: .bottomLeading)
                }

                Text(summary.agentId)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(tokens.mutedForeground)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(tokens.surface1.opacity(0.75)))
                    .overlay(Capsule().strokeBorder(tokens.borderEtched, lineWidth: 1))

                if let modelHost = summary.modelHost, !state.isViewingRemoteHost {
                    topBarRemoteModelPill(modelHost: modelHost, tokens: tokens, l10n: l10n)
                }

                Button {
                    renamingSession = summary
                } label: {
                    Text(summary.title ?? l10n.tr("sidebar.untitledSession"))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(tokens.secondaryForeground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.plain)
                .layoutPriority(1)
                .prismHoverTooltip(l10n.tr("topbar.renameHint"), alignment: .bottomLeading)

                if let branch = summary.branch {
                    Text(branch)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(tokens.placeholder)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(tokens.hoverWash))
                }
            }

            Spacer(minLength: 4)

            if let summary = selectedSummary, summary.origin != "subagent" {
                BoardPillLeaf(host: self)
                    .equatable()
            }

            if selectedSummary != nil {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        if ui.showSessionFindBar {
                            ui.closeFindBar()
                        } else {
                            ui.showSessionFindBar = true
                        }
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ui.showSessionFindBar ? tokens.primary : tokens.mutedForeground)
                        .frame(width: 26, height: 26)
                        .background(Capsule().fill(ui.showSessionFindBar ? tokens.primarySoft : tokens.surface1.opacity(0.55)))
                        .overlay(Capsule().strokeBorder(ui.showSessionFindBar ? tokens.primaryBorder : tokens.borderEtched, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("f", modifiers: .command)
                .prismHoverTooltip(l10n.tr("find.placeholder"))

                Button {
                    threadWideWidth.toggle()
                    state.markUiPrefMutated("threadWideWidth")
                } label: {
                    Image(systemName: wideThread ? "arrow.right.to.line.compact" : "arrow.left.and.right")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(wideThread ? tokens.primary : tokens.mutedForeground)
                        .frame(width: 26, height: 26)
                        .background(Capsule().fill(wideThread ? tokens.primarySoft : tokens.surface1.opacity(0.55)))
                        .overlay(Capsule().strokeBorder(wideThread ? tokens.primaryBorder : tokens.borderEtched, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .prismHoverTooltip(l10n.tr("thread.widthToggle"))

                if let summary = selectedSummary {
                    Button {
                        Task { await state.exportSessionMarkdown(sessionId: summary.id) }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(tokens.mutedForeground)
                            .frame(width: 26, height: 26)
                            .background(Capsule().fill(tokens.surface1.opacity(0.55)))
                            .overlay(Capsule().strokeBorder(tokens.borderEtched, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .prismHoverTooltip(l10n.tr("session.exportMarkdown"))
                }
            }

            // Collapsible Multi-Pane Workbench triggers: Diff / Files / Terminal / Preview (Web · iOS · Android)
            HStack(spacing: 2) {
                workbenchTogglePill(.git, tokens: tokens, l10n: l10n, shortcut: "1", drawerShown: drawerShown, drawerTab: drawerTab)
                workbenchTogglePill(.files, tokens: tokens, l10n: l10n, shortcut: "2", drawerShown: drawerShown, drawerTab: drawerTab)
                workbenchTogglePill(.terminal, tokens: tokens, l10n: l10n, shortcut: "3", drawerShown: drawerShown, drawerTab: drawerTab)
                workbenchTogglePill(.preview, tokens: tokens, l10n: l10n, shortcut: "4", drawerShown: drawerShown, drawerTab: drawerTab)
            }
            .padding(2)
            .background(Capsule().fill(tokens.surface1.opacity(0.55)))
            .overlay(Capsule().strokeBorder(tokens.borderEtched, lineWidth: 1))
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .frame(height: 44)
        .background(tokens.background.opacity(0.62))
        .overlay(alignment: .bottom) {
            Rectangle().fill(tokens.borderEtched).frame(height: 1)
        }
    }

    /// Native Sarto top-bar computer context capsule & switcher popover (shown only when paired with another Mac).
    private func topBarHostCapsule(tokens: PrismTokens, l10n: PrismL10n) -> some View {
        let active = state.activeHostSnapshot
        let isRemote = !active.isLocal
        let isOpen = ui.activePopover == .hostSwitcher
        let dotColor: Color = active.isOnline
            ? (active.isLocal ? tokens.success : tokens.prismCobalt)
            : (active.isConnecting ? tokens.warning : tokens.placeholder)

        return Button {
            ui.activePopover = isOpen ? nil : .hostSwitcher
        } label: {
            HStack(spacing: 5.5) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 5.5, height: 5.5)
                Image(systemName: active.deviceSymbolName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isRemote ? tokens.primary : tokens.mutedForeground)
                Text(active.name)
                    .font(.system(size: 11, weight: isRemote ? .semibold : .medium))
                    .foregroundStyle(isRemote ? tokens.foreground : tokens.secondaryForeground)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7.5, weight: .semibold))
                    .foregroundStyle(tokens.placeholder)
            }
            .padding(.horizontal, 8.5)
            .padding(.vertical, 3.5)
            .fixedSize()
            .background(
                Capsule().fill(
                    isRemote
                        ? tokens.primarySoft
                        : (isOpen ? tokens.activeWash : tokens.surface1.opacity(0.75))
                )
            )
            .overlay(
                Capsule().strokeBorder(
                    isRemote
                        ? tokens.primaryBorder
                        : (isOpen ? tokens.borderStrong : tokens.borderEtched),
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: popoverBinding(.hostSwitcher), arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(l10n.tr("topbar.hostPopoverTitle"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tokens.mutedForeground)
                    Spacer()
                    Text(l10n.tr("sidebar.host.onlineCount", state.onlineHostsCount))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(tokens.placeholder)
                }
                .padding(.horizontal, 6)
                .padding(.top, 2)

                VStack(spacing: 2) {
                    ForEach(state.unifiedHosts) { host in
                        let selected = host.id == state.activeHostID
                        let hostDot: Color = host.isOnline
                            ? (host.isLocal ? tokens.success : tokens.prismCobalt)
                            : (host.isConnecting ? tokens.warning : tokens.placeholder.opacity(0.5))
                        let route: String = {
                            if host.isLocal { return l10n.tr("sidebar.host.thisMac") }
                            if host.isOnline { return host.viaRelay ? l10n.tr("sidebar.host.relay") : l10n.tr("sidebar.host.direct") }
                            if host.isConnecting { return l10n.tr("sidebar.host.connecting") }
                            return l10n.tr("sidebar.host.offline")
                        }()

                        Button {
                            ui.activePopover = nil
                            guard host.id != state.activeHostID else { return }
                            Task { _ = await state.switchActiveHost(to: host.id) }
                        } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(hostDot)
                                    .frame(width: 6, height: 6)
                                Image(systemName: host.deviceSymbolName)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(host.isOnline || host.isLocal ? tokens.secondaryForeground : tokens.placeholder)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(host.name)
                                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                                        .foregroundStyle(host.isOnline || host.isLocal ? tokens.foreground : tokens.placeholder)
                                        .lineLimit(1)
                                     HStack(spacing: 5) {
                                         Text(route)
                                         if host.isOnline && !host.sessions.isEmpty {
                                             Text("· \(host.sessions.count)")
                                         }
                                         if host.isOnline, let load = state.hostLoad(for: host.isLocal ? nil : host.id) {
                                             Text("· CPU \(Int(load.cpu.percent.rounded()))%")
                                             Text("· \(Int(load.memory.usedPercent.rounded()))%")
                                             if let bat = load.battery, bat.onBattery, let pct = bat.percent {
                                                 Text("· \(Int(pct.rounded()))%")
                                             }
                                         }
                                         if !host.isLocal && host.isOnline && !host.allowsTerminal {
                                             Text("· \(l10n.tr("topbar.hostTerminalOff"))")
                                         }
                                     }
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(tokens.placeholder)
                                    .lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                if selected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(tokens.primary)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                                    .fill(selected ? tokens.activeWash : Color.clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!host.isOnline && !host.isLocal)
                    }
                }

                Rectangle().fill(tokens.borderEtched).frame(height: 1)

                Button {
                    ui.activePopover = nil
                    settingsRouter.open(section: .remoteAndCloud, rowID: "remote.mesh")
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 10.5))
                        Text(l10n.tr("sidebar.host.manageDevices"))
                            .font(.system(size: 11.5, weight: .medium))
                        Spacer()
                    }
                    .foregroundStyle(tokens.secondaryForeground)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(8)
            .frame(width: 280)
            .onAppear { state.beginWatchingHostLoads() }
            .onDisappear { state.endWatchingHostLoads() }
            .focusEffectDisabled()
            .presentationBackground(tokens.surface1)
            .environment(\.prismTokens, tokens)
            .environment(\.prismL10n, l10n)
            .environment(\.prismMotionTier, state.motionTier)
            .preferredColorScheme(state.palette.colorScheme)
        }
    }

    /// Minimalist glass capsule anchored at the top-center of the main stage when a background
    /// session needs attention while Sarto is focused. Isolated in its own leaf view so notice
    /// transitions never re-render the surrounding workbench body.
    fileprivate struct FocusedAttentionNoticeLeaf: View {
        let state: SartoState

        @Environment(\.prismTokens) private var tokens
        @Environment(\.prismL10n) private var l10n
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        @State private var isHovered: Bool = false
        @State private var isCloseHovered: Bool = false

        var body: some View {
            let motion = PrismSpringSpec.snappy.animation(tier: state.motionTier, reduceMotion: reduceMotion)
            let transition: AnyTransition = reduceMotion
                ? .opacity
                : .opacity.combined(with: .offset(y: -8)).combined(with: .scale(scale: 0.96))

            Group {
                if let notice = state.focusedAttentionNotice {
                    pill(notice: notice, motion: motion)
                        .padding(.top, 10)
                        .padding(.horizontal, 16)
                        .transition(transition)
                        .onHover { hovered in
                            withAnimation(.easeOut(duration: 0.14)) {
                                isHovered = hovered
                            }
                            state.setFocusedAttentionHovered(hovered)
                        }
                        .onDisappear {
                            isHovered = false
                            isCloseHovered = false
                            state.setFocusedAttentionHovered(false)
                        }
                }
            }
            .animation(motion, value: state.focusedAttentionNotice?.id)
        }

        private func pill(notice: FocusedAttentionNotice, motion: Animation?) -> some View {
            let accent: Color = switch notice.kind {
            case .turnEnded: tokens.success
            case .permission: tokens.warning
            case .error: tokens.danger
            }
            let subtitle: String = switch notice.kind {
            case .turnEnded: l10n.tr("notice.turnEnded")
            case .permission: l10n.tr("notice.needsPermission")
            case .error: l10n.tr("notice.error")
            }

            return HStack(spacing: 8) {
                Button {
                    Task { await state.openFocusedAttentionNotice() }
                } label: {
                    HStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(accent.opacity(tokens.palette.isDark ? 0.24 : 0.16))
                                .frame(width: 13, height: 13)
                            Circle()
                                .fill(accent)
                                .frame(width: 6.5, height: 6.5)
                        }
                        .fixedSize()

                        HStack(spacing: 5) {
                            Text(notice.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(tokens.foreground)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .layoutPriority(1)

                            Text("·")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(tokens.placeholder)
                                .fixedSize()

                            Text(subtitle)
                                .font(.system(size: 11.5))
                                .foregroundStyle(tokens.mutedForeground)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)

                            if notice.extraCount > 0 {
                                Text("+\(notice.extraCount)")
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(tokens.mutedForeground)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(Capsule().fill(tokens.surface2))
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                        }

                        Rectangle()
                            .fill(tokens.borderEtched)
                            .frame(width: 1, height: 12)
                            .padding(.leading, 2)

                        HStack(spacing: 3) {
                            Text(l10n.tr("notice.open"))
                                .font(.system(size: 11.5, weight: .medium))
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9.5, weight: .semibold))
                        }
                        .foregroundStyle(isHovered ? tokens.foreground : tokens.secondaryForeground)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.vertical, 6)
                    .padding(.leading, 10)
                    .padding(.trailing, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(motion) {
                        state.dismissFocusedAttentionNotice()
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(isCloseHovered ? tokens.foreground : tokens.placeholder)
                        .frame(width: 20, height: 20)
                        .background(
                            Circle()
                                .fill(isCloseHovered ? tokens.hoverWash : Color.clear)
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .opacity(isHovered ? 1.0 : 0.55)
                .onHover { hovered in
                    withAnimation(.easeOut(duration: 0.12)) {
                        isCloseHovered = hovered
                    }
                }
                .help(l10n.tr("notice.dismiss"))
                .padding(.trailing, 6)
            }
            .frame(maxWidth: 440)
            .background {
                ZStack {
                    Capsule().fill(.ultraThinMaterial)
                    Capsule().fill(tokens.surface1.opacity(tokens.palette.isDark ? 0.78 : 0.86))
                    if isHovered {
                        Capsule().fill(tokens.hoverWash.opacity(0.45))
                    }
                }
            }
            .overlay(
                Capsule()
                    .strokeBorder(isHovered ? tokens.borderStrong : tokens.borderEtched, lineWidth: 1)
            )
            .shadow(color: tokens.borderStrong.opacity(tokens.palette.isDark ? 0.45 : 0.22), radius: 14, y: 5)
            .shadow(color: tokens.borderStrong.opacity(tokens.palette.isDark ? 0.28 : 0.10), radius: 2, y: 1)
        }
    }

    /// Banner above the composer when a mode switch (such as agy Full access) is waiting to take effect.
    private func pendingModeSwitchStripView(
        pending: PendingConfig,
        targetName: String,
        tokens: PrismTokens,
        l10n: PrismL10n
    ) -> some View {
        let message: String = switch pending.wait {
        case .turn: String(format: l10n.tr("composer.modePending.turn"), targetName)
        case .background: String(format: l10n.tr("composer.modePending.background"), targetName)
        case .restarting: String(format: l10n.tr("composer.modePending.restarting"), targetName)
        }
        return HStack(spacing: 8) {
            if pending.wait == .restarting {
                PrismTurnDotsView(phase: .working, size: 11)
            } else {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tokens.warning)
            }
            Text(message)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(tokens.foreground)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if pending.wait != .restarting {
                Button {
                    Task { await state.cancelPendingModeSwitch() }
                } label: {
                    Text(l10n.tr("composer.modePending.cancel"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(tokens.secondaryForeground)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(tokens.surface2))
                        .overlay(Capsule().strokeBorder(tokens.borderEtched, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                .fill(tokens.warningSoft.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                .strokeBorder(tokens.warning.opacity(0.4), lineWidth: 1)
        )
    }

    /// The running / waiting board pill: the only part of the top bar that reads the replica.
    @ViewBuilder
    fileprivate func boardPill(tokens: PrismTokens, l10n: PrismL10n) -> some View {
        let boardRunning = state.activeBoardRunningCount
        let boardWaiting = state.activeBoardWaitingCount
        if boardRunning > 0 || boardWaiting > 0 {
            Button {
                let liveTotal = boardRunning + boardWaiting
                let defaultExpanded = liveTotal >= 2 || boardWaiting > 0
                let currentlyExpanded = ui.activityDockExpandedOverride ?? defaultExpanded
                withAnimation(PrismSpringSpec.snappy.animation(tier: state.motionTier)) {
                    ui.activityDockExpandedOverride = !currentlyExpanded
                }
            } label: {
                HStack(spacing: 5) {
                    if boardWaiting > 0 {
                        Circle()
                            .fill(tokens.warning)
                            .frame(width: 6, height: 6)
                    } else {
                        PrismTurnDotsView(phase: .working, size: 11)
                    }
                    Text(
                        boardWaiting > 0
                            ? l10n.tr("board.needsCount", boardWaiting)
                            : l10n.tr("board.runningCount", boardRunning)
                    )
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .lineLimit(1)
                }
                .foregroundStyle(boardWaiting > 0 ? tokens.warning : tokens.prismCobalt)
                .padding(.horizontal, 8.5)
                .frame(height: 24)
                .background(Capsule().fill(boardWaiting > 0 ? tokens.warningSoft : tokens.primarySoft))
                .overlay(
                    Capsule().strokeBorder(
                        boardWaiting > 0 ? tokens.warning.opacity(0.5) : tokens.primaryBorder,
                        lineWidth: 1
                    )
                )
                .fixedSize()
            }
            .buttonStyle(.plain)
            .prismHoverTooltip(l10n.tr("topbar.boardTooltip"))
        }
    }

    // MARK: - 3. Two-Tier Floating Glass Composer + Recessed Tray

    fileprivate func floatingComposerDock(
        tokens: PrismTokens,
        l10n: PrismL10n,
        isNewSessionStage: Bool,
        wideThread: Bool
    ) -> some View {
        // The draft is read only by the input, autocomplete, cache notice and send leaves, so typing
        // never re-renders the toolbar, queue or popovers built here.
        let attachments = state.activeDraftAttachments
        let activeToggles = activeBooleanToggleOptions()
        let hasModelOrOptions = state.activeModelConfigOption != nil
            || state.activeThoughtConfigOption != nil
            || !activeToggles.isEmpty
        // On macOS `.popover`, `arrowEdge` is the edge of the popover pointing at the anchor:
        // `.top` opens BELOW the button (ideal for upper-stage New Session), `.bottom` opens ABOVE (ideal for bottom-docked composer).
        let popoverEdge: Edge = isNewSessionStage ? .top : .bottom
        let placeholder = composerPlaceholder(isNewSessionStage: isNewSessionStage, l10n: l10n)
        let composerMaxWidth: CGFloat = (!isNewSessionStage && wideThread) ? 960 : 760
        let minEditorHeight: CGFloat = isNewSessionStage ? 52 : 34

        return VStack(spacing: 8) {
            ComposerAutocompleteLeaf(host: self, isNewSessionStage: isNewSessionStage, maxWidth: composerMaxWidth)
                .equatable()

            ComposerLeadingCommandStripLeaf(host: self, isNewSessionStage: isNewSessionStage, maxWidth: composerMaxWidth)
                .equatable()

            ComposerChipOverlayLeaf(host: self, maxWidth: composerMaxWidth)
                .equatable()

            if !isNewSessionStage {
                ComposerCacheNoticeLeaf(host: self)
                    .equatable()
            }

            if !isNewSessionStage, let targetAgent = state.pendingSwitchAgentID {
                AgentSwitchStripView(
                    targetAgentName: agentDisplayName(for: targetAgent),
                    settingsSummary: state.pendingSwitchSummaryText,
                    summarize: $state.pendingSwitchSummarize,
                    onConfigure: {
                        openModelOrAgentMenu(preferAgentSwitcher: true)
                    },
                    onCancel: {
                        withAnimation(PrismSpringSpec.snappy.animation(tier: state.motionTier)) {
                            state.cancelAgentSwitch()
                        }
                    }
                )
                .frame(maxWidth: 760)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if !isNewSessionStage, let pending = state.activePendingModeSwitch {
                pendingModeSwitchStripView(
                    pending: pending.pending,
                    targetName: pending.targetName,
                    tokens: tokens,
                    l10n: l10n
                )
                .frame(maxWidth: 760)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if !isNewSessionStage && !state.isViewingSubagent
                && (state.activeBoardRunningCount > 0 || state.activeBoardWaitingCount > 0) {
                SessionActivityDockView(
                    subagents: state.activeSubagents,
                    tasks: state.activeBackgroundTasks,
                    expandedOverride: Bindable(ui).activityDockExpandedOverride,
                    onOpenSubagent: { sid in Task { await state.selectSession(sid) } },
                    onJumpToToolEntry: { entryId in jumpToEntry(entryId) },
                    onStopTask: { tid in Task { await state.stopBackgroundTask(taskId: tid) } },
                    onReadTaskOutput: { tid in await state.readBackgroundTaskOutput(taskId: tid) }
                )
                .frame(maxWidth: 760)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if !isNewSessionStage && !state.activeQueue.isEmpty {
                QueueStackView(
                    items: state.activeQueue,
                    isPaused: state.activeQueuePaused,
                    onSendNow: { id in Task { await state.sendQueuedNow(itemId: id) } },
                    onEdit: { item in
                        Task {
                            await state.unqueueItem(item, editInComposer: true)
                            ui.requestComposerFocus()
                        }
                    },
                    onRemove: { item in Task { await state.unqueueItem(item, editInComposer: false) } },
                    onResume: { Task { await state.resumeQueue() } },
                    onOpenSession: { sid in Task { await state.selectSession(sid) } },
                    resolveSessionTitle: { sid in state.sessionSummary(for: sid)?.title }
                )
                .frame(maxWidth: 760)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // Unified Two-Tier Composer Vessel (Upper Glass Input Card + Lower Recessed Tray)
            VStack(spacing: 0) {
                // Top-edge resize grip: drag to adjust composer height, double-click to reset auto-grow.
                ComposerResizeGripLeaf(host: self, minHeight: minEditorHeight)
                    .equatable()
                    .padding(.top, 2)

                // Upper Tier: Main Input Card
                VStack(alignment: .leading, spacing: 8) {
                    if let hIdx = ui.historyIndex {
                        let total = max(ui.historyTotalCount, hIdx + 1)
                        ComposerHistoryHeaderView(
                            index: min(hIdx + 1, total),
                            count: total,
                            onRestoreDraft: { restoreHistoryDraft() }
                        )
                    } else if !isNewSessionStage, let rewound = state.activeRewound {
                        ComposerRewoundHeaderView(
                            turns: rewound.turns,
                            isBusy: state.selectedSessionSummary.map { state.rewindBusySessionIDs.contains($0.id) } ?? false,
                            onPutBack: {
                                Task {
                                    await state.putBackRewound()
                                    ui.requestComposerFocus()
                                }
                            }
                        )
                    }

                    if !isNewSessionStage && !state.activeDraftComments.isEmpty {
                        ComposerReplyCommentsListView(
                            comments: state.activeDraftComments,
                            onRevealEntry: { eid in jumpToEntry(eid) },
                            onEdit: { id, note in state.editReplyComment(id: id, comment: note) },
                            onRemove: { id in state.removeReplyComment(id: id) },
                            onRemoveAll: { state.clearReplyComments() }
                        )
                    }

                    if !attachments.isEmpty {
                        ComposerAttachmentTrayView(
                            items: attachments,
                            hiddenIDs: ui.editorController.mentionedAttachmentIDs,
                            onRemove: { id in state.removeDraftAttachment(id: id) },
                            onPreviewImage: { title, data in
                                ui.previewImageItem = PrismImagePreviewItem(title: title, data: data)
                            },
                            onOpenText: { item in
                                ui.previewTextAttachment = item
                            }
                        )
                    }

                    ComposerInputLeaf(
                        host: self,
                        isNewSessionStage: isNewSessionStage,
                        placeholder: placeholder,
                        compactTop: attachments.isEmpty,
                        minHeight: minEditorHeight
                    )
                    .equatable()

                    // Contextual inline status strip
                    if ui.isDropTargeted {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.doc.fill")
                                .font(.system(size: 11))
                            Text(l10n.tr("composer.attachmentsDropHint"))
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(tokens.prismCobalt)
                        .padding(.horizontal, 8)
                    } else if ui.armedBlockedSend != nil {
                        HStack(spacing: 6) {
                            PrismTurnDotsView(phase: .thinking, size: 11)
                            Text(l10n.tr("composer.blocked.armedSending"))
                                .font(.system(size: 11, design: .monospaced))
                        }
                        .foregroundStyle(tokens.prismCobalt)
                        .padding(.horizontal, 8)
                    } else if let refused = ui.blockedSendReason {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10.5))
                            Text(refused)
                                .font(.system(size: 11))
                                .lineLimit(2)
                        }
                        .foregroundStyle(tokens.danger)
                        .padding(.horizontal, 8)
                    } else if let err = state.activeSessionError {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10.5))
                            Text(err)
                                .font(.system(size: 11))
                                .lineLimit(2)
                        }
                        .foregroundStyle(tokens.danger)
                        .padding(.horizontal, 8)
                    } else if state.hasUploadingAttachments {
                        HStack(spacing: 6) {
                            PrismTurnDotsView(phase: .thinking, size: 11)
                            Text(l10n.tr("composer.attachmentsUploading"))
                                .font(.system(size: 11, design: .monospaced))
                        }
                        .foregroundStyle(tokens.prismCobalt)
                        .padding(.horizontal, 8)
                    } else if !isNewSessionStage && state.activeReplica?.session.status == .starting {
                        HStack(spacing: 6) {
                            PrismTurnDotsView(phase: .thinking, size: 11)
                            Text(l10n.tr("composer.startingAgent", agentDisplayName(for: state.selectedSessionSummary?.agentId ?? state.selectedAgentID)))
                                .font(.system(size: 11, design: .monospaced))
                        }
                        .foregroundStyle(tokens.prismCobalt)
                        .padding(.horizontal, 8)
                    } else if !isNewSessionStage && state.activeHeldOutside {
                        HStack(spacing: 6) {
                            Image(systemName: "terminal")
                                .font(.system(size: 10.5))
                            Text(l10n.tr("composer.heldOutside"))
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(tokens.warning)
                        .padding(.horizontal, 8)
                    } else if !isNewSessionStage,
                              let modelHost = state.activeModelHostRef,
                              state.isModelHostOffline(modelHost) {
                        composerRemoteModelOfflineBanner(modelHost: modelHost, tokens: tokens, l10n: l10n)
                    }

                    ComposerPlanLimitLeaf(host: self, isNewSessionStage: isNewSessionStage)
                        .equatable()

                    // Main Toolbar Row: [+] [Permission Mode] [Model / Effort / Flags] [Extra Selects] ... [Send / Stop / Steer]
                    HStack(spacing: 6.5) {
                        // 1. Plus / Add Menu Button
                        Button {
                            ui.activePopover = (ui.activePopover == .attach) ? nil : .attach
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(ui.activePopover == .attach ? tokens.foreground : tokens.secondaryForeground)
                                .rotationEffect(.degrees(ui.activePopover == .attach ? 45 : 0))
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(ui.activePopover == .attach ? tokens.activeWash : tokens.surface2.opacity(0.55)))
                                .overlay(Circle().strokeBorder(ui.activePopover == .attach ? tokens.borderStrong : tokens.borderEtched, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help(l10n.tr("composer.addAttachmentTooltip"))
                        .popover(isPresented: popoverBinding(.attach), arrowEdge: popoverEdge) {
                            attachMenuPopover(tokens: tokens, l10n: l10n)
                                .focusEffectDisabled()
                                .presentationBackground(tokens.surface1)
                                .environment(\.prismTokens, tokens)
                                .environment(\.prismL10n, l10n)
                                .environment(\.prismMotionTier, state.motionTier)
                                .preferredColorScheme(state.palette.colorScheme)
                        }

                        // Hidden Cmd+U shortcut to open file/image picker immediately
                        Button("") {
                            closeComposerPopovers()
                            presentAttachmentPanel(imagesOnly: false)
                        }
                        .keyboardShortcut("u", modifiers: .command)
                        .frame(width: 0, height: 0)
                        .opacity(0)
                        .allowsHitTesting(false)

                        // 2. Standalone Sarto Permission Mode Pill (Shift+Tab cycles)
                        if !state.activeModeChoices.isEmpty, let modeLabel = state.activeModeDisplayName {
                            let isFull = state.activeModeLook == .full
                            let modeKind: ComposerPopoverKind = isNewSessionStage ? .runSetup(.run) : .mode
                            let modeOpen = ui.activePopover == modeKind
                            Button {
                                if modeOpen {
                                    ui.activePopover = nil
                                } else {
                                    ui.activePopover = modeKind
                                    if isNewSessionStage { Task { await state.refreshActiveModels() } }
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: state.activeModeLook.systemImage)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(isFull ? tokens.danger : tokens.secondaryForeground)
                                    Text(modeLabel)
                                        .font(.system(size: 11.5, weight: isFull ? .semibold : .medium))
                                        .foregroundStyle(isFull ? tokens.danger : (modeOpen ? tokens.foreground : tokens.secondaryForeground))
                                        .lineLimit(1)
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 8.5, weight: .semibold))
                                        .foregroundStyle(isFull ? tokens.danger.opacity(0.75) : tokens.placeholder)
                                }
                                .padding(.horizontal, 9)
                                .frame(height: 28)
                                .background(
                                    Capsule().fill(
                                        isFull
                                            ? tokens.dangerSoft
                                            : (modeOpen ? tokens.activeWash : tokens.surface2.opacity(0.55))
                                    )
                                )
                                .overlay(
                                    Capsule().strokeBorder(
                                        isFull
                                            ? tokens.danger.opacity(0.52)
                                            : (modeOpen ? tokens.borderStrong : tokens.borderEtched),
                                        lineWidth: 1
                                    )
                                )
                            }
                            .buttonStyle(.plain)
                            .help("\(l10n.tr("popover.permissionMode")) · \(l10n.tr("composer.modeCyclesHint"))")
                            .overlay(alignment: .leading) {
                                if !isNewSessionStage {
                                    Color.clear
                                        .frame(width: 44, height: 28)
                                        .allowsHitTesting(false)
                                        .popover(isPresented: popoverBinding(.mode), arrowEdge: popoverEdge) {
                                            PermissionModePopoverView(
                                                modes: state.activeModeChoices,
                                                selectedModeID: state.activeModeValue,
                                                onSelect: { modeId in
                                                    ui.activePopover = nil
                                                    Task { await state.applyModeChoice(modeId) }
                                                    ui.requestComposerFocus()
                                                }
                                            )
                                            .focusEffectDisabled()
                                            .presentationBackground(tokens.surface1)
                                            .environment(\.prismTokens, tokens)
                                            .environment(\.prismL10n, l10n)
                                            .environment(\.prismMotionTier, state.motionTier)
                                            .preferredColorScheme(state.palette.colorScheme)
                                        }
                                }
                            }
                        }

                        // 3. Agent › Model / Effort / Boolean Flags / Switch Agent Pill
                        Group {
                            let pendingId = isNewSessionStage ? nil : state.pendingSwitchAgentID
                            let dotColor = pendingId.map { brandColor(for: $0, tokens: tokens) } ?? activeBrandColor(tokens: tokens)
                            let menuOpen = ui.activePopover == .model
                                || ui.activePopover == .agentSwitcher
                                || ui.activePopover == .runSetup(.model)
                            let fastOn = activeToggles.contains(where: { $0.isFast && $0.isOn })
                            let activeIndicators = activeToggles.filter { !$0.isFast && $0.indicator && $0.isOn }

                            Button {
                                if menuOpen {
                                    ui.activePopover = nil
                                } else if isNewSessionStage {
                                    ui.activePopover = .runSetup(.model)
                                    Task { await state.refreshActiveModels() }
                                } else {
                                    openModelOrAgentMenu(preferAgentSwitcher: pendingId != nil || !hasModelOrOptions)
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(dotColor)
                                        .frame(width: 7, height: 7)
                                        .shadow(color: dotColor.opacity(0.65), radius: 3.5)

                                    if let pendingId {
                                        Text("→ \(agentDisplayName(for: pendingId))")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(tokens.foreground)
                                            .lineLimit(1)

                                        if let summaryModel = state.activeModelConfigOption?.value.stringValue,
                                           let label = state.activeModelConfigOption?.choices?.first(where: { $0.value == summaryModel })?.name {
                                            Text(label)
                                                .font(.system(size: 10.5, weight: .medium))
                                                .foregroundStyle(tokens.secondaryForeground)
                                                .lineLimit(1)
                                        }

                                        Text(l10n.tr("composer.switchNextBadge"))
                                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(tokens.prismIris)
                                            .padding(.horizontal, 5.5)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(tokens.prismIris.opacity(0.16)))
                                    } else {
                                        if isNewSessionStage && hasModelOrOptions {
                                            Text(agentDisplayName(for: state.selectedAgentID))
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundStyle(tokens.mutedForeground)
                                                .lineLimit(1)
                                                .layoutPriority(-1)
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 8, weight: .semibold))
                                                .foregroundStyle(tokens.placeholder)
                                        }
                                        Text(state.activeModelDisplayName)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(menuOpen ? tokens.foreground : tokens.secondaryForeground)
                                            .lineLimit(1)

                                        if let modelHost = state.activeModelHostRef {
                                            composerRemoteModelBadge(modelHost: modelHost, tokens: tokens)
                                        }

                                        if let effortLabel = state.activeEffortDisplayLabel {
                                            let effortAnim: Animation? = state.motionTier == .off
                                                ? nil
                                                : .spring(response: 0.26, dampingFraction: 0.84)
                                            let allEffortLabels = state.activeEffortResolved?.levels.map(\.label) ?? [effortLabel]
                                            ZStack {
                                                // Hidden sizing phantoms lock the badge width to the widest effort
                                                // label of the active model so the composer pill never jumps.
                                                ForEach(allEffortLabels, id: \.self) { label in
                                                    Text(label)
                                                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                                        .lineLimit(1)
                                                        .opacity(0)
                                                        .accessibilityHidden(true)
                                                }
                                                Text(effortLabel)
                                                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                                    .foregroundStyle(effortTagColor(tokens: tokens))
                                                    .lineLimit(1)
                                                    .id(effortLabel)
                                                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                                            }
                                            .padding(.horizontal, 5.5)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(effortTagBg(tokens: tokens)))
                                            .animation(effortAnim, value: effortLabel)
                                        }

                                        if fastOn {
                                            Image(systemName: "bolt.fill")
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundStyle(tokens.warning)
                                        }

                                        ForEach(activeIndicators) { flag in
                                            Text("· \(flag.name)")
                                                .font(.system(size: 10.5, weight: .medium))
                                                .foregroundStyle(tokens.prismIris)
                                                .lineLimit(1)
                                        }
                                    }

                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 8.5, weight: .semibold))
                                        .foregroundStyle(tokens.placeholder)
                                }
                                .padding(.leading, 9)
                                .padding(.trailing, 9.5)
                                .frame(height: 28)
                                .background(
                                    Capsule().fill(
                                        pendingId != nil
                                            ? tokens.prismIris.opacity(0.10)
                                            : (menuOpen ? tokens.activeWash : tokens.surface2.opacity(0.55))
                                    )
                                )
                                .overlay(
                                    Capsule().strokeBorder(
                                        pendingId != nil
                                            ? tokens.prismIris.opacity(0.55)
                                            : (menuOpen ? tokens.borderStrong : tokens.borderEtched),
                                        lineWidth: 1
                                    )
                                )
                            }
                            .buttonStyle(.plain)
                            .help(isNewSessionStage ? l10n.tr("runSetup.pillHelp") : "")
                        }

                        // 4. Extra dynamic select options if any
                        ForEach(state.activeOtherSelectConfigOptions) { extraOpt in
                            if let choices = extraOpt.choices, !choices.isEmpty {
                                let currentVal = extraOpt.value.stringValue ?? ""
                                let currentLabel = choices.first(where: { $0.value == currentVal })?.name ?? extraOpt.name
                                Menu {
                                    ForEach(choices) { choice in
                                        Button {
                                            Task { await state.setActiveConfigOption(optionId: extraOpt.id, value: .string(choice.value)) }
                                        } label: {
                                            if choice.value == currentVal {
                                                Label(choice.name, systemImage: "checkmark")
                                            } else {
                                                Text(choice.name)
                                            }
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(currentLabel)
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(tokens.secondaryForeground)
                                            .lineLimit(1)
                                        Image(systemName: "chevron.down")
                                            .font(.system(size: 8, weight: .semibold))
                                            .foregroundStyle(tokens.placeholder)
                                    }
                                    .padding(.horizontal, 8)
                                    .frame(height: 28)
                                    .background(Capsule().fill(tokens.surface2.opacity(0.5)))
                                    .overlay(Capsule().strokeBorder(tokens.borderEtched, lineWidth: 1))
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                            }
                        }

                        Spacer(minLength: 8)

                        // 5. Send / Stop / Queue + Steer control
                        ComposerSendLeaf(host: self, isNewSessionStage: isNewSessionStage)
                            .equatable()
                    }
                    .overlay(alignment: .leading) {
                        // Fixed-coordinate anchor on the toolbar row itself: keeps the RunSetup /
                        // Model / AgentSwitcher popover rock-solid horizontally even when the
                        // permission mode pill, agent name, model name, or effort badge changes width.
                        Color.clear
                            .frame(width: 44, height: 28)
                            .padding(.leading, 144)
                            .allowsHitTesting(false)
                            .popover(
                                isPresented: isNewSessionStage ? runSetupPopoverBinding : modelOrAgentPopoverBinding,
                                arrowEdge: popoverEdge
                            ) {
                                Group {
                                    if isNewSessionStage {
                                        runSetupPanelContent(tokens: tokens, l10n: l10n, focus: runSetupInitialFocus)
                                    } else if ui.activePopover == .agentSwitcher {
                                        agentSwitcherPopoverContent(
                                            tokens: tokens,
                                            l10n: l10n,
                                            isNewSessionMode: isNewSessionStage,
                                            showBackButton: !isNewSessionStage && hasModelOrOptions && state.pendingSwitchAgentID == nil
                                        )
                                    } else {
                                        let resolvedEffort = state.activeEffortResolved
                                        ModelEffortPopoverView(
                                            headerTitle: agentDisplayName(for: state.activeConfigAgentID),
                                            models: availableModelOptions(tokens: tokens),
                                            selectedModelID: Binding(
                                                get: { state.activeModelSelectionID },
                                                set: { next in Task { await state.selectModelOrAgent(next) } }
                                            ),
                                            modes: [],
                                            effortTitle: resolvedEffort?.title,
                                            effortLevels: resolvedEffort?.levels ?? [],
                                            selectedEffortID: resolvedEffort?.selectedID,
                                            onSelectEffort: { nextVal in
                                                Task { await state.selectEffortValue(nextVal) }
                                            },
                                            toggles: activeToggles,
                                            onToggleOption: { optId, nextOn in
                                                Task { await state.toggleBooleanOption(optId, on: nextOn) }
                                            },
                                            accountNote: accountFooterNote(for: state.activeConfigAgentID, l10n: l10n),
                                            cacheNote: isNewSessionStage ? nil : state.warmCacheChangeNote(),
                                            canSwitchAgent: !state.isTurnBusy,
                                            switchAgentDisabledHint: l10n.tr("composer.switchAgentBetweenTurns"),
                                            useSystemPopoverChrome: true,
                                            onOpenAgentSwitcher: isNewSessionStage ? nil : {
                                                ui.activePopover = .agentSwitcher
                                            },
                                            onModelPicked: {
                                                ui.activePopover = nil
                                                ui.requestComposerFocus()
                                            },
                                            onTogglePin: modelPinAction(forAgent: state.activeConfigAgentID)
                                        )
                                    }
                                }
                                .focusEffectDisabled()
                                .presentationBackground(tokens.surface1)
                                .environment(\.prismTokens, tokens)
                                .environment(\.prismL10n, l10n)
                                .environment(\.prismMotionTier, state.motionTier)
                                .preferredColorScheme(state.palette.colorScheme)
                            }
                    }
                    .animation(
                        state.motionTier == .off ? nil : .spring(response: 0.26, dampingFraction: 0.86),
                        value: state.activeModeDisplayName
                    )
                    .padding(.horizontal, 4)
                    .padding(.bottom, 2)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)

                // Hairline divider between Main Card & Bottom Tray
                Rectangle()
                    .fill(tokens.borderEtched.opacity(0.85))
                    .frame(height: 1)

                // Lower Tier: Sleek Recessed Tray Bar
                composerBottomTray(tokens: tokens, l10n: l10n, isNewSessionStage: isNewSessionStage)
            }
            .clipShape(RoundedRectangle(cornerRadius: tokens.rLG, style: .continuous))
            .prismSurface(elevation: .floating, cornerRadius: tokens.rLG)
            .prismInputRim(
                cornerRadius: tokens.rLG,
                isFocused: ui.composerFocused || ui.isDropTargeted,
                isStreaming: !isNewSessionStage && state.activeIsStreaming
            )
            .frame(maxWidth: (!isNewSessionStage && wideThread) ? 960 : 760)
        }
        .padding(.horizontal, isNewSessionStage ? 0 : 24)
        .padding(.top, isNewSessionStage ? 0 : 10)
        .padding(.bottom, isNewSessionStage ? 0 : 16)
    }

    // MARK: - 3b. Composer Bottom Tray (New Session Pickers / In-Session Place + Branch + Telemetry)

    private func composerBottomTray(
        tokens: PrismTokens,
        l10n: PrismL10n,
        isNewSessionStage: Bool
    ) -> some View {
        HStack(spacing: 8) {
            if isNewSessionStage {
                // 1. Project chip (or locked Parent Project chip for sub-session)
                if let parent = state.resolvedNewSessionParent {
                    let isScratch = parent.scratch == true
                    let label = isScratch
                        ? l10n.tr("sidebar.noProject")
                        : (state.projects.first(where: { $0.path == parent.projectPath })?.name ?? (parent.projectPath as NSString).lastPathComponent)
                    HStack(spacing: 5) {
                        Image(systemName: isScratch ? "square.dashed" : "folder")
                            .font(.system(size: 11, weight: .medium))
                        Text(label)
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(tokens.mutedForeground)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .help(l10n.tr("newSession.subSessionProjectLocked"))
                } else {
                    let isScratch = state.effectiveNewSessionIsScratch
                    let chosenPath = state.effectiveNewSessionProjectPath
                    let chosenProj = chosenPath.flatMap { p in state.projects.first(where: { $0.path == p }) }
                    let label: String = {
                        if isScratch { return l10n.tr("sidebar.noProject") }
                        if let chosenProj { return chosenProj.name }
                        if let chosenPath { return (chosenPath as NSString).lastPathComponent }
                        return l10n.tr("newSession.chooseProject")
                    }()
                    Button {
                        ui.activePopover = (ui.activePopover == .project) ? nil : .project
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: isScratch ? "square.dashed" : (chosenProj?.isMissing == true ? "folder.badge.questionmark" : "folder"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(chosenProj?.isMissing == true ? tokens.danger : tokens.secondaryForeground)
                            Text(label)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(chosenProj?.isMissing == true ? tokens.danger : tokens.foreground)
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(tokens.placeholder)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                                .fill(ui.activePopover == .project ? tokens.activeWash : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: popoverBinding(.project), arrowEdge: .top) {
                        ProjectPickerPopoverView(
                            projects: state.projects,
                            selectedPath: state.effectiveNewSessionProjectPath,
                            isScratch: state.effectiveNewSessionIsScratch,
                            onSelectProject: { path in
                                ui.activePopover = nil
                                state.setNewSessionProject(path: path, scratch: false)
                                ui.requestComposerFocus()
                            },
                            onSelectNoProject: {
                                ui.activePopover = nil
                                state.setNewSessionProject(path: nil, scratch: true)
                                ui.requestComposerFocus()
                            },
                            onOpenFolderPicker: {
                                ui.activePopover = nil
                                presentAddProjectFolderPanel()
                            }
                        )
                        .focusEffectDisabled()
                        .presentationBackground(tokens.surface1)
                        .environment(\.prismTokens, tokens)
                        .environment(\.prismL10n, l10n)
                        .environment(\.prismMotionTier, state.motionTier)
                        .preferredColorScheme(state.palette.colorScheme)
                    }
                }

                // 2. Worktree / Local Folder chip (for git repos)
                if !state.effectiveNewSessionIsScratch,
                   state.newSessionParentID == nil,
                   let projectPath = state.effectiveNewSessionProjectPath,
                   let gitStatus = state.activeTrayGitStatus,
                   gitStatus.repo != nil {
                    let wtDraft = state.worktreeDraft(for: projectPath)
                    let currentBranch = gitStatus.head.branch ?? gitStatus.head.oid.map { String($0.prefix(7)) } ?? (gitStatus.defaultBranch ?? "main")
                    let displayBase = wtDraft.mode == .worktree ? (wtDraft.baseBranch ?? currentBranch) : currentBranch
                    let label = wtDraft.mode == .worktree
                        ? l10n.tr("worktree.newTrigger", displayBase)
                        : l10n.tr("worktree.localTrigger", currentBranch)

                    Button {
                        if ui.activePopover == .worktree {
                            ui.activePopover = nil
                        } else {
                            ui.activePopover = .worktree
                            Task { await state.loadBranches(for: projectPath) }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: wtDraft.mode == .worktree ? "arrow.triangle.branch" : "arrow.triangle.merge")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(wtDraft.mode == .worktree ? tokens.prismCobalt : tokens.mutedForeground)
                            Text(label)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(wtDraft.mode == .worktree ? tokens.prismCobalt : tokens.secondaryForeground)
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(tokens.placeholder)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                                .fill(
                                    ui.activePopover == .worktree
                                        ? tokens.activeWash
                                        : (wtDraft.mode == .worktree ? tokens.primarySoft.opacity(0.6) : Color.clear)
                                )
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: popoverBinding(.worktree), arrowEdge: .top) {
                        WorktreePickerPopoverView(
                            projectPath: projectPath,
                            gitStatus: gitStatus,
                            branches: state.gitBranchesByProject[projectPath],
                            isLoadingBranches: state.isLoadingBranches,
                            draft: wtDraft,
                            onUpdateMode: { mode in
                                state.updateWorktreeDraft(for: projectPath) { $0.mode = mode }
                            },
                            onUpdateBase: { base in
                                state.updateWorktreeDraft(for: projectPath) { $0.baseBranch = base }
                            },
                            onUpdateBranchName: { name in
                                state.updateWorktreeDraft(for: projectPath) { $0.customBranch = name }
                            },
                            onLoadBranches: {
                                Task { await state.loadBranches(for: projectPath) }
                            }
                        )
                        .focusEffectDisabled()
                        .presentationBackground(tokens.surface1)
                        .environment(\.prismTokens, tokens)
                        .environment(\.prismL10n, l10n)
                        .environment(\.prismMotionTier, state.motionTier)
                        .preferredColorScheme(state.palette.colorScheme)
                    }
                }

                Spacer(minLength: 8)

                // Prepared warm-up status indicator on New Session tray
                if state.isPreparingSession {
                    HStack(spacing: 5) {
                        PrismTurnDotsView(phase: .thinking, size: 9.5)
                        Text(l10n.tr("newSession.preparing"))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(tokens.placeholder)
                    }
                } else if state.preparedSession?.agentId == state.selectedAgentID {
                    HStack(spacing: 4.5) {
                        Circle()
                            .fill(tokens.success)
                            .frame(width: 5.5, height: 5.5)
                        Text(l10n.tr("newSession.preparedReady"))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(tokens.mutedForeground)
                    }
                }
            } else {
                // In-Session Tray Left: Session Place + Clickable Git Branch Switcher
                if let summary = state.selectedSessionSummary {
                    let isScratch = summary.scratch == true
                    let isWorktree = summary.worktree != nil
                    let projectLabel: String = {
                        if isScratch { return l10n.tr("sidebar.noProject") }
                        if let p = state.projects.first(where: { $0.path == summary.projectPath }) {
                            return p.name
                        }
                        return (summary.projectPath as NSString).lastPathComponent
                    }()

                    HStack(spacing: 5) {
                        Image(systemName: isWorktree ? "arrow.triangle.branch" : (isScratch ? "square.dashed" : "folder"))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(isWorktree ? tokens.prismCobalt : tokens.mutedForeground)
                        Text(projectLabel)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(tokens.secondaryForeground)
                            .lineLimit(1)
                    }
                    .help(summary.worktree?.path ?? summary.projectPath)

                    if let branch = state.activeTrayBranchName, !branch.isEmpty {
                        let branchProjectPath = summary.worktree?.path ?? (isScratch ? nil : summary.projectPath)
                        if let branchProjectPath {
                            Button {
                                if ui.activePopover == .branch {
                                    ui.activePopover = nil
                                } else {
                                    ui.branchSwitchError = nil
                                    ui.activePopover = .branch
                                    Task { await state.loadBranches(for: branchProjectPath) }
                                    if state.workspace.activeProjectPath == branchProjectPath {
                                        Task { await state.workspace.refreshGit() }
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.triangle.branch")
                                        .font(.system(size: 10, weight: .medium))
                                    Text(branch)
                                        .font(.system(size: 11, design: .monospaced))
                                        .lineLimit(1)
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 8, weight: .semibold))
                                        .foregroundStyle(tokens.placeholder)
                                }
                                .foregroundStyle(ui.activePopover == .branch ? tokens.foreground : tokens.mutedForeground)
                                .padding(.horizontal, 6.5)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                                        .fill(ui.activePopover == .branch ? tokens.activeWash : Color.clear)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: popoverBinding(.branch), arrowEdge: .bottom) {
                                GitBranchPopoverView(
                                    currentBranch: branch,
                                    branches: state.gitBranchesByProject[branchProjectPath],
                                    isLoading: state.isLoadingBranches,
                                    errorText: ui.branchSwitchError,
                                    onSwitchBranch: { target, create in
                                        Task {
                                            let err = await state.switchGitBranch(
                                                projectPath: branchProjectPath,
                                                branch: target,
                                                create: create
                                            )
                                            ui.branchSwitchError = err
                                            if err == nil {
                                                ui.activePopover = nil
                                            }
                                        }
                                    },
                                    workspace: state.workspace.activeProjectPath == branchProjectPath ? state.workspace : nil,
                                    onOpenGitPane: { openGitPane() }
                                )
                                .focusEffectDisabled()
                                .presentationBackground(tokens.surface1)
                                .environment(\.prismTokens, tokens)
                                .environment(\.prismL10n, l10n)
                                .environment(\.prismMotionTier, state.motionTier)
                                .preferredColorScheme(state.palette.colorScheme)
                            }
                        }
                    }
                }

                Spacer(minLength: 8)

                // In-Session Tray Right: Isolated leaf view so 60Hz TPS/telemetry ticks never invalidate MacWorkbenchView
                InSessionTelemetryTrayView(
                    state: state,
                    speedExpanded: popoverBinding(.outputSpeed),
                    cacheExpanded: popoverBinding(.promptCache),
                    contextExpanded: popoverBinding(.contextTelemetry)
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: 34)
        .background(tokens.surface1.opacity(tokens.palette.isDark ? 0.52 : 0.68))
    }

    private func attachMenuPopover(tokens: PrismTokens, l10n: PrismL10n) -> some View {
        let canPaste = clipboardHasAttachableContent()
        return VStack(alignment: .leading, spacing: 3) {
            attachMenuRow(
                icon: "photo.on.rectangle.angled",
                title: l10n.tr("composer.attachImages"),
                shortcut: nil,
                enabled: true,
                tokens: tokens
            ) {
                closeComposerPopovers()
                presentAttachmentPanel(imagesOnly: true)
            }

            attachMenuRow(
                icon: "paperclip",
                title: l10n.tr("composer.attachFiles"),
                shortcut: "⌘U",
                enabled: true,
                tokens: tokens
            ) {
                closeComposerPopovers()
                presentAttachmentPanel(imagesOnly: false)
            }

            if !state.connectionMode.isRemote, state.activeTrayProjectPath != nil {
                attachMenuRow(
                    icon: "folder.badge.plus",
                    title: l10n.tr("composer.attachments.addFolder"),
                    shortcut: nil,
                    enabled: true,
                    tokens: tokens
                ) {
                    closeComposerPopovers()
                    presentFolderAttachmentPanel()
                }
            }

            attachMenuRow(
                icon: "doc.on.clipboard",
                title: l10n.tr("composer.pasteClipboardImage"),
                shortcut: "⌘V",
                enabled: canPaste,
                tokens: tokens
            ) {
                closeComposerPopovers()
                _ = pasteFromClipboard(preferTextIfPresent: false)
            }

            Rectangle()
                .fill(tokens.borderEtched)
                .frame(height: 1)
                .padding(.vertical, 3)

            attachMenuRow(
                icon: "at",
                title: l10n.tr("composer.addMention"),
                shortcut: "@",
                enabled: true,
                tokens: tokens
            ) {
                closeComposerPopovers()
                insertComposerTrigger("@")
            }

            if !state.activeSlashCommands.isEmpty {
                attachMenuRow(
                    icon: "command",
                    title: l10n.tr("composer.addSlash"),
                    shortcut: "/",
                    enabled: true,
                    tokens: tokens
                ) {
                    closeComposerPopovers()
                    insertComposerTrigger("/")
                }
            }
        }
        .padding(7)
        .frame(width: 236)
        .background(tokens.surface1)
    }

    private func attachMenuRow(
        icon: String,
        title: String,
        shortcut: String?,
        enabled: Bool,
        tokens: PrismTokens,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(enabled ? tokens.prismCobalt : tokens.placeholder)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(enabled ? tokens.foreground : tokens.placeholder)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(tokens.placeholder)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                    .fill(Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: - Helpers

    fileprivate func composerPlaceholder(isNewSessionStage: Bool, l10n: PrismL10n) -> String {
        if isNewSessionStage {
            return l10n.tr("composer.studioPlaceholder")
        }
        let targetAgentName = state.pendingSwitchAgentID.map { agentDisplayName(for: $0) } ?? state.activeModelDisplayName
        let status = state.activeReplica?.session.status ?? state.selectedSessionSummary?.status
        if status == .starting {
            return l10n.tr("composer.placeholder.starting", targetAgentName)
        }
        if state.activeAwaitsQuestionAnswer {
            return l10n.tr("composer.placeholder.awaitingAnswer")
        }
        if status == .awaitingPermission || state.activeHasWaitingCard {
            return l10n.tr("composer.placeholder.awaiting")
        }
        if !state.isTurnBusy && state.activeEndedOnRejection {
            return l10n.tr("composer.placeholder.denied")
        }
        if state.isTurnBusy {
            return l10n.tr("composer.placeholder.runningQueue")
        }
        return l10n.tr("composer.replyPlaceholder", targetAgentName)
    }

    fileprivate struct RichCompletionContext {
        let mode: ComposerRichCompletionMode
        let slashToken: ComposerSlashToken?
        let mentionToken: ComposerMentionToken?
        let anchorX: CGFloat?

        var rowCount: Int {
            switch mode {
            case .slash(let cmds, _): return cmds.count
            case .mention(let files, let sessions, _, _, _): return files.count + sessions.count
            }
        }
    }

    fileprivate func activeRichCompletion(isNewSessionStage: Bool) -> RichCompletionContext? {
        let text = state.activeDraftText
        let caret = ui.editorController.caretUTF16 ?? (text as NSString).length

        // 1. Slash command popover (`/` anywhere at word start, including mid-sentence)
        if let slash = ComposerTrigger.slashAt(text: text, caretUTF16: caret) {
            if ui.dismissedSlashStart != slash.startUTF16 {
                let commands = state.activeSlashCommands
                let matches = ComposerTrigger.orderSlashMatches(commands: commands, query: slash.query)
                if !matches.isEmpty {
                    return RichCompletionContext(
                        mode: .slash(commands: matches, note: nil),
                        slashToken: slash,
                        mentionToken: nil,
                        anchorX: nil
                    )
                }
                if slash.startUTF16 == 0 && commands.isEmpty {
                    let note: String? = isNewSessionStage && state.effectiveNewSessionProjectPath == nil && !state.effectiveNewSessionIsScratch
                        ? state.l10n.tr("composer.mentions.chooseProject")
                        : (state.isPreparingSession ? state.l10n.tr("newSession.preparing") : nil)
                    if let note {
                        return RichCompletionContext(
                            mode: .slash(commands: [], note: note),
                            slashToken: slash,
                            mentionToken: nil,
                            anchorX: nil
                        )
                    }
                }
            }
        }

        // 2. `@` file, folder & session mention popover (supports full-width `＠` and Chinese word-start)
        guard let mention = ComposerTrigger.mentionAt(text: text, caretUTF16: caret) else {
            return nil
        }
        if ui.dismissedMentionStart == mention.startUTF16 {
            return nil
        }
        if ui.editorController.isComposing && !ui.editorController.compositionStartedWithMentionOpen {
            return nil
        }

        let projectPath: String? = isNewSessionStage
            ? (state.effectiveNewSessionIsScratch ? nil : state.effectiveNewSessionProjectPath)
            : (state.selectedSessionSummary?.scratch == true ? nil : state.selectedSessionSummary?.projectPath)
        let anchorX = ui.editorController.xOffset(forPlainUTF16: mention.startUTF16)

        guard let projectPath, !projectPath.isEmpty else {
            return RichCompletionContext(
                mode: .mention(files: [], sessions: [], totalPoolCount: 0, hasQuery: !mention.query.isEmpty, noProject: true),
                slashToken: nil,
                mentionToken: mention,
                anchorX: anchorX
            )
        }

        if state.workspace.activeProjectPath != projectPath
            || (state.workspace.filePaths.isEmpty && !state.workspace.isLoadingFiles && ui.attemptedFilesLoadProject != projectPath) {
            ui.attemptedFilesLoadProject = projectPath
            Task { @MainActor in
                if state.workspace.activeProjectPath != projectPath {
                    await state.workspace.setProjectPath(projectPath)
                }
                if state.workspace.filePaths.isEmpty && !state.workspace.isLoadingFiles {
                    await state.workspace.refreshFiles()
                }
            }
        }

        let rawFiles = state.workspace.activeProjectPath == projectPath ? state.workspace.filePaths : []
        let projectSets = ui.cachedProjectSets(for: rawFiles)
        let orderedFiles: [String]
        if mention.query.isEmpty, !isNewSessionStage, let entries = state.activeReplica?.entries, !rawFiles.isEmpty {
            let used = ComposerPathMatcher.usedFiles(
                from: entries,
                projectPath: projectPath,
                known: projectSets.files,
                limit: 20
            )
            if used.isEmpty {
                orderedFiles = rawFiles
            } else {
                let usedSet = Set(used)
                orderedFiles = used + rawFiles.filter { !usedSet.contains($0) }
            }
        } else {
            orderedFiles = rawFiles
        }

        let fileRows = ComposerPathMatcher.matchMentions(
            query: mention.query,
            files: orderedFiles,
            folders: projectSets.folderArray,
            limit: 30
        )
        let candidates = state.sameProjectReferenceableSessions(isNewSessionStage: isNewSessionStage)
        let sessionRows = ComposerSessionMatcher.matchSessions(query: mention.query, candidates: candidates, limit: 20)
        return RichCompletionContext(
            mode: .mention(
                files: fileRows,
                sessions: sessionRows,
                totalPoolCount: rawFiles.count + candidates.count,
                hasQuery: !mention.query.isEmpty,
                noProject: false
            ),
            slashToken: nil,
            mentionToken: mention,
            anchorX: anchorX
        )
    }

    fileprivate func applyRichSlash(_ command: SlashCommand, token: ComposerSlashToken) {
        let text = ui.editorController.currentPlainText()
        let knownNames = state.activeSlashCommands.map(\.name)
        let edit = ComposerTrigger.placeCommand(text: text, slash: token, name: command.name, knownNames: knownNames)
        ui.dismissedSlashStart = nil
        ui.autocompleteIndex = 0
        state.activeDraftText = edit.text
        ui.editorController.setText(edit.text, caretUTF16: edit.caretUTF16, recordUndo: true)
        ui.requestComposerFocus()
    }

    fileprivate func applyRichFileMention(_ row: ComposerMentionRow, token: ComposerMentionToken) {
        ui.deletedProjectMentions.removeValue(forKey: row.mentionName)
        state.attachProjectFile(relativePath: row.path, isFolder: row.isFolder)
        let text = ui.editorController.currentPlainText()
        let edit = ComposerTrigger.replaceMention(text: text, mention: token, name: row.mentionName)
        ui.dismissedMentionStart = nil
        ui.autocompleteIndex = 0
        state.activeDraftText = edit.text
        ui.editorController.setText(edit.text, caretUTF16: edit.caretUTF16, recordUndo: true)
        ui.requestComposerFocus()
    }

    fileprivate func applyRichSessionMention(_ row: ComposerSessionMentionRow, token: ComposerMentionToken) {
        let item = row.candidate
        let existing = state.activeDraftSessionReferences
        let mentionToken: String
        if let already = existing.first(where: { $0.id == item.id }) {
            mentionToken = already.token
        } else {
            let usedTokens = Set(existing.map(\.token))
            mentionToken = ComposerSessionMatcher.makeToken(
                title: item.title,
                sessionId: item.id,
                existingTokens: usedTokens
            )
        }
        let ref = DraftSessionReference(
            id: item.id,
            token: mentionToken,
            title: item.title,
            agentId: item.agentId,
            agentName: item.agentName,
            projectPath: item.projectPath,
            branch: item.branch,
            updatedAt: item.updatedAt
        )
        state.addDraftSessionReference(ref)

        let text = ui.editorController.currentPlainText()
        let edit = ComposerTrigger.replaceSessionMention(text: text, mention: token, token: mentionToken)
        ui.dismissedMentionStart = nil
        ui.autocompleteIndex = 0
        state.activeDraftText = edit.text
        ui.editorController.setText(edit.text, caretUTF16: edit.caretUTF16, recordUndo: true)
        ui.requestComposerFocus()
    }

    /// Runs on every edit of the draft, from the composer input leaf.
    fileprivate func draftDidChange(_ next: String, caretUTF16: Int?) {
        if ui.autocompleteIndex != 0 { ui.autocompleteIndex = 0 }
        if let ds = ui.dismissedSlashStart {
            let cur = ComposerTrigger.slashAt(text: next, caretUTF16: caretUTF16)
            if cur?.startUTF16 != ds { ui.dismissedSlashStart = nil }
        }
        if let dm = ui.dismissedMentionStart {
            let cur = ComposerTrigger.mentionAt(text: next, caretUTF16: caretUTF16)
            if cur?.startUTF16 != dm { ui.dismissedMentionStart = nil }
        }
        if let armed = ui.armedBlockedSend, armed.text != next {
            ui.armedBlockedSend = nil
        }
        if ui.blockedSendReason != nil {
            ui.blockedSendReason = nil
        }
        // Recall writes the draft too; only a text other than the recalled one is the user's edit.
        if ui.historyIndex != nil && next != ui.historyAppliedText {
            ui.exitHistory()
        }
        // Re-attach any deleted `@file` / `@folder/` mention restored via Cmd+Z undo.
        if !ui.deletedProjectMentions.isEmpty {
            for (tokenName, info) in Array(ui.deletedProjectMentions) {
                if next.contains("@\(tokenName)") || next.contains("＠\(tokenName)") {
                    ui.deletedProjectMentions.removeValue(forKey: tokenName)
                    state.attachProjectFile(relativePath: info.path, isFolder: info.isFolder)
                }
            }
        }
        if !next.isEmpty && !state.showStudioHome {
            state.attachActiveSessionEarlyIfNeeded()
        }
    }

    fileprivate func checkArmedBlockedSend() {
        guard let armed = ui.armedBlockedSend else { return }
        let currentText = ui.editorController.currentPlainText()
        let currentIDs = state.activeDraftAttachments.map(\.id)
        if armed.text != currentText || armed.attachmentIDs != currentIDs {
            ui.armedBlockedSend = nil
            return
        }
        if !state.hasUploadingAttachments {
            ui.armedBlockedSend = nil
            if state.canSendDraft(text: currentText) {
                sendDraft(textOverride: currentText, steer: armed.steer)
            } else if let block = state.sendBlockingReason(text: currentText, isNewSessionStage: state.showStudioHome) {
                ui.blockedSendReason = block.reason
            }
        }
    }

    private func openNewSessionStage(
        hostId: String? = nil,
        projectPath: String?,
        scratch: Bool,
        parentId: String?
    ) {
        closeComposerPopovers()
        if let hostId, hostId != state.activeHostID {
            Task {
                await state.openNewSession(
                    onHost: hostId,
                    projectPath: projectPath,
                    scratch: scratch,
                    parentId: parentId
                )
                ui.requestComposerFocus(newSessionStage: true)
            }
            return
        }
        withAnimation(PrismSpringSpec.snappy.animation(tier: state.motionTier)) {
            state.openNewSession(projectPath: projectPath, scratch: scratch, parentId: parentId)
        }
        ui.requestComposerFocus(newSessionStage: true)
    }

    private func openModelOrAgentMenu(preferAgentSwitcher: Bool) {
        ui.activePopover = preferAgentSwitcher ? .agentSwitcher : .model
        Task { await state.refreshActiveModels() }
    }

    private func insertComposerTrigger(_ sign: String) {
        let text = ui.editorController.currentPlainText()
        let sel = ui.editorController.selectedPlainRange()
        let edit = ComposerTrigger.insertSign(
            text: text,
            fromUTF16: sel.location,
            toUTF16: NSMaxRange(sel),
            sign: sign
        )
        ui.dismissedSlashStart = nil
        ui.dismissedMentionStart = nil
        state.activeDraftText = edit.text
        ui.editorController.setText(edit.text, caretUTF16: edit.caretUTF16, recordUndo: true)
        ui.requestComposerFocus()
    }

    private func presentFolderAttachmentPanel() {
        guard let root = state.activeTrayProjectPath else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.directoryURL = URL(fileURLWithPath: root)
        if panel.runModal() == .OK, let url = panel.url {
            let rel = ComposerPathMatcher.normalizeRelativePath(url.path, projectPath: root)
            if !rel.isEmpty && !rel.hasPrefix("/") {
                state.attachProjectFile(relativePath: rel, isFolder: true)
            } else {
                ui.blockedSendReason = state.l10n.tr("composer.attachmentsUnreadable")
            }
            ui.requestComposerFocus()
        }
    }

    private func presentAddProjectFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        if panel.runModal() == .OK, let url = panel.url {
            let path = url.path
            Task {
                await state.addProject(path: path)
                state.setNewSessionProject(path: path, scratch: false)
                ui.requestComposerFocus()
            }
        }
    }

    fileprivate func sendDraft(textOverride: String? = nil, steer: Bool = false) {
        // A send that switches agents waits on `sessions.runningWork` before the draft is cleared;
        // a second Return meanwhile must not send the same text again.
        guard !ui.isSendingSwitch else { return }
        if textOverride == nil {
            ui.editorController.commitMarkedTextIfNeeded()
        }
        let text = textOverride ?? ui.editorController.currentPlainText()
        let hasAnyContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !state.activeDraftAttachments.isEmpty
            || !state.activeDraftComments.isEmpty
        guard hasAnyContent else { return }

        if !state.canSendDraft(text: text) {
            if let block = state.sendBlockingReason(text: text, isNewSessionStage: state.showStudioHome) {
                if block.waitingForUpload {
                    ui.armedBlockedSend = (
                        text: text,
                        attachmentIDs: state.activeDraftAttachments.map(\.id),
                        steer: steer
                    )
                    ui.blockedSendReason = nil
                } else {
                    ui.blockedSendReason = block.reason
                }
            }
            return
        }

        ui.armedBlockedSend = nil
        ui.blockedSendReason = nil

        // Before executing an in-session Agent Switch, check `sessions.runningWork` so active background tasks aren't silently stopped.
        if !state.showStudioHome, state.pendingSwitchAgentID != nil {
            ui.isSendingSwitch = true
            Task {
                let running = await state.checkRunningWorkBeforeSwitch()
                if !running.isEmpty {
                    ui.pendingSwitchConfirmWork = running
                    ui.pendingSwitchConfirmDraft = text
                } else {
                    prepareForSend()
                    await state.sendPrompt(text, steer: steer)
                }
                ui.isSendingSwitch = false
            }
            return
        }

        executeSendDraft(text: text, steer: steer)
    }

    private func executeSendDraft(text: String, steer: Bool) {
        prepareForSend()
        Task { await state.sendPrompt(text, steer: steer) }
    }

    private func prepareForSend() {
        ui.exitHistory()
        ui.armedBlockedSend = nil
        ui.blockedSendReason = nil
        ui.editorController.clearPastedLinkToast()
        closeComposerPopovers()
        if !state.isTurnBusy {
            ui.forceScrollToBottomToken += 1
        }
    }

    private func runningWorkSummaryText(_ items: [RunningWorkInfo]) -> String {
        var parts: [String] = []
        let subCount = items.reduce(0) { $0 + ($1.subagents ?? 0) }
        let cmdCount = items.reduce(0) { $0 + ($1.commands ?? 0) + ($1.tasks ?? 0) }
        let monCount = items.reduce(0) { $0 + ($1.monitors ?? 0) }
        let waitCount = items.reduce(0) { $0 + $1.waiting }
        if subCount > 0 { parts.append("\(subCount) subagents") }
        if cmdCount > 0 { parts.append("\(cmdCount) tasks") }
        if monCount > 0 { parts.append("\(monCount) monitors") }
        if waitCount > 0 { parts.append("\(waitCount) waiting") }
        return parts.isEmpty ? "active work" : parts.joined(separator: ", ")
    }

    /// Up / Down recall of earlier prompts using visual line boundaries, tracking messages by entry ID,
    /// and asynchronously loading older pages when reaching the oldest loaded message (mirrors `use-input-history.ts`).
    private func browseInputHistory(forward: Bool) -> Bool {
        guard !state.showStudioHome else { return false }
        guard ui.editorController.atVisualBoundary(forward: forward) else { return false }
        if ui.isLoadingOlderHistory && !forward { return true }
        ui.isLoadingOlderHistory = false
        ui.historyLoadGeneration &+= 1
        let gen = ui.historyLoadGeneration
        let snapshotText = ui.editorController.currentPlainText()
        let snapshotSel = ui.editorController.selectedPlainRange()

        func seek() -> Bool {
            let messages = state.recallableUserMessagesWithIDs
            let currentID = ui.historyMessageID
            let currentPos: Int
            if let currentID {
                guard let idx = messages.firstIndex(where: { $0.id == currentID }) else {
                    ui.exitHistory()
                    return false
                }
                currentPos = idx
            } else {
                guard !forward else { return false }
                currentPos = messages.count
            }

            let nextIdx = currentPos + (forward ? 1 : -1)
            if nextIdx >= 0 && nextIdx < messages.count {
                if currentID == nil {
                    ui.historySavedDraft = snapshotText
                }
                let target = messages[nextIdx]
                ui.historyMessageID = target.id
                ui.historyIndex = nextIdx
                ui.historyTotalCount = messages.count
                applyRecalledHistoryText(target.text)
                return true
            }

            if forward {
                guard currentID != nil else { return false }
                restoreHistoryDraft()
                return true
            }

            // Reached oldest loaded message: fetch older history page if available.
            guard let older = state.activeReplica?.older, older > 0 else {
                return currentID != nil
            }
            ui.isLoadingOlderHistory = true
            Task { @MainActor in
                let beforeOlder = state.activeReplica?.older
                await state.loadOlderPage()
                guard ui.historyLoadGeneration == gen else { return }
                ui.isLoadingOlderHistory = false
                // Guard against replacing text the user edited or a selection they moved while waiting.
                let nowText = ui.editorController.currentPlainText()
                let nowSel = ui.editorController.selectedPlainRange()
                guard nowText == snapshotText && nowSel == snapshotSel && ui.editorController.isFocused else {
                    return
                }
                if state.activeReplica?.older != beforeOlder {
                    _ = seek()
                } else {
                    ui.blockedSendReason = state.l10n.tr("composer.history.failed")
                }
            }
            return true
        }

        return seek()
    }

    private func applyRecalledHistoryText(_ text: String) {
        ui.historyAppliedText = text
        state.activeDraftText = text
        ui.editorController.setText(text, caretUTF16: (text as NSString).length, recordUndo: false)
    }

    private func restoreHistoryDraft() {
        let saved = ui.historySavedDraft
        ui.exitHistory()
        state.activeDraftText = saved
        ui.editorController.setText(saved, caretUTF16: (saved as NSString).length, recordUndo: false)
    }

    fileprivate func handleChipClick(_ chip: ComposerChip) {
        switch chip {
        case .command:
            break
        case .session(_, _, _, let sessionId, _, _, let missing):
            if !missing {
                Task { await state.selectSession(sessionId) }
            }
        case .link(_, _, let urlString, _, _, _, _):
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        case .mention(_, _, let kind, _, _, _, let relPath, let attKey, _):
            if kind == .image,
               let attKey,
               let uuid = UUID(uuidString: attKey),
               let item = state.activeDraftAttachments.first(where: { $0.id == uuid }),
               let data = item.previewImageData ?? item.thumbnailData {
                ui.previewImageItem = PrismImagePreviewItem(title: item.name, data: data)
                return
            }
            if kind == .file, let relPath {
                openWorkbenchFile(path: relPath)
                return
            }
            if kind == .folder {
                withAnimation(PrismSpringSpec.default.animation(tier: state.motionTier)) {
                    activeWorkbenchTab = .files
                    showWorkbenchDrawer = true
                }
            }
        }
    }

    fileprivate func handleMentionDeleted(_ deletedIDs: [UUID]) {
        let currentAttachments = state.activeDraftAttachments
        for id in deletedIDs {
            if let item = currentAttachments.first(where: { $0.id == id }),
               let relPath = item.projectRelativePath {
                ui.deletedProjectMentions[item.mentionTokenName] = (path: relPath, isFolder: item.kind == .folder)
            }
            state.removeDraftAttachment(id: id)
        }
    }

    fileprivate func handleSessionRefDeleted(_ deletedSessionIDs: [String]) {
        // Keep references in memory for the current draft scope so Cmd+Z seamlessly restores
        // deleted session chips as pills; sendPrompt and persistDraft already filter by token presence.
        _ = deletedSessionIDs
    }

    fileprivate func loadFileLinesForPreview(relativePath: String) async -> [String]? {
        let projectPath = state.activeTrayProjectPath ?? state.workspace.activeProjectPath
        guard !projectPath.isEmpty else { return nil }
        let cacheKey = "\(projectPath)::\(relativePath)"
        if let cached = ui.filePreviewCache[cacheKey] {
            return cached
        }
        guard let text = await state.readProjectFileText(projectPath: projectPath, relativePath: relativePath)
        else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        ui.filePreviewCache[cacheKey] = lines
        return lines
    }

    fileprivate func handleComposerPaste() -> Bool {
        pasteFromClipboard(preferTextIfPresent: true)
    }

    fileprivate func handleComposerKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])

        // Shift+Tab cycles permission modes (skipping Full Access)
        if event.keyCode == 48 && flags == .shift {
            return state.cyclePermissionMode()
        }

        // Option+E cycles reasoning effort levels when composer is empty or non-dead-key
        if flags == .option,
           event.charactersIgnoringModifiers?.lowercased() == "e",
           optionEMayCycleEffort(event) {
            return state.cycleThoughtLevel()
        }

        let isNewStage = state.showStudioHome
        let comp = activeRichCompletion(isNewSessionStage: isNewStage)

        // Open `@` or `/` completion popover keyboard controls
        if let comp {
            if event.keyCode == 53 && flags.isEmpty { // Esc dismisses current trigger
                if let s = comp.slashToken { ui.dismissedSlashStart = s.startUTF16 }
                if let m = comp.mentionToken { ui.dismissedMentionStart = m.startUTF16 }
                ui.autocompleteIndex = 0
                return true
            }
            if comp.rowCount > 0 {
                if event.keyCode == 125 && flags.isEmpty { // Down arrow
                    ui.autocompleteIndex = (ui.autocompleteIndex + 1) % comp.rowCount
                    return true
                }
                if event.keyCode == 126 && flags.isEmpty { // Up arrow
                    ui.autocompleteIndex = (ui.autocompleteIndex - 1 + comp.rowCount) % comp.rowCount
                    return true
                }
                if (event.keyCode == 48 || event.keyCode == 36 || event.keyCode == 76) && flags.isEmpty {
                    let idx = min(ui.autocompleteIndex, comp.rowCount - 1)
                    switch comp.mode {
                    case .mention:
                        let entries = comp.mode.mentionEntries
                        if let m = comp.mentionToken, entries.indices.contains(idx) {
                            switch entries[idx] {
                            case .file(let fRow): applyRichFileMention(fRow, token: m)
                            case .session(let sRow): applyRichSessionMention(sRow, token: m)
                            }
                            return true
                        }
                    case .slash(let cmds, _):
                        if let s = comp.slashToken, cmds.indices.contains(idx) {
                            applyRichSlash(cmds[idx], token: s)
                            return true
                        }
                    }
                }
            }
        }

        // Tab accepts an active next-message suggestion when the composer is empty.
        if event.keyCode == 48 && flags.isEmpty && !isNewStage {
            let liveText = ui.editorController.currentPlainText()
            if liveText.isEmpty,
               state.activeDraftAttachments.isEmpty,
               state.activeDraftComments.isEmpty,
               let suggestion = state.activeSessionSuggestion {
                state.activeDraftText = suggestion
                draftDidChange(suggestion, caretUTF16: (suggestion as NSString).length)
                return true
            }
        }

        // Esc when no completion popover is open
        if event.keyCode == 53 && flags.isEmpty {
            if ui.activePopover != nil {
                closeComposerPopovers()
                return true
            }
            if ui.showSessionFindBar {
                ui.closeFindBar()
                return true
            }
            if ui.historyIndex != nil {
                restoreHistoryDraft()
                return true
            }
            let liveText = ui.editorController.currentPlainText()
            let isEmpty = liveText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && state.activeDraftAttachments.isEmpty
                && state.activeDraftComments.isEmpty
            if !isNewStage && state.activeHasWaitingCard {
                if isEmpty {
                    _ = state.answerFirstWaitingCard(key: .escape)
                }
                return true
            }
            if !isNewStage && state.isTurnBusy {
                Task { await state.cancelActiveTurn() }
                return true
            }
            return false
        }

        // Arrow Up / Down at visual boundary browses input history
        if flags.isEmpty {
            if event.keyCode == 126 {
                if browseInputHistory(forward: false) { return true }
            } else if event.keyCode == 125 {
                if browseInputHistory(forward: true) { return true }
            }
        }

        // Return / Enter / Shift+Enter / Cmd+Enter / Cmd+Shift+Enter
        if event.keyCode == 36 || event.keyCode == 76 {
            let liveText = ui.editorController.currentPlainText()
            let isEmpty = liveText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && state.activeDraftAttachments.isEmpty
                && state.activeDraftComments.isEmpty

            // Empty composer forwards Enter / Cmd+Enter to the first waiting card in the thread.
            if isEmpty && !isNewStage && !flags.contains(.shift) && !flags.contains(.option) && !flags.contains(.control) {
                let cardKey: ComposerCardKey? = flags == .command ? .confirm : (flags.isEmpty ? .enter : nil)
                if let cardKey, state.answerFirstWaitingCard(key: cardKey) {
                    return true
                }
            }

            if state.sendKeyMode == .commandEnter {
                if flags == .command {
                    let shouldSteer = !isNewStage && state.isTurnBusy
                    sendDraft(textOverride: liveText, steer: shouldSteer)
                    return true
                }
                if flags == [.command, .shift] && !isNewStage && state.isTurnBusy {
                    sendDraft(textOverride: liveText, steer: true)
                    return true
                }
                // Plain Enter inserts a newline naturally in Cmd+Enter send mode.
                return false
            }

            if flags == .shift {
                ui.editorController.insertPlainText("\n")
                return true
            }
            if flags == .command && !isNewStage && state.isTurnBusy {
                sendDraft(textOverride: liveText, steer: true)
                return true
            }
            if flags.isEmpty {
                sendDraft(textOverride: liveText, steer: false)
                return true
            }
        }

        return false
    }

    private func closeComposerPopovers() {
        if ui.activePopover != nil {
            ui.activePopover = nil
        }
    }

    private func jumpToEntry(_ entryID: String) {
        ui.highlightedEntryID = entryID
        ui.scrollTargetEntryID = entryID
        ui.scrollTargetToken += 1
    }

    private func openWorkbenchDiff(path: String) {
        withAnimation(PrismSpringSpec.default.animation(tier: state.motionTier)) {
            activeWorkbenchTab = .git
            showWorkbenchDrawer = true
        }
        Task {
            await state.workspace.refreshGit()
            await state.workspace.loadDiff(for: path)
        }
    }

    private func openGitPane() {
        ui.activePopover = nil
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(PrismSpringSpec.default.animation(tier: state.motionTier, reduceMotion: reduceMotion)) {
            activeWorkbenchTab = .git
            showWorkbenchDrawer = true
        }
    }

    private func openWorkbenchFile(path: String) {
        withAnimation(PrismSpringSpec.default.animation(tier: state.motionTier)) {
            activeWorkbenchTab = .files
            showWorkbenchDrawer = true
            if (WorkspaceController.isMarkdownPath(path) || WorkspaceController.isImagePath(path)) && workbenchWidth < 520 {
                workbenchWidth = 560
            }
        }
        Task {
            if state.workspace.filePaths.isEmpty {
                await state.workspace.refreshFiles()
            }
            await state.workspace.openFile(path: path)
        }
    }

    fileprivate func closeDrawer() {
        withAnimation(PrismSpringSpec.default.animation(tier: state.motionTier)) {
            showWorkbenchDrawer = false
        }
    }

    fileprivate func agentDisplayName(for agentId: String) -> String {
        if agentId == "antigravity" { return "Antigravity" }
        return state.agents.first(where: { $0.id == agentId })?.name ?? agentId
    }

    private func isIMEComposing(in window: NSWindow?) -> Bool {
        guard let responder = (window ?? NSApp.keyWindow)?.firstResponder as? NSTextInputClient else {
            return false
        }
        return responder.hasMarkedText()
    }

    private func presentAttachmentPanel(imagesOnly: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        if imagesOnly {
            panel.allowedContentTypes = [.image, .png, .jpeg, .gif, .webP, .heic, .tiff, .bmp]
        }
        if panel.runModal() == .OK {
            state.attachFiles(urls: panel.urls)
            ui.requestComposerFocus()
        }
    }

    /// Lightweight metadata-only pasteboard check that never pulls Universal Clipboard bytes on `@MainActor`.
    private func clipboardHasAttachableContent() -> Bool {
        let pb = NSPasteboard.general
        if pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            return true
        }
        let imageTypes: [NSPasteboard.PasteboardType] = [
            .png,
            .tiff,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.heic"),
            NSPasteboard.PasteboardType("org.webmproject.webp"),
        ]
        return pb.availableType(from: imageTypes) != nil
    }

    @discardableResult
    private func pasteFromClipboard(preferTextIfPresent: Bool) -> Bool {
        let pb = NSPasteboard.general

        // 1. Finder-copied files / folders always attach as files/folders.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            var fileURLs: [URL] = []
            var attachedFolder = false
            var skippedFolder = false
            for url in urls {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                if isDir {
                    if !state.connectionMode.isRemote, let root = state.activeTrayProjectPath {
                        let rel = ComposerPathMatcher.normalizeRelativePath(url.path, projectPath: root)
                        if !rel.isEmpty && !rel.hasPrefix("/") && !rel.hasPrefix("..") {
                            state.attachProjectFile(relativePath: rel, isFolder: true)
                            attachedFolder = true
                            continue
                        }
                    }
                    skippedFolder = true
                    continue
                }
                fileURLs.append(url)
            }
            if !fileURLs.isEmpty {
                state.attachFiles(urls: fileURLs)
            } else if skippedFolder && !attachedFolder {
                ui.blockedSendReason = state.l10n.tr("composer.attachmentsUnreadable")
            }
            return true
        }

        let plain = pb.string(forType: .string)

        // 2. Long pasted text (> 10,000 chars) collapses into a pasted-text attachment card.
        if preferTextIfPresent, let plain, plain.count > ComposerAttachmentRules.pastedTextThreshold {
            state.attachPastedText(plain)
            return true
        }

        // 3. Disambiguate text vs image when Cmd+V has non-empty plain text on the pasteboard:
        //    - If there are no raster image bytes on the pasteboard, let ComposerNSTextView insert plain text.
        //    - Spreadsheets & rich-text editors put `.string` + `.rtf` (or tab/newline text) alongside `.tiff`; prefer text.
        //    - Browser "Copy Image" puts raster image bytes + optional image URL string without `.rtf`; attach the image.
        let directImageTypes: [NSPasteboard.PasteboardType] = [
            .png,
            NSPasteboard.PasteboardType("public.jpeg"),
            .tiff,
            NSPasteboard.PasteboardType("public.heic"),
            NSPasteboard.PasteboardType("org.webmproject.webp"),
        ]
        let hasDirectImage = pb.availableType(from: directImageTypes) != nil
        if preferTextIfPresent,
           let plain,
           !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !hasDirectImage || ComposerAttachmentRules.shouldPreferPlainTextOverImage(plain) {
                return false
            }
            if pb.availableType(from: [.rtf, .rtfd]) != nil {
                return false
            }
        }

        // 4. Direct clipboard image bytes (e.g. macOS Screenshot Cmd+Ctrl+Shift+4, Preview, browser Copy Image).
        if let png = pb.data(forType: .png), !png.isEmpty {
            state.attachImageData(png)
            return true
        }
        if let jpeg = pb.data(forType: NSPasteboard.PasteboardType("public.jpeg")), !jpeg.isEmpty {
            state.attachImageData(jpeg)
            return true
        }
        if let tiff = pb.data(forType: .tiff), !tiff.isEmpty {
            state.attachImageData(tiff)
            return true
        }
        if (plain == nil || plain?.isEmpty == true),
           let img = NSImage(pasteboard: pb),
           let tiff = img.tiffRepresentation {
            state.attachImageData(tiff)
            return true
        }
        return false
    }

    /// Which input holds the keyboard in the workbench window.
    private enum KeyTarget {
        case composer
        case findBar
        /// Any other text input: terminal, commit message, file editor, notes, sidebar rename.
        case otherInput
        /// No text input (a list, a button, or nothing focused).
        case none
    }

    private func keyTarget(in window: NSWindow) -> KeyTarget {
        guard let responder = window.firstResponder as? NSView else { return .none }
        if responder is ComposerNSTextView {
            return .composer
        }
        if ui.isContainer(responder, in: window) {
            return ui.composerFocused ? .composer : .none
        }
        if let probe = ui.composerProbe(in: window), Self.responder(responder, liesWithin: probe) {
            return .composer
        }
        if let probe = ui.findBarProbe(in: window), Self.responder(responder, liesWithin: probe) {
            return .findBar
        }
        if responder is NSText || responder is NSTextInputClient {
            return .otherInput
        }
        return .none
    }

    /// Whether the visible part of a responder (a field editor or text view) sits inside a probe's frame.
    private static func responder(_ view: NSView, liesWithin probe: NSView) -> Bool {
        let area = probe.convert(probe.bounds, to: nil).insetBy(dx: -6, dy: -6)
        let visible = view.convert(view.visibleRect, to: nil)
        guard !visible.isEmpty else { return false }
        return area.contains(CGPoint(x: visible.midX, y: visible.midY))
    }

    /// Option+E steps the effort only while the composer is empty, and never when the layout's
    /// Option+E types a character of its own (such as the euro sign), so é and € stay typeable.
    private func optionEMayCycleEffort(_ event: NSEvent) -> Bool {
        guard ui.editorController.currentPlainText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let typed = event.characters, !typed.isEmpty else { return true }
        return typed.lowercased() == "e"
    }

    private func installClipboardPasteMonitor() {
        guard pasteKeyMonitor == nil else { return }
        pasteKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])

            // Scope all workbench shortcuts strictly to the active key main workbench window
            // so Settings window, Dynamic Island, Menu Bar panel, sheets, and NSOpenPanel are never hijacked.
            guard NSApp.modalWindow == nil,
                  let win = event.window,
                  win.attachedSheet == nil,
                  win.isKeyWindow,
                  win === NSApp.mainWindow,
                  win.identifier?.rawValue.contains("prism-settings") != true
            else {
                return event
            }
            if let own = ui.workbenchWindow, own !== win {
                return event
            }

            // Cmd+N opens full-stage New Session screen
            if flags == .command,
               event.charactersIgnoringModifiers?.lowercased() == "n" {
                openNewSessionStage(projectPath: nil, scratch: false, parentId: nil)
                return nil
            }

            let target = keyTarget(in: win)

            // Number shortcuts 1-9 for open Mode popover, and 1-4 for open Model popover (when not typing in a text field)
            if flags.isEmpty,
               let ch = event.charactersIgnoringModifiers,
               ch.count == 1,
               let digit = Int(ch),
               digit >= 1 {
                let typingInText = (win.firstResponder as? NSTextView) != nil
                if ui.activePopover == .mode && !typingInText {
                    let modes = state.activeModeChoices
                    if digit <= modes.count {
                        let chosen = modes[digit - 1]
                        ui.activePopover = nil
                        Task { await state.applyModeChoice(chosen.id) }
                        ui.requestComposerFocus()
                        return nil
                    }
                } else if ui.activePopover == .model && digit <= 4 && !typingInText {
                    let numbered = PrismModelMenuLayout.numbered(availableModelOptions(tokens: state.tokens))
                    if digit <= numbered.count {
                        let chosen = numbered[digit - 1]
                        ui.activePopover = nil
                        Task { await state.selectModelOrAgent(chosen.id) }
                        ui.requestComposerFocus()
                        return nil
                    }
                }
            }

            // Composer keys are handled directly by `ComposerNSTextView.keyDown` & `performKeyEquivalent`.
            if target == .composer {
                return event
            }

            // Window-level Esc outside the composer: closes popovers, find bar, or cancels busy turn.
            if event.keyCode == 53 {
                if isIMEComposing(in: win) {
                    return event
                }
                if ui.activePopover != nil {
                    closeComposerPopovers()
                    return nil
                }
                if ui.showSessionFindBar && (target == .findBar || target == .none) {
                    ui.closeFindBar()
                    return nil
                }
                if target == .none && !state.showStudioHome {
                    if state.activeHasWaitingCard && state.answerFirstWaitingCard(key: .escape) {
                        return nil
                    }
                    if state.isTurnBusy {
                        Task { await state.cancelActiveTurn() }
                        return nil
                    }
                }
            }

            return event
        }
    }

    private func removeClipboardPasteMonitor() {
        if let monitor = pasteKeyMonitor {
            NSEvent.removeMonitor(monitor)
            pasteKeyMonitor = nil
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
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
                    if let resolvedURL {
                        Task { @MainActor in
                            state.attachFiles(urls: [resolvedURL])
                        }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                accepted = true
                let suggested = provider.suggestedName
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data, !data.isEmpty else { return }
                    Task { @MainActor in
                        state.attachImageData(data, suggestedName: suggested)
                    }
                }
            }
        }
        return accepted
    }

    private func connectLocalDaemon() {
        Task {
            do {
                let hosts = try await daemon.connectOrStartHosts(
                    daemonEntryPath: SartoState.resolveDaemonBundlePath(),
                    relayOrigin: state.relayOrigin
                )
                await state.attachLiveSession(
                    hosts.agent,
                    terminal: hosts.terminal,
                    mode: .localDaemon(socketPath: daemon.controlSocketPath)
                )
            } catch {
                state.connectionError = error.localizedDescription
            }
        }
    }

    private func workbenchTogglePill(
        _ tab: WorkbenchTab,
        tokens: PrismTokens,
        l10n: PrismL10n,
        shortcut: KeyEquivalent,
        drawerShown: Bool,
        drawerTab: WorkbenchTab
    ) -> some View {
        let active = drawerShown && drawerTab == tab
        let label = tab.localizedTitle(l10n)
        return Button {
            toggleWorkbench(tab)
        } label: {
            HStack(spacing: 3.5) {
                Image(systemName: tab.iconName)
                    .font(.system(size: 10.5, weight: .medium))
                if tab == .git && !state.workspace.changedFiles.isEmpty {
                    Text("\(state.workspace.changedFiles.count)")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(active ? tokens.primary : tokens.mutedForeground)
                } else if tab == .preview && (
                    state.browser.hasUnseenActivity(for: state.selectedSessionSummary?.id)
                    || state.devices.hasAnyActivity(sessionId: state.selectedSessionSummary?.id)
                ) {
                    Circle()
                        .fill(tokens.primary)
                        .frame(width: 5.5, height: 5.5)
                }
            }
            .foregroundStyle(active ? tokens.foreground : tokens.mutedForeground)
            .padding(.horizontal, 7.5)
            .frame(minWidth: 26)
            .frame(height: 22)
            .background(Capsule().fill(active ? tokens.surface2 : Color.clear))
            .fixedSize()
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut, modifiers: .command)
        .prismHoverTooltip(label, shortcut: "⌘\(shortcut.character)")
    }

    private func toggleWorkbench(_ tab: WorkbenchTab) {
        withAnimation(PrismSpringSpec.default.animation(tier: state.motionTier)) {
            if showWorkbenchDrawer && activeWorkbenchTab == tab {
                showWorkbenchDrawer = false
            } else {
                activeWorkbenchTab = tab
                showWorkbenchDrawer = true
            }
        }
        if showWorkbenchDrawer {
            if tab == .preview && workbenchWidth < 460 {
                workbenchWidth = 520
            }
            Task {
                switch tab {
                case .git: await state.workspace.refreshGit()
                case .files: await state.workspace.refreshFiles()
                case .terminal: await state.workspace.ensureDefaultTerminal()
                case .preview:
                    state.browser.markSeen(sessionId: state.selectedSessionSummary?.id)
                    if state.activePreviewTarget == .ios { state.devices.markPlatformSeen(.ios) }
                    if state.activePreviewTarget == .android { state.devices.markPlatformSeen(.android) }
                    if state.activePreviewTarget != .web && state.devices.isConnected {
                        await state.devices.refreshDevices()
                    }
                }
            }
        }
    }

    private func workbenchSplitter(tokens: PrismTokens) -> some View {
        ZStack {
            Rectangle()
                .fill(splitterHovered ? tokens.primary.opacity(0.65) : tokens.borderEtched)
                .frame(width: splitterHovered ? 2 : 1)
                .ignoresSafeArea()
        }
        .frame(width: 6)
        .contentShape(Rectangle())
        .pointerStyle(.frameResize(position: .trailing))
        .onHover { splitterHovered = $0 }
        .onDisappear { splitterHovered = false }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let startWidth: CGFloat
                    if let existing = splitterDragStartWidth {
                        startWidth = existing
                    } else {
                        startWidth = workbenchWidth
                        splitterDragStartWidth = startWidth
                    }
                    let proposed = startWidth - value.translation.width
                    workbenchWidth = max(320, min(920, proposed))
                }
                .onEnded { _ in
                    splitterDragStartWidth = nil
                }
        )
    }

    private func agentSwitcherPopoverContent(
        tokens: PrismTokens,
        l10n: PrismL10n,
        isNewSessionMode: Bool,
        showBackButton: Bool
    ) -> some View {
        AgentSwitcherPopoverView(
            sections: availableAgentMenuSections(tokens: tokens, l10n: l10n, isNewSessionMode: isNewSessionMode),
            activeAgentID: isNewSessionMode
                ? state.selectedAgentID
                : (state.activeModelHostRef != nil ? nil : (state.activeReplica?.session.agentId ?? state.selectedSessionSummary?.agentId)),
            pendingAgentID: isNewSessionMode ? nil : state.pendingSwitchAgentID,
            showBackToModelsTitle: showBackButton ? l10n.tr("composer.backToModels", agentDisplayName(for: state.activeConfigAgentID)) : nil,
            useSystemPopoverChrome: true,
            onInspectAgent: { agentId in
                guard SartoState.remoteClaudeHostID(from: agentId) == nil else { return }
                state.ensureAgentOptionsLoaded(for: agentId)
            },
            onChooseAgent: { agentId in
                if isNewSessionMode {
                    state.setNewSessionAgent(agentId)
                } else {
                    withAnimation(PrismSpringSpec.snappy.animation(tier: state.motionTier)) {
                        state.prepareAgentSwitch(to: agentId)
                    }
                }
            },
            onSelectModel: { agentId, modelId in
                if isNewSessionMode {
                    if let opt = state.configOptions(
                        forAgent: agentId,
                        overrides: state.newSessionOptionPicks[agentId] ?? [:],
                        includeStartMode: true
                    ).first(where: { $0.category == "model" }) {
                        Task { await state.setActiveConfigOption(optionId: opt.id, value: .string(modelId), forAgent: agentId) }
                    } else {
                        state.setNewSessionAgent(agentId)
                    }
                } else {
                    let currentAgent = state.activeReplica?.session.agentId ?? state.selectedSessionSummary?.agentId
                    if agentId != currentAgent || state.activeModelHostRef != nil {
                        state.prepareAgentSwitch(to: agentId)
                    } else {
                        state.cancelAgentSwitch()
                    }
                    if let opt = state.configOptions(
                        forAgent: agentId,
                        overrides: agentId == state.pendingSwitchAgentID ? state.pendingSwitchValues : [:],
                        includeStartMode: false
                    ).first(where: { $0.category == "model" }) ?? ((agentId == currentAgent && state.activeModelHostRef == nil) ? state.activeModelConfigOption : nil) {
                        Task { await state.setActiveConfigOption(optionId: opt.id, value: .string(modelId), forAgent: agentId) }
                    }
                }
                ui.activePopover = nil
                ui.requestComposerFocus()
            },
            onSelectMode: { agentId, modeId in
                if !isNewSessionMode {
                    let currentAgent = state.activeReplica?.session.agentId ?? state.selectedSessionSummary?.agentId
                    if agentId != currentAgent || state.activeModelHostRef != nil { state.prepareAgentSwitch(to: agentId) }
                } else if agentId != state.selectedAgentID {
                    state.setNewSessionAgent(agentId)
                }
                if let opt = state.configOptions(
                    forAgent: agentId,
                    overrides: isNewSessionMode ? (state.newSessionOptionPicks[agentId] ?? [:]) : state.pendingSwitchValues,
                    includeStartMode: isNewSessionMode
                ).first(where: { $0.category == "mode" }) ?? state.activeModeConfigOption {
                    Task { await state.setActiveConfigOption(optionId: opt.id, value: .string(modeId), forAgent: agentId) }
                }
            },
            onSelectEffort: { agentId, effortVal in
                if !isNewSessionMode {
                    let currentAgent = state.activeReplica?.session.agentId ?? state.selectedSessionSummary?.agentId
                    if agentId != currentAgent { state.prepareAgentSwitch(to: agentId) }
                } else if agentId != state.selectedAgentID {
                    state.setNewSessionAgent(agentId)
                }
                Task { await state.selectEffortValue(effortVal, forAgent: agentId) }
            },
            onToggleOption: { agentId, optionId, nextOn in
                if !isNewSessionMode {
                    let currentAgent = state.activeReplica?.session.agentId ?? state.selectedSessionSummary?.agentId
                    if agentId != currentAgent { state.prepareAgentSwitch(to: agentId) }
                } else if agentId != state.selectedAgentID {
                    state.setNewSessionAgent(agentId)
                }
                Task { await state.toggleBooleanOption(optionId, on: nextOn, forAgent: agentId) }
            },
            onBackToModels: showBackButton ? { ui.activePopover = .model } : nil,
            onFixAgent: { agentId in
                ui.activePopover = nil
                // Runs once the popover has closed, since a fix may open a sheet or an open panel.
                Task { @MainActor in runAgentFix(agentId) }
            }
        )
    }

    private func topBarRemoteModelPill(
        modelHost: ModelHostRef,
        tokens: PrismTokens,
        l10n: PrismL10n
    ) -> some View {
        let offline = state.isModelHostOffline(modelHost)
        let accent = offline ? tokens.warning : tokens.prismCobalt
        let fill = offline ? tokens.warningSoft : tokens.prismCobalt.opacity(0.14)
        let stroke = offline ? tokens.warning.opacity(0.35) : tokens.prismCobalt.opacity(0.30)
        return HStack(spacing: 5) {
            Circle()
                .fill(accent)
                .frame(width: 6, height: 6)
            Text(l10n.tr("remoteClaude.topbarPill", modelHost.hostName))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(accent)
                .lineLimit(1)
        }
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(fill))
        .overlay(Capsule().strokeBorder(stroke, lineWidth: 1))
        .prismHoverTooltip(
            l10n.tr(
                offline ? "remoteClaude.topbarTooltipOffline" : "remoteClaude.topbarTooltipOnline",
                modelHost.hostName
            ),
            alignment: .bottomLeading
        )
    }

    private func composerRemoteModelOfflineBanner(
        modelHost: ModelHostRef,
        tokens: PrismTokens,
        l10n: PrismL10n
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10.5))
            Text(l10n.tr("remoteClaude.hostOfflineBanner", modelHost.hostName))
                .font(.system(size: 11))
                .lineLimit(2)
            Spacer(minLength: 4)
            Button(l10n.tr("remoteClaude.openRemoteSettings")) {
                settingsRouter.open(section: .remoteAndCloud, rowID: "remote.mesh")
            }
            .buttonStyle(.plain)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(tokens.primary)
        }
        .foregroundStyle(tokens.warning)
        .padding(.horizontal, 8)
    }

    private func composerRemoteModelBadge(
        modelHost: ModelHostRef,
        tokens: PrismTokens
    ) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 9, weight: .semibold))
            Text(modelHost.hostName)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tokens.prismCobalt)
        .padding(.horizontal, 5.5)
        .padding(.vertical, 1.5)
        .background(Capsule().fill(tokens.prismCobalt.opacity(0.14)))
    }

    /// The new session's run setup panel: the agent, its model, and its mode and effort at once.
    private func runSetupPanelContent(
        tokens: PrismTokens,
        l10n: PrismL10n,
        focus: PrismRunSetupColumn
    ) -> some View {
        RunSetupPanelView(
            sections: availableAgentMenuSections(tokens: tokens, l10n: l10n, isNewSessionMode: true),
            selectedAgentID: state.selectedRunSetupAgentID,
            initialFocus: focus,
            onInspectAgent: { selectionId in
                guard SartoState.remoteClaudeHostID(from: selectionId) == nil else { return }
                state.ensureAgentOptionsLoaded(for: selectionId)
            },
            onChooseAgent: { selectionId in
                state.setNewSessionAgent(selectionId)
            },
            onSelectModel: { selectionId, modelId in
                if selectionId != state.selectedRunSetupAgentID { state.setNewSessionAgent(selectionId) }
                let realAgentId: String
                let pool: [ConfigOption]
                if let hostId = SartoState.remoteClaudeHostID(from: selectionId),
                   let remoteHost = state.remoteClaudeHosts.first(where: { $0.hostId == hostId }) {
                    realAgentId = "claude-code"
                    pool = state.remoteClaudeConfigOptions(
                        for: remoteHost,
                        overrides: state.newSessionOptionPicks["claude-code"] ?? [:]
                    )
                } else {
                    realAgentId = selectionId
                    pool = state.configOptions(
                        forAgent: realAgentId,
                        overrides: state.newSessionOptionPicks[realAgentId] ?? [:],
                        includeStartMode: true
                    )
                }
                if let opt = pool.first(where: { $0.category == "model" }) {
                    Task { await state.setActiveConfigOption(optionId: opt.id, value: .string(modelId), forAgent: realAgentId) }
                }
            },
            onSelectMode: { selectionId, modeId in
                if selectionId != state.selectedRunSetupAgentID { state.setNewSessionAgent(selectionId) }
                let realAgentId: String
                let pool: [ConfigOption]
                if let hostId = SartoState.remoteClaudeHostID(from: selectionId),
                   let remoteHost = state.remoteClaudeHosts.first(where: { $0.hostId == hostId }) {
                    realAgentId = "claude-code"
                    pool = state.remoteClaudeConfigOptions(
                        for: remoteHost,
                        overrides: state.newSessionOptionPicks["claude-code"] ?? [:]
                    )
                } else {
                    realAgentId = selectionId
                    pool = state.configOptions(
                        forAgent: realAgentId,
                        overrides: state.newSessionOptionPicks[realAgentId] ?? [:],
                        includeStartMode: true
                    )
                }
                if let opt = pool.first(where: { $0.category == "mode" }) ?? state.activeModeConfigOption {
                    Task { await state.setActiveConfigOption(optionId: opt.id, value: .string(modeId), forAgent: realAgentId) }
                }
            },
            onSelectEffort: { selectionId, effortVal in
                if selectionId != state.selectedRunSetupAgentID { state.setNewSessionAgent(selectionId) }
                let realAgentId = SartoState.remoteClaudeHostID(from: selectionId) != nil ? "claude-code" : selectionId
                Task { await state.selectEffortValue(effortVal, forAgent: realAgentId) }
            },
            onToggleOption: { selectionId, optionId, nextOn in
                if selectionId != state.selectedRunSetupAgentID { state.setNewSessionAgent(selectionId) }
                let realAgentId = SartoState.remoteClaudeHostID(from: selectionId) != nil ? "claude-code" : selectionId
                Task { await state.toggleBooleanOption(optionId, on: nextOn, forAgent: realAgentId) }
            },
            onSetPinnedModels: { selectionId, models in
                let realAgentId = SartoState.remoteClaudeHostID(from: selectionId) != nil ? "claude-code" : selectionId
                return await state.setPinnedModels(agentId: realAgentId, models: models)
            },
            onFixAgent: { selectionId in
                guard SartoState.remoteClaudeHostID(from: selectionId) == nil else {
                    ui.activePopover = nil
                    settingsRouter.open(section: .remoteAndCloud, rowID: "remote.mesh")
                    return
                }
                ui.activePopover = nil
                // Runs once the popover has closed, since a fix may open a sheet or an open panel.
                Task { @MainActor in runAgentFix(selectionId) }
            },
            onDone: {
                ui.activePopover = nil
                ui.requestComposerFocus()
            }
        )
    }

    private func runAgentFix(_ agentId: String) {
        let state = state
        let settingsRouter = settingsRouter
        AgentFixRunner.run(
            agentId,
            state: state,
            surface: .workbench,
            settings: .direct(state: state, daemon: daemon),
            openSettings: { settingsRouter.open(section: .agents, rowID: "agents.list") },
            onError: { message in state.agentAvailabilityModel.installErrors[agentId] = message }
        )
    }

    private func activeBooleanToggleOptions() -> [PrismBoolToggleOption] {
        makeBooleanToggles(
            from: state.activeBooleanConfigOptions,
            isRunning: !state.showStudioHome && state.isTurnBusy,
            agentId: state.activeConfigAgentID
        )
    }

    private func makeBooleanToggles(from options: [ConfigOption], isRunning: Bool, agentId: String) -> [PrismBoolToggleOption] {
        let l10n = state.l10n
        let harness = state.agents.first(where: { $0.id == agentId })?.harnessName.flatMap { $0.isEmpty ? nil : $0 }
            ?? agentDisplayName(for: agentId)
        return options.map { opt in
            let lower = opt.id.lowercased()
            // A switch with no value of its own follows the harness's setting, known once resolved.
            let followsLine: String? = opt.value.stringValue == "default"
                ? opt.defaultValue.map { l10n.tr($0 ? "composer.followsAgentOn" : "composer.followsAgentOff", harness) }
                    ?? l10n.tr("composer.followsAgent", harness)
                : nil
            return PrismBoolToggleOption(
                id: opt.id,
                name: opt.name,
                description: opt.description,
                isOn: opt.resolvedBoolValue,
                isDisabled: (opt.idleOnly == true) && isRunning,
                isFast: lower.contains("fast"),
                isUltracode: lower.contains("ultracode"),
                indicator: opt.indicator == true,
                followsLine: followsLine
            )
        }
    }

    /// The model menu's pin action for the agent, while the host can pin its models.
    private func modelPinAction(forAgent agentId: String) -> (@MainActor (String, Bool) async -> String?)? {
        guard state.activeModelConfigOption != nil, state.canPinModels(forAgent: agentId) else { return nil }
        let state = state
        return { model, pinned in
            await state.setModelPinned(model, pinned: pinned, forAgent: agentId)
        }
    }

    /// The model menu's rows for an agent's model option, by Sarto's rule: the pinned models, then
    /// the current generation (or, from several providers, the ones used last) in the main list,
    /// and the rest under More models by provider and family.
    private func modelMenuOptions(for modelOpt: ConfigOption, agentId: String, brand: Color) -> [PrismModelOption] {
        guard let choices = modelOpt.choices, !choices.isEmpty else { return [] }
        let l10n = state.l10n
        let kept = state.agentOptionsById[agentId]?.keptModels ?? KeptModels()
        let lists = ui.modelLists(agentId: agentId, choices: choices, current: modelOpt.value.stringValue, kept: kept)
        let pinned = Set(kept.pinned)
        func row(_ read: ModelMenuRead, tier: PrismModelTier) -> PrismModelOption {
            let uses = read.isDefault ? lists.defaultUses(read) : nil
            let subtitle = uses.map { l10n.tr("composer.defaultUses", $0) }
                ?? [lists.several ? read.provider : "", read.choice.description ?? ""]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
            return PrismModelOption(
                id: read.value,
                name: read.name,
                subtitle: subtitle,
                brandColor: brand,
                tag: read.value == lists.defaultValue ? l10n.tr("composer.defaultTag") : "",
                isOlder: read.older,
                tier: tier,
                group: lists.several && !read.provider.isEmpty ? read.provider : nil,
                isPinned: pinned.contains(read.value)
            )
        }
        return lists.main.map { row($0, tier: .main) } + lists.moreInOrder.map { row($0, tier: .more) }
    }

    private func tightestQuotaLeftPercent(for agent: AgentStatusInfo) -> Int? {
        guard let limits = agent.limits, !limits.isEmpty else { return nil }
        let nowMs = Date().timeIntervalSince1970 * 1000.0
        let active = limits.filter { ($0.resetsAt ?? Double.infinity) > nowMs }
        let pool = active.isEmpty ? limits : active
        guard let maxUsed = pool.compactMap(\.usedPercent).max() else { return nil }
        return max(0, min(100, Int((100.0 - maxUsed).rounded())))
    }

    /// The used-up window of the composer's agent that counts on its model, as the composer
    /// placeholder picks it: one that holds an idle session back first, else one extra usage covers.
    /// Nil while an agent switch is pending, since the strip above says where the session goes.
    fileprivate func composerPlanLimit(
        isNewSessionStage: Bool,
        nowMs: Double
    ) -> (limit: PlanLimitInfo, coveredByExtraUsage: Bool)? {
        let agentId: String
        let choices: [ConfigChoice]
        let model: String?
        let busy: Bool
        // Claude Code on another computer runs on that computer's plan, whose limits this one
        // does not read.
        if isNewSessionStage {
            guard state.activeModelHostRef == nil else { return nil }
            agentId = state.selectedAgentID
            let option = state.activeModelConfigOption
            choices = option?.choices ?? []
            model = option?.value.stringValue
            busy = false
        } else {
            guard !state.showStudioHome,
                  state.pendingSwitchAgentID == nil,
                  let summary = state.selectedSessionSummary,
                  summary.modelHost == nil
            else { return nil }
            agentId = summary.agentId
            choices = state.agentOptionsById[agentId]?.config.first { $0.category == "model" }?.choices ?? []
            model = summary.model
            busy = summary.status == .running || summary.status == .starting || summary.status == .awaitingPermission
        }
        guard let limits = state.agents.first(where: { $0.id == agentId })?.limits, !limits.isEmpty else {
            return nil
        }
        let scoped = PlanLimitScope.limits(limits, choices: choices, model: model)
        if !busy, let held = PlanLimitScope.heldBack(scoped, nowMs: nowMs) {
            return (held, false)
        }
        if let covered = PlanLimitScope.coveredByExtraUsage(scoped, nowMs: nowMs) {
            return (covered, true)
        }
        return nil
    }

    private func accountFooterNote(for agentId: String, l10n: PrismL10n) -> String? {
        guard let agent = state.agents.first(where: { $0.id == agentId }) else { return nil }
        var parts: [String] = []
        if let email = agent.account?.email, !email.isEmpty { parts.append(email) }
        if let label = agent.account?.label, !label.isEmpty {
            if let tier = agent.account?.tier, !tier.isEmpty, !label.localizedCaseInsensitiveContains(tier) {
                parts.append("\(label) \(tier)")
            } else {
                parts.append(label)
            }
        }
        if let pct = tightestQuotaLeftPercent(for: agent) {
            parts.append(l10n.tr("composer.quotaLeft", pct))
        }
        // As Sarto's agent tag: a used-up window of the model a new session starts on that extra
        // usage covers.
        if let limits = agent.limits, !limits.isEmpty {
            let option = state.agentOptionsById[agentId]?.config.first { $0.category == "model" }
            let scoped = PlanLimitScope.limits(limits, choices: option?.choices ?? [], model: option?.value.stringValue)
            if PlanLimitScope.coveredByExtraUsage(scoped, nowMs: Date().timeIntervalSince1970 * 1000.0) != nil {
                parts.append(l10n.tr("composer.extraUsage"))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func availableAgentMenuSections(
        tokens: PrismTokens,
        l10n: PrismL10n,
        isNewSessionMode: Bool
    ) -> [PrismAgentMenuSection] {
        let currentId = isNewSessionMode
            ? state.selectedAgentID
            : (state.activeReplica?.session.agentId ?? state.selectedSessionSummary?.agentId ?? state.selectedAgentID)

        // Worked out once per change of the agents, not on every pass of this popover.
        let availability = state.agentAvailability
        let installErrors = state.agentAvailabilityModel.installErrors
        func canStart(_ agent: AgentStatusInfo) -> Bool {
            availability[agent.id]?.canStart ?? (agent.state == "ready" || agent.state == "available")
        }

        // By the tokens each used in the last 30 days, so the list keeps its order while choosing.
        let usedTokens = island.usageStore.agentTokens
        let ordered = state.selectableAgents.sorted { lhs, rhs in
            let lAvail = canStart(lhs)
            let rAvail = canStart(rhs)
            if lAvail != rAvail { return lAvail }
            let lTokens = usedTokens[lhs.id] ?? 0
            let rTokens = usedTokens[rhs.id] ?? 0
            if lTokens != rTokens { return lTokens > rTokens }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        var localSections: [PrismAgentMenuSection] = ordered.map { agent in
            let entry = availability[agent.id]
            let brand = brandColor(for: agent.id, tokens: tokens)
            let isSelectedLocal = isNewSessionMode
                ? (agent.id == currentId && state.selectedModelHostID == nil)
                : (agent.id == currentId && state.activeModelHostRef == nil)
            let option = PrismAgentSwitchOption(
                id: agent.id,
                name: agentDisplayName(for: agent.id),
                brandColor: brand,
                isCurrent: isSelectedLocal,
                isAvailable: canStart(agent),
                statusText: agent.state,
                version: agent.version,
                accountSummary: accountFooterNote(for: agent.id, l10n: l10n),
                quotaLeftPercent: tightestQuotaLeftPercent(for: agent),
                tag: entry?.tag,
                problemText: installErrors[agent.id]
                    ?? entry?.problem?.text
                    ?? (entry?.fix != nil ? entry?.tag?.title : nil),
                fixTitle: entry?.fixTitle
            )

            let cfg: [ConfigOption]
            if !isNewSessionMode && agent.id == currentId && state.activeModelHostRef == nil && state.pendingSwitchAgentID == nil {
                cfg = state.activeReplica?.session.config ?? state.configOptions(forAgent: agent.id, overrides: [:], includeStartMode: false)
            } else if isNewSessionMode {
                let prepCfg = (state.preparedSession?.agentId == agent.id && state.preparedSession?.modelHost == nil)
                    ? state.preparedSession?.prepared?.config
                    : nil
                cfg = state.configOptions(
                    forAgent: agent.id,
                    overrides: state.newSessionOptionPicks[agent.id] ?? [:],
                    includeStartMode: true,
                    preparedOverride: prepCfg
                )
            } else {
                let overrides = (state.pendingSwitchAgentID == agent.id) ? state.pendingSwitchValues : [:]
                cfg = state.configOptions(forAgent: agent.id, overrides: overrides, includeStartMode: false)
            }

            let modelOpt = cfg.first(where: { $0.category == "model" && $0.type == "select" })
            let rawModelVal = modelOpt?.value.stringValue
            let shownModelID = rawModelVal.flatMap { v in
                modelOpt?.choices?.first(where: { $0.value == v })?.shownAs ?? v
            }
            let models: [PrismModelOption] = modelOpt.map {
                modelMenuOptions(for: $0, agentId: agent.id, brand: brand)
            } ?? []

            let modeOpt = cfg.first(where: { $0.category == "mode" && $0.type == "select" })
            let modes: [PrismModeOption] = (modeOpt?.choices ?? []).map {
                PrismModeOption(
                    id: $0.value,
                    name: $0.name,
                    description: $0.description ?? "",
                    look: SartoState.modeLookKind(for: $0.value)
                )
            }

            let resolvedEffort = state.resolveEffort(for: cfg)

            let toggles = makeBooleanToggles(
                from: cfg.filter { $0.type == "boolean" },
                isRunning: !isNewSessionMode && state.isTurnBusy,
                agentId: agent.id
            )

            return PrismAgentMenuSection(
                agent: option,
                models: models,
                selectedModelID: shownModelID,
                pinnedModelIDs: state.agentOptionsById[agent.id]?.keptModels.pinned ?? [],
                canManagePinnedModels: state.canPinModels(forAgent: agent.id),
                modes: modes,
                selectedModeID: modeOpt?.value.stringValue,
                effortTitle: resolvedEffort?.title,
                effortLevels: resolvedEffort?.levels ?? [],
                selectedEffortID: resolvedEffort?.selectedID,
                toggles: toggles
            )
        }

        if isNewSessionMode && !state.isViewingRemoteHost {
            let remoteHosts = state.remoteClaudeHosts.filter(\.status.enabled)
            let claudeBrand = brandColor(for: "claude-code", tokens: tokens)
            for host in remoteHosts {
                let selectionId = SartoState.remoteClaudeSelectionID(for: host.hostId)
                let status = host.status
                let tag: PrismAgentTag
                let problemText: String?
                if status.authRequired {
                    tag = PrismAgentTag(
                        text: l10n.tr("remoteClaude.tagAuthRequired"),
                        tone: .attention,
                        title: l10n.tr("remoteClaude.tagAuthRequiredTitle", host.hostName)
                    )
                    problemText = l10n.tr("remoteClaude.tagAuthRequiredTitle", host.hostName)
                } else if status.isBusy {
                    tag = PrismAgentTag(
                        text: l10n.tr("remoteClaude.tagBusy", status.activeRuns, status.maxConcurrent),
                        tone: .attention,
                        title: l10n.tr("remoteClaude.tagBusyTitle", host.hostName, status.activeRuns, status.maxConcurrent)
                    )
                    problemText = l10n.tr("remoteClaude.tagBusyTitle", host.hostName, status.activeRuns, status.maxConcurrent)
                } else if !status.ready {
                    tag = PrismAgentTag(
                        text: l10n.tr("remoteClaude.tagUnavailable"),
                        tone: .muted,
                        title: status.error
                    )
                    problemText = status.error ?? l10n.tr("remoteClaude.tagUnavailable")
                } else {
                    tag = PrismAgentTag(
                        text: l10n.tr("remoteClaude.tagRemote"),
                        tone: .muted,
                        title: l10n.tr("remoteClaude.tagRemoteTitle", host.hostName)
                    )
                    problemText = nil
                }

                let option = PrismAgentSwitchOption(
                    id: selectionId,
                    name: l10n.tr("remoteClaude.sectionAgentName", host.hostName),
                    brandColor: claudeBrand,
                    isCurrent: state.selectedRunSetupAgentID == selectionId,
                    isAvailable: status.isSelectable,
                    statusText: status.isSelectable ? "ready" : "unavailable",
                    version: nil,
                    accountSummary: l10n.tr("remoteClaude.footerNote", host.hostName),
                    quotaLeftPercent: nil,
                    tag: tag,
                    problemText: problemText,
                    fixTitle: nil
                )

                let prepCfg = (state.preparedSession?.agentId == "claude-code" && state.preparedSession?.modelHost?.hostId == host.hostId)
                    ? state.preparedSession?.prepared?.config
                    : nil
                let cfg = state.remoteClaudeConfigOptions(
                    for: host,
                    overrides: state.newSessionOptionPicks["claude-code"] ?? [:],
                    preparedOverride: prepCfg
                )

                let modelOpt = cfg.first(where: { $0.category == "model" && $0.type == "select" })
                let rawModelVal = modelOpt?.value.stringValue
                let shownModelID = rawModelVal.flatMap { v in
                    modelOpt?.choices?.first(where: { $0.value == v })?.shownAs ?? v
                }
                let models: [PrismModelOption] = modelOpt.map {
                    modelMenuOptions(for: $0, agentId: "claude-code", brand: claudeBrand)
                } ?? []

                let modeOpt = cfg.first(where: { $0.category == "mode" && $0.type == "select" })
                let modes: [PrismModeOption] = (modeOpt?.choices ?? []).map {
                    PrismModeOption(
                        id: $0.value,
                        name: $0.name,
                        description: $0.description ?? "",
                        look: SartoState.modeLookKind(for: $0.value)
                    )
                }

                let resolvedEffort = state.resolveEffort(for: cfg)
                let toggles = makeBooleanToggles(
                    from: cfg.filter { $0.type == "boolean" },
                    isRunning: false,
                    agentId: "claude-code"
                )

                localSections.append(
                    PrismAgentMenuSection(
                        agent: option,
                        models: models,
                        selectedModelID: shownModelID,
                        pinnedModelIDs: state.agentOptionsById["claude-code"]?.keptModels.pinned ?? [],
                        canManagePinnedModels: state.canPinModels(forAgent: "claude-code"),
                        modes: modes,
                        selectedModeID: modeOpt?.value.stringValue,
                        effortTitle: resolvedEffort?.title,
                        effortLevels: resolvedEffort?.levels ?? [],
                        selectedEffortID: resolvedEffort?.selectedID,
                        toggles: toggles
                    )
                )
            }
        }

        return localSections
    }

    private func availableModelOptions(tokens: PrismTokens) -> [PrismModelOption] {
        if let modelOpt = state.activeModelConfigOption, let choices = modelOpt.choices, !choices.isEmpty {
            return modelMenuOptions(
                for: modelOpt,
                agentId: state.activeConfigAgentID,
                brand: activeBrandColor(tokens: tokens)
            )
        }

        let list = state.selectableAgents
        if !list.isEmpty {
            return list.map { agent in
                let ver = agent.version.map { "v\($0)" } ?? agent.state
                let subtitle: String
                switch agent.id {
                case "antigravity": subtitle = "agy acp · \(ver)"
                case "claude-code": subtitle = "Claude Agent SDK · \(ver)"
                case "codex": subtitle = "codex app-server · \(ver)"
                case "pi": subtitle = "Pi RPC Mode · \(ver)"
                case "opencode": subtitle = "OpenCode Server / ACP · \(ver)"
                default: subtitle = "\(agent.harnessId ?? "ACP") · \(ver)"
                }
                let tag: String
                switch agent.state {
                case "ready": tag = "READY"
                case "available": tag = "LOCAL"
                case "starting": tag = "BOOT"
                case "not-installed": tag = "INSTALL"
                default: tag = agent.state.uppercased()
                }
                return PrismModelOption(
                    id: agent.id,
                    name: agent.id == "antigravity" ? "Antigravity" : agent.name,
                    subtitle: subtitle,
                    brandColor: brandColor(for: agent.id, tokens: tokens),
                    tag: tag
                )
            }
        }

        return [
            PrismModelOption(id: "antigravity", name: "Antigravity", subtitle: "agy acp · Google Antigravity", brandColor: Color(hex: 0x4C8DF6), tag: "LOCAL"),
        ]
    }

    private func brandColor(for agentId: String, tokens: PrismTokens) -> Color {
        switch agentId {
        case "antigravity", "gemini": return Color(hex: 0x4C8DF6)
        case "claude-code": return Color(hex: 0xD97757)
        case "codex": return Color(hex: 0x669DF6)
        case "opencode": return Color(hex: 0x9B72CB)
        case "pi": return Color(hex: 0x50A37B)
        default: return tokens.success
        }
    }

    private func activeBrandColor(tokens: PrismTokens) -> Color {
        brandColor(for: state.activeConfigAgentID, tokens: tokens)
    }

    private func effortTagColor(tokens: PrismTokens) -> Color {
        switch state.activeEffortTier {
        case .max: return tokens.palette.isDark ? Color(hex: 0xDFCFFF) : Color(hex: 0x5B21B6)
        case .high: return tokens.palette.isDark ? Color(hex: 0xC4D2EC) : Color(hex: 0x1D4ED8)
        case .normal: return tokens.mutedForeground
        }
    }

    private func effortTagBg(tokens: PrismTokens) -> Color {
        switch state.activeEffortTier {
        case .max: return tokens.prismIris.opacity(0.18)
        case .high: return tokens.prismCobalt.opacity(0.16)
        case .normal: return tokens.surface3.opacity(0.6)
        }
    }

    private func timeAwareGreeting(l10n: PrismL10n) -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 6 { return l10n.tr("greeting.lateNight") }
        if hour < 12 { return l10n.tr("greeting.morning") }
        if hour < 18 { return l10n.tr("greeting.afternoon") }
        return l10n.tr("greeting.evening")
    }

    private func daemonStatusLabel(l10n: PrismL10n) -> String {
        switch daemon.state {
        case .stopped: return l10n.tr("settings.daemon.stopped")
        case .starting: return l10n.tr("settings.daemon.starting")
        case .running(let pid): return l10n.tr("settings.daemon.running", Int(pid))
        case .connectedExternal:
            if daemon.isLaunchdService {
                if let pid = daemon.activePID {
                    return l10n.tr("settings.daemon.serviceRunning", Int(pid))
                }
                return l10n.tr("settings.daemon.serviceRunningNoPid")
            }
            if let pid = daemon.activePID {
                return l10n.tr("settings.daemon.running", Int(pid))
            }
            return l10n.tr("settings.daemon.external")
        case .failed(let msg): return l10n.tr("settings.daemon.failed", msg)
        }
    }

    private func relayShortLabel(l10n: PrismL10n) -> String {
        switch state.relayStatus {
        case .idle: return l10n.tr("settings.relay.idle")
        case .checking: return l10n.tr("settings.relay.checking")
        case .online(let count, _): return l10n.tr("settings.relay.online", count)
        case .failed: return l10n.tr("settings.relay.offline")
        }
    }
}

// MARK: - Workbench UI Model

/// Transient composer, thread and find state read by the leaf views below. An observable object
/// rather than `@State` on `MacWorkbenchView`, so a change re-renders only the leaves that read
/// it instead of the whole workbench.
@MainActor
@Observable
fileprivate final class WorkbenchUIModel {
    private static let composerFixedHeightKey = "sarto.composer.fixedHeight"

    let editorController = ComposerEditorController()
    var rootWindowHeight: CGFloat = 800
    var composerFixedHeight: Double = UserDefaults.standard.double(forKey: WorkbenchUIModel.composerFixedHeightKey) {
        didSet {
            if oldValue != composerFixedHeight {
                UserDefaults.standard.set(composerFixedHeight, forKey: Self.composerFixedHeightKey)
            }
        }
    }
    var activePopover: MacWorkbenchView.ComposerPopoverKind?
    var branchSwitchError: String?
    var historyIndex: Int?
    var historyTotalCount: Int = 0
    @ObservationIgnored var historyMessageID: String?
    @ObservationIgnored var historySavedDraft = ""
    /// The text recall last wrote into the draft, which tells it apart from the user's own edits.
    @ObservationIgnored var historyAppliedText: String?
    @ObservationIgnored var historyLoadGeneration: UInt64 = 0
    @ObservationIgnored var isLoadingOlderHistory = false
    var pendingSwitchConfirmWork: [RunningWorkInfo]?
    var pendingSwitchConfirmDraft: String?
    var scrollTargetEntryID: String?
    var scrollTargetToken = 0
    var highlightedEntryID: String?
    var showSessionFindBar = false
    var sessionFindQuery = ""
    var sessionFindIndex = 0
    var forceScrollToBottomToken = 0
    var autocompleteIndex = 0
    /// Start UTF-16 offset of the `/` or `@` trigger dismissed by Esc.
    var dismissedSlashStart: Int?
    var dismissedMentionStart: Int?
    /// Armed auto-send while attachments finish uploading (mirrors `use-blocked-enter.ts`).
    var armedBlockedSend: (text: String, attachmentIDs: [UUID], steer: Bool)?
    var blockedSendReason: String?
    var activityDockExpandedOverride: Bool?
    var isDropTargeted = false
    var previewImageItem: PrismImagePreviewItem?
    var previewTextAttachment: DraftAttachmentItem?
    var composerFocusRequest: ComposerFocusRequest?
    @ObservationIgnored var handledFocusRequestID = 0
    @ObservationIgnored private var nextFocusRequestID = 0
    /// Set while a send that switches agents waits on `sessions.runningWork`.
    @ObservationIgnored var isSendingSwitch = false
    @ObservationIgnored weak var workbenchWindow: NSWindow?
    // Weak sets: while one composer replaces another, both exist for a moment, and the one
    // registered last may be the one leaving.
    private let windowProbes = NSHashTable<NSView>.weakObjects()
    private let composerProbes = NSHashTable<NSView>.weakObjects()
    private let findBarProbes = NSHashTable<NSView>.weakObjects()
    @ObservationIgnored private var findCache: (key: FindCacheKey, matches: [String])?
    @ObservationIgnored private var modelListsCache: [String: (key: ModelListsKey, lists: ModelMenuLists)] = [:]
    @ObservationIgnored var filePreviewCache: [String: [String]] = [:]
    @ObservationIgnored var deletedProjectMentions: [String: (path: String, isFolder: Bool)] = [:]
    @ObservationIgnored var attemptedFilesLoadProject: String? = nil
    @ObservationIgnored private var projectSetsCache: (count: Int, first: String?, last: String?, files: Set<String>, folders: Set<String>, folderArray: [String])?

    var composerFocused: Bool { editorController.isFocused }

    func cachedProjectSets(for paths: [String]) -> (files: Set<String>, folders: Set<String>, folderArray: [String]) {
        if let c = projectSetsCache, c.count == paths.count, c.first == paths.first, c.last == paths.last {
            return (c.files, c.folders, c.folderArray)
        }
        let files = Set(paths)
        let folderArray = ComposerPathMatcher.folders(of: paths)
        let folders = Set(folderArray)
        projectSetsCache = (paths.count, paths.first, paths.last, files, folders, folderArray)
        return (files, folders, folderArray)
    }

    /// An agent's model menu lists, read again only when its models or kept models change, since
    /// the menus and the number keys ask for them on every render.
    func modelLists(agentId: String, choices: [ConfigChoice], current: String?, kept: KeptModels) -> ModelMenuLists {
        let key = ModelListsKey(choices: choices, current: current, kept: kept)
        if let cached = modelListsCache[agentId], cached.key == key {
            return cached.lists
        }
        let lists = ModelMenuLists(choices: choices, current: current, kept: kept)
        modelListsCache[agentId] = (key, lists)
        return lists
    }

    /// `newSessionStage` targets the composer of one stage, so a composer about to be replaced
    /// never consumes a request meant for the one replacing it.
    func requestComposerFocus(newSessionStage: Bool? = nil) {
        nextFocusRequestID += 1
        composerFocusRequest = ComposerFocusRequest(id: nextFocusRequestID, newSessionStage: newSessionStage)
        editorController.focus()
    }

    func exitHistory() {
        if historyIndex != nil { historyIndex = nil }
        historyTotalCount = 0
        historyMessageID = nil
        historySavedDraft = ""
        historyAppliedText = nil
        isLoadingOlderHistory = false
        historyLoadGeneration &+= 1
    }

    func closeFindBar() {
        if showSessionFindBar { showSessionFindBar = false }
        if !sessionFindQuery.isEmpty { sessionFindQuery = "" }
        if sessionFindIndex != 0 { sessionFindIndex = 0 }
        if highlightedEntryID != nil { highlightedEntryID = nil }
    }

    func register(_ probe: NSView, role: ResponderProbeRole) {
        guard let window = probe.window else { return }
        switch role {
        case .window:
            workbenchWindow = window
            windowProbes.add(probe)
        case .composer: composerProbes.add(probe)
        case .findBar: findBarProbes.add(probe)
        }
    }

    /// Whether a responder contains one of the workbench's probes, as its SwiftUI host view does.
    func isContainer(_ responder: NSView, in window: NSWindow) -> Bool {
        let probes = windowProbes.allObjects + composerProbes.allObjects + findBarProbes.allObjects
        return probes.contains { $0.window === window && ($0 === responder || $0.isDescendant(of: responder)) }
    }

    func composerProbe(in window: NSWindow) -> NSView? {
        composerProbes.allObjects.first { $0.window === window }
    }

    func findBarProbe(in window: NSWindow) -> NSView? {
        findBarProbes.allObjects.first { $0.window === window }
    }

    func findMatches(
        replica: ThreadReplica,
        l10n: PrismL10n,
        canForkSession: Bool,
        canForkAtMessage: Bool,
        query: String
    ) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let key = FindCacheKey(
            sessionId: replica.session.id,
            seq: replica.seq,
            entryCount: replica.order.count,
            status: replica.session.status,
            query: trimmed,
            language: l10n.language,
            canForkSession: canForkSession,
            canForkAtMessage: canForkAtMessage
        )
        if let findCache, findCache.key == key {
            return findCache.matches
        }
        let timeline = ThreadTimelineBuilder.build(
            replica: replica,
            l10n: l10n,
            canForkSession: canForkSession,
            canForkAtMessage: canForkAtMessage
        )
        let matches = ThreadTimelineBuilder.findMatchingEntryIDs(query: trimmed, in: timeline.items)
        findCache = (key, matches)
        return matches
    }
}

fileprivate struct ComposerFocusRequest: Equatable {
    let id: Int
    let newSessionStage: Bool?
}

fileprivate struct ModelListsKey: Equatable {
    let choices: [ConfigChoice]
    let current: String?
    let kept: KeptModels
}

fileprivate struct FindCacheKey: Equatable {
    let sessionId: String
    let seq: Int
    let entryCount: Int
    let status: SessionStatus
    let query: String
    let language: PrismLanguage
    let canForkSession: Bool
    let canForkAtMessage: Bool
}

// MARK: - Responder Probes

fileprivate enum ResponderProbeRole {
    case window
    case composer
    case findBar
}

/// An invisible view laid out behind an input, so the key monitor can tell which input the
/// window's first responder belongs to by comparing frames.
fileprivate final class ResponderProbeView: NSView {
    var onWindowChange: (@MainActor (ResponderProbeView) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

fileprivate struct ResponderProbe: NSViewRepresentable {
    let role: ResponderProbeRole
    let ui: WorkbenchUIModel

    func makeNSView(context: Context) -> ResponderProbeView {
        let view = ResponderProbeView()
        let role = role
        view.onWindowChange = { [weak ui] probe in
            ui?.register(probe, role: role)
        }
        return view
    }

    func updateNSView(_ nsView: ResponderProbeView, context: Context) {
        ui.register(nsView, role: role)
    }
}

// MARK: - Workbench Leaf Views

// Each leaf is Equatable on its plain inputs only and reads everything else from observable
// state, so a parent pass that changes none of those inputs skips its body, while the state it
// reads still re-renders it alone. A leaf must never read the host's `@State` in its body.
extension MacWorkbenchView {
    fileprivate struct TopBarLeaf: View, Equatable {
        let host: MacWorkbenchView
        let drawerShown: Bool
        let drawerTab: WorkbenchTab
        let wideThread: Bool

        @Environment(\.prismTokens) private var tokens
        @Environment(\.prismL10n) private var l10n

        nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.drawerShown == rhs.drawerShown && lhs.drawerTab == rhs.drawerTab && lhs.wideThread == rhs.wideThread
        }

        var body: some View {
            host.topTitleBar(
                tokens: tokens,
                l10n: l10n,
                drawerShown: drawerShown,
                drawerTab: drawerTab,
                wideThread: wideThread
            )
        }
    }

    fileprivate struct BoardPillLeaf: View, Equatable {
        let host: MacWorkbenchView

        @Environment(\.prismTokens) private var tokens
        @Environment(\.prismL10n) private var l10n

        nonisolated static func == (lhs: Self, rhs: Self) -> Bool { true }

        var body: some View {
            host.boardPill(tokens: tokens, l10n: l10n)
        }
    }

    fileprivate struct ThreadStageLeaf: View, Equatable {
        let host: MacWorkbenchView
        let runningRailEnabled: Bool
        let runningRailCollapsed: Bool
        let drawerShown: Bool

        @Environment(\.prismTokens) private var tokens

        nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.runningRailEnabled == rhs.runningRailEnabled
                && lhs.runningRailCollapsed == rhs.runningRailCollapsed
                && lhs.drawerShown == rhs.drawerShown
        }

        var body: some View {
            host.threadStage(tokens: tokens)
        }
    }

    fileprivate struct FindBarLeaf: View, Equatable {
        let host: MacWorkbenchView

        nonisolated static func == (lhs: Self, rhs: Self) -> Bool { true }

        var body: some View {
            let ui = host.ui
            let matches = host.currentFindMatches()
            SessionFindBarView(
                query: Bindable(ui).sessionFindQuery,
                matchCount: matches.count,
                currentIndex: matches.isEmpty ? 0 : min(ui.sessionFindIndex, matches.count - 1),
                onPrev: { host.stepFind(forward: false) },
                onNext: { host.stepFind(forward: true) },
                onClose: { ui.closeFindBar() }
            )
            .background(ResponderProbe(role: .findBar, ui: ui))
            .onChange(of: ui.sessionFindQuery) { _, _ in
                host.findQueryDidChange()
            }
        }
    }

    fileprivate struct SessionFooterLeaf: View, Equatable {
        let host: MacWorkbenchView
        let wideThread: Bool

        nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.wideThread == rhs.wideThread }

        var body: some View {
            host.sessionFooter(wideThread: wideThread)
        }
    }

    fileprivate struct ComposerDockLeaf: View, Equatable {
        let host: MacWorkbenchView
        let isNewSessionStage: Bool
        let wideThread: Bool

        @Environment(\.prismTokens) private var tokens
        @Environment(\.prismL10n) private var l10n

        nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.isNewSessionStage == rhs.isNewSessionStage && lhs.wideThread == rhs.wideThread
        }

        var body: some View {
            let dock = host.floatingComposerDock(
                tokens: tokens,
                l10n: l10n,
                isNewSessionStage: isNewSessionStage,
                wideThread: wideThread
            )
            if isNewSessionStage {
                dock
            } else {
                let ui = host.ui
                let state = host.state
                let showsConfirm = ui.pendingSwitchConfirmWork != nil
                dock.alert(
                    l10n.tr(
                        "composer.switchConfirmTitle",
                        state.pendingSwitchAgentID.map { host.agentDisplayName(for: $0) } ?? ""
                    ),
                    isPresented: Binding(
                        get: { showsConfirm },
                        set: { shown in
                            if !shown {
                                ui.pendingSwitchConfirmWork = nil
                                ui.pendingSwitchConfirmDraft = nil
                            }
                        }
                    )
                ) {
                    Button(l10n.tr("sidebar.cancel"), role: .cancel) {
                        ui.pendingSwitchConfirmWork = nil
                        ui.pendingSwitchConfirmDraft = nil
                    }
                    Button(l10n.tr("composer.switchConfirmGo"), role: .destructive) {
                        let draft = ui.pendingSwitchConfirmDraft
                        ui.pendingSwitchConfirmWork = nil
                        ui.pendingSwitchConfirmDraft = nil
                        if let draft {
                            host.executeSendDraft(text: draft, steer: false)
                        }
                    }
                } message: {
                    Text(l10n.tr("composer.switchConfirmMessage", host.runningWorkSummaryText(ui.pendingSwitchConfirmWork ?? [])))
                }
            }
        }
    }

    /// Isolated resize grip leaf reading observable height state directly so dragging never stalls
    /// behind `SessionFooterLeaf.equatable()` / `ComposerDockLeaf.equatable()` or re-renders the workbench.
    fileprivate struct ComposerResizeGripLeaf: View, Equatable {
        let host: MacWorkbenchView
        let minHeight: CGFloat

        nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.minHeight == rhs.minHeight
        }

        var body: some View {
            let ui = host.ui
            let maxHeight = max(minHeight + 40, min(ui.rootWindowHeight * 0.40, 360))
            let autoHeight = max(minHeight, min(ui.editorController.measuredContentHeight, maxHeight))
            let currentHeight = ui.composerFixedHeight > 0
                ? min(maxHeight, max(minHeight, CGFloat(ui.composerFixedHeight)))
                : autoHeight

            ComposerResizeGripView(
                currentHeight: currentHeight,
                autoHeight: autoHeight,
                minHeight: minHeight,
                maxHeight: maxHeight,
                onSetFixedHeight: { nextH in
                    ui.composerFixedHeight = Double(nextH)
                },
                onResetAutoHeight: {
                    ui.composerFixedHeight = 0
                }
            )
        }
    }

    /// Native AppKit NSTextView composer leaf with inline atomic chips, live Markdown styling,
    /// caret-aware triggers, visual line boundary detection, and resizable height.
    fileprivate struct ComposerInputLeaf: View, Equatable {
        let host: MacWorkbenchView
        let isNewSessionStage: Bool
        let placeholder: String
        let compactTop: Bool
        let minHeight: CGFloat

        @Environment(\.prismTokens) private var tokens
        @Environment(\.prismTypography) private var typography

        nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.isNewSessionStage == rhs.isNewSessionStage
                && lhs.placeholder == rhs.placeholder
                && lhs.compactTop == rhs.compactTop
                && lhs.minHeight == rhs.minHeight
        }

        var body: some View {
            let ui = host.ui
            let state = host.state
            let draft = state.activeDraftText
            let attachments = state.activeDraftAttachments
            let sessionRefs = state.activeDraftSessionReferences
            let missingSessions = state.missingReferencedSessionIDs(for: sessionRefs)
            let commandNames = state.activeSlashCommands.map(\.name)
            let isStarting = !isNewSessionStage && state.activeReplica?.session.status == .starting
            let suggestion = (!isNewSessionStage && draft.isEmpty && attachments.isEmpty && state.activeDraftComments.isEmpty)
                ? state.activeSessionSuggestion
                : nil
            let effectivePlaceholder = suggestion ?? placeholder
            let maxHeight = max(minHeight + 40, min(ui.rootWindowHeight * 0.40, 360))
            let fixedHeight: CGFloat? = ui.composerFixedHeight > 0 ? CGFloat(ui.composerFixedHeight) : nil
            let resolvedHeight: CGFloat = fixedHeight.map { min(maxHeight, max(minHeight, $0)) }
                ?? min(maxHeight, max(minHeight, ui.editorController.measuredContentHeight))

            ZStack(alignment: .topTrailing) {
                ComposerTextEditor(
                    scope: state.activeAttachmentScope,
                    controller: ui.editorController,
                    text: draft,
                    placeholder: effectivePlaceholder,
                    isDisabled: isStarting,
                    tokens: tokens,
                    typography: typography,
                    commandNames: commandNames,
                    attachments: attachments,
                    sessionReferences: sessionRefs,
                    missingSessionIDs: missingSessions,
                    isMentionPopoverOpen: {
                        if let comp = host.activeRichCompletion(isNewSessionStage: isNewSessionStage),
                           case .mention = comp.mode {
                            return true
                        }
                        return false
                    },
                    onTextChange: { next, caret in
                        state.activeDraftText = next
                        host.draftDidChange(next, caretUTF16: caret)
                    },
                    onCaretChange: { _ in },
                    onKeyDown: { event in
                        host.handleComposerKeyDown(event)
                    },
                    onPaste: {
                        host.handleComposerPaste()
                    },
                    onChipClick: { chip in
                        host.handleChipClick(chip)
                    },
                    onMentionDeleted: { deletedIDs in
                        host.handleMentionDeleted(deletedIDs)
                    },
                    onSessionRefDeleted: { deletedSessionIDs in
                        host.handleSessionRefDeleted(deletedSessionIDs)
                    }
                )
                if let suggestion {
                    Button {
                        state.activeDraftText = suggestion
                        host.draftDidChange(suggestion, caretUTF16: (suggestion as NSString).length)
                        ui.requestComposerFocus()
                    } label: {
                        Text(host.state.l10n.tr("composer.suggestionHint"))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(tokens.mutedForeground)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                                    .fill(tokens.surface2.opacity(0.85))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                                    .strokeBorder(tokens.borderEtched, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 5)
                    .padding(.trailing, 4)
                }
            }
            .frame(height: resolvedHeight)
            .background(ResponderProbe(role: .composer, ui: ui))
            .padding(.horizontal, 4)
            .padding(.top, compactTop ? 2 : 0)
            .onChange(of: ui.composerFocusRequest) { _, _ in
                honorFocusRequest()
            }
            .onAppear {
                honorFocusRequest()
            }
        }

        private func honorFocusRequest() {
            let ui = host.ui
            guard let request = ui.composerFocusRequest,
                  request.id != ui.handledFocusRequestID,
                  request.newSessionStage == nil || request.newSessionStage == isNewSessionStage
            else { return }
            ui.handledFocusRequestID = request.id
            DispatchQueue.main.async {
                ui.editorController.focus()
            }
        }
    }

    fileprivate struct ComposerAutocompleteLeaf: View, Equatable {
        let host: MacWorkbenchView
        let isNewSessionStage: Bool
        let maxWidth: CGFloat

        nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.isNewSessionStage == rhs.isNewSessionStage && lhs.maxWidth == rhs.maxWidth
        }

        var body: some View {
            if let context = host.activeRichCompletion(isNewSessionStage: isNewSessionStage) {
                let agentName = host.agentDisplayName(
                    for: isNewSessionStage
                        ? host.state.selectedAgentID
                        : (host.state.pendingSwitchAgentID ?? host.state.selectedSessionSummary?.agentId ?? host.state.selectedAgentID)
                )
                let popoverWidth: CGFloat = context.mentionToken != nil ? min(420, maxWidth) : min(560, maxWidth)
                let leadingOffset: CGFloat = {
                    guard let x = context.anchorX, context.mentionToken != nil else { return 0 }
                    return max(0, min(x, maxWidth - popoverWidth))
                }()

                HStack(spacing: 0) {
                    ComposerRichAutocompleteView(
                        mode: context.mode,
                        agentName: agentName,
                        selectedIndex: min(host.ui.autocompleteIndex, max(0, context.rowCount - 1)),
                        onHighlight: { idx in
                            if host.ui.autocompleteIndex != idx {
                                host.ui.autocompleteIndex = idx
                            }
                        },
                        onSelectSlash: { cmd in
                            if let s = context.slashToken {
                                host.applyRichSlash(cmd, token: s)
                            }
                        },
                        onSelectFile: { row in
                            if let m = context.mentionToken {
                                host.applyRichFileMention(row, token: m)
                            }
                        },
                        onSelectSession: { row in
                            if let m = context.mentionToken {
                                host.applyRichSessionMention(row, token: m)
                            }
                        }
                    )
                    .frame(width: popoverWidth)
                    .padding(.leading, leadingOffset)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: maxWidth)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }

    fileprivate struct ComposerLeadingCommandStripLeaf: View, Equatable {
        let host: MacWorkbenchView
        let isNewSessionStage: Bool
        let maxWidth: CGFloat

        nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.isNewSessionStage == rhs.isNewSessionStage && lhs.maxWidth == rhs.maxWidth
        }

        var body: some View {
            let ui = host.ui
            let state = host.state
            let popoverOpen = host.activeRichCompletion(isNewSessionStage: isNewSessionStage) != nil
            let hasOverlay = ui.editorController.hoveredChip != nil || ui.editorController.pastedLinkToast != nil
            if ui.editorController.isFocused && !popoverOpen && !hasOverlay {
                let commands = state.activeSlashCommands
                let names = commands.map(\.name)
                let text = state.activeDraftText
                let cmdLen = ComposerTrigger.leadingCommandLengthUTF16(in: text, names: names)
                if cmdLen > 1 {
                    let cmdName = (text as NSString).substring(with: NSRange(location: 1, length: cmdLen - 1))
                    if let cmd = commands.first(where: { $0.name == cmdName }) {
                        let agentName = host.agentDisplayName(
                            for: isNewSessionStage
                                ? state.selectedAgentID
                                : (state.pendingSwitchAgentID ?? state.selectedSessionSummary?.agentId ?? state.selectedAgentID)
                        )
                        ComposerLeadingCommandStripView(command: cmd, agentName: agentName)
                            .frame(maxWidth: maxWidth)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
            }
        }
    }

    fileprivate struct ComposerChipOverlayLeaf: View, Equatable {
        let host: MacWorkbenchView
        let maxWidth: CGFloat

        nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.maxWidth == rhs.maxWidth
        }

        var body: some View {
            let controller = host.ui.editorController
            if let toast = controller.pastedLinkToast {
                let offset = max(0, min(toast.anchorX, maxWidth - 260))
                HStack(spacing: 0) {
                    ComposerPastedLinkToastView {
                        controller.keepLinkAsText(url: toast.url)
                    }
                    .padding(.leading, offset)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: maxWidth)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if let hovered = controller.hoveredChip {
                let offset = max(0, min(hovered.anchorX, maxWidth - 320))
                let att: DraftAttachmentItem? = hovered.chip.attachmentKey
                    .flatMap(UUID.init(uuidString:))
                    .flatMap { uuid in host.state.activeDraftAttachments.first(where: { $0.id == uuid }) }
                HStack(spacing: 0) {
                    ComposerChipHoverPreviewView(
                        chip: hovered.chip,
                        attachment: att,
                        loadFileLines: { rel in await host.loadFileLinesForPreview(relativePath: rel) },
                        loadSessionPreview: { sid in await host.state.fetchSessionPreview(sessionId: sid) }
                    )
                    .padding(.leading, offset)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: maxWidth)
                .transition(.opacity)
            }
        }
    }

    fileprivate struct ComposerCacheNoticeLeaf: View, Equatable {
        let host: MacWorkbenchView

        nonisolated static func == (lhs: Self, rhs: Self) -> Bool { true }

        var body: some View {
            let state = host.state
            let draftNonEmpty = state.activeDraftText.contains(where: { !$0.isWhitespace })
                || !state.activeDraftAttachments.isEmpty
                || !state.activeDraftComments.isEmpty
            if let usedTokens = state.expiredCacheNoticeTokens(draftNonEmpty: draftNonEmpty) {
                ComposerCacheNoticeView(
                    usedTokens: usedTokens,
                    onDismiss: { state.dismissActiveCacheNotice() }
                )
                .frame(maxWidth: 760)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }

    /// The plan window the composer's agent is up against, as the composer placeholder shows it:
    /// a used-up window that holds the session back and when it resets, or one that extra usage
    /// covers, with its badge. Reads summaries and agents, never the replica.
    fileprivate struct ComposerPlanLimitLeaf: View, Equatable {
        let host: MacWorkbenchView
        let isNewSessionStage: Bool

        @Environment(\.prismTokens) private var tokens
        @Environment(\.prismL10n) private var l10n

        nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.isNewSessionStage == rhs.isNewSessionStage
        }

        var body: some View {
            let nowMs = Date().timeIntervalSince1970 * 1000.0
            if let shown = host.composerPlanLimit(isNewSessionStage: isNewSessionStage, nowMs: nowMs) {
                if shown.coveredByExtraUsage {
                    HStack(spacing: 6) {
                        Text(l10n.tr("composer.extraUsage"))
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(tokens.warning)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(tokens.warningSoft))
                            .overlay(Capsule().strokeBorder(tokens.warning.opacity(0.45), lineWidth: 1))
                            .fixedSize()
                        Text(l10n.tr("composer.limitExtraUsage", shown.limit.label))
                            .font(.system(size: 11))
                            .foregroundStyle(tokens.mutedForeground)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(.horizontal, 8)
                    .accessibilityElement(children: .combine)
                    .prismHoverTooltip(l10n.tr("composer.extraUsageTooltip"), alignment: .topLeading)
                } else {
                    let text: String = shown.limit.resetsAt.map { resetsAt in
                        l10n.tr(
                            "composer.limitReached",
                            shown.limit.label,
                            SidebarTurnEnding.resetTime(resetsAt, nowMs: nowMs, locale: l10n.language.resolvedLocale)
                        )
                    } ?? l10n.tr("composer.limitReachedNoReset", shown.limit.label)
                    HStack(spacing: 6) {
                        Image(systemName: "hourglass")
                            .font(.system(size: 10.5))
                        Text(text)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .foregroundStyle(tokens.warning)
                    .padding(.horizontal, 8)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    fileprivate struct ComposerSendLeaf: View, Equatable {
        let host: MacWorkbenchView
        let isNewSessionStage: Bool

        nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.isNewSessionStage == rhs.isNewSessionStage
        }

        var body: some View {
            let state = host.state
            let busy = !isNewSessionStage && state.isTurnBusy
            ComposerSendControlView(
                isRunning: busy,
                isBusy: busy,
                canSend: state.canSendDraft(text: state.activeDraftText),
                supportsSteering: state.activeAgentCapabilities?.steering == true,
                onSendOrQueue: { host.sendDraft(steer: false) },
                onSteerNow: { host.sendDraft(steer: true) },
                onStop: { Task { await state.cancelActiveTurn() } }
            )
        }
    }

    /// Reads the selected session for the drawer, so the workbench body never depends on the
    /// session list.
    fileprivate struct DrawerLeaf: View {
        let host: MacWorkbenchView
        @Binding var activeTab: WorkbenchTab

        var body: some View {
            let state = host.state
            let summary = state.selectedSessionSummary
            WorkbenchDrawerView(
                workspace: state.workspace,
                browser: state.browser,
                devices: state.devices,
                previewTarget: Bindable(state).activePreviewTarget,
                sessionId: summary?.id,
                agentDisplayName: summary.map { host.agentDisplayName(for: $0.agentId) } ?? "Agent",
                activeTab: $activeTab,
                onClose: { host.closeDrawer() },
                onPreviewHTML: summary == nil ? nil : { path in
                    Task { await state.previewHTMLFileInBrowser(relativePath: path) }
                },
                onQuoteToComposer: { quote in
                    state.appendQuotedFilePassage(quote)
                    host.ui.requestComposerFocus()
                }
            )
        }
    }

    /// Isolates Dynamic Island running-session observation from `MacWorkbenchView.body` so live
    /// session line / status ticks only re-evaluate the right rail leaf.
    fileprivate struct RunningRailSlotLeaf: View {
        let host: MacWorkbenchView
        let runningRailEnabled: Bool
        @Binding var runningRailCollapsed: Bool
        @Binding var showWorkbenchDrawer: Bool

        var body: some View {
            let model = host.island.model
            let state = host.state
            let hasRows = runningRailEnabled && !RunningSessionsRail.rows(of: model).isEmpty
            Group {
                if hasRows {
                    RunningSessionsRail(
                        model: model,
                        rpgStore: host.island.rpgStore,
                        collapsed: runningRailCollapsed || showWorkbenchDrawer,
                        selectedSessionID: state.showStudioHome ? nil : state.selectedSessionSummary?.id,
                        onSelect: { sid in
                            host.closeComposerPopovers()
                            Task {
                                await state.selectSession(sid)
                            }
                        },
                        onToggleCollapsed: {
                            withAnimation(PrismSpringSpec.default.animation(tier: state.motionTier)) {
                                if showWorkbenchDrawer {
                                    showWorkbenchDrawer = false
                                    runningRailCollapsed = false
                                } else {
                                    runningRailCollapsed.toggle()
                                }
                            }
                        }
                    )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(
                PrismSpringSpec.default.animation(tier: state.motionTier),
                value: hasRows
            )
        }
    }
}

/// Instant, zero-delay Obsidian Prism floating tooltip that works reliably inside `.hiddenTitleBar` windows.
private struct PrismHoverTooltipModifier: ViewModifier {
    @Environment(\.prismTokens) private var tokens

    let text: String
    let shortcut: String?
    let alignment: Alignment

    @State private var isHovered = false

    private var cleanLabel: String {
        guard let shortcut, !shortcut.isEmpty else { return text }
        return text
            .replacingOccurrences(of: " (\(shortcut))", with: "")
            .replacingOccurrences(of: " \(shortcut)", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private var tooltipAnchorAlignment: Alignment {
        switch alignment {
        case .bottomLeading: return .topLeading
        case .bottomTrailing: return .topTrailing
        case .top: return .bottom
        case .topLeading: return .bottomLeading
        case .topTrailing: return .bottomTrailing
        default: return .top
        }
    }

    private var isPlacedAbove: Bool {
        alignment == .top || alignment == .topLeading || alignment == .topTrailing
    }

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) {
                    isHovered = hovering
                }
            }
            .overlay(alignment: alignment) {
                Color.clear
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .overlay(alignment: tooltipAnchorAlignment) {
                        if isHovered && !cleanLabel.isEmpty {
                            HStack(spacing: 6) {
                                Text(cleanLabel)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(tokens.foreground)
                                if let shortcut, !shortcut.isEmpty {
                                    Text(shortcut)
                                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(tokens.mutedForeground)
                                        .padding(.horizontal, 4.5)
                                        .padding(.vertical, 1.5)
                                        .background(
                                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                                .fill(tokens.hoverWash)
                                        )
                                }
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .prismSurface(elevation: .popover, cornerRadius: tokens.rXS)
                            .overlay(
                                RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                                    .strokeBorder(tokens.borderStrong, lineWidth: 1)
                            )
                            .fixedSize()
                            .padding(isPlacedAbove ? .bottom : .top, 8)
                            .allowsHitTesting(false)
                            .transition(.opacity.combined(with: .offset(y: isPlacedAbove ? 3 : -3)))
                        }
                    }
            }
            .zIndex(isHovered ? 80 : 0)
    }
}

private extension View {
    func prismHoverTooltip(
        _ text: String,
        shortcut: String? = nil,
        alignment: Alignment = .bottom
    ) -> some View {
        modifier(PrismHoverTooltipModifier(text: text, shortcut: shortcut, alignment: alignment))
    }
}

// MARK: - Isolated High-Frequency Observation Leaf Views

private struct StageBackdropHostView: View {
    var state: SartoState

    var body: some View {
        AsciiRippleSeaView(
            calmCenter: true,
            liftoffToken: state.liftoffToken,
            intensity: state.showStudioHome ? 1.0 : 0.36,
            bottomAuraState: state.showStudioHome ? nil : state.activeAuraState,
            interactiveRipples: state.showStudioHome
        )
    }
}

private struct InSessionTelemetryTrayView: View {
    var state: SartoState
    var speedExpanded: Binding<Bool>
    var cacheExpanded: Binding<Bool>
    var contextExpanded: Binding<Bool>

    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    var body: some View {
        MiniTelemetryStripView(
            tps: state.currentTPS,
            cacheHitPercent: state.currentCacheHit,
            cacheMode: state.currentCacheMode,
            totalTokens: state.activeContextTotal,
            contextFill: state.activeContextFill,
            speedExpanded: speedExpanded,
            cacheExpanded: cacheExpanded,
            contextExpanded: contextExpanded,
            speedPopover: { styled(speedPopover) },
            cachePopover: { styled(cachePopover) },
            contextPopover: {
                styled(
                    ContextTelemetryPopoverView(
                        modelName: state.activeModelDisplayName,
                        usedTokens: state.activeContextUsed,
                        totalTokens: state.activeContextTotal,
                        turnContextDelta: state.currentTurnContextDelta,
                        strata: state.activeContextStrata,
                        detailLists: state.activeContextDetailLists,
                        isLoadingDetails: state.isLoadingContextBreakdown,
                        useSystemPopoverChrome: true
                    )
                )
                .task {
                    await state.refreshActiveContextBreakdown()
                }
            }
        )
    }

    private var speedPopover: OutputSpeedPopoverView {
        let speed = state.activeReplica?.session.speed
        return OutputSpeedPopoverView(
            rate: state.currentTPS,
            isApprox: state.currentTPSIsApprox,
            isStreaming: state.activeIsStreaming,
            recentRates: speed?.recent?.map(\.rate) ?? [],
            firstTokenMs: speed?.last?.firstTokenMs ?? state.currentTTFTMs.map(Double.init),
            lastTokens: speed?.last?.tokens,
            lastMs: speed?.last?.ms,
            turnRate: speed?.turn?.rate,
            turnRequests: speed?.turn?.requests,
            sessionRate: speed?.session?.rate,
            sessionRequests: speed?.session?.requests,
            useSystemPopoverChrome: true
        )
    }

    private var cachePopover: PromptCachePopoverView {
        let session = state.activeReplica?.session
        let request = session?.lastRequest
        let cache = session?.usage?.cache
        let account = session.flatMap { s in state.agents.first(where: { $0.id == s.agentId })?.account }
        let effectiveExpiresAt = cache?.expiresAt ?? session.flatMap { s in
            IslandPromptCache.cacheWindow(
                agentId: s.agentId,
                cache: cache,
                model: state.selectedSessionSummary?.model ?? state.activeModelConfigOption?.value.stringValue,
                account: account
            )?.expiresAt
        }
        return PromptCachePopoverView(
            hitPercent: state.currentCacheHit,
            mode: state.currentCacheMode,
            sessionHitPercent: state.currentSessionCacheHit,
            requestCacheRead: request?.cacheRead,
            requestCacheWrite: request?.cacheWrite,
            requestUncached: request?.input,
            sessionCacheRead: session?.usage?.tokens?.cacheRead,
            sessionCacheWrite: session?.usage?.tokens?.cacheWrite,
            expiresAtMs: effectiveExpiresAt,
            lastRequestAtMs: cache?.lastRequestAt ?? request?.at,
            isTurnActive: state.isTurnBusy,
            useSystemPopoverChrome: true
        )
    }

    private func styled<Content: View>(_ content: Content) -> some View {
        content
            .focusEffectDisabled()
            .presentationBackground(tokens.surface1)
            .environment(\.prismTokens, tokens)
            .environment(\.prismL10n, l10n)
            .environment(\.prismMotionTier, state.motionTier)
            .preferredColorScheme(state.palette.colorScheme)
    }
}
