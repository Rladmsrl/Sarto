import AppKit
import SartoProtocol
import PrismDesign
import SwiftUI

// MARK: - Native Independent macOS Settings Window

struct PrismSettingsWindowView: View {
    @Bindable var state: SartoState
    @Bindable var daemon: LocalDaemonManager
    @Bindable var island: PrismDynamicIslandCoordinator
    @Bindable var router: PrismSettingsRouter
    @State private var store = PrismSettingsStore()
    @Environment(ProblemReportCoordinator.self) private var problemReport

    private struct PreloadKey: Equatable {
        let section: PrismSettingsSection
        let hostID: String
        let isLive: Bool
    }

    private var preloadKey: PreloadKey {
        PreloadKey(section: router.selectedSection, hostID: state.activeHostID, isLive: state.connectionMode.isLive)
    }

    private var tokens: PrismTokens { state.tokens }
    private var l10n: PrismL10n { state.l10n }

    private var searchMatches: [PrismSettingsSearchItem] {
        PrismSettingsSearchCatalog.matching(query: router.searchQuery, l10n: l10n)
    }

    var body: some View {
        NavigationSplitView {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 215, ideal: 232, max: 268)
        } detail: {
            detailContent
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 780, minHeight: 540)
        .background(tokens.background)
        .preferredColorScheme(state.palette.colorScheme)
        .environment(\.prismTokens, tokens)
        .environment(\.prismL10n, l10n)
        .environment(\.prismMotionTier, state.motionTier)
        .environment(\.locale, state.language.resolvedLocale)
        .onAppear {
            island.launchAtLogin.refresh()
            deliverPendingNotice()
            if store.daemonStatus == nil {
                Task { await store.loadSidebarStatus(daemon: daemon) }
            }
        }
        .task(id: preloadKey) {
            await preload(section: preloadKey.section)
        }
        .onChange(of: router.selectedSection) { _, _ in
            store.clearBanners()
        }
        .onChange(of: router.pendingNotice) { _, _ in
            deliverPendingNotice()
        }
        .onChange(of: state.memoryChangeRevision) { _, _ in
            if router.selectedSection == .memory, state.connectionMode.isLive {
                Task { await store.loadMemorySection(state: state) }
            }
        }
        .onChange(of: state.marketKeysChangeRevision) { _, _ in
            if router.selectedSection == .extensions, state.connectionMode.isLive {
                Task { await store.refreshMarketKeys(state: state) }
            }
        }
        .onChange(of: state.marketConnectionsByServer) { _, updates in
            for (serverId, conn) in updates {
                store.marketConnections[serverId] = conn
                if store.activeOAuthServerID == serverId, conn.state != "disconnected" {
                    store.activeOAuthServerID = nil
                    store.activeOAuthStart = nil
                }
            }
        }
        .onChange(of: state.marketConnectionError) { _, message in
            if let message, !message.isEmpty {
                store.showError(message)
                store.activeOAuthServerID = nil
                store.activeOAuthStart = nil
                state.marketConnectionError = nil
            }
        }
        .sheet(item: Bindable(problemReport).settingsWindowRequest) { req in
            ProblemReportSheetView(
                request: req,
                state: state,
                daemon: daemon,
                coordinator: problemReport,
                onOpenSignIn: {
                    router.jumpTo(section: .remoteAndCloud, rowID: "remote.sync")
                }
            )
            .focusEffectDisabled()
            .environment(\.prismTokens, tokens)
            .environment(\.prismL10n, l10n)
            .environment(\.locale, state.language.resolvedLocale)
            .environment(\.prismMotionTier, state.motionTier)
            .preferredColorScheme(state.palette.colorScheme)
        }
    }

    private func deliverPendingNotice() {
        guard let text = router.pendingNotice else { return }
        router.pendingNotice = nil
        // After this update, so a section switch that clears the banners does not hide it.
        Task { @MainActor in store.showNotice(text) }
    }

    private func preload(section: PrismSettingsSection) async {
        switch section {
        case .general, .gitAndTerminal, .islandAndMenuBar:
            await store.loadHostSettings(state: state, daemon: daemon)
            if section == .general, let host = state.activeHostSession {
                if let lights = try? await host.listLightAgents() {
                    store.lightAgents = lights
                    for item in lights where !PrismSettingsStore.retiredAgentIDs.contains(item.agentId) {
                        state.ensureAgentOptionsLoaded(for: item.agentId)
                    }
                }
            }
        case .agents:
            await store.loadAgentsSection(state: state, daemon: daemon)
        case .extensions:
            await store.loadExtensionsSection(state: state, daemon: daemon)
        case .memory:
            await store.loadMemorySection(state: state)
        case .remoteAndCloud, .advanced:
            await store.loadDaemonAndRemote(state: state, daemon: daemon)
        case .updatesAndAbout:
            await store.loadUpdatesAccountStatus(state: state, daemon: daemon)
        case .appearance, .notifications:
            break
        }
    }

    // MARK: - Sidebar (macOS System Settings Style + Live Search)

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            // Search Box
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tokens.mutedForeground)
                TextField(l10n.tr("settings.searchPlaceholder"), text: $router.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(tokens.foreground)
                if !router.searchQuery.isEmpty {
                    Button {
                        router.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(tokens.mutedForeground)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6.5)
            .background(
                RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                    .fill(tokens.surface1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                    .strokeBorder(tokens.borderEtched, lineWidth: 1)
            )
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            // Grouped Navigation List
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(PrismSettingsGroup.allCases) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.title(l10n))
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(tokens.mutedForeground)
                                .textCase(.uppercase)
                                .padding(.horizontal, 10)
                                .padding(.bottom, 3)

                            ForEach(group.sections) { section in
                                sidebarRow(section)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }

            Divider().overlay(tokens.borderEtched)

            // Bottom Daemon Connection Indicator Pill (clickable to open Daemon service controls)
            Button {
                router.jumpTo(section: .advanced, rowID: "remote.daemon")
            } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(state.connectionMode.isLive ? tokens.success : tokens.warning)
                        .frame(width: 7, height: 7)
                    Text(state.connectionMode.isLive ? l10n.tr("settings.status.daemonConnected") : l10n.tr("settings.status.daemonOffline"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(tokens.secondaryForeground)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let ver = store.daemonStatus?.version {
                        Text("v\(ver)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(tokens.mutedForeground)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(tokens.mutedForeground.opacity(0.7))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(l10n.tr("settings.status.daemonOpenHelp"))
        }
        .background(tokens.sidebar)
    }

    private func sidebarRow(_ section: PrismSettingsSection) -> some View {
        let isSelected = router.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && router.selectedSection == section
        let badgeColor = section.badgeColor(tokens: tokens)
        return Button {
            router.searchQuery = ""
            router.selectedSection = section
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? badgeColor : badgeColor.opacity(0.18))
                    Image(systemName: section.symbolName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.white : badgeColor)
                }
                .frame(width: 22, height: 22)

                Text(section.title(l10n))
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? tokens.foreground : tokens.secondaryForeground)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if section == .extensions {
                    let activeCount = store.hostSettings.marketplaceMcp.filter(\.on).count
                        + (store.marketPlugins?.installed.filter(\.enabled).count ?? 0)
                    if activeCount > 0 {
                        Text("\(activeCount)")
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(tokens.mutedForeground)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(tokens.surface2))
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                    .fill(isSelected ? tokens.activeWash : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                    .strokeBorder(isSelected ? tokens.borderEtched : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail Area (Search Results OR Selected Section)

    private var detailContent: some View {
        ZStack(alignment: .top) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !router.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            searchResultsView
                        } else {
                            sectionHeader(for: router.selectedSection)
                            if state.connectionMode.isRemote && router.selectedSection.editsActiveHost {
                                remoteHostScopeBanner
                            }
                            sectionBody(for: router.selectedSection)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .background(tokens.background)
                .onChange(of: router.highlightedRowID) { _, rowID in
                    guard let rowID else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(rowID, anchor: .center)
                        }
                    }
                }
            }

            SettingsFeedbackToastOverlay(store: store, motionTier: state.motionTier)
                .zIndex(50)
        }
    }

    private func sectionHeader(for section: PrismSettingsSection) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(section.badgeColor(tokens: tokens).opacity(0.16))
                Image(systemName: section.symbolName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(section.badgeColor(tokens: tokens))
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(section.title(l10n))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tokens.foreground)
                Text(section.subtitle(l10n))
                    .font(.system(size: 12))
                    .foregroundStyle(tokens.mutedForeground)
            }

            Spacer(minLength: 8)

            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.bottom, 2)
    }

    private var searchResultsView: some View {
        let matches = searchMatches
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(l10n.tr("settings.search.resultsTitle"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tokens.foreground)
                Text(l10n.tr("settings.search.resultsCount", matches.count))
                    .font(.system(size: 12))
                    .foregroundStyle(tokens.mutedForeground)
            }

            if matches.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 24))
                        .foregroundStyle(tokens.mutedForeground)
                    Text(l10n.tr("settings.search.empty"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(tokens.secondaryForeground)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
                .prismSurface(elevation: .flat, cornerRadius: tokens.rMD)
            } else {
                SettingsCardGroup {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { idx, item in
                        if idx > 0 { SettingsRowDivider() }
                        Button {
                            router.jumpTo(section: item.section, rowID: item.rowID)
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(item.section.badgeColor(tokens: tokens).opacity(0.16))
                                    Image(systemName: item.section.symbolName)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(item.section.badgeColor(tokens: tokens))
                                }
                                .frame(width: 24, height: 24)

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(l10n.tr(item.titleKey))
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(tokens.foreground)
                                        Text(item.section.title(l10n))
                                            .font(.system(size: 10.5, weight: .medium))
                                            .foregroundStyle(tokens.mutedForeground)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1.5)
                                            .background(Capsule().fill(tokens.surface2))
                                    }
                                    if let subKey = item.subtitleKey {
                                        Text(l10n.tr(subKey))
                                            .font(.system(size: 11.5))
                                            .foregroundStyle(tokens.mutedForeground)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(tokens.mutedForeground)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var remoteHostScopeBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "network")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(tokens.prismCobalt)
            Text(l10n.tr("settings.remoteScope.banner", state.activeHostSnapshot.name))
                .font(.system(size: 12))
                .foregroundStyle(tokens.foreground)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            SettingsPillButton(l10n.tr("settings.remoteScope.switchLocal"), icon: "laptopcomputer") {
                Task {
                    _ = await state.switchActiveHost(to: SartoState.localHostID)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).fill(tokens.primarySoft))
        .overlay(
            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                .strokeBorder(tokens.prismCobalt.opacity(0.35), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func sectionBody(for section: PrismSettingsSection) -> some View {
        switch section {
        case .general:
            GeneralSettingsSectionView(state: state, daemon: daemon, island: island, store: store, router: router)
        case .appearance:
            AppearanceSettingsSectionView(state: state, router: router)
        case .islandAndMenuBar:
            IslandMenuBarSettingsSectionView(state: state, daemon: daemon, island: island, store: store, router: router)
        case .notifications:
            NotificationsSettingsSectionView(state: state, island: island, router: router)
        case .agents:
            AgentsSettingsSectionView(state: state, daemon: daemon, store: store, router: router)
        case .extensions:
            ExtensionsSettingsSectionView(state: state, daemon: daemon, store: store, router: router)
        case .memory:
            MemorySettingsSectionView(state: state, store: store, router: router)
        case .gitAndTerminal:
            GitTerminalSettingsSectionView(state: state, daemon: daemon, store: store, router: router)
        case .remoteAndCloud:
            RemoteCloudSettingsSectionView(state: state, daemon: daemon, store: store, router: router)
        case .advanced:
            AdvancedServiceSettingsSectionView(state: state, daemon: daemon, store: store, router: router)
        case .updatesAndAbout:
            UpdatesAboutSettingsSectionView(state: state, daemon: daemon, router: router)
        }
    }
}

// MARK: - Shared Native macOS Settings Chrome

struct SettingsGroupSection<Trailing: View, Content: View>: View {
    @Environment(\.prismTokens) private var tokens
    let title: String
    let trailingBadge: String?
    let trailing: () -> Trailing
    let content: () -> Content

    init(
        _ title: String,
        trailingBadge: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.trailingBadge = trailingBadge
        self.trailing = trailing
        self.content = content
    }

    init(_ title: String, trailingBadge: String? = nil, @ViewBuilder content: @escaping () -> Content) where Trailing == EmptyView {
        self.title = title
        self.trailingBadge = trailingBadge
        self.trailing = { EmptyView() }
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(tokens.mutedForeground)
                if let trailingBadge, !trailingBadge.isEmpty {
                    Text(trailingBadge)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(tokens.mutedForeground)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(tokens.surface2))
                }
                Spacer(minLength: 0)
                trailing()
            }
            .padding(.horizontal, 4)

            SettingsCardGroup(content: content)
        }
    }
}

