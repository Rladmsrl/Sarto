import AppKit
import Observation
import SwiftUI

/// Caches physical hardware notch metrics per `CGDirectDisplayID` whenever `safeAreaInsets.top > 0`
/// so entering a native macOS fullscreen Space (`safeAreaInsets.top == 0` transiently) preserves
/// the physical notch silhouette instead of collapsing to the floating pill fallback.
@MainActor
enum HardwareNotchCache {
    struct Metrics: Equatable {
        let notchWidth: CGFloat
        let barHeight: CGFloat
        let centerXOffset: CGFloat
        let referenceSize: CGSize
    }

    private static var byDisplayID: [UInt32: Metrics] = [:]

    static func record(
        screenID: UInt32,
        notchWidth: CGFloat,
        barHeight: CGFloat,
        centerXOffset: CGFloat,
        frameSize: CGSize
    ) {
        guard screenID != 0, notchWidth > 0, barHeight > 0, frameSize.width > 0, frameSize.height > 0 else { return }
        byDisplayID[screenID] = Metrics(
            notchWidth: notchWidth,
            barHeight: barHeight,
            centerXOffset: centerXOffset,
            referenceSize: frameSize
        )
    }

    static func metrics(for screenID: UInt32, currentFrameSize: CGSize) -> (notchWidth: CGFloat, barHeight: CGFloat, centerXOffset: CGFloat)? {
        guard let cached = byDisplayID[screenID],
              cached.referenceSize.width > 0,
              cached.referenceSize.height > 0
        else { return nil }
        if cached.referenceSize == currentFrameSize {
            return (cached.notchWidth, cached.barHeight, cached.centerXOffset)
        }
        let sx = currentFrameSize.width / cached.referenceSize.width
        let sy = currentFrameSize.height / cached.referenceSize.height
        return (
            (cached.notchWidth * sx).rounded(),
            (cached.barHeight * sy).rounded(),
            (cached.centerXOffset * sx).rounded()
        )
    }

    static func hasNotch(_ screenID: UInt32) -> Bool {
        byDisplayID[screenID] != nil
    }
}

/// Borderless non-activating overlay panel sitting at `mainMenu + 3` above every Space & full-screen app.
/// Never steals app activation; accepts keyboard focus only when explicitly clicked open.
final class PrismIslandPanel: NSPanel {
    var keyable = false

    override var canBecomeKey: Bool { keyable }
    override var canBecomeMain: Bool { false }

    // Allow positioning flush against the top edge over the macOS menu bar / notch.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Per-display geometry container so heterogeneous monitors (e.g. MacBook notch + external 4K)
/// render simultaneously with exact per-screen notch/menu-bar dimensions.
@MainActor
@Observable
final class ScreenGeometryBox {
    var geometry = IslandGeometry()
}

/// Manages a single display's Dynamic Island panel (`PrismIslandPanel`), hosted by `PrismIslandHub`.
@MainActor
final class PrismIslandPanelController {
    let screenID: UInt32
    let panel: PrismIslandPanel
    let geometryBox = ScreenGeometryBox()

    private let model: PrismIslandModel
    private(set) var topAnchor = CGPoint.zero
    private(set) var screenFrame = CGRect.zero
    private var hideWork: DispatchWorkItem?
    /// The window that was key before a click opened the panel, given key status back on collapse.
    private weak var previousKeyWindow: NSWindow?

    init(
        screenID: UInt32,
        model: PrismIslandModel,
        usageStore: PrismUsageStore,
        settingsStore: UsageSettingsStore,
        gameStore: GameStore
    ) {
        self.screenID = screenID
        self.model = model
        self.panel = PrismIslandPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        // Set floating panel before raising the level, since `isFloatingPanel = true` resets level to `.floating`.
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle, .transient,
        ]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none

        let host = NSHostingView(
            rootView: PrismIslandRootView(
                model: model,
                usageStore: usageStore,
                settingsStore: settingsStore,
                gameStore: gameStore,
                screenID: screenID,
                geometryBox: geometryBox
            )
            .focusEffectDisabled()
        )
        host.sizingOptions = []
        panel.contentView = host

