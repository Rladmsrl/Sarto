import AppKit
import SartoProtocol
import PrismDesign
import SwiftUI

// MARK: - 10. Account, Cloud Sync & Multi-Device Section

struct RemoteCloudSettingsSectionView: View {
    @Bindable var state: SartoState
    @Bindable var daemon: LocalDaemonManager
    @Bindable var store: PrismSettingsStore
    @Bindable var router: PrismSettingsRouter

    @State private var recoveryKeyInput: String = ""
    @State private var pendingRemoveCloudDevice: CloudDeviceInfo? = nil

    @State private var isSubmittingSync: Bool = false
    @State private var isDisconnectingRemoteClaude: Bool = false
    @State private var busyUpdateHostIDs: Set<String> = []
    @State private var checkedRemoteHostIDs: Set<String> = []

    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var accountStatus: CloudAccountStatusInfo {
        state.cloudAccountStatus
    }

    private var accountState: CloudAccountStateInfo {
        accountStatus.account
    }

    private var syncStatus: SartoSyncStatusInfo {
        state.sartoSyncStatus
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // 1. Unified Sarto Account & E2EE Keybag v2 Sync
            SettingsGroupSection(
                l10n.tr("settings.account.title"),
                trailingBadge: syncModeBadge
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    if accountState.isSignedIn {
                        signedInAccountHeader
                        if accountState.plainText || syncStatus.plainText {
                            SettingsBannerView(text: l10n.tr("settings.account.plainTextWarning"), kind: .info)
                        }
                        if let key = daemon.pendingRecoveryKey {
                            oneTimeRecoveryKeyCard(key)
                        }
                        vaultStatePanel
                    } else {
                        unifiedSignInPanel
                    }

                    if let syncErr = syncStatus.error, !syncErr.isEmpty {
                        SettingsBannerView(text: syncErr, kind: .error)
                    }
                }
                .padding(14)
                .id("remote.sync")
            }

            // 2. Unified My Devices (Computers + Mobile signed in to the same Sarto account)
            myDevicesSection

