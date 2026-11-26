import Foundation
import SartoProtocol
import Observation
import SwiftUI
#if os(macOS)
import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
#endif

// MARK: - Unified Preview Target (Web / iOS / Android under one Workbench Entry)

public enum PreviewTargetMode: String, CaseIterable, Identifiable, Sendable {
    case web
    case ios
    case android

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .web: return "globe"
        case .ios: return "iphone"
        case .android: return "candybarphone"
        }
    }
}

// MARK: - Native VideoToolbox / AVSampleBufferDisplayLayer Decoder (macOS)

#if os(macOS)
/// Hardware-accelerated H.264 (`avcC`) and HEVC (`hvcC`) live frame decoder backed by
/// Apple's `AVSampleBufferDisplayLayer` (zero-copy Media Engine decoding).
@MainActor
public final class PrismDeviceVideoSink {
    public let displayLayer: AVSampleBufferDisplayLayer
    public var seedImage: NSImage? = nil
    public private(set) var hasVideoFrame: Bool = false
    public private(set) var videoSize: CGSize = CGSize(width: 1179, height: 2556)

    private var formatDescription: CMVideoFormatDescription? = nil
    private var lastDescriptionConfig: Data? = nil
    private var codecString: String = "avc1.640033"
    private var waitingForKeyframe: Bool = true
    private var frameIndex: Int64 = 0
    public var onFrameUpdated: (() -> Void)?

    public init() {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.clear.cgColor
        layer.masksToBounds = true
        self.displayLayer = layer
    }

    public func configure(screen: DeviceScreenInfo) {
        let codecChanged = self.codecString != screen.codec
        self.codecString = screen.codec
        var sizeChanged = false
        if screen.width > 0 && screen.height > 0 {
            let nextSize = CGSize(width: screen.width, height: screen.height)
            sizeChanged = self.videoSize != nextSize
            self.videoSize = nextSize
        }
        if let config = lastDescriptionConfig, codecChanged || (sizeChanged && !hasVideoFrame) {
            formatDescription = makeFormatDescription(config: config, codec: codecString, size: videoSize)
            if codecChanged {
                displayLayer.sampleBufferRenderer.flush()
                waitingForKeyframe = true
            }
        }
    }

    public func reset() {
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        formatDescription = nil
        lastDescriptionConfig = nil
        waitingForKeyframe = true
        hasVideoFrame = false
        seedImage = nil
        frameIndex = 0
        onFrameUpdated?()
    }

    public func push(kind: String, data: Data) {
        switch kind {
        case "seed":
            if let img = NSImage(data: data) {
                seedImage = img
                onFrameUpdated?()
            }

        case "description":
            lastDescriptionConfig = data
            formatDescription = makeFormatDescription(config: data, codec: codecString, size: videoSize)
            displayLayer.sampleBufferRenderer.flush()
            waitingForKeyframe = true

        case "key", "delta":
            let isKey = (kind == "key")
            if waitingForKeyframe {
                guard isKey else { return }
                waitingForKeyframe = false
            }
            guard let desc = formatDescription else { return }
            if displayLayer.sampleBufferRenderer.status == .failed {
                displayLayer.sampleBufferRenderer.flush()
                if !isKey {
                    waitingForKeyframe = true
                    return
                }
            }
            enqueueSample(data: data, formatDescription: desc, isKeyframe: isKey)

        default:
            break
        }
    }

    private func makeFormatDescription(config: Data, codec: String, size: CGSize) -> CMVideoFormatDescription? {
        let lower = codec.lowercased()
        let isHEVC = lower.hasPrefix("hvc1") || lower.hasPrefix("hev1")
        let codecType: CMVideoCodecType = isHEVC ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        let atomKey: CFString = (isHEVC ? "hvcC" : "avcC") as CFString

        let atoms: [CFString: Any] = [atomKey: config as CFData]
        let extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms as CFDictionary,
        ]
        var desc: CMVideoFormatDescription?
        let width = max(16, Int32(size.width))
        let height = max(16, Int32(size.height))
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            width: width,
            height: height,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &desc
        )
        return status == noErr ? desc : nil
    }

    private func enqueueSample(
        data: Data,
        formatDescription: CMVideoFormatDescription,
        isKeyframe: Bool
    ) {
        guard !data.isEmpty else { return }
        var blockBuffer: CMBlockBuffer?
        let length = data.count
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard createStatus == noErr, let blockBuffer else { return }

        let replaceStatus = data.withUnsafeBytes { rawBuf -> OSStatus in
            guard let base = rawBuf.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: length
            )
        }
        guard replaceStatus == noErr else { return }

        var sampleSize = length
        let pts = CMTime(value: frameIndex, timescale: 60)
        frameIndex += 1
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sampleBuffer else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
            if !isKeyframe {
                CFDictionarySetValue(
                    dict,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                )
            }
        }

        displayLayer.sampleBufferRenderer.enqueue(sampleBuffer)
        if !hasVideoFrame {
            hasVideoFrame = true
            onFrameUpdated?()
        }
    }
}
#endif

