import AppKit
import PrismDesign
import QuartzCore
import SwiftUI

// MARK: - Brand Emblem & Official Agent Marks

/// Sarto N-01 Spectrum Core mark shown when the Dynamic Island is calm/idle.
struct SartoEmblem: View {
    var size: CGFloat = IslandMetrics.wingMark
    var active: Bool = false

    var body: some View {
        SartoSpectrumEmblem(size: size, active: active)
    }
}

/// Renders Antigravity's official swoosh mark natively in SwiftUI without CoreSVG filter latency.
struct AntigravityMarkShape: View {
    var size: CGFloat

    var body: some View {
        AntigravitySwooshPath()
            .fill(
                LinearGradient(
                    colors: [
                        Color(hex: 0x34A853),
                        Color(hex: 0x4285F4),
                        Color(hex: 0x9B72CB),
                        Color(hex: 0xEA4335),
                        Color(hex: 0xFBBC05),
                    ],
                    startPoint: .bottomLeading,
                    endPoint: .topTrailing
                )
            )
            .frame(width: size, height: size)
    }
}

private struct AntigravitySwooshPath: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 16.0
        let sy = rect.height / 16.0
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }
        var p = Path()
        p.move(to: pt(14.1452, 14.6818))
        p.addCurve(to: pt(15.0997, 13.7273), control1: pt(14.9937, 15.3182), control2: pt(16.2664, 14.894))
        p.addCurve(to: pt(7.99366, 1.0), control1: pt(11.5998, 10.3333), control2: pt(12.3421, 1.0))
        p.addCurve(to: pt(0.887603, 13.7273), control1: pt(3.64518, 1.0), control2: pt(4.3876, 10.3333))
        p.addCurve(to: pt(1.84215, 14.6818), control1: pt(-0.385123, 15.0), control2: pt(0.993664, 15.3182))
        p.addCurve(to: pt(7.99366, 8.5303), control1: pt(5.13002, 12.4545), control2: pt(4.9179, 8.5303))
        p.addCurve(to: pt(14.1452, 14.6818), control1: pt(11.0694, 8.5303), control2: pt(10.8573, 12.4545))
        p.closeSubpath()
        return p
    }
}

/// Thread-safe cache for CoreSVG-rasterized Sarto agent harness marks.
enum IslandMarkImageCache {
    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var cache: [String: NSImage] = [:]

        func get(_ key: String) -> NSImage? {
            lock.lock()
            defer { lock.unlock() }
            return cache[key]
        }

        func set(_ image: NSImage, for key: String) {
            lock.lock()
            defer { lock.unlock() }
            cache[key] = image
        }
    }

    private static let store = Store()

    @MainActor
    static func image(for harness: String) -> NSImage? {
        if let hit = store.get(harness) { return hit }
        guard let svg = IslandAssets.markSVG[harness],
              let data = svg.data(using: .utf8),
              let image = NSImage(data: data),
              image.isValid
        else { return nil }
        store.set(image, for: harness)
        return image
    }

    /// Pre-warms CoreSVG on the main actor during startup idle time without cross-thread
    /// `NSGraphicsContext` races so the first island animation stays smooth.
    @MainActor
    static func warmUp() {
        for harness in ["claude-code", "codex"] {
            _ = image(for: harness)
        }
    }
}

struct IslandMarkView: View {
    let agent: IslandAgentIdentity
    let size: CGFloat

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if agent.harness == "antigravity" || agent.id == "antigravity" {
                    AntigravityMarkShape(size: size)
                } else if let nsImage = IslandMarkImageCache.image(for: agent.harness) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .fill(IslandTheme.card)
                        .overlay(
                            Text(String(agent.name.prefix(1)).uppercased())
                                .font(IslandFonts.ui(size * 0.55, .semibold))
                                .foregroundStyle(IslandTheme.text)
                        )
                }
            }
            .frame(width: size, height: size)

            if let colorName = agent.color, let hex = IslandAssets.agentDotHex[colorName] {
                let diameter = max(3, min(7, (size / 4).rounded()))
                let ring = min(1.5, diameter / 4)
                Circle()
                    .fill(Color(hex: hex))
                    .frame(width: diameter, height: diameter)
                    .background(
                        Circle()
                            .fill(IslandTheme.surface)
                            .frame(width: diameter + 2 * ring, height: diameter + 2 * ring)
                    )
                    .offset(x: ring, y: ring)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Up to three overlapping agent marks, front-most first, each cutout in obsidian black.
struct IslandMarkStack: View {
    let agents: [IslandAgentIdentity]
    var size: CGFloat = IslandMetrics.wingMark

    var body: some View {
        HStack(spacing: -(IslandMetrics.markOverlap + 4)) {
            ForEach(Array(agents.prefix(3).enumerated()), id: \.offset) { index, agent in
                IslandMarkView(agent: agent, size: size)
                    .padding(2)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(IslandTheme.surface)
                    )
                    .zIndex(Double(3 - index))
            }
        }
    }
}

// MARK: - Zero-CPU Core Animation 9-Dot Turn Matrix (Prism Accent)

struct IslandTurnDots: NSViewRepresentable {
    enum Pattern: String, Equatable, Sendable {
        case chase, think, read, search, edit, fetch, compact, write

        init(phase: String?) {
            switch phase {
            case "think", "thinking": self = .think
            case "read": self = .read
            case "search": self = .search
            case "edit": self = .edit
            case "fetch": self = .fetch
            case "compact", "compacting": self = .compact
            case "write", "writing": self = .write
            default: self = .chase
            }
        }
    }

    let pattern: Pattern
    var size: CGFloat = 12
    let reduceMotion: Bool

    func makeNSView(context: Context) -> IslandDotsNSView { IslandDotsNSView() }

