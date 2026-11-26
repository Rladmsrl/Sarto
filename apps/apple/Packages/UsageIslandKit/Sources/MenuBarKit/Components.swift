// Portions of this file are adapted from Cindy (https://github.com/makecindy/cindy),
// Copyright 2026 XD Inc., licensed under the Apache License 2.0 (LICENSES/Apache-2.0.txt).
// Modified for Sarto.

import AppKit
import SwiftUI

// Small building blocks of Cindy's menu bar panel
// (apps/desktop/native/menubar/macos-menubar-helper.swift), made public.

public struct IconButton: View {
  let systemName: String
  let label: String
  var help: String?
  var rotation: Double
  let action: () -> Void
  @State private var hovering = false

  public init(systemName: String, label: String, help: String? = nil, rotation: Double = 0, action: @escaping () -> Void) {
    self.systemName = systemName
    self.label = label
    self.help = help
    self.rotation = rotation
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 12, weight: .medium))
        .rotationEffect(.degrees(rotation))
        .frame(width: 28, height: 28)
        .foregroundStyle(hovering ? Palette.ink : Palette.ink2)
        .background(Circle().fill(hovering ? Palette.ink5 : .clear))
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .onHover { hovering in withAnimation(Motion.quick) { self.hovering = hovering } }
    .help(help ?? label)
    .accessibilityLabel(label)
  }
}

/// Spins a full turn each time `spinToken` changes (the refresh button).
public struct SpinningIconButton: View {
  let systemName: String
  let label: String
  let spinToken: Int
  let action: () -> Void
  @State private var angle: Double = 0

  public init(systemName: String, label: String, spinToken: Int, action: @escaping () -> Void) {
    self.systemName = systemName
    self.label = label
    self.spinToken = spinToken
    self.action = action
  }

  public var body: some View {
    IconButton(systemName: systemName, label: label, rotation: angle, action: action)
      .onChange(of: spinToken) {
        withAnimation(.timingCurve(0.4, 0.1, 0.3, 1, duration: 0.9)) { angle += 360 }
      }
  }
}

/// The one solid control of the panel. With `brandMark`, the red ">" leads the title, slides in
/// when the panel opens, leans forward on hover and pushes on press.
public struct InkPillButton: View {
  let title: String
  var shortcut: String?
  var height: CGFloat
  var fullWidth: Bool
  var disabled: Bool
  var brandMark: Bool
  var replayToken: Int
  let action: () -> Void
  @State private var hovering = false

  public init(title: String, shortcut: String? = nil, height: CGFloat = 30, fullWidth: Bool = false, disabled: Bool = false,
              brandMark: Bool = false, replayToken: Int = 0, action: @escaping () -> Void) {
    self.title = title
    self.shortcut = shortcut
    self.height = height
    self.fullWidth = fullWidth
    self.disabled = disabled
    self.brandMark = brandMark
    self.replayToken = replayToken
    self.action = action
  }

  public var body: some View {
    Button(action: action) { Text(title) }
      .buttonStyle(InkPillStyle(title: title, shortcut: shortcut, height: height, fullWidth: fullWidth,
                                brandMark: brandMark, hovering: hovering, replayToken: replayToken))
      .disabled(disabled)
      .opacity(disabled ? 0.4 : 1)
      .onHover { hovering in withAnimation(Motion.quick) { self.hovering = hovering } }
  }
}

private struct InkPillStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let title: String
  let shortcut: String?
  let height: CGFloat
  let fullWidth: Bool
  let brandMark: Bool
  let hovering: Bool
  let replayToken: Int

  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 8) {
      if brandMark {
        BrandPromptMark(replayToken: replayToken)
          .offset(x: reduceMotion ? 0 : configuration.isPressed ? 4 : hovering ? 2 : 0)
          .scaleEffect(x: !reduceMotion && configuration.isPressed ? 0.8 : 1, anchor: .trailing)
          .animation(configuration.isPressed ? .easeOut(duration: 0.12) : .spring(response: 0.35, dampingFraction: 0.6), value: configuration.isPressed)
          .animation(.spring(response: 0.35, dampingFraction: 0.6), value: hovering)
          .padding(.trailing, -2)
      }
      Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
      if let shortcut {
        Text(shortcut).font(.system(size: 12, weight: .medium)).opacity(0.55)
      }
    }
    .padding(.leading, brandMark ? 12 : 14)
    .padding(.trailing, 14)
    .frame(height: height)
    .frame(maxWidth: fullWidth ? .infinity : nil)
    .foregroundStyle(Palette.onInk)
    .background(Capsule().fill(Palette.cta))
    .contentShape(Capsule())
    .scaleEffect(configuration.isPressed ? 0.97 : 1)
    .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

