import Metal
import MetalKit
import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

// MARK: - 1. Standalone GPU Metal Volumetric Nebula & Bottom Horizon Aura (iOS & Lightweight Views)

public struct PrismHorizonView: View {
    public static let idlePreferredFPS: Int = 24

    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismMotionTier) private var motionTier
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var auraState: PrismAuraState
    public var bottomFocus: Bool
    public var intensity: Double

    public init(
        auraState: PrismAuraState = .idle,
        bottomFocus: Bool = false,
        intensity: Double = 1.0
    ) {
        self.auraState = auraState
        self.bottomFocus = bottomFocus
        self.intensity = intensity
    }

    public var body: some View {
        let motionActive = !reduceMotion && motionTier != .off
        let shouldAnimate: Bool = {
            guard motionActive else { return false }
            if !bottomFocus { return true }
            switch auraState {
            case .start, .running: return true
            case .idle, .waiting, .error, .completed: return false
            }
        }()

        let semanticCode = Self.semanticCode(for: auraState)
        let tierScale = Self.tierScale(for: motionTier)
        let targetFPS = Self.resolvedPreferredFPS(auraState: auraState, bottomFocus: bottomFocus)
        let engine = PrismMetalEngine.shared

        Group {
            if engine.cachedPipeline(for: .horizonAura, opaque: false) != nil {
                PrismMetalView(
                    kind: .horizonAura,
                    uniforms: PrismUniforms(
                        time: 2.4,
                        isDark: tokens.palette.isDark,
                        accent: tokens.shaderAccentCode,
                        params: SIMD4(Float(intensity) * tierScale, semanticCode, bottomFocus ? 1.0 : 0.0, 0)
                    ),
                    isAnimating: shouldAnimate,
                    preferredFPS: targetFPS,
                    activity: shouldAnimate ? Self.renderActivity(for: auraState) : .still
                )
            } else {
                fallback
                    .task { await engine.preparePipeline(for: .horizonAura, opaque: false) }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Drawn until the shader is built: a faint glow where the bottom aura sits, nothing for the nebula.
    private var fallback: some View {
        LinearGradient(
            colors: [tokens.prismCobalt.opacity(bottomFocus ? 0.10 * intensity : 0), Color.clear],
            startPoint: .bottom,
            endPoint: .center
        )
    }

    /// Steps idle ambient nebula down to 24fps while running active turns at native 60/120Hz.
    public static func resolvedPreferredFPS(
        auraState: PrismAuraState,
        bottomFocus: Bool,
        activeFPS: Int = 0
    ) -> Int {
        switch auraState {
        case .start, .running:
            return activeFPS
        case .idle, .waiting, .error, .completed:
            return bottomFocus ? activeFPS : idlePreferredFPS
        }
    }

    static func renderActivity(for state: PrismAuraState) -> PrismRenderActivity {
        switch state {
        case .start, .running: return .streaming
        case .idle, .waiting, .error, .completed: return .ambient
        }
    }

    static func semanticCode(for state: PrismAuraState) -> Float {
        switch state {
        case .idle, .running: return 0.0
        case .start: return 1.0
        case .waiting: return 2.0
        case .error: return 3.0
        case .completed: return 4.0
        }
    }

    static func tierScale(for tier: PrismMotionTier) -> Float {
        switch tier {
        case .off: return 0.5
        case .subtle: return 0.65
        case .standard: return 0.85
        case .ultra: return 1.0
        }
    }
}

// MARK: - 2. GPU Metal Interactive ASCII Ripple Sea + Nebula + Bottom Aura

@MainActor
final class AsciiWaveEngine {
    let cols: Int
    let rows: Int
    var height: [Float]
    var velocity: [Float]
    var cloudMask: [Float]
    var baseGlyph: [UInt8]
    var calmMask: [Float]

    private(set) var hasActiveWaves = false
    private(set) var gridDirty = true
    private var lastPointerCol = -1
    private var lastPointerRow = -1

    init(cols: Int = 96, rows: Int = 42) {
        self.cols = max(8, cols)
        self.rows = max(6, rows)
        let n = self.cols * self.rows
        self.height = [Float](repeating: 0, count: n)
        self.velocity = [Float](repeating: 0, count: n)
        self.cloudMask = [Float](repeating: 0, count: n)
        self.baseGlyph = [UInt8](repeating: 0, count: n)
        self.calmMask = [Float](repeating: 1, count: n)
        precomputeStaticFields()
    }

    private static func valueNoise(_ x: Float, _ y: Float) -> Float {
        let ix = floor(x), iy = floor(y)
        let fx = x - ix, fy = y - iy
        let ux = fx * fx * (3 - 2 * fx)
        let uy = fy * fy * (3 - 2 * fy)
        func h(_ a: Float, _ b: Float) -> Float {
            let v = sin(a * 127.1 + b * 311.7) * 43758.5453
            return v - floor(v)
        }
        let a = h(ix, iy), b = h(ix + 1, iy), c = h(ix, iy + 1), d = h(ix + 1, iy + 1)
        return a + (b - a) * ux + (c - a) * uy + (a - b - c + d) * ux * uy
    }

    private static func fbm(_ x: Float, _ y: Float) -> Float {
        valueNoise(x, y) * 0.55
            + valueNoise(x * 2.03 + 11.4, y * 2.03 + 7.2) * 0.30
            + valueNoise(x * 4.1 + 3.1, y * 4.1 + 19.7) * 0.15
    }

    private func precomputeStaticFields() {
        let fc = Float(cols), fr = Float(rows)
        let glyphCount = PrismMetalEngine.asciiGlyphChars.count
        for r in 0..<rows {
            let ry = Float(r) / max(1, fr - 1)
            let edgeY = smoothstep(0.0, 0.12, min(ry, 1.0 - ry))
            for c in 0..<cols {
                let idx = r * cols + c
                let rx = Float(c) / max(1, fc - 1)
                let edgeX = smoothstep(0.0, 0.08, min(rx, 1.0 - rx))
                let cloud = Self.fbm(Float(c) * 0.085 + 2.3, Float(r) * 0.14 + 1.7)
                cloudMask[idx] = smoothstep(0.30, 0.72, cloud) * edgeX * edgeY

                let dx = (rx - 0.5) / 0.34
                let dy = (ry - 0.50) / 0.30
                calmMask[idx] = 0.22 + 0.78 * smoothstep(0.55, 1.25, sqrt(dx * dx + dy * dy))

                let gHash = Int(Self.valueNoise(Float(c) * 1.73, Float(r) * 2.91) * Float(glyphCount))
                baseGlyph[idx] = UInt8(max(0, min(glyphCount - 1, gHash)))
            }
        }
        gridDirty = true
    }

    func disturb(col: Int, row: Int, strength: Float = 1.0, radius: Int = 3) {
        guard col >= 0, col < cols, row >= 0, row < rows else { return }
        let r0 = max(1, row - radius), r1 = min(rows - 2, row + radius)
        let c0 = max(1, col - radius), c1 = min(cols - 2, col + radius)
        let rf = Float(max(1, radius))
        let stride = cols
        velocity.withUnsafeMutableBufferPointer { vBuf in
            for r in r0...r1 {
                let rowOff = r * stride
                for c in c0...c1 {
                    let dx = Float(c - col) / rf, dy = Float(r - row) / rf
                    let d2 = dx * dx + dy * dy
                    if d2 < 1.0 {
                        let w = (1.0 - d2) * (1.0 - d2)
                        vBuf[rowOff + c] += strength * w * 14.0
                    }
                }
            }
        }
        hasActiveWaves = true
        gridDirty = true
    }

    func disturbWake(col: Int, row: Int) {
        if col == lastPointerCol && row == lastPointerRow { return }
        lastPointerCol = col
        lastPointerRow = row
        disturb(col: col, row: row, strength: 0.78, radius: 2)
    }

    func triggerLiftoffBurst(normX: Float = 0.5, normY: Float = 0.72) {
        let col = max(2, min(cols - 3, Int(normX * Float(cols - 1))))
        let row = max(2, min(rows - 3, Int(normY * Float(rows - 1))))
        disturb(col: col, row: row, strength: 2.35, radius: 5)
    }

    /// Flattens the sea at once, for when motion stops and the static frame must not show a frozen ripple.
    func reset() {
        guard hasActiveWaves else { return }
        for i in 0..<height.count {
            height[i] = 0
            velocity[i] = 0
        }
        hasActiveWaves = false
        gridDirty = true
    }

    func step(dt rawDt: Float) {
        guard hasActiveWaves, rawDt.isFinite, rawDt > 0 else { return }
        let dt = min(0.020, max(0.002, rawDt))
        let c2: Float = 26.0
        let damping: Float = 2.45
        let stride = cols
        let rowEnd = rows - 1
        let colEnd = cols - 1
        var maxEnergy: Float = 0

        height.withUnsafeMutableBufferPointer { hBuf in
            velocity.withUnsafeMutableBufferPointer { vBuf in
                for r in 1..<rowEnd {
                    let rowOff = r * stride
                    for c in 1..<colEnd {
                        let idx = rowOff + c
                        let hCenter = hBuf[idx]
                        let lap = (hBuf[idx - 1] + hBuf[idx + 1] + hBuf[idx - stride] + hBuf[idx + stride]) * 0.25 - hCenter
                        vBuf[idx] += (c2 * lap - damping * vBuf[idx] - 1.2 * hCenter) * dt
                    }
                }
                for r in 1..<rowEnd {
                    let rowOff = r * stride
                    for c in 1..<colEnd {
                        let idx = rowOff + c
                        let v = vBuf[idx]
                        var nextH = hBuf[idx] + v * dt
                        if nextH > 2.5 { nextH = 2.5 }
                        else if nextH < -2.5 { nextH = -2.5 }
                        hBuf[idx] = nextH
                        let eH = abs(nextH)
                        let eV = abs(v) * 0.08
                        if eH > maxEnergy { maxEnergy = eH }
                        if eV > maxEnergy { maxEnergy = eV }
                    }
                }
                if maxEnergy < 0.012 {
                    for i in 0..<hBuf.count {
                        hBuf[i] = 0
                        vBuf[i] = 0
                    }
                }
            }
        }
        gridDirty = true
        if maxEnergy < 0.012 {
            hasActiveWaves = false
        }
    }

    /// Packs static channels once and only refreshes byte 0 (wave height) on active ticks.
    func packRGBA8(into out: inout [UInt8]) {
        let count = cols * rows
        let needsInit = out.count != count * 4
        if needsInit {
            out = [UInt8](repeating: 0, count: count * 4)
        }
        height.withUnsafeBufferPointer { hBuf in
            out.withUnsafeMutableBufferPointer { oBuf in
                if needsInit {
                    for i in 0..<count {
                        let base = i * 4
                        let hNorm = max(0.0, min(1.0, hBuf[i] * 0.2 + 0.5))
                        oBuf[base] = UInt8(hNorm * 255.0)
                        oBuf[base + 1] = UInt8(max(0.0, min(1.0, cloudMask[i])) * 255.0)
                        oBuf[base + 2] = baseGlyph[i]
                        oBuf[base + 3] = UInt8(max(0.0, min(1.0, calmMask[i])) * 255.0)
                    }
                } else {
                    for i in 0..<count {
                        let hNorm = max(0.0, min(1.0, hBuf[i] * 0.2 + 0.5))
                        oBuf[i * 4] = UInt8(hNorm * 255.0)
                    }
                }
            }
        }
        gridDirty = false
    }

    private func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - e0) / max(1e-5, e1 - e0)))
        return t * t * (3 - 2 * t)
    }
}