    func updateNSView(_ view: IslandDotsNSView, context: Context) {
        view.configure(pattern: pattern, size: size, reduceMotion: reduceMotion)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: IslandDotsNSView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}

final class IslandDotsNSView: NSView {
    private var shown: (IslandTurnDots.Pattern, CGFloat, Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    private struct Keys {
        let times: [Double]
        let values: [Double]
    }

    private static let trail = Keys(times: [0, 0.4, 1], values: [1, 0.22, 0.22])
    private static let twinkle = Keys(times: [0, 0.15, 0.3, 1], values: [0.22, 1, 0.22, 0.22])
    private static let swap = Keys(times: [0, 0.5, 1], values: [0.22, 1, 0.22])
    private static let sweepEdge = Keys(
        times: [0, 0.125, 0.25, 0.75, 0.875, 1],
        values: [1, 0.74, 0.22, 0.22, 0.74, 1]
    )
    private static let sweepMid = Keys(
        times: [0, 0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875, 1],
        values: [0.22, 0.36, 1, 0.36, 0.22, 0.36, 1, 0.36, 0.22]
    )
    private static let fill = Keys(times: [0, 0.55, 0.62, 1], values: [1, 1, 0.22, 0.22])

    private static let ring = [0, 1, 2, 7, -1, 3, 6, 5, 4]
    private static let twinkles = [0, 0.53, 0.21, 0.78, 0.37, 0.91, 0.12, 0.66, 0.45]

    // Subtle Obsidian Prism cobalt → iris diagonal tint across the 3x3 dot matrix.
    private static let prismDotColors: [NSColor] = [
        NSColor(srgbRed: 0.30, green: 0.55, blue: 0.96, alpha: 1),
        NSColor(srgbRed: 0.40, green: 0.52, blue: 0.94, alpha: 1),
        NSColor(srgbRed: 0.52, green: 0.48, blue: 0.88, alpha: 1),
        NSColor(srgbRed: 0.36, green: 0.53, blue: 0.95, alpha: 1),
        NSColor(srgbRed: 0.48, green: 0.50, blue: 0.90, alpha: 1),
        NSColor(srgbRed: 0.61, green: 0.45, blue: 0.80, alpha: 1),
        NSColor(srgbRed: 0.44, green: 0.51, blue: 0.92, alpha: 1),
        NSColor(srgbRed: 0.56, green: 0.47, blue: 0.84, alpha: 1),
        NSColor(srgbRed: 0.72, green: 0.44, blue: 0.68, alpha: 1),
    ]

    private static func loop(_ pattern: IslandTurnDots.Pattern) -> (
        seconds: Double, eases: Bool, dot: (Int, Int) -> (Keys, Double)?
    ) {
        let centre = { (x: Int, y: Int) in hypot(Double(x) - 1, Double(y) - 1) }
        switch pattern {
        case .chase:
            return (
                0.96, false,
                { x, y in
                    let place = ring[y * 3 + x]
                    return place < 0 ? nil : (trail, Double(place) / 8)
                }
            )
        case .think:
            return (2.0, true, { x, y in (twinkle, (1 - twinkles[y * 3 + x]).truncatingRemainder(dividingBy: 1)) })
        case .read:
            return (1.5, false, { x, y in (trail, (Double(y) * 1.2 + Double(x) * 0.3) / 3.6) })
        case .search:
            return (1.6, false, { x, _ in x == 1 ? (sweepMid, 0) : (sweepEdge, Double(x) / 4) })
        case .edit:
            return (1.4, true, { x, y in (swap, (x + y) % 2 == 1 ? 0.5 : 0) })
        case .fetch:
            return (1.2, false, { x, y in (trail, centre(x, y) / 2.6) })
        case .compact:
            return (1.2, false, { x, y in (trail, (2.0.squareRoot() - centre(x, y)) / 2.6) })
        case .write:
            return (1.8, false, { x, y in (fill, Double(y * 3 + x) * 0.05) })
        }
    }

    private static func value(_ keys: Keys, at phase: Double) -> Double {
        for i in 1..<keys.times.count where phase <= keys.times[i] {
            let t0 = keys.times[i - 1]
            let t1 = keys.times[i]
            let f = t1 > t0 ? (phase - t0) / (t1 - t0) : 0
            return keys.values[i - 1] + (keys.values[i] - keys.values[i - 1]) * f
        }
        return keys.values.last ?? 0.22
    }

    func configure(pattern: IslandTurnDots.Pattern, size: CGFloat, reduceMotion: Bool) {
        if let shown, shown.0 == pattern, shown.1 == size, shown.2 == reduceMotion { return }
        shown = (pattern, size, reduceMotion)
        for dot in layer?.sublayers ?? [] { dot.removeFromSuperlayer() }
        let unit = size / 12
        let loop = Self.loop(pattern)
        for index in 0..<9 {
            let x = index % 3
            let y = index / 3
            let dot = CALayer()
            let radius = 1.4 * unit
            dot.frame = CGRect(
                x: (2 + CGFloat(x) * 4) * unit - radius,
                y: (2 + CGFloat(y) * 4) * unit - radius,
                width: radius * 2,
                height: radius * 2
            )
            dot.cornerRadius = radius
            dot.backgroundColor = Self.prismDotColors[index].cgColor
            dot.opacity = 0.22
            if let (keys, at) = loop.dot(x, y) {
                let start = (1 - at).truncatingRemainder(dividingBy: 1)
                if reduceMotion {
                    dot.opacity = Float(Self.value(keys, at: start))
                } else {
                    let animation = CAKeyframeAnimation(keyPath: "opacity")
                    animation.values = keys.values
                    animation.keyTimes = keys.times.map { NSNumber(value: $0) }
                    animation.duration = loop.seconds
                    animation.repeatCount = .infinity
                    animation.timeOffset = start * loop.seconds
                    animation.calculationMode = .linear
                    if loop.eases {
                        animation.timingFunctions = Array(
                            repeating: CAMediaTimingFunction(name: .easeInEaseOut),
                            count: keys.values.count - 1
                        )
                    }
                    animation.isRemovedOnCompletion = false
                    dot.add(animation, forKey: "opacity")
                }
            }
            layer?.addSublayer(dot)
        }
    }
}

// MARK: - Subtle Obsidian Prism Static Optical Rim (0% CPU)

/// Draws a restrained static optical rim along the Dynamic Island silhouette, driven by the active
/// Sarto 4-palette theme (`PrismTokens`). Intentionally avoids animated SwiftUI gradients
/// (which force per-frame CoreGraphics CPU software rasterization).
struct IslandOpticalRim: View {
    let radius: CGFloat
    let shoulderWidth: CGFloat
    let aura: IslandAuraState
    let tokens: PrismTokens
    let isOpen: Bool
    let paused: Bool
    let reduceMotion: Bool

    var body: some View {
        let shape = IslandShape(radius: radius, shoulders: true, shoulderWidth: shoulderWidth)
        ZStack {
            // Base etched optical bevel synced to active palette warmth
            shape
                .stroke(
                    (tokens.palette == .warm || tokens.palette == .alabaster
                        ? Color(hex: 0xF5F0E6)
                        : Color.white).opacity(isOpen ? 0.14 : 0.085),
                    lineWidth: isOpen ? 1.0 : 0.75
                )

            switch aura {
            case .calm, .running:
                if isOpen {
                    shape
                        .stroke(
                            LinearGradient(
                                colors: [
                                    tokens.primary.opacity(0.28),
                                    tokens.prismIris.opacity(0.20),
                                    Color.clear,
                                ],
                                startPoint: .bottomLeading,
                                endPoint: .topTrailing
                            ),
                            lineWidth: 1.0
                        )
                }

            case .waiting:
                shape
                    .stroke(IslandTheme.attention.opacity(0.72), lineWidth: 1.15)

            case .failed:
                shape
                    .stroke(IslandTheme.danger.opacity(0.75), lineWidth: 1.15)

            case .done:
                shape
                    .stroke(IslandTheme.success.opacity(0.56), lineWidth: 1.0)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Status Signals & Progress Rings

enum IslandSignal: Equatable, Sendable {
    case waiting
    case failed
    case running(IslandTurnDots.Pattern)
    case stuck
    case limited
    case unread
}

struct IslandWaitingDot: View {
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(IslandTheme.attentionDot)
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(IslandTheme.attentionDot.opacity(0.24))
                    .frame(width: size + 6, height: size + 6)
            )
            .frame(width: 14, height: 14)
    }
}

struct IslandLimitRing: View {
    var size: CGFloat = 13

    var body: some View {
        ZStack {
            Circle().fill(IslandTheme.usageRed.opacity(0.22))
            Circle().stroke(IslandTheme.usageRed, lineWidth: size * 0.17).padding(size * 0.15)
        }
        .frame(width: size, height: size)
    }
}

struct IslandSignalView: View {
    let signal: IslandSignal
    var size: CGFloat = 14
    let reduceMotion: Bool

    var body: some View {
        switch signal {
        case .waiting:
            IslandWaitingDot(size: size >= 14 ? 8 : 7)
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: size - 2, weight: .medium))
                .foregroundStyle(IslandTheme.danger)
                .frame(width: size, height: size)
        case .running(let pattern):
            IslandTurnDots(pattern: pattern, size: 12, reduceMotion: reduceMotion)
                .frame(width: size, height: size)
        case .stuck:
            Image(systemName: "clock")
                .font(.system(size: size - 2, weight: .medium))
                .foregroundStyle(IslandTheme.warning)
                .frame(width: size, height: size)
        case .limited:
            IslandLimitRing(size: size - 1)
                .frame(width: size, height: size)
        case .unread:
            let dot: CGFloat = size >= 14 ? 8 : 6
            Circle()
                .fill(IslandTheme.unread)
                .frame(width: dot, height: dot)
                .frame(width: size, height: size)
        }
    }
}

struct IslandPlanRing: View {
    let done: Int
    let total: Int
    var size: CGFloat = 13