/// Sarto prompt mark inside the primary pill CTA, normalized to its box.
public struct BrandPrompt: Shape {
  public init() {}

  public func path(in rect: CGRect) -> Path {
    let points: [(CGFloat, CGFloat)] = [
      (0, 0), (1, 0.4354), (1, 0.5636), (0, 1), (0, 0.6551), (0.352, 0.4995), (0, 0.3442),
    ]
    var path = Path()
    for (index, point) in points.enumerated() {
      let p = CGPoint(x: rect.minX + point.0 * rect.width, y: rect.minY + point.1 * rect.height)
      if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    path.closeSubpath()
    return path
  }
}

struct BrandPromptMark: View {
  let replayToken: Int
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var shown = true

  var body: some View {
    BrandPrompt()
      .fill(Palette.brand)
      .frame(width: 7, height: 11)
      .opacity(shown ? 1 : 0)
      .offset(x: shown ? 0 : -5)
      .accessibilityHidden(true)
      .onAppear { replay() }
      .onChange(of: replayToken) { replay() }
  }

  private func replay() {
    guard !reduceMotion else { shown = true; return }
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) { shown = false }
    DispatchQueue.main.async {
      withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.7).delay(0.45)) { shown = true }
    }
  }
}

public struct PressScaleStyle: ButtonStyle {
  public init() {}
  public func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

/// Pressing squeezes a little, then springs back as the next page opens.
public struct CellPressStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  public init() {}
  public func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(!reduceMotion && configuration.isPressed ? 0.95 : 1)
      .animation(configuration.isPressed ? .easeOut(duration: 0.1) : .spring(response: 0.35, dampingFraction: 0.55), value: configuration.isPressed)
  }
}

public struct Tile<Content: View>: View {
  var radius: CGFloat
  let content: Content

  public init(radius: CGFloat = 14, @ViewBuilder content: () -> Content) {
    self.radius = radius
    self.content = content()
  }

  public var body: some View {
    content
      .background(RoundedRectangle(cornerRadius: radius, style: .circular).fill(Palette.tile))
      .overlay(RoundedRectangle(cornerRadius: radius, style: .circular).strokeBorder(Palette.line, lineWidth: 0.5))
  }
}

/// The panel's one hairline: 0.5pt in the soft `line` color.
public struct Hairline: View {
  public init() {}
  public var body: some View { Rectangle().fill(Palette.line).frame(height: 0.5) }
}

/// Fixed bar edge above or below a scroll area; shows only while content runs under it.
public struct EdgeLine: View {
  let visible: Bool
  public init(visible: Bool) { self.visible = visible }
  public var body: some View {
    Rectangle().fill(Palette.line).frame(height: 0.5).opacity(visible ? 1 : 0)
      .animation(Motion.quick, value: visible)
  }
}

private struct ScrollOffsetKey: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ContentHeightKey: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Scroll view that reports how far it is scrolled and how tall its content is.
public struct TrackedScroll<Content: View>: View {
  @Binding var offset: CGFloat
  @Binding var contentHeight: CGFloat
  let content: Content
  @State private var space = UUID().uuidString

  public init(offset: Binding<CGFloat>, contentHeight: Binding<CGFloat>, @ViewBuilder content: () -> Content) {
    _offset = offset
    _contentHeight = contentHeight
    self.content = content()
  }

  public var body: some View {
    GeometryReader { outer in
      ScrollView(.vertical, showsIndicators: false) {
        content
          .background(GeometryReader { inner in
            Color.clear
              .preference(key: ScrollOffsetKey.self, value: -inner.frame(in: .named(space)).minY)
              .preference(key: ContentHeightKey.self, value: inner.size.height)
          })
      }
      .coordinateSpace(name: space)
      .onPreferenceChange(ScrollOffsetKey.self) { offset = $0 }
      .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
      .frame(height: outer.size.height)
    }
  }
}

/// A page with a fixed header and footer around a body that scrolls only when the screen is
/// too short. Reports its natural height so the panel can size itself to it.
public struct PanelPage<Header: View, Content: View, Footer: View>: View {
  let onNaturalHeight: (CGFloat) -> Void
  let header: Header
  let content: Content
  let footer: Footer
  @State private var offset: CGFloat = 0
  @State private var contentHeight: CGFloat = 0
  @State private var headerHeight: CGFloat = 0
  @State private var footerHeight: CGFloat = 0
  @State private var viewportHeight: CGFloat = 0

  public init(onNaturalHeight: @escaping (CGFloat) -> Void,
              @ViewBuilder header: () -> Header,
              @ViewBuilder content: () -> Content,
              @ViewBuilder footer: () -> Footer) {
    self.onNaturalHeight = onNaturalHeight
    self.header = header()
    self.content = content()
    self.footer = footer()
  }

