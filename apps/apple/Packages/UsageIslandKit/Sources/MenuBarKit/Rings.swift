// Portions of this file are adapted from Cindy (https://github.com/makecindy/cindy),
// Copyright 2026 XD Inc., licensed under the Apache License 2.0 (LICENSES/Apache-2.0.txt).
// Modified for Sarto.

import SwiftUI

// Segmented equal-radius progress ring of the detail page: one full ring for a single window,
// or equal-radius arcs separated by crisp gaps for 2–4 windows so the center always stays airy.

public struct RingArc: Shape {
  public var progress: Double
  let lineWidth: CGFloat

  public init(progress: Double, lineWidth: CGFloat) {
    self.progress = progress
    self.lineWidth = lineWidth
  }

  public var animatableData: Double {
    get { progress }
    set { progress = newValue }
  }

  /// The visible arc including both round caps spans exactly 0...progress of the circle. A full
  /// ring uses butt caps so two round caps never meet; zero draws nothing.
  public func path(in rect: CGRect) -> Path {
    let radius = min(rect.width, rect.height) / 2 - lineWidth / 2
    let center = CGPoint(x: rect.midX, y: rect.midY)
    guard progress > 0.0005, radius > 0 else { return Path() }
    var arc = Path()
    if progress >= 0.9995 {
      arc.addArc(center: center, radius: radius, startAngle: .degrees(-90), endAngle: .degrees(270), clockwise: false)
      return arc.strokedPath(StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
    }
    let cap = Double(lineWidth / 2 / radius)
    let start = -Double.pi / 2 + cap
    let end = max(start + 0.0001, -Double.pi / 2 + 2 * Double.pi * progress - cap)
    arc.addArc(center: center, radius: radius, startAngle: .radians(start), endAngle: .radians(end), clockwise: false)
    return arc.strokedPath(StrokeStyle(lineWidth: lineWidth, lineCap: .round))
  }
}

/// One arc slot along the outer circle, starting at `startDegrees` (0 = 12 o'clock, clockwise)
/// and spanning `progress` (0...1) of `spanDegrees`. Round caps stay strictly inside the slot.
public struct SegmentedArc: Shape {
  public var progress: Double
  let startDegrees: Double
  let spanDegrees: Double
  let lineWidth: CGFloat

  public init(progress: Double, startDegrees: Double, spanDegrees: Double, lineWidth: CGFloat) {
    self.progress = progress
    self.startDegrees = startDegrees
    self.spanDegrees = spanDegrees
    self.lineWidth = lineWidth
  }

  public var animatableData: Double {
    get { progress }
    set { progress = newValue }
  }

  public func path(in rect: CGRect) -> Path {
    let radius = min(rect.width, rect.height) / 2 - lineWidth / 2
    let center = CGPoint(x: rect.midX, y: rect.midY)
    guard progress > 0.0005, radius > 0, spanDegrees > 0 else { return Path() }
    let cap = Double(lineWidth / 2 / radius)
    let slotStart = (startDegrees - 90) * .pi / 180 + cap
    let slotSpan = max(0, spanDegrees * .pi / 180 - 2 * cap)
    let end = slotStart + slotSpan * min(1, max(0, progress))
    var arc = Path()
    arc.addArc(center: center, radius: radius, startAngle: .radians(slotStart), endAngle: .radians(max(slotStart + 0.0001, end)), clockwise: false)
    return arc.strokedPath(StrokeStyle(lineWidth: lineWidth, lineCap: .round))
  }
}

public struct Ring: Equatable {
  public let fraction: Double
  public let color: Color
  public init(fraction: Double, color: Color) {
    self.fraction = fraction
    self.color = color
  }
}

/// Rings fill from zero each time `fillToken` changes, staggered 60ms apart.
/// With 1 ring, draws a full circle; with 2+, divides one circle into equal-radius arc segments.
public struct RingsView: View {
  let rings: [Ring]
  let fillToken: Int
  var size: CGFloat
  var highlighted: Int?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var shown = true

  public init(rings: [Ring], fillToken: Int, size: CGFloat = 196, highlighted: Int? = nil) {
    self.rings = rings
    self.fillToken = fillToken
    self.size = size
    self.highlighted = highlighted
  }

  public var body: some View {
    let lineWidth: CGFloat = (size * (rings.count > 1 ? 0.064 : 0.068)).rounded()
    ZStack {
      if rings.count <= 1 {
        let ring = rings.first ?? Ring(fraction: 0, color: Palette.fill)
        Circle().strokeBorder(Palette.ink5, lineWidth: lineWidth)
        RingArc(progress: shown ? max(0, min(1, ring.fraction)) : 0, lineWidth: lineWidth)
          .fill(ring.color)
          .animation(Motion.fill, value: shown)
          .animation(Motion.fill, value: ring.fraction)
      } else {
        let gapDegrees: Double = rings.count == 2 ? 12 : (rings.count == 3 ? 11 : 10)
        let spanDegrees = (360.0 - gapDegrees * Double(rings.count)) / Double(rings.count)
        let startOffset = gapDegrees / 2
        ForEach(Array(rings.enumerated()), id: \.offset) { index, ring in
          let start = startOffset + Double(index) * (spanDegrees + gapDegrees)
          let dimmed = highlighted != nil && highlighted != index
          ZStack {
            SegmentedArc(progress: 1, startDegrees: start, spanDegrees: spanDegrees, lineWidth: lineWidth)
              .fill(Palette.ink5)
            SegmentedArc(progress: shown ? max(0, min(1, ring.fraction)) : 0,
                         startDegrees: start, spanDegrees: spanDegrees, lineWidth: lineWidth)
              .fill(ring.color)
              .animation(Motion.fill.delay(Double(index) * 0.06), value: shown)
              .animation(Motion.fill, value: ring.fraction)
          }
          .opacity(dimmed ? 0.28 : 1)
          .animation(Motion.quick, value: highlighted)
        }
      }
    }
    .padding(3)
    .frame(width: size, height: size)
    .onAppear { replay() }
    .onChange(of: fillToken) { replay() }
  }

  private func replay() {
    guard !reduceMotion else { shown = true; return }
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) { shown = false }
    DispatchQueue.main.async { shown = true }
  }
}