    var body: some View {
        let share = total > 0 ? CGFloat(done) / CGFloat(total) : 0
        ZStack {
            Circle().stroke(IslandTheme.track, lineWidth: 2.2)
            Circle()
                .trim(from: 0, to: share)
                .stroke(IslandTheme.planDone, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(1.1)
        .frame(width: size, height: size)
    }
}

struct IslandCacheRing: View {
    let share: Double

    var body: some View {
        ZStack {
            Circle().stroke(IslandTheme.track, lineWidth: 1.6)
            Circle()
                .trim(from: 0, to: max(0, min(1, share)))
                .stroke(IslandTheme.warning, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 11, height: 11)
    }
}

struct IslandUsageRing: View {
    let percent: Double

    var body: some View {
        let share = min(1, max(0, percent / 100))
        ZStack {
            Circle().fill(IslandTheme.usageRed.opacity(0.18))
            Circle()
                .trim(from: 0, to: share)
                .stroke(IslandTheme.usageRed, style: StrokeStyle(lineWidth: 2.2, lineCap: .butt))
                .rotationEffect(.degrees(-90))
                .padding(1.1)
        }
        .frame(width: 12, height: 12)
    }
}

// MARK: - Kinetic Pixel-Strike Running Animation (Agent Sprite -> Pixel Stream -> App Icon)

struct IslandPixelCell: Sendable {
    let gx: Int
    let gy: Int
    let r: Double
    let g: Double
    let b: Double

    var color: Color {
        Color(red: r, green: g, blue: b)
    }

    var luminance: Double { 0.299 * r + 0.587 * g + 0.114 * b }
    var saturation: Double { max(r, g, b) - min(r, g, b) }

    func distance(to other: IslandPixelCell) -> Double {
        let dr = r - other.r, dg = g - other.g, db = b - other.b
        return dr * dr + dg * dg + db * db
    }
}

struct IslandPixelSprite: Sendable {
    let gridSize: Int
    let cells: [IslandPixelCell]
    let palette: [Color]
    /// Indices into `cells` on the right half of the icon used as pixel launch emitters.
    let launchIndices: [Int]
}

@MainActor
enum IslandPixelSpriteCache {
    private static var cache: [String: IslandPixelSprite] = [:]
    /// Cells per side. Marks are drawn 16-20 pt tall, so a cell lands near 1.2 pt: fine enough to
    /// keep a mark recognisable, coarse enough to read as pixel art.
    static let gridSize = 14

    static func sprite(for agent: IslandAgentIdentity) -> IslandPixelSprite {
        let key = "\(agent.harness)|\(agent.color ?? "")|\(agent.name.prefix(1))"
        if let hit = cache[key] { return hit }
        let built = buildAgentSprite(agent: agent)
        cache[key] = built
        return built
    }

    /// Sarto's app icon as pixel art: a dark tile whose dot matrix grows and brightens toward the
    /// lower right, closing into a solid quarter, as on the real icon.
    static let appSprite: IslandPixelSprite = {
        let n = gridSize
        var grid = Array(repeating: Array(repeating: -1.0, count: n), count: n)
        let inner = Double(n - 3)
        for gy in stride(from: 1, to: n - 1, by: 2) {
            for gx in stride(from: 1, to: n - 1, by: 2) {
                let u = Double(gx - 1) / inner
                let v = Double(gy - 1) / inner
                let reach = (u + v) / 2
                guard reach > 0.30, !(u > 0.9 && v < 0.12) else { continue }
                let t = min(1, max(0, (reach - 0.30) / 0.62))
                grid[gy][gx] = t
                let arc = (1 - u) * (1 - u) + (1 - v) * (1 - v)
                if arc < 0.45 {
                    for (dx, dy) in [(1, 0), (0, 1), (1, 1)] where gx + dx < n - 1 && gy + dy < n - 1 {
                        grid[gy + dy][gx + dx] = max(grid[gy + dy][gx + dx], t)
                    }
                }
            }
        }
        var cells: [IslandPixelCell] = []
        for gy in 0..<n {
            for gx in 0..<n {
                if (gx == 0 || gx == n - 1) && (gy == 0 || gy == n - 1) { continue }
                let edge = gx == 0 || gy == 0 || gx == n - 1 || gy == n - 1
                let t = grid[gy][gx]
                if t >= 0 {
                    cells.append(IslandPixelCell(gx: gx, gy: gy, r: 0.88 - 0.64 * t, g: 0.94 - 0.42 * t, b: 1.0 - 0.03 * t))
                } else if edge {
                    cells.append(IslandPixelCell(gx: gx, gy: gy, r: 0.16, g: 0.24, b: 0.38))
                } else {
                    let shade = Double(gx + gy) / Double(2 * n)
                    cells.append(IslandPixelCell(gx: gx, gy: gy, r: 0.06 + 0.02 * shade, g: 0.09 + 0.03 * shade, b: 0.16 + 0.06 * shade))
                }
            }
        }
        let lit = cells.indices.filter { cells[$0].luminance > 0.4 }
        return IslandPixelSprite(
            gridSize: n,
            cells: cells,
            palette: [Color(hex: 0x86C5FF), Color(hex: 0x3B82F6), Color.white],
            launchIndices: lit
        )
    }()

    private static func buildAgentSprite(agent: IslandAgentIdentity) -> IslandPixelSprite {
        let cells: [IslandPixelCell]
        if agent.harness == "antigravity" || agent.id == "antigravity" {
            cells = pixelize(colors: 5, liftDark: false, draw: drawAntigravity)
        } else if let image = IslandMarkImageCache.image(for: agent.harness) {
            cells = pixelize(colors: 4, liftDark: true) { ctx, side in
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                let pad = side * 0.04
                image.draw(
                    in: NSRect(x: pad, y: pad, width: side - 2 * pad, height: side - 2 * pad),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1
                )
                NSGraphicsContext.restoreGraphicsState()
            }
        } else {
            cells = []
        }
        guard !cells.isEmpty else { return fallbackSprite(agent: agent) }

        var palette: [Color] = []
        var seen: [IslandPixelCell] = []
        for cell in cells where cell.saturation > 0.18 || cell.luminance > 0.55 {
            if !seen.contains(where: { $0.distance(to: cell) < 0.05 }) && seen.count < 6 {
                seen.append(cell)
                palette.append(cell.color)
            }
        }
        if palette.isEmpty {
            palette = [agentDot(agent) ?? IslandTheme.prismCobalt, IslandTheme.prismIris]
        }
        let n = gridSize
        let leftHalf = cells.indices.filter { cells[$0].gx < n / 2 }
        return IslandPixelSprite(
            gridSize: n,
            cells: cells,
            palette: palette,
            launchIndices: leftHalf.isEmpty ? Array(cells.indices) : leftHalf
        )
    }

    /// Draws a mark at 8x the grid, keeps each cell at least 42% covered, and snaps the cells to at
    /// most `colors` shared colors, so edges stay crisp instead of averaging into grey. A dark,
    /// colorless mark (a black logo) is drawn light, since the island is black.
    private static func pixelize(
        colors k: Int,
        liftDark: Bool,
        draw: (CGContext, CGFloat) -> Void
    ) -> [IslandPixelCell] {
        let n = gridSize
        let ss = 8
        let px = n * ss
        var buffer = [UInt8](repeating: 0, count: px * px * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: &buffer,
                  width: px,
                  height: px,
                  bitsPerComponent: 8,
                  bytesPerRow: px * 4,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return [] }
        ctx.interpolationQuality = .high
        draw(ctx, CGFloat(px))

        var raw: [IslandPixelCell] = []
        for gy in 0..<n {
            for gx in 0..<n {
                var a = 0.0, r = 0.0, g = 0.0, b = 0.0
                for sy in 0..<ss {
                    let row = px - 1 - (gy * ss + sy)
                    for sx in 0..<ss {
                        let o = (row * px + gx * ss + sx) * 4
                        a += Double(buffer[o + 3]) / 255
                        r += Double(buffer[o]) / 255
                        g += Double(buffer[o + 1]) / 255
                        b += Double(buffer[o + 2]) / 255
                    }
                }
                guard a / Double(ss * ss) >= 0.42 else { continue }
                raw.append(IslandPixelCell(gx: gx, gy: gy, r: min(1, r / a), g: min(1, g / a), b: min(1, b / a)))
            }
        }
        guard !raw.isEmpty else { return [] }

        var centres: [IslandPixelCell] = []
        for cell in raw.sorted(by: { $0.luminance < $1.luminance }) where centres.count < k {
            if !centres.contains(where: { $0.distance(to: cell) < 0.04 }) { centres.append(cell) }
        }
        for _ in 0..<8 {
            var sums = Array(repeating: (r: 0.0, g: 0.0, b: 0.0, n: 0.0), count: centres.count)
            for cell in raw {
                let i = nearest(cell, in: centres)
                sums[i].r += cell.r
                sums[i].g += cell.g
                sums[i].b += cell.b
                sums[i].n += 1
            }
            for i in centres.indices where sums[i].n > 0 {
                centres[i] = IslandPixelCell(gx: 0, gy: 0, r: sums[i].r / sums[i].n, g: sums[i].g / sums[i].n, b: sums[i].b / sums[i].n)
            }
        }
        return raw.map { cell in
            var c = centres[nearest(cell, in: centres)]
            if liftDark && c.luminance < 0.2 && c.saturation < 0.15 {
                c = IslandPixelCell(gx: 0, gy: 0, r: 0.90, g: 0.90, b: 0.93)
            }
            return IslandPixelCell(gx: cell.gx, gy: cell.gy, r: c.r, g: c.g, b: c.b)
        }
    }

    private static func nearest(_ cell: IslandPixelCell, in centres: [IslandPixelCell]) -> Int {
        var best = 0
        var bestDistance = Double.infinity
        for (i, centre) in centres.enumerated() {
            let d = centre.distance(to: cell)
            if d < bestDistance {
                bestDistance = d
                best = i
            }
        }
        return best
    }

    private static func drawAntigravity(_ ctx: CGContext, _ side: CGFloat) {
        let path = AntigravitySwooshPath().path(in: CGRect(x: 0, y: 0, width: side, height: side))
        ctx.saveGState()
        ctx.addPath(path.cgPath)
        ctx.clip()
        let hexes: [Int] = [0x34A853, 0x4285F4, 0x9B72CB, 0xEA4335, 0xFBBC05]
        let colors: [CGColor] = hexes.map { hex in
            let r = CGFloat((hex >> 16) & 0xFF) / 255.0
            let g = CGFloat((hex >> 8) & 0xFF) / 255.0
            let b = CGFloat(hex & 0xFF) / 255.0
            return CGColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
        }
        if let space = CGColorSpace(name: CGColorSpace.sRGB),
           let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 0.28, 0.54, 0.78, 1])
        {
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: side, y: side), options: [])
        }
        ctx.restoreGState()
    }

