// Portions of this file are adapted from Cindy (https://github.com/makecindy/cindy),
// Copyright 2026 XD Inc., licensed under the Apache License 2.0 (LICENSES/Apache-2.0.txt).
// Modified for Sarto.

import AppKit
import SwiftUI

// Extracted from Cindy's apps/desktop/native/menubar/macos-menubar-helper.swift.

/// A glass tube whose liquid level shows how much is left. Opening the panel (`fillToken`)
/// pours it in from empty with a randomized slosh; an `active` source ripples; hovering nudges.
public struct TubeView: View {
  let fill: Double?
  let level: String
  let reserve: Bool
  let emphasized: Bool
  /// Something is drawing on this source right now: the liquid surface ripples gently.
  var active = false
  /// The pointer just came onto the tube: the liquid gives a small nudge, then settles.
  var hovered = false
  let index: Int
  let fillToken: Int
  var height: CGFloat = 104
  /// Liquid color when the level is fine (defaults to the neutral ink liquid).
  var tint: Color? = nil

  public init(fill: Double?, level: String = "ok", reserve: Bool = false, emphasized: Bool = false, active: Bool = false,
              hovered: Bool = false, index: Int, fillToken: Int, height: CGFloat = 104, tint: Color? = nil) {
    self.fill = fill
    self.level = level
    self.reserve = reserve
    self.emphasized = emphasized
    self.active = active
    self.hovered = hovered
    self.index = index
    self.fillToken = fillToken
    self.height = height
    self.tint = tint
  }
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var shown = true
  /// Set while the opening slosh plays; the wave clock runs for every tube meanwhile.
  @State private var openedAt: Date?
  // The standing ripple of a source in use eases between levels on the wave clock itself
  // (not through SwiftUI's animator, which a per-frame clock would fight and make pop).
  @State private var rippleFrom: CGFloat = 0
  @State private var rippleGoal: CGFloat = 0
  @State private var rippleChangedAt: Date = .distantPast
  /// Keeps the clock alive while a ripple change eases in or out.
  @State private var rippleEasing = false
  /// Drawn anew every time the panel opens, so no two openings slosh the same way.
  @State private var slosh = SloshProfile.random()
  @State private var nudgedAt: Date?
  @State private var nudgeDirection: CGFloat = 1

  private static let inset: CGFloat = 3
  private static let outerRadius: CGFloat = 13
  /// Peak height of the ripple; small enough that the level still reads exactly.
  private static let rippleAmplitude: CGFloat = 1.5

  // Opening slosh. While the liquid rushes up it stays nearly flat; when it stops, inertia
  // tips the surface from side to side like a damped pendulum (first mode, one side up while
  // the other is down) with a faster, smaller second mode on top, and both decay to still.
  /// Seconds after a tube's own start at which the rising liquid has all but arrived.
  private static let arrival: Double = 0.5
  /// Edge height of the first tilt, in points, for a full tube (less when the tube is lower).
  private static let sloshTilt: CGFloat = 5.0
  /// While rising the surface only shivers this much…
  private static let riseShiver: CGFloat = 0.3
  /// …and rocks a little, quicker and far smaller than the slosh after it stops.
  private static let riseRock: CGFloat = 1.1
  private static let riseRockPeriod: Double = 0.34
  private static let sloshDuration: Double = 4.6
  /// Hover nudge: a small, short sway, a third of the opening slosh.
  private static let nudgeTilt: CGFloat = 1.7
  private static let nudgePeriod: Double = 0.72
  private static let nudgeDecay: Double = 0.5
  private static let nudgeDuration: Double = 2.2

