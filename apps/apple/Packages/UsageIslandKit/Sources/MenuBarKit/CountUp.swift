// Portions of this file are adapted from Cindy (https://github.com/makecindy/cindy),
// Copyright 2026 XD Inc., licensed under the Apache License 2.0 (LICENSES/Apache-2.0.txt).
// Modified for Sarto.

import AppKit
import SwiftUI

// Extracted from Cindy's apps/desktop/native/menubar/macos-menubar-helper.swift.

/// A plain number ("53", "$31.17", "$20.0k") counts up from zero each time the panel opens
/// (`replayToken`), alongside the rising liquid. The final text reserves the width, so the
/// count never shifts its neighbours; anything that is not a plain number shows as-is.
public struct CountUpText: View {
  let text: String
  let font: Font
  let replayToken: Int
  var delay: Double = 0

  public init(text: String, font: Font, replayToken: Int, delay: Double = 0) {
    self.text = text
    self.font = font
    self.replayToken = replayToken
    self.delay = delay
  }
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var progress: Double = 1

  public var body: some View {
    if let parts = CountUpParts(text) {
      Text(text)
        .opacity(0)
        .modifier(CountUpModifier(progress: progress, parts: parts))
        .font(font.monospacedDigit())
        .onAppear { replay() }
        .onChange(of: replayToken) { replay() }
    } else {
      Text(text).font(font.monospacedDigit())
    }
  }

  private func replay() {
    guard !reduceMotion else { progress = 1; return }
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) { progress = 0 }
    DispatchQueue.main.async {
      withAnimation(Motion.liquid.delay(delay)) { progress = 1 }
    }
  }
}

private struct CountUpModifier: ViewModifier, Animatable {
  var progress: Double
  let parts: CountUpParts

  var animatableData: Double {
    get { progress }
    set { progress = newValue }
  }

  /// The visible count is laid out in the hidden final text's frame and inherits the same
  /// line limit and scale factor, so a long value shrinks together with its placeholder.
  func body(content: Content) -> some View {
    content.overlay(alignment: .trailing) {
      Text(parts.render(progress)).accessibilityHidden(true)
    }
  }
}

/// "$20.0k" -> prefix "$", value 20.0 with one decimal, suffix "k".
struct CountUpParts: Equatable {
  let prefix: String
  let value: Double
  let decimals: Int
  let grouped: Bool
  let suffix: String

  private static let pattern = try! NSRegularExpression(
    pattern: "^([^0-9]*)([0-9][0-9,]*(?:\\.[0-9]+)?)([^0-9]*)$"
  )
  private static let formatterLock = NSLock()
  private nonisolated(unsafe) static var groupedFormatters: [Int: NumberFormatter] = [:]

  private static func formatGrouped(_ value: Double, decimals: Int) -> String {
    formatterLock.lock()
    defer { formatterLock.unlock() }
    let formatter: NumberFormatter
    if let cached = groupedFormatters[decimals] {
      formatter = cached
    } else {
      let created = NumberFormatter()
      created.numberStyle = .decimal
      created.locale = Locale(identifier: "en_US")
      created.minimumFractionDigits = decimals
      created.maximumFractionDigits = decimals
      groupedFormatters[decimals] = created
      formatter = created
    }
    return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.\(decimals)f", value)
  }

  init?(_ text: String) {
    let range = NSRange(text.startIndex..., in: text)
    guard let match = Self.pattern.firstMatch(in: text, range: range),
          let prefixRange = Range(match.range(at: 1), in: text),
          let numberRange = Range(match.range(at: 2), in: text),
          let suffixRange = Range(match.range(at: 3), in: text)
    else { return nil }
    let number = String(text[numberRange])
    guard let value = Double(number.replacingOccurrences(of: ",", with: "")) else { return nil }
    prefix = String(text[prefixRange])
    suffix = String(text[suffixRange])
    self.value = value
    decimals = number.split(separator: ".").dropFirst().first?.count ?? 0
    grouped = number.contains(",")
  }

  func render(_ progress: Double) -> String {
    let current = value * max(0, min(1, progress))
    let body: String
    if grouped {
      body = Self.formatGrouped(current, decimals: decimals)
    } else {
      body = String(format: "%.\(decimals)f", current)
    }
    return prefix + body + suffix
  }
}
