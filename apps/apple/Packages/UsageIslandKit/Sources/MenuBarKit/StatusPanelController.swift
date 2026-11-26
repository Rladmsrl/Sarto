// Portions of this file are adapted from Cindy (https://github.com/makecindy/cindy),
// Copyright 2026 XD Inc., licensed under the Apache License 2.0 (LICENSES/Apache-2.0.txt).
// Modified for Sarto.

import AppKit
import Combine
import SwiftUI

/// State shared by the status panel and the pages inside it.
@MainActor
public final class MenuBarPanelState: ObservableObject {
  public static let defaultWidth: CGFloat = 368

  /// True from `open` until the closing fade has ordered the panel out. Pages render nothing
  /// while false, so their clocks and repeating animations stop.
  @Published public internal(set) var panelVisible = false
  /// Bumped every time the panel opens; tubes, rings and counters replay from zero.
  @Published public internal(set) var fillToken = 0
  /// Set when the panel opens on a short screen (13–14" laptops): content should tighten.
  @Published public internal(set) var short = false
  /// Panel width; changing it while open slides the panel to the new width.
  @Published public var width: CGFloat = MenuBarPanelState.defaultWidth
  /// Natural height of the page on screen; the panel follows it (capped to the screen).
  @Published public var contentHeight: CGFloat = 0
  /// Explicit appearance for the dropdown panel only (nil follows the system). Never touches
  /// NSApp.appearance so the menu bar status item keeps adapting to light/dark wallpapers.
  @Published public var panelAppearance: NSAppearance.Name?
  /// Active Sarto 4-palette theme driving all `Palette.*` tokens inside the menu bar panel.
  @Published public var themeStyle: MenuBarThemeStyle = .obsidian {
    didSet {
      Palette.currentStyle = themeStyle
      panelAppearance = themeStyle.appearanceName
      themeRevision += 1
    }
  }
  @Published public var accentHex: UInt32 = 0x5B89D6 {
    didSet {
      Palette.currentAccentHex = accentHex
      themeRevision += 1
    }
  }
  @Published public var themeRevision: Int = 0

  public var colorScheme: ColorScheme? {
    themeStyle.colorScheme
  }

  public init() {}
}

final class StatusPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

/// Rounded, frosted backing: the system popover material, so the panel reads like other menu
/// bar extras in both appearances.
public final class PanelBackgroundView: NSVisualEffectView {
  public static let radius: CGFloat = 20

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    material = .popover
    blendingMode = .behindWindow
    state = .active
    maskImage = Self.mask(radius: Self.radius)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  static func mask(radius: CGFloat) -> NSImage {
    let edge = radius * 2 + 1
    let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
      NSColor.black.setFill()
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
      return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
  }
}

/// The status item and its drop-down panel, extracted from Cindy's `StatusController`:
///
/// - Opens with a 0.22s fade + 6pt drop on the (0.22, 1, 0.36, 1) curve, closes with a 0.16s fade.
/// - Right edge stays under the status item, top just under the menu bar, never taller than
///   86% of the visible screen.
/// - Height changes settle in 0.25s; width changes slide with the page in 0.55s; a change that
///   lands mid-open retargets the running animation.
/// - Behaves like a menu: a click elsewhere, another app taking focus or Esc closes it.
@MainActor
public final class StatusPanelController: NSObject, NSWindowDelegate {
  private static let screenGap: CGFloat = 6
  private static let sideMargin: CGFloat = 12
  private static let shortScreenHeight: CGFloat = 1000
  private static let heightShare: CGFloat = 0.86

  public let state: MenuBarPanelState
  /// Return true to swallow a key while the panel is open (Esc already closes it).
  public var keyHandler: ((NSEvent) -> Bool)?
  /// Esc on a sub-page should go back instead of closing; return true when handled.
  public var escapeHandler: (() -> Bool)?
  public var onOpenChange: ((Bool) -> Void)?
  /// Preview/screenshot or modal guard: focus moving elsewhere or outside clicks do not close the panel.
  public var pinned = false {
    didSet {
      if !pinned, oldValue, isOpen {
        panel?.makeKey()
      }
    }
  }