  public var body: some View {
    let wellHeight = height - Self.inset * 2
    let fraction = max(0, min(1, fill ?? 0))
    let liquid = fraction > 0 ? max(3, fraction * wellHeight) : 0
    let warn = Palette.level(level)
    ZStack {
      if fill == nil {
        RoundedRectangle(cornerRadius: Self.outerRadius, style: .circular)
          .strokeBorder(Palette.ink4, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
      } else {
        RoundedRectangle(cornerRadius: Self.outerRadius, style: .circular)
          .fill(LinearGradient(colors: [Palette.wellTop, Palette.wellBottom], startPoint: .top, endPoint: .bottom)
            .shadow(.inner(color: Palette.wellShade, radius: 1.5, y: 1)))
        if reserve {
          HatchPattern()
            .stroke(Palette.ink4, lineWidth: 2)
            .clipShape(RoundedRectangle(cornerRadius: Self.outerRadius - Self.inset, style: .circular))
            .padding(Self.inset)
        }
        // Liquid lives in a well inset 3pt on every side; the well's rounded bottom shapes low
        // levels, so the liquid never touches the tube wall.
        VStack(spacing: 0) {
          Spacer(minLength: 0)
          surface(warn: warn)
            .frame(height: liquid)
            .scaleEffect(x: 1, y: shown ? 1 : 0.001, anchor: .bottom)
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.outerRadius - Self.inset, style: .circular))
        .padding(Self.inset)
        .animation(Motion.liquid, value: liquid)
        RoundedRectangle(cornerRadius: Self.outerRadius, style: .circular)
          // The recommended tube: a 1pt secondary-gray outline, quiet enough not to read as a
          // selection; the headline names the source it marks.
          .strokeBorder(emphasized ? Palette.ink2 : Palette.ink4, lineWidth: emphasized ? 1 : 0.5)
      }
    }
    .background(alignment: .bottom) {
      if warn != nil && fill != nil {
        Ellipse()
          .fill(RadialGradient(colors: [(warn ?? Palette.warn).opacity(0.5), .clear], center: .center, startRadius: 0, endRadius: 18))
          .frame(width: 34, height: 14)
          .blur(radius: 4)
          .offset(y: 7)
          .opacity(0.45)
          .allowsHitTesting(false)
      }
    }
    .frame(maxWidth: 40)
    .frame(height: height)
    .onChange(of: fillToken) { replay() }
    .onChange(of: active) { updateRipple() }
    .onChange(of: hovered) { _, isHovered in if isHovered { nudge() } }
    .onAppear {
      replay()
      updateRipple()
    }
  }

  /// The standing ripple at `now`, easing from where it was toward its goal.
  private func rippleLevel(at now: Date) -> CGFloat {
    let duration = rippleGoal > rippleFrom ? 0.8 : 1.4
    let p = max(0, min(1, now.timeIntervalSince(rippleChangedAt) / duration))
    let eased = CGFloat(p * p * (3 - 2 * p))
    return rippleFrom + (rippleGoal - rippleFrom) * eased
  }

  /// Surface state at `now`, including a hover nudge on top of whatever else is moving.
  private func surfaceState(at now: Date, fraction: Double) -> (ripple: CGFloat, tilt: CGFloat, second: CGFloat) {
    var state = baseSurfaceState(at: now, fraction: fraction)
    if let nudgedAt {
      let u = now.timeIntervalSince(nudgedAt)
      if u >= 0, u < Self.nudgeDuration {
        // Fuller tubes sway a little more; even a low one visibly answers the pointer.
        let m = CGFloat(0.35 + 0.65 * fraction)
        state.tilt += nudgeDirection * Self.nudgeTilt * m
          * CGFloat(exp(-u / Self.nudgeDecay) * sin(2 * .pi * u / Self.nudgePeriod))
        state.second -= nudgeDirection * Self.nudgeTilt * 0.3 * m
          * CGFloat(exp(-u / (Self.nudgeDecay * 0.7)) * sin(2 * .pi * u / (Self.nudgePeriod * 0.48)))
      }
    }
    return state
  }

