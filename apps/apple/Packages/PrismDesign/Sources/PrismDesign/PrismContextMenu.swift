import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - Data Model

public struct PrismContextMenuHeader: Sendable, Equatable {
    public let icon: String
    public let title: String
    public let subtitle: String?

    public init(icon: String, title: String, subtitle: String? = nil) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
    }
}

public struct PrismContextMenuItem: Identifiable {
    public enum Role: Sendable, Equatable {
        case standard
        case primary
        case destructive
    }

    public let id: String
    public let title: String
    public let systemImage: String
    public let shortcut: String?
    public let role: Role
    public let isEnabled: Bool
    public let action: @MainActor () -> Void

    public init(
        id: String = UUID().uuidString,
        title: String,
        systemImage: String,
        shortcut: String? = nil,
        role: Role = .standard,
        isEnabled: Bool = true,
        action: @escaping @MainActor () -> Void
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.role = role
        self.isEnabled = isEnabled
        self.action = action
    }
}

public enum PrismContextMenuEntry: Identifiable {
    case action(PrismContextMenuItem)
    case separator(id: String = UUID().uuidString)

    public var id: String {
        switch self {
        case .action(let item): return item.id
        case .separator(let id): return id
        }
    }
}

// MARK: - Screen-Clamped Placement Geometry

public enum PrismContextMenuLayout {
    public struct Insets: Sendable, Equatable {
        public let top: CGFloat
        public let leading: CGFloat
        public let bottom: CGFloat
        public let trailing: CGFloat

        public init(top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat) {
            self.top = top
            self.leading = leading
            self.bottom = bottom
            self.trailing = trailing
        }

        public static let popoverShadow = Insets(top: 14, leading: 24, bottom: 32, trailing: 24)
    }

    /// Computes the AppKit bottom-left frame origin for a transparent host panel so the visible
    /// card opens next to `anchor`, flipping cleanly when near a screen edge and never clipping
    /// outside `visibleFrame`.
    public static func panelOrigin(
        anchor: CGPoint,
        cardSize: CGSize,
        visibleFrame: CGRect,
        shadowInsets: Insets = .popoverShadow,
        cursorOffset: CGFloat = 2,
        edgeMargin: CGFloat = 8
    ) -> CGPoint {
        let minCardX = visibleFrame.minX + edgeMargin
        let maxCardX = max(minCardX, visibleFrame.maxX - edgeMargin - cardSize.width)
        var cardX = anchor.x + cursorOffset
        if cardX + cardSize.width > visibleFrame.maxX - edgeMargin {
            cardX = anchor.x - cursorOffset - cardSize.width
        }
        cardX = min(max(cardX, minCardX), maxCardX)

        // AppKit coordinates have +Y upward: default places the card's top just below `anchor.y`.
        let minCardY = visibleFrame.minY + edgeMargin
        let maxCardY = max(minCardY, visibleFrame.maxY - edgeMargin - cardSize.height)
        var cardY = anchor.y - cursorOffset - cardSize.height
        if cardY < minCardY {
            cardY = anchor.y + cursorOffset
        }
        cardY = min(max(cardY, minCardY), maxCardY)

        return CGPoint(
            x: (cardX - shadowInsets.leading).rounded(),
            y: (cardY - shadowInsets.bottom).rounded()
        )
    }
}

#if os(macOS)

// MARK: - Menu Model & Presenter

@MainActor
@Observable
private final class PrismContextMenuState {
    var highlightedID: String? = nil
    var isPresented: Bool = false
}

private final class PrismContextMenuPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Presents a single custom Prism-styled floating context menu panel without stealing key focus
/// from the underlying view (so text selection stays highlighted).
@MainActor
public final class PrismContextMenuPresenter {
    public static let shared = PrismContextMenuPresenter()