    private static func agentDot(_ agent: IslandAgentIdentity) -> Color? {
        agent.color.flatMap { IslandAssets.agentDotHex[$0] }.map { Color(hex: $0) }
    }

    /// A rounded tile in the agent's color carrying its initial, for a harness with no mark.
    private static func fallbackSprite(agent: IslandAgentIdentity) -> IslandPixelSprite {
        let n = gridSize
        let hex = agent.color.flatMap { IslandAssets.agentDotHex[$0] } ?? 0x4C8DF6
        let base = IslandPixelCell(
            gx: 0,
            gy: 0,
            r: Double((hex >> 16) & 0xFF) / 255,
            g: Double((hex >> 8) & 0xFF) / 255,
            b: Double(hex & 0xFF) / 255
        )
        let letter = pixelize(colors: 1, liftDark: false) { ctx, side in
            let text = String(agent.name.prefix(1)).uppercased() as NSString
            let font = NSFont.systemFont(ofSize: side * 0.62, weight: .heavy)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let size = text.size(withAttributes: attributes)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            text.draw(at: NSPoint(x: (side - size.width) / 2, y: (side - size.height) / 2), withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
        }
        // Text lands upside down in this unflipped context, unlike an image: turn its rows over.
        let glyph = Set(letter.map { (n - 1 - $0.gy) * n + $0.gx })
        var cells: [IslandPixelCell] = []
        for gy in 1..<(n - 1) {
            for gx in 1..<(n - 1) {
                let corner = (gx == 1 || gx == n - 2) && (gy == 1 || gy == n - 2)
                if corner { continue }
                if glyph.contains(gy * n + gx) {
                    cells.append(IslandPixelCell(gx: gx, gy: gy, r: 0.97, g: 0.97, b: 0.99))
                } else {
                    let edge = gx == 1 || gx == n - 2 || gy == 1 || gy == n - 2
                    let k = edge ? 1.0 : 0.62
                    cells.append(IslandPixelCell(gx: gx, gy: gy, r: base.r * k, g: base.g * k, b: base.b * k))
                }
            }
        }
        let launch = cells.indices.filter { cells[$0].gx < n / 2 }
        return IslandPixelSprite(
            gridSize: n,
            cells: cells,
            palette: [base.color, IslandTheme.prismCobalt, IslandTheme.prismIris],
            launchIndices: launch.isEmpty ? Array(cells.indices) : launch
        )
    }
}

/// Real-time duplex pulse & impact physics engine (Scheme C: App ⇄ Agents) for the Dynamic Island.
/// Top lane: Sarto App icon (left) fires blue-white command pulses into active Agent(s) (right).
/// Bottom lane: struck Agent(s) recoil, flash, and fire back dense brand-colored Token pixel streaks
/// that charge the App icon bottom-up until a full-charge overdrive shockwave bursts.
@MainActor
final class IslandStrikeSimulation {
    enum ShotLane {
        case command // Left -> Right (App -> Agent, upper lane)
        case token   // Right -> Left (Agent -> App, lower lane)
    }

    struct AgentSlot {
        let index: Int
        let x: CGFloat
        let y: CGFloat
        let size: CGFloat
        var half: CGFloat { size * 0.5 }
    }

    struct PixelShot {
        var lane: ShotLane
        var x: CGFloat
        var y: CGFloat
        var vx: CGFloat
        var vy: CGFloat
        var color: Color
        var tailLength: Int
        var thick: Bool
        var targetAgentIndex: Int
    }

    struct PixelSpark {
        var x: CGFloat
        var y: CGFloat
        var vx: CGFloat
        var vy: CGFloat
        var gravity: CGFloat
        var age: Double
        var life: Double
        var color: Color
        var size: CGFloat
    }

    struct Shockwave {
        var age: Double
        var duration: Double
        var dir: CGFloat
        var color: Color
        var accent: Color
    }

    struct SpeedLine {
        var x: CGFloat
        var y: CGFloat
        var length: CGFloat
        var speed: CGFloat
        var dir: CGFloat
        var alpha: Double
    }

    struct MissingPixel {
        var agentIndex: Int
        var cellIndex: Int
        var ttl: Double
    }

    private(set) var shots: [PixelShot] = []
    private(set) var sparks: [PixelSpark] = []
    private(set) var shockwaves: [Shockwave] = []
    private(set) var speedLines: [SpeedLine] = []
    private(set) var missingPixels: [MissingPixel] = []
    private(set) var chargeHistory: [Color] = []

    private(set) var elapsed: Double = 0
    private(set) var appKick: Double = 0
    private(set) var appSquash: Double = 0
    private(set) var appFlash: Double = 0
    private(set) var appCharge: Double = 0
    private(set) var agentSquash: [Double] = [0, 0, 0]
    private(set) var agentFlash: [Double] = [0, 0, 0]
    private(set) var agentKick: [Double] = [0, 0, 0]
    private(set) var arenaShake: Double = 0

    private var lastTimestamp: Double?
    private var commandCarry: Double = 0.85
    private var rngState: UInt64 = 0x5EED_CAFE_C0DE
    private var commandCounter: Int = 0
    private var tokenCounter: Int = 0

    private static let commandColors: [Color] = [
        Color(hex: 0x5AA2FF),
        Color(hex: 0x86C5FF),
        Color(hex: 0x9F8CFF),
        Color.white,
    ]

    init() {
        speedLines = (0..<6).map { idx in
            let isTop = idx % 2 == 0
            return SpeedLine(
                x: nextCGFloat(0, 1),
                y: isTop ? nextCGFloat(0.16, 0.42) : nextCGFloat(0.58, 0.84),
                length: nextCGFloat(7, 18),
                speed: nextCGFloat(0.65, 1.35),
                dir: isTop ? 1 : -1,
                alpha: Double(nextCGFloat(0.05, 0.13))
            )
        }
    }

    private func nextUnit() -> Double {
        rngState = rngState &* 6364136223846793005 &+ 1442695040888963407
        let shifted = (rngState >> 11) & 0x1FFFFF_FFFFFFFF
        return Double(shifted) / Double(0x200000_00000000)
    }

