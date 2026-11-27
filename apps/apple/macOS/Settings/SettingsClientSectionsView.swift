import AppKit
import SartoProtocol
import MenuBarKit
import PrismDesign
import SwiftUI

// MARK: - 1. General Settings Section

struct GeneralSettingsSectionView: View {
    @Bindable var state: SartoState
    @Bindable var daemon: LocalDaemonManager
    @Bindable var island: PrismDynamicIslandCoordinator
    @Bindable var store: PrismSettingsStore
    @Bindable var router: PrismSettingsRouter

    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroupSection(l10n.tr("settings.general.groupInput")) {
                SettingsRowView(
                    id: "general.language",
                    highlightedID: router.highlightedRowID,
                    title: l10n.tr("settings.general.language"),
                    subtitle: l10n.tr("settings.general.languageSub")
                ) {
                    Picker("", selection: $state.language) {
                        ForEach(PrismLanguage.allCases) { lang in
                            Text(lang.pickerLabel(l10n: l10n)).tag(lang)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }

                SettingsRowDivider()

                SettingsRowView(
                    id: "general.sendKey",
                    highlightedID: router.highlightedRowID,
                    title: l10n.tr("settings.general.sendKey"),
                    subtitle: l10n.tr("settings.general.sendKeySub")
                ) {
                    Picker("", selection: $state.sendKeyMode) {
                        Text("Enter").tag(PrismSendKeyMode.enter)
                        Text("⌘ Enter").tag(PrismSendKeyMode.commandEnter)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                }
            }

            SettingsGroupSection(l10n.tr("settings.general.groupSessions")) {
                SettingsRowView(
                    id: "general.defaultAgent",
                    highlightedID: router.highlightedRowID,
                    title: l10n.tr("settings.general.defaultAgent"),
                    subtitle: l10n.tr("settings.general.defaultAgentSub")
                ) {
                    Picker(
                        "",
                        selection: Binding<String>(
                            get: {
                                if state.connectionMode.isRemote {
                                    return store.hostSettings.defaultAgent ?? ""
                                }
                                return state.defaultAgentID ?? store.hostSettings.defaultAgent ?? ""
                            },
                            set: { next in
                                let value: String? = next.isEmpty ? nil : next
                                if !state.connectionMode.isRemote {
                                    state.defaultAgentID = value
                                }
                                store.hostSettings.defaultAgent = value
                                // Keep the active host's general.defaultAgent aligned for background tasks.
                                if state.connectionMode.isLive {
                                    Task {
                                        await store.patchHostSettings(
                                            ["general": .object(["defaultAgent": value.map(JSONValue.string) ?? .null])],
                                            state: state,
                                            daemon: daemon
                                        )
                                    }
                                }
                            }
                        )
                    ) {
                        Text(l10n.tr("settings.general.defaultAgentAsk")).tag("")
                        ForEach(PrismSettingsStore.visibleAgents(from: state.agents).filter { ($0.disabled ?? false) == false }) { agent in
                            Text(agent.name).tag(agent.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                }

                SettingsRowDivider()

                SettingsRowView(
                    id: "general.restore",
                    highlightedID: router.highlightedRowID,
                    title: l10n.tr("settings.general.restore"),
                    subtitle: l10n.tr("settings.general.restoreSub")
                ) {
                    Toggle("", isOn: $state.restoreLastSession)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                SettingsRowDivider()

                SettingsRowView(
                    id: "general.sessionTitles",
                    highlightedID: router.highlightedRowID,
                    title: l10n.tr("settings.general.sessionTitles"),
                    subtitle: l10n.tr("settings.general.sessionTitlesSub")
                ) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { store.hostSettings.sessionTitles },
                            set: { next in
                                store.hostSettings.sessionTitles = next
                                Task {
                                    await store.patchHostSettings(
                                        ["general": .object(["sessionTitles": .bool(next)])],
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
                    id: "general.promptSuggestions",
                    highlightedID: router.highlightedRowID,
                    title: l10n.tr("settings.general.promptSuggestions"),
                    subtitle: l10n.tr("settings.general.promptSuggestionsSub")
                ) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { store.hostSettings.promptSuggestions },
                            set: { next in
                                store.hostSettings.promptSuggestions = next
                                Task {
                                    await store.patchHostSettings(
                                        ["general": .object(["promptSuggestions": .bool(next)])],
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
                    id: "general.lightModel",
                    highlightedID: router.highlightedRowID,
                    title: l10n.tr("settings.general.lightModel"),
                    subtitle: l10n.tr("settings.general.lightModelSub")
                ) {
                    Picker(
                        "",
                        selection: Binding<String>(
                            get: { lightModelSelectionTag },
                            set: { applyLightModelTag($0) }
                        )
                    ) {
                        Text(l10n.tr("settings.general.lightModelAuto")).tag("mode:small")
                        Text(l10n.tr("settings.general.lightModelSession")).tag("mode:session")
                        ForEach(pinnedLightAgentChoices, id: \.tag) { choice in
                            Text(choice.label).tag(choice.tag)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                    .disabled(!state.connectionMode.isLive)
                }
            }

            SettingsGroupSection(l10n.tr("settings.general.groupStartup")) {
                LaunchAtLoginSettingsRow(launch: island.launchAtLogin, highlightedID: router.highlightedRowID)
            }
        }
        .onAppear {
            for item in store.lightAgents where !PrismSettingsStore.retiredAgentIDs.contains(item.agentId) {
                state.ensureAgentOptionsLoaded(for: item.agentId)
            }
        }
    }

    private struct PinnedLightChoice {
        let tag: String
        let agentId: String
        let model: String
        let label: String
    }

    private var pinnedLightAgentChoices: [PinnedLightChoice] {
        var out: [PinnedLightChoice] = []
        var seen: Set<String> = []
        for item in store.lightAgents where !PrismSettingsStore.retiredAgentIDs.contains(item.agentId) {
            guard let opts = state.agentOptionsById[item.agentId],
                  let modelOpt = opts.config.first(where: { $0.category == "model" || $0.id == "model" })
            else { continue }

            let available = modelOpt.choices ?? []
            if !available.isEmpty {
                for choice in available {
                    let mid = choice.value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !mid.isEmpty else { continue }
                    let tag = "pinned:\(item.agentId)::\(mid)"
                    guard seen.insert(tag).inserted else { continue }
                    out.append(PinnedLightChoice(
                        tag: tag,
                        agentId: item.agentId,
                        model: mid,
                        label: "\(item.name) · \(choice.name)"
                    ))
                }
            } else if let mid = modelOpt.value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !mid.isEmpty {
                let tag = "pinned:\(item.agentId)::\(mid)"
                if seen.insert(tag).inserted {
                    out.append(PinnedLightChoice(
                        tag: tag,
                        agentId: item.agentId,
                        model: mid,
                        label: "\(item.name) · \(mid)"
                    ))
                }
            }
        }
        if store.hostSettings.lightModelMode == "pinned",
           let aid = store.hostSettings.lightModelAgentId,
           let mid = store.hostSettings.lightModelId,
           !mid.isEmpty {
            let currentTag = "pinned:\(aid)::\(mid)"
            if seen.insert(currentTag).inserted {
                let agentName = state.agentDisplayName(for: aid)
                out.append(PinnedLightChoice(tag: currentTag, agentId: aid, model: mid, label: "\(agentName) · \(mid)"))
            }
        }
        return out
    }

    private var lightModelSelectionTag: String {
        switch store.hostSettings.lightModelMode {
        case "session":
            return "mode:session"
        case "pinned":
            if let aid = store.hostSettings.lightModelAgentId,
               let mid = store.hostSettings.lightModelId,
               !mid.isEmpty {
                return "pinned:\(aid)::\(mid)"
            }
            return "mode:small"
        default:
            return "mode:small"
        }
    }

    private func applyLightModelTag(_ tag: String) {
        let val: JSONValue
        if tag == "mode:session" {
            store.hostSettings.lightModelMode = "session"
            store.hostSettings.lightModelAgentId = nil
            store.hostSettings.lightModelId = nil
            val = .object(["mode": .string("session")])
        } else if tag.hasPrefix("pinned:"),
                  let choice = pinnedLightAgentChoices.first(where: { $0.tag == tag }) {
            store.hostSettings.lightModelMode = "pinned"
            store.hostSettings.lightModelAgentId = choice.agentId
            store.hostSettings.lightModelId = choice.model
            val = .object([
                "mode": .string("pinned"),
                "agentId": .string(choice.agentId),
                "model": .string(choice.model),
            ])
        } else {
            store.hostSettings.lightModelMode = "small"
            store.hostSettings.lightModelAgentId = nil
            store.hostSettings.lightModelId = nil
            val = .object(["mode": .string("small")])
        }
        Task {
            await store.patchHostSettings(
                ["general": .object(["lightModel": val])],
                state: state,
                daemon: daemon
            )
        }
    }
}

private struct LaunchAtLoginSettingsRow: View {
    @ObservedObject var launch: PrismLaunchAtLogin
    let highlightedID: String?
    @Environment(\.prismL10n) private var l10n

    private var subtitle: String {
        switch launch.state {
        case .unavailable: return l10n.tr("settings.general.launchUnavailable")
        case .requiresApproval: return l10n.tr("settings.general.launchNeedsApproval")
        default: return launch.error ?? l10n.tr("settings.general.launchAtLoginSub")
        }
    }

    var body: some View {
        SettingsRowView(
            id: "general.launchAtLogin",
            highlightedID: highlightedID,
            title: l10n.tr("settings.general.launchAtLogin"),
            subtitle: subtitle
        ) {
            if launch.state == .requiresApproval {
                SettingsPillButton(l10n.tr("settings.general.openLoginItems")) {
                    launch.openSystemSettings()
                }
            } else {
                Toggle(
                    "",
                    isOn: Binding(get: { launch.state == .on }, set: { launch.set($0) })
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(launch.state == .unavailable)
            }
        }
    }
}

// MARK: - Installed System Font Catalog

private enum SystemFontKind: Equatable, Sendable {
    case prose
    case mono
}

@MainActor
private enum SystemFontCatalog {
    static let allFamilies: [String] = {
        NSFontManager.shared.availableFontFamilies
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }()

    static let installedSet: Set<String> = Set(allFamilies)

    private static let proseRecommended = ["SF Pro Text", "Inter", "PingFang SC", "Helvetica Neue", "Avenir Next"]
    private static let monoRecommended = [
        "JetBrains Mono", "SF Mono", "Maple Mono", "Cascadia Code",
        "Fira Code", "Menlo", "Hack", "Sarasa Mono SC",
    ]

    static let proseSections: (preferred: [String], others: [String]) = buildBaseSections(proseRecommended)
    static let monoSections: (preferred: [String], others: [String]) = buildBaseSections(monoRecommended)

    private static func buildBaseSections(_ recommended: [String]) -> (preferred: [String], others: [String]) {
        let preferred = recommended.filter { installedSet.contains($0) }
        let prefSet = Set(preferred)
        let others = allFamilies.filter { !prefSet.contains($0) }
        return (preferred, others)
    }

    static func baseSections(for kind: SystemFontKind) -> (preferred: [String], others: [String]) {
        switch kind {
        case .prose: return proseSections
        case .mono: return monoSections
        }
    }
}

/// Equatable leaf view so unrelated `SartoState` updates never re-diff hundreds of system font items.
private struct SystemFontFamilyMenu: View, Equatable {
    let selection: String
    let kind: SystemFontKind
    let defaultLabel: String
    let onSelect: (String) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.selection == rhs.selection && lhs.kind == rhs.kind && lhs.defaultLabel == rhs.defaultLabel
    }

    var body: some View {
        let base = SystemFontCatalog.baseSections(for: kind)
        let missingCurrent = !selection.isEmpty && !SystemFontCatalog.installedSet.contains(selection)
        Picker(
            "",
            selection: Binding(
                get: { selection },
                set: { onSelect($0) }
            )
        ) {
            Text(defaultLabel).tag("")
            if missingCurrent || !base.preferred.isEmpty {
                Divider()
                if missingCurrent {
                    Text(selection).tag(selection)
                }
                ForEach(base.preferred, id: \.self) { font in
                    Text(font).tag(font)
                }
            }
            if !base.others.isEmpty {
                Divider()
                ForEach(base.others, id: \.self) { font in
                    Text(font).tag(font)
                }
            }
        }
        .labelsHidden()
    }
}

// MARK: - 2. Appearance & Typography Section

struct AppearanceSettingsSectionView: View {
    @Bindable var state: SartoState
    @AppStorage("sarto.runningRail.enabled") private var runningRailEnabled: Bool = true
    @Bindable var router: PrismSettingsRouter

    @AppStorage("prism.threadWideWidth") private var threadWideWidth: Bool = false
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    private var hasCustomTypographyFonts: Bool {
        !state.proseFontFamily.isEmpty || !state.codeFontFamily.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroupSection(l10n.tr("settings.appearance.groupTheme")) {
                SettingsRowView(
                    id: "appearance.colorMode",
                    highlightedID: router.highlightedRowID,
                    title: l10n.tr("settings.appearance.colorMode"),
                    subtitle: l10n.tr("settings.appearance.colorModeSub")
                ) {
                    Picker("", selection: $state.colorMode) {
                        Text(l10n.tr("settings.appearance.modeSystem")).tag(PrismColorMode.system)
                        Text(l10n.tr("settings.appearance.modeDark")).tag(PrismColorMode.dark)
                        Text(l10n.tr("settings.appearance.modeLight")).tag(PrismColorMode.light)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }

                SettingsRowDivider()

                VStack(alignment: .leading, spacing: 10) {
                    Text(l10n.tr("settings.palettes"))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(tokens.mutedForeground)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(PrismPalette.allCases) { p in
                            let preview = PrismTokens.resolved(palette: p, accent: state.accentMode)
                            let selected = state.palette == p
                            Button {
                                withAnimation(PrismSpringSpec.default.animation(tier: state.motionTier)) {
                                    state.selectPaletteDirectly(p)
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(preview.background)
                                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                                            .fill(preview.primary)
                                            .frame(width: 14, height: 14)
                                    }
                                    .frame(width: 30, height: 30)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .strokeBorder(preview.borderStrong, lineWidth: 1)
                                    )

                                    VStack(alignment: .leading, spacing: 1.5) {
                                        Text(p.localizedName(l10n))
                                            .font(.system(size: 12.5, weight: .semibold))
                                            .foregroundStyle(tokens.foreground)
                                        Text(p.localizedSubtitle(l10n))
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(tokens.mutedForeground)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 4)
                                    if selected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 14))
                                            .foregroundStyle(tokens.primary)
                                    }
                                }
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                                        .fill(selected ? tokens.primarySoft : tokens.surface2.opacity(0.65))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                                        .strokeBorder(selected ? tokens.primary : tokens.borderEtched, lineWidth: selected ? 1.5 : 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(14)
                .id("appearance.palette")

                SettingsRowDivider()

                SettingsRowView(
                    id: "appearance.accent",
                    highlightedID: router.highlightedRowID,
                    title: l10n.tr("settings.accents"),
                    subtitle: nil
                ) {
                    PrismAccentPickerControl(state: state)
                }
            }

            SettingsGroupSection(l10n.tr("settings.appearance.groupAppIcon")) {
                AppIconPickerSectionView(
                    state: state,
                    highlighted: router.highlightedRowID == "appearance.appIcon"
                )
                .id("appearance.appIcon")
            }

            SettingsGroupSection(l10n.tr("settings.appearance.groupTypography")) {
                SettingsRowView(
                    id: "appearance.textSize",
                    highlightedID: router.highlightedRowID,
                    title: l10n.tr("settings.appearance.textSize"),
                    subtitle: l10n.tr("settings.appearance.textSizeSub")
                ) {
                    Picker("", selection: $state.textSize) {
                        Text(l10n.tr("settings.appearance.sizeSmall")).tag(PrismTextSize.small)
                        Text(l10n.tr("settings.appearance.sizeDefault")).tag(PrismTextSize.standard)
                        Text(l10n.tr("settings.appearance.sizeLarge")).tag(PrismTextSize.large)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                }

                SettingsRowDivider()

                SettingsRowView(
                    id: "appearance.readingWidth",
                    highlightedID: router.highlightedRowID,
                    title: l10n.tr("settings.appearance.readingWidth"),
                    subtitle: l10n.tr("settings.appearance.readingWidthSub")
                ) {
                    Picker(
                        "",
                        selection: Binding(
                            get: { threadWideWidth },
                            set: { next in
                                guard threadWideWidth != next else { return }
                                threadWideWidth = next
                                state.markUiPrefMutated("threadWideWidth")
                            }
                        )
                    ) {
                        Text(l10n.tr("settings.appearance.widthCompact")).tag(false)
                        Text(l10n.tr("settings.appearance.widthWide")).tag(true)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                }

                SettingsRowDivider()

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(l10n.tr("settings.appearance.fonts"))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(tokens.foreground)
                            Text(l10n.tr("settings.appearance.fontsSub"))
                                .font(.system(size: 11.5))
                                .foregroundStyle(tokens.mutedForeground)
                        }
                        Spacer()
                        if hasCustomTypographyFonts {
                            SettingsPillButton(l10n.tr("settings.common.reset")) {
                                state.proseFontFamily = ""
                                state.codeFontFamily = ""
                            }
                        }
                    }

                    HStack(spacing: 12) {
                        fontFamilyPicker(
                            label: l10n.tr("settings.appearance.proseFont"),
                            selection: state.proseFontFamily,
                            kind: .prose,
                            onSelect: { state.proseFontFamily = $0 }
                        )
                        fontFamilyPicker(
                            label: l10n.tr("settings.appearance.codeFont"),
                            selection: state.codeFontFamily,
                            kind: .mono,
                            onSelect: { state.codeFontFamily = $0 }
                        )
                    }
                }
                .padding(14)
                .id("appearance.fonts")

                SettingsRowDivider()

                SettingsRowView(
                    id: "terminal.fontSize",
                    highlightedID: router.highlightedRowID,
                    title: l10n.tr("settings.terminal.fontSize"),
                    subtitle: l10n.tr("settings.terminal.fontSizeSub")
                ) {
                    Picker("", selection: $state.terminalFontSize) {
                        Text("12 pt").tag(12)
                        Text("13 pt").tag(13)
                        Text("14 pt").tag(14)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                }

                SettingsRowDivider()

                SettingsRowView(
                    id: "terminal.fontFamily",
                    highlightedID: router.highlightedRowID,
                    title: l10n.tr("settings.terminal.fontFamily"),
                    subtitle: nil
                ) {
                    HStack(spacing: 6) {
                        if !state.terminalFontFamily.isEmpty {
                            SettingsPillButton(l10n.tr("settings.common.reset")) {
                                state.terminalFontFamily = ""
                            }
                        }
                        SystemFontFamilyMenu(
                            selection: state.terminalFontFamily,
                            kind: .mono,
                            defaultLabel: l10n.tr("settings.appearance.fontSystemDefault"),
                            onSelect: { state.terminalFontFamily = $0 }
                        )
                        .equatable()
                        .frame(width: 190)
                    }
                }
            }

            SettingsGroupSection(l10n.tr("settings.appearance.groupMotionAndLayout")) {
                SettingsRowView(
                    id: "appearance.motion",
                    highlightedID: router.highlightedRowID,
                    title: l10n.tr("settings.motionTier"),
                    subtitle: l10n.tr("settings.appearance.motionSub")
                ) {
                    Picker("", selection: $state.motionTier) {
                        ForEach(PrismMotionTier.allCases) { tier in
                            Text(l10n.tr("motion.\(tier.rawValue)")).tag(tier)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                }

                SettingsRowDivider()

                SettingsRowView(
                    id: "appearance.rail",
                    highlightedID: router.highlightedRowID,
                    title: l10n.tr("settings.island.rail"),
                    subtitle: l10n.tr("settings.island.railSub")
                ) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { runningRailEnabled },
                            set: { next in
                                guard runningRailEnabled != next else { return }
                                runningRailEnabled = next
                                state.markUiPrefMutated("runningRailEnabled")
                            }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            }
        }
    }

    private func fontFamilyPicker(
        label: String,
        selection: String,
        kind: SystemFontKind,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tokens.mutedForeground)
            SystemFontFamilyMenu(
                selection: selection,
                kind: kind,
                defaultLabel: l10n.tr("settings.appearance.fontSystemDefault"),
                onSelect: onSelect
            )
            .equatable()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AppIconPickerSectionView: View {
    @Bindable var state: SartoState
    let highlighted: Bool

    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: PrismAppIconStyle.allCases.count)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(l10n.tr("settings.appearance.appIconTitle"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tokens.foreground)
                Text(l10n.tr("settings.appearance.appIconSub"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(tokens.mutedForeground)
            }

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(PrismAppIconStyle.allCases) { style in
                    AppIconOptionTile(
                        style: style,
                        selected: state.appIconStyle == style,
                        motionTier: state.motionTier,
                        reduceMotion: reduceMotion
                    ) {
                        withAnimation(PrismSpringSpec.default.animation(tier: state.motionTier, reduceMotion: reduceMotion)) {
                            state.appIconStyle = style
                        }
                        SartoAppIconManager.apply(style)
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                .fill(highlighted ? tokens.primarySoft : Color.clear)
        )
    }
}

private struct AppIconOptionTile: View {
    let style: PrismAppIconStyle
    let selected: Bool
    let motionTier: PrismMotionTier
    let reduceMotion: Bool
    let action: () -> Void

    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack(alignment: .topTrailing) {
                    Image(style.assetName)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 58, height: 58)
                        .scaleEffect(hovered && !reduceMotion && motionTier != .off ? 1.04 : 1.0)

                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(tokens.primary)
                            .background(Circle().fill(tokens.surface1).padding(1.5))
                            .offset(x: 4, y: -2)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 2)

                VStack(spacing: 3) {
                    Text(style.localizedName(l10n))
                        .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? tokens.foreground : tokens.secondaryForeground)
                        .lineLimit(1)

                    if style == .defaultStyle {
                        Text(l10n.tr("settings.appearance.appIconDefaultBadge"))
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(tokens.primary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(tokens.primarySoft))
                    } else {
                        Color.clear.frame(height: 15)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: tokens.rMD, style: .continuous)
                    .fill(selected ? tokens.primarySoft : (hovered ? tokens.hoverWash : tokens.surface2.opacity(0.65)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: tokens.rMD, style: .continuous)
                    .strokeBorder(
                        selected ? tokens.primary : (hovered ? tokens.borderStrong : tokens.borderEtched),
                        lineWidth: selected ? 1.5 : 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier, reduceMotion: reduceMotion)) {
                hovered = isHovering
            }
        }
    }
}

// MARK: - 3. Dynamic Island, Menu Bar & Usage Section (Consolidated)

struct IslandMenuBarSettingsSectionView: View {
    @Bindable var state: SartoState
    @Bindable var daemon: LocalDaemonManager
    @Bindable var island: PrismDynamicIslandCoordinator
    @Bindable var store: PrismSettingsStore
    @Bindable var router: PrismSettingsRouter

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            IslandMenuBarSettingsBody(
                state: state,
                daemon: daemon,
                settingsStore: island.settingsStore,
                usageStore: island.usageStore,
                island: island,
                store: store,
                router: router,
                highlightedID: router.highlightedRowID
            )
            GameSettingsSection(
                state: state,
                store: island.gameStore,
                highlightedID: router.highlightedRowID
            )
        }
        .onAppear { island.setUsageViewerVisible(true) }
        .onDisappear { island.setUsageViewerVisible(false) }
    }
}

private struct IslandMenuBarSettingsBody: View {
    @Bindable var state: SartoState
    @Bindable var daemon: LocalDaemonManager
    @ObservedObject var settingsStore: UsageSettingsStore
    @ObservedObject var usageStore: PrismUsageStore
    let island: PrismDynamicIslandCoordinator
    @Bindable var store: PrismSettingsStore
    let router: PrismSettingsRouter
    let highlightedID: String?

    @State private var displays = Displays.all()
    @State private var showSyncedDevices: Bool = false
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var settings: Binding<UsageIslandSettings> { $settingsStore.settings }

    var body: some View {
        let allProviders = settingsStore.ordered(usageStore.providers)
        let activeProvidersCount = allProviders.filter { !settings.wrappedValue.hidden.contains($0.id) }.count
        let encryptedUsageActive = state.sartoSyncStatus.isVaultReady
        let activeMacCount = max(usageStore.devices.count, state.sartoSyncStatus.usageDevices.count)
        let previewHighlighted = highlightedID == "island.preview"
        let motion = PrismSpringSpec.snappy.animation(tier: state.motionTier, reduceMotion: reduceMotion)

        VStack(alignment: .leading, spacing: 18) {
            SettingsGroupSection(l10n.tr("settings.island.groupIsland")) {
                HStack(spacing: 6) {
                    SettingsPillButton(
                        l10n.tr("settings.island.previewPop"),
                        icon: "bell.badge",
                        disabled: !settings.wrappedValue.islandEnabled
                    ) {
                        island.triggerPreviewPop()
                    }
                    SettingsPillButton(
                        l10n.tr("settings.island.previewApproval"),
                        icon: "checkmark.shield",
                        disabled: !settings.wrappedValue.islandEnabled
                    ) {
                        island.triggerPreviewApproval()
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                        .fill(previewHighlighted ? tokens.primarySoft : Color.clear)
                        .animation(.easeInOut(duration: 0.25), value: previewHighlighted)
                )
                .id("island.preview")
            } content: {
                SettingsRowView(
                    id: "island.enabled",
                    highlightedID: highlightedID,
                    title: l10n.tr("settings.island.show"),
                    subtitle: l10n.tr("settings.island.showSub")
                ) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { settings.wrappedValue.islandEnabled },
                            set: { settingsStore.setIslandEnabled($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                SettingsRowDivider()

                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(l10n.tr("settings.island.displays"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(tokens.foreground)
                        Text(l10n.tr("settings.island.displaysSub"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(tokens.mutedForeground)
                    }
                    DisplayMapPicker(
                        chosen: settings.wrappedValue.islandDisplays,
                        displays: displays,
                        toggle: { settingsStore.toggleIslandDisplay($0) },
                        useAutomatic: { settingsStore.useAutomaticIslandDisplays() }
                    )
                }
                .padding(14)
                .disabled(!settings.wrappedValue.islandEnabled)
                .opacity(settings.wrappedValue.islandEnabled ? 1 : 0.45)
                .id("island.displays")

                SettingsRowDivider()

                SettingsRowView(
                    id: "island.motion",
                    highlightedID: highlightedID,
                    title: l10n.tr("settings.island.motion"),
                    subtitle: l10n.tr("settings.island.motionSub")
                ) {
                    Picker("", selection: settings.islandMotion) {
                        Text(l10n.tr("settings.island.motionLively")).tag(IslandMotionStyle.lively)
                        Text(l10n.tr("settings.island.motionCalm")).tag(IslandMotionStyle.calm)
                        Text(l10n.tr("settings.island.motionStill")).tag(IslandMotionStyle.still)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 268)
                    .disabled(!settings.wrappedValue.islandEnabled)
                }
            }

            SettingsGroupSection(l10n.tr("settings.menubar.groupMenuBar")) {
                SettingsRowView(
                    id: "menubar.enabled",
                    highlightedID: highlightedID,
                    title: l10n.tr("settings.menubar.show"),
                    subtitle: l10n.tr("settings.menubar.showSub")
                ) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { settings.wrappedValue.menubarEnabled },
                            set: { settingsStore.setMenubarEnabled($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                SettingsRowDivider()

                VStack(alignment: .leading, spacing: 12) {
                    StatusItemPreview(
                        image: prismStatusMarkImage(),
                        text: prismStatusTitle(store: usageStore, settings: settingsStore.settings)
                    )

                    HStack(spacing: 12) {
                        Text(l10n.tr("settings.menubar.textMode"))
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(tokens.foreground)
                        Spacer()
                        Picker("", selection: settings.statusText) {
                            ForEach(StatusTextMode.allCases, id: \.self) { mode in
                                Text(mode.label(l10n)).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 240)
                    }
                }
                .padding(14)
                .disabled(!settings.wrappedValue.menubarEnabled)
                .opacity(settings.wrappedValue.menubarEnabled ? 1 : 0.45)
            }

            SettingsGroupSection(
                l10n.tr("settings.usage.sources"),
                trailingBadge: "\(activeProvidersCount) / \(allProviders.count)"
            ) {
                VStack(spacing: 0) {
                    ForEach(Array(allProviders.enumerated()), id: \.element.id) { index, provider in
                        if index > 0 { SettingsRowDivider() }
                        let hidden = settings.wrappedValue.hidden.contains(provider.id)
                        HStack(spacing: 10) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(tokens.surface2)
                                SVGMark(svg: provider.logo, size: 13)
                            }
                            .frame(width: 26, height: 26)
                            .opacity(hidden ? 0.4 : 1)

                            VStack(alignment: .leading, spacing: 1.5) {
                                Text(provider.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(tokens.foreground)
                                Text(providerSubtitle(provider, hidden: hidden))
                                    .font(.system(size: 11))
                                    .foregroundStyle(tokens.mutedForeground)
                                    .lineLimit(1)
                            }
                            .opacity(hidden ? 0.45 : 1)

                            Spacer(minLength: 8)

                            HStack(spacing: 4) {
                                Button {
                                    settingsStore.moveBy(provider.id, offset: -1, all: usageStore.providers)
                                } label: {
                                    Image(systemName: "chevron.up")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(tokens.mutedForeground)
                                        .frame(width: 22, height: 22)
                                        .background(Circle().fill(tokens.surface2))
                                }
                                .buttonStyle(.plain)
                                .disabled(index == 0)
                                .opacity(index == 0 ? 0.35 : 1)

                                Button {
                                    settingsStore.moveBy(provider.id, offset: 1, all: usageStore.providers)
                                } label: {
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(tokens.mutedForeground)
                                        .frame(width: 22, height: 22)
                                        .background(Circle().fill(tokens.surface2))
                                }
                                .buttonStyle(.plain)
                                .disabled(index == allProviders.count - 1)
                                .opacity(index == allProviders.count - 1 ? 0.35 : 1)
                            }

                            let lastShown = !hidden && activeProvidersCount <= 1
                            Toggle(
                                "",
                                isOn: Binding(
                                    get: { !hidden },
                                    set: { on in _ = settingsStore.setVisible(provider.id, on, all: usageStore.providers) }
                                )
                            )
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .disabled(lastShown)
                            .help(lastShown ? l10n.tr("settings.usage.lastSourceHelp") : "")
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                    }
                }
                .id("usage.sources")
            }

            SettingsGroupSection(
                l10n.tr("settings.usage.groupDisplay"),
                trailingBadge: encryptedUsageActive && activeMacCount > 0 ? "\(activeMacCount) Mac" : nil
            ) {
                SettingsRowView(
                    id: "usage.privacy",
                    highlightedID: highlightedID,
                    title: l10n.tr("settings.usage.privacy"),
                    subtitle: l10n.tr("settings.usage.privacySub")
                ) {
                    Toggle("", isOn: settings.privacy)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                SettingsRowDivider()

                SettingsRowView(
                    id: "usage.fromComputer",
                    highlightedID: highlightedID,
                    title: l10n.tr("settings.usage.fromComputer"),
                    subtitle: state.connectionMode.isRemote
                        ? l10n.tr("settings.usage.fromComputerRemoteSub", state.activeHostSnapshot.name)
                        : l10n.tr("settings.usage.fromComputerSub")
                ) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { store.hostSettings.usageFromComputer },
                            set: { next in
                                store.hostSettings.usageFromComputer = next
                                Task {
                                    await store.patchHostSettings(
                                        ["usage": .object(["fromComputer": .bool(next)])],
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

                if encryptedUsageActive {
                    SettingsRowView(
                        id: "usage.syncScope",
                        highlightedID: highlightedID,
                        title: l10n.tr("settings.usage.syncScope"),
                        subtitle: l10n.tr("settings.usage.encryptedSyncNote", max(1, activeMacCount))
                    ) {
                        Picker("", selection: settings.usageScope) {
                            ForEach(UsageScope.allCases, id: \.self) { scope in
                                Text(scope.label(l10n)).tag(scope)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 190)
                    }

                    if usageStore.devices.contains(where: { !$0.isThisMac }) {
                        SettingsRowDivider()
                        Button {
                            withAnimation(motion) {
                                showSyncedDevices.toggle()
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: showSyncedDevices ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(tokens.mutedForeground)
                                    .frame(width: 12)
                                Text(l10n.tr("settings.usage.syncedDevices", usageStore.devices.count))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(tokens.secondaryForeground)
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if showSyncedDevices {
                            ForEach(usageStore.devices) { device in
                                SettingsRowDivider()
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(device.name)
                                                .font(.system(size: 12.5, weight: .medium))
                                                .foregroundStyle(tokens.foreground)
                                            if device.isThisMac {
                                                Text(l10n.tr("settings.usage.thisMac"))
                                                    .font(.system(size: 10, weight: .semibold))
                                                    .foregroundStyle(tokens.primary)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 1.5)
                                                    .background(Capsule().fill(tokens.primarySoft))
                                            }
                                        }
                                        Text(device.updatedAt.map { UsageAgo.text($0, l10n: l10n) } ?? "—")
                                            .font(.system(size: 11))
                                            .foregroundStyle(tokens.mutedForeground)
                                    }
                                    Spacer()
                                    if !device.isThisMac {
                                        SettingsPillButton(l10n.tr("settings.common.remove"), destructive: true) {
                                            usageStore.removeDevice(device.id)
                                        }
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                            }
                        }
                    }

                    if let syncError = usageStore.syncError {
                        SettingsRowDivider()
                        Text(syncError)
                            .font(.system(size: 11.5))
                            .foregroundStyle(tokens.warning)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                    }
                } else {
                    SettingsRowView(
                        id: "usage.syncScope",
                        highlightedID: highlightedID,
                        title: l10n.tr("settings.usage.sync"),
                        subtitle: l10n.tr("settings.usage.syncOffBody")
                    ) {
                        SettingsPillButton(l10n.tr("settings.usage.openCloudSync"), icon: "arrow.right", prominent: true) {
                            router.jumpTo(section: .remoteAndCloud, rowID: "remote.sync")
                        }
                    }
                }
            }
        }
        .onAppear { displays = Displays.all() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays = Displays.all()
        }
    }

    private func providerSubtitle(_ provider: ProviderUsage, hidden: Bool) -> String {
        if !provider.available { return l10n.tr("settings.usage.providerNotFound") }
        if hidden { return l10n.tr("settings.usage.providerHidden") }
        if let rem = provider.remaining {
            return "\(Int((rem * 100).rounded()))%"
        }
        return provider.note ?? provider.plan
    }
}

// MARK: - 4. Notifications Section

struct NotificationsSettingsSectionView: View {
    @Bindable var state: SartoState
    @Bindable var island: PrismDynamicIslandCoordinator
    @Bindable var router: PrismSettingsRouter

    var body: some View {
        NotificationsSettingsBody(
            state: state,
            settingsStore: island.settingsStore,
            highlightedID: router.highlightedRowID
        )
    }
}

private struct NotificationsSettingsBody: View {
    @Bindable var state: SartoState
    @ObservedObject var settingsStore: UsageSettingsStore
    let highlightedID: String?

    @Environment(\.prismL10n) private var l10n
    @Environment(\.prismTokens) private var tokens
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let motion = PrismSpringSpec.snappy.animation(tier: state.motionTier, reduceMotion: reduceMotion)

        VStack(alignment: .leading, spacing: 18) {
            SettingsGroupSection(l10n.tr("settings.notifications.groupEvents")) {
                SettingsRowView(
                    id: "notifications.permission",
                    highlightedID: highlightedID,
                    title: l10n.tr("settings.notifications.permission"),
                    subtitle: l10n.tr("settings.notifications.permissionSub")
                ) {
                    Toggle("", isOn: $state.notificationPrefs.permissionNeeded)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                SettingsRowDivider()

                SettingsRowView(
                    id: "notifications.turnEnded",
                    highlightedID: highlightedID,
                    title: l10n.tr("settings.notifications.turnEnded"),
                    subtitle: l10n.tr("settings.notifications.turnEndedSub")
                ) {
                    Toggle("", isOn: $state.notificationPrefs.turnEnded)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                SettingsRowDivider()

                SettingsRowView(
                    id: "notifications.error",
                    highlightedID: highlightedID,
                    title: l10n.tr("settings.notifications.error"),
                    subtitle: l10n.tr("settings.notifications.errorSub")
                ) {
                    Toggle("", isOn: $state.notificationPrefs.error)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                SettingsRowDivider()

                SettingsRowView(
                    id: "notifications.lowQuota",
                    highlightedID: highlightedID,
                    title: l10n.tr("settings.usage.lowAlert"),
                    subtitle: l10n.tr("settings.notifications.lowQuotaSub")
                ) {
                    Picker(
                        "",
                        selection: Binding(
                            get: { settingsStore.settings.lowQuotaAlert },
                            set: { next in
                                withAnimation(motion) {
                                    settingsStore.settings.lowQuotaAlert = next
                                }
                            }
                        )
                    ) {
                        Text(l10n.tr("settings.notifications.lowQuota.pop")).tag(LowQuotaAlertMode.pop)
                        Text(l10n.tr("settings.notifications.lowQuota.badge")).tag(LowQuotaAlertMode.badge)
                        Text(l10n.tr("settings.notifications.lowQuota.off")).tag(LowQuotaAlertMode.off)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }

                let showThresholdRow = settingsStore.settings.lowAlert || highlightedID == "notifications.threshold"
                if showThresholdRow {
                    SettingsRowDivider()

                    SettingsRowView(
                        id: "notifications.threshold",
                        highlightedID: highlightedID,
                        title: l10n.tr("settings.usage.threshold"),
                        subtitle: l10n.tr("settings.notifications.thresholdSub")
                    ) {
                        Picker("", selection: $settingsStore.settings.lowThreshold) {
                            ForEach(UsageIslandSettings.lowThresholds, id: \.self) { value in
                                Text("\(value)%").tag(value)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 210)
                        .disabled(!settingsStore.settings.lowAlert)
                        .opacity(settingsStore.settings.lowAlert ? 1 : 0.5)
                    }
                }
            }
            .animation(motion, value: settingsStore.settings.lowAlert || highlightedID == "notifications.threshold")

            Text(l10n.tr(
                settingsStore.settings.islandEnabled
                    ? "settings.notifications.deliveryIsland"
                    : "settings.notifications.deliverySystem"
            ))
            .font(.system(size: 11.5))
            .foregroundStyle(tokens.mutedForeground)
            .padding(.horizontal, 4)
            .fixedSize(horizontal: false, vertical: true)

            SettingsGroupSection(l10n.tr("settings.notifications.groupDelivery")) {
                SettingsRowView(
                    id: "notifications.inAppPill",
                    highlightedID: highlightedID,
                    title: l10n.tr("settings.notifications.inAppPill"),
                    subtitle: l10n.tr("settings.notifications.inAppPillSub")
                ) {
                    Picker("", selection: $state.notificationPrefs.inAppNoticeMode) {
                        Text(l10n.tr("settings.notifications.inAppPill.important")).tag(PrismInAppNoticeMode.importantOnly)
                        Text(l10n.tr("settings.notifications.inAppPill.all")).tag(PrismInAppNoticeMode.all)
                        Text(l10n.tr("settings.notifications.inAppPill.off")).tag(PrismInAppNoticeMode.off)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }

                SettingsRowDivider()

                SettingsRowView(
                    id: "notifications.sound",
                    highlightedID: highlightedID,
                    title: l10n.tr("settings.notifications.sound"),
                    subtitle: l10n.tr("settings.notifications.soundSub")
                ) {
                    Toggle("", isOn: $state.notificationPrefs.soundEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                SettingsRowDivider()

                SettingsRowView(
                    id: "notifications.badge",
                    highlightedID: highlightedID,
                    title: l10n.tr("settings.notifications.badge"),
                    subtitle: l10n.tr("settings.notifications.badgeSub")
                ) {
                    Toggle("", isOn: $state.notificationPrefs.dockBadgeEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
        }
    }
}

// MARK: - Accent Swatches & Circular Color Wheel Popover

private struct PrismAccentPickerControl: View {
    @Bindable var state: SartoState

    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var hoveredSwatchID: String?
    @State private var wheelHovered = false
    @State private var showColorWheel = false

    private var isCustomWheelActive: Bool {
        guard case .custom = state.accentMode else { return false }
        return !PrismAccentSwatch.curated.contains { $0.mode == state.accentMode }
    }

    private var activeHex: UInt32 {
        PrismTokens.resolvedPrimaryHex(palette: state.palette, accent: state.accentMode)
    }

    private var wheelTooltip: String {
        if isCustomWheelActive, let hex = state.accentMode.customHex {
            return l10n.tr("accent.customValue", String(format: "#%06X", hex))
        }
        return l10n.tr("accent.customPicker")
    }

    var body: some View {
        let motion = PrismSpringSpec.snappy.animation(tier: state.motionTier, reduceMotion: reduceMotion)
        let followSelected = state.accentMode == .model

        HStack(spacing: 10) {
            Button {
                withAnimation(motion) {
                    state.accentMode = .model
                }
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(state.palette.defaultPrimaryColor)
                        .frame(width: 9, height: 9)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white.opacity(tokens.palette.isDark ? 0.28 : 0.45), lineWidth: 0.5)
                        )
                    Text(l10n.tr("accent.model"))
                        .font(.system(size: 11.5, weight: followSelected ? .semibold : .regular))
                        .foregroundStyle(followSelected ? tokens.foreground : tokens.secondaryForeground)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(followSelected ? tokens.activeWash : tokens.surface2))
                .overlay(Capsule().strokeBorder(followSelected ? tokens.primary : tokens.borderEtched, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()

            Rectangle()
                .fill(tokens.borderEtched)
                .frame(width: 1, height: 14)

            HStack(spacing: 7) {
                ForEach(PrismAccentSwatch.curated) { swatch in
                    let selected = state.accentMode == swatch.mode
                    let hovered = hoveredSwatchID == swatch.id
                    Button {
                        withAnimation(motion) {
                            state.accentMode = swatch.mode
                        }
                    } label: {
                        ZStack {
                            if selected {
                                Circle()
                                    .strokeBorder(swatch.color, lineWidth: 1.5)
                                    .frame(width: 22, height: 22)
                            }
                            Circle()
                                .fill(swatch.color)
                                .overlay(
                                    LinearGradient(
                                        colors: [Color.white.opacity(0.28), Color.clear],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                    .clipShape(Circle())
                                )
                                .overlay(
                                    Circle()
                                        .strokeBorder(
                                            tokens.palette.isDark ? Color.white.opacity(0.16) : Color.black.opacity(0.12),
                                            lineWidth: 0.5
                                        )
                                )
                                .frame(width: selected ? 16 : 17, height: selected ? 16 : 17)
                        }
                        .frame(width: 22, height: 22)
                        .scaleEffect(hovered && !selected ? 1.12 : 1.0)
                        .animation(PrismSpringSpec.micro.animation(tier: state.motionTier, reduceMotion: reduceMotion), value: hovered)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(l10n.tr(swatch.labelKey))
                    .accessibilityLabel(l10n.tr(swatch.labelKey))
                    .onHover { inside in
                        hoveredSwatchID = inside ? swatch.id : (hoveredSwatchID == swatch.id ? nil : hoveredSwatchID)
                    }
                }
            }

            Button {
                showColorWheel.toggle()
            } label: {
                ZStack {
                    if isCustomWheelActive {
                        Circle()
                            .strokeBorder(Color(hex: activeHex), lineWidth: 1.5)
                            .frame(width: 24, height: 24)
                    }

                    Circle()
                        .strokeBorder(
                            AngularGradient(
                                colors: [
                                    Color(hex: 0xEF5B6C),
                                    Color(hex: 0xF2B84B),
                                    Color(hex: 0x2E9E72),
                                    Color(hex: 0x1499A6),
                                    Color(hex: 0x3B82F6),
                                    Color(hex: 0x8E63D2),
                                    Color(hex: 0xEF5B6C),
                                ],
                                center: .center
                            ),
                            lineWidth: isCustomWheelActive ? 2.2 : 2.6
                        )
                        .frame(width: 19, height: 19)

                    if isCustomWheelActive {
                        Circle()
                            .fill(Color(hex: activeHex))
                            .frame(width: 12, height: 12)
                    } else {
                        Circle()
                            .fill(tokens.surface1)
                            .frame(width: 13, height: 13)
                        Image(systemName: "plus")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundStyle(tokens.mutedForeground)
                    }
                }
                .frame(width: 24, height: 24)
                .scaleEffect(wheelHovered && !isCustomWheelActive ? 1.10 : 1.0)
                .animation(PrismSpringSpec.micro.animation(tier: state.motionTier, reduceMotion: reduceMotion), value: wheelHovered)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(wheelTooltip)
            .accessibilityLabel(wheelTooltip)
            .onHover { wheelHovered = $0 }
            .popover(isPresented: $showColorWheel, arrowEdge: .bottom) {
                PrismColorWheelPopover(
                    initialHex: activeHex,
                    onChangeHex: { pickedHex in
                        state.accentMode = .custom(pickedHex)
                    }
                )
                .environment(\.prismTokens, tokens)
                .environment(\.prismL10n, l10n)
                .preferredColorScheme(tokens.palette.colorScheme)
            }
        }
        .fixedSize()
    }
}

private struct PrismColorWheelPopover: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    let initialHex: UInt32
    let onChangeHex: (UInt32) -> Void

    @State private var hue: Double = 0.6
    @State private var saturation: Double = 0.72
    @State private var brightness: Double = 0.92
    @State private var didSeed = false
    @State private var hasInteracted = false
    @State private var lastCommittedHex: UInt32?
    @State private var lastCommitTime: ContinuousClock.Instant?
    @State private var pendingHex: UInt32?
    @State private var pendingCommitTask: Task<Void, Never>?

    private let wheelSize: CGFloat = 176
    private let minBrightness: Double = 0.22
    private static let dragCommitInterval: Duration = .milliseconds(120)

    private var currentHex: UInt32 {
        Self.hsbToHex(h: hue, s: saturation, b: brightness)
    }

    var body: some View {
        let radius = wheelSize * 0.5
        let thumbAngle = hue * 2.0 * .pi
        let thumbRadius = saturation * (radius - 7)
        let thumbX = radius + CGFloat(cos(thumbAngle)) * thumbRadius
        let thumbY = radius + CGFloat(sin(thumbAngle)) * thumbRadius
        let currentColor = Color(hex: currentHex)

        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        AngularGradient(
                            colors: [
                                Color(hue: 0.0 / 6.0, saturation: 1, brightness: 1),
                                Color(hue: 1.0 / 6.0, saturation: 1, brightness: 1),
                                Color(hue: 2.0 / 6.0, saturation: 1, brightness: 1),
                                Color(hue: 3.0 / 6.0, saturation: 1, brightness: 1),
                                Color(hue: 4.0 / 6.0, saturation: 1, brightness: 1),
                                Color(hue: 5.0 / 6.0, saturation: 1, brightness: 1),
                                Color(hue: 1.0, saturation: 1, brightness: 1),
                            ],
                            center: .center,
                            startAngle: .degrees(0),
                            endAngle: .degrees(360)
                        )
                    )
                    .overlay(
                        RadialGradient(
                            colors: [Color.white, Color.white.opacity(0)],
                            center: .center,
                            startRadius: 0,
                            endRadius: radius
                        )
                    )
                    .overlay(Color.black.opacity(max(0, 1.0 - brightness)))
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .strokeBorder(tokens.borderStrong, lineWidth: 1)
                    )

                Circle()
                    .fill(currentColor)
                    .frame(width: 16, height: 16)
                    .overlay(Circle().strokeBorder(Color.white, lineWidth: 2))
                    .shadow(color: Color.black.opacity(0.32), radius: 3, x: 0, y: 1)
                    .position(x: thumbX, y: thumbY)
                    .allowsHitTesting(false)
            }
            .frame(width: wheelSize, height: wheelSize)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let dx = Double(value.location.x - radius)
                        let dy = Double(value.location.y - radius)
                        let dist = hypot(dx, dy)
                        saturation = min(1.0, dist / Double(radius))
                        let rawAngle = atan2(dy, dx)
                        let normalized = rawAngle < 0 ? rawAngle + 2.0 * .pi : rawAngle
                        hue = normalized / (2.0 * .pi)
                        scheduleHexCommit(currentHex, immediate: false)
                    }
                    .onEnded { _ in
                        scheduleHexCommit(currentHex, immediate: true)
                    }
            )

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(l10n.tr("accent.brightness"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(tokens.mutedForeground)
                    Spacer()
                    Text("\(Int((brightness * 100).rounded()))%")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(tokens.secondaryForeground)
                }

                GeometryReader { geo in
                    let w = max(1, geo.size.width)
                    let frac = max(0, min(1, (brightness - minBrightness) / (1.0 - minBrightness)))
                    let knobX = 8 + CGFloat(frac) * max(0, w - 16)
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(hue: hue, saturation: saturation, brightness: minBrightness),
                                        Color(hue: hue, saturation: saturation, brightness: 1.0),
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .overlay(Capsule().strokeBorder(tokens.borderEtched, lineWidth: 0.75))
                            .frame(height: 10)

                        Circle()
                            .fill(currentColor)
                            .frame(width: 15, height: 15)
                            .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.8))
                            .shadow(color: Color.black.opacity(0.28), radius: 2, x: 0, y: 1)
                            .position(x: knobX, y: geo.size.height * 0.5)
                            .allowsHitTesting(false)
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let t = max(0, min(1, Double((value.location.x - 8) / max(1, w - 16))))
                                brightness = minBrightness + t * (1.0 - minBrightness)
                                scheduleHexCommit(currentHex, immediate: false)
                            }
                            .onEnded { _ in
                                scheduleHexCommit(currentHex, immediate: true)
                            }
                    )
                }
                .frame(height: 18)
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(currentColor)
                    .frame(width: 16, height: 16)
                    .overlay(
                        Circle()
                            .strokeBorder(
                                tokens.palette.isDark ? Color.white.opacity(0.18) : Color.black.opacity(0.14),
                                lineWidth: 0.75
                            )
                    )
                Text(String(format: "#%06X", currentHex))
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(tokens.foreground)
                Spacer()
            }
        }
        .padding(14)
        .frame(width: 212)
        .background(tokens.popoverBackground)
        .onAppear {
            guard !didSeed else { return }
            didSeed = true
            let hsb = Self.rgbToHSB(initialHex)
            hue = hsb.h
            saturation = hsb.s
            brightness = max(minBrightness, hsb.b)
        }
        .onDisappear {
            pendingCommitTask?.cancel()
            pendingCommitTask = nil
            if hasInteracted {
                scheduleHexCommit(currentHex, immediate: true)
            }
        }
    }

    /// Keeps the wheel thumb at display refresh rate while throttling global `SartoState.accentMode`
    /// writes (UserDefaults, sync timestamp JSON encoding, and full-window token recomputation).
    private func scheduleHexCommit(_ hex: UInt32, immediate: Bool) {
        hasInteracted = true
        pendingHex = hex
        if immediate {
            pendingCommitTask?.cancel()
            pendingCommitTask = nil
            if hex != lastCommittedHex {
                lastCommittedHex = hex
                lastCommitTime = .now
                onChangeHex(hex)
            }
            return
        }
        guard hex != lastCommittedHex else { return }
        let now = ContinuousClock.Instant.now
        if let lastCommitTime {
            let elapsed = lastCommitTime.duration(to: now)
            if elapsed < Self.dragCommitInterval {
                if pendingCommitTask == nil {
                    let delay = Self.dragCommitInterval - elapsed
                    pendingCommitTask = Task { @MainActor in
                        try? await Task.sleep(for: delay)
                        pendingCommitTask = nil
                        guard !Task.isCancelled, let latest = pendingHex, latest != lastCommittedHex else { return }
                        lastCommittedHex = latest
                        self.lastCommitTime = .now
                        onChangeHex(latest)
                    }
                }
                return
            }
        }
        pendingCommitTask?.cancel()
        pendingCommitTask = nil
        lastCommittedHex = hex
        lastCommitTime = now
        onChangeHex(hex)
    }

    private static func rgbToHSB(_ hex: UInt32) -> (h: Double, s: Double, b: Double) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        let maxV = max(r, max(g, b))
        let minV = min(r, min(g, b))
        let delta = maxV - minV
        var h = 0.0
        if delta > 1e-6 {
            if maxV == r {
                h = ((g - b) / delta).truncatingRemainder(dividingBy: 6.0)
            } else if maxV == g {
                h = (b - r) / delta + 2.0
            } else {
                h = (r - g) / delta + 4.0
            }
            h /= 6.0
            if h < 0 { h += 1.0 }
        }
        let s = maxV > 1e-6 ? delta / maxV : 0.0
        return (h, s, maxV)
    }

    private static func hsbToHex(h: Double, s: Double, b: Double) -> UInt32 {
        let hh = ((h.truncatingRemainder(dividingBy: 1.0)) + 1.0).truncatingRemainder(dividingBy: 1.0)
        let ss = max(0, min(1, s))
        let bb = max(0, min(1, b))
        let c = bb * ss
        let x = c * (1.0 - abs((hh * 6.0).truncatingRemainder(dividingBy: 2.0) - 1.0))
        let m = bb - c
        let (r1, g1, b1): (Double, Double, Double)
        switch hh * 6.0 {
        case 0..<1: (r1, g1, b1) = (c, x, 0)
        case 1..<2: (r1, g1, b1) = (x, c, 0)
        case 2..<3: (r1, g1, b1) = (0, c, x)
        case 3..<4: (r1, g1, b1) = (0, x, c)
        case 4..<5: (r1, g1, b1) = (x, 0, c)
        default:    (r1, g1, b1) = (c, 0, x)
        }
        let r = UInt32(round((r1 + m) * 255.0))
        let g = UInt32(round((g1 + m) * 255.0))
        let bv = UInt32(round((b1 + m) * 255.0))
        return (r << 16) | (g << 8) | bv
    }
}
