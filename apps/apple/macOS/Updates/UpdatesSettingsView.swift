import PrismDesign
import SartoUpdate
import SwiftUI

/// Settings › Updates & About › Updates: where the updater stands, what it found, and when it
/// downloads and installs.
struct UpdatesSettingsGroup: View {
    @Bindable var updater: SartoUpdater
    @Bindable var router: PrismSettingsRouter

    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    var body: some View {
        SettingsGroupSection(l10n.tr("settings.updates.title"), trailingBadge: "v\(updater.current)") {
            SettingsRowView(
                id: "advanced.updates",
                highlightedID: router.highlightedRowID,
                title: statusTitle,
                subtitle: statusDetail
            ) {
                statusControl
            }

            if let notes = noticeNotes, !notes.isEmpty {
                whatsNew(notes)
            }

            if case .off = updater.state {} else {
                SettingsRowDivider()
                SettingsRowView(
                    id: "advanced.updates.automatic",
                    highlightedID: router.highlightedRowID,
                    title: l10n.tr("settings.updates.automatic"),
                    subtitle: l10n.tr("settings.updates.automaticSub")
                ) {
                    Picker("", selection: choiceBinding) {
                        ForEach(choices, id: \.self) { choice in
                            Text(label(for: choice)).tag(choice)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                SettingsRowDivider()
                SettingsRowView(
                    id: "advanced.updates.channel",
                    highlightedID: router.highlightedRowID,
                    title: l10n.tr("settings.updates.channel"),
                    subtitle: l10n.tr(updater.channelChoice == .beta ? "settings.updates.channel.betaSub" : "settings.updates.channel.stableSub")
                ) {
                    Picker("", selection: $updater.channelChoice) {
                        Text(l10n.tr("settings.updates.channel.stable")).tag(UpdateChannel.stable)
                        Text(l10n.tr("settings.updates.channel.beta")).tag(UpdateChannel.beta)
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                SettingsRowDivider()
                SettingsRowView(
                    id: "advanced.updates.source",
                    highlightedID: router.highlightedRowID,
                    title: l10n.tr("settings.updates.source"),
                    subtitle: l10n.tr(updater.sourceChoice == .auto ? "settings.updates.source.autoSub" : "settings.updates.source.officialSub")
                ) {
                    Picker("", selection: $updater.sourceChoice) {
                        Text(l10n.tr("settings.updates.source.auto")).tag(SourceChoice.auto)
                        Text(l10n.tr("settings.updates.source.official")).tag(SourceChoice.official)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
    }

    // MARK: Status

    private var statusTitle: String {
        switch updater.state {
        case .off:
            return l10n.tr("settings.updates.offDevelopment")
        case .idle(let checkedAt):
            if let from = updater.updatedFrom, updater.showsNotice {
                return l10n.tr("settings.updates.updatedTo", updater.current) + " · " + l10n.tr("settings.updates.updatedFrom", from)
            }
            return checkedAt == nil ? l10n.tr("settings.updates.version", updater.current) : l10n.tr("settings.updates.upToDate")
        case .checking:
            return l10n.tr("settings.updates.checking")
        case .available(let version, _, _):
            return l10n.tr("settings.updates.available", version)
        case .downloading(let version, _, _):
            return l10n.tr("settings.updates.downloading", version)
        case .ready:
            return l10n.tr("settings.updates.readyTitle")
        case .error:
            return l10n.tr("settings.updates.failed")
        }
    }

    private var statusDetail: String? {
        switch updater.state {
        case .off:
            return nil
        case .idle(let checkedAt):
            if updater.daemonOutdated { return l10n.tr("settings.updates.daemonOutdated") }
            guard let checkedAt else { return l10n.tr("settings.updates.notChecked") }
            return l10n.tr("settings.updates.checkedAt", Self.relativeTimeString(for: checkedAt, locale: l10n.language.resolvedLocale))
        case .checking:
            return nil
        case .available:
            if updater.effectiveMode == .install { return nil }
            return l10n.tr(updater.mode == .install ? "settings.updates.cannotInstallHere" : "settings.updates.linkDetail")
        case .downloading(_, let percent, _):
            return "\(percent)%"
        case .ready(let version, _):
            let restartsDaemon = updater.stagedRestartsDaemon
            let how = updater.choice == .automatic
                ? l10n.tr(restartsDaemon ? "settings.updates.readyAutoDaemon" : "settings.updates.readyAuto")
                : l10n.tr("settings.updates.readyClick") + " "
                    + l10n.tr(restartsDaemon ? "settings.updates.readyRestartsDaemon" : "settings.updates.readyKeepsSessions")
            return "v\(updater.current) → v\(version)\n" + how
        case .error(let message, _):
            return message
        }
    }

    @ViewBuilder
    private var statusControl: some View {
        switch updater.state {
        case .off:
            EmptyView()
        case .idle, .error:
            SettingsPillButton(l10n.tr(isError ? "settings.updates.tryAgain" : "settings.updates.check"), icon: "arrow.clockwise") {
                Task { await updater.check() }
            }
        case .checking:
            ProgressView()
                .controlSize(.small)
        case .available:
            HStack(spacing: 8) {
                if updater.showsNotice {
                    SettingsPillButton(l10n.tr("settings.updates.later")) { updater.dismiss() }
                }
                if updater.effectiveMode == .install {
                    SettingsPillButton(l10n.tr("settings.updates.update"), icon: "arrow.down.circle", prominent: true) {
                        updater.update()
                    }
                } else {
                    SettingsPillButton(l10n.tr("settings.updates.download"), icon: "arrow.down.circle", prominent: true) {
                        updater.openDownload()
                    }
                }
            }
        case .downloading(_, let percent, _):
            ProgressView(value: Double(percent), total: 100)
                .progressViewStyle(.linear)
                .frame(width: 140)
                .tint(tokens.primary)
                .accessibilityLabel(l10n.tr("settings.updates.downloadProgress"))
        case .ready:
            SettingsPillButton(l10n.tr("settings.updates.restart"), icon: "arrow.triangle.2.circlepath", prominent: true) {
                updater.restart()
            }
        }
    }

    private var isError: Bool {
        if case .error = updater.state { return true }
        return false
    }

    // MARK: What's new

    /// The highlights of the update waiting, or of the version just updated to.
    private var noticeNotes: [String]? {
        let notes: [String: [String]]
        switch updater.state {
        case .ready(_, let ready):
            notes = ready
        case .idle where updater.updatedFrom != nil && updater.showsNotice:
            notes = updater.currentNotes
        default:
            return nil
        }
        return notes[l10n.resolvedCode] ?? notes["en"]
    }

    private func whatsNew(_ notes: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(l10n.tr("settings.updates.whatsNew"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(tokens.mutedForeground)
                Spacer()
                if case .idle = updater.state {
                    SettingsPillButton(l10n.tr("settings.updates.dismiss")) { updater.dismiss() }
                }
            }
            ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•")
                        .foregroundStyle(tokens.mutedForeground)
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(tokens.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    // MARK: Choices

    private static let relativeDateFormatter = RelativeDateTimeFormatter()

    private static func relativeTimeString(for date: Date, locale: Locale) -> String {
        if relativeDateFormatter.locale != locale {
            relativeDateFormatter.locale = locale
        }
        return relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }

    private var choices: [UpdateChoice] {
        updater.effectiveMode == .install ? UpdateChoice.allCases : [.notify, .off]
    }

    /// In Link mode nothing downloads by itself, so a choice that would download reads as asking.
    private var choiceBinding: Binding<UpdateChoice> {
        Binding(
            get: {
                let choice = updater.choice
                if updater.effectiveMode == .link, choice != .notify, choice != .off { return .notify }
                return choice
            },
            set: { updater.choice = $0 }
        )
    }

    private func label(for choice: UpdateChoice) -> String {
        if updater.effectiveMode == .link {
            return l10n.tr(choice == .off ? "settings.updates.automatic.linkOff" : "settings.updates.automatic.linkNotify")
        }
        return l10n.tr("settings.updates.automatic.\(choice.rawValue)")
    }
}