  /// Surface state at `now`: wave amplitude and the side-to-side tilt, both in points.
  private func baseSurfaceState(at now: Date, fraction: Double) -> (ripple: CGFloat, tilt: CGFloat, second: CGFloat) {
    let standing = rippleLevel(at: now)
    guard let openedAt else { return (standing, 0, 0) }
    let t = now.timeIntervalSince(openedAt) - Double(index) * 0.06
    let arrival = Self.arrival + slosh.arrivalShift
    // How far the liquid climbs sets how hard it moves: a nearly full tube swings widely, a
    // low one barely does (momentum grows faster than the level).
    let momentum = CGFloat(max(0.04, pow(fraction, 1.5)))
    if t < arrival {
      // Rising: a small, quick rock that swells mid-climb and is back to level on arrival
      // (the envelope is zero at both ends), handing over smoothly to the slosh.
      let p = max(0, t) / arrival
      let rock = Self.riseRock * CGFloat(0.5 + 0.5 * fraction) * CGFloat(sin(.pi * p))
        * CGFloat(sin(2 * .pi * max(0, t) / Self.riseRockPeriod)) * slosh.direction
      return (max(standing, Self.riseShiver), rock, 0)
    }
    let s = t - arrival
    // Both modes start from zero (sin), so the surface leans away from flat smoothly the
    // moment the liquid stops rather than snapping to a lean.
    let tilt = slosh.direction * slosh.strength * Self.sloshTilt * momentum
      * CGFloat(exp(-s / slosh.decay) * sin(2 * .pi * s / slosh.period))
    let second = -slosh.direction * slosh.secondRatio * Self.sloshTilt * momentum
      * CGFloat(exp(-s / (slosh.decay * 0.7)) * sin(2 * .pi * s / (slosh.period * slosh.secondPeriodRatio)))
    let shiver = Self.riseShiver * CGFloat(exp(-s / 0.6))
    return (max(standing, shiver), tilt, second)
  }

  @ViewBuilder
  private func surface(warn: Color?) -> some View {
    let color = warn ?? tint ?? Palette.liquid
    // The clock only runs for a source in use; when it stops, the amplitude eases to zero and
    // the frozen phase settles into a flat, still surface.
    TimelineView(.animation(minimumInterval: 1 / 30, paused: !(active || openedAt != nil || rippleEasing || nudgedAt != nil) || reduceMotion)) { context in
      let state = surfaceState(at: context.date, fraction: max(0, min(1, fill ?? 0)))
      LiquidSurface(
        phase: context.date.timeIntervalSinceReferenceDate * 2 * .pi / 3.6 + Double(index) * 1.3,
        amplitude: state.ripple,
        tilt: state.tilt,
        second: state.second
      )
      .fill(color)
    }
  }

  private var rippleTarget: CGFloat { active && !reduceMotion ? Self.rippleAmplitude : 0 }

  private func updateRipple() {
    // While the opening slosh plays the standing ripple waits; the slosh's end calls this.
    guard openedAt == nil, rippleTarget != rippleGoal else { return }
    let now = Date()
    let target = rippleTarget
    rippleFrom = rippleLevel(at: now)
    rippleGoal = target
    rippleChangedAt = now
    rippleEasing = true
    let duration = target > rippleFrom ? 0.8 : 1.4
    DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.1) {
      if rippleChangedAt == now { rippleEasing = false }
    }
  }

  private func nudge() {
    guard !reduceMotion, fill != nil else { return }
    let now = Date()
    // Sweeping the pointer across the row should not restart a nudge that just began.
    if let nudgedAt, now.timeIntervalSince(nudgedAt) < 0.35 { return }
    nudgeDirection = Bool.random() ? 1 : -1
    nudgedAt = now
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.nudgeDuration + 0.05) {
      if nudgedAt == now { nudgedAt = nil }
    }
  }

  private func replay() {
    guard !reduceMotion else {
      shown = true
      openedAt = nil
      rippleFrom = 0
      rippleGoal = 0
      return
    }
    let delay = Double(index) * 0.06
    let started = Date()
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      shown = false
      openedAt = started
      slosh = SloshProfile.random()
      // The standing ripple restarts from still once the slosh is over.
      rippleFrom = 0
      rippleGoal = 0
    }
    DispatchQueue.main.async {
      withAnimation(Motion.liquid.delay(delay)) { shown = true }
    }
    // The slosh is over once the tilt has decayed; an active source then keeps its ripple.
    DispatchQueue.main.asyncAfter(deadline: .now() + delay + Self.arrival + 0.1 + Self.sloshDuration) {
      guard openedAt == started else { return }
      openedAt = nil
      updateRipple()
    }
  }
}