        place()
    }

    func place() {
        guard let screen = Displays.screen(id: screenID) else {
            hideWork?.cancel()
            panel.orderOut(nil)
            return
        }
        let frame = screen.frame
        self.screenFrame = frame

        var g = IslandGeometry()
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea
        {
            let notchWidth = frame.width - left.width - right.width
            let barHeight = screen.safeAreaInsets.top
            let centerOffset = left.width + notchWidth / 2
            g.notchWidth = notchWidth
            g.notchHeight = barHeight
            g.hasNotch = true
            topAnchor = CGPoint(x: frame.minX + centerOffset, y: frame.maxY)
            HardwareNotchCache.record(
                screenID: screenID,
                notchWidth: notchWidth,
                barHeight: barHeight,
                centerXOffset: centerOffset,
                frameSize: frame.size
            )
        } else if let cached = HardwareNotchCache.metrics(for: screenID, currentFrameSize: frame.size) {
            // Preserve physical hardware notch geometry inside fullscreen macOS Spaces where
            // `safeAreaInsets.top` transiently reports 0.
            g.notchWidth = cached.notchWidth
            g.notchHeight = cached.barHeight
            g.hasNotch = true
            topAnchor = CGPoint(x: frame.minX + cached.centerXOffset, y: frame.maxY)
        } else {
            let menuBarHeight = frame.maxY - screen.visibleFrame.maxY
            g.notchWidth = 0
            g.notchHeight = menuBarHeight > 20 ? menuBarHeight : IslandMetrics.bandHeight
            g.hasNotch = false
            topAnchor = CGPoint(x: frame.midX, y: frame.maxY)
        }
        g.maxHeight = (frame.height * IslandMetrics.maxHeightShare).rounded()

        if geometryBox.geometry != g {
            geometryBox.geometry = g
        }
        if let preferred = Displays.preferredScreen(), Displays.id(of: preferred) == screenID {
            if model.geometry != g { model.geometry = g }
        }

        let width = max(
            model.openWidth(for: g),
            model.stackWidth(for: g),
            model.collapsedWidth(for: g),
            IslandMetrics.grownWidth
        ) + 2 * IslandMetrics.margin
        let height = g.maxHeight + IslandMetrics.margin
        panel.setFrame(
            NSRect(
                x: (topAnchor.x - width / 2).rounded(),
                y: topAnchor.y - height,
                width: width,
                height: height
            ),
            display: false
        )
    }

    /// Whether a point over the island lies in its notch-high top band.
    func isInBand(_ point: NSPoint) -> Bool {
        point.y >= topAnchor.y - geometryBox.geometry.notchHeight
    }

    func hitRect() -> NSRect {
        let m = model.effectiveMode(for: screenID)
        if m == .hidden || (m == .collapsed && model.collapsedQuiet && !geometryBox.geometry.hasNotch) {
            return .zero
        }
        let size = model.frameSize(for: geometryBox.geometry, mode: m, screenID: screenID)
        return NSRect(
            x: topAnchor.x - size.width / 2,
            y: topAnchor.y - size.height,
            width: size.width,
            height: size.height
        )
    }

    var topBandMinY: CGFloat {
        let bandHeight: CGFloat
        if model.effectiveMode(for: screenID) == .collapsed && model.isSessionStackActive {
            bandHeight = model.frameSize(for: geometryBox.geometry, mode: .collapsed, screenID: screenID).height
        } else {
            bandHeight = max(geometryBox.geometry.notchHeight, 44)
        }
        return topAnchor.y - bandHeight - 18
    }

    func setIgnoresMouseEvents(_ ignore: Bool) {
        if panel.ignoresMouseEvents != ignore {
            panel.ignoresMouseEvents = ignore
        }
    }