struct SettingsCardGroup<Content: View>: View {
    @Environment(\.prismTokens) private var tokens
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: tokens.rMD, style: .continuous)
                .fill(tokens.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: tokens.rMD, style: .continuous)
                .strokeBorder(tokens.borderEtched, lineWidth: 1)
        )
    }
}

struct SettingsRowDivider: View {
    @Environment(\.prismTokens) private var tokens

    var body: some View {
        Rectangle()
            .fill(tokens.borderEtched)
            .frame(height: 1)
            .padding(.leading, 14)
    }
}

struct SettingsRowView<Control: View>: View {
    @Environment(\.prismTokens) private var tokens
    let id: String
    let highlightedID: String?
    let title: String
    let subtitle: String?
    let control: () -> Control

    init(
        id: String,
        highlightedID: String? = nil,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder control: @escaping () -> Control
    ) {
        self.id = id
        self.highlightedID = highlightedID
        self.title = title
        self.subtitle = subtitle
        self.control = control
    }

    private var isFlashing: Bool {
        highlightedID == id
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tokens.foreground)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokens.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                .fill(isFlashing ? tokens.primarySoft : Color.clear)
                .animation(.easeInOut(duration: 0.25), value: isFlashing)
        )
        .id(id)
    }
}

/// Floating glass capsule anchored at the top-center of the settings detail viewport so action
/// feedback and errors stay visible regardless of scroll offset and never shift page content.
private struct SettingsFeedbackToastOverlay: View {
    @Bindable var store: PrismSettingsStore
    let motionTier: PrismMotionTier

    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isHovered: Bool = false
    @State private var isCloseHovered: Bool = false