#if os(macOS)
@MainActor
final class StageBackdropCoordinator: NSObject, MTKViewDelegate {
    /// The nebula is soft enough to shade at 1/6 of the drawable size and upsample bilinearly.
    static let nebulaDownsample = 6
    static let maxFramesInFlight = 3
    static let pointerWakeDuration: CFTimeInterval = 0.65

    let waveEngine = AsciiWaveEngine(cols: 96, rows: 42)
    private let commandQueue: MTLCommandQueue?
    /// One cell texture per frame in flight, so a CPU upload never lands in a texture the GPU still reads.
    private var cellTextures: [MTLTexture] = []
    private var cellTextureVersions: [Int] = []
    private var cellBytes: [UInt8] = []
    private var gridVersion = 0
    private var frameIndex = 0
    private let framesInFlight = DispatchSemaphore(value: 3)
    private var nebulaTexture: MTLTexture?

    var isDark: Bool = true
    var bgRGB: SIMD3<Float> = PrismPalette.obsidian.backgroundRGB
    var accentCode: Float = 0
    var nebulaIntensity: Float = 1.0
    var asciiIntensity: Float = 1.0
    var bottomAuraIntensity: Float = 0.0
    var semanticMode: Float = 0.0
    var calmCenter: Bool = true
    private(set) var motionActive: Bool = true
    var interactiveRipples: Bool = true
    var isStreamingActivity: Bool = false
    var lastLiftoffToken: Int = 0
    private var lastStaticRenderSignature: Int = 0

