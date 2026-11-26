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
    @Environment(\.prismL10n) private var l10n

    private var islandIds: Set<UInt32> {
        Set(Displays.screens(for: chosen).map(Displays.id(of:)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisplayArrangement(displays: displays, islandIds: islandIds) { display in
                withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                    toggle(display)
                }
            }
            .frame(height: 92)

            Text(caption)
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .animation(Motion.quick, value: caption)
        }
    }

    private var caption: String {
        let showing = displays.filter { islandIds.contains($0.id) }
            .map { l10n.tr("display.quoted", $0.name) }
            .joined(separator: l10n.tr("common.listSeparator"))
        let connected = chosen.contains { choice in displays.contains { $0.id == choice.id || $0.name == choice.name } }
        if let away = chosen.first, !connected {
            return l10n.tr("display.caption.disconnected", l10n.tr("display.quoted", away.name), showing)
        }
        return l10n.tr("display.caption.showing", showing)
    }
}

private struct DisplayArrangement: View {
    let displays: [DisplayInfo]
    let islandIds: Set<UInt32>
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
    let size: CGSize
    let action: () -> Void
    @Environment(\.prismL10n) private var l10n
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        Button(action: action) {
            ZStack(alignment: .top) {
                shape.fill(Palette.tile)
                shape.fill(hasIsland ? Palette.ink5 : (hovering ? Palette.ink5 : .clear))
                shape.strokeBorder(hasIsland ? Palette.focus : Palette.line, lineWidth: hasIsland ? 1.4 : 0.5)

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
                        .foregroundStyle(Palette.ink3)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .foregroundStyle(hasIsland ? Palette.ink : Palette.ink2)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Image(systemName: hasIsland ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(hasIsland ? Palette.focus : Palette.ink3)
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .accessibilityHidden(true)
            }
            .contentShape(shape)
            .scaleEffect(hovering ? 1.02 : 1)
        }
        .buttonStyle(CellPressStyle())
        .onHover { value in
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.25)) { hovering = value }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: hasIsland)
        .help(l10n.tr(hasIsland ? "display.help.hide" : "display.help.show", display.name))
    }

    private var subtitle: String {
        var parts = [display.resolution]
        if display.builtIn { parts.append(l10n.tr("display.builtIn")) } else if display.primary { parts.append(l10n.tr("display.primary")) }
        return parts.joined(separator: " · ")
    }
}

private struct MiniNotchSilhouette: View {
    var body: some View {
        IslandShape(radius: 3, shoulders: true, shoulderWidth: 2)
            .fill(Color.black)
            .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
    }
}