  public var body: some View {
    VStack(spacing: 0) {
      header.background(heightReader { headerHeight = $0 })
      EdgeLine(visible: offset > 2)
      TrackedScroll(offset: $offset, contentHeight: $contentHeight) { content }
        .frame(maxHeight: contentHeight > 0 ? contentHeight : nil)
        .background(heightReader { viewportHeight = $0 })
      EdgeLine(visible: offset + viewportHeight < contentHeight - 2)
      footer.background(heightReader { footerHeight = $0 })
    }
    .frame(maxHeight: .infinity, alignment: .top)
    .onChange(of: contentHeight) { report() }
    .onChange(of: headerHeight) { report() }
    .onChange(of: footerHeight) { report() }
    .onAppear { report() }
  }

  private func heightReader(_ set: @escaping (CGFloat) -> Void) -> some View {
    GeometryReader { g in
      Color.clear
        .onAppear { set(g.size.height) }
        .onChange(of: g.size.height) { _, h in set(h) }
    }
  }

  private func report() {
    guard contentHeight > 0 else { return }
    onNaturalHeight((headerHeight + contentHeight + footerHeight + 1).rounded(.up))
  }
}

public struct Headline: View {
  let primary: String
  let secondary: String?
  var alert: Bool
  var short: Bool

  public init(primary: String, secondary: String?, alert: Bool = false, short: Bool = false) {
    self.primary = primary
    self.secondary = secondary
    self.alert = alert
    self.short = short
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(primary)
        .font(.system(size: short ? 19 : 21, weight: .semibold))
        .tracking(-0.5)
        .lineSpacing(1)
      if let secondary {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          if alert {
            Circle()
              .fill(Palette.warn)
              .frame(width: 7, height: 7)
              .alignmentGuide(.firstTextBaseline) { $0[.bottom] + (short ? 1.5 : 2) }
          }
          Text(secondary)
            .font(.system(size: short ? 14.5 : 16, weight: .semibold))
            .tracking(-0.3)
            .foregroundStyle(Palette.ink3)
        }
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }
}

public struct Caption<Trailing: View>: View {
  let title: String
  let detail: String
  let trailing: Trailing

  public init(title: String, detail: String, @ViewBuilder trailing: () -> Trailing) {
    self.title = title
    self.detail = detail
    self.trailing = trailing()
  }

  public var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(title).font(.system(size: 12.5, weight: .semibold)).tracking(-0.1).lineLimit(1).fixedSize()
      Text(detail).font(.system(size: 11.5)).foregroundStyle(Palette.ink3).monospacedDigit().lineLimit(1)
      Spacer(minLength: 4)
      trailing
    }
  }
}

/// A share bar's fill. While `running`, a soft highlight travels along it: being spent now.
public struct ShareFill: View {
  let running: Bool
  var color: Color
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public init(running: Bool, color: Color = Palette.ink3) {
    self.running = running
    self.color = color
  }

  public var body: some View {
    if running && !reduceMotion {
      TimelineView(.animation(minimumInterval: 1 / 30)) { context in
        let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
        Capsule()
          .fill(LinearGradient(
            stops: [
              .init(color: color, location: 0),
              .init(color: Palette.ink, location: 0.5),
              .init(color: color, location: 1),
            ],
            startPoint: UnitPoint(x: -1 + 2 * t, y: 0.5),
            endPoint: UnitPoint(x: 2 * t, y: 0.5)
          ))
      }
    } else {
      Capsule().fill(color)
    }
  }
}

/// A 28pt tile with an icon; while `running`, a ring pulses out of it.
public struct PulsingIcon<Icon: View>: View {
  let running: Bool
  let icon: Icon
  @State private var pulse = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public init(running: Bool, @ViewBuilder icon: () -> Icon) {
    self.running = running
    self.icon = icon()
  }

  public var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 9, style: .circular).fill(Palette.tile)
      RoundedRectangle(cornerRadius: 9, style: .circular).strokeBorder(Palette.line, lineWidth: 0.5)
      icon
      if running && !reduceMotion {
        RoundedRectangle(cornerRadius: 11, style: .circular)
          .strokeBorder(Palette.ink3, lineWidth: 1)
          .padding(-3)
          .scaleEffect(pulse ? 1.12 : 0.92)
          .opacity(pulse ? 0 : 0.7)
          .onAppear { restartPulse() }
      }
    }
    .frame(width: 28, height: 28)
  }

  /// `pulse` outlives the ring: it is still true when `running` turns on again, so it has to
  /// drop back without animation before the repeating animation can start over.
  private func restartPulse() {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) { pulse = false }
    DispatchQueue.main.async {
      withAnimation(.easeOut(duration: 2.2).repeatForever(autoreverses: false)) { pulse = true }
    }
  }
}

