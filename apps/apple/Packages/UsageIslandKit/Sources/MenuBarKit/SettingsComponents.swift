// Portions of this file are adapted from Cindy (https://github.com/makecindy/cindy),
// Copyright 2026 XD Inc., licensed under the Apache License 2.0 (LICENSES/Apache-2.0.txt).
// Modified for Sarto.

import AppKit
import SwiftUI

// The status preview of Cindy's menu bar panel's settings page (StatusPreview in
// apps/desktop/native/menubar/macos-menubar-helper.swift), made public.

/// A slice of a menu bar over a wallpaper, showing exactly what the status item will look like.
public struct StatusItemPreview: View {
  let image: NSImage?
  let text: String
  @Environment(\.colorScheme) private var colorScheme

  public init(image: NSImage?, text: String) {
    self.image = image
    self.text = text
  }

  public var body: some View {
    let dark = colorScheme == .dark
    ZStack(alignment: .topLeading) {
      wallpaper(dark: dark)
      HStack(spacing: 4) {
        Spacer()
        Image(systemName: "wifi").font(.system(size: 12, weight: .semibold)).opacity(0.5).padding(.horizontal, 6)
        HStack(spacing: 5) {
          if let image {
            Image(nsImage: image).renderingMode(.template).resizable().aspectRatio(contentMode: .fit).frame(width: 16, height: 16)
          }
          if !text.isEmpty {
            Text(text).font(.system(size: 13, weight: .regular)).monospacedDigit().lineLimit(1).fixedSize()
          }
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(dark ? Color.white.opacity(0.18) : Color.black.opacity(0.11)))
        .layoutPriority(1)
        TimelineView(.periodic(from: .now, by: 30)) { context in
          Text(context.date, format: .dateTime.weekday(.abbreviated).hour().minute())
            .font(.system(size: 12, weight: .medium))
            .monospacedDigit()
            .lineLimit(1)
            .opacity(0.8)
            .padding(.horizontal, 6)
        }
      }
      .foregroundStyle(dark ? Color(white: 0.957) : Color(white: 0.063))
      .padding(.horizontal, 10)
      .frame(height: 26)
      .background(.ultraThinMaterial)
      .padding(.top, 16)
    }
    .frame(height: 68)
    .frame(maxWidth: .infinity)
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .circular))
    .overlay(RoundedRectangle(cornerRadius: 14, style: .circular).strokeBorder(Palette.line, lineWidth: 0.5))
    .animation(Motion.quick, value: text)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(text)
  }

  private func wallpaper(dark: Bool) -> some View {
    ZStack {
      (dark ? Color(red: 0.055, green: 0.059, blue: 0.071) : Color(red: 0.89, green: 0.882, blue: 0.859))
      RadialGradient(colors: [dark ? Color(red: 0.165, green: 0.137, blue: 0.251) : Color(red: 0.965, green: 0.937, blue: 0.894), .clear], center: UnitPoint(x: 0.15, y: 0.15), startRadius: 0, endRadius: 220)
      RadialGradient(colors: [dark ? Color(red: 0.29, green: 0.165, blue: 0.11) : Color(red: 0.941, green: 0.788, blue: 0.651), .clear], center: UnitPoint(x: 0.85, y: 0.25), startRadius: 0, endRadius: 200)
      RadialGradient(colors: [dark ? Color(red: 0.071, green: 0.231, blue: 0.227) : Color(red: 0.663, green: 0.765, blue: 0.776), .clear], center: UnitPoint(x: 0.7, y: 1), startRadius: 0, endRadius: 220)
    }
  }
}
