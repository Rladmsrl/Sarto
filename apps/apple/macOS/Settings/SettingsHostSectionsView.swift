import AppKit
import SartoProtocol
import PrismDesign
import SwiftUI

// MARK: - 6. Agents & Harnesses Section

struct AgentsSettingsSectionView: View {
    @Bindable var state: SartoState
    @Bindable var daemon: LocalDaemonManager
    @Bindable var store: PrismSettingsStore
    @Bindable var router: PrismSettingsRouter

    @State private var expandedAgentID: String? = nil
    @State private var apiKeyDraftByAgent: [String: String] = [:]
    @State private var autoCompactDraftByAgent: [String: String] = [:]

    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    private var visibleAgents: [AgentStatusInfo] {
        PrismSettingsStore.visibleAgents(from: state.agents)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !state.connectionMode.isLive {
                SettingsBannerView(text: l10n.tr("settings.hostOfflineBanner"), kind: .info)
            }

            if let warn = store.environmentInfo?.warning, !warn.isEmpty {
                SettingsBannerView(text: warn, kind: .error)
            }

            let groups = Dictionary(grouping: visibleAgents, by: hasInstalledHarness)
            installedAgentsGroup(groups[true] ?? [])
                .id("agents.list")
            if let installable = groups[false], !installable.isEmpty {
                agentGroup(installable, title: "settings.agents.installable")
            }

            // Idle Session Auto-Release Policy (Claude Code)
            SettingsGroupSection(l10n.tr("settings.agents.idleRelease")) {
                SettingsRowView(
                    id: "agents.idleRelease",
                    highlightedID: router.highlightedRowID,
                    title: l10n.tr("settings.agents.idleMode"),
                    subtitle: idleReleaseSubtitle
                ) {
                    Picker(
                        "",
                        selection: Binding<String>(
                            get: { store.hostSettings.idleRelease },
                            set: { next in
                                let wasCustom = store.hostSettings.idleRelease == "custom"
                                store.hostSettings.idleRelease = next
                                var idleObj: [String: JSONValue] = ["release": .string(next)]
                                if next == "custom" && !wasCustom {
                                    store.hostSettings.idleOutOfView = 5
                                    store.hostSettings.idleInView = 15
                                    store.hostSettings.idleLimit = 2
                                    idleObj["outOfView"] = .number(5)
                                    idleObj["inView"] = .number(15)
                                    idleObj["limit"] = .number(2)
                                }
                                Task {
                                    await store.patchHostSettings(
                                        ["idleSessions": .object(idleObj)],
                                        state: state,
                                        daemon: daemon
                                    )
                                }
                            }
                        )
                    ) {
                        Text(l10n.tr("settings.agents.idleOff")).tag("never")
                        Text(l10n.tr("settings.agents.idleBalanced")).tag("auto")
                        Text(l10n.tr("settings.agents.idleAggressive")).tag("custom")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                    .disabled(!state.connectionMode.isLive)
                }
            }

            // Runtime Environment (secondary diagnostic card at bottom)
            SettingsGroupSection(l10n.tr("settings.agents.environment")) {
                SettingsRowView(
                    id: "agents.environment",
                    highlightedID: router.highlightedRowID,
                    title: environmentHeadline,
                    subtitle: environmentSubtitle
                ) {
                    SettingsPillButton(l10n.tr("settings.agents.reloadEnv"), icon: "arrow.triangle.2.circlepath", disabled: !state.connectionMode.isLive) {
                        Task {
                            guard let host = state.activeHostSession else { return }
                            do {
                                let updated = try await host.reloadAgentEnvironment()
                                state.agents = updated
                                if let env = try? await host.agentEnvironment() {
                                    store.environmentInfo = env
                                }
                                store.showNotice(l10n.tr("settings.agents.envReloaded"))
                            } catch {
                                store.showError(error.localizedDescription)
                            }
                        }
                    }
                }
            }
        }
        .modifier(AgentAvailabilityPresenter(state: state, surface: .settings, settings: storeSettings))
        .task(id: state.connectionMode.isLive) {
            guard state.connectionMode.isLive, let host = state.activeHostSession else { return }
            let pending = visibleAgents.filter { agent in
                AgentAvailability.isInstalled(agent)
                    && agent.disabled != true
                    && agent.state == "ready"
                    && agent.signIn == "unknown"
            }
            guard !pending.isEmpty else { return }
            await withTaskGroup(of: Void.self) { group in
                for agent in pending {
                    let agentId = agent.id
                    group.addTask {
                        try? await host.refreshAgentAccount(agentId: agentId, force: false)
                    }
                }
            }
            await state.refreshAgentsFromHost()
        }
    }

    private var environmentHeadline: String {
        if let env = store.environmentInfo {
            let node = env.nodeVersion.map { "Node \($0)" } ?? "Node —"
            let shell = env.shell.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "shell"
            return "\(node) · \(shell) (\(env.source))"
        }
        return l10n.tr("settings.agents.environment")
    }

    private var environmentSubtitle: String {
        if let warn = store.environmentInfo?.warning, !warn.isEmpty {
            return warn
        }
        return store.environmentInfo?.npmPath ?? l10n.tr("settings.agents.environmentSub")
    }

    private var idleReleaseSubtitle: String {
        switch store.hostSettings.idleRelease {
        case "never":
            return l10n.tr("settings.agents.idleOffSub")
        case "custom":
            let out = store.hostSettings.idleOutOfView
            let inV = store.hostSettings.idleInView
            if let limit = store.hostSettings.idleLimit {
                return l10n.tr("settings.agents.idleCustomWithLimitSub", out, inV, limit)
            }
            return l10n.tr("settings.agents.idleCustomSub", out, inV)
        default:
            return l10n.tr("settings.agents.idleBalancedSub")
        }
    }