// MARK: - Mobile Device Stream & Control State Controller

@MainActor
@Observable
public final class PrismDeviceController {
    public private(set) var isConnected: Bool = false
    public private(set) var isConnectingDeviceHost: Bool = false
    public private(set) var daemonNeedsRestartForDevices: Bool = false
    public private(set) var environment: DeviceEnvironmentInfo? = nil
    public private(set) var devices: [MobileDeviceInfo] = []
    public var selectedDeviceIDByPlatform: [DevicePlatform: String] = [:]
    public private(set) var screenByDevice: [String: DeviceScreenInfo] = [:]
    public private(set) var streamStateByDevice: [String: String] = [:]
    public private(set) var streamErrorByDevice: [String: String] = [:]
    public private(set) var appearanceByDevice: [String: DeviceAppearance] = [:]
    public private(set) var frameByDevice: [String: DeviceFrameInfo] = [:]
    public private(set) var lastAgentTapByDevice: [String: (id: Int, point: DeviceActPoint)] = [:]
    public private(set) var busyDeviceIDs: Set<String> = []
    public private(set) var statusBanner: String? = nil
    public private(set) var unseenPlatforms: Set<DevicePlatform> = []
    public private(set) var heldPulseToken: Int = 0
    public private(set) var videoRevision: Int = 0

    @ObservationIgnored private var bridge: DeviceSessionBridge? = nil
    @ObservationIgnored private var localEventTask: Task<Void, Never>? = nil
    @ObservationIgnored private var lazyConnectTask: Task<Void, Never>? = nil
    @ObservationIgnored private var idleDetachTask: Task<Void, Never>? = nil
    @ObservationIgnored private var watchedDevice: (deviceId: String, sessionId: String)? = nil
    @ObservationIgnored private var lastAckedSeqByDevice: [String: Int] = [:]
    @ObservationIgnored private var tapRippleCounter: Int = 0
    @ObservationIgnored private var openTokenByDevice: [String: UInt64] = [:]
    @ObservationIgnored private var openTokenCounter: UInt64 = 0

    #if os(macOS)
    @ObservationIgnored private var videoSinks: [String: PrismDeviceVideoSink] = [:]
    #endif

    /// Lazy local `device-host` connector supplied by the macOS host app so `device-host` is never
    /// forked and `xcrun`/`adb` never polls while iOS/Android previews are unused.
    @ObservationIgnored public var onRequestLocalDeviceSession: (() async throws -> SartoDeviceSession)?

    /// Called when an agent opens a mobile device for a session so the Preview pane switches straight to it.
    @ObservationIgnored public var onAgentOpenedDevice: ((String, DevicePlatform, String) -> Void)?

    public var canConnectLocal: Bool {
        onRequestLocalDeviceSession != nil
    }

    public init() {}

    #if os(macOS)
    public func videoSink(for deviceId: String) -> PrismDeviceVideoSink {
        if let existing = videoSinks[deviceId] { return existing }
        let sink = PrismDeviceVideoSink()
        sink.onFrameUpdated = { [weak self] in
            self?.videoRevision &+= 1
        }
        videoSinks[deviceId] = sink
        return sink
    }
    #endif

    public func attach(localSession: SartoDeviceSession?) {
        resetBridgeState(cancelConnect: true)
        guard let localSession else {
            isConnected = false
            return
        }
        installLocalSession(localSession)
    }

    private func installLocalSession(_ localSession: SartoDeviceSession) {
        resetBridgeState(cancelConnect: false)
        daemonNeedsRestartForDevices = false
        bridge = .local(localSession)
        isConnected = true
        localEventTask = Task { [weak self] in
            for await event in localSession.events {
                guard let self, !Task.isCancelled else { break }
                self.handleEvent(event)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if case .local(let current) = self.bridge, current === localSession {
                    self.bridge = nil
                    self.isConnected = false
                }
            }
        }
    }

    public func attach(remoteHostSession: SartoHostSession?) {
        resetBridgeState(cancelConnect: true)
        guard let remoteHostSession else {
            isConnected = false
            return
        }
        daemonNeedsRestartForDevices = false
        bridge = .remote(remoteHostSession)
        isConnected = true
    }