/// One opening's slosh: which way the surface first leans, how strongly, how fast it swings and
/// how quickly it dies down. Redrawn on every opening so the tubes never repeat themselves.
struct SloshProfile {
  /// +1 leans left-up first, -1 right-up first.
  var direction: CGFloat
  /// Scales the first tilt (0.8...1.15).
  var strength: CGFloat
  var period: Double
  var decay: Double
  var secondRatio: CGFloat
  var secondPeriodRatio: Double
  /// Moves the instant the liquid stops, so the tubes do not all lurch at once.
  var arrivalShift: Double

  static func random() -> SloshProfile {
    SloshProfile(
      direction: Bool.random() ? 1 : -1,
      strength: CGFloat.random(in: 0.8...1.15),
      period: Double.random(in: 0.82...1.12),
      decay: Double.random(in: 1.0...1.5),
      secondRatio: CGFloat.random(in: 0.18...0.4),
      secondPeriodRatio: Double.random(in: 0.4...0.55),
      arrivalShift: Double.random(in: -0.06...0.08)
    )
  }
}

/// Liquid with a gently waving top edge. The wave stays inside the frame (it dips at most
/// twice the amplitude below the top), and zero amplitude is a flat surface.
struct LiquidSurface: Shape {
  var phase: Double
  var amplitude: CGFloat
  /// First slosh mode: the surface leans, left edge up while the right is down (and back).
  var tilt: CGFloat = 0
  /// Second slosh mode: both edges rise while the middle sinks.
  var second: CGFloat = 0

  var animatableData: CGFloat {
    get { amplitude }
    set { amplitude = newValue }
  }

  func path(in rect: CGRect) -> Path {
    var path = Path()
    guard rect.width > 0, rect.height > 0 else { return path }
    let amp = min(amplitude, rect.height / 4)
    let wavelength = Double(rect.width) * 1.35
    func y(_ x: CGFloat) -> CGFloat {
      let k = 2 * Double.pi / wavelength
      let wave = 0.65 * sin(k * Double(x) + phase) + 0.35 * sin(1.7 * k * Double(x) - 1.3 * phase)
      // Both slosh modes average to zero across the width, so the liquid volume is unchanged;
      // the surface may rise above the nominal level (the well clips it).
      let u = Double(x / rect.width)
      let lean = Double(tilt) * (1 - 2 * u)
      let mode2 = Double(second) * cos(2 * Double.pi * u)
      return rect.minY + amp * CGFloat(1 + wave) - CGFloat(lean + mode2)
    }
    // The surface meets the walls in a soft corner rather than a hard angle (owner request,
    // 2026-11-01), the same 4pt as the iPhone widgets; a very low level gets a smaller one.
    let corner = min(4, rect.height / 2, rect.width / 4)
    path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX, y: y(0) + corner))
    path.addQuadCurve(to: CGPoint(x: rect.minX + corner, y: y(corner)), control: CGPoint(x: rect.minX, y: y(0)))
    let steps = 16
    for step in 1..<steps {
      let x = corner + (rect.width - 2 * corner) * CGFloat(step) / CGFloat(steps)
      path.addLine(to: CGPoint(x: rect.minX + x, y: y(x)))
    }
    path.addLine(to: CGPoint(x: rect.maxX - corner, y: y(rect.width - corner)))
    path.addQuadCurve(to: CGPoint(x: rect.maxX, y: y(rect.width) + corner), control: CGPoint(x: rect.maxX, y: y(rect.width)))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    path.closeSubpath()
    return path
  }
}

struct HatchPattern: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    let step: CGFloat = 7
    var x = -rect.height
    while x < rect.width {
      path.move(to: CGPoint(x: x, y: rect.maxY))
      path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
      x += step
    }
    return path
  }
}