    private var pointerPos: CGPoint = CGPoint(x: -9999, y: -9999)
    private var pointerAlpha: Float = 0.0
    private var pointerWakeUntil: CFTimeInterval = 0
    /// Unwrapped animation time in seconds; wrapped only when handed to the shader.
    private var animationTime: Double = 2.4
    private var lastDrawTime: CFTimeInterval?

    weak var attachedView: MTKView?
    private weak var observedWindow: NSWindow?
    nonisolated(unsafe) private var windowObservers: [NSObjectProtocol] = []
    nonisolated(unsafe) private var energyObserver: NSObjectProtocol?
    nonisolated(unsafe) private var mouseMonitor: Any?

    override init() {
        self.commandQueue = PrismMetalEngine.shared.commandQueue
        super.init()
        if let dev = PrismMetalEngine.shared.device {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: waveEngine.cols,
                height: waveEngine.rows,
                mipmapped: false
            )
            desc.usage = .shaderRead
            for _ in 0..<Self.maxFramesInFlight {
                if let tex = dev.makeTexture(descriptor: desc) {
                    cellTextures.append(tex)
                }
            }
            cellTextureVersions = Array(repeating: -1, count: cellTextures.count)
        }
        waveEngine.disturb(col: waveEngine.cols / 3, row: waveEngine.rows / 3, strength: 0.9, radius: 4)
        waveEngine.disturb(col: (waveEngine.cols * 3) / 4, row: (waveEngine.rows * 2) / 3, strength: 0.85, radius: 4)
    }

    deinit {
        for token in windowObservers {
            NotificationCenter.default.removeObserver(token)
        }
        if let energyObserver {
            NotificationCenter.default.removeObserver(energyObserver)
        }
        if let mouseMonitor {
            DispatchQueue.main.async {
                NSEvent.removeMonitor(mouseMonitor)
            }
        }
    }

    func setMotionActive(_ active: Bool) {
        guard motionActive != active else { return }
        motionActive = active
        lastDrawTime = active ? CACurrentMediaTime() : nil
    }

    private var isPointerAwake: Bool {
        CACurrentMediaTime() < pointerWakeUntil
    }

    /// Pointer ripples run only on the interactive stage, with the ASCII layer visible and power to spare.
    private var wantsPointer: Bool {
        motionActive
            && interactiveRipples
            && asciiIntensity > 0.005
            && !PrismEnergyMonitor.shared.conditions.isConstrained
    }

    var renderActivity: PrismRenderActivity {
        PrismEnergyPolicy.stageBackdropActivity(
            motionActive: motionActive,
            interactiveRipples: interactiveRipples,
            hasActiveWaves: waveEngine.hasActiveWaves,
            pointerAwake: isPointerAwake,
            isStreaming: isStreamingActivity
        )
    }

    func computeStaticSignature() -> Int {
        var hasher = Hasher()
        hasher.combine(isDark)
        hasher.combine(bgRGB.x)
        hasher.combine(bgRGB.y)
        hasher.combine(bgRGB.z)
        hasher.combine(accentCode)
        hasher.combine(nebulaIntensity)
        hasher.combine(asciiIntensity)
        hasher.combine(bottomAuraIntensity)
        hasher.combine(semanticMode)
        hasher.combine(calmCenter)
        return hasher.finalize()
    }

    func attach(to view: MTKView) {
        attachedView = view

        if observedWindow !== view.window {
            for token in windowObservers {
                NotificationCenter.default.removeObserver(token)
            }
            windowObservers.removeAll()
            observedWindow = view.window

            if let win = view.window {
                let screenToken = NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeScreenNotification,
                    object: win,
                    queue: .main
                ) { [weak self, weak view] _ in
                    Task { @MainActor [weak self, weak view] in
                        guard let self, let view else { return }
                        self.syncRenderMode(for: view)
                    }
                }
                windowObservers.append(screenToken)

                let occlusionToken = NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeOcclusionStateNotification,
                    object: win,
                    queue: .main
                ) { [weak self, weak view] _ in
                    Task { @MainActor [weak self, weak view] in
                        guard let self, let view else { return }
                        self.syncRenderMode(for: view)
                    }
                }
                windowObservers.append(occlusionToken)
            }
        }

        if energyObserver == nil {
            energyObserver = NotificationCenter.default.addObserver(
                forName: PrismEnergyMonitor.conditionsDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let view = self.attachedView else { return }
                    self.syncRenderMode(for: view, forceRedraw: true)
                }
            }
        }

        syncRenderMode(for: view)
    }

    func detach() {
        for token in windowObservers {
            NotificationCenter.default.removeObserver(token)
        }
        windowObservers.removeAll()
        observedWindow = nil
        if let energyObserver {
            NotificationCenter.default.removeObserver(energyObserver)
            self.energyObserver = nil
        }
        removeMouseMonitor()
        attachedView = nil
    }

    func canRender(in view: MTKView) -> Bool {
        guard let win = view.window, win.isVisible, win.occlusionState.contains(.visible) else {
            return false
        }
        return true
    }

    /// Picks continuous drawing at the policy rate or on-demand drawing, and keeps the pointer monitor in step.
    func syncRenderMode(for view: MTKView, forceRedraw: Bool = false) {
        var redraw = forceRedraw
        if !motionActive || PrismEnergyMonitor.shared.conditions.isConstrained {
            if waveEngine.hasActiveWaves {
                waveEngine.reset()
                redraw = true
            }
        }
        updateMouseMonitor()

        guard canRender(in: view) else {
            view.isPaused = true
            return
        }
        let fps = PrismEnergyPolicy.framesPerSecond(
            for: renderActivity,
            surface: .fullWindow,
            displayMaxFPS: PrismDisplayRefresh.maxFPS(for: view.window),
            conditions: PrismEnergyMonitor.shared.conditions
        )
        if fps > 0 {
            if view.preferredFramesPerSecond != fps {
                view.preferredFramesPerSecond = fps
            }
            if view.isPaused {
                lastDrawTime = CACurrentMediaTime()
            }
            view.enableSetNeedsDisplay = false
            view.isPaused = false
        } else {
            view.isPaused = true
            view.enableSetNeedsDisplay = true
            let sig = computeStaticSignature()
            if redraw || sig != lastStaticRenderSignature {
                lastStaticRenderSignature = sig
                view.needsDisplay = true
            }
        }
    }

    private func updateMouseMonitor() {
        guard wantsPointer, attachedView?.window != nil else {
            removeMouseMonitor()
            return
        }
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] event in
            self?.handleMouseEvent(event)
            return event
        }
    }

    private func removeMouseMonitor() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        pointerAlpha = 0
        pointerPos = CGPoint(x: -9999, y: -9999)
        pointerWakeUntil = 0
    }

    private func handleMouseEvent(_ event: NSEvent) {
        guard wantsPointer,
              let view = attachedView,
              let win = view.window,
              event.window === win,
              win.isVisible,
              win.occlusionState.contains(.visible)
        else { return }
        let local = view.convert(event.locationInWindow, from: nil)
        let bounds = view.bounds
        guard bounds.width > 10, bounds.height > 10 else { return }
        if bounds.contains(local) {
            let yTop = view.isFlipped ? local.y : (bounds.height - local.y)
            pointerPos = CGPoint(x: local.x, y: yTop)
            pointerAlpha = 1.0
            pointerWakeUntil = CACurrentMediaTime() + Self.pointerWakeDuration
            let col = Int((local.x / bounds.width) * CGFloat(waveEngine.cols))
            let row = Int((yTop / bounds.height) * CGFloat(waveEngine.rows))
            if event.type == .leftMouseDown {
                waveEngine.disturb(col: col, row: row, strength: 1.85, radius: 4)
            } else {
                waveEngine.disturbWake(col: col, row: row)
            }
            syncRenderMode(for: view)
        } else if pointerAlpha > 0 {
            pointerAlpha = 0.0
            pointerPos = CGPoint(x: -9999, y: -9999)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        if view.isPaused && view.enableSetNeedsDisplay && canRender(in: view) {
            view.needsDisplay = true
        }
    }

    func draw(in view: MTKView) {
        guard canRender(in: view) else {
            view.isPaused = true
            return
        }
        guard view.bounds.width > 0 && view.bounds.height > 0 else { return }

        let now = CACurrentMediaTime()
        let running = !view.isPaused
        var dt = 0.0
        if let prev = lastDrawTime {
            let raw = now - prev
            dt = raw.isFinite ? min(PrismMetalCoordinator.maxClockStep, max(0.0, raw)) : 0.0
        }
        lastDrawTime = now

        // On-demand redraws of a paused backdrop keep the clock and the sea still.
        if running && motionActive {
            animationTime += dt
            stepWaves(dt: dt)
        }

        encodeFrame(in: view)

        if running {
            syncRenderMode(for: view)
        }
    }

    /// Substeps the wave solver so ripples keep their speed at any frame rate.
    private func stepWaves(dt: Double) {
        guard waveEngine.hasActiveWaves else { return }
        var remaining = Float(min(dt, 0.1))
        var steps = 0
        while remaining > 0.001 && steps < 6 && waveEngine.hasActiveWaves {
            let slice = min(remaining, 1.0 / 60.0)
            waveEngine.step(dt: slice)
            remaining -= slice
            steps += 1
        }
    }

    private func nebulaTarget(device: MTLDevice, drawableSize: CGSize) -> MTLTexture? {
        let divisor = CGFloat(Self.nebulaDownsample)
        let width = max(1, Int((drawableSize.width / divisor).rounded(.up)))
        let height = max(1, Int((drawableSize.height / divisor).rounded(.up)))
        if let tex = nebulaTexture, tex.width == width, tex.height == height {
            return tex
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: PrismMetalEngine.asciiNebulaPixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        nebulaTexture = device.makeTexture(descriptor: desc)
        return nebulaTexture
    }

    private func encodeFrame(in view: MTKView) {
        let engine = PrismMetalEngine.shared
        let isOpaquePass = view.clearColor.alpha >= 1.0
        guard let pipeline = engine.pipeline(for: .asciiSea, opaque: isOpaquePass),
              let nebulaPipeline = engine.pipeline(.asciiNebula),
              let atlas = engine.glyphAtlasTexture,
              let device = engine.device,
              let queue = commandQueue,
              cellTextures.count == Self.maxFramesInFlight
        else { return }

        // Bounds frames in flight to the cell texture ring; drop the frame immediately rather than stall the main thread.
        guard framesInFlight.wait(timeout: .now()) == .success else { return }
        var committed = false
        defer {
            if !committed {
                framesInFlight.signal()
            }
        }

        guard let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let nebulaTarget = nebulaTarget(device: device, drawableSize: view.drawableSize),
              let cmd = queue.makeCommandBuffer()
        else { return }

        // Slot `frameIndex % 3` was last read by frame `frameIndex - 3`, which the semaphore says has completed.
        let slot = frameIndex % cellTextures.count
        let cellTexture = cellTextures[slot]
        if waveEngine.gridDirty {
            waveEngine.packRGBA8(into: &cellBytes)
            gridVersion &+= 1
        }
        if cellTextureVersions[slot] != gridVersion {
            cellTexture.replace(
                region: MTLRegionMake2D(0, 0, waveEngine.cols, waveEngine.rows),
                mipmapLevel: 0,
                withBytes: cellBytes,
                bytesPerRow: waveEngine.cols * 4
            )
            cellTextureVersions[slot] = gridVersion
        }

        var uniforms = PrismUniforms(
            size: view.bounds.size,
            time: Float(PrismMetalCoordinator.wrapShaderTime(animationTime)),
            isDark: isDark,
            pointer: pointerPos,
            pointerAlpha: pointerAlpha,
            accent: accentCode,
            params: SIMD4(nebulaIntensity, asciiIntensity, bottomAuraIntensity, semanticMode),
            extra: SIMD4(
                Float(waveEngine.cols),
                Float(waveEngine.rows),
                calmCenter ? 1.0 : 0.0,
                Float(PrismMetalEngine.asciiGlyphChars.count)
            )
        )
        uniforms.wave0 = SIMD4(bgRGB.x, bgRGB.y, bgRGB.z, 1.0)
        PrismNebulaLobes.write(time: animationTime, into: &uniforms)

        let nebulaPass = MTLRenderPassDescriptor()
        nebulaPass.colorAttachments[0].texture = nebulaTarget
        nebulaPass.colorAttachments[0].loadAction = .dontCare
        nebulaPass.colorAttachments[0].storeAction = .store
        guard let nebulaEncoder = cmd.makeRenderCommandEncoder(descriptor: nebulaPass) else { return }
        nebulaEncoder.setRenderPipelineState(nebulaPipeline)
        nebulaEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<PrismUniforms>.stride, index: 0)
        nebulaEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        nebulaEncoder.endEncoding()

        if isOpaquePass {
            rpd.colorAttachments[0].loadAction = .dontCare
        }
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<PrismUniforms>.stride, index: 0)
        enc.setFragmentTexture(atlas, index: 0)
        enc.setFragmentTexture(cellTexture, index: 1)
        enc.setFragmentTexture(nebulaTarget, index: 2)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()

        let semaphore = framesInFlight
        cmd.addCompletedHandler { @Sendable _ in
            semaphore.signal()
        }
        cmd.present(drawable)
        cmd.commit()
        committed = true
        frameIndex &+= 1
    }
}

