import AppKit
import PrismDesign
import SartoProtocol
import SwiftUI

/// Whether the idle game can be turned on. While locked, the switch in Settings only says the game
/// is in development, and the game stays off, so nothing of it loads or shows.
///
/// Unlocking takes: a production game service with game tokens from the account service, and a
/// section on the idle game in PRIVACY.md and PRIVACY.zh-CN.md (opt-in per Mac, what is sent and
/// where, how to turn it off, that turning it off deletes unsent facts, the local upload log).
/// Flipping it lets the switch ask for consent and turn the game on, and shows the upload log.
enum GameFeature {
    static let locked = true
}

/// The idle game's switch for Settings. It is off by default on every Mac; turning it on asks
/// first, listing what this Mac would send and what never leaves it.
struct GameSettingsSection: View {
    var state: SartoState
    var store: GameStore
    var highlightedID: String? = nil

    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showsConsent = false
    @State private var showsLockedNotice = false
    @State private var isPillHovered = false
    @State private var failed = false

    var body: some View {
        let motion = PrismSpringSpec.snappy.animation(tier: state.motionTier, reduceMotion: reduceMotion)
        VStack(alignment: .leading, spacing: 10) {
            SettingsGroupSection(l10n.tr("game.settings.section")) {
                SettingsRowView(
                    id: "game.enabled",
                    highlightedID: highlightedID,
                    title: l10n.tr("game.settings.toggle"),
                    subtitle: subtitle
                ) {
                    if GameFeature.locked {
                        Button {
                            showsLockedNotice = true
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 10.5, weight: .semibold))
                                Text(l10n.tr("game.settings.inDesignPill"))
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundStyle(tokens.prismIris)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule().fill(
                                    tokens.prismIris.opacity(
                                        isPillHovered
                                            ? (tokens.palette.isDark ? 0.26 : 0.18)
                                            : (tokens.palette.isDark ? 0.16 : 0.10)
                                    )
                                )
                            )
                            .overlay(
                                Capsule().strokeBorder(
                                    tokens.prismIris.opacity(isPillHovered ? 0.50 : 0.30),
                                    lineWidth: 1
                                )
                            )
                        }
                        .buttonStyle(.plain)
                        .onHover { hovered in
                            withAnimation(PrismSpringSpec.micro.animation(tier: state.motionTier, reduceMotion: reduceMotion)) {
                                isPillHovered = hovered
                            }
                        }
                        .accessibilityLabel(l10n.tr("game.settings.inDesignPill"))
                    } else {
                        Toggle("", isOn: toggle)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                            .disabled(!canSwitch)
                            .accessibilityLabel(l10n.tr("game.settings.toggle"))
                    }
                }
                if !GameFeature.locked, let log = store.status?.uploadLog {
                    SettingsRowDivider()
                    SettingsRowView(
                        id: "game.uploads",
                        highlightedID: highlightedID,
                        title: l10n.tr("game.settings.uploadsTitle"),
                        subtitle: l10n.tr("game.settings.uploadsSubtitle")
                    ) {
                        SettingsPillButton(l10n.tr("game.settings.viewUploads"), icon: "doc.text.magnifyingglass") {
                            reveal(log)
                        }
                    }
                }
            }
            if failed {
                SettingsBannerView(text: l10n.tr("game.settings.failed"), kind: .error) { failed = false }
                    .transition(.opacity)
            }
        }
        .animation(motion, value: failed)
        .animation(motion, value: subtitle)
        .sheet(isPresented: $showsConsent) {
            GameConsentSheet { confirmed in
                showsConsent = false
                if confirmed { switchTo(true) }
            }
            .environment(\.prismTokens, tokens)
            .environment(\.prismL10n, l10n)
            .preferredColorScheme(state.palette.colorScheme)
        }
        .alert(l10n.tr("game.settings.locked"), isPresented: $showsLockedNotice) {
            Button(l10n.tr("game.settings.ok"), role: .cancel) {}
        } message: {
            Text(l10n.tr("game.settings.lockedDetail"))
        }
    }

    /// Shows the owner's choice; turning it on asks first, and while locked only says why it can't.
    private var toggle: Binding<Bool> {
        Binding(
            get: { store.status?.optedIn ?? false },
            set: { on in
                if !on {
                    switchTo(false)
                } else if GameFeature.locked {
                    showsLockedNotice = true
                } else {
                    showsConsent = true
                }
            }
        )
    }

    private var canSwitch: Bool {
        if store.switching { return false }
        if GameFeature.locked || store.status?.optedIn == true { return true }
        return store.status?.available == true
    }

    private var subtitle: String {
        if GameFeature.locked { return l10n.tr("game.settings.inDesignSubtitle") }
        guard let status = store.status else { return l10n.tr("game.settings.waiting") }
        if !status.optedIn && !status.available { return l10n.tr("game.settings.noServer") }
        if status.optedIn && !status.enabled { return l10n.tr("game.settings.signIn") }
        return l10n.tr("game.settings.description")
    }

    private func switchTo(_ enabled: Bool) {
        Task {
            failed = !(await store.setEnabled(enabled))
        }
    }

    /// Shows the log of what was sent in Finder, or its folder before anything was.
    private func reveal(_ path: String) {
        let file = URL(fileURLWithPath: path)
        Task.detached(priority: .userInitiated) {
            let exists = FileManager.default.fileExists(atPath: file.path)
            await MainActor.run {
                if exists {
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                } else {
                    NSWorkspace.shared.open(file.deletingLastPathComponent())
                }
            }
        }
    }
}

/// Asks before the game is turned on, listing what this Mac would send to the game service (the
/// facts `src/daemon/game/facts.ts` makes) and what it never sends.
private struct GameConsentSheet: View {
    let onFinish: (Bool) -> Void

    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    private static let sent = [
        "game.consent.sent.turns",
        "game.consent.sent.work",
        "game.consent.sent.tokens",
        "game.consent.sent.harness",
        "game.consent.sent.todo",
        "game.consent.sent.refs",
    ]

    private static let never = [
        "game.consent.never.content",
        "game.consent.never.names",
        "game.consent.never.commands",
        "game.consent.never.models",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(l10n.tr("game.consent.title"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tokens.foreground)
            Text(l10n.tr("game.consent.intro"))
                .font(.system(size: 12))
                .foregroundStyle(tokens.secondaryForeground)
                .fixedSize(horizontal: false, vertical: true)
            list(l10n.tr("game.consent.sentTitle"), keys: Self.sent, icon: "arrow.up.circle", accent: tokens.prismCobalt)
            list(l10n.tr("game.consent.neverTitle"), keys: Self.never, icon: "nosign", accent: tokens.success)
            Text(l10n.tr("game.consent.footer"))
                .font(.system(size: 11.5))
                .foregroundStyle(tokens.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button(l10n.tr("game.consent.cancel")) { onFinish(false) }
                    .keyboardShortcut(.cancelAction)
                Button(l10n.tr("game.consent.confirm")) { onFinish(true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(tokens.background)
    }

    private func list(_ title: String, keys: [String], icon: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tokens.foreground)
            ForEach(keys, id: \.self) { key in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(accent)
                    Text(l10n.tr(key))
                        .font(.system(size: 12))
                        .foregroundStyle(tokens.secondaryForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).fill(tokens.surface1))
        .overlay(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).strokeBorder(tokens.borderEtched, lineWidth: 1))
    }
}