  private let statusItem: NSStatusItem
  private let makeRoot: () -> AnyView
  private var panel: StatusPanel?
  private nonisolated(unsafe) var outsideMonitor: Any?
  private nonisolated(unsafe) var keyMonitor: Any?
  private var cancellables = Set<AnyCancellable>()
  public private(set) var isOpen = false
  private var closeGeneration: UInt64 = 0
  private var openRetries = 0
  private var openAnimating = false
  private var closedByStatusPressAt: TimeInterval?

  deinit {
    let outside = outsideMonitor
    let key = keyMonitor
    if outside != nil || key != nil {
      DispatchQueue.main.async {
        if let outside { NSEvent.removeMonitor(outside) }
        if let key { NSEvent.removeMonitor(key) }
      }
    }
  }

  public init<Root: View>(state: MenuBarPanelState? = nil, @ViewBuilder root: @escaping () -> Root) {
    let state = state ?? MenuBarPanelState()
    self.state = state
    self.makeRoot = { AnyView(root()) }
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    super.init()
    if let button = statusItem.button {
      button.imagePosition = .imageLeading
      button.target = self
      button.action = #selector(toggle)
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
    state.$contentHeight
      .removeDuplicates()
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        guard let self, self.isOpen else { return }
        self.layoutPanel(animated: true)
      }
      .store(in: &cancellables)
    state.$width
      .removeDuplicates()
      .dropFirst()
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        guard let self, self.isOpen else { return }
        self.layoutPanel(animated: true)
      }
      .store(in: &cancellables)
    state.$panelAppearance
      .removeDuplicates()
      .receive(on: RunLoop.main)
      .sink { [weak self] name in
        self?.panel?.appearance = name.flatMap(NSAppearance.init(named:))
      }
      .store(in: &cancellables)
  }

  /// Hides the status item without quitting; the panel can still open (anchored top-right).
  public var statusItemVisible: Bool {
    get { statusItem.isVisible }
    set { statusItem.isVisible = newValue }
  }

  /// Image plus an optional title in monospaced digits (a thin space keeps them apart).
  /// Without a tint, uses a template image and plain `button.title` + `button.font` so macOS
  /// adapts automatically to dark and light menu bars. With a tint, pre-tints the image and uses
  /// `attributedTitle` instead of `button.contentTintColor`, because setting `contentTintColor` on
  /// `NSStatusBarButton` renders both icon and text solid black on newer macOS releases.
  public func setStatus(image: NSImage?, title: String, tint: NSColor? = nil, accessibilityLabel: String? = nil) {
    guard let button = statusItem.button else { return }
    let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    button.contentTintColor = nil
    button.font = font
    let displayImage: NSImage?
    if let image, let tint {
      displayImage = Self.tintedStatusImage(image, color: tint)
    } else {
      displayImage = image
    }
    button.image = displayImage
    if title.isEmpty {
      button.attributedTitle = NSAttributedString()
      button.title = ""
      button.imagePosition = .imageOnly
    } else {
      let displayTitle = (displayImage == nil ? "" : "\u{2009}") + title
      button.imagePosition = displayImage == nil ? .noImage : .imageLeading
      if let tint {
        button.attributedTitle = NSAttributedString(
          string: displayTitle,
          attributes: [
            .font: font,
            .foregroundColor: tint,
          ]
        )
      } else {
        button.attributedTitle = NSAttributedString()
        button.title = displayTitle
      }
    }
    button.setAccessibilityLabel(accessibilityLabel ?? title)
  }

  /// Renders a tinted, non-template copy of a template icon at draw time so dynamic colors
  /// (such as `.systemOrange`) resolve against the menu bar's current appearance at Retina scale
  /// without mutating the caller's cached template image.
  private static func tintedStatusImage(_ image: NSImage, color: NSColor) -> NSImage {
    let tinted = NSImage(size: image.size, flipped: false) { rect in
      guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
      ctx.beginTransparencyLayer(in: rect, auxiliaryInfo: nil)
      image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
      color.setFill()
      rect.fill(using: .sourceAtop)
      ctx.endTransparencyLayer()
      return true
    }
    tinted.isTemplate = false
    tinted.accessibilityDescription = image.accessibilityDescription
    return tinted
  }

  @objc public func toggle() {
    if let at = closedByStatusPressAt {
      closedByStatusPressAt = nil
      if ProcessInfo.processInfo.systemUptime - at < 0.6 { return }
    }
    isOpen ? close() : open()
  }

  public func open() {
    guard !isOpen else { return }
    // When the status item is visible right after launch it may not be placed yet; wait briefly.
    // When hidden (`statusItem.isVisible == false`), skip the retry loop and open immediately at
    // the fallback screen/mouse anchor.
    if statusItem.isVisible && statusAnchor() == nil && openRetries < 20 {
      openRetries += 1
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.open() }
      return
    }
    openRetries = 0
    isOpen = true
    closeGeneration &+= 1
    state.panelVisible = true
    let panel = ensurePanel()
    let screen = statusAnchor()?.screen ?? fallbackScreen()
    let short = screen.map { $0.visibleFrame.height < Self.shortScreenHeight } ?? false
    if state.short != short { state.short = short }
    state.fillToken += 1
    layoutPanel(animated: false)
    let target = panel.frame
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    if reduceMotion {
      panel.setFrame(target, display: true)
      panel.alphaValue = 1
      panel.makeKeyAndOrderFront(nil)
      openAnimating = false
    } else {
      panel.setFrame(target.offsetBy(dx: 0, dy: 6), display: false)
      panel.alphaValue = 0
      panel.makeKeyAndOrderFront(nil)
      openAnimating = true
      NSAnimationContext.runAnimationGroup({ context in
        context.duration = 0.22
        context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
        panel.animator().alphaValue = 1
        panel.animator().setFrame(target, display: true)
      }, completionHandler: { [weak self] in
        Task { @MainActor in
          guard let self else { return }
          self.openAnimating = false
          // Content height often changes mid-animation; settle on the latest frame.
          if self.isOpen { self.layoutPanel(animated: false) }
        }
      })
    }
    statusItem.button?.highlight(true)
    installMonitors()
    onOpenChange?(true)
  }

  public func close() {
    guard isOpen, let panel else { return }
    isOpen = false
    closeGeneration &+= 1
    let gen = closeGeneration
    removeMonitors()
    statusItem.button?.highlight(false)
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    if reduceMotion {
      panel.alphaValue = 0
      panel.orderOut(nil)
      state.panelVisible = false
    } else {
      NSAnimationContext.runAnimationGroup({ context in
        context.duration = 0.16
        context.timingFunction = CAMediaTimingFunction(name: .easeIn)
        panel.animator().alphaValue = 0
      }, completionHandler: { [weak self] in
        Task { @MainActor in
          guard let self, !self.isOpen, self.closeGeneration == gen else { return }
          panel.orderOut(nil)
          self.state.panelVisible = false
        }
      })
    }
    onOpenChange?(false)
  }

  private func ensurePanel() -> StatusPanel {
    if let panel { return panel }
    let panel = StatusPanel(
      contentRect: NSRect(x: 0, y: 0, width: state.width, height: 600),
      styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    panel.isFloatingPanel = true
    panel.level = .popUpMenu
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.isMovable = false
    panel.animationBehavior = .none
    panel.appearance = state.panelAppearance.flatMap(NSAppearance.init(named:))
    panel.delegate = self

    let background = PanelBackgroundView(frame: panel.contentLayoutRect)
    background.autoresizingMask = [.width, .height]
    let hosting = NSHostingView(rootView: MenuBarPanelChrome(state: state, content: makeRoot))
    hosting.translatesAutoresizingMaskIntoConstraints = true
    hosting.autoresizingMask = [.width, .height]
    hosting.frame = background.bounds
    hosting.sizingOptions = []
    background.addSubview(hosting)
    panel.contentView = background
    self.panel = panel
    return panel
  }

  private func statusAnchor() -> (rect: NSRect, screen: NSScreen)? {
    guard let button = statusItem.button, let buttonWindow = button.window else { return nil }
    let rect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
    guard rect.width > 0, rect.height > 0 else { return nil }
    let center = NSPoint(x: rect.midX, y: rect.midY)
    guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) else { return nil }
    return (rect, screen)
  }

  private func fallbackScreen() -> NSScreen? {
    let mouse = NSEvent.mouseLocation
    return NSScreen.screens.first(where: { $0.frame.contains(mouse) })
      ?? NSScreen.main
      ?? NSScreen.screens.first
  }

  private func targetFrame() -> NSRect? {
    let buttonRect: NSRect
    let screen: NSScreen
    if statusItem.isVisible, let anchor = statusAnchor() {
      buttonRect = anchor.rect
      screen = anchor.screen
    } else {
      guard let fallback = fallbackScreen() else { return nil }
      screen = fallback
      let mouse = NSEvent.mouseLocation
      let anchorX = fallback.frame.contains(mouse)
        ? min(max(mouse.x, fallback.visibleFrame.minX + state.width / 2 + Self.sideMargin), fallback.visibleFrame.maxX - state.width / 2 - Self.sideMargin)
        : (fallback.frame.maxX - state.width / 2 - Self.sideMargin)
      buttonRect = NSRect(x: anchorX, y: fallback.visibleFrame.maxY, width: 0, height: 0)
    }
    let visible = screen.visibleFrame
    let top = min(buttonRect.minY, visible.maxY) - Self.screenGap
    let maxHeight = max(320, min(top - visible.minY - Self.sideMargin, (visible.height * Self.heightShare).rounded(.down)))
    let width = min(state.width, visible.width - Self.sideMargin * 2)
    let right = min(visible.maxX - Self.sideMargin, buttonRect.midX + state.width / 2)
    let x = max(visible.minX + Self.sideMargin, right - width)
    let natural = state.contentHeight > 0 ? state.contentHeight : 560
    let height = min(maxHeight, natural)
    return NSRect(x: x, y: top - height, width: width, height: height)
  }

  public func layoutPanel(animated: Bool) {
    guard let panel, isOpen, let target = targetFrame() else { return }
    if panel.frame.equalTo(target) { return }
    if openAnimating {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.18
        context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
        panel.animator().setFrame(target, display: true)
      }
      return
    }
    let widthChanged = abs(panel.frame.width - target.width) > 0.5
    let heightChanged = abs(panel.frame.height - target.height) > 0.5
    if animated && (widthChanged || heightChanged) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = widthChanged ? 0.55 : 0.25
        context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
        context.allowsImplicitAnimation = true
        panel.animator().setFrame(target, display: true)
      }
    } else {
      panel.setFrame(target, display: true)
    }
  }

  private func installMonitors() {
    removeMonitors()
    outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
      Task { @MainActor in
        guard let self, !self.pinned else { return }
        // A quick tap on our own item may never reach its action: close here, skip that click.
        if self.statusAnchor()?.rect.contains(NSEvent.mouseLocation) == true {
          guard self.isOpen else { return }
          self.close()
          self.closedByStatusPressAt = ProcessInfo.processInfo.systemUptime
          return
        }
        self.close()
      }
    }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
      guard let self, self.isOpen else { return event }
      if event.keyCode == 53 {
        if self.escapeHandler?() != true { self.close() }
        return nil
      }
      if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "w" {
        self.close()
        return nil
      }
      return self.keyHandler?(event) == true ? nil : event
    }
  }

  private func removeMonitors() {
    if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    outsideMonitor = nil
    keyMonitor = nil
  }

  public func windowDidResignKey(_ notification: Notification) {
    if let event = NSApp.currentEvent,
       event.type == .leftMouseDown || event.type == .rightMouseDown,
       let buttonWindow = statusItem.button?.window,
       event.window === buttonWindow {
      return
    }
    if isOpen && !pinned { close() }
  }
}