private struct StageBackdropMetalRepresentable: NSViewRepresentable {
    let isDark: Bool
    let bgRGB: SIMD3<Float>
    let accentCode: Float
    let nebulaIntensity: Float
    let asciiIntensity: Float
    let bottomAuraIntensity: Float
    let semanticMode: Float
    let calmCenter: Bool
    let motionActive: Bool
    let interactiveRipples: Bool
    let isStreamingActivity: Bool
    let liftoffToken: Int

    func makeCoordinator() -> StageBackdropCoordinator {
        StageBackdropCoordinator()
    }

    func makeNSView(context: Context) -> MTKView {
        let view = NonInteractiveMTKView(frame: .zero, device: PrismMetalEngine.shared.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: Double(bgRGB.x), green: Double(bgRGB.y), blue: Double(bgRGB.z), alpha: 1.0)
        view.framebufferOnly = true
        // Glyphs stay sharp at 1.5x; the nebula, the costly part, renders at 1/6 of this in its own pass.
        view.autoResizeDrawable = false
        view.maxBackingScale = 1.5
        view.wantsLayer = true
        view.layer?.isOpaque = true
        prismConfigureMetalLayer(of: view)
        view.preferredFramesPerSecond = PrismEnergyPolicy.ambientFPS
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = context.coordinator
        view.onWindowAttached = { [weak coord = context.coordinator] attached in
            coord?.attach(to: attached)
        }
        context.coordinator.lastLiftoffToken = liftoffToken
        applyProps(to: context.coordinator)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        let coord = context.coordinator
        applyProps(to: coord)
        nsView.clearColor = MTLClearColor(red: Double(bgRGB.x), green: Double(bgRGB.y), blue: Double(bgRGB.z), alpha: 1.0)
        if liftoffToken != coord.lastLiftoffToken {
            coord.lastLiftoffToken = liftoffToken
            if motionActive && !PrismEnergyMonitor.shared.conditions.isConstrained {
                coord.waveEngine.triggerLiftoffBurst()
            }
        }
        coord.syncRenderMode(for: nsView)
    }

