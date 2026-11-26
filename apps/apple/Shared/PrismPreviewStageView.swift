import SartoProtocol
import PrismDesign
import SwiftUI
#if os(macOS)
import AppKit
import AVFoundation
#endif

// MARK: - Unified 3-in-1 Preview / Test / Simulation Stage (Web + iOS Simulator + Android Emulator)

public struct PreviewWorkbenchView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    @Environment(\.prismMotionTier) private var motionTier

    @Bindable public var browser: PrismBrowserController
    @Bindable public var devices: PrismDeviceController
    @Binding public var targetMode: PreviewTargetMode
    public let sessionId: String?
    public let agentDisplayName: String

    @State private var copiedToast: Bool = false

    public init(
        browser: PrismBrowserController,
        devices: PrismDeviceController,
        targetMode: Binding<PreviewTargetMode>,
        sessionId: String?,
        agentDisplayName: String
    ) {
        self.browser = browser
        self.devices = devices
        self._targetMode = targetMode
        self.sessionId = sessionId
        self.agentDisplayName = agentDisplayName
    }

    public var body: some View {
        VStack(spacing: 0) {
            unifiedTargetBar
            Rectangle().fill(tokens.borderEtched).frame(height: 1)

            Group {
                switch targetMode {
                case .web:
                    BrowserWorkbenchView(
                        browser: browser,
                        sessionId: sessionId,
                        agentDisplayName: agentDisplayName
                    )
                case .ios:
                    MobileDevicePreviewBody(
                        platform: .ios,
                        devices: devices,
                        sessionId: sessionId,
                        agentDisplayName: agentDisplayName,
                        copiedToast: $copiedToast
                    )
                case .android:
                    MobileDevicePreviewBody(
                        platform: .android,
                        devices: devices,
                        sessionId: sessionId,
                        agentDisplayName: agentDisplayName,
                        copiedToast: $copiedToast
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(tokens.surface1)
        .onAppear {
            markCurrentTargetSeen()
            if targetMode != .web {
                Task { await devices.ensureConnectedAndRefresh() }
            }
        }
        .onChange(of: targetMode) { _, next in
            markCurrentTargetSeen()
            if next != .web {
                Task { await devices.ensureConnectedAndRefresh() }
            } else {
                Task { await devices.handleMobileSurfaceHidden() }
            }
        }
        .onDisappear {
            Task { await devices.handleMobileSurfaceHidden() }
        }
    }

    private func markCurrentTargetSeen() {
        switch targetMode {
        case .web: browser.markSeen(sessionId: sessionId)
        case .ios: devices.markPlatformSeen(.ios)
        case .android: devices.markPlatformSeen(.android)
        }
    }

    private var unifiedTargetBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(PreviewTargetMode.allCases) { mode in
                    let selected = targetMode == mode
                    let hasDot = hasDot(for: mode)
                    Button {
                        withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier)) {
                            targetMode = mode
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: mode.iconName)
                                .font(.system(size: 10, weight: .medium))
                            Text(modeTitle(mode))
                                .font(.system(size: 11, weight: selected ? .semibold : .medium))
                            if hasDot && !selected {
                                Circle()
                                    .fill(tokens.primary)
                                    .frame(width: 5, height: 5)
                            }
                        }
                        .foregroundStyle(selected ? tokens.foreground : tokens.mutedForeground)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(Capsule().fill(selected ? tokens.surface2 : Color.clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(Capsule().fill(tokens.hoverWash))
            .overlay(Capsule().strokeBorder(tokens.borderEtched, lineWidth: 1))

            Spacer()

            if copiedToast {
                Text(l10n.tr("preview.device.screenshotCopied"))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(tokens.success)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(tokens.sidebar.opacity(0.65))
    }

    private func modeTitle(_ mode: PreviewTargetMode) -> String {
        switch mode {
        case .web: return l10n.tr("preview.target.web")
        case .ios: return l10n.tr("preview.target.ios")
        case .android: return l10n.tr("preview.target.android")
        }
    }

    private func hasDot(for mode: PreviewTargetMode) -> Bool {
        switch mode {
        case .web: return browser.hasUnseenActivity(for: sessionId)
        case .ios: return devices.hasActivity(for: .ios, sessionId: sessionId)
        case .android: return devices.hasActivity(for: .android, sessionId: sessionId)
        }
    }
}

// MARK: - iOS / Android Live Simulator & Emulator Surface

private struct MobileDevicePreviewBody: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    let platform: DevicePlatform
    @Bindable var devices: PrismDeviceController
    let sessionId: String?
    let agentDisplayName: String
    @Binding var copiedToast: Bool

    var body: some View {
        let list = devices.devices(for: platform)
        let active = devices.activeDevice(for: platform, sessionId: sessionId)
        let isHeldByThisSession = active != nil && sessionId != nil && active?.sessionId == sessionId

        VStack(spacing: 0) {
            if devices.daemonNeedsRestartForDevices {
                daemonRestartNotice
            } else if devices.isConnectingDeviceHost {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.regular)
                    Text(l10n.tr("preview.device.streamStarting"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokens.mutedForeground)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !devices.isConnected {
                disconnectedNotice
            } else {
                deviceToolbar(list: list, active: active, isHeldByThisSession: isHeldByThisSession)
                Rectangle().fill(tokens.borderEtched).frame(height: 1)

                if let banner = devices.statusBanner, !banner.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(tokens.warning)
                        Text(banner)
                            .font(.system(size: 11))
                            .foregroundStyle(tokens.foreground)
                            .lineLimit(2)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(tokens.warning.opacity(0.10))
                    Rectangle().fill(tokens.borderEtched).frame(height: 1)
                }

                if let sid = sessionId, let device = active, isHeldByThisSession {
                    liveDeviceStage(device: device, sessionId: sid)
                } else {
                    devicePickerEmptyState(list: list, active: active)
                }
            }
        }
        .onChange(of: active?.id) { _, _ in
            if let sid = sessionId, let dev = active, dev.sessionId == sid {
                Task { await devices.startWatching(deviceId: dev.id, sessionId: sid) }
            }
        }
        .onAppear {
            if let sid = sessionId, let dev = active, dev.sessionId == sid {
                Task { await devices.startWatching(deviceId: dev.id, sessionId: sid) }
            }
        }
        .onDisappear {
            Task { await devices.stopWatchingIfNeeded() }
        }
    }

    // MARK: - Compact Device Toolbar

    private func deviceToolbar(
        list: [MobileDeviceInfo],
        active: MobileDeviceInfo?,
        isHeldByThisSession: Bool
    ) -> some View {
        HStack(spacing: 6) {
            Menu {
                if list.isEmpty {
                    Text(platform == .ios
                         ? l10n.tr("preview.device.noneIos")
                         : l10n.tr("preview.device.noneAndroid"))
                } else {
                    ForEach(list) { dev in
                        Button {
                            devices.selectedDeviceIDByPlatform[platform] = dev.id
                            if let sid = sessionId, dev.sessionId == sid {
                                Task { await devices.startWatching(deviceId: dev.id, sessionId: sid) }
                            }
                        } label: {
                            let stateTag = dev.state == .booted || dev.state == .connected ? "● " : "○ "
                            let osTag = dev.osVersion.map { " (\($0))" } ?? ""
                            Text("\(stateTag)\(dev.name)\(osTag)")
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusDotColor(for: active))
                        .frame(width: 6.5, height: 6.5)
                    Text(active?.name ?? (platform == .ios ? "iOS Simulator" : "Android Emulator"))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(tokens.foreground)
                        .lineLimit(1)
                    if let os = active?.osVersion, !os.isEmpty {
                        Text(os)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(tokens.mutedForeground)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(tokens.placeholder)
                }
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).fill(tokens.surface2))
                .overlay(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).strokeBorder(tokens.borderEtched, lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            if let sid = sessionId, let dev = active, isHeldByThisSession {
                iconButton("rotate.right", help: l10n.tr("preview.device.rotate")) {
                    devices.sendInput(deviceId: dev.id, sessionId: sid, input: .button("rotate"))
                }
                iconButton(
                    devices.appearanceByDevice[dev.id] == .dark ? "sun.max" : "moon",
                    help: l10n.tr("preview.device.appearance")
                ) {
                    devices.toggleAppearance(deviceId: dev.id, sessionId: sid)
                }
                iconButton("camera", help: l10n.tr("preview.device.screenshot")) {
                    Task {
                        if await devices.captureScreenshotToClipboard(deviceId: dev.id, sessionId: sid) {
                            withAnimation(.easeOut(duration: 0.15)) { copiedToast = true }
                            try? await Task.sleep(for: .seconds(1.8))
                            withAnimation(.easeOut(duration: 0.2)) { copiedToast = false }
                        }
                    }
                }
                iconButton("power", help: l10n.tr("preview.device.close")) {
                    Task { await devices.closeDevice(dev, sessionId: sid, shutdown: false) }
                }
            } else if let sid = sessionId, let dev = active {
                let busy = devices.busyDeviceIDs.contains(dev.id)
                Button {
                    Task { await devices.openDevice(dev, sessionId: sid) }
                } label: {
                    HStack(spacing: 5) {
                        if busy {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9))
                        }
                        Text(busy ? l10n.tr("preview.device.booting") : l10n.tr("preview.device.bootAndConnect"))
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Capsule().fill(tokens.primary))
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }

            iconButton("arrow.clockwise", help: l10n.tr("preview.device.refresh")) {
                Task { await devices.refreshDevices() }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tokens.sidebar.opacity(0.45))
    }

    // MARK: - Live Hardware-Decoded Stage

    private func liveDeviceStage(device: MobileDeviceInfo, sessionId: String) -> some View {
        let screen = devices.screenByDevice[device.id]
        let rawSize: CGSize = {
            if let s = screen, s.width > 0, s.height > 0 {
                return CGSize(width: CGFloat(s.width), height: CGFloat(s.height))
            }
            return platform == .ios
                ? CGSize(width: 1179.0, height: 2556.0)
                : CGSize(width: 1080.0, height: 2400.0)
        }()
        // An iOS simulator keeps streaming a portrait framebuffer when rotated, so turn it
        // clockwise/counter-clockwise to match DeviceFrame and ios-simulator.ts rawPoint().
        let turnDegrees: CGFloat = {
            guard rawSize.width <= rawSize.height, let orientation = screen?.orientation else {
                return 0
            }
            switch orientation {
            case .landscapeLeft: return 90
            case .landscapeRight: return -90
            case .portraitUpsideDown: return 180
            case .portrait: return 0
            }
        }()
        let sideways = abs(turnDegrees) == 90
        let aspect: CGFloat = sideways
            ? (rawSize.height / rawSize.width)
            : (rawSize.width / rawSize.height)
        let op = device.operator
        let controlKind = op?.control?.kind
        let isAgentHolding = controlKind == "agent"
        let isUserHolding = controlKind == "you" || op?.user == true
        let streamState = devices.streamStateByDevice[device.id] ?? "starting"
        let streamError = devices.streamErrorByDevice[device.id]

        return VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                tokens.background.opacity(0.6)

                GeometryReader { geo in
                    let pad: CGFloat = 18
                    let bezelInset: CGFloat = 4
                    let pillReserve: CGFloat = (isAgentHolding || isUserHolding) ? 48 : 0
                    let maxScreenW = max(1, geo.size.width - pad * 2 - bezelInset * 2)
                    let maxScreenH = max(1, geo.size.height - pad * 2 - pillReserve - bezelInset * 2)
                    let screenW = min(maxScreenW, maxScreenH * aspect)
                    let screenH = screenW / aspect
                    let bezelW = screenW + bezelInset * 2
                    let bezelH = screenH + bezelInset * 2
                    let screenRadius = min(platform == .ios ? 24 : 16, min(screenW, screenH) * 0.11)
                    let bezelRadius = screenRadius + bezelInset

                    ZStack {
                        RoundedRectangle(cornerRadius: bezelRadius, style: .continuous)
                            .fill(Color.black)
                            .shadow(color: Color.black.opacity(0.45), radius: 22, y: 8)

                        #if os(macOS)
                        PrismDeviceVideoHost(
                            sink: devices.videoSink(for: device.id),
                            videoRevision: devices.videoRevision,
                            cornerRadius: screenRadius,
                            turnDegrees: turnDegrees,
                            holdsInput: isAgentHolding,
                            onInput: { action in
                                devices.sendInput(deviceId: device.id, sessionId: sessionId, input: action)
                            },
                            onHeldClick: {
                                devices.pulseHeld()
                            }
                        )
                        .frame(width: screenW, height: screenH)
                        .clipShape(RoundedRectangle(cornerRadius: screenRadius, style: .continuous))
                        #endif

                        // Live ripple showing where the Agent tapped
                        if let tap = devices.lastAgentTapByDevice[device.id] {
                            Circle()
                                .strokeBorder(tokens.primary, lineWidth: 2)
                                .background(Circle().fill(tokens.primary.opacity(0.28)))
                                .frame(width: 24, height: 24)
                                .position(
                                    x: bezelInset + CGFloat(tap.point.x) * screenW,
                                    y: bezelInset + CGFloat(tap.point.y) * screenH
                                )
                                .allowsHitTesting(false)
                                .transition(.scale.combined(with: .opacity))
                        }

                        // Loading / Error overlay before first frame arrives
                        #if os(macOS)
                        let sink = devices.videoSink(for: device.id)
                        if !sink.hasVideoFrame && sink.seedImage == nil {
                            VStack(spacing: 10) {
                                if streamState == "error", let err = streamError {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 20))
                                        .foregroundStyle(tokens.warning)
                                    Text(err)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Color.white.opacity(0.85))
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal, 16)
                                    Button(l10n.tr("preview.device.reconnect")) {
                                        Task {
                                            await devices.stopWatchingIfNeeded(deviceId: device.id)
                                            await devices.startWatching(deviceId: device.id, sessionId: sessionId)
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                } else {
                                    ProgressView().controlSize(.small)
                                    Text(l10n.tr("preview.device.connectingStream"))
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Color.white.opacity(0.75))
                                }
                            }
                        }
                        #endif
                    }
                    .frame(width: bezelW, height: bezelH)
                    .overlay(
                        RoundedRectangle(cornerRadius: bezelRadius, style: .continuous)
                            .strokeBorder(
                                isAgentHolding ? tokens.primary.opacity(0.85) : tokens.borderStrong,
                                lineWidth: isAgentHolding ? 2 : 1
                            )
                    )
                    .position(x: geo.size.width / 2, y: (geo.size.height - pillReserve) / 2)
                }

                // Floating Agent Control / Take Over / Hand Back pill
                if isAgentHolding {
                    controlPill(
                        dotColor: tokens.primary,
                        text: l10n.tr("browser.control.using", op?.agentName ?? agentDisplayName),
                        buttonLabel: l10n.tr("browser.control.takeOver"),
                        borderColor: tokens.primaryBorder
                    ) {
                        devices.takeOver(deviceId: device.id, sessionId: sessionId)
                    }
                    .padding(.bottom, 12)
                } else if isUserHolding {
                    controlPill(
                        dotColor: tokens.warning,
                        text: l10n.tr("browser.control.youHold"),
                        buttonLabel: l10n.tr("browser.control.handBack"),
                        borderColor: tokens.warning.opacity(0.55)
                    ) {
                        devices.handBack(deviceId: device.id, sessionId: sessionId)
                    }
                    .padding(.bottom, 12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            Rectangle().fill(tokens.borderEtched).frame(height: 1)

            // Hardware navigation bar (Back / Home / Recents / Lock)
            HStack(spacing: 14) {
                if platform == .android {
                    hardwareButton("chevron.backward", label: "Back") {
                        devices.sendInput(deviceId: device.id, sessionId: sessionId, input: .button("back"))
                    }
                }
                hardwareButton("house", label: "Home") {
                    devices.sendInput(deviceId: device.id, sessionId: sessionId, input: .button("home"))
                }
                hardwareButton("square.on.square", label: l10n.tr("preview.device.recents")) {
                    devices.sendInput(deviceId: device.id, sessionId: sessionId, input: .button("recents"))
                }
                hardwareButton("lock", label: l10n.tr("preview.device.lock")) {
                    devices.sendInput(deviceId: device.id, sessionId: sessionId, input: .button("lock"))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(tokens.sidebar.opacity(0.75))
        }
    }

    // MARK: - Empty / Setup / Restart States

    private func devicePickerEmptyState(list: [MobileDeviceInfo], active: MobileDeviceInfo?) -> some View {
        VStack(spacing: 14) {
            Spacer()

            ZStack {
                RoundedRectangle(cornerRadius: tokens.rMD, style: .continuous)
                    .fill(tokens.surface2)
                    .frame(width: 46, height: 46)
                    .overlay(
                        RoundedRectangle(cornerRadius: tokens.rMD, style: .continuous)
                            .strokeBorder(tokens.borderEtched, lineWidth: 1)
                    )
                Image(systemName: platform == .ios ? "iphone" : "candybarphone")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(tokens.primary)
            }

            if list.isEmpty {
                VStack(spacing: 5) {
                    Text(platform == .ios
                         ? l10n.tr("preview.device.noneIos")
                         : l10n.tr("preview.device.noneAndroid"))
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(tokens.foreground)
                    Text(platform == .ios
                         ? l10n.tr("preview.device.iosSetupHint")
                         : l10n.tr("preview.device.androidSetupHint"))
                        .font(.system(size: 12))
                        .foregroundStyle(tokens.mutedForeground)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                }
            } else {
                VStack(spacing: 5) {
                    Text(platform == .ios
                         ? l10n.tr("preview.device.readyIosTitle")
                         : l10n.tr("preview.device.readyAndroidTitle"))
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(tokens.foreground)
                    Text(l10n.tr("preview.device.readyHint", agentDisplayName))
                        .font(.system(size: 12))
                        .foregroundStyle(tokens.mutedForeground)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                }

                if let sid = sessionId, let dev = active {
                    let busy = devices.busyDeviceIDs.contains(dev.id)
                    Button {
                        Task { await devices.openDevice(dev, sessionId: sid) }
                    } label: {
                        HStack(spacing: 6) {
                            if busy {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "play.fill").font(.system(size: 10))
                            }
                            Text(busy
                                 ? l10n.tr("preview.device.booting")
                                 : "\(l10n.tr("preview.device.launchPrefix")) \(dev.name)")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(Capsule().fill(tokens.primary))
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                }
            }

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var daemonRestartNotice: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "arrow.triangle.2.circlepath.circle")
                .font(.system(size: 26))
                .foregroundStyle(tokens.primary)
            Text(l10n.tr("preview.device.daemonRestartTitle"))
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(tokens.foreground)
            Text(l10n.tr("preview.device.daemonRestartHint"))
                .font(.system(size: 12))
                .foregroundStyle(tokens.mutedForeground)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 310)
            if devices.canConnectLocal {
                Button(l10n.tr("preview.device.reconnect")) {
                    Task { await devices.ensureConnectedAndRefresh() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.top, 2)
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var disconnectedNotice: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 24))
                .foregroundStyle(tokens.mutedForeground)
            Text(l10n.tr("preview.device.offlineTitle"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tokens.foreground)
            Text(l10n.tr("preview.device.offlineHint"))
                .font(.system(size: 12))
                .foregroundStyle(tokens.mutedForeground)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            if devices.canConnectLocal {
                Button(l10n.tr("preview.device.reconnect")) {
                    Task { await devices.ensureConnectedAndRefresh() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.top, 2)
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Small UI Helpers

    private func statusDotColor(for device: MobileDeviceInfo?) -> Color {
        guard let device else { return tokens.placeholder }
        switch device.state {
        case .booted, .connected: return tokens.success
        case .booting: return tokens.warning
        case .shutdown, .unavailable: return tokens.placeholder
        }
    }

    private func iconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tokens.mutedForeground)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func hardwareButton(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .medium))
                Text(label)
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(tokens.secondaryForeground)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(tokens.hoverWash))
        }
        .buttonStyle(.plain)
    }

    private func controlPill(
        dotColor: Color,
        text: String,
        buttonLabel: String,
        borderColor: Color,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Circle().fill(dotColor).frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(tokens.foreground)
            Button(action: action) {
                Text(buttonLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(tokens.primary))
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(tokens.surface2.opacity(0.95))
                .shadow(color: Color.black.opacity(0.28), radius: 12, y: 4)
        )
        .overlay(Capsule().strokeBorder(borderColor, lineWidth: 1))
    }
}

// MARK: - Interactive macOS AVSampleBufferDisplayLayer Host View

#if os(macOS)
private struct PrismDeviceVideoHost: NSViewRepresentable {
    let sink: PrismDeviceVideoSink
    let videoRevision: Int
    let cornerRadius: CGFloat
    let turnDegrees: CGFloat
    let holdsInput: Bool
    let onInput: (DeviceInputAction) -> Void
    let onHeldClick: () -> Void

    func makeNSView(context: Context) -> PrismDeviceSurfaceNSView {
        let view = PrismDeviceSurfaceNSView(sink: sink)
        view.cornerRadius = cornerRadius
        view.turnDegrees = turnDegrees
        view.holdsInput = holdsInput
        view.onInput = onInput
        view.onHeldClick = onHeldClick
        return view
    }

    func updateNSView(_ nsView: PrismDeviceSurfaceNSView, context: Context) {
        nsView.attach(sink: sink)
        nsView.cornerRadius = cornerRadius
        nsView.turnDegrees = turnDegrees
        nsView.holdsInput = holdsInput
        nsView.onInput = onInput
        nsView.onHeldClick = onHeldClick
        nsView.refreshSeed()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: PrismDeviceSurfaceNSView,
        context: Context
    ) -> CGSize? {
        // Always fit SwiftUI's proposed screen frame so full-resolution seed screenshots
        // or video buffers never expand the representable beyond the device bezel.
        let fallback = CGSize(width: 240, height: 520)
        return CGSize(
            width: max(1, proposal.width ?? fallback.width),
            height: max(1, proposal.height ?? fallback.height)
        )
    }

    static func dismantleNSView(_ nsView: PrismDeviceSurfaceNSView, coordinator: ()) {
        nsView.detach()
    }
}

private final class PrismDeviceSurfaceNSView: NSView {
    private var sink: PrismDeviceVideoSink
    private let rootLayer = CALayer()
    private let seedLayer = CALayer()
    var cornerRadius: CGFloat = 24 {
        didSet {
            guard cornerRadius != oldValue else { return }
            syncLayerFrames()
        }
    }
    var turnDegrees: CGFloat = 0 {
        didSet {
            guard turnDegrees != oldValue else { return }
            syncLayerFrames()
        }
    }
    var holdsInput: Bool = false
    var onInput: ((DeviceInputAction) -> Void)?
    var onHeldClick: (() -> Void)?

    init(sink: PrismDeviceVideoSink) {
        self.sink = sink
        super.init(frame: .zero)
        rootLayer.backgroundColor = NSColor.black.cgColor
        rootLayer.masksToBounds = true
        rootLayer.cornerRadius = cornerRadius
        rootLayer.cornerCurve = .continuous
        // Layer-hosting NSView: assign backing layer before enabling wantsLayer so sublayers
        // (AVSampleBufferDisplayLayer + seedLayer) never trigger AppKit Auto Layout inflation.
        self.layer = rootLayer
        self.wantsLayer = true

        seedLayer.contentsGravity = .resizeAspect
        seedLayer.backgroundColor = NSColor.black.cgColor
        seedLayer.masksToBounds = true
        seedLayer.zPosition = 1
        rootLayer.addSublayer(seedLayer)

        attach(sink: sink)
        refreshSeed()
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLayerScales()
        syncLayerFrames()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateLayerScales()
    }

    func attach(sink next: PrismDeviceVideoSink) {
        if sink !== next {
            if sink.displayLayer.superlayer === rootLayer {
                sink.displayLayer.removeFromSuperlayer()
            }
            sink = next
        }
        if sink.displayLayer.superlayer !== rootLayer {
            sink.displayLayer.removeFromSuperlayer()
            sink.displayLayer.zPosition = 0
            rootLayer.insertSublayer(sink.displayLayer, at: 0)
        }
        updateLayerScales()
        syncLayerFrames()
    }

    func detach() {
        if sink.displayLayer.superlayer === rootLayer {
            sink.displayLayer.removeFromSuperlayer()
        }
        seedLayer.contents = nil
    }

    func refreshSeed() {
        let showSeed = !sink.hasVideoFrame && sink.seedImage != nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if showSeed, let img = sink.seedImage {
            seedLayer.contents = img.cgImage(forProposedRect: nil, context: nil, hints: nil) ?? img
            seedLayer.isHidden = false
        } else {
            seedLayer.contents = nil
            seedLayer.isHidden = true
        }
        CATransaction.commit()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncLayerFrames()
    }

    override func layout() {
        super.layout()
        syncLayerFrames()
    }

    private func updateLayerScales() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.contentsScale = scale
        seedLayer.contentsScale = scale
        sink.displayLayer.contentsScale = scale
        CATransaction.commit()
    }

    private func syncLayerFrames() {
        let viewBounds = bounds
        let sideways = abs(turnDegrees) == 90
        let contentBounds = CGRect(
            origin: .zero,
            size: sideways
                ? CGSize(width: viewBounds.height, height: viewBounds.width)
                : viewBounds.size
        )
        let center = CGPoint(x: viewBounds.midX, y: viewBounds.midY)
        // AppKit CALayer uses a bottom-left origin (+Z rotation is CCW), so negate clockwise degrees.
        let transform = turnDegrees == 0
            ? CATransform3DIdentity
            : CATransform3DMakeRotation(-turnDegrees * .pi / 180.0, 0, 0, 1)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.masksToBounds = true
        rootLayer.cornerRadius = cornerRadius
        rootLayer.cornerCurve = .continuous

        for sublayer in [sink.displayLayer as CALayer, seedLayer] {
            sublayer.transform = CATransform3DIdentity
            sublayer.bounds = contentBounds
            sublayer.position = center
            sublayer.transform = transform
        }
        CATransaction.commit()
    }

    private func normalizedPoint(for event: NSEvent) -> (x: Double, y: Double)? {
        let local = convert(event.locationInWindow, from: nil)
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let nx = max(0, min(1, Double(local.x / bounds.width)))
        // Flip Y from AppKit bottom-left origin to device top-left origin
        let ny = max(0, min(1, Double(1.0 - local.y / bounds.height)))
        return (nx, ny)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if holdsInput {
            onHeldClick?()
            return
        }
        guard let pt = normalizedPoint(for: event) else { return }
        onInput?(.touch(phase: "begin", x: pt.x, y: pt.y))
    }

    override func mouseDragged(with event: NSEvent) {
        guard !holdsInput, let pt = normalizedPoint(for: event) else { return }
        onInput?(.touch(phase: "move", x: pt.x, y: pt.y))
    }

    override func mouseUp(with event: NSEvent) {
        guard !holdsInput, let pt = normalizedPoint(for: event) else { return }
        onInput?(.touch(phase: "end", x: pt.x, y: pt.y))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let pt = normalizedPoint(for: event) else { return }
        onInput?(.scroll(
            x: pt.x,
            y: pt.y,
            dx: Double(-event.scrollingDeltaX),
            dy: Double(-event.scrollingDeltaY)
        ))
    }

    override func keyDown(with event: NSEvent) {
        if holdsInput {
            onHeldClick?()
            return
        }
        if let code = mappedSpecialKeyCode(event.keyCode) {
            onInput?(.key(phase: "down", code: code))
            onInput?(.key(phase: "up", code: code))
            return
        }
        if let chars = event.characters, !chars.isEmpty {
            onInput?(.text(chars))
        }
    }

    private func mappedSpecialKeyCode(_ keyCode: UInt16) -> String? {
        switch keyCode {
        case 36, 76: return "Enter"
        case 51: return "Backspace"
        case 117: return "Delete"
        case 48: return "Tab"
        case 53: return "Escape"
        case 126: return "ArrowUp"
        case 125: return "ArrowDown"
        case 123: return "ArrowLeft"
        case 124: return "ArrowRight"
        case 115: return "Home"
        case 119: return "End"
        case 116: return "PageUp"
        case 121: return "PageDown"
        default: return nil
        }
    }
}
#endif