            // 3. Local Remote Sharing Permissions (Remote Terminal + Remote Claude Code Hosting)
            SettingsGroupSection(l10n.tr("settings.remote.sharingGroup")) {
                SettingsRowView(
                    id: "remote.terminal",
                    highlightedID: router.highlightedRowID,
                    title: l10n.tr("settings.remote.terminal"),
                    subtitle: l10n.tr("settings.remote.terminalSub")
                ) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { store.remoteTerminalAllowed },
                            set: { next in
                                store.remoteTerminalAllowed = next
                                Task {
                                    do {
                                        store.remoteTerminalAllowed = try await daemon.setRemoteTerminalAllowed(next)
                                    } catch {
                                        store.showError(error.localizedDescription)
                                    }
                                }
                            }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                SettingsRowDivider()

                remoteClaudeSettingsBlock
            }
        }
        .onAppear {
            state.beginWatchingHostLoads()
        }
        .onDisappear {
            state.endWatchingHostLoads()
        }
        .onChange(of: state.cloudAccountStatus.account.state) { _, newState in
            if newState == "signed-in" {
                Task {
                    async let devicesTask = try? daemon.listAccountDevices()
                    async let syncTask = try? daemon.fetchSyncStatus()
                    _ = await (devicesTask, syncTask)
                }
            }
        }
        .task {
            let state = self.state
            let onlineRemoteHostIDs = state.allUnifiedHosts
                .filter { !$0.isLocal && $0.isOnline }
                .map(\.id)
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await state.refreshRemoteClaudeActiveRuns() }
                group.addTask { await state.refreshRemoteClaudeHosts() }
                for hostID in onlineRemoteHostIDs {
                    group.addTask { await state.refreshHostAppUpdateStatus(hostId: hostID) }
                }
            }

            // PrismSettingsWindowView's preload already fetched the initial paired-device snapshot;
            // wait one interval before polling so entering this section avoids duplicate RPCs.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { break }
                await store.refreshLiveDevicePresence(daemon: daemon)
            }
        }
        .alert(
            pendingRemoveCloudDevice.map { l10n.tr("settings.account.removeDeviceConfirmTitle", $0.name) } ?? "",
            isPresented: Binding(
                get: { pendingRemoveCloudDevice != nil },
                set: { if !$0 { pendingRemoveCloudDevice = nil } }
            ),
            presenting: pendingRemoveCloudDevice
        ) { dev in
            Button(l10n.tr("settings.account.removeDevice"), role: .destructive) {
                pendingRemoveCloudDevice = nil
                submitRemoveCloudDevice(dev)
            }
            Button(l10n.tr("settings.account.cancelSignIn"), role: .cancel) {
                pendingRemoveCloudDevice = nil
            }
        } message: { dev in
            Text(
                dev.current
                    ? l10n.tr("settings.account.removeThisDeviceConfirmBody")
                    : l10n.tr("settings.account.removeDeviceConfirmBody")
            )
        }
    }

    private var syncModeBadge: String? {
        if accountState.isSignedIn {
            switch syncStatus.keyState {
            case "ready": return l10n.tr("settings.account.badge.ready")
            case "awaiting-approval": return l10n.tr("settings.account.badge.awaiting")
            case "needs-setup": return l10n.tr("settings.account.badge.setup")
            default: return l10n.tr("settings.account.badge.signedIn")
            }
        }
        return nil
    }

    private var unifiedSignInPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l10n.tr("settings.account.subtitle"))
                .font(.system(size: 12))
                .foregroundStyle(tokens.secondaryForeground)

            if let bannerText = signInStatusMessage {
                VStack(alignment: .leading, spacing: 8) {
                    SettingsBannerView(text: bannerText, kind: .error)
                    if accountState.failure == "device-limit",
                       let rawURL = accountState.devicesUrl,
                       let url = URL(string: rawURL) {
                        SettingsPillButton(l10n.tr("settings.account.openDevicesPage"), icon: "arrow.up.right.square") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                SettingsPillButton(
                    l10n.tr("settings.account.signInBrowser"),
                    icon: "safari",
                    prominent: true,
                    disabled: isSubmittingSync || accountState.isSigningIn
                ) {
                    submitBrowserSignIn()
                }

                if accountState.isSigningIn {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(l10n.tr("settings.account.signingIn"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(tokens.mutedForeground)
                        if let rawUrl = accountStatus.authUrl, let url = URL(string: rawUrl) {
                            SettingsPillButton(
                                l10n.tr("settings.account.reopenBrowser"),
                                icon: "arrow.up.right.square",
                                disabled: isSubmittingSync
                            ) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        SettingsPillButton(
                            l10n.tr("settings.account.cancelSignIn"),
                            disabled: isSubmittingSync
                        ) {
                            submitCancelSignIn()
                        }
                    }
                }

                Spacer()
            }
        }
    }

    private var signInStatusMessage: String? {
        if let failure = accountState.failure {
            switch failure {
            case "device-limit": return l10n.tr("settings.account.failure.deviceLimit")
            case "timeout": return l10n.tr("settings.account.failure.timeout")
            case "network": return l10n.tr("settings.account.failure.network")
            case "service", "disabled": return l10n.tr("settings.account.failure.service")
            case "local": return l10n.tr("settings.account.failure.local")
            default: return failure
            }
        }
        if let reason = accountState.reason {
            switch reason {
            case "reused": return l10n.tr("settings.account.reason.reused")
            case "account-page", "admin": return l10n.tr("settings.account.reason.accountPage")
            case "expired", "invalid", "disabled": return l10n.tr("settings.account.reason.expired")
            default: return reason
            }
        }
        return nil
    }

    private var signedInAccountHeader: some View {
        let profile = accountState.account
        let displayName = (profile?.name?.isEmpty == false ? profile?.name : nil) ?? profile?.email ?? "Sarto Account"
        let initial = String(displayName.prefix(1)).uppercased()
        let manageHref = accountState.manageUrl ?? "\(accountStatus.origin)/account/"

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(tokens.primarySoft)
                        .frame(width: 38, height: 38)
                    Text(initial)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(tokens.primary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(tokens.foreground)
                    if let email = profile?.email, !email.isEmpty {
                        Text(email)
                            .font(.system(size: 11.5))
                            .foregroundStyle(tokens.secondaryForeground)
                    }
                }

                Spacer()
            }

            HStack(spacing: 8) {
                if let consoleURL = URL(string: "\(accountStatus.origin)/console/") {
                    SettingsPillButton(l10n.tr("settings.account.openConsole"), icon: "macwindow", prominent: true) {
                        NSWorkspace.shared.open(consoleURL)
                    }
                }
                if let url = URL(string: manageHref) {
                    SettingsPillButton(l10n.tr("settings.account.manageAccount"), icon: "arrow.up.right.square") {
                        NSWorkspace.shared.open(url)
                    }
                }
                SettingsPillButton(l10n.tr("settings.account.checkStatus"), icon: "arrow.clockwise", disabled: isSubmittingSync) {
                    Task {
                        isSubmittingSync = true
                        defer { isSubmittingSync = false }
                        _ = try? await daemon.checkAccount()
                        _ = try? await daemon.listAccountDevices()
                        _ = try? await daemon.fetchSyncStatus()
                    }
                }
                Spacer()
                SettingsPillButton(l10n.tr("settings.account.signOut"), destructive: true, disabled: isSubmittingSync) {
                    submitSignOut()
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: tokens.rSM).fill(tokens.surface2))
        .overlay(RoundedRectangle(cornerRadius: tokens.rSM).strokeBorder(tokens.borderEtched, lineWidth: 1))
    }

    private func oneTimeRecoveryKeyCard(_ key: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tokens.warning)
                Text(l10n.tr("settings.vault.recoveryKeyTitle"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tokens.foreground)
            }

            Text(l10n.tr("settings.vault.recoveryKeyBody"))
                .font(.system(size: 11.5))
                .foregroundStyle(tokens.secondaryForeground)

            Text(key)
                .font(.system(size: 13.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(tokens.foreground)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: tokens.rXS).fill(tokens.codeBackground))
                .overlay(RoundedRectangle(cornerRadius: tokens.rXS).strokeBorder(tokens.warning.opacity(0.6), lineWidth: 1))

            HStack(spacing: 8) {
                SettingsPillButton(l10n.tr("settings.vault.copyRecoveryKey"), icon: "doc.on.doc", prominent: true) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(key, forType: .string)
                    store.showNotice(l10n.tr("settings.common.copied"))
                }
                Spacer()
                SettingsPillButton(l10n.tr("settings.vault.savedRecoveryKey"), icon: "checkmark") {
                    daemon.pendingRecoveryKey = nil
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: tokens.rSM).fill(tokens.primarySoft.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: tokens.rSM).strokeBorder(tokens.warning.opacity(0.5), lineWidth: 1))
    }

    @ViewBuilder
    private var vaultStatePanel: some View {
        switch syncStatus.keyState {
        case "needs-setup":
            vaultSetupCard
        case "awaiting-approval":
            vaultAwaitingApprovalCard
        case "ready":
            VStack(alignment: .leading, spacing: 10) {
                if !syncStatus.pendingApprovals.isEmpty {
                    pendingApprovalsCard
                }
                activeSyncStatusBanner
            }
        default:
            if syncStatus.mode != "off" {
                activeSyncStatusBanner
            }
        }
    }

    private var vaultSetupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(tokens.primary)
                Text(l10n.tr("settings.vault.setupTitle"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tokens.foreground)
            }
            Text(l10n.tr("settings.vault.setupBody"))
                .font(.system(size: 11.5))
                .foregroundStyle(tokens.secondaryForeground)
            SettingsPillButton(
                l10n.tr("settings.vault.setupBtn"),
                icon: "lock.shield",
                prominent: true,
                disabled: isSubmittingSync
            ) {
                submitSetupVault()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: tokens.rSM).fill(tokens.surface2))
        .overlay(RoundedRectangle(cornerRadius: tokens.rSM).strokeBorder(tokens.borderEtched, lineWidth: 1))
    }

    private var vaultAwaitingApprovalCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(l10n.tr("settings.vault.awaitingTitle"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tokens.foreground)
            }

            Text(awaitingApprovalMessage)
                .font(.system(size: 11.5))
                .foregroundStyle(tokens.secondaryForeground)

            if let code = syncStatus.approvalCode, !code.isEmpty {
                Text(code)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(tokens.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: tokens.rXS).fill(tokens.primarySoft.opacity(0.6)))
                    .overlay(RoundedRectangle(cornerRadius: tokens.rXS).strokeBorder(tokens.primary.opacity(0.45), lineWidth: 1))
            }

            if syncStatus.approvalStage == "confirm" {
                HStack(spacing: 8) {
                    Spacer()
                    SettingsPillButton(
                        l10n.tr("settings.vault.codesDifferBtn"),
                        destructive: true,
                        disabled: isSubmittingSync
                    ) {
                        submitConfirmApproval(matches: false)
                    }
                    SettingsPillButton(
                        l10n.tr("settings.vault.codesMatchBtn"),
                        icon: "checkmark.shield",
                        prominent: true,
                        disabled: isSubmittingSync
                    ) {
                        submitConfirmApproval(matches: true)
                    }
                }
            }

            SettingsRowDivider()

            VStack(alignment: .leading, spacing: 6) {
                Text(l10n.tr("settings.vault.orRecoveryTitle"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(tokens.mutedForeground)
                HStack(spacing: 8) {
                    TextField(l10n.tr("settings.vault.recoveryPlaceholder"), text: $recoveryKeyInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: tokens.rXS).fill(tokens.codeBackground))
                        .overlay(RoundedRectangle(cornerRadius: tokens.rXS).strokeBorder(tokens.borderEtched, lineWidth: 1))

                    SettingsPillButton(
                        l10n.tr("settings.vault.unlockBtn"),
                        icon: "key",
                        prominent: true,
                        disabled: isSubmittingSync || recoveryKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ) {
                        submitUnlockRecovery()
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: tokens.rSM).fill(tokens.surface2))
        .overlay(RoundedRectangle(cornerRadius: tokens.rSM).strokeBorder(tokens.borderEtched, lineWidth: 1))
    }

    /// What the waiting Mac asks of the user at each step of its approval.
    private var awaitingApprovalMessage: String {
        let approver = syncStatus.approverName.flatMap { $0.isEmpty ? nil : $0 }
            ?? l10n.tr("settings.vault.anotherMac")
        switch syncStatus.approvalStage {
        case "confirm": return l10n.tr("settings.vault.confirmCodeBody", approver)
        case "confirmed": return l10n.tr("settings.vault.confirmedBody", approver)
        default: return l10n.tr("settings.vault.awaitingBody")
        }
    }

    private var pendingApprovalsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(tokens.primary)
                Text(l10n.tr("settings.vault.pendingApprovalsTitle"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tokens.foreground)
            }
            Text(l10n.tr("settings.vault.pendingApprovalsBody"))
                .font(.system(size: 11.5))
                .foregroundStyle(tokens.secondaryForeground)

            ForEach(syncStatus.pendingApprovals) { req in
                HStack(spacing: 12) {
                    Image(systemName: req.platform.lowercased().contains("ios") ? "iphone" : "laptopcomputer")
                        .font(.system(size: 16))
                        .foregroundStyle(tokens.primary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(req.deviceName)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(tokens.foreground)
                        Text(req.platform)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(tokens.mutedForeground)
                    }
                    Spacer()
                    Text(req.code)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(tokens.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: tokens.rXS).fill(tokens.background.opacity(0.8)))
                    SettingsPillButton(l10n.tr("settings.vault.rejectBtn"), destructive: true, disabled: isSubmittingSync) {
                        submitRejectDevice(req)
                    }
                    SettingsPillButton(l10n.tr("settings.vault.approveBtn"), prominent: true, disabled: isSubmittingSync) {
                        submitApproveDevice(req)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: tokens.rXS).fill(tokens.background.opacity(0.65)))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: tokens.rSM).fill(tokens.primarySoft.opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: tokens.rSM).strokeBorder(tokens.primary.opacity(0.45), lineWidth: 1))
    }

    /// What sync carries, in the words a user knows, with the scope or record each one is.
    /// Scopes the Mac app does not create (`skills`, `themes`) only show when already populated.
    private var syncCategories: [(icon: String, titleKey: String, scope: String)] {
        let all: [(icon: String, titleKey: String, scope: String)] = [
            ("paintbrush", "settings.sync.cat.prefs", "ui-prefs"),
            ("cpu", "settings.sync.cat.agents", "host-config"),
            ("server.rack", "settings.sync.cat.mcp", "mcp-servers"),
            ("key", "settings.sync.cat.vault", "mcp-vault"),
            ("sparkles", "settings.sync.cat.skills", "skills"),
            ("paintpalette", "settings.sync.cat.themes", "themes"),
            ("brain", "settings.sync.cat.memory", "memory-and-mesh"),
            ("chart.bar", "settings.sync.cat.usage", "usage"),
        ]
        return all.filter { item in
            if item.scope == "skills" || item.scope == "themes" {
                return (syncStatus.revisions[item.scope] ?? 0) > 0
            }
            return true
        }
    }

    private var activeSyncStatusBanner: some View {
        let online = syncStatus.connected || syncStatus.syncing
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: online ? "lock.icloud.fill" : "icloud.slash")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(online ? tokens.success : tokens.warning)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(l10n.tr("settings.sync.title"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(tokens.foreground)
                    Text(syncSubtitleSummary())
                        .font(.system(size: 11))
                        .foregroundStyle(online ? tokens.mutedForeground : tokens.warning)
                }

                Spacer()

                SettingsPillButton(
                    syncStatus.syncing ? l10n.tr("settings.remote.syncingNow") : l10n.tr("settings.remote.syncNow"),
                    icon: "arrow.triangle.2.circlepath",
                    disabled: syncStatus.syncing || isSubmittingSync
                ) {
                    Task {
                        do {
                            let st = try await daemon.syncNow()
                            if let err = st.error, !err.isEmpty {
                                store.showError(err)
                            } else {
                                store.showNotice(l10n.tr("settings.remote.syncedNotice"))
                            }
                        } catch {
                            store.showError(error.localizedDescription)
                        }
                    }
                }

                if syncStatus.mode != "account" {
                    SettingsPillButton(l10n.tr("settings.disconnect"), destructive: true, disabled: isSubmittingSync) {
                        Task {
                            do {
                                _ = try await daemon.disconnectSync()
                                store.showNotice(l10n.tr("settings.remote.syncDisconnected"))
                            } catch {
                                store.showError(error.localizedDescription)
                            }
                        }
                    }
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(syncCategories, id: \.scope) { category in
                    syncCategoryTile(icon: category.icon, title: l10n.tr(category.titleKey), state: syncCategoryState(category.scope))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                syncFootnote(icon: "lock", text: l10n.tr("settings.sync.encryptedNote"))
                syncFootnote(icon: "hand.raised", text: l10n.tr("settings.sync.notSyncedNote"))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: tokens.rSM).fill(tokens.surface2))
        .overlay(RoundedRectangle(cornerRadius: tokens.rSM).strokeBorder(tokens.borderEtched, lineWidth: 1))
    }

    /// Whether a category holds anything yet, said plainly; usage counts the Macs it covers.
    private func syncCategoryState(_ scope: String) -> (text: String, synced: Bool) {
        if scope == "usage" {
            let macs = syncStatus.usageDevices.count
            return macs > 0
                ? (l10n.tr("settings.vault.usageMacsBadge", macs), true)
                : (l10n.tr("settings.sync.state.empty"), false)
        }
        return (syncStatus.revisions[scope] ?? 0) > 0
            ? (l10n.tr("settings.sync.state.synced"), true)
            : (l10n.tr("settings.sync.state.empty"), false)
    }

    private func syncCategoryTile(icon: String, title: String, state: (text: String, synced: Bool)) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tokens.secondaryForeground)
                .frame(width: 18)
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(tokens.foreground)
                .lineLimit(1)
            Spacer(minLength: 4)
            HStack(spacing: 3) {
                if state.synced {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                }
                Text(state.text)
                    .font(.system(size: 10.5))
                    .lineLimit(1)
            }
            .foregroundStyle(state.synced ? tokens.success : tokens.mutedForeground)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: tokens.rXS).fill(tokens.background.opacity(0.6)))
    }

    private func syncFootnote(icon: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .medium))
            Text(text)
                .font(.system(size: 10.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(tokens.mutedForeground)
    }

    private struct MyComputerEntry: Identifiable {
        let id: String
        let name: String
        let symbolName: String
        let version: String?
        let isLocal: Bool
        let host: UnifiedHostSnapshot?
        let cloudDevice: CloudDeviceInfo?
    }

    private func isMobileCloudDevice(_ dev: CloudDeviceInfo) -> Bool {
        let kind = dev.kind.lowercased()
        let os = dev.os.lowercased()
        return kind == "ios" || kind == "mobile" || os.contains("ios") || os.contains("ipad") || os.contains("android")
    }

    private var myComputerEntries: [MyComputerEntry] {
        var matchedCloudIDs: Set<String> = []
        var entries: [MyComputerEntry] = []

        for host in state.allUnifiedHosts {
            let matchedCloud: CloudDeviceInfo? = {
                guard accountState.isSignedIn else { return nil }
                if host.isLocal {
                    return daemon.accountDevices.first { $0.current && !isMobileCloudDevice($0) }
                }
                return daemon.accountDevices.first { dev in
                    guard !dev.current, !isMobileCloudDevice(dev), !matchedCloudIDs.contains(dev.id) else {
                        return false
                    }
                    let cleanDev = SartoState.cleanHostDisplayName(dev.name)
                    return cleanDev.caseInsensitiveCompare(host.name) == .orderedSame
                        || dev.name.caseInsensitiveCompare(host.fullName) == .orderedSame
                }
            }()
            if let matchedCloud {
                matchedCloudIDs.insert(matchedCloud.id)
            }
            let resolvedVersion: String? = {
                if !host.version.isEmpty && host.version != "0.0.0" { return host.version }
                if let cv = matchedCloud?.version, !cv.isEmpty { return cv }
                return host.version.isEmpty ? nil : host.version
            }()
            entries.append(
                MyComputerEntry(
                    id: host.id,
                    name: host.name,
                    symbolName: host.deviceSymbolName,
                    version: resolvedVersion,
                    isLocal: host.isLocal,
                    host: host,
                    cloudDevice: matchedCloud
                )
            )
        }

        if accountState.isSignedIn {
            for dev in daemon.accountDevices where !isMobileCloudDevice(dev) && !matchedCloudIDs.contains(dev.id) {
                let clean = SartoState.cleanHostDisplayName(dev.name)
                entries.append(
                    MyComputerEntry(
                        id: "cloud:\(dev.id)",
                        name: clean,
                        symbolName: cloudDeviceIconName(dev),
                        version: dev.version,
                        isLocal: dev.current,
                        host: nil,
                        cloudDevice: dev
                    )
                )
            }
        }
        return entries
    }

    private var myMobileDevices: [CloudDeviceInfo] {
        guard accountState.isSignedIn else { return [] }
        return daemon.accountDevices.filter { isMobileCloudDevice($0) }
    }

    private func myDevicesSectionBadge(computerCount: Int, mobileCount: Int) -> String {
        if accountState.isSignedIn && mobileCount > 0 {
            return l10n.tr("settings.myDevices.badgeComputersAndMobile", computerCount, mobileCount)
        }
        return l10n.tr("settings.myDevices.badgeComputersOnly", computerCount)
    }

    @ViewBuilder
    private var myDevicesSection: some View {
        let computers = myComputerEntries
        let mobiles = myMobileDevices
        let mobilePairedCandidates = store.pairedDevices.filter { isMobilePairedDevice($0) }
        let remoteClaudeSelectableByHostID: [String: Bool] = {
            var map: [String: Bool] = [:]
            for item in state.remoteClaudeHosts where item.status.enabled {
                if map[item.hostId] == nil {
                    map[item.hostId] = item.status.isSelectable
                }
            }
            return map
        }()

        SettingsGroupSection(
            l10n.tr("settings.myDevices.title"),
            trailingBadge: myDevicesSectionBadge(computerCount: computers.count, mobileCount: mobiles.count)
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text(l10n.tr("settings.myDevices.sub"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(tokens.mutedForeground)

                VStack(alignment: .leading, spacing: 7) {
                    Text(l10n.tr("settings.myDevices.computersHeader"))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(tokens.mutedForeground)

                    VStack(spacing: 6) {
                        ForEach(computers) { entry in
                            let remoteClaudeSelectable = entry.host.flatMap { remoteClaudeSelectableByHostID[$0.id] }
                            myComputerRow(entry, remoteClaudeSelectable: remoteClaudeSelectable)
                        }
                    }
                }
                .id("remote.mesh")

                if accountState.isSignedIn {
                    SettingsRowDivider()

                    VStack(alignment: .leading, spacing: 7) {
                        Text(l10n.tr("settings.myDevices.mobileHeader"))
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(tokens.mutedForeground)

                        if mobiles.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "iphone")
                                    .font(.system(size: 13))
                                    .foregroundStyle(tokens.mutedForeground)
                                    .frame(width: 22)
                                Text(l10n.tr("settings.myDevices.noMobileHint"))
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(tokens.mutedForeground)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: tokens.rXS).fill(tokens.surface2.opacity(0.65)))
                        } else {
                            VStack(spacing: 6) {
                                ForEach(mobiles) { dev in
                                    myMobileRow(
                                        dev,
                                        pairedCandidates: mobilePairedCandidates,
                                        mobileCount: mobiles.count
                                    )
                                }
                            }
                        }
                    }

                    Text(l10n.tr("settings.myDevices.signedInFootnote"))
                        .font(.system(size: 11))
                        .foregroundStyle(tokens.mutedForeground)
                } else {
                    Text(l10n.tr("settings.myDevices.signedOutFootnote"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokens.mutedForeground)
                }
            }
            .padding(14)
            .id("remote.devices")
        }
    }

    private func cloudDeviceIconName(_ dev: CloudDeviceInfo) -> String {
        let lowerOS = dev.os.lowercased()
        let lowerName = dev.name.lowercased()
        let lowerKind = dev.kind.lowercased()
        if lowerOS.contains("ipad") || lowerName.contains("ipad") { return "ipad" }
        if lowerOS.contains("ios") || lowerKind == "ios" || lowerKind == "mobile" || lowerName.contains("iphone") {
            return "iphone"
        }
        switch lowerKind {
        case "cli": return "terminal"
        case "daemon":
            if lowerName.contains("mini") { return "macmini" }
            if lowerName.contains("studio") { return "macstudio" }
            if lowerName.contains("imac") { return "desktopcomputer" }
            if lowerOS.contains("mac") || lowerOS.contains("darwin") { return "laptopcomputer" }
            return "server.rack"
        default:
            if lowerName.contains("mini") { return "macmini" }
            if lowerName.contains("studio") { return "macstudio" }
            if lowerName.contains("imac") { return "desktopcomputer" }
            return "laptopcomputer"
        }
    }

    @MainActor
    private static let abbreviatedRelativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    @MainActor
    private static let fullRelativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private func cloudDeviceSubtitle(_ dev: CloudDeviceInfo, overrideLastUsedMs: Double? = nil, hideTimestamp: Bool = false) -> String {
        let base = [dev.os, dev.arch].filter { !$0.isEmpty }.joined(separator: " · ")
        guard !hideTimestamp else { return base }
        let ts = max(dev.lastUsedAt, overrideLastUsedMs ?? 0)
        if ts > 0 {
            let date = Date(timeIntervalSince1970: ts / 1000.0)
            let formatter = Self.abbreviatedRelativeFormatter
            if formatter.locale != locale {
                formatter.locale = locale
            }
            let rel = formatter.localizedString(for: date, relativeTo: Date())
            return base.isEmpty ? rel : "\(base) · \(rel)"
        }
        return base
    }

    private func syncSubtitleSummary() -> String {
        if syncStatus.syncing {
            return l10n.tr("settings.remote.syncingNow")
        }
        if !syncStatus.connected {
            return l10n.tr("settings.sync.offline")
        }
        guard let ts = syncStatus.lastSyncedAt, ts > 0 else {
            return l10n.tr("settings.sync.notYet")
        }
        let date = Date(timeIntervalSince1970: ts / 1000.0)
        // Seconds-old syncs read as "just now" rather than a count of seconds.
        let rel: String
        if Date().timeIntervalSince(date) < 60 {
            rel = l10n.tr("settings.sync.justNow")
        } else {
            let formatter = Self.fullRelativeFormatter
            if formatter.locale != locale {
                formatter.locale = locale
            }
            rel = formatter.localizedString(for: date, relativeTo: Date())
        }
        return l10n.tr("settings.sync.lastSynced", rel)
    }

    private func submitBrowserSignIn() {
        isSubmittingSync = true
        Task {
            defer { isSubmittingSync = false }
            do {
                let acc = try await daemon.signInAccount(serverUrl: nil, openBrowser: false)
                state.applyAccountStatus(acc)
                if let rawUrl = acc.authUrl, let url = URL(string: rawUrl) {
                    NSWorkspace.shared.open(url)
                }
            } catch {
                store.showError(error.localizedDescription)
            }
        }
    }

    private func submitCancelSignIn() {
        isSubmittingSync = true
        Task {
            defer { isSubmittingSync = false }
            do {
                let acc = try await daemon.cancelSignInAccount()
                state.applyAccountStatus(acc)
            } catch {
                store.showError(error.localizedDescription)
            }
        }
    }

    private func submitSignOut() {
        isSubmittingSync = true
        Task {
            defer { isSubmittingSync = false }
            do {
                let acc = try await daemon.signOutAccount()
                state.applyAccountStatus(acc)
                store.showNotice(l10n.tr("settings.account.signedOutNotice"))
            } catch {
                store.showError(error.localizedDescription)
            }
        }
    }

    private func submitSetupVault() {
        isSubmittingSync = true
        Task {
            defer { isSubmittingSync = false }
            do {
                let res = try await daemon.setupSyncVault()
                if let key = res.recoveryKey {
                    daemon.pendingRecoveryKey = key
                    store.showNotice(l10n.tr("settings.remote.syncedNotice"))
                } else {
                    // Another Mac set up this account first; this Mac now waits for its approval.
                    store.showNotice(l10n.tr("settings.vault.joinExistingNotice"))
                }
            } catch {
                store.showError(error.localizedDescription)
            }
        }
    }

    private func submitUnlockRecovery() {
        let key = recoveryKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        isSubmittingSync = true
        Task {
            defer { isSubmittingSync = false }
            do {
                _ = try await daemon.unlockSyncRecovery(recoveryKey: key)
                recoveryKeyInput = ""
                store.showNotice(l10n.tr("settings.vault.unlockedNotice"))
            } catch {
                store.showError(error.localizedDescription)
            }
        }
    }

    private func submitConfirmApproval(matches: Bool) {
        isSubmittingSync = true
        Task {
            defer { isSubmittingSync = false }
            do {
                _ = try await daemon.confirmSyncApproval(matches: matches)
                if !matches {
                    store.showNotice(l10n.tr("settings.vault.codesDifferNotice"))
                }
            } catch {
                store.showError(error.localizedDescription)
            }
        }
    }

    private func submitApproveDevice(_ req: SyncPendingApprovalInfo) {
        isSubmittingSync = true
        Task {
            defer { isSubmittingSync = false }
            do {
                _ = try await daemon.approveSyncDevice(deviceId: req.deviceId)
                store.showNotice(l10n.tr("settings.vault.approvedNotice", req.deviceName))
            } catch {
                store.showError(error.localizedDescription)
            }
        }
    }

    private func submitRejectDevice(_ req: SyncPendingApprovalInfo) {
        isSubmittingSync = true
        Task {
            defer { isSubmittingSync = false }
            do {
                _ = try await daemon.rejectSyncDevice(deviceId: req.deviceId)
                store.showNotice(l10n.tr("settings.vault.rejectedNotice", req.deviceName))
            } catch {
                store.showError(error.localizedDescription)
            }
        }
    }

    /// Whether Claude Code is ready on this computer; while another host is in front, `state.agents`
    /// are that host's, so the local host's pooled list is read instead.
    private var localClaudeReadyForHosting: Bool {
        let agents = state.activeHostID == SartoState.localHostID
            ? state.agents
            : (state.hostPool[SartoState.localHostID]?.agents ?? [])
        guard let claude = agents.first(where: { $0.id == "claude-code" }) else { return false }
        let usableState = claude.state == "ready" || claude.state == "available"
        return usableState && claude.signIn != "required"
    }

    /// The presets, and the current value where it is none of them, so the control always shows it.
    private static func choices(_ presets: [Int], current: Int) -> [Int] {
        presets.contains(current) ? presets : (presets + [current]).sorted()
    }

    /// Shows the change at once, then makes it on this computer's daemon.
    private func setRemoteClaude(_ field: String, _ value: JSONValue, change: (inout HostSettingsSnapshot) -> Void) {
        let previous = store.localHostSettings
        change(&store.localHostSettings)
        Task {
            await store.patchLocalRemoteClaude([field: value], previous: previous, state: state, daemon: daemon)
            await state.refreshRemoteClaudeActiveRuns()
        }
    }

    @ViewBuilder
    private var remoteClaudeSettingsBlock: some View {
        let local = store.localHostSettings
        let enabled = local.remoteClaudeEnabled
        let motion = PrismSpringSpec.snappy.animation(tier: state.motionTier, reduceMotion: reduceMotion)

        VStack(alignment: .leading, spacing: 0) {
            SettingsRowView(
                id: "remote.claude",
                highlightedID: router.highlightedRowID,
                title: l10n.tr("settings.remote.claudeTitle"),
                subtitle: l10n.tr("settings.remote.claudeSub")
            ) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { store.localHostSettings.remoteClaudeEnabled },
                        set: { next in
                            withAnimation(motion) {
                                setRemoteClaude("enabled", .bool(next)) { $0.remoteClaudeEnabled = next }
                            }
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            if enabled {
                if !localClaudeReadyForHosting {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11.5))
                            .foregroundStyle(tokens.warning)
                        Text(l10n.tr("settings.remote.claudeNeedsAuthHint"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(tokens.secondaryForeground)
                        Spacer(minLength: 8)
                        SettingsPillButton(l10n.tr("settings.remote.claudeOpenAgents")) {
                            router.jumpTo(section: .agents, rowID: "agents.list")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                            .fill(tokens.warningSoft)
                    )
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                }

                SettingsRowDivider()

                SettingsRowView(
                    id: "remote.claude.maxConcurrent",
                    highlightedID: router.highlightedRowID,
                    title: l10n.tr("settings.remote.claudeMaxConcurrent")
                ) {
                    Picker(
                        "",
                        selection: Binding(
                            get: { store.localHostSettings.remoteClaudeMaxConcurrent },
                            set: { next in
                                setRemoteClaude("maxConcurrent", .number(Double(next))) {
                                    $0.remoteClaudeMaxConcurrent = next
                                }
                            }
                        )
                    ) {
                        ForEach(Self.choices([1, 2, 3, 5], current: local.remoteClaudeMaxConcurrent), id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }

                SettingsRowDivider()

                SettingsRowView(
                    id: "remote.claude.idleMinutes",
                    highlightedID: router.highlightedRowID,
                    title: l10n.tr("settings.remote.claudeIdleMinutes")
                ) {
                    Picker(
                        "",
                        selection: Binding(
                            get: { store.localHostSettings.remoteClaudeIdleMinutes },
                            set: { next in
                                setRemoteClaude("idleMinutes", .number(Double(next))) {
                                    $0.remoteClaudeIdleMinutes = next
                                }
                            }
                        )
                    ) {
                        ForEach(Self.choices([5, 10, 30], current: local.remoteClaudeIdleMinutes), id: \.self) { mins in
                            Text(l10n.tr("settings.remote.claudeMinutesFormat", mins)).tag(mins)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }

                if !state.remoteClaudeActiveRuns.isEmpty {
                    let devices = Array(Set(state.remoteClaudeActiveRuns.map(\.deviceName))).sorted().joined(separator: ", ")
                    SettingsRowDivider()
                    SettingsRowView(
                        id: "remote.claude.active",
                        highlightedID: router.highlightedRowID,
                        title: l10n.tr("settings.remote.claudeActiveTitle"),
                        subtitle: "\(l10n.tr("settings.remote.claudeActiveCount", state.remoteClaudeActiveRuns.count)) · \(devices)"
                    ) {
                        SettingsPillButton(
                            l10n.tr("settings.remote.claudeDisconnectAll"),
                            icon: "xmark.circle",
                            destructive: true,
                            disabled: isDisconnectingRemoteClaude
                        ) {
                            isDisconnectingRemoteClaude = true
                            Task {
                                defer { isDisconnectingRemoteClaude = false }
                                do {
                                    let closed = try await state.disconnectAllRemoteClaudeRuns()
                                    store.showNotice(l10n.tr("settings.remote.claudeDisconnectedNotice", closed))
                                } catch {
                                    store.showError(error.localizedDescription)
                                }
                            }
                        }
                    }
                }
            }
        }
        .animation(motion, value: enabled)
    }

    @ViewBuilder
    private func myComputerRow(_ entry: MyComputerEntry, remoteClaudeSelectable: Bool?) -> some View {
        let host = entry.host
        let isVisible = host.map { state.isHostVisible($0.id) } ?? true
        let isOnline = host?.isOnline ?? false
        let isConnecting = host?.isConnecting ?? false
        let dotColor: Color = isOnline
            ? (entry.isLocal ? tokens.success : tokens.prismCobalt)
            : (isConnecting ? tokens.warning : tokens.placeholder.opacity(0.6))
        let updateMeta: (detail: String?, detailColor: Color, error: String?) = {
            if entry.isLocal { return (nil, tokens.mutedForeground, nil) }
            guard let host else { return (nil, tokens.mutedForeground, nil) }
            return remoteUpdateMeta(for: host)
        }()
        let subtitleParts: [String] = {
            var parts: [String] = []
            if entry.isLocal {
                parts.append(isOnline ? l10n.tr("settings.remote.online") : l10n.tr("sidebar.host.offline"))
                if let dev = entry.cloudDevice {
                    if !dev.os.isEmpty { parts.append(dev.os) }
                    if !dev.arch.isEmpty { parts.append(dev.arch) }
                }
                if let host, host.isOnline && host.isLoaded {
                    parts.append(l10n.tr("settings.remote.sessionCount", host.sessions.count))
                }
            } else if let host, host.isOnline {
                let route = host.viaRelay ? l10n.tr("sidebar.host.relay") : l10n.tr("sidebar.host.direct")
                parts.append(l10n.tr("settings.remote.online"))
                parts.append(route)
                if let os = entry.cloudDevice?.os, !os.isEmpty { parts.append(os) }
                if isVisible && host.isLoaded {
                    parts.append(l10n.tr("settings.remote.sessionCount", host.sessions.count))
                } else if !isVisible {
                    parts.append(l10n.tr("settings.remote.hiddenInSidebar"))
                }
            } else if isConnecting {
                parts.append(l10n.tr("sidebar.host.connecting"))
                if let os = entry.cloudDevice?.os, !os.isEmpty { parts.append(os) }
            } else {
                parts.append(l10n.tr("sidebar.host.offline"))
                if let dev = entry.cloudDevice {
                    let meta = cloudDeviceSubtitle(dev)
                    if !meta.isEmpty { parts.append(meta) }
                }
                if host != nil && !isVisible {
                    parts.append(l10n.tr("settings.remote.hiddenInSidebar"))
                }
            }
            return parts
        }()

        let hostLoad: HostLoad? = {
            if entry.isLocal {
                return state.hostLoad(for: nil)
            }
            if let host, host.isOnline {
                return state.hostLoad(for: host.id)
            }
            return nil
        }()

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: entry.symbolName)
                        .font(.system(size: 13.5))
                        .foregroundStyle(
                            isVisible
                                ? (isOnline || entry.isLocal ? tokens.foreground : tokens.mutedForeground)
                                : tokens.placeholder
                        )
                        .frame(width: 24, height: 24)
                    Circle()
                        .fill(dotColor)
                        .frame(width: 6.5, height: 6.5)
                        .overlay(Circle().strokeBorder(tokens.surface2, lineWidth: 1.2))
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.name)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(isVisible ? tokens.foreground : tokens.mutedForeground)
                            .lineLimit(1)
                        if let ver = entry.version, !ver.isEmpty {
                            Text("v\(ver)")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(tokens.mutedForeground)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(tokens.surface3))
                        }
                        if entry.isLocal {
                            Text(l10n.tr("settings.account.thisDevice"))
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(tokens.primary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(tokens.primarySoft))
                        } else if let isSelectable = remoteClaudeSelectable {
                            HStack(spacing: 3) {
                                Circle()
                                    .fill(isSelectable ? tokens.prismCobalt : tokens.warning)
                                    .frame(width: 5, height: 5)
                                Text(l10n.tr("settings.remote.claudeDeviceBadge"))
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(tokens.prismCobalt)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(tokens.prismCobalt.opacity(0.14)))
                        }
                    }
                    HStack(spacing: 5) {
                        Text(subtitleParts.joined(separator: " · "))
                        if let detail = updateMeta.detail {
                            Text("· \(detail)")
                                .foregroundStyle(updateMeta.detailColor)
                        }
                    }
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(tokens.mutedForeground)
                    .lineLimit(1)

                    if let err = updateMeta.error, !err.isEmpty {
                        Text(err)
                            .font(.system(size: 10.5))
                            .foregroundStyle(tokens.danger)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    if entry.isLocal {
                        Text(l10n.tr("settings.remote.alwaysShown"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(tokens.mutedForeground)
                            .fixedSize()
                    } else {
                        if let host, host.isOnline {
                            remoteUpdateControl(for: host)
                        }
                        if let host {
                            Toggle(
                                "",
                                isOn: Binding(
                                    get: { state.isHostVisible(host.id) },
                                    set: { next in
                                        Task { await state.setHostVisible(host.id, visible: next) }
                                    }
                                )
                            )
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .help(l10n.tr("settings.remote.toggleVisibilityHint"))
                        }
                        if let dev = entry.cloudDevice {
                            SettingsPillButton(
                                l10n.tr("settings.myDevices.removeShort"),
                                destructive: true,
                                disabled: isSubmittingSync
                            ) {
                                pendingRemoveCloudDevice = dev
                            }
                        }
                    }
                }
            }

            if let hostLoad {
                Rectangle()
                    .fill(tokens.borderEtched)
                    .frame(height: 1)
                HostLoadMetersView(load: hostLoad)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: tokens.rXS).fill(tokens.surface2))
        .opacity(isVisible ? 1.0 : 0.72)
    }

    private func isMobilePairedDevice(_ device: PairedDeviceSummary) -> Bool {
        let kind = device.kind.lowercased()
        let platform = device.platform.lowercased()
        return kind == "ios" || kind == "mobile" || kind == "iphone" || kind == "ipad"
            || platform.contains("ios") || platform.contains("ipad") || platform.contains("iphone")
    }

    private func matchedPairedMobile(
        for dev: CloudDeviceInfo,
        candidates: [PairedDeviceSummary],
        mobileCount: Int
    ) -> PairedDeviceSummary? {
        if let exact = candidates.first(where: { $0.connected && $0.name.caseInsensitiveCompare(dev.name) == .orderedSame }) {
            return exact
        }
        if let exactAny = candidates.first(where: { $0.name.caseInsensitiveCompare(dev.name) == .orderedSame }) {
            return exactAny
        }
        if let fuzzyConnected = candidates.first(where: {
            $0.connected && ($0.name.localizedCaseInsensitiveContains(dev.name) || dev.name.localizedCaseInsensitiveContains($0.name))
        }) {
            return fuzzyConnected
        }
        if candidates.count == 1 && mobileCount == 1 {
            return candidates.first
        }
        return candidates.first(where: {
            $0.name.localizedCaseInsensitiveContains(dev.name) || dev.name.localizedCaseInsensitiveContains($0.name)
        })
    }

    @ViewBuilder
    private func myMobileRow(
        _ dev: CloudDeviceInfo,
        pairedCandidates: [PairedDeviceSummary],
        mobileCount: Int
    ) -> some View {
        let paired = matchedPairedMobile(for: dev, candidates: pairedCandidates, mobileCount: mobileCount)
        let isOnline = paired?.connected == true
        let dotColor: Color = isOnline ? tokens.success : tokens.placeholder.opacity(0.6)
        let meta = cloudDeviceSubtitle(dev, overrideLastUsedMs: paired?.lastConnectedAt, hideTimestamp: isOnline)
        let statusPrefix = isOnline ? l10n.tr("settings.remote.online") : l10n.tr("sidebar.host.offline")
        let subtitle = meta.isEmpty ? statusPrefix : "\(statusPrefix) · \(meta)"

        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: cloudDeviceIconName(dev))
                    .font(.system(size: 13.5))
                    .foregroundStyle(isOnline ? tokens.foreground : tokens.mutedForeground)
                    .frame(width: 24, height: 24)
                Circle()
                    .fill(dotColor)
                    .frame(width: 6.5, height: 6.5)
                    .overlay(Circle().strokeBorder(tokens.surface2, lineWidth: 1.2))
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(dev.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(tokens.foreground)
                        .lineLimit(1)
                    if let ver = dev.version, !ver.isEmpty {
                        Text("v\(ver)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(tokens.mutedForeground)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(tokens.surface3))
                    }
                }
                Text(subtitle)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(tokens.mutedForeground)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            SettingsPillButton(
                l10n.tr("settings.myDevices.removeLogin"),
                destructive: true,
                disabled: isSubmittingSync
            ) {
                pendingRemoveCloudDevice = dev
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: tokens.rXS).fill(tokens.surface2))
    }

    private func remoteUpdateMeta(for host: UnifiedHostSnapshot) -> (detail: String?, detailColor: Color, error: String?) {
        guard host.isOnline, let status = state.remoteAppUpdateStatusByHost[host.id] else {
            return (nil, tokens.mutedForeground, nil)
        }
        switch status.state {
        case "checking":
            return (l10n.tr("settings.remote.updateChecking"), tokens.mutedForeground, nil)
        case "available":
            let ver = status.availableVersion ?? ""
            return (ver.isEmpty ? nil : l10n.tr("settings.remote.updateAvailable", ver), tokens.primary, nil)
        case "downloading":
            let ver = status.availableVersion ?? ""
            let pct = status.progress ?? 0
            let text = ver.isEmpty
                ? l10n.tr("settings.remote.updateDownloading", pct)
                : l10n.tr("settings.remote.updateDownloadingVersion", ver, pct)
            return (text, tokens.prismCobalt, nil)
        case "ready":
            let ver = status.availableVersion ?? ""
            return (ver.isEmpty ? nil : l10n.tr("settings.remote.updateReady", ver), tokens.success, nil)
        case "restarting":
            return (l10n.tr("settings.remote.updateRestarting"), tokens.primary, nil)
        case "error":
            return (nil, tokens.mutedForeground, status.error)
        case "idle":
            if checkedRemoteHostIDs.contains(host.id) {
                return (l10n.tr("settings.remote.updateUpToDate"), tokens.success, nil)
            }
            return (nil, tokens.mutedForeground, nil)
        default:
            return (nil, tokens.mutedForeground, nil)
        }
    }

    @ViewBuilder
    private func remoteUpdateControl(for host: UnifiedHostSnapshot) -> some View {
        let status = state.remoteAppUpdateStatusByHost[host.id]
        let isBusy = busyUpdateHostIDs.contains(host.id)
        if isBusy || status?.state == "checking" {
            updateProgressPill(l10n.tr("settings.remote.updateChecking"))
        } else if status?.state == "downloading" {
            updateProgressPill(l10n.tr("settings.remote.updateDownloading", status?.progress ?? 0))
        } else if status?.state == "restarting" {
            updateProgressPill(l10n.tr("settings.remote.updateRestarting"))
        } else if status?.state == "ready" {
            SettingsPillButton(l10n.tr("settings.remote.updateRestart"), icon: "arrow.clockwise", prominent: true) {
                triggerRemoteAppUpdate(for: host, action: "install")
            }
        } else if status?.state == "available", let ver = status?.availableVersion, !ver.isEmpty {
            SettingsPillButton(
                l10n.tr("settings.remote.updateToVersion", ver),
                icon: "arrow.down.circle",
                prominent: status?.canInstall == true
            ) {
                triggerRemoteAppUpdate(for: host, action: "install")
            }
        } else {
            SettingsPillButton(l10n.tr("settings.remote.updateCheck"), icon: "arrow.triangle.2.circlepath") {
                triggerRemoteAppUpdate(for: host, action: "check")
            }
        }
    }

    private func updateProgressPill(_ label: String) -> some View {
        HStack(spacing: 5) {
            ProgressView()
                .controlSize(.mini)
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(tokens.mutedForeground)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(tokens.surface3))
        .fixedSize()
    }

    private func triggerRemoteAppUpdate(for host: UnifiedHostSnapshot, action: String) {
        guard busyUpdateHostIDs.insert(host.id).inserted else { return }
        Task {
            defer { busyUpdateHostIDs.remove(host.id) }
            let outcome = await state.requestRemoteAppUpdate(hostId: host.id, action: action)
            if outcome.accepted {
                if action == "check" {
                    checkedRemoteHostIDs.insert(host.id)
                    store.showNotice(l10n.tr("settings.remote.updateCheckStarted", host.name))
                } else {
                    store.showNotice(l10n.tr("settings.remote.updateInstallStarted", host.name))
                }
            } else if let msg = outcome.message {
                store.showError(msg)
            }
        }
    }

    private func submitRemoveCloudDevice(_ dev: CloudDeviceInfo) {
        isSubmittingSync = true
        Task {
            defer { isSubmittingSync = false }
            do {
                try await daemon.removeAccountDevice(id: dev.id)
                store.showNotice(l10n.tr("settings.account.deviceSignedOut", dev.name))
                if dev.current {
                    _ = try? await daemon.checkAccount()
                } else {
                    _ = try? await daemon.syncNow()
                    _ = try? await daemon.listAccountDevices()
                }
                _ = try? await daemon.fetchSyncStatus()
            } catch {
                store.showError(error.localizedDescription)
            }
        }
    }

}