    static func dismantleNSView(_ nsView: MTKView, coordinator: StageBackdropCoordinator) {
        nsView.isPaused = true
        coordinator.detach()
    }

    private func applyProps(to coord: StageBackdropCoordinator) {
        coord.isDark = isDark
        coord.bgRGB = bgRGB
        coord.accentCode = accentCode
        coord.nebulaIntensity = nebulaIntensity
        coord.asciiIntensity = asciiIntensity
        coord.bottomAuraIntensity = bottomAuraIntensity
        coord.semanticMode = semanticMode
        coord.calmCenter = calmCenter
        coord.interactiveRipples = interactiveRipples
        coord.isStreamingActivity = isStreamingActivity
        coord.setMotionActive(motionActive)
    }
}
#endif

/// Full-stage Obsidian Prism backdrop: volumetric 3-lobe nebula, 4,032-cell interactive ASCII ripple sea
/// and conversation bottom aura. Draws at the rate `PrismEnergyPolicy` allows and pauses entirely in
/// Low Power Mode, at a serious thermal state, or with Reduce Motion on.
public struct AsciiRippleSeaView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismMotionTier) private var motionTier
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var calmCenter: Bool
    public var liftoffToken: Int
    public var intensity: Double
    public var bottomAuraState: PrismAuraState?
    public var interactiveRipples: Bool

    public init(
        calmCenter: Bool = true,
        liftoffToken: Int = 0,
        intensity: Double = 1.0,
        bottomAuraState: PrismAuraState? = nil,
        interactiveRipples: Bool = true
    ) {
        self.calmCenter = calmCenter
        self.liftoffToken = liftoffToken
        self.intensity = intensity
        self.bottomAuraState = bottomAuraState
        self.interactiveRipples = interactiveRipples
    }

    public var body: some View {
        #if os(macOS)
        let motionActive = !reduceMotion && motionTier != .off
        let tierScale = PrismHorizonView.tierScale(for: motionTier)
        let semanticCode = bottomAuraState.map { PrismHorizonView.semanticCode(for: $0) } ?? 0.0
        let bottomIntensity: Float = bottomAuraState != nil ? tierScale : 0.0
        let isStreamingActivity = (bottomAuraState == .start || bottomAuraState == .running)
        let engine = PrismMetalEngine.shared

        Group {
            if engine.stageBackdropReady {
                StageBackdropMetalRepresentable(
                    isDark: tokens.palette.isDark,
                    bgRGB: tokens.palette.backgroundRGB,
                    accentCode: tokens.shaderAccentCode,
                    nebulaIntensity: Float(intensity) * tierScale,
                    asciiIntensity: Float(intensity) * tierScale,
                    bottomAuraIntensity: bottomIntensity,
                    semanticMode: semanticCode,
                    calmCenter: calmCenter,
                    motionActive: motionActive,
                    interactiveRipples: interactiveRipples,
                    isStreamingActivity: isStreamingActivity,
                    liftoffToken: liftoffToken
                )
            } else {
                // Same color as the backdrop's clear color, until the shaders are built.
                tokens.background
                    .task { await engine.prepareStageBackdrop() }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        #else
        PrismHorizonView(
            auraState: bottomAuraState ?? .idle,
            bottomFocus: bottomAuraState != nil,
            intensity: intensity
        )
        #endif
    }
}