    private func nextCGFloat(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        lo + (hi - lo) * CGFloat(nextUnit())
    }

    static func computeAgentSlots(
        count: Int,
        anchorX: CGFloat,
        arenaHeight: CGFloat,
        appSize: CGFloat
    ) -> [AgentSlot] {
        let clamped = max(1, min(3, count))
        let midY = arenaHeight * 0.5
        switch clamped {
        case 1:
            return [AgentSlot(index: 0, x: anchorX, y: midY, size: appSize)]
        case 2:
            let s = min(13.5, max(11.0, (arenaHeight - 8) * 0.48))
            let dy = min(arenaHeight * 0.5 - s * 0.5 - 2.5, s * 0.54)
            return [
                AgentSlot(index: 0, x: anchorX - 3.0, y: midY - dy, size: s),
                AgentSlot(index: 1, x: anchorX + 3.5, y: midY + dy, size: s),
            ]
        default:
            let s = min(11.0, max(9.5, (arenaHeight - 6) * 0.38))
            let dy = min(arenaHeight * 0.5 - s * 0.5 - 2.0, s * 0.72)
            return [
                AgentSlot(index: 0, x: anchorX - 4.0, y: midY - dy, size: s),
                AgentSlot(index: 1, x: anchorX + 4.5, y: midY, size: s),
                AgentSlot(index: 2, x: anchorX - 4.0, y: midY + dy, size: s),
            ]
        }
    }

    func step(
        timestamp: Double,
        arenaWidth: CGFloat,
        arenaHeight: CGFloat,
        appCenterX: CGFloat,
        appHalfSize: CGFloat,
        agentSlots: [AgentSlot],
        agentSprites: [IslandPixelSprite],
        intensity: Double,
        allPalettes: [Color]
    ) {
        let dt: Double
        if let prev = lastTimestamp {
            let raw = timestamp - prev
            if raw <= 0 { return }
            dt = min(0.05, raw)
        } else {
            dt = 1.0 / 60.0
        }
        lastTimestamp = timestamp
        elapsed += dt

        guard !agentSlots.isEmpty, !agentSprites.isEmpty else { return }

        let midY = arenaHeight * 0.5
        let clampedIntensity = max(0.25, min(1.0, intensity))
        let palette = allPalettes.isEmpty ? agentSprites[0].palette : allPalettes

        // 1. Top lane: App icon fires crisp command pulses toward active Agent(s) round-robin
        let squadMultiplier = 1.0 + Double(max(0, agentSlots.count - 1)) * 0.28
        let commandsPerSecond = (2.6 + 3.8 * clampedIntensity) * squadMultiplier
        commandCarry += commandsPerSecond * dt
        var burstCap = 2
        while commandCarry >= 1.0 && burstCap > 0 {
            commandCarry -= 1.0
            burstCap -= 1
            fireCommandPulse(
                appCenterX: appCenterX,
                appHalfSize: appHalfSize,
                midY: midY,
                agentSlots: agentSlots,
                intensity: clampedIntensity
            )
        }

        // 2. Advance both lanes of projectiles and resolve impacts on Agents (right) & App (left)
        let appImpactX = appCenterX + appHalfSize - 1.0
        var survivingShots: [PixelShot] = []
        survivingShots.reserveCapacity(shots.count + 6)
        var pendingReturns: [(slotIndex: Int, hitY: CGFloat)] = []

        for var shot in shots {
            shot.x += shot.vx * CGFloat(dt)
            shot.y += shot.vy * CGFloat(dt)

            switch shot.lane {
            case .command:
                let idx = min(max(0, shot.targetAgentIndex), agentSlots.count - 1)
                let slot = agentSlots[idx]
                let agentImpactX = slot.x - slot.half + 1.0
                if shot.x >= agentImpactX {
                    handleCommandHit(
                        slot: slot,
                        hitX: agentImpactX,
                        hitY: shot.y,
                        color: shot.color
                    )
                    pendingReturns.append((slotIndex: idx, hitY: shot.y))
                } else if shot.x < arenaWidth + 24 {
                    survivingShots.append(shot)
                }

            case .token:
                if shot.x <= appImpactX {
                    handleTokenImpactOnApp(
                        hitX: appImpactX,
                        hitY: shot.y,
                        color: shot.color,
                        appCenterX: appCenterX,
                        midY: midY,
                        intensity: clampedIntensity,
                        palette: palette
                    )
                } else if shot.x > -24 {
                    survivingShots.append(shot)
                }
            }
        }
        shots = survivingShots

        // 3. Struck Agent(s) immediately fire back 2-3 dense brand-colored Token streaks on bottom lane
        for ret in pendingReturns {
            let slot = agentSlots[ret.slotIndex]
            let sprite = agentSprites[ret.slotIndex % agentSprites.count]
            fireTokenReturnBurst(
                slot: slot,
                sprite: sprite,
                appCenterX: appCenterX,
                appHalfSize: appHalfSize,
                midY: midY,
                intensity: clampedIntensity
            )
        }

        // 4. Advance sparks with gravity & quadratic fade
        sparks = sparks.compactMap { spark in
            var s = spark
            s.age += dt
            guard s.age < s.life else { return nil }
            s.vy += s.gravity * CGFloat(dt)
            s.x += s.vx * CGFloat(dt)
            s.y += s.vy * CGFloat(dt)
            return s
        }

        // 5. Advance shockwave arcs
        shockwaves = shockwaves.compactMap { wave in
            var w = wave
            w.age += dt
            return w.age < w.duration ? w : nil
        }

        // 6. Advance dual-lane ambient speed lines (top -> right, bottom -> left)
        for i in speedLines.indices {
            let delta = speedLines[i].speed * CGFloat(dt) * CGFloat(0.65 + 0.9 * clampedIntensity)
            speedLines[i].x += speedLines[i].dir * delta
            if speedLines[i].dir > 0 && speedLines[i].x > 1.25 {
                speedLines[i].x = -0.25
                speedLines[i].y = nextCGFloat(0.14, 0.42)
            } else if speedLines[i].dir < 0 && speedLines[i].x < -0.25 {
                speedLines[i].x = 1.25
                speedLines[i].y = nextCGFloat(0.58, 0.86)
            }
        }

        // 7. Decay missing-pixel flickers and kinetic impulses
        missingPixels = missingPixels.compactMap { item in
            var m = item
            m.ttl -= dt
            return m.ttl > 0 ? m : nil
        }
        appKick = max(0, appKick - 9.5 * dt)
        appSquash = max(0, appSquash - 8.2 * dt)
        appFlash = max(0, appFlash - 6.8 * dt)
        for i in 0..<3 {
            agentSquash[i] = max(0, agentSquash[i] - 8.8 * dt)
            agentFlash[i] = max(0, agentFlash[i] - 7.2 * dt)
            agentKick[i] = max(0, agentKick[i] - 9.0 * dt)
        }
        arenaShake = max(0, arenaShake - 5.5 * dt)
    }

    private func fireCommandPulse(
        appCenterX: CGFloat,
        appHalfSize: CGFloat,
        midY: CGFloat,
        agentSlots: [AgentSlot],
        intensity: Double
    ) {
        guard shots.count < 42 else { return }
        let idx = commandCounter % agentSlots.count
        commandCounter &+= 1
        appKick = 1.0

        let slot = agentSlots[idx]
        let launchX = appCenterX + appHalfSize - 1.0
        let launchY = midY - nextCGFloat(2.0, min(5.5, appHalfSize * 0.56))
        let targetY = slot.y - nextCGFloat(0.0, slot.half * 0.45)

        let dx = max(24, (slot.x - slot.half) - launchX)
        let speed = CGFloat(285 + 165 * intensity) * nextCGFloat(0.94, 1.12)
        let flightTime = dx / speed
        let vy = (targetY - launchY) / max(0.08, flightTime)

        let color = Self.commandColors[commandCounter % Self.commandColors.count]
        shots.append(PixelShot(
            lane: .command,
            x: launchX,
            y: launchY,
            vx: speed,
            vy: vy,
            color: color,
            tailLength: 3,
            thick: false,
            targetAgentIndex: idx
        ))
    }