    private var activeToast: (id: UUID, text: String, isError: Bool)? {
        if let error = store.bannerError {
            return (store.bannerID, error, true)
        }
        if let notice = store.bannerNotice {
            return (store.bannerID, notice, false)
        }
        return nil
    }

    var body: some View {
        let motion = PrismSpringSpec.snappy.animation(tier: motionTier, reduceMotion: reduceMotion)
        let transition: AnyTransition = reduceMotion
            ? .opacity
            : .opacity.combined(with: .offset(y: -8)).combined(with: .scale(scale: 0.96))

        Group {
            if let toast = activeToast {
                toastPill(text: toast.text, isError: toast.isError, motion: motion)
                    .id(toast.id)
                    .padding(.top, 14)
                    .padding(.horizontal, 20)
                    .transition(transition)
                    .onHover { hovered in
                        withAnimation(.easeOut(duration: 0.14)) {
                            isHovered = hovered
                        }
                        store.setBannerHovered(hovered)
                    }
                    .onDisappear {
                        isHovered = false
                        isCloseHovered = false
                        store.setBannerHovered(false)
                    }
            }
        }
        .animation(motion, value: activeToast?.id)
    }

    private func toastPill(text: String, isError: Bool, motion: Animation?) -> some View {
        let accent = isError ? tokens.danger : tokens.success
        let shape = RoundedRectangle(cornerRadius: 17, style: .continuous)

        return HStack(alignment: .center, spacing: 9) {
            ZStack {
                Circle()
                    .fill(accent.opacity(tokens.palette.isDark ? 0.24 : 0.16))
                    .frame(width: 13, height: 13)
                Circle()
                    .fill(accent)
                    .frame(width: 6.5, height: 6.5)
            }
            .fixedSize()

            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tokens.foreground)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                withAnimation(motion) {
                    store.clearBanners()
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
            .opacity(isHovered || isError ? 1.0 : 0.55)
            .onHover { hovered in
                withAnimation(.easeOut(duration: 0.12)) {
                    isCloseHovered = hovered
                }
            }
            .help(l10n.tr("notice.dismiss"))
        }
        .padding(.leading, 12)
        .padding(.trailing, 7)
        .padding(.vertical, 7)
        .frame(maxWidth: 480)
        .background {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(tokens.surface1.opacity(tokens.palette.isDark ? 0.80 : 0.88))
                if isHovered {
                    shape.fill(tokens.hoverWash.opacity(0.42))
                }
            }
        }
        .overlay(
            shape.strokeBorder(
                isError
                    ? tokens.danger.opacity(isHovered ? 0.50 : 0.32)
                    : (isHovered ? tokens.borderStrong : tokens.borderEtched),
                lineWidth: 1
            )
        )
        .shadow(color: tokens.borderStrong.opacity(tokens.palette.isDark ? 0.45 : 0.22), radius: 14, y: 5)
        .shadow(color: tokens.borderStrong.opacity(tokens.palette.isDark ? 0.28 : 0.10), radius: 2, y: 1)
    }
}