// MARK: - 10. Advanced & Service Section (Daemon, Proxy & Diagnostics)

struct AdvancedServiceSettingsSectionView: View {
    @Bindable var state: SartoState
    @Bindable var daemon: LocalDaemonManager
    @Bindable var store: PrismSettingsStore
    @Bindable var router: PrismSettingsRouter

    @State private var isRestartingDaemon: Bool = false
    @State private var proxyMode: String = "environment"
    @State private var proxyUrl: String = ""
    @State private var proxyNoProxy: String = ""
    @State private var verboseEnabled: Bool = false
    @State private var showClearConfirm: Bool = false

    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // 1. Unified Local Background Service (Controls + Health Metrics)
            SettingsGroupSection(l10n.tr("settings.localDaemon")) {
                SettingsPillButton(l10n.tr("settings.common.refresh"), icon: "arrow.clockwise") {
                    Task { await store.loadDaemonAndRemote(state: state, daemon: daemon) }
                }
            } content: {
                SettingsRowView(
                    id: "remote.daemon",
                    highlightedID: router.highlightedRowID,
                    title: daemonStatusText,
                    subtitle: daemonSubtitleText
                ) {
                    HStack(spacing: 8) {
                        if isRestartingDaemon {
                            ProgressView()
                                .controlSize(.small)
                            SettingsPillButton(
                                l10n.tr("settings.daemon.restart"),
                                icon: "arrow.clockwise",
                                disabled: true
                            ) {}
                        } else if state.connectionMode.isLive || daemon.isStartingOrRunning {
                            if daemon.canRestartLocally {
                                SettingsPillButton(
                                    daemon.runtimeOutdated
                                        ? l10n.tr("settings.daemon.restartToUpdate")
                                        : l10n.tr("settings.daemon.restart"),
                                    icon: "arrow.clockwise",
                                    prominent: daemon.runtimeOutdated
                                ) {
                                    restartLocalDaemon()
                                }
                            } else {
                                SettingsPillButton(
                                    l10n.tr("settings.daemon.reconnect"),
                                    icon: "arrow.clockwise"
                                ) {
                                    reconnectLocalDaemon()
                                }
                            }
                        } else {
                            SettingsPillButton(
                                l10n.tr("settings.startAndConnect"),
                                icon: "play.fill",
                                prominent: true
                            ) {
                                reconnectLocalDaemon()
                            }
                        }
                    }
                }
                .help(daemon.controlSocketPath)

                if let st = store.daemonStatus {
                    SettingsRowDivider()
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 16) {
                            let daemonTags = [st.origin, st.commit].compactMap { value -> String? in
                                guard let value, !value.isEmpty else { return nil }
                                return value
                            }
                            let daemonMeta = daemonTags.isEmpty ? "" : " · " + daemonTags.joined(separator: " · ")
                            healthMetric(label: "Daemon", value: "v\(st.version)\(daemonMeta) · PID \(st.pid)")
                            healthMetric(label: l10n.tr("settings.advanced.uptime"), value: formatUptime(startedAtMs: st.startedAt))
                        }
                        HStack(spacing: 8) {
                            hostChip(name: "agent-host", status: st.hosts.agent)
                            hostChip(name: "terminal-host", status: st.hosts.terminal)
                            hostChip(name: "remote-host", status: st.hosts.remote)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                }
            }