    private func handleCommandHit(
        slot: AgentSlot,
        hitX: CGFloat,
        hitY: CGFloat,
        color: Color
    ) {
        if slot.index < agentSquash.count {
            agentSquash[slot.index] = max(agentSquash[slot.index], 0.82)
            agentFlash[slot.index] = max(agentFlash[slot.index], 0.85)
        }

        // Crisp cyan-white micro sparks rebounding left off the Agent's impact face
        let count = nextUnit() < 0.65 ? 2 : 1
        for i in 0..<count where sparks.count < 48 {
            sparks.append(PixelSpark(
                x: hitX,
                y: hitY,
                vx: nextCGFloat(-75, -18),
                vy: nextCGFloat(-65, 55),
                gravity: 190,
                age: 0,
                life: Double(nextCGFloat(0.16, 0.30)),
                color: i == 0 ? .white : color,
                size: 1.85
            ))
        }
    }

    private func fireTokenReturnBurst(
        slot: AgentSlot,
        sprite: IslandPixelSprite,
        appCenterX: CGFloat,
        appHalfSize: CGFloat,
        midY: CGFloat,
        intensity: Double
    ) {
        if slot.index < agentKick.count {
            agentKick[slot.index] = 1.0
        }

        let burstCount = intensity > 0.62 ? 3 : 2
        let cellPx = slot.size / CGFloat(sprite.gridSize)

        for b in 0..<burstCount where shots.count < 48 {
            tokenCounter &+= 1
            let launchX: CGFloat
            let launchY: CGFloat
            let tokenColor: Color

            if !sprite.launchIndices.isEmpty {
                let pick = sprite.launchIndices[Int(nextUnit() * Double(sprite.launchIndices.count)) % sprite.launchIndices.count]
                let cell = sprite.cells[pick]
                launchX = slot.x - slot.half + (CGFloat(cell.gx) + 0.5) * cellPx - CGFloat(b) * 3.2
                launchY = slot.y - slot.half + (CGFloat(cell.gy) + 0.5) * cellPx + nextCGFloat(0.5, 2.5)
                tokenColor = (b == 0) ? cell.color : sprite.palette[tokenCounter % max(1, sprite.palette.count)]
                if missingPixels.count < 10 {
                    missingPixels.append(MissingPixel(agentIndex: slot.index, cellIndex: pick, ttl: 0.14))
                }
            } else {
                launchX = slot.x - slot.half - CGFloat(b) * 3.2
                launchY = slot.y + nextCGFloat(0, 4)
                tokenColor = sprite.palette[tokenCounter % max(1, sprite.palette.count)]
            }

            let targetY = midY + nextCGFloat(1.0, min(6.5, appHalfSize * 0.66))
            let dx = max(24, launchX - (appCenterX + appHalfSize))
            let speed = CGFloat(250 + 175 * intensity) * nextCGFloat(0.86, 1.14)
            let flightTime = dx / speed
            let vy = (targetY - launchY) / max(0.08, flightTime)

            let tail = 2 + (intensity > 0.50 ? 1 : 0) + (b == 0 && nextUnit() > 0.45 ? 1 : 0)
            shots.append(PixelShot(
                lane: .token,
                x: launchX,
                y: launchY,
                vx: -speed,
                vy: vy,
                color: tokenColor,
                tailLength: tail,
                thick: b == 0 && intensity > 0.64,
                targetAgentIndex: slot.index
            ))
        }
    }

    private func handleTokenImpactOnApp(
        hitX: CGFloat,
        hitY: CGFloat,
        color: Color,
        appCenterX: CGFloat,
        midY: CGFloat,
        intensity: Double,
        palette: [Color]
    ) {
        appSquash = max(appSquash, 0.48)
        appFlash = max(appFlash, 0.34)
        appCharge += 0.068 + 0.022 * intensity

        chargeHistory.append(color)
        if chargeHistory.count > 12 {
            chargeHistory.removeFirst(chargeHistory.count - 12)
        }

        // Rebounding pixel sparks spraying rightward off the App icon's right impact face
        let sparkCount = nextUnit() < (0.55 + 0.35 * intensity) ? 2 : 1
        for i in 0..<sparkCount where sparks.count < 48 {
            let whiteHot = i == 0 && nextUnit() < 0.25
            sparks.append(PixelSpark(
                x: hitX,
                y: hitY,
                vx: nextCGFloat(26, 108),
                vy: nextCGFloat(-86, 86),
                gravity: 230,
                age: 0,
                life: Double(nextCGFloat(0.20, 0.38)),
                color: whiteHot ? .white : color,
                size: 2.0
            ))
        }

        // Full charge overdrive burst (shockwave + big recoil + celebratory sparks)
        if appCharge >= 1.0 {
            appCharge = 0
            appSquash = 1.0
            appFlash = 1.0
            arenaShake = 1.0

            let accent = palette[(tokenCounter + 1) % max(1, palette.count)]
            shockwaves.append(Shockwave(age: 0, duration: 0.34, dir: 1, color: color, accent: accent))

            let burstCount = 8
            for i in 0..<burstCount where sparks.count < 54 {
                let angle = Double(i) / Double(burstCount) * .pi * 2.0 + nextUnit() * 0.4
                let spd = nextCGFloat(48, 125)
                let c = i % 3 == 0 ? Color.white : palette[(tokenCounter + i) % max(1, palette.count)]
                sparks.append(PixelSpark(
                    x: appCenterX + nextCGFloat(-4, 4),
                    y: midY + nextCGFloat(-5, 5),
                    vx: CGFloat(cos(angle)) * spd + 18,
                    vy: CGFloat(sin(angle)) * spd - 16,
                    gravity: 190,
                    age: 0,
                    life: Double(nextCGFloat(0.26, 0.50)),
                    color: c,
                    size: 2.0
                ))
            }
        }
    }
}

/// Renders the kinetic Scheme C (Duplex Pulse Crossfire: App ⇄ Agents) arena inside the Dynamic Island.
/// Supports 1-3 staggered Agent pixel sprites on the right (+ overflow badge for >3) and seamless
/// tunneling across physical MacBook notches.
struct IslandPixelStrikeStage: View {
    let agents: [IslandAgentIdentity]
    let tps: Double?
    let runningCount: Int
    let notchGapWidth: CGFloat
    let leftWingWidth: CGFloat
    let paused: Bool
    let reduceMotion: Bool
    /// 60 for the lively style, 30 for the calm one, which also fires fewer shots.
    var framesPerSecond: Double = 60

    @State private var sim = IslandStrikeSimulation()

    private var activeAgents: [IslandAgentIdentity] {
        if agents.isEmpty {
            return [IslandAgentIdentity(id: "sarto", name: "Agent", harness: "claude-code", color: nil)]
        }
        return Array(agents.prefix(3))
    }

    private var normalizedIntensity: Double {
        let speedBoost: Double = {
            guard let tps, tps > 0 else { return 0.40 }
            return min(1.0, 0.32 + (tps / 85.0) * 0.68)
        }()
        let multiBoost = min(0.32, Double(max(0, runningCount - 1)) * 0.14)
        let intensity = min(1.0, max(speedBoost, 0.38 + multiBoost))
        return framesPerSecond < 60 ? intensity * 0.7 : intensity
    }