struct SettingsBannerView: View {
    enum Kind { case error, success, info }
    @Environment(\.prismTokens) private var tokens
    let text: String
    let kind: Kind
    let onDismiss: (() -> Void)?

    init(text: String, kind: Kind = .info, onDismiss: (() -> Void)? = nil) {
        self.text = text
        self.kind = kind
        self.onDismiss = onDismiss
    }

    private var accentColor: Color {
        switch kind {
        case .error: return tokens.danger
        case .success: return tokens.success
        case .info: return tokens.prismCobalt
        }
    }

    private var fillColor: Color {
        switch kind {
        case .error: return tokens.dangerSoft
        case .success: return tokens.successSoft
        case .info: return tokens.primarySoft
        }
    }

    private var iconName: String {
        switch kind {
        case .error: return "exclamationmark.triangle.fill"
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 12.5))
                .foregroundStyle(accentColor)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(tokens.foreground)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(tokens.mutedForeground)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).fill(fillColor))
        .overlay(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).strokeBorder(accentColor.opacity(0.35), lineWidth: 1))
    }
}

struct SettingsPillButton: View {
    @Environment(\.prismTokens) private var tokens
    let title: String
    let icon: String?
    let prominent: Bool
    let destructive: Bool
    let disabled: Bool
    let action: () -> Void

    init(
        _ title: String,
        icon: String? = nil,
        prominent: Bool = false,
        destructive: Bool = false,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.prominent = prominent
        self.destructive = destructive
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .medium))
                }
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).fill(background))
            .overlay(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).strokeBorder(border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }

    private var foreground: Color {
        if prominent { return tokens.onPrimary }
        if destructive { return tokens.danger }
        return tokens.foreground
    }

    private var background: Color {
        if prominent { return tokens.primary }
        if destructive { return tokens.dangerSoft }
        return tokens.surface2
    }

    private var border: Color {
        if prominent { return tokens.primary }
        if destructive { return tokens.danger.opacity(0.35) }
        return tokens.borderEtched
    }
}
