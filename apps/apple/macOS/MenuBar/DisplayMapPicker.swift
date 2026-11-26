import MenuBarKit
import PrismDesign
import SwiftUI

/// Visual multi-monitor display picker from llm-usage-island:
/// Each connected monitor appears left-to-right as a clickable tile with a miniature Dynamic Island
/// springing onto its top edge. Supports ticking multiple monitors (such as dual 4K displays) at once.
struct DisplayMapPicker: View {
    let chosen: [DisplayChoice]
    let displays: [DisplayInfo]
    let toggle: (DisplayInfo) -> Void
    /// Clears the choice so the island picks its display itself; the Automatic option shows only
    /// when this is given.
    var useAutomatic: (() -> Void)? = nil
    @Environment(\.prismL10n) private var l10n
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismMotionTier) private var motionTier
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var islandIds: Set<UInt32> {
        Set(Displays.screens(for: chosen).map(Displays.id(of:)))
    }

    private var automatic: Bool { chosen.isEmpty }

    var body: some View {
        let ids = islandIds
        let captionText = caption(ids)
        VStack(alignment: .leading, spacing: 10) {
            if let useAutomatic {
                AutomaticDisplayChoice(selected: automatic) {
                    guard !automatic else { return }
                    withAnimation(PrismSpringSpec.gentle.animation(tier: motionTier, reduceMotion: reduceMotion)) {
                        useAutomatic()
                    }
                }
            }

            // The island always shows somewhere, so the one display it is left on cannot be unchecked.
            DisplayArrangement(displays: displays, islandIds: ids, lockedId: ids.count == 1 ? ids.first : nil) { display in
                withAnimation(PrismSpringSpec.gentle.animation(tier: motionTier, reduceMotion: reduceMotion)) {
                    toggle(display)
                }
            }
            .frame(height: 92)

            Text(captionText)
                .font(.system(size: 10.5))
                .foregroundStyle(tokens.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .animation(PrismSpringSpec.snappy.animation(tier: motionTier, reduceMotion: reduceMotion), value: captionText)
        }
    }

    private func caption(_ ids: Set<UInt32>) -> String {
        let showing = displays.filter { ids.contains($0.id) }
            .map { l10n.tr("display.quoted", $0.name) }
            .joined(separator: l10n.tr("common.listSeparator"))
        if automatic {
            return l10n.tr("display.caption.automatic", showing)
        }
        let away = Displays.awayChoices(chosen)
        if let first = away.first, away.count == chosen.count {
            return l10n.tr("display.caption.disconnected", l10n.tr("display.quoted", first.name), showing)
        }
        return l10n.tr("display.caption.showing", showing)
    }
}

private enum DisplayTileMetrics {
    static let radius: CGFloat = 9
    static let ringGap: CGFloat = 3
}

/// The window turns the system focus ring off, so keyboard focus draws its own.
private struct DisplayFocusRing: ViewModifier {
    let focused: Bool
    @Environment(\.prismTokens) private var tokens