    var body: some View {
        let visibleAgents = activeAgents
        let sprites = visibleAgents.map { IslandPixelSpriteCache.sprite(for: $0) }
        let allPalettes = sprites.flatMap(\.palette)
        let effectivePalette = allPalettes.isEmpty ? [IslandTheme.prismCobalt, IslandTheme.prismIris] : allPalettes
        let policyFPS = PrismEnergyPolicy.framesPerSecond(
            for: .streaming,
            surface: .widget,
            displayMaxFPS: 60,
            conditions: PrismEnergyMonitor.shared.conditions
        )
        let effectiveFPS = PrismEnergyPolicy.capped(policyFPS, requestedFPS: Int(framesPerSecond.rounded()))

        if reduceMotion || effectiveFPS <= 0 {
            staticReducedMotionCanvas(sprites: sprites, palette: effectivePalette)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / Double(max(1, effectiveFPS)), paused: paused)) { timeline in
                Canvas(rendersAsynchronously: false) { context, size in
                    guard size.width > 40, size.height > 12 else { return }
                    let appSize: CGFloat = min(20, max(16, size.height - 10))
                    let appHalf = appSize * 0.5
                    let appX: CGFloat = 10 + appHalf
                    let squadAnchorX = resolveSquadAnchorX(size: size, appHalf: appHalf, agentCount: sprites.count)
                    let slots = IslandStrikeSimulation.computeAgentSlots(
                        count: sprites.count,
                        anchorX: squadAnchorX,
                        arenaHeight: size.height,
                        appSize: appSize
                    )

                    sim.step(
                        timestamp: timeline.date.timeIntervalSinceReferenceDate,
                        arenaWidth: size.width,
                        arenaHeight: size.height,
                        appCenterX: appX,
                        appHalfSize: appHalf,
                        agentSlots: slots,
                        agentSprites: sprites,
                        intensity: normalizedIntensity,
                        allPalettes: effectivePalette
                    )

                    drawArena(
                        context: &context,
                        size: size,
                        appX: appX,
                        appSize: appSize,
                        slots: slots,
                        sprites: sprites,
                        palette: effectivePalette
                    )
                }
            }
        }
    }

    private func resolveSquadAnchorX(size: CGSize, appHalf: CGFloat, agentCount: Int) -> CGFloat {
        if notchGapWidth > 0 {
            let rightPad: CGFloat = agentCount > 1 ? 13 : (appHalf + 5)
            let rightEarStart = leftWingWidth + notchGapWidth
            let minAnchor = rightEarStart + (agentCount > 1 ? 11 : appHalf + 3)
            let preferred = rightEarStart + (agentCount > 1 ? 38 : 36 + appHalf)
            return max(minAnchor, min(size.width - rightPad, preferred))
        }
        let rightPad: CGFloat = agentCount > 1 ? 15 : (appHalf + 10)
        return size.width - rightPad
    }

    private func staticReducedMotionCanvas(sprites: [IslandPixelSprite], palette: [Color]) -> some View {
        Canvas(rendersAsynchronously: false) { context, size in
            guard size.width > 40, size.height > 12 else { return }
            let appSize: CGFloat = min(20, max(16, size.height - 10))
            let appHalf = appSize * 0.5
            let appX: CGFloat = 10 + appHalf
            let squadAnchorX = resolveSquadAnchorX(size: size, appHalf: appHalf, agentCount: sprites.count)
            let slots = IslandStrikeSimulation.computeAgentSlots(
                count: sprites.count,
                anchorX: squadAnchorX,
                arenaHeight: size.height,
                appSize: appSize
            )
            let midY = size.height * 0.5

            drawPlaceholderAppIcon(
                context: &context,
                centerX: appX,
                centerY: midY,
                size: appSize,
                kick: 0,
                squash: 0,
                flash: 0,
                charge: 0.45,
                jitterX: 0,
                jitterY: 0,
                chargeColors: palette
            )

            // Calm dual-lane pixel bridge: top cyan command dots, bottom brand-color token dots
            let cell: CGFloat = 2.0
            let tokenColor = palette.first ?? IslandTheme.prismCobalt
            let midX = (appX + squadAnchorX) * 0.5
            for i in -1...1 {
                let x = snap(midX + CGFloat(i) * 7, step: cell)
                if !isHiddenByNotch(x: x) {
                    let topRect = CGRect(x: x, y: snap(midY - 4, step: cell), width: 2.2, height: 2.2)
                    context.fill(Path(topRect), with: .color(Color(hex: 0x6BB0FF).opacity(0.72)))
                    let botRect = CGRect(x: x, y: snap(midY + 2, step: cell), width: 2.2, height: 2.2)
                    context.fill(Path(botRect), with: .color(tokenColor.opacity(0.80)))
                }
            }

            for slot in slots {
                let sprite = sprites[slot.index % sprites.count]
                drawAgentSprite(
                    context: &context,
                    sprite: sprite,
                    centerX: slot.x,
                    centerY: slot.y,
                    size: slot.size,
                    kick: 0,
                    squash: 0,
                    flash: 0,
                    missing: []
                )
            }
        }
    }

    private func drawArena(
        context: inout GraphicsContext,
        size: CGSize,
        appX: CGFloat,
        appSize: CGFloat,
        slots: [IslandStrikeSimulation.AgentSlot],
        sprites: [IslandPixelSprite],
        palette: [Color]
    ) {
        let midY = size.height * 0.5
        let cell: CGFloat = 2.0
        let appHalf = appSize * 0.5
        let squadLeftEdge = slots.map { $0.x - $0.half }.min() ?? (size.width - 24)

        // Micro screen-shake on full-charge overdrive burst
        let shakeAmp = CGFloat(sim.arenaShake * sim.arenaShake) * 1.4
        let frameIdx = floor(sim.elapsed * 60.0)
        let shakeX: CGFloat = shakeAmp > 0.08 ? CGFloat(hashNoise(frameIdx, 1) - 0.5) * 2 * shakeAmp : 0
        let shakeY: CGFloat = shakeAmp > 0.08 ? CGFloat(hashNoise(frameIdx, 2) - 0.5) * 2 * shakeAmp : 0

        context.translateBy(x: shakeX, y: shakeY)

        // 1. Subtle dual-lane velocity speed-lines in the runway channel
        let runwayStart = appX + appHalf + 4
        let runwayEnd = max(runwayStart + 2, squadLeftEdge - 4)
        let runwaySpan = max(1, runwayEnd - runwayStart)
        for line in sim.speedLines {
            let lx = runwayStart + line.x * runwaySpan
            let ly = snap(line.y * size.height, step: cell)
            if isHiddenByNotch(x: lx) { continue }
            let clippedX = max(runwayStart, lx)
            let clippedEnd = min(runwayEnd, lx + line.length)
            if clippedEnd > clippedX {
                let rect = CGRect(x: clippedX, y: ly, width: clippedEnd - clippedX, height: 1.0)
                let tint = line.dir > 0 ? Color(hex: 0x8CC4FF) : Color.white
                context.fill(Path(rect), with: .color(tint.opacity(line.alpha)))
            }
        }

        // 2. Subtle high-speed dashed energy beam along the bottom Token return lane when streaming fast
        if normalizedIntensity > 0.60 {
            let beamAlpha = (normalizedIntensity - 0.60) / 0.40 * 0.22
            let phase = Int(floor(sim.elapsed * 28.0))
            let beamColor = palette.first ?? IslandTheme.prismCobalt
            var gx = snap(runwayStart + 2, step: cell)
            var stepIndex = 0
            while gx < runwayEnd - 2 {
                if !isHiddenByNotch(x: gx) && (((stepIndex + phase) % 5 + 5) % 5) < 2 {
                    let rect = CGRect(x: gx, y: snap(midY + 3, step: cell), width: 1.7, height: 1.7)
                    context.fill(Path(rect), with: .color(beamColor.opacity(beamAlpha)))
                }
                gx += cell
                stepIndex += 1
            }
        }

        // 3. Curved pixel shockwaves blasting rightward off the App icon on full charge
        for wave in sim.shockwaves {
            let p = CGFloat(wave.age / wave.duration)
            let fade = Double(1.0 - p) * 0.92
            let arcHalfH = appHalf * 0.85 + p * 8.5
            let arcDepth = arcHalfH * 0.42
            let frontX = appX + wave.dir * (appHalf + 1.5 + p * 18.0)

            var dy = -arcHalfH
            while dy <= arcHalfH {
                let u = dy / max(1, arcHalfH)
                let wx = snap(frontX - wave.dir * arcDepth * u * u, step: cell)
                let wy = snap(midY + dy, step: cell)
                if !isHiddenByNotch(x: wx) && wx > 0 && wx < size.width - 2 && wy > 1 && wy < size.height - 2 {
                    let thickness = abs(u) < 0.55 ? 2 : 1
                    for layer in 0..<thickness {
                        let px = wx - wave.dir * CGFloat(layer) * cell
                        let col = layer == 0 ? wave.color : wave.accent
                        context.fill(
                            Path(CGRect(x: px, y: wy, width: 1.75, height: 1.75)),
                            with: .color(col.opacity(fade * (layer == 0 ? 1.0 : 0.65)))
                        )
                    }
                }
                dy += cell
            }
        }

        // 4. Placeholder pixelated App icon (left) — fires top command pulses & absorbs bottom Token charge
        let chargeTremble = CGFloat(sim.appCharge * 0.85 + sim.appSquash * 0.55)
        let jitterX = chargeTremble > 0.16 ? CGFloat(hashNoise(frameIdx, 5) - 0.5) * 1.8 * chargeTremble : 0
        let jitterY = chargeTremble > 0.16 ? CGFloat(hashNoise(frameIdx, 9) - 0.5) * 1.3 * chargeTremble : 0
        drawPlaceholderAppIcon(
            context: &context,
            centerX: appX,
            centerY: midY,
            size: appSize,
            kick: sim.appKick,
            squash: sim.appSquash,
            flash: sim.appFlash,
            charge: sim.appCharge,
            jitterX: jitterX,
            jitterY: jitterY,
            chargeColors: sim.chargeHistory.isEmpty ? palette : sim.chargeHistory
        )

        // 5. Flying grid-snapped duplex pixel comets (top: command ->, bottom: <- token)
        for shot in sim.shots {
            let dir: CGFloat = shot.vx >= 0 ? 1 : -1
            let slope = shot.vy / max(1, abs(shot.vx))
            for seg in 0..<shot.tailLength {
                let sx = snap(shot.x - dir * CGFloat(seg) * cell, step: cell)
                let sy = snap(shot.y - slope * CGFloat(seg) * cell, step: cell)
                guard !isHiddenByNotch(x: sx) else { continue }
                let a = max(0.18, 1.0 - Double(seg) / Double(shot.tailLength + 1) * 0.78)
                let side: CGFloat = shot.lane == .command ? 1.65 : 1.80
                let block = CGRect(x: sx, y: sy, width: side, height: side)
                context.fill(Path(block), with: .color(shot.color.opacity(a)))
                if shot.thick && seg < 2 {
                    let block2 = CGRect(x: sx, y: sy + cell, width: side, height: side)
                    context.fill(Path(block2), with: .color(shot.color.opacity(a * 0.72)))
                }
            }
        }

        // 6. Active running Agent pixel sprite squad (right: 1 centered, 2-3 staggered)
        for slot in slots {
            let sprite = sprites[slot.index % sprites.count]
            let missingSet = Set(
                sim.missingPixels
                    .filter { $0.agentIndex == slot.index }
                    .map(\.cellIndex)
            )
            let kick = slot.index < sim.agentKick.count ? sim.agentKick[slot.index] : 0
            let squash = slot.index < sim.agentSquash.count ? sim.agentSquash[slot.index] : 0
            let flash = slot.index < sim.agentFlash.count ? sim.agentFlash[slot.index] : 0
            drawAgentSprite(
                context: &context,
                sprite: sprite,
                centerX: slot.x,
                centerY: slot.y,
                size: slot.size,
                kick: kick,
                squash: squash,
                flash: flash,
                missing: missingSet
            )
        }

        // 7. Rebounding pixel sparks on top
        for spark in sim.sparks {
            let ratio = spark.age / spark.life
            let alpha = max(0, 1.0 - ratio * ratio)
            let px = snap(spark.x, step: cell)
            let py = snap(spark.y, step: cell)
            guard !isHiddenByNotch(x: px), px > 0, px < size.width - 1, py > 0, py < size.height - 1 else { continue }
            context.fill(
                Path(CGRect(x: px, y: py, width: spark.size - 0.25, height: spark.size - 0.25)),
                with: .color(spark.color.opacity(alpha))
            )
        }
    }