            // 2. Network Proxy
            SettingsGroupSection(l10n.tr("settings.advanced.proxy")) {
                SettingsRowView(
                    id: "advanced.proxy",
                    highlightedID: router.highlightedRowID,
                    title: l10n.tr("settings.advanced.proxyMode"),
                    subtitle: l10n.tr("settings.advanced.proxySub")
                ) {
                    Picker("", selection: $proxyMode) {
                        Text(l10n.tr("settings.advanced.proxyEnv")).tag("environment")
                        Text(l10n.tr("settings.advanced.proxyCustom")).tag("custom")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                    .onChange(of: proxyMode) { _, next in
                        if next == "environment" {
                            saveProxy()
                        }
                    }
                }

                if proxyMode == "custom" {
                    SettingsRowDivider()
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(l10n.tr("settings.advanced.proxyUrl"))
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(tokens.mutedForeground)
                            TextField("http://127.0.0.1:7890", text: $proxyUrl)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: tokens.rXS).fill(tokens.codeBackground))
                                .overlay(RoundedRectangle(cornerRadius: tokens.rXS).strokeBorder(tokens.borderEtched, lineWidth: 1))
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("NO_PROXY")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(tokens.mutedForeground)
                            TextField("localhost,127.0.0.1,.local", text: $proxyNoProxy)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: tokens.rXS).fill(tokens.codeBackground))
                                .overlay(RoundedRectangle(cornerRadius: tokens.rXS).strokeBorder(tokens.borderEtched, lineWidth: 1))
                        }

                        HStack {
                            Spacer()
                            SettingsPillButton(l10n.tr("settings.common.save"), prominent: true) {
                                saveProxy()
                            }
                        }
                    }
                    .padding(14)
                }
            }

            // 3. Diagnostics & Data
            SettingsGroupSection(l10n.tr("settings.advanced.diagnostics")) {
                SettingsRowView(
                    id: "advanced.diagnostics",
                    highlightedID: router.highlightedRowID,
                    title: l10n.tr("settings.advanced.verbose"),
                    subtitle: l10n.tr("settings.advanced.verboseSub")
                ) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { verboseEnabled },
                            set: { next in
                                verboseEnabled = next
                                Task {
                                    do {
                                        let until = try await daemon.setVerboseLogging(next)
                                        store.localHostSettings.verboseUntil = until
                                        if !state.connectionMode.isRemote {
                                            store.hostSettings.verboseUntil = until
                                        }
                                        verboseEnabled = until != nil
                                    } catch {
                                        verboseEnabled = !next
                                        store.showError(error.localizedDescription)
                                    }
                                }
                            }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                SettingsRowDivider()

                SettingsRowView(
                    id: "advanced.dataFolder",
                    highlightedID: router.highlightedRowID,
                    title: l10n.tr("settings.advanced.dataFolder"),
                    subtitle: store.daemonStatus?.dataPath ?? daemon.dataDirectory
                ) {
                    SettingsPillButton(l10n.tr("settings.advanced.openFolder"), icon: "folder") {
                        let path = store.daemonStatus?.dataPath ?? daemon.dataDirectory
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    }
                }

                SettingsRowDivider()

                SettingsRowView(
                    id: "advanced.clearSessions",
                    highlightedID: router.highlightedRowID,
                    title: l10n.tr("settings.advanced.clearSessions"),
                    subtitle: l10n.tr("settings.advanced.clearSessionsSub")
                ) {
                    SettingsPillButton(l10n.tr("settings.advanced.clearAllBtn"), icon: "trash", destructive: true, disabled: !state.connectionMode.isLive) {
                        showClearConfirm = true
                    }
                }
            }
        }
        .onAppear {
            syncFromStore()
        }
        .onChange(of: store.hostSettings) { _, _ in syncFromStore() }
        .onChange(of: store.localHostSettings) { _, _ in syncFromStore() }
        .alert(l10n.tr("settings.advanced.clearSessionsConfirmTitle"), isPresented: $showClearConfirm) {
            Button(l10n.tr("thread.entry.cancel"), role: .cancel) {}
            Button(l10n.tr("settings.advanced.clearAllBtn"), role: .destructive) {
                Task {
                    do {
                        try await state.clearAllHostSessions()
                        store.showNotice(l10n.tr("settings.advanced.clearSessionsDone"))
                    } catch {
                        store.showError(error.localizedDescription)
                    }
                }
            }
        } message: {
            Text(
                state.connectionMode.isRemote
                    ? l10n.tr("settings.advanced.clearSessionsConfirmRemoteBody", state.activeHostSnapshot.name)
                    : l10n.tr("settings.advanced.clearSessionsConfirmBody")
            )
        }
    }

    private func syncFromStore() {
        proxyMode = store.hostSettings.proxyMode
        proxyUrl = store.hostSettings.proxyUrl
        proxyNoProxy = store.hostSettings.proxyNoProxy
        // Verbose logging controls this Mac's local daemon even when viewing a remote host.
        if let until = store.localHostSettings.verboseUntil {
            verboseEnabled = until > Date().timeIntervalSince1970 * 1000
        } else {
            verboseEnabled = false
        }
    }

    private func saveProxy() {
        let proxyObj: [String: JSONValue]
        if proxyMode == "environment" {
            proxyObj = ["mode": .string("environment")]
        } else {
            proxyObj = [
                "mode": .string("custom"),
                "url": .string(proxyUrl.trimmingCharacters(in: .whitespacesAndNewlines)),
                "noProxy": .string(proxyNoProxy.trimmingCharacters(in: .whitespacesAndNewlines)),
            ]
        }
        let patch: [String: JSONValue] = ["proxy": .object(proxyObj)]
        Task {
            await store.patchHostSettings(patch, state: state, daemon: daemon, notice: l10n.tr("settings.common.saved"))
        }
    }

    private var daemonStatusText: String {
        if isRestartingDaemon {
            return l10n.tr("settings.daemon.restarting")
        }
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

    private var daemonSubtitleText: String {
        if daemon.runtimeOutdated {
            return l10n.tr("settings.daemon.subtitleOutdated")
        }
        if daemon.isLaunchdService {
            return l10n.tr("settings.daemon.subtitleService")
        }
        return l10n.tr("settings.daemon.subtitle")
    }

    private func confirmRestartIfBusy() -> Bool {
        guard state.hasRunningTurns else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = l10n.tr("settings.daemon.restartConfirmTitle")
        alert.informativeText = l10n.tr("settings.daemon.restartConfirmBody")
        alert.addButton(withTitle: l10n.tr("settings.daemon.restart"))
        alert.addButton(withTitle: l10n.tr("thread.entry.cancel"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func restartLocalDaemon() {
        guard !isRestartingDaemon else { return }
        guard confirmRestartIfBusy() else { return }
        isRestartingDaemon = true
        let onRemoteHost = state.connectionMode.isRemote
        Task {
            defer { isRestartingDaemon = false }
            do {
                state.flushDraftsNow()
                if !onRemoteHost {
                    await state.disconnectLive()
                }
                let hosts = try await daemon.restartBoundDaemon(
                    daemonEntryPath: SartoState.resolveDaemonBundlePath(),
                    relayOrigin: state.relayOrigin
                )
                if onRemoteHost {
                    await hosts.agent.close()
                    await hosts.terminal?.close()
                } else {
                    await state.attachLiveSession(
                        hosts.agent,
                        terminal: hosts.terminal,
                        mode: .localDaemon(socketPath: daemon.controlSocketPath)
                    )
                }
                await store.loadDaemonAndRemote(state: state, daemon: daemon)
                store.showNotice(l10n.tr("settings.daemon.restartedNotice"))
            } catch {
                store.showError(error.localizedDescription)
            }
        }
    }

    private func reconnectLocalDaemon() {
        guard !isRestartingDaemon else { return }
        isRestartingDaemon = true
        let onRemoteHost = state.connectionMode.isRemote
        Task {
            defer { isRestartingDaemon = false }
            do {
                let hosts = try await daemon.connectOrStartHosts(
                    daemonEntryPath: SartoState.resolveDaemonBundlePath(),
                    relayOrigin: state.relayOrigin
                )
                if onRemoteHost {
                    await hosts.agent.close()
                    await hosts.terminal?.close()
                } else {
                    await state.attachLiveSession(
                        hosts.agent,
                        terminal: hosts.terminal,
                        mode: .localDaemon(socketPath: daemon.controlSocketPath)
                    )
                }
                await store.loadDaemonAndRemote(state: state, daemon: daemon)
            } catch {
                store.showError(error.localizedDescription)
            }
        }
    }

    private func healthMetric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(tokens.mutedForeground)
            Text(value)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(tokens.foreground)
        }
    }

    private func hostChip(name: String, status: DaemonHostProcessStatus) -> some View {
        let healthy = status.state == "running" || status.state == "ready"
        return HStack(spacing: 5) {
            Circle()
                .fill(healthy ? tokens.success : (status.state == "idle" ? tokens.mutedForeground : tokens.warning))
                .frame(width: 6, height: 6)
            Text(name)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(tokens.foreground)
            Text(status.state)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(tokens.mutedForeground)
            if status.restarts > 0 {
                Text("×\(status.restarts)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(tokens.warning)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: tokens.rXS).fill(tokens.surface2))
    }

    private func formatUptime(startedAtMs: Double) -> String {
        guard startedAtMs > 0 else { return "—" }
        let sec = max(0, Int(Date().timeIntervalSince1970 - startedAtMs / 1000))
        let h = sec / 3600
        let m = (sec % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}

// MARK: - 11. Updates, Reports & About Section

struct UpdatesAboutSettingsSectionView: View {
    @Bindable var state: SartoState
    @Bindable var daemon: LocalDaemonManager
    @Bindable var router: PrismSettingsRouter

    @State private var cloudReports: CloudReportListInfo? = nil
    @State private var isLoadingReports: Bool = false
    @State private var reportsError: String? = nil
    @State private var copiedReportID: String? = nil

    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    @Environment(SartoUpdater.self) private var updater
    @Environment(ProblemReportCoordinator.self) private var problemReport

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            UpdatesSettingsGroup(updater: updater, router: router)

            myProblemReportsSection

            SettingsGroupSection(l10n.tr("settings.advanced.about")) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        Image(state.appIconStyle.assetName)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 48, height: 48)

                        VStack(alignment: .leading, spacing: 2.5) {
                            Text(SartoBrand.name)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(tokens.foreground)
                            Text(l10n.tr("brand.slogan"))
                                .font(.system(size: 11.5))
                                .foregroundStyle(tokens.secondaryForeground)
                                .lineLimit(1)
                            let info = Bundle.main.infoDictionary ?? [:]
                            let appVer = (info["SartoVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                                ?? (info["CFBundleShortVersionString"] as? String) ?? "0.2.0"
                            let buildNo = (info["CFBundleVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "2"
                            let commit = (info["SartoGitCommit"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                            let channel = (info["SartoBuildChannel"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                            let buildSuffix = ([buildNo, commit].compactMap { $0 }).joined(separator: " · ")
                            let channelSuffix = (channel != nil && channel != "stable") ? " [\(channel!)]" : ""
                            Text("macOS Native ADE · v\(appVer) (\(buildSuffix))\(channelSuffix)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(tokens.mutedForeground)
                        }
                        Spacer()
                    }
                    .padding(14)
                    .id("advanced.about")

                    SettingsRowDivider()

                    SettingsRowView(
                        id: "remote.privacy",
                        highlightedID: router.highlightedRowID,
                        title: l10n.tr("settings.privacy.policyTitle"),
                        subtitle: l10n.tr("settings.privacy.policySub")
                    ) {
                        SettingsPillButton(
                            l10n.tr("settings.privacy.policyAction"),
                            icon: "checkmark.shield"
                        ) {
                            openPrivacyPolicy()
                        }
                    }
                }
            }
        }
        .onAppear {
            Task { await refreshCloudReports() }
        }
        .onChange(of: state.cloudAccountStatus.account.isSignedIn) { _, _ in
            Task { await refreshCloudReports() }
        }
        .onChange(of: problemReport.reportsRefreshToken) { _, _ in
            Task { await refreshCloudReports() }
        }
    }

    private func openProblemReportSheet() {
        let isRemote = state.activeHostID != SartoState.localHostID
        let remoteName = isRemote
            ? state.otherHosts.first(where: { $0.id == state.activeHostID })?.name
            : nil
        problemReport.open(
            target: .settings,
            remoteHostId: isRemote ? state.activeHostID : nil,
            remoteHostName: remoteName
        )
    }

    private func openPrivacyPolicy() {
        if let url = state.privacyPolicyURL {
            NSWorkspace.shared.open(url)
        }
    }

    private var myProblemReportsSection: some View {
        let totalBadge: String? = {
            guard state.cloudAccountStatus.account.isSignedIn,
                  let total = cloudReports?.total,
                  total > 0
            else { return nil }
            return "\(total)"
        }()

        return SettingsGroupSection(l10n.tr("settings.reports.section"), trailingBadge: totalBadge) {
            SettingsPillButton(l10n.tr("settings.advanced.reportProblem"), icon: "ladybug.fill", prominent: true) {
                openProblemReportSheet()
            }
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                if !state.cloudAccountStatus.account.isSignedIn {
                    signedOutReportsBanner
                } else {
                    reportsHeaderBar
                    Rectangle()
                        .fill(tokens.borderEtched)
                        .frame(height: 1)

                    if let reportsError {
                        reportsErrorRow(reportsError)
                    } else if isLoadingReports && cloudReports == nil {
                        reportsLoadingRow
                    } else if let list = cloudReports, !list.reports.isEmpty {
                        let visible = Array(list.reports.prefix(10))
                        VStack(spacing: 0) {
                            ForEach(Array(visible.enumerated()), id: \.element.id) { idx, rep in
                                if idx > 0 {
                                    SettingsRowDivider()
                                }
                                CloudReportRowView(
                                    report: rep,
                                    origin: list.origin,
                                    isCopied: copiedReportID == rep.id,
                                    statusColor: reportStatusColor(rep.status),
                                    statusIcon: reportStatusIcon(rep.status),
                                    statusLabel: l10n.tr("settings.reports.status.\(rep.status)"),
                                    relativeTime: formatReportRelativeTime(rep.createdAt),
                                    onCopyID: { copyReportID(rep.id) },
                                    onOpenConsole: { openReportInConsole(id: rep.id, origin: list.origin) }
                                )
                            }
                        }

                        if list.total > visible.count {
                            Rectangle()
                                .fill(tokens.borderEtched)
                                .frame(height: 1)
                            HStack(spacing: 8) {
                                Text(l10n.tr("settings.reports.showingRecent", visible.count, list.total))
                                    .font(.system(size: 11))
                                    .foregroundStyle(tokens.mutedForeground)
                                Spacer()
                                if let url = reportsConsoleURL(origin: list.origin) {
                                    Button {
                                        NSWorkspace.shared.open(url)
                                    } label: {
                                        HStack(spacing: 4) {
                                            Text(l10n.tr("settings.reports.viewAll"))
                                            Image(systemName: "arrow.up.right")
                                                .font(.system(size: 9.5, weight: .semibold))
                                        }
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(tokens.prismCobalt)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(tokens.surface2.opacity(0.22))
                        }
                    } else {
                        reportsEmptyState
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: tokens.rMD, style: .continuous))
            .id("advanced.reports")
        }
    }

    private var signedOutReportsBanner: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                    .fill(tokens.surface2)
                    .overlay(
                        RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                            .strokeBorder(tokens.borderEtched, lineWidth: 1)
                    )
                Image(systemName: "ladybug.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tokens.mutedForeground)
            }
            .frame(width: 32, height: 32)

            Text(l10n.tr("settings.reports.signedOut"))
                .font(.system(size: 12))
                .foregroundStyle(tokens.secondaryForeground)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 10)

            SettingsPillButton(l10n.tr("report.sheet.signIn"), icon: "person.crop.circle") {
                router.jumpTo(section: .remoteAndCloud, rowID: "remote.sync")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
    }

    private var reportsHeaderBar: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 8) {
                if isLoadingReports && cloudReports == nil {
                    ProgressView()
                        .controlSize(.mini)
                    Text(l10n.tr("settings.reports.syncing"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokens.mutedForeground)
                } else if let list = cloudReports, list.total > 0 {
                    Text(l10n.tr("settings.reports.summaryTotal", list.total))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(tokens.secondaryForeground)
                    reportsStatusBreakdown(list.countsByStatus)
                } else {
                    Circle()
                        .fill(tokens.success)
                        .frame(width: 6, height: 6)
                    Text(l10n.tr("settings.reports.connected"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokens.mutedForeground)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                if let origin = cloudReports?.origin, let url = reportsConsoleURL(origin: origin) {
                    SettingsPillButton(l10n.tr("settings.reports.openConsole"), icon: "arrow.up.right.square") {
                        NSWorkspace.shared.open(url)
                    }
                }
                SettingsPillButton(
                    l10n.tr("settings.common.refresh"),
                    icon: "arrow.clockwise",
                    disabled: isLoadingReports
                ) {
                    Task { await refreshCloudReports() }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(tokens.surface2.opacity(0.32))
    }

    @ViewBuilder
    private func reportsStatusBreakdown(_ counts: [String: Int]) -> some View {
        let ordered = ["investigating", "confirmed", "fixed", "submitted"]
        let items: [(status: String, count: Int)] = ordered.compactMap { key in
            guard let n = counts[key], n > 0 else { return nil }
            return (key, n)
        }
        if !items.isEmpty {
            HStack(spacing: 6) {
                ForEach(items.prefix(3), id: \.status) { item in
                    let color = reportStatusColor(item.status)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(color)
                            .frame(width: 5, height: 5)
                        Text("\(l10n.tr("settings.reports.status.\(item.status)")) \(item.count)")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(tokens.mutedForeground)
                    }
                    .padding(.horizontal, 6.5)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(tokens.surface1.opacity(0.85)))
                    .overlay(Capsule().strokeBorder(tokens.borderEtched, lineWidth: 1))
                }
            }
        }
    }

    private var reportsLoadingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(l10n.tr("settings.reports.syncing"))
                .font(.system(size: 12))
                .foregroundStyle(tokens.mutedForeground)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 18)
    }

    private func reportsErrorRow(_ message: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12.5))
                .foregroundStyle(tokens.danger)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(tokens.danger)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            SettingsPillButton(l10n.tr("settings.reports.retry"), icon: "arrow.clockwise") {
                Task { await refreshCloudReports() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(tokens.danger.opacity(0.06))
    }

    private var reportsEmptyState: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                    .fill(tokens.surface2.opacity(0.75))
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(tokens.mutedForeground)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2.5) {
                Text(l10n.tr("settings.reports.empty"))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(tokens.foreground)
                Text(l10n.tr("settings.reports.emptySub"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(tokens.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
    }

    private func copyReportID(_ id: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(id, forType: .string)
        copiedReportID = id
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedReportID == id { copiedReportID = nil }
        }
    }

    private func reportsConsoleURL(origin: String, reportID: String? = nil) -> URL? {
        let trimmed = origin.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return nil }
        if let reportID, !reportID.isEmpty {
            return URL(string: "\(trimmed)/console/#reports/\(reportID)")
        }
        return URL(string: "\(trimmed)/console/#reports")
    }

    private func openReportInConsole(id: String, origin: String) {
        guard let url = reportsConsoleURL(origin: origin, reportID: id) else { return }
        NSWorkspace.shared.open(url)
    }

    private func reportStatusColor(_ status: String) -> Color {
        switch status {
        case "fixed": return tokens.success
        case "confirmed": return tokens.prismCobalt
        case "investigating": return tokens.prismAmber
        case "wont_fix", "closed": return tokens.mutedForeground
        default: return tokens.prismIris
        }
    }

    private func reportStatusIcon(_ status: String) -> String {
        switch status {
        case "fixed": return "checkmark.circle.fill"
        case "confirmed": return "checkmark.seal.fill"
        case "investigating": return "magnifyingglass"
        case "wont_fix", "closed": return "archivebox.fill"
        default: return "paperplane.fill"
        }
    }

    @MainActor
    private static let reportDateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt
    }()

    private func formatReportRelativeTime(_ timestampMs: Double) -> String? {
        guard timestampMs > 0 else { return nil }
        let seconds = max(0, Int(Date().timeIntervalSince1970 - timestampMs / 1000))
        if seconds < 60 { return l10n.tr("settings.reports.justNow") }
        let minutes = seconds / 60
        if minutes < 60 { return l10n.tr("settings.reports.minutesAgo", minutes) }
        let hours = minutes / 60
        if hours < 24 { return l10n.tr("settings.reports.hoursAgo", hours) }
        let days = hours / 24
        if days < 14 { return l10n.tr("settings.reports.daysAgo", days) }
        let date = Date(timeIntervalSince1970: timestampMs / 1000)
        return Self.reportDateFormatter.string(from: date)
    }

    private func refreshCloudReports() async {
        guard state.cloudAccountStatus.account.isSignedIn else {
            cloudReports = nil
            reportsError = nil
            return
        }
        isLoadingReports = true
        reportsError = nil
        defer { isLoadingReports = false }
        do {
            cloudReports = try await daemon.listProblemReports(limit: 20)
        } catch {
            reportsError = error.localizedDescription
        }
    }
}

/// Dedicated row leaf view for a submitted Cloud problem report so hover and copy transitions
/// stay localized without re-rendering the entire Settings pane.
private struct CloudReportRowView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    @Environment(\.prismMotionTier) private var motionTier
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let report: CloudReportSummaryInfo
    let origin: String
    let isCopied: Bool
    let statusColor: Color
    let statusIcon: String
    let statusLabel: String
    let relativeTime: String?
    let onCopyID: () -> Void
    let onOpenConsole: () -> Void

    @State private var isRowHovered = false
    @State private var isCopyHovered = false
    @State private var isOpenHovered = false

    private var canOpenConsole: Bool {
        !origin.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Leading semantic status anchor
            ZStack {
                RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                    .fill(statusColor.opacity(0.11))
                    .overlay(
                        RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                            .strokeBorder(statusColor.opacity(0.22), lineWidth: 1)
                    )
                Image(systemName: statusIcon)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
            .frame(width: 32, height: 32)

            // Main content hierarchy: Title + status pill first, crisp metadata underneath
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 7) {
                    Text(report.title.isEmpty ? report.id : report.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(tokens.foreground)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 5, height: 5)
                        Text(statusLabel)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(statusColor)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(statusColor.opacity(0.11)))
                    .overlay(Capsule().strokeBorder(statusColor.opacity(0.2), lineWidth: 1))
                    .fixedSize()

                    if let fixed = report.fixedInVersion, !fixed.isEmpty {
                        Text(l10n.tr("settings.reports.fixedIn", fixed))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(tokens.success)
                            .padding(.horizontal, 6.5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(tokens.success.opacity(0.11)))
                            .overlay(Capsule().strokeBorder(tokens.success.opacity(0.22), lineWidth: 1))
                            .fixedSize()
                    }
                }

                HStack(spacing: 6) {
                    Text(report.id)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(tokens.secondaryForeground)

                    if !report.version.isEmpty {
                        metadataDot
                        Text("v\(report.version.hasPrefix("v") ? String(report.version.dropFirst()) : report.version)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(tokens.mutedForeground)
                    }

                    if let relativeTime {
                        metadataDot
                        Text(relativeTime)
                            .font(.system(size: 11))
                            .foregroundStyle(tokens.mutedForeground)
                    }

                    if report.hasBundle && report.bundleSize > 0 {
                        metadataDot
                        HStack(spacing: 3) {
                            Image(systemName: "paperclip")
                                .font(.system(size: 9.5, weight: .medium))
                            Text(formatBundleSize(report.bundleSize))
                                .font(.system(size: 10.5, design: .monospaced))
                        }
                        .foregroundStyle(tokens.mutedForeground)
                    }

                    if report.commentCount > 0 {
                        metadataDot
                        HStack(spacing: 3) {
                            Image(systemName: "bubble.left.fill")
                                .font(.system(size: 9.5))
                            Text(l10n.tr("settings.reports.comments", report.commentCount))
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(tokens.prismCobalt)
                    }
                }
            }

            Spacer(minLength: 10)

            // Subtle trailing action controls
            HStack(spacing: 6) {
                Button(action: onCopyID) {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                        if isCopied {
                            Text(l10n.tr("report.sheet.copied"))
                                .font(.system(size: 10.5, weight: .medium))
                        }
                    }
                    .foregroundStyle(
                        isCopied ? tokens.success
                            : (isCopyHovered ? tokens.foreground : tokens.mutedForeground)
                    )
                    .padding(.horizontal, isCopied ? 8 : 0)
                    .frame(minWidth: 28, minHeight: 28)
                    .background(
                        RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                            .fill(
                                isCopied ? tokens.success.opacity(0.12)
                                    : (isCopyHovered ? tokens.surface2 : tokens.surface2.opacity(isRowHovered ? 0.6 : 0.0))
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                            .strokeBorder(
                                isCopied ? tokens.success.opacity(0.28)
                                    : (isCopyHovered || isRowHovered ? tokens.borderEtched : Color.clear),
                                lineWidth: 1
                            )
                    )
                }
                .buttonStyle(.plain)
                .onHover { isCopyHovered = $0 }
                .help(l10n.tr("report.sheet.copyId"))

                if canOpenConsole {
                    Button(action: onOpenConsole) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(isOpenHovered ? tokens.prismCobalt : tokens.secondaryForeground)
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                                    .fill(
                                        isOpenHovered ? tokens.prismCobalt.opacity(0.12)
                                            : tokens.surface2.opacity(isRowHovered ? 0.85 : 0.45)
                                    )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                                    .strokeBorder(
                                        isOpenHovered ? tokens.prismCobalt.opacity(0.32) : tokens.borderEtched,
                                        lineWidth: 1
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { isOpenHovered = $0 }
                    .help(l10n.tr("report.sheet.openConsole"))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(isRowHovered ? tokens.surface2.opacity(0.38) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovered in
            withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier, reduceMotion: reduceMotion)) {
                isRowHovered = hovered
            }
        }
        .onTapGesture {
            if canOpenConsole {
                onOpenConsole()
            }
        }
    }

    private var metadataDot: some View {
        Text("·")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(tokens.mutedForeground.opacity(0.6))
    }

    private func formatBundleSize(_ bytes: Int) -> String {
        if bytes >= 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        }
        if bytes >= 1024 {
            return String(format: "%.0f KB", Double(bytes) / 1024)
        }
        return "\(bytes) B"
    }
}

/// Compact leaf view for host CPU, memory, disk, and battery load meters.
/// Kept isolated so periodic load samples only re-render the meters.
private struct HostLoadMetersView: View {
    let load: HostLoad

    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    private static let memoryByteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useMB, .useGB, .useTB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    private static let diskByteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB, .useTB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                meterColumn(
                    label: l10n.tr("hostLoad.cpu"),
                    value: cpuValueText,
                    fraction: clampedFraction(load.cpu.percent / 100.0),
                    barColor: cpuBarColor,
                    valueColor: cpuValueColor
                )

                meterColumn(
                    label: l10n.tr("hostLoad.memory"),
                    value: memoryValueText,
                    fraction: clampedFraction(load.memory.usedPercent / 100.0),
                    barColor: memoryTintColor,
                    valueColor: memoryTextColor
                )
            }

            if load.disk != nil || load.battery != nil || load.container == true {
                HStack(alignment: .center, spacing: 10) {
                    if let disk = load.disk {
                        meterColumn(
                            label: l10n.tr("hostLoad.disk"),
                            value: l10n.tr("hostLoad.free", formatDiskBytes(disk.free)),
                            fraction: clampedFraction(disk.usedPercent / 100.0),
                            barColor: diskTintColor(for: disk),
                            valueColor: diskTextColor(for: disk)
                        )
                        .help(disk.name)
                    }

                    if let battery = load.battery {
                        batteryPill(battery)
                    }

                    if load.container == true {
                        Text(l10n.tr("hostLoad.container"))
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(tokens.mutedForeground)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(tokens.surface3))
                            .fixedSize()
                    }
                }
            }
        }
    }

    private var cpuPercentInt: Int {
        guard load.cpu.percent.isFinite else { return 0 }
        return max(0, min(100, Int(load.cpu.percent.rounded())))
    }

    private var cpuCoreCount: Int {
        guard load.cpu.cores.isFinite, load.cpu.cores > 0 else { return 1 }
        return max(1, Int(load.cpu.cores.rounded()))
    }

    private var cpuValueText: String {
        "\(cpuPercentInt)% · \(l10n.tr("hostLoad.cores", cpuCoreCount))"
    }

    private var cpuBarColor: Color {
        if load.cpu.percent >= 90 { return tokens.danger }
        if load.cpu.percent >= 75 { return tokens.warning }
        return tokens.prismCobalt
    }

    private var cpuValueColor: Color {
        if load.cpu.percent >= 90 { return tokens.danger }
        if load.cpu.percent >= 75 { return tokens.warning }
        return tokens.secondaryForeground
    }

    private var memoryValueText: String {
        "\(formatMemoryBytes(load.memory.used)) / \(formatMemoryBytes(load.memory.total))"
    }

    private var memoryTintColor: Color {
        switch load.memory.state {
        case "critical": return tokens.danger
        case "low": return tokens.warning
        default: return tokens.prismIris
        }
    }

    private var memoryTextColor: Color {
        switch load.memory.state {
        case "critical": return tokens.danger
        case "low": return tokens.warning
        default: return tokens.secondaryForeground
        }
    }

    private func diskTintColor(for disk: HostLoadDisk) -> Color {
        if disk.free <= HostLoadConstants.diskCriticalBytes { return tokens.danger }
        if disk.free <= HostLoadConstants.diskWarnBytes { return tokens.warning }
        return tokens.primary
    }

    private func diskTextColor(for disk: HostLoadDisk) -> Color {
        if disk.free <= HostLoadConstants.diskCriticalBytes { return tokens.danger }
        if disk.free <= HostLoadConstants.diskWarnBytes { return tokens.warning }
        return tokens.secondaryForeground
    }

    private func meterColumn(
        label: String,
        value: String,
        fraction: Double,
        barColor: Color,
        valueColor: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 3.5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(tokens.mutedForeground)
                Spacer(minLength: 4)
                Text(value)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(tokens.surface3)
                    Capsule()
                        .fill(barColor)
                        .frame(width: max(fraction > 0 ? 3 : 0, geo.size.width * fraction))
                }
            }
            .frame(height: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func batteryPill(_ battery: HostBattery) -> some View {
        let tint = batteryTint(battery)
        let symbol = batterySymbol(battery)
        let statusText: String = {
            if battery.charging { return l10n.tr("hostLoad.charging") }
            if battery.onBattery { return l10n.tr("hostLoad.onBattery") }
            return l10n.tr("hostLoad.pluggedIn")
        }()

        return HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
            if let pct = battery.percent, pct.isFinite {
                Text("\(max(0, min(100, Int(pct.rounded()))))%")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
            Text(statusText)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tokens.mutedForeground)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(tokens.surface3))
        .overlay(Capsule().strokeBorder(batteryBorderColor(battery), lineWidth: 1))
        .fixedSize()
    }

    private func batteryTint(_ battery: HostBattery) -> Color {
        if battery.charging { return tokens.success }
        if let pct = battery.percent, pct.isFinite {
            if pct <= HostLoadConstants.batteryCriticalPercent { return tokens.danger }
            if pct <= HostLoadConstants.batteryWarnPercent { return tokens.warning }
        }
        return tokens.secondaryForeground
    }

    private func batteryBorderColor(_ battery: HostBattery) -> Color {
        if !battery.charging, let pct = battery.percent, pct.isFinite {
            if pct <= HostLoadConstants.batteryCriticalPercent { return tokens.danger.opacity(0.45) }
            if pct <= HostLoadConstants.batteryWarnPercent { return tokens.warning.opacity(0.45) }
        }
        return tokens.borderEtched
    }

    private func batterySymbol(_ battery: HostBattery) -> String {
        if battery.charging { return "battery.100.bolt" }
        if !battery.onBattery { return "powerplug.fill" }
        guard let pct = battery.percent, pct.isFinite else { return "battery.50" }
        if pct >= 85 { return "battery.100" }
        if pct >= 60 { return "battery.75" }
        if pct >= 35 { return "battery.50" }
        if pct >= 15 { return "battery.25" }
        return "battery.0"
    }

    private func clampedFraction(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1.0, max(0.0, value))
    }

    private func formatMemoryBytes(_ bytes: Double) -> String {
        Self.memoryByteFormatter.string(fromByteCount: clampedByteCount(bytes))
    }

    private func formatDiskBytes(_ bytes: Double) -> String {
        Self.diskByteFormatter.string(fromByteCount: clampedByteCount(bytes))
    }

    private func clampedByteCount(_ bytes: Double) -> Int64 {
        guard bytes.isFinite, bytes > 0 else { return 0 }
        return Int64(min(bytes, Double(Int64.max - 1024)))
    }
}