    func handleModeChange(_ mode: IslandMode) {
        guard Displays.screen(id: screenID) != nil else {
            hideWork?.cancel()
            panel.orderOut(nil)
            return
        }
        let localMode = model.effectiveMode(for: screenID)
        panel.setAccessibilityLabel(model.strings.text("label"))
        hideWork?.cancel()

        if localMode == .hidden {
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.model.effectiveMode(for: self.screenID) == .hidden else { return }
                    self.panel.orderOut(nil)
                }
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        } else if !panel.isVisible {
            place()
            panel.orderFrontRegardless()
        }

        if localMode == .open && model.openedByClick {
            if !panel.isKeyWindow {
                let current = NSApp.keyWindow
                previousKeyWindow = current is PrismIslandPanel ? nil : current
            }
            panel.keyable = true
            panel.makeKey()
        } else if localMode != .open {
            panel.keyable = false
            if panel.isKeyWindow {
                releaseKeyFocus()
            } else {
                previousKeyWindow = nil
            }
        }
    }

    /// `resignKey()` must never be called directly, so key status is handed back instead: to the
    /// app's previous key window while the app is active, otherwise by ordering the (now unkeyable)
    /// panel out and in, which returns keyboard focus to the app that had it.
    private func releaseKeyFocus() {
        let previous = previousKeyWindow
        previousKeyWindow = nil
        if NSApp.isActive, let previous, previous.isVisible, !previous.isMiniaturized, previous.canBecomeKey {
            previous.makeKey()
        } else {
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    func announce(_ text: String) {
        guard !text.isEmpty else { return }
        NSAccessibility.post(
            element: panel,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    func tearDown() {
        hideWork?.cancel()
        hideWork = nil
        panel.keyable = false
        panel.ignoresMouseEvents = true
        panel.orderOut(nil)
        panel.close()
    }
}

/// Thread-safe synchronous pre-filter state for `NSEvent` mouse monitors so 1000Hz mice never
/// allocate `Task` closures while moving below the top menu-bar band in `.collapsed` mode.
private final class PointerPreFilter: @unchecked Sendable {
    struct Band {
        let minX: CGFloat
        let maxX: CGFloat
        let minY: CGFloat
    }

    private let lock = NSLock()
    private var enabled = false
    private var needsFullCheck = false
    private var bands: [Band] = []

    func update(enabled: Bool, needsFullCheck: Bool, bands: [Band]) {
        lock.lock()
        self.enabled = enabled
        self.needsFullCheck = needsFullCheck
        self.bands = bands
        lock.unlock()
    }

    func shouldDispatch(point: CGPoint) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return false }
        if needsFullCheck { return true }
        for band in bands {
            if point.y >= band.minY && point.x >= band.minX && point.x <= band.maxX {
                return true
            }
        }
        return false
    }
}

/// Multi-monitor Dynamic Island hub: spawns one `PrismIslandPanelController` per checked screen,
/// registers AppKit event monitors ONLY while enabled, synchronously pre-filters mouse movement
/// before hopping onto `@MainActor`, and suspends animations when displays sleep or lock.
@MainActor
final class PrismIslandHub {
    private let model: PrismIslandModel
    private let usageStore: PrismUsageStore
    private let settingsStore: UsageSettingsStore
    private let gameStore: GameStore

    private var enabled = false
    private var desiredChoices: [DisplayChoice] = []
    private var controllers: [UInt32: PrismIslandPanelController] = [:]
    private let preFilter = PointerPreFilter()
    private nonisolated(unsafe) var monitors: [Any] = []
    private nonisolated(unsafe) var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private nonisolated(unsafe) var distributedObservers: [NSObjectProtocol] = []

    private nonisolated(unsafe) var hoverTimer: Timer?
    private nonisolated(unsafe) var leaveTimer: Timer?
    private nonisolated(unsafe) var wakeHoldTimer: Timer?
    private var wakeSuppressed = false
    private var hoveredScreenID: UInt32?
    private var lastPoint: CGPoint?
    private var lastMoveTime: TimeInterval = 0
    private var smoothedSpeed: Double = 0
    private var collapsedAt: TimeInterval = 0

    /// Pointer dwell threshold (120ms, < 1.2 pt/ms) so casual menu-bar sweeps never misfire.
    private static let dwellDelay: TimeInterval = 0.12
    private static let slowSpeedThreshold: Double = 1.2
    private static let leaveGraceDelay: TimeInterval = 0.40
    private static let hoverCooldown: TimeInterval = 0.30

    var isVisible: Bool {
        enabled && !controllers.isEmpty && model.mode != .hidden
    }

    init(
        model: PrismIslandModel,
        usageStore: PrismUsageStore,
        settingsStore: UsageSettingsStore,
        gameStore: GameStore
    ) {
        self.model = model
        self.usageStore = usageStore
        self.settingsStore = settingsStore
        self.gameStore = gameStore

        model.onModeChange = { [weak self] mode in
            self?.handleModeChange(mode)
        }
        model.onAnnounce = { [weak self] text in
            self?.announce(text)
        }
        model.onHitAreaChange = { [weak self] in
            self?.refreshPreFilter()
            self?.pointerMoved()
        }

        installNotificationObservers()
    }

    deinit {
        hoverTimer?.invalidate()
        leaveTimer?.invalidate()
        wakeHoldTimer?.invalidate()
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        for (center, token) in observers {
            center.removeObserver(token)
        }
        let dnc = DistributedNotificationCenter.default()
        for token in distributedObservers {
            dnc.removeObserver(token)
        }
    }

    // MARK: - Multi-Display Management

    func setEnabled(_ on: Bool, screens: [NSScreen]) {
        apply(enabled: on, screens: screens)
    }

    func apply(enabled: Bool, screens: [NSScreen]) {
        self.enabled = enabled
        self.desiredChoices = settingsStore.settings.islandDisplays

        guard enabled, !screens.isEmpty else {
            removeEventMonitors()
            tearDownAllControllers()
            model.leave()
            refreshPreFilter()
            return
        }

        syncPanels(with: screens)
        installEventMonitors()
        refreshPreFilter()
        pointerMoved()
    }

    func relocateAll() {
        guard enabled else { return }
        let activeScreens = Displays.screens(for: settingsStore.settings.islandDisplays)
        guard !activeScreens.isEmpty else {
            tearDownAllControllers()
            refreshPreFilter()
            return
        }
        syncPanels(with: activeScreens)
        refreshPreFilter()
        pointerMoved()
    }

    /// Synchronizes live panel controllers against connected `screens`, immediately ordering out
    /// and tearing down any disconnected `CGDirectDisplayID`s.
    private func syncPanels(with screens: [NSScreen]) {
        let connectedIDs = Set(NSScreen.screens.map(Displays.id(of:)))
        let liveScreens = screens.filter { connectedIDs.contains(Displays.id(of: $0)) }
        let desiredIDs = Set(liveScreens.map(Displays.id(of:)))

        for (sid, controller) in controllers where !desiredIDs.contains(sid) {
            controller.panel.orderOut(nil)
            controller.tearDown()
            controllers.removeValue(forKey: sid)
            if hoveredScreenID == sid { hoveredScreenID = nil }
        }

        for screen in liveScreens {
            let sid = Displays.id(of: screen)
            if let existing = controllers[sid] {
                existing.place()
            } else {
                let controller = PrismIslandPanelController(
                    screenID: sid,
                    model: model,
                    usageStore: usageStore,
                    settingsStore: settingsStore,
                    gameStore: gameStore
                )
                controllers[sid] = controller
                controller.handleModeChange(model.mode)
            }
        }
    }

    private func tearDownAllControllers() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        leaveTimer?.invalidate()
        leaveTimer = nil
        wakeHoldTimer?.invalidate()
        wakeHoldTimer = nil
        wakeSuppressed = false
        hoveredScreenID = nil
        for controller in controllers.values {
            controller.tearDown()
        }
        controllers.removeAll()
    }

    private func refreshPreFilter() {
        let needsFull = hoveredScreenID != nil
            || model.pointerInside
            || model.mode == .open
            || model.mode == .grown
        let bands = controllers.values.compactMap { c -> PointerPreFilter.Band? in
            guard c.screenFrame.width > 0 else { return nil }
            return PointerPreFilter.Band(
                minX: c.screenFrame.minX,
                maxX: c.screenFrame.maxX,
                minY: c.topBandMinY
            )
        }
        preFilter.update(
            enabled: enabled && !controllers.isEmpty && model.mode != .hidden,
            needsFullCheck: needsFull,
            bands: bands
        )
    }

    // MARK: - Zero-Polling Observers & Event Monitors

    private func installNotificationObservers() {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()

        observers.append((
            center,
            center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.relocateAll() }
            }
        ))

        for name in [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didActivateApplicationNotification,
        ] {
            observers.append((
                workspace,
                workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.enabled, self.model.mode != .open else { return }
                        self.relocateAll()
                    }
                }
            ))
        }

        observers.append((
            workspace,
            workspace.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                }
            }
        ))

        // Pause island optical animations when display sleeps or session locks (0% idle background power).
        for name in [
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ] {
            observers.append((
                workspace,
                workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.model.suspended = true
                        self?.wakeHoldTimer?.invalidate()
                        self?.wakeHoldTimer = nil
                    }
                }
            ))
        }
        for name in [
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ] {
            observers.append((
                workspace,
                workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.model.suspended = false
                        self.wakeSuppressed = true
                        self.wakeHoldTimer?.invalidate()
                        self.wakeHoldTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
                            Task { @MainActor [weak self] in
                                self?.wakeSuppressed = false
                                self?.wakeHoldTimer = nil
                            }
                        }
                        if self.enabled { self.relocateAll() }
                    }
                }
            ))
        }
        distributedObservers.append(
            dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.model.suspended = true }
            }
        )
        distributedObservers.append(
            dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.model.suspended = false }
            }
        )
    }

    private func installEventMonitors() {
        guard monitors.isEmpty else { return }
        let preFilter = self.preFilter
        let moveMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]

        if let m = NSEvent.addGlobalMonitorForEvents(matching: moveMask, handler: { [weak self] _ in
            let point = NSEvent.mouseLocation
            guard preFilter.shouldDispatch(point: point) else { return }
            Task { @MainActor [weak self] in self?.pointerMoved(at: point) }
        }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: moveMask, handler: { [weak self] event in
            let point = NSEvent.mouseLocation
            if preFilter.shouldDispatch(point: point) {
                Task { @MainActor [weak self] in self?.pointerMoved(at: point) }
            }
            return event
        }) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            guard preFilter.shouldDispatch(point: NSEvent.mouseLocation) else { return }
            Task { @MainActor [weak self] in
                if self?.model.mode == .open {
                    self?.model.collapse()
                }
            }
        }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, self.model.mode == .open else { return }
                let isIslandWindow = self.controllers.values.contains { $0.panel === event.window }
                if !isIslandWindow {
                    self.model.collapse()
                }
            }
            return event
        }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, self.controllers.values.contains(where: { $0.panel.isKeyWindow }) else { return event }
            return self.handleKeyDown(event) ? nil : event
        }) {
            monitors.append(m)
        }
    }

    private func removeEventMonitors() {
        guard !monitors.isEmpty else { return }
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors.removeAll()
    }

    // MARK: - Pointer Hit Testing & Hover State

    private func pointerMoved(at overridePoint: CGPoint? = nil) {
        guard enabled, !controllers.isEmpty, model.mode != .hidden else {
            for controller in controllers.values { controller.setIgnoresMouseEvents(true) }
            if model.pointerInside { model.pointerInside = false }
            refreshPreFilter()
            return
        }

        let point = overridePoint ?? NSEvent.mouseLocation
        let nowTime = ProcessInfo.processInfo.systemUptime
        if let last = lastPoint, nowTime > lastMoveTime {
            let instantSpeed = hypot(point.x - last.x, point.y - last.y) / ((nowTime - lastMoveTime) * 1000)
            smoothedSpeed = 0.6 * instantSpeed + 0.4 * smoothedSpeed
        }
        lastPoint = point
        lastMoveTime = nowTime

        var hitScreenID: UInt32?
        for (sid, controller) in controllers {
            let hit = controller.hitRect().insetBy(dx: -2, dy: -2).contains(point)
            controller.setIgnoresMouseEvents(!hit)
            if hit { hitScreenID = sid }
        }

        let over = hitScreenID != nil
        if model.pointerInside != over {
            model.pointerInside = over
        }

        // Over the running session stack only its top band opens the panel on hover, so the
        // session rows below stay where the pointer can click them.
        if let sid = hitScreenID,
           model.mode == .collapsed,
           model.isSessionStackActive,
           controllers[sid]?.isInBand(point) == false
        {
            hitScreenID = nil
        }

        guard hitScreenID != hoveredScreenID else {
            refreshPreFilter()
            return
        }
        let prev = hoveredScreenID
        hoveredScreenID = hitScreenID
        refreshPreFilter()
        if let sid = hitScreenID {
            pointerEntered(screenID: sid)
        } else if prev != nil {
            pointerLeft()
        }
    }

    private func pointerEntered(screenID: UInt32) {
        leaveTimer?.invalidate()
        leaveTimer = nil
        guard !wakeSuppressed else { return }
        guard model.mode == .collapsed || model.mode == .grown else { return }
        if ProcessInfo.processInfo.systemUptime - collapsedAt < Self.hoverCooldown { return }
        model.holdPop(paused: true)
        model.prepare(onScreen: screenID)
        armHoverTimer(after: Self.dwellDelay, screenID: screenID)
    }

    private func armHoverTimer(after seconds: TimeInterval, screenID: UInt32) {
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.hoveredScreenID == screenID else { return }
                let still = ProcessInfo.processInfo.systemUptime - self.lastMoveTime > 0.05
                if still || self.smoothedSpeed < Self.slowSpeedThreshold {
                    self.model.expand(by: .hover, onScreen: screenID)
                } else {
                    self.armHoverTimer(after: 0.04, screenID: screenID)
                }
            }
        }
    }

    private func pointerLeft() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        if model.mode == .grown { model.holdPop(paused: false) }
        if model.mode == .collapsed { model.cancelMeasurement() }
        if model.mode == .open && model.opener == .hover {
            leaveTimer?.invalidate()
            leaveTimer = Timer.scheduledTimer(withTimeInterval: Self.leaveGraceDelay, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.leaveTimer = nil
                    self?.model.collapse()
                }
            }
        }
    }

    // MARK: - Keyboard Navigation

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: // Esc
            model.collapse()
            return true
        case 125: // Down arrow
            model.moveSelection(1)
            return true
        case 126: // Up arrow
            model.moveSelection(-1)
            return true
        case 36, 76: // Return / Enter
            if let rowKey = model.selectedRowKey {
                model.openRow(rowKey)
                return true
            }
            if let req = model.requests.first {
                model.openRequest(req)
                return true
            }
            return false
        default:
            guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                  let digit = event.charactersIgnoringModifiers.flatMap(Int.init),
                  let req = model.requests.first,
                  let option = model.digitOption(digit, for: req)
            else { return false }
            model.answer(req, option: option)
            return true
        }
    }

    // MARK: - Broadcast Mode & Accessibility

    private func handleModeChange(_ mode: IslandMode) {
        if mode == .collapsed {
            collapsedAt = ProcessInfo.processInfo.systemUptime
            leaveTimer?.invalidate()
            leaveTimer = nil
        } else if mode == .hidden {
            hoverTimer?.invalidate()
            hoverTimer = nil
            leaveTimer?.invalidate()
            leaveTimer = nil
        }
        for controller in controllers.values {
            controller.handleModeChange(mode)
        }
        refreshPreFilter()
        pointerMoved()
    }

    private func announce(_ text: String) {
        if let active = model.activeScreenID, let controller = controllers[active] {
            controller.announce(text)
        } else {
            controllers.values.first?.announce(text)
        }
    }
}