    private func hasInstalledHarness(_ agent: AgentStatusInfo) -> Bool {
        if agent.uninstalled == true { return false }
        if agent.cli?.installed != nil || agent.availability.release != nil { return true }
        if let package = agent.availability.package { return package.installed }
        return AgentAvailability.isInstalled(agent)
    }

    private func installedAgentsGroup(_ agents: [AgentStatusInfo]) -> some View {
        SettingsGroupSection(
            l10n.tr("settings.agents.list"),
            trailingBadge: String(agents.count)
        ) {
            SettingsPillButton(
                l10n.tr("settings.agents.checkUpdates"),
                icon: "arrow.down.circle",
                disabled: !state.connectionMode.isLive
            ) {
                Task {
                    guard let host = state.activeHostSession else { return }
                    do {
                        let updated = try await host.checkAgentUpdates()
                        state.agents = updated
                        store.showNotice(l10n.tr("settings.agents.updatesChecked"))
                    } catch {
                        store.showError(error.localizedDescription)
                    }
                }
            }
        } content: {
            if agents.isEmpty {
                Text(l10n.tr("settings.agents.empty"))
                    .font(.system(size: 12))
                    .foregroundStyle(tokens.mutedForeground)
                    .padding(14)
            } else {
                ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                    if index > 0 { SettingsRowDivider() }
                    agentRow(agent)
                }
            }
        }
    }

    private func agentGroup(_ agents: [AgentStatusInfo], title: String) -> some View {
        SettingsGroupSection(l10n.tr(title), trailingBadge: String(agents.count)) {
            if agents.isEmpty {
                Text(l10n.tr("settings.agents.empty"))
                    .font(.system(size: 12))
                    .foregroundStyle(tokens.mutedForeground)
                    .padding(14)
            } else {
                ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                    if index > 0 { SettingsRowDivider() }
                    agentRow(agent)
                }
            }
        }
    }

    private func versionSummary(_ agent: AgentStatusInfo) -> String {
        guard hasInstalledHarness(agent) else { return "" }
        let package = agent.availability.package
        var parts: [String] = []
        func append(_ key: String, _ installed: String?, update: String?) {
            guard let installed, !installed.isEmpty else { return }
            var text = l10n.tr(key, installed)
            if let update, !update.isEmpty, update != installed { text += " → " + update }
            parts.append(text)
        }

        // Earlier hosts omit isCli for packages that provide the executable on PATH.
        let packageRunsCLI = package?.isCli == true || (package?.isSdk == false
            && agent.availability.program?.onPath == true && agent.cli?.installed == nil)
        if let package, !packageRunsCLI {
            append("settings.agents.cliVersion", agent.cli?.installed?.version,
                   update: agent.cli?.update?.version)
            if package.installed {
                let label: String
                if package.isSdk {
                    label = "settings.agents.sdkVersion"
                } else if agent.cli != nil || agent.availability.program?.onPath == false {
                    label = "settings.agents.adapterVersion"
                } else {
                    label = "settings.agents.packageVersion"
                }
                append(label, package.version, update: agent.update?.adapterVersion)
            }
        } else {
            let version = agent.cli?.installed?.version ?? agent.availability.release?.version
                ?? (package?.installed == true ? package?.version : nil) ?? agent.version
            append("settings.agents.cliVersion", version,
                   update: agent.cli?.update?.version ?? agent.update?.displayVersion)
        }
        return parts.joined(separator: " · ")
    }

    private func agentRow(_ agent: AgentStatusInfo) -> some View {
        let isExpanded = expandedAgentID == agent.id
        let isDisabled = store.hostSettings.disabledAgents.contains(agent.id) || (agent.disabled == true)
        let isBusy = store.busyAgentIDs.contains(agent.id) || (agent.task?.isRunning == true)
        let entry = state.agentAvailability[agent.id]
        let statusColor = entry?.problem != nil ? problemColor(entry) : agentStatusColor(agent.state)
        let subtitle = agentRowSubtitle(agent, showsState: entry?.problem == nil)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Circle()
                    .fill(isDisabled ? tokens.mutedForeground.opacity(0.45) : statusColor)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isDisabled ? tokens.mutedForeground : tokens.foreground)
                    let versions = versionSummary(agent)
                    if !versions.isEmpty {
                        Text(versions)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(tokens.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 0) {
                        // Why its harness cannot run leads the line, said as everywhere else.
                        if let problem = entry?.problem {
                            Text(problem.label)
                                .foregroundStyle(problemColor(entry))
                            if !subtitle.isEmpty {
                                Text(" · ")
                                    .foregroundStyle(tokens.mutedForeground)
                            }
                        }
                        Text(subtitle)
                            .foregroundStyle(tokens.mutedForeground)
                    }
                    .font(.system(size: 11))
                    .lineLimit(1)
                }

                Spacer(minLength: 8)

                if isBusy {
                    ProgressView().controlSize(.small)
                } else if let entry, let fix = entry.fix, let title = entry.fixTitle, fix != .openSettings, fix != .retry {
                    SettingsPillButton(title, prominent: fix == .install, disabled: !state.connectionMode.isLive) {
                        runFix(agent.id)
                    }
                }

                Toggle(
                    "",
                    isOn: Binding(
                        get: { !isDisabled },
                        set: { enabled in
                            toggleAgentEnabled(agentId: agent.id, enabled: enabled)
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!state.connectionMode.isLive)

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        expandedAgentID = isExpanded ? nil : agent.id
                    }
                    if !isExpanded {
                        state.ensureAgentOptionsLoaded(for: agent.id)
                        Task { await store.loadAgentDetails(agent: agent, state: state) }
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tokens.mutedForeground)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(tokens.surface2))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.18)) {
                    expandedAgentID = isExpanded ? nil : agent.id
                }
                if !isExpanded {
                    state.ensureAgentOptionsLoaded(for: agent.id)
                    Task { await store.loadAgentDetails(agent: agent, state: state) }
                }
            }

            if isExpanded {
                agentInspector(agent)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
    }

    private func modeChoices(for agentId: String) -> [ConfigChoice] {
        guard let opts = state.agentOptionsById[agentId] else { return [] }
        return opts.config.first(where: { $0.category == "mode" || $0.id == "mode" })?.choices ?? []
    }

    private func agentInspector(_ agent: AgentStatusInfo) -> some View {
        let harnessId = agent.harnessId ?? agent.id
        let modeOptions = modeChoices(for: agent.id)

        let entry = state.agentAvailability[agent.id]
        let installError = state.agentAvailabilityModel.installErrors[agent.id]

        return VStack(alignment: .leading, spacing: 11) {
            if let installError {
                SettingsBannerView(text: installError, kind: .error) {
                    state.agentAvailabilityModel.installErrors[agent.id] = nil
                }
            }
            if let problem = entry?.problem {
                agentProblemBanner(agent, problem: problem, entry: entry)
            }

            // Quick Action Buttons (Update / CLI Update / Auth / Logout / Refresh / Retry)
            HStack(spacing: 8) {
                if agent.update != nil {
                    SettingsPillButton(l10n.tr("settings.agents.update"), icon: "arrow.down.circle", prominent: true) {
                        runAgentAction(agent.id) { try await $0.updateAgent(agentId: agent.id) }
                    }
                }
                if let command = agent.cli?.update?.command {
                    // The user's own program updates by its install's command, shown before it runs.
                    SettingsPillButton(l10n.tr("settings.agents.updateCli"), icon: "terminal") {
                        state.requestAgentUpdate(agent.id, command: command, from: .settings)
                    }
                }
                if agent.signIn != "signed-in" {
                    let methods = actionableAuthMethods(for: agent)
                    ForEach(Array(methods.enumerated()), id: \.element.id) { index, method in
                        if method.type == "terminal", let command = method.command, !command.isEmpty {
                            SettingsPillButton(method.name, icon: "terminal", prominent: index == 0) {
                                launchSignInTerminal(command: command)
                            }
                        } else if method.type == "agent" {
                            SettingsPillButton(method.name, icon: "person.badge.key", prominent: index == 0) {
                                runAgentAction(agent.id) {
                                    try await $0.authenticateAgent(agentId: agent.id, methodId: method.id)
                                    try? await $0.refreshAgentAccount(agentId: agent.id, force: true)
                                }
                            }
                        }
                    }
                }
                if agent.canLogout == true && agent.signIn == "signed-in" {
                    SettingsPillButton(l10n.tr("settings.agents.logout"), destructive: true) {
                        runAgentAction(agent.id) { try await $0.logoutAgent(agentId: agent.id) }
                    }
                }
                SettingsPillButton(l10n.tr("settings.agents.refreshAccount"), icon: "arrow.clockwise") {
                    runAgentAction(agent.id) {
                        try? await $0.refreshAgentAccount(agentId: agent.id, force: true)
                        try? await $0.refreshAgentLimits(agentId: agent.id, force: true)
                    }
                }
                if agent.state == "error" || agent.state == "failed" {
                    SettingsPillButton(l10n.tr("settings.agents.retry"), icon: "bolt") {
                        runAgentAction(agent.id) { try await $0.retryAgent(agentId: agent.id) }
                    }
                }
                Spacer(minLength: 0)
            }

            // Default Start Mode
            if !modeOptions.isEmpty {
                HStack(spacing: 10) {
                    Text(l10n.tr("settings.agents.startMode"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(tokens.secondaryForeground)
                    Spacer()
                    Picker(
                        "",
                        selection: Binding<String>(
                            get: { store.hostSettings.startModes[agent.id] ?? "" },
                            set: { next in
                                var modes = store.hostSettings.startModes
                                if next.isEmpty { modes.removeValue(forKey: agent.id) } else { modes[agent.id] = next }
                                store.hostSettings.startModes = modes
                                let val: JSONValue = next.isEmpty ? .null : .string(next)
                                Task {
                                    await store.patchHostSettings(
                                        ["startModes": .object([agent.id: val])],
                                        state: state,
                                        daemon: daemon
                                    )
                                }
                            }
                        )
                    ) {
                        Text(l10n.tr("settings.agents.startModeDefault")).tag("")
                        ForEach(modeOptions, id: \.value) { opt in
                            Text(opt.name).tag(opt.value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                }
            }

            // API Key Management (when harness supports API key)
            if let keyState = agent.apiKey {
                HStack(spacing: 8) {
                    Text(l10n.tr("settings.agents.apiKeyLabel"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(tokens.secondaryForeground)
                    SecureField(
                        keyState.set ? "••••••••••••••••" : l10n.tr("settings.agents.apiKeyPlaceholder"),
                        text: Binding(
                            get: { apiKeyDraftByAgent[agent.id] ?? "" },
                            set: { apiKeyDraftByAgent[agent.id] = $0 }
                        )
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: tokens.rXS).fill(tokens.codeBackground))
                    .overlay(RoundedRectangle(cornerRadius: tokens.rXS).strokeBorder(tokens.borderEtched, lineWidth: 1))

                    SettingsPillButton(l10n.tr("settings.common.save"), prominent: true) {
                        let key = (apiKeyDraftByAgent[agent.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !key.isEmpty else { return }
                        runAgentAction(agent.id) {
                            try await $0.setAgentApiKey(agentId: agent.id, key: key)
                            await MainActor.run { apiKeyDraftByAgent[agent.id] = "" }
                        }
                    }
                    if keyState.set {
                        SettingsPillButton(l10n.tr("settings.common.clear"), destructive: true) {
                            runAgentAction(agent.id) { try await $0.clearAgentApiKey(agentId: agent.id) }
                        }
                    }
                }
            }

            // Custom Binary Path Override
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1.5) {
                    Text(l10n.tr("settings.agents.binaryPath"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(tokens.secondaryForeground)
                    Text(store.hostSettings.agentBinaryPaths[harnessId] ?? agent.binaryOverride ?? agent.binaryPath ?? l10n.tr("settings.agents.binaryAuto"))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(tokens.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if store.hostSettings.agentBinaryPaths[harnessId] != nil || agent.binaryOverride != nil {
                    SettingsPillButton(l10n.tr("settings.common.reset")) {
                        Task {
                            await store.patchHostSettings(
                                ["agents": .object([harnessId: .object(["binaryPath": .null])])],
                                state: state,
                                daemon: daemon,
                                notice: l10n.tr("settings.common.saved")
                            )
                            await state.refreshAgentsFromHost()
                        }
                    }
                }
                SettingsPillButton(l10n.tr("settings.common.choose")) {
                    chooseExecutable { chosenPath in
                        Task {
                            do {
                                try await store.setAgentBinary(harnessId: harnessId, path: chosenPath, state: state, daemon: daemon)
                                await state.refreshAgentsFromHost()
                                store.showNotice(l10n.tr("settings.common.saved"))
                            } catch {
                                store.showError(error.localizedDescription)
                            }
                        }
                    }
                }
            }

            // Claude Prompt Cache TTL (when available)
            if let claude = store.claudeSettingsByAgent[agent.id] {
                HStack(spacing: 10) {
                    Text(l10n.tr("settings.agents.promptCacheTTL"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(tokens.secondaryForeground)
                    Spacer()
                    Picker(
                        "",
                        selection: Binding<String>(
                            get: { claude.promptCacheTtl ?? "" },
                            set: { next in
                                runAgentAction(agent.id) {
                                    try await $0.setAgentClaudePromptCacheTtl(agentId: agent.id, ttl: next.isEmpty ? nil : next)
                                    await store.loadAgentDetails(agent: agent, state: state)
                                }
                            }
                        )
                    ) {
                        Text(l10n.tr("settings.agents.startModeDefault")).tag("")
                        Text("5m").tag("5m")
                        Text("1h").tag("1h")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 170)
                }
            }

            // Auto-Compact Settings (when harness supports it)
            if let compact = store.autoCompactByAgent[agent.id] {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1.5) {
                        Text(l10n.tr("settings.agents.autoCompact"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(tokens.secondaryForeground)
                        Text("\(compact.min)–\(compact.max) \(compact.unit)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(tokens.mutedForeground)
                    }
                    Spacer()
                    TextField(
                        compact.all.map(String.init) ?? l10n.tr("settings.agents.startModeDefault"),
                        text: Binding(
                            get: { autoCompactDraftByAgent[agent.id] ?? (compact.all.map(String.init) ?? "") },
                            set: { autoCompactDraftByAgent[agent.id] = $0 }
                        )
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5, design: .monospaced))
                    .frame(width: 90)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4.5)
                    .background(RoundedRectangle(cornerRadius: tokens.rXS).fill(tokens.codeBackground))
                    .overlay(RoundedRectangle(cornerRadius: tokens.rXS).strokeBorder(tokens.borderEtched, lineWidth: 1))

                    SettingsPillButton(l10n.tr("settings.common.apply")) {
                        let raw = (autoCompactDraftByAgent[agent.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        let parsed: Int? = raw.isEmpty ? nil : Int(raw)
                        runAgentAction(agent.id) {
                            try await $0.setAgentAutoCompact(agentId: agent.id, model: nil, value: parsed)
                            await store.loadAgentDetails(agent: agent, state: state)
                        }
                    }
                }
            }

            if entry?.problem == nil, let detail = agent.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).fill(tokens.surface2.opacity(0.65)))
    }

    private func toggleAgentEnabled(agentId: String, enabled: Bool) {
        var list = store.hostSettings.disabledAgents
        if enabled {
            list.removeAll { $0 == agentId }
        } else if !list.contains(agentId) {
            list.append(agentId)
        }
        store.hostSettings.disabledAgents = list
        Task {
            await store.patchHostSettings(
                ["disabledAgents": .array(list.map(JSONValue.string))],
                state: state,
                daemon: daemon
            )
            await state.refreshAgentsFromHost()
        }
    }

    private func actionableAuthMethods(for agent: AgentStatusInfo) -> [AgentAuthMethodInfo] {
        let all = (agent.authMethods ?? []).filter { method in
            method.type == "agent" || (method.type == "terminal" && !(method.command?.isEmpty ?? true))
        }
        if state.connectionMode.isRemote {
            let remoteUsable = all.filter { $0.type == "terminal" || $0.delegated }
            if !remoteUsable.isEmpty { return remoteUsable }
        }
        return all
    }

    private func launchSignInTerminal(command: String) {
        let hasWorkbenchWindow = NSApp.windows.contains {
            $0.isVisible && $0.identifier?.rawValue != "settings" && !($0 is NSPanel)
        }
        if hasWorkbenchWindow {
            state.requestTerminalCommand(command, run: true)
            store.showNotice(l10n.tr("settings.agents.signInTerminalOpened", command))
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            store.showNotice(l10n.tr("settings.agents.signInCommandCopied", command))
        }
    }

    private func runAgentAction(_ agentId: String, _ work: @escaping (SartoHostSession) async throws -> Void) {
        guard let host = state.activeHostSession else { return }
        store.busyAgentIDs.insert(agentId)
        Task {
            defer { store.busyAgentIDs.remove(agentId) }
            do {
                try await work(host)
                await state.refreshAgentsFromHost()
                store.showNotice(l10n.tr("settings.common.done"))
            } catch {
                store.showError(error.localizedDescription)
            }
        }
    }

    /// A program to update is a warning; one to install is quiet; anything else stops the agent.
    private func problemColor(_ entry: AgentAvailabilityEntry?) -> Color {
        switch entry?.need {
        case .update?: return tokens.warning
        case .install?, .adapter?: return tokens.mutedForeground
        default: return tokens.danger
        }
    }

    /// Why the harness cannot run, in a sentence, with the host's own detail when it says more.
    /// Its fix is the button on the agent's row.
    private func agentProblemBanner(
        _ agent: AgentStatusInfo,
        problem: AgentHarnessProblem,
        entry: AgentAvailabilityEntry?
    ) -> some View {
        let color = problemColor(entry)
        let detail = agent.detail.flatMap { $0.isEmpty || $0 == problem.text ? nil : $0 }
        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: entry?.need == .install || entry?.need == .adapter ? "arrow.down.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(color)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(problem.text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tokens.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(tokens.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).fill(tokens.surface1))
        .overlay(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).strokeBorder(color.opacity(0.35), lineWidth: 1))
    }

    /// Host settings written through the store, so this page shows the values they leave.
    private var storeSettings: AgentHostSettings {
        let state = state
        let store = store
        let daemon = daemon
        return AgentHostSettings(
            patch: { patch in await store.patchHostSettings(patch, state: state, daemon: daemon) },
            setBinary: { harness, path in
                try await store.setAgentBinary(harnessId: harness, path: path, state: state, daemon: daemon)
            }
        )
    }

    private func runFix(_ agentId: String) {
        let store = store
        AgentFixRunner.run(
            agentId,
            state: state,
            surface: .settings,
            settings: storeSettings,
            openSettings: { expandedAgentID = agentId },
            onError: { message in store.showError(message) }
        )
    }

    private func agentStatusColor(_ state: String) -> Color {
        switch state {
        case "ready", "running": return tokens.success
        case "auth-required", "installing", "starting", "updating": return tokens.warning
        case "error", "failed": return tokens.danger
        default: return tokens.mutedForeground
        }
    }

    /// `showsState` is off when the row already says why the harness cannot run.
    private func agentRowSubtitle(_ agent: AgentStatusInfo, showsState: Bool = true) -> String {
        if agent.task?.state == "failed", let err = agent.task?.error, !err.isEmpty {
            return showsState ? "\(agent.state) · \(err)" : err
        }
        var parts: [String] = showsState ? [agent.state] : []
        if let email = agent.account?.email ?? agent.account?.label, !email.isEmpty {
            parts.append(email)
        } else if let signIn = agent.signIn {
            parts.append(signIn)
        }
        if let path = agent.binaryPath, !path.isEmpty {
            parts.append(URL(fileURLWithPath: path).lastPathComponent)
        }
        return parts.joined(separator: " · ")
    }

    private func chooseExecutable(_ onPicked: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            onPicked(url.path)
        }
    }
}

// MARK: - 7. Memory Management Section

struct MemorySettingsSectionView: View {
    @Bindable var state: SartoState
    @Bindable var store: PrismSettingsStore
    @Bindable var router: PrismSettingsRouter

    @State private var filterText: String = ""
    @State private var editingEntry: MemoryEntryInfo? = nil
    @State private var isAddingNew: Bool = false
    @State private var draftTitle: String = ""
    @State private var draftDesc: String = ""
    @State private var draftBody: String = ""
    @State private var importScan: MemoryImportScanInfo? = nil
    @State private var selectedImportKeys: Set<String> = []
    @State private var showImportSheet: Bool = false

    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    private var filteredEntries: [MemoryEntryInfo] {
        let q = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return store.memoryEntries }
        return store.memoryEntries.filter {
            $0.title.lowercased().contains(q)
                || $0.description.lowercased().contains(q)
                || $0.body.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !state.connectionMode.isLive {
                SettingsBannerView(text: l10n.tr("settings.hostOfflineBanner"), kind: .info)
            }

            SettingsGroupSection(l10n.tr("settings.memory.groupSwitch")) {
                SettingsRowView(
                    id: "memory.enabled",
                    highlightedID: router.highlightedRowID,
                    title: l10n.tr("settings.memory.enabled"),
                    subtitle: l10n.tr("settings.memory.enabledSub")
                ) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { store.memoryOverview?.enabled ?? true },
                            set: { next in
                                Task {
                                    guard let host = state.activeHostSession else { return }
                                    do {
                                        try await host.memorySetEnabled(next)
                                        await store.loadMemorySection(state: state)
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
                    .disabled(!state.connectionMode.isLive)
                }
            }

            // Scope Switcher + Actions
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            scopeChip(
                                title: l10n.tr("thread.memory.global") + " (\(store.memoryOverview?.global.count ?? 0))",
                                active: store.selectedMemoryScope == .global
                            ) {
                                Task { await store.loadMemoryEntries(scope: .global, state: state) }
                            }
                            ForEach(store.memoryOverview?.projects ?? []) { proj in
                                let scope = MemoryScopeSelection.project(path: proj.project, name: proj.name)
                                scopeChip(
                                    title: "\(proj.name) (\(proj.count))",
                                    active: store.selectedMemoryScope == scope
                                ) {
                                    Task { await store.loadMemoryEntries(scope: scope, state: state) }
                                }
                            }
                        }
                    }

                    Spacer(minLength: 6)

                    SettingsPillButton(l10n.tr("settings.memory.import"), icon: "square.and.arrow.down", disabled: !state.connectionMode.isLive) {
                        Task { await scanForImports() }
                    }
                    SettingsPillButton(l10n.tr("settings.memory.add"), icon: "plus", prominent: true, disabled: !state.connectionMode.isLive) {
                        editingEntry = nil
                        draftTitle = ""
                        draftDesc = ""
                        draftBody = ""
                        isAddingNew = true
                    }
                }

                // Filter input
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokens.mutedForeground)
                    TextField(l10n.tr("settings.memory.searchPlaceholder"), text: $filterText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: tokens.rSM).fill(tokens.surface1))
                .overlay(RoundedRectangle(cornerRadius: tokens.rSM).strokeBorder(tokens.borderEtched, lineWidth: 1))

                SettingsCardGroup {
                    if store.isLoadingMemory {
                        HStack {
                            Spacer()
                            ProgressView().controlSize(.small)
                            Spacer()
                        }
                        .padding(24)
                    } else if filteredEntries.isEmpty {
                        Text(l10n.tr("settings.memory.empty"))
                            .font(.system(size: 12))
                            .foregroundStyle(tokens.mutedForeground)
                            .padding(16)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(filteredEntries.enumerated()), id: \.element.id) { idx, entry in
                                if idx > 0 { SettingsRowDivider() }
                                HStack(alignment: .top, spacing: 10) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(entry.title)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(tokens.foreground)
                                        if !entry.description.isEmpty {
                                            Text(entry.description)
                                                .font(.system(size: 11.5))
                                                .foregroundStyle(tokens.secondaryForeground)
                                                .lineLimit(2)
                                        }
                                        if !entry.body.isEmpty {
                                            Text(entry.body)
                                                .font(.system(size: 11))
                                                .foregroundStyle(tokens.mutedForeground)
                                                .lineLimit(2)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    HStack(spacing: 6) {
                                        if case .project(let projPath, _) = store.selectedMemoryScope {
                                            SettingsPillButton(l10n.tr("settings.memory.promote")) {
                                                Task {
                                                    guard let host = state.activeHostSession else { return }
                                                    do {
                                                        _ = try await host.memoryMoveToGlobal(project: projPath, id: entry.id)
                                                        await store.loadMemorySection(state: state)
                                                        store.showNotice(l10n.tr("settings.memory.promoted"))
                                                    } catch {
                                                        store.showError(error.localizedDescription)
                                                    }
                                                }
                                            }
                                        }
                                        SettingsPillButton(l10n.tr("settings.common.edit")) {
                                            editingEntry = entry
                                            draftTitle = entry.title
                                            draftDesc = entry.description
                                            draftBody = entry.body
                                            isAddingNew = true
                                        }
                                        SettingsPillButton(l10n.tr("settings.common.delete"), destructive: true) {
                                            Task {
                                                guard let host = state.activeHostSession else { return }
                                                do {
                                                    try await host.memoryRemove(
                                                        layer: store.selectedMemoryScope.layer,
                                                        project: store.selectedMemoryScope.projectPath,
                                                        id: entry.id
                                                    )
                                                    await store.loadMemorySection(state: state)
                                                } catch {
                                                    store.showError(error.localizedDescription)
                                                }
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                            }
                        }
                    }
                }
                .id("memory.entries")
            }
        }
        .sheet(isPresented: $isAddingNew) {
            memoryEditorSheet
        }
        .sheet(isPresented: $showImportSheet) {
            memoryImportSheet
        }
    }

    private func scopeChip(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: active ? .semibold : .medium))
                .foregroundStyle(active ? .white : tokens.secondaryForeground)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(active ? tokens.primary : tokens.surface2))
        }
        .buttonStyle(.plain)
    }

    private var memoryEditorSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editingEntry == nil ? l10n.tr("settings.memory.add") : l10n.tr("settings.common.edit"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tokens.foreground)

            VStack(alignment: .leading, spacing: 4) {
                Text(l10n.tr("settings.memory.fieldTitle"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(tokens.mutedForeground)
                TextField("", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: tokens.rXS).fill(tokens.codeBackground))
                    .overlay(RoundedRectangle(cornerRadius: tokens.rXS).strokeBorder(tokens.borderEtched, lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(l10n.tr("settings.memory.fieldDesc"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(tokens.mutedForeground)
                TextField("", text: $draftDesc)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: tokens.rXS).fill(tokens.codeBackground))
                    .overlay(RoundedRectangle(cornerRadius: tokens.rXS).strokeBorder(tokens.borderEtched, lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(l10n.tr("settings.memory.fieldBody"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(tokens.mutedForeground)
                TextEditor(text: $draftBody)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 150)
                    .background(RoundedRectangle(cornerRadius: tokens.rXS).fill(tokens.codeBackground))
                    .overlay(RoundedRectangle(cornerRadius: tokens.rXS).strokeBorder(tokens.borderEtched, lineWidth: 1))
            }

            HStack {
                Spacer()
                SettingsPillButton(l10n.tr("thread.entry.cancel")) { isAddingNew = false }
                SettingsPillButton(l10n.tr("settings.common.save"), prominent: true, disabled: draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    Task {
                        guard let host = state.activeHostSession else { return }
                        do {
                            _ = try await host.memorySave(
                                layer: store.selectedMemoryScope.layer,
                                project: store.selectedMemoryScope.projectPath,
                                id: editingEntry?.id,
                                title: draftTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                                description: draftDesc.trimmingCharacters(in: .whitespacesAndNewlines),
                                body: draftBody
                            )
                            isAddingNew = false
                            await store.loadMemorySection(state: state)
                            store.showNotice(l10n.tr("settings.common.saved"))
                        } catch {
                            store.showError(error.localizedDescription)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(tokens.background)
    }

    private var memoryImportSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(l10n.tr("settings.memory.import"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tokens.foreground)

            if let sources = importScan?.sources, !sources.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(sources) { src in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(src.agentName) · \(URL(fileURLWithPath: src.project).lastPathComponent)")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(tokens.mutedForeground)
                                ForEach(src.entries) { entry in
                                    let chosen = selectedImportKeys.contains(entry.key)
                                    Button {
                                        if chosen { selectedImportKeys.remove(entry.key) } else { selectedImportKeys.insert(entry.key) }
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: chosen ? "checkmark.square.fill" : "square")
                                                .foregroundStyle(chosen ? tokens.primary : tokens.mutedForeground)
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(entry.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(tokens.foreground)
                                                Text(entry.description).font(.system(size: 11)).foregroundStyle(tokens.mutedForeground).lineLimit(1)
                                            }
                                            Spacer()
                                        }
                                        .padding(8)
                                        .background(RoundedRectangle(cornerRadius: tokens.rXS).fill(tokens.surface1))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 280)
            } else {
                Text(l10n.tr("settings.memory.noImportable"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(tokens.mutedForeground)
                    .padding(.vertical, 24)
            }

            HStack {
                Spacer()
                SettingsPillButton(l10n.tr("thread.entry.cancel")) { showImportSheet = false }
                SettingsPillButton(l10n.tr("settings.memory.importSelected"), prominent: true, disabled: (importScan?.sources.isEmpty ?? true)) {
                    Task {
                        guard let host = state.activeHostSession, let sources = importScan?.sources else { return }
                        do {
                            let pairs = sources.map { (agentId: $0.agentId, project: $0.project) }
                            let res = try await host.memoryImport(
                                sources: pairs,
                                globalKeys: Array(selectedImportKeys)
                            )
                            showImportSheet = false
                            await store.loadMemorySection(state: state)
                            store.showNotice(l10n.tr("settings.memory.importDone", res.imported))
                        } catch {
                            store.showError(error.localizedDescription)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(tokens.background)
    }

    private func scanForImports() async {
        guard let host = state.activeHostSession else { return }
        do {
            let scan = try await host.memoryImportScan()
            importScan = scan
            selectedImportKeys = Set(scan.sources.flatMap(\.entries).filter(\.aboutUser).map(\.key))
            showImportSheet = true
        } catch {
            store.showError(error.localizedDescription)
        }
    }
}

// MARK: - 8. Git & Terminal Section

struct GitTerminalSettingsSectionView: View {
    @Bindable var state: SartoState
    @Bindable var daemon: LocalDaemonManager
    @Bindable var store: PrismSettingsStore
    @Bindable var router: PrismSettingsRouter

    @State private var selectedProjectPath: String = ""
    @State private var wtBranchTemplate: String = "sarto/{slug}"
    @State private var wtCopyPaths: String = ""
    @State private var wtSetupCmd: String = ""
    @State private var wtWaitForSetup: Bool = true

    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroupSection(l10n.tr("settings.git.group")) {
                SettingsRowView(
                    id: "git.fetch",
                    highlightedID: router.highlightedRowID,
                    title: l10n.tr("settings.git.fetch"),
                    subtitle: l10n.tr("settings.git.fetchSub")
                ) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { store.hostSettings.gitBackgroundFetch },
                            set: { next in
                                store.hostSettings.gitBackgroundFetch = next
                                Task {
                                    await store.patchHostSettings(
                                        ["git": .object(["backgroundFetch": .bool(next)])],
                                        state: state,
                                        daemon: daemon
                                    )
                                }
                            }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!state.connectionMode.isLive)
                }

                SettingsRowDivider()

                SettingsRowView(
                    id: "git.worktreeRoot",
                    highlightedID: router.highlightedRowID,
                    title: l10n.tr("settings.git.worktreeRoot"),
                    subtitle: store.hostSettings.gitWorktreeRoot ?? l10n.tr("settings.git.worktreeRootDefault")
                ) {
                    HStack(spacing: 6) {
                        if store.hostSettings.gitWorktreeRoot != nil {
                            SettingsPillButton(l10n.tr("settings.common.reset")) {
                                store.hostSettings.gitWorktreeRoot = nil
                                Task {
                                    await store.patchHostSettings(
                                        ["git": .object(["worktreeRoot": .null])],
                                        state: state,
                                        daemon: daemon,
                                        notice: l10n.tr("settings.common.saved")
                                    )
                                }
                            }
                        }
                        SettingsPillButton(l10n.tr("settings.common.choose")) {
                            chooseFolder { path in
                                store.hostSettings.gitWorktreeRoot = path
                                Task {
                                    await store.patchHostSettings(
                                        ["git": .object(["worktreeRoot": .string(path)])],
                                        state: state,
                                        daemon: daemon,
                                        notice: l10n.tr("settings.common.saved")
                                    )
                                }
                            }
                        }
                    }
                }

                if !state.projects.isEmpty {
                    SettingsRowDivider()
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(l10n.tr("settings.git.projectWorktree"))
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(tokens.foreground)
                            Spacer()
                            Picker("", selection: $selectedProjectPath) {
                                ForEach(state.projects) { proj in
                                    Text(proj.name).tag(proj.path)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 210)
                        }

                        if !selectedProjectPath.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Text(l10n.tr("settings.git.branchTemplate"))
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(tokens.mutedForeground)
                                        .frame(width: 110, alignment: .leading)
                                    TextField("sarto/{slug}", text: $wtBranchTemplate)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(RoundedRectangle(cornerRadius: tokens.rXS).fill(tokens.codeBackground))
                                        .overlay(RoundedRectangle(cornerRadius: tokens.rXS).strokeBorder(tokens.borderEtched, lineWidth: 1))
                                }

                                HStack(spacing: 8) {
                                    Text(l10n.tr("settings.git.copyPaths"))
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(tokens.mutedForeground)
                                        .frame(width: 110, alignment: .leading)
                                    TextField(l10n.tr("settings.git.copyPathsPlaceholder"), text: $wtCopyPaths)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(RoundedRectangle(cornerRadius: tokens.rXS).fill(tokens.codeBackground))
                                        .overlay(RoundedRectangle(cornerRadius: tokens.rXS).strokeBorder(tokens.borderEtched, lineWidth: 1))
                                }

                                HStack(spacing: 8) {
                                    Text(l10n.tr("settings.git.setupCommand"))
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(tokens.mutedForeground)
                                        .frame(width: 110, alignment: .leading)
                                    TextField("pnpm install", text: $wtSetupCmd)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(RoundedRectangle(cornerRadius: tokens.rXS).fill(tokens.codeBackground))
                                        .overlay(RoundedRectangle(cornerRadius: tokens.rXS).strokeBorder(tokens.borderEtched, lineWidth: 1))
                                }

                                HStack {
                                    Toggle(l10n.tr("settings.git.waitForSetup"), isOn: $wtWaitForSetup)
                                        .font(.system(size: 11.5))
                                        .toggleStyle(.checkbox)
                                    Spacer()
                                    SettingsPillButton(l10n.tr("settings.common.save"), prominent: true) {
                                        saveProjectWorktree()
                                    }
                                }
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: tokens.rSM).fill(tokens.surface2.opacity(0.6)))
                        }
                    }
                    .padding(14)
                }
            }

            SettingsGroupSection(l10n.tr("settings.terminal.group")) {
                SettingsRowView(
                    id: "terminal.shell",
                    highlightedID: router.highlightedRowID,
                    title: l10n.tr("settings.terminal.shell"),
                    subtitle: store.hostSettings.terminalShellPath ?? l10n.tr("settings.terminal.shellDefault")
                ) {
                    HStack(spacing: 6) {
                        if store.hostSettings.terminalShellPath != nil {
                            SettingsPillButton(l10n.tr("settings.common.reset")) {
                                store.hostSettings.terminalShellPath = nil
                                Task {
                                    await store.patchHostSettings(
                                        ["terminal": .object(["shellPath": .null])],
                                        state: state,
                                        daemon: daemon,
                                        notice: l10n.tr("settings.common.saved")
                                    )
                                }
                            }
                        }
                        SettingsPillButton(l10n.tr("settings.common.choose")) {
                            chooseFile { path in
                                Task {
                                    do {
                                        try await store.setShellPath(path, state: state, daemon: daemon)
                                        store.showNotice(l10n.tr("settings.common.saved"))
                                    } catch {
                                        store.showError(error.localizedDescription)
                                    }
                                }
                            }
                        }
                    }
                }

                SettingsRowDivider()

                SettingsRowView(
                    id: "terminal.typographyLink",
                    highlightedID: router.highlightedRowID,
                    title: l10n.tr("settings.terminal.typographyTitle"),
                    subtitle: l10n.tr("settings.terminal.typographySub")
                ) {
                    SettingsPillButton(l10n.tr("settings.terminal.openAppearance"), icon: "arrow.right") {
                        router.jumpTo(section: .appearance, rowID: "terminal.fontSize")
                    }
                }
            }
        }
        .onAppear {
            syncSelectedProject(from: state.projects.map(\.path), forceReload: false)
        }
        .onChange(of: state.projects) { _, nextProjects in
            syncSelectedProject(from: nextProjects.map(\.path), forceReload: false)
        }
        .onChange(of: state.activeHostID) { _, _ in
            syncSelectedProject(from: state.projects.map(\.path), forceReload: true)
        }
        .onChange(of: selectedProjectPath) { _, next in
            loadSelectedProjectWorktree(next)
        }
    }

    private func syncSelectedProject(from paths: [String], forceReload: Bool) {
        if paths.isEmpty {
            selectedProjectPath = ""
            wtBranchTemplate = "sarto/{slug}"
            wtCopyPaths = ""
            wtSetupCmd = ""
            wtWaitForSetup = true
            return
        }
        if selectedProjectPath.isEmpty || !paths.contains(selectedProjectPath) {
            selectedProjectPath = paths[0]
        } else if forceReload {
            loadSelectedProjectWorktree(selectedProjectPath)
        }
    }

    private func loadSelectedProjectWorktree(_ path: String) {
        guard !path.isEmpty else { return }
        Task {
            await store.loadProjectWorktreeSettings(projectPath: path, state: state)
            guard selectedProjectPath == path else { return }
            if let wt = store.worktreeSettingsByProject[path] {
                wtBranchTemplate = wt.branchTemplate
                wtCopyPaths = wt.copy.joined(separator: ", ")
                wtSetupCmd = wt.setup ?? ""
                wtWaitForSetup = wt.waitForSetup
            }
        }
    }

    private func saveProjectWorktree() {
        guard !selectedProjectPath.isEmpty, let host = state.activeHostSession else { return }
        let copies = wtCopyPaths.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let setup = wtSetupCmd.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await host.setProjectWorktreeSettings(
                    path: selectedProjectPath,
                    branchTemplate: wtBranchTemplate.isEmpty ? "sarto/{slug}" : wtBranchTemplate,
                    copy: copies,
                    setup: setup.isEmpty ? nil : setup,
                    waitForSetup: wtWaitForSetup
                )
                store.showNotice(l10n.tr("settings.common.saved"))
            } catch {
                store.showError(error.localizedDescription)
            }
        }
    }

    private func chooseFolder(_ onPicked: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            onPicked(url.path)
        }
    }

    private func chooseFile(_ onPicked: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            onPicked(url.path)
        }
    }
}