public struct BreathingDot: View {
  let animate: Bool
  var color: Color
  var size: CGFloat
  @State private var dim = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public init(animate: Bool, color: Color = Palette.ink2, size: CGFloat = 5) {
    self.animate = animate
    self.color = color
    self.size = size
  }

  public var body: some View {
    Circle()
      .fill(color)
      .frame(width: size, height: size)
      .opacity(animate && !reduceMotion && dim ? 0.2 : 1)
      .onAppear { updateAnimation() }
      .onChange(of: animate) { _, _ in updateAnimation() }
      .onChange(of: reduceMotion) { _, _ in updateAnimation() }
  }

  private func updateAnimation() {
    guard animate, !reduceMotion else {
      dim = false
      return
    }
    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
      dim = true
    }
  }
}

public struct MoreRow: View {
  let label: String
  let value: String
  let action: () -> Void
  @State private var hovering = false

  public init(label: String, value: String, action: @escaping () -> Void) {
    self.label = label
    self.value = value
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      HStack {
        Text(label)
        Spacer()
        Text(value + " ›").monospacedDigit()
      }
      .font(.system(size: 11.5))
      .foregroundStyle(hovering ? Palette.ink : Palette.ink3)
      .padding(.vertical, 4)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering in withAnimation(Motion.quick) { self.hovering = hovering } }
  }
}

/// Capsule segments, one per series. Tiny shares keep a readable minimum width.
public struct SegmentBar: View {
  let values: [(color: Color, value: Double)]

  public init(values: [(color: Color, value: Double)]) { self.values = values }

  public var body: some View {
    GeometryReader { geometry in
      let present = values.filter { $0.value > 0 }
      let total = max(present.reduce(0) { $0 + $1.value }, 0.0001)
      let gaps = CGFloat(max(0, present.count - 1)) * 2
      let available = max(0, geometry.size.width - gaps)
      let minimum: CGFloat = 6
      let raw = present.map { CGFloat($0.value / total) * available }
      let deficit = raw.reduce(0) { $0 + max(0, minimum - $1) }
      let flexible = raw.reduce(0) { $0 + ($1 > minimum ? $1 : 0) }
      HStack(spacing: 2) {
        ForEach(Array(present.enumerated()), id: \.offset) { index, item in
          let width = raw[index] <= minimum ? minimum : raw[index] - deficit * (raw[index] / max(flexible, 0.0001))
          Capsule().fill(item.color).frame(width: max(minimum, width))
        }
      }
    }
  }
}

public struct FactCard: View {
  let label: String
  let value: String
  let sub: String

  public init(label: String, value: String, sub: String) {
    self.label = label
    self.value = value
    self.sub = sub
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(label).font(.system(size: 10.5)).foregroundStyle(Palette.ink3).lineLimit(1)
      Text(value)
        .font(.system(size: value.count > 14 ? 12 : 15, weight: .semibold))
        .tracking(value.count > 14 ? 0 : -0.3)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.top, value.count > 14 ? 4 : 2)
      Text(sub).font(.system(size: 10.5)).foregroundStyle(Palette.ink3).lineLimit(1).padding(.top, 1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(EdgeInsets(top: 9, leading: 11, bottom: 9, trailing: 11))
    .background(RoundedRectangle(cornerRadius: 12, style: .circular).fill(Palette.tile))
    .overlay(RoundedRectangle(cornerRadius: 12, style: .circular).strokeBorder(Palette.line, lineWidth: 0.5))
  }
}

/// Draws a monochrome SVG as a template image, tinted like text.
public struct SVGMark: View {
  let svg: String
  var size: CGFloat
  var color: Color

  public init(svg: String, size: CGFloat = 13, color: Color = Palette.ink) {
    self.svg = svg
    self.size = size
    self.color = color
  }

  public var body: some View {
    if let image = SVGMarkCache.image(svg) {
      Image(nsImage: image)
        .renderingMode(.template)
        .resizable()
        .interpolation(.high)
        .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
        .foregroundStyle(color)
    } else {
      Color.clear.frame(width: size, height: size)
    }
  }
}

public enum SVGMarkCache {
  @MainActor private static var cache: [String: NSImage] = [:]

  @MainActor public static func image(_ svg: String) -> NSImage? {
    if let cached = cache[svg] { return cached }
    guard let data = svg.data(using: .utf8), let image = NSImage(data: data) else { return nil }
    image.isTemplate = true
    cache[svg] = image
    return image
  }
}
