import SwiftUI

public enum SartoBrand {
    public static let name = "Sarto"
    public static let englishSlogan = "Sarto — The Native Agentic Development Environment."
    public static let chineseSlogan = "原生多引擎 ADE，连接不同 Agent 与你的每一台电脑。"
}

/// Sarto's "Many to One" mark on its 1024 master canvas: separate tiles that grow along the
/// diagonal until they join into one solid form.
public enum SartoMarkGeometry {
    public static let masterSize: Double = 1024
    static let lo: Double = 284
    static let hi: Double = 740
    static let cornerRadius: Double = 120

    /// Fewer, larger tiles at small sizes so the mark still reads at 16 pt.
    public enum Detail: Sendable {
        case full, mid, small

        var grid: (n: Int, s0: Double, power: Double, solidFrom: Double) {
            switch self {
            case .full: return (8, 0.26, 1.6, 0.78)
            case .mid: return (6, 0.30, 1.5, 0.76)
            case .small: return (5, 0.36, 1.3, 0.70)
            }
        }
    }

    public enum Part: Sendable { case tiles, solid }

    public static func detail(forBoxWidth width: CGFloat) -> Detail {
        width < 14 ? .small : (width < 40 ? .mid : .full)
    }

    /// The mark's separate tiles or its solid part, with the master box `lo...hi` filling `box`.
    public static func path(in box: CGRect, detail: Detail, part: Part) -> Path {
        let (n, s0, power, solidFrom) = detail.grid
        let k = box.width / CGFloat(hi - lo)
        let step = (hi - lo) / Double(n)
        func map(_ v: Double) -> CGFloat { CGFloat(v - lo) * k }
        var path = Path()
        for i in 0..<n {
            for j in 0..<n {
                let t = Double(i + j) / Double(2 * (n - 1))
                let u = pow(min(t / solidFrom, 1), power)
                if u >= 1 {
                    guard part == .solid else { continue }
                    let x = lo + Double(i) * step - 0.8
                    let y = lo + Double(j) * step - 0.8
                    path.addRect(CGRect(
                        x: box.minX + map(x), y: box.minY + map(y),
                        width: CGFloat(step + 1.6) * k, height: CGFloat(step + 1.6) * k
                    ))
                } else if part == .tiles {
                    let side = step * (s0 + (1 - s0) * u)
                    let x = lo + (Double(i) + 0.5) * step - side / 2
                    let y = lo + (Double(j) + 0.5) * step - side / 2
                    guard insideBox(x, y, x + side, y + side) else { continue }
                    let radius = CGFloat(side / 2 * pow(1 - u, 0.8)) * k
                    path.addRoundedRect(
                        in: CGRect(x: box.minX + map(x), y: box.minY + map(y), width: CGFloat(side) * k, height: CGFloat(side) * k),
                        cornerSize: CGSize(width: radius, height: radius)
                    )
                }
            }
        }
        let clip = Path(roundedRect: box, cornerRadius: CGFloat(cornerRadius) * k, style: .circular)
        return path.intersection(clip)
    }

    private static func insideBox(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Bool {
        func ok(_ px: Double, _ py: Double) -> Bool {
            let cx = min(max(px, lo + cornerRadius), hi - cornerRadius)
            let cy = min(max(py, lo + cornerRadius), hi - cornerRadius)
            return hypot(px - cx, py - cy) <= cornerRadius + 0.5
        }
        return ok(x0, y0) && ok(x1, y0) && ok(x0, y1) && ok(x1, y1)
    }
}

/// The Sarto mark without its tile, in Electric Cobalt or one colour (menu bar, templates).
public struct SartoSpectrumSymbol: View {
    public var size: CGFloat
    public var monochrome: Color?
    /// Fills the frame when drawn on its own; leaves room for a container's padding otherwise.
    public var tightCrop: Bool

    public init(size: CGFloat = 24, monochrome: Color? = nil, tightCrop: Bool = true) {
        self.size = size
        self.monochrome = monochrome
        self.tightCrop = tightCrop
    }

    public var body: some View {
        let boxSide = size * (tightCrop ? 0.86 : 0.49)
        let detail = SartoMarkGeometry.detail(forBoxWidth: boxSide)
        Canvas { context, canvas in
            let box = CGRect(
                x: (canvas.width - boxSide) / 2,
                y: (canvas.height - boxSide) / 2,
                width: boxSide,
                height: boxSide
            )
            let tiles = SartoMarkGeometry.path(in: box, detail: detail, part: .tiles)
            let solid = SartoMarkGeometry.path(in: box, detail: detail, part: .solid)
            if let mono = monochrome {
                context.fill(tiles, with: .color(mono.opacity(0.75)))
                context.fill(solid, with: .color(mono))
            } else {
                let shading = GraphicsContext.Shading.linearGradient(
                    Gradient(stops: [
                        .init(color: Color(hex: 0xFFFFFF), location: 0.0),
                        .init(color: Color(hex: 0xC4DAF7), location: 0.38),
                        .init(color: Color(hex: 0x5A9CF8), location: 0.64),
                        .init(color: Color(hex: 0x1D4ED8), location: 1.0),
                    ]),
                    startPoint: CGPoint(x: box.minX, y: box.minY),
                    endPoint: CGPoint(x: box.maxX, y: box.maxY)
                )
                context.fill(tiles, with: shading)
                context.fill(solid, with: shading)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The Sarto app icon as a UI emblem: the "Many to One" mark on its deep-space cobalt tile.
public struct SartoSpectrumEmblem: View {
    public var size: CGFloat
    public var active: Bool
    public var withChassis: Bool

    public init(size: CGFloat = 18, active: Bool = false, withChassis: Bool = true) {
        self.size = size
        self.active = active
        self.withChassis = withChassis
    }

    public var body: some View {
        if withChassis {
            let radius = size * 0.225
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: Color(hex: 0x14233C), location: 0.0),
                                .init(color: Color(hex: 0x0B1323), location: 0.52),
                                .init(color: Color(hex: 0x060A13), location: 1.0),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(hex: 0x3B82F6).opacity(active ? 0.42 : 0.26),
                                Color.clear,
                            ],
                            center: UnitPoint(x: 0.65, y: 0.62),
                            startRadius: 0,
                            endRadius: size * 0.72
                        )
                    )

                SartoSpectrumSymbol(size: size * 1.12, monochrome: nil, tightCrop: false)

                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color(hex: 0x608AC6).opacity(0.68),
                                Color(hex: 0x283E64).opacity(0.36),
                                Color(hex: 0x1B2A46).opacity(0.56),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: max(0.6, size * 0.032)
                    )
            }
            .frame(width: size, height: size)
            .shadow(
                color: active ? Color(hex: 0x3B82F6).opacity(0.48) : .clear,
                radius: max(3, size * 0.24)
            )
            .accessibilityHidden(true)
        } else {
            SartoSpectrumSymbol(size: size, monochrome: nil, tightCrop: true)
        }
    }
}