    /// Ensures the lazy local `device-host` socket is connected (if in local mode) and refreshes
    /// the device list. Never called at startup — only when opening iOS/Android preview or when
    /// an agent invokes a `device_*` tool.
    public func ensureConnectedAndRefresh() async {
        idleDetachTask?.cancel()
        idleDetachTask = nil

        if bridge == nil, let connector = onRequestLocalDeviceSession {
            if let existing = lazyConnectTask {
                await existing.value
            } else {
                let task = Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isConnectingDeviceHost = true
                    self.daemonNeedsRestartForDevices = false
                    self.statusBanner = nil
                    defer { self.isConnectingDeviceHost = false }
                    do {
                        let session = try await connector()
                        guard !Task.isCancelled else {
                            await session.close()
                            return
                        }
                        self.installLocalSession(session)
                    } catch let rpcError as PortRPCError where rpcError.code == "invalid_params" {
                        self.resetBridgeState(cancelConnect: false)
                        self.daemonNeedsRestartForDevices = true
                    } catch {
                        self.statusBanner = error.localizedDescription
                    }
                }
                lazyConnectTask = task
                await task.value
                lazyConnectTask = nil
            }
        }

        if bridge != nil {
            await refreshDevices()
        }
    }

    /// Called when the user switches away from the iOS/Android tab or closes the Preview drawer.
    /// Immediately unsubscribes from live video frames, and after a brief idle grace period closes
    /// the local `device-host` socket if no session holds an active device — which stops the
    /// 5-second `xcrun`/`adb` background polling timer on the daemon side.
    public func handleMobileSurfaceHidden() async {
        await stopWatchingIfNeeded()
        guard case .local = bridge else { return }

        idleDetachTask?.cancel()
        idleDetachTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled else { return }
            guard self.watchedDevice == nil,
                  self.busyDeviceIDs.isEmpty,
                  !self.devices.contains(where: { $0.sessionId != nil }),
                  case .local(let localSession) = self.bridge
            else { return }
            self.localEventTask?.cancel()
            self.localEventTask = nil
            self.bridge = nil
            self.isConnected = false
            self.lastAckedSeqByDevice.removeAll()
            #if os(macOS)
            for (_, sink) in self.videoSinks { sink.reset() }
            self.videoSinks.removeAll()
            #endif
            await localSession.close()
        }
    }

    public func markDaemonNeedsRestart() {
        resetBridgeState(cancelConnect: true)
        daemonNeedsRestartForDevices = true
        isConnected = false
    }

    public func tearDown() {
        resetBridgeState(cancelConnect: true)
    }

    private func resetBridgeState(cancelConnect: Bool) {
        if cancelConnect {
            lazyConnectTask?.cancel()
            lazyConnectTask = nil
            isConnectingDeviceHost = false
        }
        idleDetachTask?.cancel()
        idleDetachTask = nil
        localEventTask?.cancel()
        localEventTask = nil
        let previousBridge = bridge
        bridge = nil
        isConnected = false
        watchedDevice = nil
        lastAckedSeqByDevice.removeAll()
        openTokenByDevice.removeAll()
        #if os(macOS)
        for (_, sink) in videoSinks { sink.reset() }
        videoSinks.removeAll()
        #endif
        if case .local(let localSession) = previousBridge {
            Task { await localSession.close() }
        }
    }

    public func markPlatformSeen(_ platform: DevicePlatform) {
        unseenPlatforms.remove(platform)
    }

    public func hasActivity(for platform: DevicePlatform, sessionId: String?) -> Bool {
        if unseenPlatforms.contains(platform) { return true }
        guard let sessionId else { return false }
        return devices.contains { $0.platform == platform && $0.sessionId == sessionId && $0.operator != nil }
    }

    public func hasAnyActivity(sessionId: String?) -> Bool {
        hasActivity(for: .ios, sessionId: sessionId) || hasActivity(for: .android, sessionId: sessionId)
    }

    public func devices(for platform: DevicePlatform) -> [MobileDeviceInfo] {
        devices.filter { $0.platform == platform }
    }

    public func activeDevice(for platform: DevicePlatform, sessionId: String?) -> MobileDeviceInfo? {
        let matching = devices(for: platform)
        if let sid = sessionId, let held = matching.first(where: { $0.sessionId == sid }) {
            return held
        }
        if let chosen = selectedDeviceIDByPlatform[platform],
           let found = matching.first(where: { $0.id == chosen }) {
            return found
        }
        if let booted = matching.first(where: { $0.state == .booted || $0.state == .connected }) {
            return booted
        }
        return matching.first
    }

    // MARK: - RPC Actions

    public func refreshDevices() async {
        guard let bridge else { return }
        do {
            async let env = bridge.environment()
            async let list = bridge.listDevices()
            self.environment = try? await env
            self.devices = try await list
            self.statusBanner = nil
        } catch {
            // Silently ignore if remote host doesn't run device-host; keep clean UI state
            if let rpcErr = error as? PortRPCError, rpcErr.code == "unknown_method" {
                self.isConnected = false
            }
        }
    }

    public func openDevice(_ device: MobileDeviceInfo, sessionId: String) async {
        guard let bridge else { return }
        openTokenCounter &+= 1
        let token = openTokenCounter
        openTokenByDevice[device.id] = token
        busyDeviceIDs.insert(device.id)
        streamErrorByDevice[device.id] = nil
        statusBanner = nil
        defer {
            if openTokenByDevice[device.id] == token {
                busyDeviceIDs.remove(device.id)
            }
        }
        do {
            let opened: MobileDeviceInfo
            if let holder = device.sessionId, holder != sessionId {
                opened = try await bridge.moveDevice(deviceId: device.id, sessionId: sessionId)
            } else {
                opened = try await bridge.openDevice(deviceId: device.id, sessionId: sessionId)
            }
            guard openTokenByDevice[device.id] == token else { return }
            upsertDevice(opened)
            selectedDeviceIDByPlatform[opened.platform] = opened.id
            await startWatching(deviceId: opened.id, sessionId: sessionId)
        } catch {
            if Self.isClosedWhileStarting(error) || openTokenByDevice[device.id] != token {
                return
            }
            streamErrorByDevice[device.id] = error.localizedDescription
            statusBanner = error.localizedDescription
        }
    }

    public func closeDevice(_ device: MobileDeviceInfo, sessionId: String, shutdown: Bool) async {
        guard let bridge else { return }
        openTokenByDevice.removeValue(forKey: device.id)
        busyDeviceIDs.insert(device.id)
        defer { busyDeviceIDs.remove(device.id) }
        await stopWatchingIfNeeded(deviceId: device.id)
        do {
            try await bridge.closeDevice(deviceId: device.id, sessionId: sessionId, shutdown: shutdown)
            #if os(macOS)
            videoSinks[device.id]?.reset()
            #endif
            await refreshDevices()
        } catch {
            statusBanner = error.localizedDescription
        }
    }

    /// Returns true when `devices.open` failed because the device was closed while booting.
    /// `device-host` sends code `unavailable` with `{ reason: "closed" }` and the localized
    /// `devices.closedWhileStarting` message; `PortRPCError` does not carry `data` yet, so we
    /// match the code and message until structured error data is decoded on `PortRPCError`.
    private static func isClosedWhileStarting(_ error: Error) -> Bool {
        guard let rpcError = error as? PortRPCError else { return false }
        if rpcError.code == "closed" { return true }
        if rpcError.data?.objectValue?["reason"]?.stringValue == "closed" { return true }
        guard rpcError.code == "unavailable" else { return false }
        let lower = rpcError.message.lowercased()
        return lower.contains("closed before it finished starting")
            || rpcError.message.contains("\u{542F}\u{52A8}\u{5B8C}\u{6210}\u{524D}\u{88AB}\u{5173}\u{95ED}")
    }

    public func startWatching(deviceId: String, sessionId: String) async {
        guard let bridge else { return }
        if let current = watchedDevice, current.deviceId == deviceId && current.sessionId == sessionId {
            return
        }
        if let prev = watchedDevice {
            watchedDevice = nil
            try? await bridge.unwatch(deviceId: prev.deviceId, sessionId: prev.sessionId)
        }
        watchedDevice = (deviceId: deviceId, sessionId: sessionId)
        streamStateByDevice[deviceId] = "starting"
        streamErrorByDevice[deviceId] = nil
        lastAckedSeqByDevice[deviceId] = 0
        do {
            if let screen = try await bridge.watch(deviceId: deviceId, sessionId: sessionId) {
                screenByDevice[deviceId] = screen
                #if os(macOS)
                videoSink(for: deviceId).configure(screen: screen)
                #endif
            }
            if let app = try? await bridge.appearance(deviceId: deviceId, sessionId: sessionId) {
                appearanceByDevice[deviceId] = app
            }
            if frameByDevice[deviceId] == nil,
               let frame = try? await bridge.frame(deviceId: deviceId, sessionId: sessionId) {
                frameByDevice[deviceId] = frame
            }
        } catch {
            streamStateByDevice[deviceId] = "error"
            streamErrorByDevice[deviceId] = error.localizedDescription
        }
    }

    public func stopWatchingIfNeeded(deviceId: String? = nil) async {
        guard let bridge, let current = watchedDevice else { return }
        if let deviceId, current.deviceId != deviceId { return }
        watchedDevice = nil
        try? await bridge.unwatch(deviceId: current.deviceId, sessionId: current.sessionId)
    }

    public func sendInput(deviceId: String, sessionId: String, input: DeviceInputAction) {
        guard let bridge else { return }
        Task {
            try? await bridge.sendInput(deviceId: deviceId, sessionId: sessionId, input: input)
        }
    }

    public func takeOver(deviceId: String, sessionId: String) {
        guard let bridge else { return }
        Task { try? await bridge.takeOver(deviceId: deviceId, sessionId: sessionId) }
    }

    public func handBack(deviceId: String, sessionId: String) {
        guard let bridge else { return }
        Task { try? await bridge.handBack(deviceId: deviceId, sessionId: sessionId) }
    }

    public func toggleAppearance(deviceId: String, sessionId: String) {
        guard let bridge else { return }
        let next: DeviceAppearance = (appearanceByDevice[deviceId] == .dark) ? .light : .dark
        appearanceByDevice[deviceId] = next
        Task {
            try? await bridge.setAppearance(deviceId: deviceId, sessionId: sessionId, appearance: next)
        }
    }

    public func captureScreenshotToClipboard(deviceId: String, sessionId: String) async -> Bool {
        guard let bridge else { return false }
        guard let pngData = try? await bridge.screenshot(deviceId: deviceId, sessionId: sessionId) else {
            return false
        }
        #if os(macOS)
        guard let image = NSImage(data: pngData) else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(pngData, forType: .png)
        pb.writeObjects([image])
        return true
        #else
        return !pngData.isEmpty
        #endif
    }

    public func pulseHeld() {
        heldPulseToken &+= 1
    }

    // MARK: - Event Handling

    public func handleEvent(_ event: DeviceEvent) {
        switch event {
        case .devicesChanged(let list):
            devices = list

        case .deviceScreen(let deviceId, let screen):
            screenByDevice[deviceId] = screen
            #if os(macOS)
            videoSink(for: deviceId).configure(screen: screen)
            #endif

        case .deviceFrame(let deviceId, let seq, let kind, let data):
            #if os(macOS)
            videoSink(for: deviceId).push(kind: kind, data: data)
            #endif
            if streamStateByDevice[deviceId] != "live" {
                streamStateByDevice[deviceId] = "live"
            }
            if let current = watchedDevice, current.deviceId == deviceId {
                let last = lastAckedSeqByDevice[deviceId] ?? 0
                if seq > last && (kind == "key" || seq - last >= 2) {
                    lastAckedSeqByDevice[deviceId] = seq
                    if let bridge {
                        Task { try? await bridge.ack(deviceId: deviceId, sessionId: current.sessionId, seq: seq) }
                    }
                }
            }

        case .deviceStream(let deviceId, let state, let error):
            streamStateByDevice[deviceId] = state
            streamErrorByDevice[deviceId] = error

        case .devicesRestarted:
            if let prev = watchedDevice {
                watchedDevice = nil
                Task {
                    await refreshDevices()
                    await startWatching(deviceId: prev.deviceId, sessionId: prev.sessionId)
                }
            } else {
                Task { await refreshDevices() }
            }

        case .deviceOpened(let deviceId, let sessionId):
            let platform: DevicePlatform = deviceId.hasPrefix("ios") ? .ios : .android
            selectedDeviceIDByPlatform[platform] = deviceId
            unseenPlatforms.insert(platform)
            onAgentOpenedDevice?(sessionId, platform, deviceId)
            Task {
                await refreshDevices()
                await startWatching(deviceId: deviceId, sessionId: sessionId)
            }

        case .deviceAct(let deviceId, let point):
            if let point {
                tapRippleCounter &+= 1
                let token = tapRippleCounter
                lastAgentTapByDevice[deviceId] = (id: token, point: point)
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(650))
                    if self?.lastAgentTapByDevice[deviceId]?.id == token {
                        self?.lastAgentTapByDevice.removeValue(forKey: deviceId)
                    }
                }
            }

        case .unknown:
            break
        }
    }

    private func upsertDevice(_ info: MobileDeviceInfo) {
        if let idx = devices.firstIndex(where: { $0.id == info.id }) {
            devices[idx] = info
        } else {
            devices.append(info)
        }
    }
}