    func body(content: Content) -> some View {
        content.overlay {
            if focused {
                RoundedRectangle(
                    cornerRadius: DisplayTileMetrics.radius + DisplayTileMetrics.ringGap,
                    style: .continuous
                )
                .strokeBorder(tokens.primary, lineWidth: 2)
                .padding(-DisplayTileMetrics.ringGap)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

private struct AutomaticDisplayChoice: View {
    let selected: Bool
    let action: () -> Void
    @Environment(\.prismL10n) private var l10n
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismMotionTier) private var motionTier
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DisplayTileMetrics.radius, style: .continuous)
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(selected ? tokens.primary : tokens.mutedForeground)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(l10n.tr("display.automatic"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(selected ? tokens.foreground : tokens.secondaryForeground)
                    Text(l10n.tr("display.automaticSub"))
                        .font(.system(size: 10))
                        .foregroundStyle(tokens.mutedForeground)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                ZStack {
                    shape.fill(selected ? tokens.primarySoft : (hovering ? tokens.hoverWash : tokens.surface2.opacity(0.65)))
                    shape.strokeBorder(
                        selected ? tokens.primary : (hovering ? tokens.borderStrong : tokens.borderEtched),
                        lineWidth: selected ? 1.4 : 0.5
                    )
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(CellPressStyle())
        .focused($focused)
        .modifier(DisplayFocusRing(focused: focused))
        .onHover { value in
            withAnimation(PrismSpringSpec.micro.animation(tier: motionTier, reduceMotion: reduceMotion)) {
                hovering = value
            }
        }
        .animation(PrismSpringSpec.gentle.animation(tier: motionTier, reduceMotion: reduceMotion), value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct DisplayArrangement: View {
    let displays: [DisplayInfo]
    let islandIds: Set<UInt32>
    let lockedId: UInt32?
    let choose: (DisplayInfo) -> Void

    var body: some View {
        GeometryReader { proxy in
            let ordered = displays.sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
            let gap: CGFloat = 8
            let count = CGFloat(max(1, ordered.count))
            let width = min((proxy.size.width - gap * (count - 1)) / count, proxy.size.height * 1.7)
            HStack(spacing: gap) {
                ForEach(ordered) { display in
                    DisplayTile(
                        display: display,
                        hasIsland: islandIds.contains(display.id),
                        locked: lockedId == display.id,
                        size: CGSize(width: width, height: proxy.size.height),
                        action: { choose(display) }
                    )
                    .frame(width: width, height: proxy.size.height)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

private struct DisplayTile: View {
    let display: DisplayInfo
    let hasIsland: Bool
    /// The only display the island shows on: checked, and not to be unchecked.
    let locked: Bool
    let size: CGSize
    let action: () -> Void
    @Environment(\.prismL10n) private var l10n
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismMotionTier) private var motionTier
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DisplayTileMetrics.radius, style: .continuous)
        let animates = PrismSpringSpec.micro.animation(tier: motionTier, reduceMotion: reduceMotion) != nil
        let hovered = hovering && !locked
        Button(action: action) {
            ZStack(alignment: .top) {
                shape.fill(hasIsland ? tokens.primarySoft : (hovered ? tokens.hoverWash : tokens.surface2.opacity(0.65)))
                shape.strokeBorder(
                    locked ? tokens.primaryBorder : (hasIsland ? tokens.primary : (hovered ? tokens.borderStrong : tokens.borderEtched)),
                    lineWidth: hasIsland ? 1.4 : 0.5
                )

                MiniNotchSilhouette()
                    .frame(width: max(18, size.width * 0.3), height: 6)
                    .scaleEffect(x: hasIsland ? 1 : 0.2, y: hasIsland ? 1 : 0.2, anchor: .top)
                    .opacity(hasIsland ? 1 : 0)
                    .padding(.top, 0.75)

                VStack(spacing: 1) {
                    Text(display.name)
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(subtitle)
                        .font(.system(size: 9.5))
                        .foregroundStyle(tokens.mutedForeground)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .foregroundStyle(hasIsland ? tokens.foreground : tokens.secondaryForeground)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Image(systemName: hasIsland ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(hasIsland ? tokens.primary : tokens.mutedForeground)
                    .opacity(locked ? 0.5 : 1)
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .accessibilityHidden(true)
            }
            .contentShape(shape)
            .scaleEffect(hovered && animates ? 1.02 : 1)
        }
        .buttonStyle(CellPressStyle())
        .disabled(locked)
        .focused($focused)
        .modifier(DisplayFocusRing(focused: focused))
        // Outside `disabled`, so the locked tile still explains itself on hover.
        .onHover { value in
            withAnimation(PrismSpringSpec.micro.animation(tier: motionTier, reduceMotion: reduceMotion)) {
                hovering = value
            }
        }
        .animation(PrismSpringSpec.gentle.animation(tier: motionTier, reduceMotion: reduceMotion), value: hasIsland)
        .accessibilityAddTraits(hasIsland ? .isSelected : [])
        .help(helpText)
    }

    private var helpText: String {
        if locked { return l10n.tr("display.help.last") }
        return l10n.tr(hasIsland ? "display.help.hide" : "display.help.show", display.name)
    }

    private var subtitle: String {
        var parts = [display.resolution]
        if display.builtIn { parts.append(l10n.tr("display.builtIn")) } else if display.primary { parts.append(l10n.tr("display.primary")) }
        return parts.joined(separator: " · ")
    }
}

/// The physical notch is black in every palette, as the island's own chassis is.
private struct MiniNotchSilhouette: View {
    @Environment(\.prismTokens) private var tokens

    var body: some View {
        IslandShape(radius: 3, shoulders: true, shoulderWidth: 2)
            .fill(tokens.island.surface)
            .shadow(color: tokens.island.surface.opacity(0.25), radius: 1.5, y: 0.5)
    }
}