    private var panel: PrismContextMenuPanel?
    private var state: PrismContextMenuState?
    private var enabledItems: [PrismContextMenuItem] = []
    private var cardFrameInScreen: CGRect = .zero
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    private init() {}

    public var isVisible: Bool {
        panel != nil
    }

    public func present(
        header: PrismContextMenuHeader? = nil,
        items: [PrismContextMenuEntry],
        at screenPoint: NSPoint,
        parentWindow: NSWindow? = nil,
        tokens: PrismTokens,
        motionTier: PrismMotionTier = .ultra,
        reduceMotion: Bool = false
    ) {
        dismiss()

        let normalized = Self.normalizedEntries(items)
        let selectable = normalized.compactMap { entry -> PrismContextMenuItem? in
            if case .action(let item) = entry, item.isEnabled { return item }
            return nil
        }
        guard !normalized.isEmpty else { return }

        let menuState = PrismContextMenuState()
        let shadowInsets = PrismContextMenuLayout.Insets.popoverShadow
        let animateIn = !reduceMotion && motionTier != .off
        if !animateIn {
            menuState.isPresented = true
        }

        let content = PrismContextMenuCardView(
            header: header,
            entries: normalized,
            state: menuState,
            shadowInsets: shadowInsets,
            motionTier: motionTier,
            reduceMotion: reduceMotion,
            onTrigger: { [weak self] item in
                self?.trigger(item)
            }
        )
        .environment(\.prismTokens, tokens)
        .environment(\.prismMotionTier, motionTier)
        .preferredColorScheme(tokens.palette.colorScheme)

        let hosting = FirstMouseHostingView(rootView: content)
        let fitting = hosting.fittingSize
        let totalSize = NSSize(
            width: ceil(max(220, fitting.width)),
            height: ceil(max(44, fitting.height))
        )
        let cardSize = CGSize(
            width: max(180, totalSize.width - shadowInsets.leading - shadowInsets.trailing),
            height: max(30, totalSize.height - shadowInsets.top - shadowInsets.bottom)
        )

        let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(screenPoint) })
            ?? parentWindow?.screen
            ?? NSScreen.main
        let visibleFrame = targetScreen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = PrismContextMenuLayout.panelOrigin(
            anchor: screenPoint,
            cardSize: cardSize,
            visibleFrame: visibleFrame,
            shadowInsets: shadowInsets
        )

        let panelRect = NSRect(origin: origin, size: totalSize)
        let cardScreenRect = CGRect(
            x: origin.x + shadowInsets.leading,
            y: origin.y + shadowInsets.bottom,
            width: cardSize.width,
            height: cardSize.height
        )

        let menuPanel = PrismContextMenuPanel(
            contentRect: panelRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        menuPanel.isOpaque = false
        menuPanel.backgroundColor = .clear
        menuPanel.hasShadow = false
        menuPanel.level = .popUpMenu
        menuPanel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        menuPanel.hidesOnDeactivate = true
        menuPanel.isMovable = false
        menuPanel.isReleasedWhenClosed = false
        menuPanel.ignoresMouseEvents = false
        menuPanel.acceptsMouseMovedEvents = true
        menuPanel.becomesKeyOnlyIfNeeded = true
        menuPanel.animationBehavior = .none
        menuPanel.appearance = NSAppearance(named: tokens.palette.isDark ? .darkAqua : .aqua)
        hosting.frame = NSRect(origin: .zero, size: totalSize)
        menuPanel.contentView = hosting

        self.panel = menuPanel
        self.state = menuState
        self.enabledItems = selectable
        self.cardFrameInScreen = cardScreenRect

        installMonitors(parentWindow: parentWindow)
        menuPanel.orderFront(nil)

        if animateIn {
            DispatchQueue.main.async { [weak menuState] in
                menuState?.isPresented = true
            }
        }
    }

    public func dismiss() {
        removeMonitors()
        if let current = panel {
            current.orderOut(nil)
            current.contentView = nil
        }
        panel = nil
        state = nil
        enabledItems = []
        cardFrameInScreen = .zero
    }

    private func trigger(_ item: PrismContextMenuItem) {
        guard item.isEnabled else { return }
        dismiss()
        item.action()
    }

    private func moveHighlight(delta: Int) {
        guard let state, !enabledItems.isEmpty else { return }
        if let currentID = state.highlightedID,
           let idx = enabledItems.firstIndex(where: { $0.id == currentID }) {
            let next = (idx + delta + enabledItems.count) % enabledItems.count
            state.highlightedID = enabledItems[next].id
        } else {
            state.highlightedID = delta > 0 ? enabledItems.first?.id : enabledItems.last?.id
        }
    }

    private func installMonitors(parentWindow: NSWindow?) {
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]
        ) { [weak self] event in
            guard let self, self.panel != nil else { return event }
            switch event.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                let clickScreen = NSEvent.mouseLocation
                if !self.cardFrameInScreen.contains(clickScreen) {
                    self.dismiss()
                }
                return event

            case .scrollWheel:
                self.dismiss()
                return event

            case .keyDown:
                switch event.keyCode {
                case 53: // Escape
                    self.dismiss()
                    return nil
                case 125: // Down Arrow
                    self.moveHighlight(delta: 1)
                    return nil
                case 126: // Up Arrow
                    self.moveHighlight(delta: -1)
                    return nil
                case 36, 76: // Return / Keypad Enter
                    if let currentID = self.state?.highlightedID,
                       let match = self.enabledItems.first(where: { $0.id == currentID }) {
                        self.trigger(match)
                        return nil
                    }
                    self.dismiss()
                    return nil
                default:
                    return event
                }

            default:
                return event
            }
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.dismiss()
            }
        }

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        })

        if let parentWindow {
            for name in [
                NSWindow.didResignKeyNotification,
                NSWindow.didMoveNotification,
                NSWindow.didResizeNotification,
                NSWindow.willCloseNotification,
            ] {
                observers.append(nc.addObserver(forName: name, object: parentWindow, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.dismiss() }
                })
            }
        }
    }

    private func removeMonitors() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        let nc = NotificationCenter.default
        for token in observers {
            nc.removeObserver(token)
        }
        observers.removeAll()
    }

    /// Drops leading, trailing, and consecutive separators so callers can compose sections freely.
    static func normalizedEntries(_ entries: [PrismContextMenuEntry]) -> [PrismContextMenuEntry] {
        var result: [PrismContextMenuEntry] = []
        result.reserveCapacity(entries.count)
        for entry in entries {
            switch entry {
            case .action:
                result.append(entry)
            case .separator:
                if let last = result.last, case .action = last {
                    result.append(entry)
                }
            }
        }
        while let last = result.last, case .separator = last {
            result.removeLast()
        }
        return result
    }
}

