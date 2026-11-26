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
                            get: { state.defaultAgentID ?? "" },
                            set: { state.defaultAgentID = $0.isEmpty ? nil : $0 }
                        )
                    ) {
                        Text(l10n.tr("settings.general.defaultAgentAsk")).tag("")
                        ForEach(state.agents.filter { ($0.disabled ?? false) == false && $0.id != "fake-agent" }) { agent in
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
                    id: "general.confirmQuit",
                    highlightedID: router.highlightedRowID,
                    title: l10n.tr("settings.general.confirmQuit"),
                    subtitle: l10n.tr("settings.general.confirmQuitSub")
                ) {
                    Toggle("", isOn: $state.confirmQuitWhileRunning)
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
    }

    private struct PinnedLightChoice {
        let tag: String
        let agentId: String
        let model: String
        let label: String
    }

    private var pinnedLightAgentChoices: [PinnedLightChoice] {
        var out: [PinnedLightChoice] = []
        for item in store.lightAgents {
            if let opts = state.agentOptionsById[item.agentId],
               let modelOpt = opts.config.first(where: { $0.category == "model" || $0.id == "model" }) {
                let modelId = modelOpt.value.stringValue
                    ?? modelOpt.choices?.first?.value
                    ?? ""
                if !modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let modelLabel = modelOpt.choices?.first(where: { $0.value == modelId })?.name ?? modelId
                    out.append(PinnedLightChoice(
                        tag: "pinned:\(item.agentId)::\(modelId)",
                        agentId: item.agentId,
                        model: modelId,
                        label: "\(item.name) · \(modelLabel)"
                    ))
                }
            }
        }
        if store.hostSettings.lightModelMode == "pinned",
           let aid = store.hostSettings.lightModelAgentId,
           let mid = store.hostSettings.lightModelId,
           !mid.isEmpty {
            let currentTag = "pinned:\(aid)::\(mid)"
            if !out.contains(where: { $0.tag == currentTag }) {
                out.append(PinnedLightChoice(tag: currentTag, agentId: aid, model: mid, label: "\(aid) · \(mid)"))
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

// MARK: - 2. Appearance & Typography Section

struct AppearanceSettingsSectionView: View {
    @Bindable var state: SartoState
    @Bindable var router: PrismSettingsRouter

    @AppStorage("prism.threadWideWidth") private var threadWideWidth: Bool = false
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    private static let uiFontSuggestions = ["", "SF Pro Text", "Inter", "PingFang SC", "Helvetica Neue"]
    private static let codeFontSuggestions = ["", "JetBrains Mono", "SF Mono", "Menlo", "Fira Code", "Hack"]

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
                        if !state.proseFontFamily.isEmpty || !state.codeFontFamily.isEmpty {
                            SettingsPillButton(l10n.tr("settings.common.reset")) {
                                state.proseFontFamily = ""
                                state.codeFontFamily = ""
                            }
                        }
                    }

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(l10n.tr("settings.appearance.proseFont"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(tokens.mutedForeground)
                            Picker("", selection: $state.proseFontFamily) {
                                Text(l10n.tr("settings.appearance.fontSystemDefault")).tag("")
                                ForEach(Self.uiFontSuggestions.dropFirst(), id: \.self) { font in
                                    Text(font).tag(font)
                                }
                            }
                            .labelsHidden()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(l10n.tr("settings.appearance.codeFont"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(tokens.mutedForeground)
                            Picker("", selection: $state.codeFontFamily) {
                                Text(l10n.tr("settings.appearance.fontSystemDefault")).tag("")
                                ForEach(Self.codeFontSuggestions.dropFirst(), id: \.self) { font in
                                    Text(font).tag(font)
                                }
                            }
                            .labelsHidden()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(14)
                .id("appearance.fonts")
            }

            SettingsGroupSection(l10n.tr("settings.appearance.groupMotion")) {
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
            }
        }
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

// MARK: - 3. Dynamic Island & Menu Bar Section (Single Source of Truth)

struct IslandMenuBarSettingsSectionView: View {
    @Bindable var state: SartoState
    @Bindable var island: PrismDynamicIslandCoordinator
    @Bindable var router: PrismSettingsRouter

    var body: some View {
        IslandMenuBarSettingsBody(
            state: state,
            settingsStore: island.settingsStore,
            usageStore: island.usageStore,
            island: island,
            highlightedID: router.highlightedRowID
        )
        .onAppear { island.setUsageViewerVisible(true) }
        .onDisappear { island.setUsageViewerVisible(false) }
    }
}

private struct IslandMenuBarSettingsBody: View {
    @Bindable var state: SartoState
    @ObservedObject var settingsStore: UsageSettingsStore
    @ObservedObject var usageStore: PrismUsageStore
    let island: PrismDynamicIslandCoordinator
    let highlightedID: String?

    @State private var displays = Displays.all()
    @AppStorage("sarto.runningRail.enabled") private var runningRailEnabled: Bool = true
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    private var settings: Binding<UsageIslandSettings> { $settingsStore.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroupSection(l10n.tr("settings.island.groupIsland")) {
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
                    DisplayMapPicker(chosen: settings.wrappedValue.islandDisplays, displays: displays) { display in
                        settingsStore.toggleIslandDisplay(display)
                    }
                }
                .padding(14)
                .disabled(!settings.wrappedValue.islandEnabled)
                .opacity(settings.wrappedValue.islandEnabled ? 1 : 0.45)
                .id("island.displays")

                SettingsRowDivider()

                SettingsRowView(
                    id: "island.subtle",
                    highlightedID: highlightedID,
                    title: l10n.tr("settings.island.subtle"),
                    subtitle: l10n.tr("settings.island.subtleSub")
                ) {
                    Toggle("", isOn: settings.subtleReminders)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(!settings.wrappedValue.islandEnabled)
                }

                SettingsRowDivider()

                SettingsRowView(
                    id: "island.preview",
                    highlightedID: highlightedID,
                    title: l10n.tr("settings.island.previewTitle"),
                    subtitle: l10n.tr("settings.island.previewSub")
                ) {
                    HStack(spacing: 8) {
                        SettingsPillButton(l10n.tr("settings.island.previewPop"), icon: "bell.badge") {
                            island.triggerPreviewPop()
                        }
                        SettingsPillButton(l10n.tr("settings.island.previewApproval"), icon: "checkmark.shield") {
                            island.triggerPreviewApproval()
                        }
                    }
                }
            }

            SettingsGroupSection(l10n.tr("settings.island.groupStack")) {
                let islandOn = settings.wrappedValue.islandEnabled
                let stackOn = islandOn && settings.wrappedValue.islandSessionStack

                SettingsRowView(
                    id: "island.rail",
                    highlightedID: highlightedID,
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

                SettingsRowDivider()

                SettingsRowView(
                    id: "island.stack",
                    highlightedID: highlightedID,
                    title: l10n.tr("settings.island.stack"),
                    subtitle: l10n.tr("settings.island.stackSub")
                ) {
                    Toggle("", isOn: settings.islandSessionStack)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(!islandOn)
                }

                SettingsRowDivider()

                SettingsRowView(
                    id: "island.maxRows",
                    highlightedID: highlightedID,
                    title: l10n.tr("settings.island.maxRows"),
                    subtitle: l10n.tr("settings.island.maxRowsSub")
                ) {
                    Picker("", selection: settings.islandMaxRows) {
                        ForEach(IslandStackOptions.rowChoices, id: \.self) { value in
                            Text("\(value)").tag(value)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                    .disabled(!stackOn)
                }

                SettingsRowDivider()

                SettingsRowView(
                    id: "island.quota",
                    highlightedID: highlightedID,
                    title: l10n.tr("settings.island.quota"),
                    subtitle: l10n.tr("settings.island.quotaSub")
                ) {
                    Toggle("", isOn: settings.islandShowQuota)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(!stackOn)
                }

                SettingsRowDivider()

                SettingsRowView(
                    id: "island.motion",
                    highlightedID: highlightedID,
                    title: l10n.tr("settings.island.motion"),
                    subtitle: l10n.tr("settings.island.motionSub")
                ) {
                    Picker("", selection: settings.islandMotion) {
                        Text(l10n.tr("settings.island.motionArcade")).tag(IslandMotionStyle.arcade)
                        Text(l10n.tr("settings.island.motionLively")).tag(IslandMotionStyle.lively)
                        Text(l10n.tr("settings.island.motionCalm")).tag(IslandMotionStyle.calm)
                        Text(l10n.tr("settings.island.motionStill")).tag(IslandMotionStyle.still)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 268)
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
        }
        .onAppear { displays = Displays.all() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays = Displays.all()
        }
    }
}

// MARK: - 4. Usage & Multi-Mac Sync Section (Consolidated from Menu Bar)

struct UsageSyncSettingsSectionView: View {
    @Bindable var state: SartoState
    @Bindable var daemon: LocalDaemonManager
    @Bindable var island: PrismDynamicIslandCoordinator
    @Bindable var store: PrismSettingsStore
    @Bindable var router: PrismSettingsRouter

    var body: some View {
        UsageSyncSettingsBody(
            state: state,
            daemon: daemon,
            settingsStore: island.settingsStore,
            usageStore: island.usageStore,
            store: store,
            router: router,
            highlightedID: router.highlightedRowID
        )
        .onAppear { island.setUsageViewerVisible(true) }
        .onDisappear { island.setUsageViewerVisible(false) }
    }
}

private struct UsageSyncSettingsBody: View {
    @Bindable var state: SartoState
    @Bindable var daemon: LocalDaemonManager
    @ObservedObject var settingsStore: UsageSettingsStore
    @ObservedObject var usageStore: PrismUsageStore
    @Bindable var store: PrismSettingsStore
    let router: PrismSettingsRouter
    let highlightedID: String?

    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    private var settings: Binding<UsageIslandSettings> { $settingsStore.settings }

    var body: some View {
        let all = settingsStore.ordered(usageStore.providers)
        let activeCount = all.filter { !settings.wrappedValue.hidden.contains($0.id) }.count

        VStack(alignment: .leading, spacing: 18) {
            SettingsGroupSection(l10n.tr("settings.usage.sources"), trailingBadge: "\(activeCount) / \(all.count)") {
                VStack(spacing: 0) {
                    ForEach(Array(all.enumerated()), id: \.element.id) { index, provider in
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
                                .disabled(index == all.count - 1)
                                .opacity(index == all.count - 1 ? 0.35 : 1)
                            }

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
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                    }
                }
                .id("usage.sources")
            }

            SettingsGroupSection(l10n.tr("settings.usage.groupAlertsPrivacy")) {
                SettingsRowView(
                    id: "usage.lowAlert",
                    highlightedID: highlightedID,
                    title: l10n.tr("settings.usage.lowAlert"),
                    subtitle: l10n.tr("settings.usage.lowAlertSub", settings.wrappedValue.lowThreshold)
                ) {
                    Toggle("", isOn: settings.lowAlert)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                SettingsRowDivider()

                SettingsRowView(
                    id: "usage.threshold",
                    highlightedID: highlightedID,
                    title: l10n.tr("settings.usage.threshold"),
                    subtitle: nil
                ) {
                    Picker("", selection: settings.lowThreshold) {
                        ForEach(UsageIslandSettings.lowThresholds, id: \.self) { value in
                            Text("\(value)%").tag(value)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                    .disabled(!settings.wrappedValue.lowAlert)
                }

                SettingsRowDivider()

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
                    subtitle: l10n.tr("settings.usage.fromComputerSub")
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
            }

            let encryptedUsageActive = state.sartoSyncStatus.isVaultReady
            let activeMacCount = max(usageStore.devices.count, state.sartoSyncStatus.usageDevices.count)

            SettingsGroupSection(
                l10n.tr("settings.usage.sync"),
                trailingBadge: encryptedUsageActive && activeMacCount > 0 ? "\(activeMacCount) Mac" : nil
            ) {
                if encryptedUsageActive {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(tokens.success)
                            .padding(.top, 1)
                        Text(l10n.tr("settings.usage.encryptedSyncNote", max(1, activeMacCount)))
                            .font(.system(size: 12))
                            .foregroundStyle(tokens.secondaryForeground)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                } else {
                    // Usage reaches other Macs only through Sarto's encrypted sync, set up with the account.
                    SettingsRowView(
                        id: "usage.sync",
                        highlightedID: highlightedID,
                        title: l10n.tr("settings.usage.syncOffTitle"),
                        subtitle: l10n.tr("settings.usage.syncOffBody")
                    ) {
                        SettingsPillButton(l10n.tr("settings.usage.openCloudSync"), icon: "arrow.right", prominent: true) {
                            router.jumpTo(section: .remoteAndCloud, rowID: "remote.sync")
                        }
                    }
                }

                if encryptedUsageActive {
                    SettingsRowDivider()
                    SettingsRowView(
                        id: "usage.syncScope",
                        highlightedID: highlightedID,
                        title: l10n.tr("settings.usage.syncScope"),
                        subtitle: nil
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

                    if let syncError = usageStore.syncError {
                        SettingsRowDivider()
                        Text(syncError)
                            .font(.system(size: 11.5))
                            .foregroundStyle(tokens.warning)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                    }
                }
            }
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

// MARK: - 5. Notifications Section

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

    var body: some View {
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
                    subtitle: l10n.tr("settings.usage.lowAlertSub", settingsStore.settings.lowThreshold)
                ) {
                    Toggle("", isOn: $settingsStore.settings.lowAlert)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }

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

    private let wheelSize: CGFloat = 176
    private let minBrightness: Double = 0.22

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
                        onChangeHex(currentHex)
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
                                onChangeHex(currentHex)
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
