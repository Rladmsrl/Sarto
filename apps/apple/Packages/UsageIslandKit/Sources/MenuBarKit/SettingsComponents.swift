// Portions of this file are adapted from Cindy (https://github.com/makecindy/cindy),
// Copyright 2026 XD Inc., licensed under the Apache License 2.0 (LICENSES/Apache-2.0.txt).
// Modified for Sarto.

import AppKit
import SwiftUI

// Settings-page pieces of Cindy's menu bar panel (ManagePage, ChoiceGrid, StatusPreview in
// apps/desktop/native/menubar/macos-menubar-helper.swift), made public.

/// Section title with an optional right-aligned detail ("4 / 6 shown").
public struct SettingsSectionHeader: View {
  let title: String
  let detail: String?

  public init(_ title: String, detail: String? = nil) {
    self.title = title
    self.detail = detail
  }

  public var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).fixedSize()
      Spacer(minLength: 0)
      if let detail {
        Text(detail).font(.system(size: 11)).foregroundStyle(Palette.ink3).monospacedDigit().lineLimit(1).truncationMode(.tail)
      }
    }
    .padding(EdgeInsets(top: 16, leading: 18, bottom: 6, trailing: 18))
  }
}

/// Title (and optional hint) on the left, a control on the right.
public struct SettingRow<Control: View>: View {
  let title: String
  let sub: String?
  let control: Control

  public init(_ title: String, sub: String? = nil, @ViewBuilder control: () -> Control) {
    self.title = title
    self.sub = sub
    self.control = control()
  }

  public var body: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 1) {
        Text(title).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
        if let sub {
          Text(sub).font(.system(size: 10.5)).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      control
    }
    .padding(.vertical, 8)
  }
}

/// A small switch, the only toggle style the panel uses. `shakeToken` changes make it shake
/// (the user tried to turn off the last thing that must stay on).
public struct PanelSwitch: View {
  let label: String
  @Binding var isOn: Bool
  var shakeToken: Int
  @State private var shake: CGFloat = 0

  public init(_ label: String, isOn: Binding<Bool>, shakeToken: Int = 0) {
    self.label = label
    _isOn = isOn
    self.shakeToken = shakeToken
  }

  public var body: some View {
    Toggle(label, isOn: $isOn)
      .toggleStyle(.switch)
      .controlSize(.small)
      .labelsHidden()
      .offset(x: shake)
      .onChange(of: shakeToken) {
        withAnimation(.easeInOut(duration: 0.06).repeatCount(4, autoreverses: true)) { shake = 4 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { withAnimation(.easeOut(duration: 0.05)) { shake = 0 } }
      }
  }
}

/// Exclusive choice in two columns of equal chips; assistive tech sees one radio group.
public struct ChoiceGrid: View {
  let label: String
  let options: [(id: String, label: String)]
  let selected: String
  let choose: (String) -> Void

  public init(label: String, options: [(id: String, label: String)], selected: String, choose: @escaping (String) -> Void) {
    self.label = label
    self.options = options
    self.selected = selected
    self.choose = choose
  }

  public var body: some View {
    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
      ForEach(options, id: \.id) { option in
        ChoiceChip(label: option.label, selected: option.id == selected) { choose(option.id) }
      }
    }
    .accessibilityRepresentation {
      Picker(label, selection: Binding(get: { selected }, set: { choose($0) })) {
        ForEach(options, id: \.id) { option in Text(option.label).tag(option.id) }
      }
      .pickerStyle(.radioGroup)
    }
  }
}

public struct ChoiceChip: View {
  let label: String
  let selected: Bool
  let action: () -> Void
  @State private var hovering = false

  public init(label: String, selected: Bool, action: @escaping () -> Void) {
    self.label = label
    self.selected = selected
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      Text(label)
        .font(.system(size: 12, weight: selected ? .semibold : .regular))
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .padding(.horizontal, 8)
        .foregroundStyle(selected ? Palette.onInk : Palette.ink2)
        .background(Capsule().fill(selected ? Palette.ink : (hovering ? Palette.ink5 : Palette.tile)))
        .overlay(Capsule().strokeBorder(selected ? Color.clear : Palette.line, lineWidth: 0.5))
        .contentShape(Capsule())
    }
    .buttonStyle(PressScaleStyle())
    .onHover { value in withAnimation(Motion.quick) { hovering = value } }
    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
  }
}

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