// MARK: - SwiftUI Menu Surface

private struct PrismContextMenuCardView: View {
    @Environment(\.prismTokens) private var tokens

    let header: PrismContextMenuHeader?
    let entries: [PrismContextMenuEntry]
    let state: PrismContextMenuState
    let shadowInsets: PrismContextMenuLayout.Insets
    let motionTier: PrismMotionTier
    let reduceMotion: Bool
    let onTrigger: (PrismContextMenuItem) -> Void

    var body: some View {
        let entryAnimation = PrismSpringSpec.snappy.animation(tier: motionTier, reduceMotion: reduceMotion)

        VStack(alignment: .leading, spacing: 0) {
            if let header {
                headerView(header)
                Rectangle()
                    .fill(tokens.borderEtched)
                    .frame(height: 1)
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(entries) { entry in
                    switch entry {
                    case .separator:
                        Rectangle()
                            .fill(tokens.borderEtched)
                            .frame(height: 1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)

                    case .action(let item):
                        PrismContextMenuRowView(
                            item: item,
                            isHighlighted: state.highlightedID == item.id,
                            onHoverChanged: { inside in
                                if inside {
                                    if item.isEnabled {
                                        state.highlightedID = item.id
                                    }
                                } else if state.highlightedID == item.id {
                                    state.highlightedID = nil
                                }
                            },
                            onTrigger: { onTrigger(item) }
                        )
                    }
                }
            }
            .padding(5)
        }
        .frame(minWidth: 224, maxWidth: 278, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .prismSurface(elevation: .popover, cornerRadius: tokens.rLG)
        .scaleEffect(state.isPresented ? 1.0 : 0.96, anchor: .topLeading)
        .opacity(state.isPresented ? 1.0 : 0.0)
        .animation(entryAnimation, value: state.isPresented)
        .padding(.top, shadowInsets.top)
        .padding(.leading, shadowInsets.leading)
        .padding(.bottom, shadowInsets.bottom)
        .padding(.trailing, shadowInsets.trailing)
    }

    private func headerView(_ header: PrismContextMenuHeader) -> some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                    .fill(tokens.primarySoft)
                Image(systemName: header.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tokens.primary)
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(header.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(tokens.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let subtitle = header.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(tokens.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            tokens.surface2.opacity(tokens.palette.isDark ? 0.36 : 0.45)
        )
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: tokens.rLG,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: tokens.rLG,
                style: .continuous
            )
        )
    }
}

