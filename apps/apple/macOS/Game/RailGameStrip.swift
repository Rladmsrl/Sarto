import PrismDesign
import SartoProtocol
import SwiftUI

/// The idle game in the running rail: shows the hero's version, power, live battle canvas and
/// quick badges (Boss ready / choice waiting), and opens the full Expedition window on click.
struct RailGameStrip: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var store: GameStore
    var paused: Bool = false
    @State private var hovered = false

    var body: some View {
        if let state = store.state {
            VStack(alignment: .leading, spacing: 6) {
                header(state)
                arena(state)
                    .frame(height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(hovered ? tokens.primaryBorder : tokens.borderEtched, lineWidth: 0.8)
                    )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(hovered ? tokens.hoverWash.opacity(0.5) : Color.clear)
            .overlay(alignment: .bottom) { Rectangle().fill(tokens.borderEtched).frame(height: 1) }
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .onTapGesture { store.openExpedition() }
            .help(l10n.tr("game.strip.openHelp"))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(l10n.tr("game.strip.accessibility", state.version, "\(state.power)", stageText(state)))
            .onAppear { store.setSurfaceVisible(true) }
            .onDisappear { store.setSurfaceVisible(false) }
        }
    }

    private func header(_ state: GameStateInfo) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tokens.prismIris)
            Text(l10n.tr("game.strip.title"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tokens.foreground)
            Text(state.version)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(tokens.prismAmber)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(tokens.prismAmber.opacity(0.12)))
            Text(stageText(state))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(state.pendingOffers > 0 || state.bossReady ? tokens.prismAmber : tokens.secondaryForeground)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(l10n.tr("game.strip.power", "\(state.power)"))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(tokens.secondaryForeground)
                .monospacedDigit()
            Circle()
                .fill(stateColor(state.accountState))
                .frame(width: 6, height: 6)
                .help(l10n.tr("game.state.\(state.accountState)"))
            Image(systemName: "arrow.up.right.square")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(hovered ? tokens.foreground : tokens.mutedForeground)
        }
    }

    private func stageText(_ state: GameStateInfo) -> String {
        if state.pendingOffers > 0 { return l10n.tr("game.strip.offerWaiting") }
        if state.runStatus == "fighting" { return l10n.tr("game.strip.hackathon") }
        if state.bossReady { return l10n.tr("game.strip.bossReady") }
        return "\(state.chapter)-\(state.stage) · \(state.kills)/\(state.killsNeeded)"
    }

    private func stateColor(_ value: String) -> Color {
        switch value {
        case "active": tokens.success
        case "inactive": tokens.warning
        default: tokens.mutedForeground
        }
    }

    @ViewBuilder
    private func arena(_ state: GameStateInfo) -> some View {
        let fps = PrismEnergyPolicy.capped(
            PrismEnergyPolicy.framesPerSecond(
                for: .streaming,
                surface: .widget,
                displayMaxFPS: 60,
                conditions: PrismEnergyMonitor.shared.conditions
            ),
            requestedFPS: 20
        )
        let still = reduceMotion || fps <= 0
        TimelineView(.animation(minimumInterval: 1.0 / Double(max(1, still ? 4 : fps)), paused: paused)) { timeline in
            Canvas(rendersAsynchronously: false) { context, size in
                GameArenaRenderer.draw(
                    context: &context,
                    size: size,
                    display: store.frame(at: timeline.date),
                    weaponHarness: state.mainWeapon,
                    tokens: tokens,
                    l10n: l10n,
                    now: timeline.date,
                    still: still,
                    compact: true
                )
            }
        }
        .background(tokens.surface2)
    }
}