/// Backdrop, hairline edge and clip shared by every page.
struct MenuBarPanelChrome: View {
  @ObservedObject var state: MenuBarPanelState
  let content: () -> AnyView

  var body: some View {
    let _ = state.themeRevision
    ZStack(alignment: .topTrailing) {
      if state.panelVisible { content() }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    .background { PanelBackdrop() }
    .overlay(
      RoundedRectangle(cornerRadius: PanelBackgroundView.radius, style: .circular)
        .strokeBorder(Palette.edge, lineWidth: 0.5)
        .allowsHitTesting(false)
    )
    .clipShape(RoundedRectangle(cornerRadius: PanelBackgroundView.radius, style: .circular))
    .foregroundStyle(Palette.ink)
    .preferredColorScheme(state.colorScheme)
    .id(state.themeRevision)
  }
}

/// Warm tint over the popover material with a faint orange glow in the top-left corner.
public struct PanelBackdrop: View {
  public init() {}

  public var body: some View {
    ZStack {
      Palette.panelTint
      RadialGradient(colors: [Palette.panelGlow, .clear], center: .topLeading, startRadius: 0, endRadius: 240)
      RadialGradient(colors: [Palette.panelGlow2, .clear], center: UnitPoint(x: 1, y: 0.18), startRadius: 0, endRadius: 220)
    }
    .allowsHitTesting(false)
  }
}
