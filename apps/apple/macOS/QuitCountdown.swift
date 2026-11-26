import AppKit
import PrismDesign
import SwiftUI

/// ⌘Q asks twice: the first press shows a countdown over the
/// window it came from, and a second press within it closes Sarto's windows. Sarto itself, its
/// menu bar item and the daemon keep running; only the menu bar quits them.
@MainActor
final class QuitCountdown {
    struct Style {
        let tokens: PrismTokens
        let l10n: PrismL10n
        let motionTier: PrismMotionTier
    }

    static let duration: TimeInterval = 2

    /// Closes the windows, as the second press asks.
    var close: () -> Void = {}
    /// The app's current theme, language and motion; without it no hint is shown.
    var style: (() -> Style)?

    private var panel: NSPanel?
    private var expiry: Task<Void, Never>?
    private var anchorObserver: NSObjectProtocol?

    private var isArmed: Bool { expiry != nil }

    /// A ⌘Q over `anchor`, the window it came from; with no window shown there is nothing to close.
    func press(over anchor: NSWindow?) {
        if isArmed {
            disarm()
            close()
            return
        }
        guard let anchor, anchor.isVisible, !anchor.isMiniaturized, let style = style?() else { return }
        arm(over: anchor, style: style)
    }

    private func arm(over anchor: NSWindow, style: Style) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let animated = !reduceMotion && style.motionTier != .off
        let hint = QuitHintView(
            title: style.l10n.tr("quitHint.title"),
            caption: style.l10n.tr("quitHint.caption"),
            spoken: style.l10n.tr("quitHint.spoken"),
            duration: Self.duration,
            animated: animated,
            tokens: style.tokens,
            motionTier: style.motionTier
        )
        let host = NSHostingView(rootView: hint)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let origin = NSPoint(
            x: anchor.frame.midX - size.width / 2,
            y: anchor.frame.midY - size.height / 2
        )
        let panel = QuitHintPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.level = anchor.level
        panel.appearance = anchor.effectiveAppearance
        panel.contentView = host
        anchor.addChildWindow(panel, ordered: .above)
        self.panel = panel

        // A window that goes away takes its question with it.
        anchorObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: anchor,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.disarm() }
        }
        expiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.duration))
            guard !Task.isCancelled else { return }
            self?.disarm()
        }
    }

    private func disarm() {
        expiry?.cancel()
        expiry = nil
        if let anchorObserver {
            NotificationCenter.default.removeObserver(anchorObserver)
            self.anchorObserver = nil
        }
        guard let panel else { return }
        self.panel = nil
        let finish = {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard !reduceMotion, style?().motionTier != .off else {
            finish()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            finish()
        }
    }
}

/// Never takes the key window from the window it covers, so the second ⌘Q reaches Sarto.
private final class QuitHintPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The hint in the middle of the window: ⌘ and Q keys, Q running out with the time left.
private struct QuitHintView: View {
    let title: String
    let caption: String
    let spoken: String
    let duration: TimeInterval
    let animated: Bool
    let tokens: PrismTokens
    let motionTier: PrismMotionTier

    @State private var shown = false
    @State private var remaining: CGFloat = 1

    var body: some View {
        VStack(spacing: 11) {
            HStack(spacing: 6) {
                QuitKeyCap(label: "⌘", remaining: nil, tokens: tokens)
                QuitKeyCap(label: "Q", remaining: remaining, tokens: tokens)
            }
            VStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tokens.foreground)
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.mutedForeground)
            }
            .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 15)
        .background(
            RoundedRectangle(cornerRadius: tokens.rLG, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: tokens.rLG, style: .continuous)
                .strokeBorder(tokens.borderEtched, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 22, y: 10)
        .padding(28)
        .scaleEffect(shown ? 1 : 0.94)
        .opacity(shown ? 1 : 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(.updatesFrequently)
        .onAppear {
            guard animated else {
                shown = true
                return
            }
            withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier)) { shown = true }
            withAnimation(.linear(duration: duration)) { remaining = 0 }
        }
    }
}

private struct QuitKeyCap: View {
    let label: String
    /// The share of the countdown left, drawn as the key's fill running out toward its right edge.
    let remaining: CGFloat?
    let tokens: PrismTokens

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: tokens.rMD, style: .continuous)
        Text(label)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(tokens.foreground)
            .frame(minWidth: 38, minHeight: 38)
            .padding(.horizontal, 4)
            .background {
                ZStack {
                    shape.fill(tokens.surface2)
                    if let remaining {
                        shape
                            .fill(tokens.primarySoft)
                            .scaleEffect(x: remaining, y: 1, anchor: .trailing)
                    }
                }
                .clipShape(shape)
            }
            .overlay(shape.strokeBorder(tokens.borderStrong, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
    }
}