private struct PrismContextMenuRowView: View {
    @Environment(\.prismTokens) private var tokens

    let item: PrismContextMenuItem
    let isHighlighted: Bool
    let onHoverChanged: (Bool) -> Void
    let onTrigger: () -> Void

    var body: some View {
        Button(action: onTrigger) {
            HStack(spacing: 8) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(iconColor)
                    .frame(width: 16, alignment: .center)

                Text(item.title)
                    .font(.system(size: 12.5, weight: item.role == .primary ? .semibold : .medium))
                    .foregroundStyle(labelColor)
                    .lineLimit(1)

                Spacer(minLength: 14)

                if let shortcut = item.shortcut, !shortcut.isEmpty {
                    Text(shortcut)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(tokens.placeholder)
                }
            }
            .padding(.horizontal, 8.5)
            .padding(.vertical, 5.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(
            PrismContextMenuRowButtonStyle(
                role: item.role,
                isEnabled: item.isEnabled,
                isHighlighted: isHighlighted,
                tokens: tokens
            )
        )
        .disabled(!item.isEnabled)
        .opacity(item.isEnabled ? 1.0 : 0.42)
        .onHover(perform: onHoverChanged)
    }

    private var iconColor: Color {
        switch item.role {
        case .destructive:
            return tokens.danger
        case .primary:
            return tokens.primary
        case .standard:
            return isHighlighted ? tokens.foreground : tokens.secondaryForeground
        }
    }

    private var labelColor: Color {
        switch item.role {
        case .destructive:
            return tokens.danger
        case .primary:
            return tokens.primary
        case .standard:
            return tokens.foreground
        }
    }
}

private struct PrismContextMenuRowButtonStyle: ButtonStyle {
    let role: PrismContextMenuItem.Role
    let isEnabled: Bool
    let isHighlighted: Bool
    let tokens: PrismTokens

    func makeBody(configuration: Configuration) -> some View {
        let fill: Color = {
            guard isEnabled else { return .clear }
            if configuration.isPressed {
                switch role {
                case .destructive: return tokens.dangerSoft
                case .primary: return tokens.primarySoft
                case .standard: return tokens.activeWash
                }
            }
            if isHighlighted {
                switch role {
                case .destructive: return tokens.dangerSoft.opacity(0.75)
                case .primary: return tokens.primarySoft
                case .standard: return tokens.hoverWash
                }
            }
            return .clear
        }()

        configuration.label
            .background(
                RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                    .fill(fill)
            )
    }
}
#endif