    private func drawAgentSprite(
        context: inout GraphicsContext,
        sprite: IslandPixelSprite,
        centerX: CGFloat,
        centerY: CGFloat,
        size: CGFloat,
        kick: Double,
        squash: Double,
        flash: Double,
        missing: Set<Int>
    ) {
        let n = CGFloat(sprite.gridSize)
        let step = size / n
        let gap: CGFloat = step >= 1.6 ? 0.24 : 0.12
        // Command hits from left & return bursts both recoil the right-side Agent subtly rightward
        let impact = max(squash, kick * 0.75)
        let sx = CGFloat(1.0 - 0.13 * impact)
        let sy = CGFloat(1.0 + 0.13 * impact)
        let recoilX = CGFloat(2.0 * impact)

        var localCtx = context
        localCtx.translateBy(x: centerX + recoilX, y: centerY)
        localCtx.scaleBy(x: sx, y: sy)

        let origin = -size * 0.5
        for (idx, cell) in sprite.cells.enumerated() {
            let alpha: Double = missing.contains(idx) ? 0.22 : 1.0
            let rect = CGRect(
                x: origin + CGFloat(cell.gx) * step,
                y: origin + CGFloat(cell.gy) * step,
                width: max(0.95, step - gap),
                height: max(0.95, step - gap)
            )
            localCtx.fill(Path(rect), with: .color(cell.color.opacity(alpha)))
            if flash > 0.04 {
                localCtx.fill(Path(rect), with: .color(Color.white.opacity(0.62 * flash)))
            }
        }
    }

    private func drawPlaceholderAppIcon(
        context: inout GraphicsContext,
        centerX: CGFloat,
        centerY: CGFloat,
        size: CGFloat,
        kick: Double,
        squash: Double,
        flash: Double,
        charge: Double,
        jitterX: CGFloat,
        jitterY: CGFloat,
        chargeColors: [Color]
    ) {
        let sprite = IslandPixelSpriteCache.appSprite
        let n = sprite.gridSize
        let step = size / CGFloat(n)
        let gap: CGFloat = step >= 1.6 ? 0.22 : 0.12

        // Token hits from right & command recoil both push/squash the left-side App icon slightly left
        let compress = max(squash, kick * 0.45)
        let scaleX = CGFloat(1.0 - 0.14 * compress)
        let scaleY = CGFloat(1.0 + 0.14 * compress)
        let knockX = CGFloat(-2.3 * squash - 1.2 * kick)

        var localCtx = context
        localCtx.translateBy(x: centerX + knockX + jitterX, y: centerY + jitterY)
        localCtx.scaleBy(x: scaleX, y: scaleY)

        let origin = -size * 0.5
        // Charge fills the tile from the bottom row up: its lit dots take the colors of the tokens
        // that came back, and the dark tile between them glows faintly.
        let chargedFrom = Double(n - 1) - max(0, min(1, charge)) * Double(n - 2)
        for cell in sprite.cells {
            let rect = CGRect(
                x: origin + CGFloat(cell.gx) * step,
                y: origin + CGFloat(cell.gy) * step,
                width: max(0.9, step - gap),
                height: max(0.9, step - gap)
            )
            let charged = Double(cell.gy) >= chargedFrom && cell.gy > 0 && cell.gy < n - 1
            let rowColor = chargeColors.isEmpty
                ? IslandTheme.prismCobalt
                : chargeColors[(n - 1 - cell.gy) % chargeColors.count]
            localCtx.fill(Path(rect), with: .color(cell.color))
            if charged {
                let lit = cell.luminance > 0.4
                localCtx.fill(Path(rect), with: .color(rowColor.opacity(lit ? 0.78 : 0.26)))
            }
            if flash > 0.02 {
                localCtx.fill(Path(rect), with: .color(Color.white.opacity(0.6 * flash)))
            }
        }
    }

    private func isHiddenByNotch(x: CGFloat) -> Bool {
        guard notchGapWidth > 0 else { return false }
        return x > leftWingWidth - 2 && x < leftWingWidth + notchGapWidth + 2
    }

    private func snap(_ value: CGFloat, step: CGFloat) -> CGFloat {
        (value / step).rounded() * step
    }

    private func hashNoise(_ a: Double, _ b: Double) -> Double {
        let v = sin(a * 127.1 + b * 311.7) * 43758.5453
        return v - floor(v)
    }
}
