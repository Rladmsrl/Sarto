import CoreGraphics
import CoreText
import Foundation
import Metal
import MetalKit
import Observation
import OSLog
import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

private let prismMetalLog = Logger(subsystem: "PrismDesign", category: "Metal")

/// Available GPU Metal optical shaders compiled once at runtime on the system Metal driver.
public enum PrismMetalShaderKind: String, CaseIterable, Sendable {
    case cutCrystal = "pk_cut_crystal_frag"
    case starfieldTrack = "pk_starfield_track_frag"
    case opticalVial = "pk_optical_vial_frag"
    case horizonAura = "pk_horizon_aura_frag"
    case prismRim = "pk_prism_rim_frag"
    case asciiSea = "pk_ascii_sea_frag"
}

/// Resolves the live maximum refresh rate of the host display (60Hz / 120Hz ProMotion / 144Hz+ external).
@MainActor
public enum PrismDisplayRefresh {
    #if os(macOS)
    public static func maxFPS(for window: NSWindow? = nil) -> Int {
        let raw = window?.screen?.maximumFramesPerSecond
            ?? NSScreen.main?.maximumFramesPerSecond
            ?? 120
        return max(60, min(240, raw))
    }
    #elseif os(iOS)
    public static func maxFPS(for view: UIView? = nil) -> Int {
        let raw = view?.window?.windowScene?.screen.maximumFramesPerSecond
            ?? UIScreen.main.maximumFramesPerSecond
        return max(60, min(120, raw))
    }
    #endif
}

// MARK: - Energy policy

/// What a Metal view is animating, which decides how often it may draw.
public enum PrismRenderActivity: Sendable, Equatable, CaseIterable {
    /// Nothing moves: the view draws only when its inputs change.
    case still
    /// Slow decorative drift, such as the idle nebula.
    case ambient
    /// Decorative motion that marks an agent turn in progress.
    case streaming
    /// Direct response to the pointer, a drag or settling physics.
    case interactive
}

/// How much of the window a Metal view covers.
public enum PrismRenderSurface: Sendable, Equatable {
    case widget
    case fullWindow
}

/// The system power state the energy policy reacts to.
public struct PrismPowerConditions: Sendable, Equatable {
    public var isLowPowerModeEnabled: Bool
    public var thermalState: ProcessInfo.ThermalState

    public init(isLowPowerModeEnabled: Bool = false, thermalState: ProcessInfo.ThermalState = .nominal) {
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.thermalState = thermalState
    }

    public static let nominal = PrismPowerConditions()

    /// Low Power Mode, or a serious or critical thermal state.
    public var isConstrained: Bool {
        isLowPowerModeEnabled || thermalState == .serious || thermalState == .critical
    }

    public static var current: PrismPowerConditions {
        let info = ProcessInfo.processInfo
        return PrismPowerConditions(isLowPowerModeEnabled: info.isLowPowerModeEnabled, thermalState: info.thermalState)
    }
}

/// The one frame-rate policy every Metal view in PrismDesign draws by.
public enum PrismEnergyPolicy {
    public static let ambientFPS = 10
    public static let streamingFPS = 30
    public static let fullWindowInteractiveFPS = 60
    public static let constrainedInteractiveFPS = 30

    /// Frames per second a view may draw at. `0` pauses it, so it draws only when its inputs change.
    public static func framesPerSecond(
        for activity: PrismRenderActivity,
        surface: PrismRenderSurface = .widget,
        displayMaxFPS: Int,
        conditions: PrismPowerConditions = .nominal
    ) -> Int {
        let display = max(1, displayMaxFPS)
        switch activity {
        case .still:
            return 0
        case .ambient:
            return conditions.isConstrained ? 0 : min(ambientFPS, display)
        case .streaming:
            return conditions.isConstrained ? 0 : min(streamingFPS, display)
        case .interactive:
            switch (surface, conditions.isConstrained) {
            case (.fullWindow, true): return 0
            case (.fullWindow, false): return min(fullWindowInteractiveFPS, display)
            case (.widget, true): return min(constrainedInteractiveFPS, display)
            case (.widget, false): return display
            }
        }
    }

    /// Applies a caller's `preferredFPS` cap (`0` means none) to a policy rate.
    public static func capped(_ policyFPS: Int, requestedFPS: Int) -> Int {
        guard policyFPS > 0 else { return 0 }
        return requestedFPS > 0 ? min(requestedFPS, policyFPS) : policyFPS
    }

    /// Activity of the full-window stage backdrop behind the workbench.
    static func stageBackdropActivity(
        motionActive: Bool,
        interactiveRipples: Bool,
        hasActiveWaves: Bool,
        pointerAwake: Bool,
        isStreaming: Bool
    ) -> PrismRenderActivity {
        guard motionActive else { return .still }
        if hasActiveWaves || pointerAwake { return .interactive }
        if isStreaming { return .streaming }
        return interactiveRipples ? .ambient : .still
    }
}

/// Publishes Low Power Mode and thermal state changes to the Metal views.
@MainActor
@Observable
public final class PrismEnergyMonitor {
    public static let shared = PrismEnergyMonitor()

    /// Posted on the main queue after `conditions` changes.
    public static let conditionsDidChangeNotification = Notification.Name("PrismEnergyMonitor.conditionsDidChange")

    public private(set) var conditions: PrismPowerConditions
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        conditions = .current
        let center = NotificationCenter.default
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                }
            }
            observers.append(token)
        }
    }

    public func refresh() {
        let next = PrismPowerConditions.current
        guard next != conditions else { return }
        conditions = next
        NotificationCenter.default.post(name: Self.conditionsDidChangeNotification, object: nil)
    }
}

// MARK: - Shader clock

/// CPU-side kinematics of the three nebula lobes, evaluated in Double from unwrapped animation time,
/// so the 8.4 / 10.8 / 12.8 s lobe cycles never jump when the Float32 shader clock wraps.
enum PrismNebulaLobes {
    private static let periods: [Double] = [8.4, 10.8, 12.8]
    private static let phases: [Double] = [0.35, 2.45, 4.55]
    private static let angles: [Double] = [2.85, 0.52, 4.62]
    private static let hues: [Double] = [0.04, 0.54, 0.80]

    /// `(centerU, centerV, strength, hue)` of lobe `index` (`0..<3`) after `time` seconds of animation.
    static func lobe(_ index: Int, at time: Double) -> SIMD4<Float> {
        let t = time.isFinite ? time : 0
        let fi = Double(index)
        let rawSin = 0.5 + 0.5 * sin(2.0 * Double.pi * t / periods[index] + phases[index])
        let env = rawSin * rawSin * (3.0 - 2.0 * rawSin)
        let strength = 0.14 + 0.86 * pow(max(env, 0.0), 1.3)
        let direction: Double = index == 1 ? -1.0 : 1.0
        let angle = angles[index]
            + 0.52 * sin(t * (0.13 + fi * 0.023) + fi * 1.7)
            + direction * t * (0.045 + fi * 0.006)
        let ringR = 0.34 + 0.045 * cos(t * (0.11 + fi * 0.019) + fi * 1.1)
        let rawHue = hues[index] + 0.14 * sin(t * 0.09 + fi * 2.1)
        return SIMD4(
            Float(0.5 + ringR * 1.06 * cos(angle)),
            Float(0.5 + ringR * 0.92 * sin(angle)),
            Float(strength),
            Float(rawHue - floor(rawHue))
        )
    }

    /// Writes the lobes into `wave1...wave3`, where `pk_nebulaAccumulate` reads them.
    static func write(time: Double, into uniforms: inout PrismUniforms) {
        uniforms.wave1 = lobe(0, at: time)
        uniforms.wave2 = lobe(1, at: time)
        uniforms.wave3 = lobe(2, at: time)
    }
}

/// Strictly 16-byte-aligned uniform struct matching `PrismUniforms` in PrismMetalSource.
public struct PrismUniforms: Sendable, Equatable {
    public var resTimeDark: SIMD4<Float>
    public var pointerAccent: SIMD4<Float>
    public var params: SIMD4<Float>
    public var extra: SIMD4<Float>
    public var wave0: SIMD4<Float>
    public var wave1: SIMD4<Float>
    public var wave2: SIMD4<Float>
    public var wave3: SIMD4<Float>
    public var wave4: SIMD4<Float>
    public var wave5: SIMD4<Float>

    public init(
        size: CGSize = .zero,
        time: Float = 0,
        isDark: Bool = true,
        pointer: CGPoint = CGPoint(x: -9999, y: -9999),
        pointerAlpha: Float = 0,
        accent: Float = 0,
        params: SIMD4<Float> = .zero,
        extra: SIMD4<Float> = .zero,
        wave: [Double] = []
    ) {
        self.resTimeDark = SIMD4(Float(size.width), Float(size.height), time, isDark ? 1.0 : 0.0)
        self.pointerAccent = SIMD4(Float(pointer.x), Float(pointer.y), pointerAlpha, accent)
        self.params = params
        self.extra = extra
        func w(_ i: Int) -> Float { i < wave.count ? Float(wave[i]) : 0 }
        self.wave0 = SIMD4(w(0), w(1), w(2), w(3))
        self.wave1 = SIMD4(w(4), w(5), w(6), w(7))
        self.wave2 = SIMD4(w(8), w(9), w(10), w(11))
        self.wave3 = SIMD4(w(12), w(13), w(14), w(15))
        self.wave4 = SIMD4(w(16), w(17), w(18), w(19))
        self.wave5 = SIMD4(w(20), w(21), w(22), w(23))
    }
}

// MARK: - Engine

/// Shared Metal device, the runtime-compiled shader library, lazily built pipeline states and the ASCII glyph atlas.
///
/// The library compiles off the main thread when the engine is first used; until `isReady` (and the pipeline a
/// view needs) is available, views draw their SwiftUI fallbacks. Observable, so a view that reads `isReady` or
/// `cachedPipeline(for:opaque:)` in its body swaps its fallback for the Metal view once the shader is built.
@MainActor
@Observable
public final class PrismMetalEngine {
    public static let shared = PrismMetalEngine()

    nonisolated public static let asciiGlyphChars: [String] = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ").map { String($0) }

    /// Render target format of the stage backdrop's reduced-resolution nebula pass.
    nonisolated static let asciiNebulaPixelFormat: MTLPixelFormat = .rgba16Float

    struct PipelineKey: Hashable, Sendable {
        enum Variant: Hashable, Sendable {
            case blended
            case opaque
            case nebulaTarget
        }

        let function: String
        let variant: Variant

        static func shader(_ kind: PrismMetalShaderKind, opaque: Bool) -> PipelineKey {
            PipelineKey(function: kind.rawValue, variant: opaque ? .opaque : .blended)
        }

        static let asciiNebula = PipelineKey(function: "pk_ascii_nebula_frag", variant: .nebulaTarget)
    }

    private enum LibraryPhase {
        case compiling
        case ready
        case failed
    }

    private struct GlyphAtlasPixels: Sendable {
        let width: Int
        let height: Int
        let bytes: [UInt8]
    }

    private struct MetalBox<Value>: @unchecked Sendable {
        let value: Value
    }

    private struct LibraryCompileResult: @unchecked Sendable {
        var library: MTLLibrary?
        var vertexFunction: MTLFunction?
        var error: String?
        var glyphAtlas: GlyphAtlasPixels?
    }

    private enum PipelineBuildOutcome: @unchecked Sendable {
        case success(MTLRenderPipelineState)
        case failure(String)
    }

    public let device: MTLDevice?
    public let commandQueue: MTLCommandQueue?
    public private(set) var pipelines: [PrismMetalShaderKind: MTLRenderPipelineState] = [:]
    public private(set) var opaquePipelines: [PrismMetalShaderKind: MTLRenderPipelineState] = [:]
    /// The most recent library or pipeline build error; every error is also logged.
    public private(set) var compilationError: String?
    private var libraryPhase: LibraryPhase = .compiling
    /// Whether everything the stage backdrop draws with is built.
    private(set) var stageBackdropReady = false

    @ObservationIgnored private var shaderLibrary: MTLLibrary?
    @ObservationIgnored private var fullscreenVertexFn: MTLFunction?
    @ObservationIgnored private var nebulaPipelines: [PipelineKey: MTLRenderPipelineState] = [:]
    @ObservationIgnored private var pendingBuilds: [PipelineKey: Task<Void, Never>] = [:]
    @ObservationIgnored private var failedBuilds: Set<PipelineKey> = []
    @ObservationIgnored private var libraryTask: Task<Void, Never>?
    @ObservationIgnored private var cachedGlyphAtlas: MTLTexture?

    private init() {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let queue = dev.makeCommandQueue()
        else {
            self.device = nil
            self.commandQueue = nil
            self.compilationError = "No Metal GPU device available"
            self.libraryPhase = .failed
            prismMetalLog.error("No Metal GPU device available; Prism effects draw their SwiftUI fallbacks")
            return
        }
        self.device = dev
        self.commandQueue = queue
        let deviceBox = MetalBox(value: dev)
        libraryTask = Task { [weak self] in
            let result = await Self.compileLibrary(device: deviceBox)
            self?.finishLibraryCompile(result)
        }
    }

    /// True once the shader library compiled. Pipelines may still be building; see `cachedPipeline(for:opaque:)`.
    public var isReady: Bool {
        libraryPhase == .ready
    }

    public var glyphAtlasTexture: MTLTexture? {
        cachedGlyphAtlas
    }

    /// Waits for the shader library and returns whether it compiled.
    @discardableResult
    public func prepare() async -> Bool {
        await libraryTask?.value
        return isReady
    }

    /// The built pipeline for `kind`, or nil while it builds or when it failed. Never starts a build.
    public func cachedPipeline(for kind: PrismMetalShaderKind, opaque: Bool) -> MTLRenderPipelineState? {
        opaque ? opaquePipelines[kind] : pipelines[kind]
    }

    /// The built pipeline for `kind`; when it is not built yet, starts building it off the main thread and returns nil.
    public func pipeline(for kind: PrismMetalShaderKind, opaque: Bool) -> MTLRenderPipelineState? {
        pipeline(.shader(kind, opaque: opaque))
    }

    /// Builds the pipeline for `kind` if needed and waits for it. Nil when the shader cannot be built.
    @discardableResult
    public func preparePipeline(for kind: PrismMetalShaderKind, opaque: Bool) async -> MTLRenderPipelineState? {
        await preparePipeline(.shader(kind, opaque: opaque))
    }

    func cachedPipeline(_ key: PipelineKey) -> MTLRenderPipelineState? {
        switch key.variant {
        case .blended:
            return PrismMetalShaderKind(rawValue: key.function).flatMap { pipelines[$0] }
        case .opaque:
            return PrismMetalShaderKind(rawValue: key.function).flatMap { opaquePipelines[$0] }
        case .nebulaTarget:
            return nebulaPipelines[key]
        }
    }

    /// True when `key` can never be built: no device, a library that failed, or a pipeline that failed.
    func isUnavailable(_ key: PipelineKey) -> Bool {
        device == nil || libraryPhase == .failed || failedBuilds.contains(key)
    }

    func pipeline(_ key: PipelineKey) -> MTLRenderPipelineState? {
        if let hit = cachedPipeline(key) { return hit }
        if pendingBuilds[key] == nil && !isUnavailable(key) {
            startBuild(key)
        }
        return nil
    }

    func preparePipeline(_ key: PipelineKey) async -> MTLRenderPipelineState? {
        if let hit = cachedPipeline(key) { return hit }
        if isUnavailable(key) { return nil }
        let task = pendingBuilds[key] ?? startBuild(key)
        await task.value
        return cachedPipeline(key)
    }

    /// Builds the stage backdrop's pipelines; `stageBackdropReady` flips once they and the glyph atlas exist.
    @discardableResult
    func prepareStageBackdrop() async -> Bool {
        if stageBackdropReady { return true }
        let seaKey = PipelineKey.shader(.asciiSea, opaque: true)
        _ = pipeline(.asciiNebula)
        let sea = await preparePipeline(seaKey)
        let nebula = await preparePipeline(.asciiNebula)
        let ready = sea != nil && nebula != nil && cachedGlyphAtlas != nil
        if ready && !stageBackdropReady {
            stageBackdropReady = true
        }
        return ready
    }

    @discardableResult
    private func startBuild(_ key: PipelineKey) -> Task<Void, Never> {
        let task = Task { [weak self] in
            guard let self else { return }
            guard await self.prepare(),
                  let device = self.device,
                  let library = self.shaderLibrary,
                  let vertex = self.fullscreenVertexFn
            else {
                self.pendingBuilds[key] = nil
                return
            }
            let outcome = await Self.buildPipeline(
                key,
                device: MetalBox(value: device),
                library: MetalBox(value: library),
                vertex: MetalBox(value: vertex)
            )
            _ = self.finishBuild(key, outcome)
        }
        pendingBuilds[key] = task
        return task
    }

    private func finishBuild(_ key: PipelineKey, _ outcome: PipelineBuildOutcome) -> MTLRenderPipelineState? {
        pendingBuilds[key] = nil
        switch outcome {
        case .success(let state):
            switch key.variant {
            case .blended:
                if let kind = PrismMetalShaderKind(rawValue: key.function) { pipelines[kind] = state }
            case .opaque:
                if let kind = PrismMetalShaderKind(rawValue: key.function) { opaquePipelines[kind] = state }
            case .nebulaTarget:
                nebulaPipelines[key] = state
            }
            return state
        case .failure(let message):
            failedBuilds.insert(key)
            compilationError = message
            prismMetalLog.error(
                "Prism pipeline \(key.function, privacy: .public) (\(String(describing: key.variant), privacy: .public)) failed to build: \(message, privacy: .public)"
            )
            return nil
        }
    }

    private func finishLibraryCompile(_ result: LibraryCompileResult) {
        if let pixels = result.glyphAtlas, let device {
            cachedGlyphAtlas = Self.makeGlyphAtlasTexture(pixels, device: device)
        }
        if cachedGlyphAtlas == nil {
            prismMetalLog.error("Prism ASCII glyph atlas could not be built; the stage backdrop keeps its fallback")
        }
        if let library = result.library, let vertex = result.vertexFunction {
            shaderLibrary = library
            fullscreenVertexFn = vertex
            libraryPhase = .ready
        } else {
            let message = result.error ?? "Unknown Metal library error"
            compilationError = message
            libraryPhase = .failed
            prismMetalLog.error("Prism shader library failed to compile: \(message, privacy: .public)")
        }
    }

    nonisolated private static func compileLibrary(device: MetalBox<MTLDevice>) async -> LibraryCompileResult {
        await Task.detached(priority: .userInitiated) {
            var result = LibraryCompileResult()
            result.glyphAtlas = Self.rasterizeGlyphAtlas()
            do {
                let library = try await device.value.makeLibrary(source: PrismMetalSource.librarySource, options: MTLCompileOptions())
                if let vertex = library.makeFunction(name: "pk_fullscreen_vertex") {
                    result.library = library
                    result.vertexFunction = vertex
                } else {
                    result.error = "Missing vertex function pk_fullscreen_vertex"
                }
            } catch {
                result.error = error.localizedDescription
            }
            return result
        }.value
    }

    nonisolated private static func buildPipeline(
        _ key: PipelineKey,
        device: MetalBox<MTLDevice>,
        library: MetalBox<MTLLibrary>,
        vertex: MetalBox<MTLFunction>
    ) async -> PipelineBuildOutcome {
        await Task.detached(priority: .userInitiated) {
            guard let fragment = library.value.makeFunction(name: key.function) else {
                return .failure("Missing fragment function \(key.function)")
            }
            let desc = MTLRenderPipelineDescriptor()
            desc.label = key.function
            desc.vertexFunction = vertex.value
            desc.fragmentFunction = fragment
            switch key.variant {
            case .blended:
                desc.colorAttachments[0].pixelFormat = .bgra8Unorm
                desc.colorAttachments[0].isBlendingEnabled = true
                desc.colorAttachments[0].rgbBlendOperation = .add
                desc.colorAttachments[0].alphaBlendOperation = .add
                desc.colorAttachments[0].sourceRGBBlendFactor = .one
                desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                desc.colorAttachments[0].sourceAlphaBlendFactor = .one
                desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            case .opaque:
                desc.colorAttachments[0].pixelFormat = .bgra8Unorm
                desc.colorAttachments[0].isBlendingEnabled = false
            case .nebulaTarget:
                desc.colorAttachments[0].pixelFormat = Self.asciiNebulaPixelFormat
                desc.colorAttachments[0].isBlendingEnabled = false
            }
            do {
                let state = try await device.value.makeRenderPipelineState(descriptor: desc)
                return .success(state)
            } catch {
                return .failure(error.localizedDescription)
            }
        }.value
    }

    /// Rasterizes all 62 monospace ASCII characters into r8 bytes for the glyph atlas.
    nonisolated private static func rasterizeGlyphAtlas() -> GlyphAtlasPixels? {
        let glyphs = asciiGlyphChars
        let cellW = 24
        let cellH = 32
        let atlasW = glyphs.count * cellW
        let atlasH = cellH

        var pixels = [UInt8](repeating: 0, count: atlasW * atlasH)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(
                data: buffer.baseAddress,
                width: atlasW,
                height: atlasH,
                bitsPerComponent: 8,
                bytesPerRow: atlasW,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                return false
            }

            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: atlasW, height: atlasH))
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldAntialias(true)

            let font = CTFontCreateWithName("Menlo-Regular" as CFString, 21.0, nil)
            let white = CGColor(gray: 1.0, alpha: 1.0)
            let attrs: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: white,
            ]
            for (idx, glyph) in glyphs.enumerated() {
                guard let attrStr = CFAttributedStringCreate(nil, glyph as CFString, attrs as CFDictionary) else { continue }
                let line = CTLineCreateWithAttributedString(attrStr)
                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                let typographicW = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
                let drawX = CGFloat(idx * cellW) + (CGFloat(cellW) - typographicW) * 0.5
                let drawY = (CGFloat(cellH) - (ascent + descent)) * 0.5 + descent
                ctx.textPosition = CGPoint(x: drawX, y: drawY)
                CTLineDraw(line, ctx)
            }
            return true
        }
        return drawn ? GlyphAtlasPixels(width: atlasW, height: atlasH, bytes: pixels) : nil
    }

    private static func makeGlyphAtlasTexture(_ pixels: GlyphAtlasPixels, device: MTLDevice) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: pixels.width,
            height: pixels.height,
            mipmapped: false
        )
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(
            region: MTLRegionMake2D(0, 0, pixels.width, pixels.height),
            mipmapLevel: 0,
            withBytes: pixels.bytes,
            bytesPerRow: pixels.width
        )
        return tex
    }
}

// MARK: - Coordinator

/// Coordinator rendering a single shader pipeline at the rate `PrismEnergyPolicy` allows.
@MainActor
public final class PrismMetalCoordinator: NSObject, MTKViewDelegate {
    /// Shader time wraps after an hour of animation. Float32 still resolves 2^-12 s (about 0.24 ms) at 3,600 s,
    /// and 3,600 is a whole multiple of every fixed period the shaders evaluate in-shader (glints 100/31, 100/47,
    /// 100/23 and 100/37 s, the 3.125 s sweep, the 12.5 s hue drift, the 50/17 and 6.25 s aura drifts), so those
    /// loop without a seam. The nebula lobes (8.4 / 10.8 / 12.8 s) are computed on the CPU in Double instead
    /// (`PrismNebulaLobes`). Terms with irrational rates, like `sin(time * 2.1)`, and noise scrolls still step
    /// once per wrap; no common multiple exists for them.
    nonisolated public static let shaderTimeWrapPeriod: Double = 3_600.0

    /// Longest step the animation clock takes in one frame: above the slowest policy rate (10 fps),
    /// so ambient views keep real speed, yet short enough that a stall does not jump the animation.
    nonisolated static let maxClockStep: Double = 0.25

    nonisolated public static func wrapShaderTime(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0.0 }
        let rem = seconds.truncatingRemainder(dividingBy: shaderTimeWrapPeriod)
        return rem >= 0 ? rem : rem + shaderTimeWrapPeriod
    }

    let kind: PrismMetalShaderKind
    private let commandQueue: MTLCommandQueue?
    public var uniforms: PrismUniforms
    var requestedFPS: Int // 0 = no cap beyond the energy policy
    /// What the view animates; nil is treated as `.interactive`, the rate callers got before the policy existed.
    var activity: PrismRenderActivity?
    private(set) var isAnimating: Bool
    /// Unwrapped animation time in seconds; wrapped only when handed to the shader.
    private(set) var lastRenderedTime: Double
    private var hasAnimated: Bool
    private var lastDrawTime: CFTimeInterval?
    private var awaitingPipeline = false
    var onDrawTick: ((_ dt: Double, _ coordinator: PrismMetalCoordinator, _ view: MTKView) -> Void)?
    var tracksWindowPointer: Bool
    var basePointerAlpha: Float

    weak var attachedView: MTKView?
    nonisolated(unsafe) private var notificationObservers: [NSObjectProtocol] = []
    nonisolated(unsafe) private var energyObserver: NSObjectProtocol?

    #if os(macOS)
    private weak var observedWindow: NSWindow?
    nonisolated(unsafe) private var pointerMonitor: Any?
    private var isPointerInside: Bool = false
    #endif

    init(
        kind: PrismMetalShaderKind,
        uniforms: PrismUniforms,
        isAnimating: Bool,
        requestedFPS: Int,
        activity: PrismRenderActivity? = nil,
        tracksWindowPointer: Bool = false,
        onDrawTick: ((_ dt: Double, _ coordinator: PrismMetalCoordinator, _ view: MTKView) -> Void)? = nil
    ) {
        self.kind = kind
        self.commandQueue = PrismMetalEngine.shared.commandQueue
        self.uniforms = uniforms
        self.isAnimating = isAnimating
        self.lastRenderedTime = Double(uniforms.resTimeDark.z).isFinite ? Double(uniforms.resTimeDark.z) : 0
        self.hasAnimated = isAnimating
        self.lastDrawTime = isAnimating ? CACurrentMediaTime() : nil
        self.requestedFPS = requestedFPS
        self.activity = activity
        self.tracksWindowPointer = tracksWindowPointer
        self.basePointerAlpha = uniforms.pointerAccent.z
        self.onDrawTick = onDrawTick
        super.init()
    }

    deinit {
        for token in notificationObservers {
            NotificationCenter.default.removeObserver(token)
        }
        if let energyObserver {
            NotificationCenter.default.removeObserver(energyObserver)
        }
        #if os(macOS)
        if let pointerMonitor {
            DispatchQueue.main.async {
                NSEvent.removeMonitor(pointerMonitor)
            }
        }
        #endif
    }

    func setAnimating(_ active: Bool) {
        guard isAnimating != active else { return }
        isAnimating = active
        if active {
            hasAnimated = true
            lastDrawTime = CACurrentMediaTime()
        } else {
            lastDrawTime = nil
        }
    }

    func updateStaticTimeIfNeeded(_ staticTime: Float) {
        if !isAnimating && !hasAnimated && staticTime.isFinite {
            lastRenderedTime = Double(staticTime)
        }
    }

    /// Policy rate while animating, already capped by `requestedFPS`.
    func animatingFPS(for view: MTKView) -> Int {
        let policy = PrismEnergyPolicy.framesPerSecond(
            for: activity ?? .interactive,
            surface: .widget,
            displayMaxFPS: displayMaxFPS(for: view),
            conditions: PrismEnergyMonitor.shared.conditions
        )
        return PrismEnergyPolicy.capped(policy, requestedFPS: requestedFPS)
    }

    /// Switches the view between continuous drawing at the policy rate and on-demand drawing.
    func syncRenderMode(for view: MTKView, redraw: Bool) {
        guard canRender(in: view) else {
            view.isPaused = true
            return
        }
        let fps = animatingFPS(for: view)
        // Keep the cap on the view even while paused, since some callers resume it directly.
        if fps > 0 && view.preferredFramesPerSecond != fps {
            view.preferredFramesPerSecond = fps
        }
        let runs = isAnimating && fps > 0
        if runs {
            if view.isPaused {
                lastDrawTime = CACurrentMediaTime()
            }
            view.enableSetNeedsDisplay = false
            view.isPaused = false
        } else {
            view.isPaused = true
            view.enableSetNeedsDisplay = true
            if redraw {
                requestRedraw(of: view)
            }
        }
    }

    private func requestRedraw(of view: MTKView) {
        #if os(macOS)
        view.needsDisplay = true
        #elseif os(iOS)
        view.setNeedsDisplay()
        #endif
    }

    private func displayMaxFPS(for view: MTKView) -> Int {
        #if os(macOS)
        PrismDisplayRefresh.maxFPS(for: view.window)
        #elseif os(iOS)
        PrismDisplayRefresh.maxFPS(for: view)
        #endif
    }

    private func installEnergyObserver() {
        guard energyObserver == nil else { return }
        energyObserver = NotificationCenter.default.addObserver(
            forName: PrismEnergyMonitor.conditionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let view = self.attachedView else { return }
                self.syncRenderMode(for: view, redraw: true)
            }
        }
    }

    private func removeEnergyObserver() {
        if let energyObserver {
            NotificationCenter.default.removeObserver(energyObserver)
            self.energyObserver = nil
        }
    }

    /// The pipeline this frame needs; when it is still building, schedules a redraw for when it lands.
    private func activePipeline(opaque: Bool) -> MTLRenderPipelineState? {
        let engine = PrismMetalEngine.shared
        if let hit = engine.cachedPipeline(for: kind, opaque: opaque) {
            return hit
        }
        let key = PrismMetalEngine.PipelineKey.shader(kind, opaque: opaque)
        guard !awaitingPipeline, !engine.isUnavailable(key) else { return nil }
        awaitingPipeline = true
        Task { [weak self] in
            _ = await PrismMetalEngine.shared.preparePipeline(key)
            guard let self else { return }
            self.awaitingPipeline = false
            if let view = self.attachedView, view.isPaused, self.canRender(in: view) {
                self.requestRedraw(of: view)
            }
        }
        return nil
    }

    #if os(macOS)
    func installObservers(for view: MTKView) {
        attachedView = view
        installEnergyObserver()

        if observedWindow !== view.window {
            for token in notificationObservers {
                NotificationCenter.default.removeObserver(token)
            }
            notificationObservers.removeAll()
            observedWindow = view.window

            if let win = view.window {
                let screenToken = NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeScreenNotification,
                    object: win,
                    queue: .main
                ) { [weak self, weak view] _ in
                    Task { @MainActor [weak self, weak view] in
                        guard let self, let view else { return }
                        self.syncRenderMode(for: view, redraw: false)
                    }
                }
                notificationObservers.append(screenToken)

                let occlusionToken = NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeOcclusionStateNotification,
                    object: win,
                    queue: .main
                ) { [weak self, weak view] _ in
                    Task { @MainActor [weak self, weak view] in
                        guard let self, let view else { return }
                        self.syncRenderMode(for: view, redraw: true)
                    }
                }
                notificationObservers.append(occlusionToken)
            }
        }

        syncPointerTracking(for: view)
        syncRenderMode(for: view, redraw: true)
    }

    func syncPointerTracking(for view: MTKView) {
        if tracksWindowPointer {
            if let win = view.window, !win.acceptsMouseMovedEvents {
                win.acceptsMouseMovedEvents = true
            }
            if pointerMonitor == nil {
                pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .scrollWheel]) { [weak self] event in
                    self?.handlePointerEvent(event)
                    return event
                }
            }
        } else {
            if let pointerMonitor {
                NSEvent.removeMonitor(pointerMonitor)
                self.pointerMonitor = nil
            }
            if isPointerInside {
                isPointerInside = false
                uniforms.pointerAccent.x = -9999
                uniforms.pointerAccent.y = -9999
                uniforms.pointerAccent.z = basePointerAlpha
                if view.isPaused && view.enableSetNeedsDisplay {
                    view.needsDisplay = true
                }
            }
        }
    }

    func tearDownObservers() {
        for token in notificationObservers {
            NotificationCenter.default.removeObserver(token)
        }
        notificationObservers.removeAll()
        observedWindow = nil
        removeEnergyObserver()
        if let pointerMonitor {
            NSEvent.removeMonitor(pointerMonitor)
            self.pointerMonitor = nil
        }
    }

    func canRender(in view: MTKView) -> Bool {
        guard let win = view.window, win.isVisible, win.occlusionState.contains(.visible) else {
            return false
        }
        return true
    }

    private func handlePointerEvent(_ event: NSEvent) {
        guard let view = attachedView,
              let win = view.window,
              event.window === win,
              win.isVisible,
              win.occlusionState.contains(.visible)
        else { return }
        let local = view.convert(event.locationInWindow, from: nil)
        let bounds = view.bounds
        let inside = bounds.insetBy(dx: -18, dy: -18).contains(local)
        if inside {
            // Convert AppKit bottom-left Y to top-left SwiftUI point Y expected by shaders
            let yTop = view.isFlipped ? local.y : (bounds.height - local.y)
            uniforms.pointerAccent.x = Float(local.x)
            uniforms.pointerAccent.y = Float(yTop)
            uniforms.pointerAccent.z = max(basePointerAlpha, 1.0)
            isPointerInside = true
            if view.isPaused && view.enableSetNeedsDisplay {
                view.needsDisplay = true
            }
        } else if isPointerInside {
            isPointerInside = false
            uniforms.pointerAccent.x = -9999
            uniforms.pointerAccent.y = -9999
            uniforms.pointerAccent.z = basePointerAlpha
            if view.isPaused && view.enableSetNeedsDisplay {
                view.needsDisplay = true
            }
        }
    }
    #elseif os(iOS)
    func installObservers(for view: MTKView) {
        attachedView = view
        installEnergyObserver()
        if notificationObservers.isEmpty {
            let nc = NotificationCenter.default
            let resign = nc.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.attachedView?.isPaused = true
                }
            }
            let bg = nc.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.attachedView?.isPaused = true
                }
            }
            let willFg = nc.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.syncApplicationState()
                }
            }
            let active = nc.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.syncApplicationState()
                }
            }
            notificationObservers = [resign, bg, willFg, active]
        }
        syncApplicationState()
    }

    func tearDownObservers() {
        for token in notificationObservers {
            NotificationCenter.default.removeObserver(token)
        }
        notificationObservers.removeAll()
        removeEnergyObserver()
    }

    func canRender(in view: MTKView) -> Bool {
        view.window != nil && UIApplication.shared.applicationState != .background
    }

    func syncApplicationState() {
        guard let view = attachedView else { return }
        syncRenderMode(for: view, redraw: true)
    }
    #endif

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        if view.isPaused && view.enableSetNeedsDisplay && canRender(in: view) {
            requestRedraw(of: view)
        }
    }

    public func draw(in view: MTKView) {
        guard canRender(in: view) else {
            view.isPaused = true
            return
        }
        guard view.bounds.width > 0 && view.bounds.height > 0 else { return }

        let now = CACurrentMediaTime()
        let dt: Double
        if let prev = lastDrawTime {
            let raw = now - prev
            dt = raw.isFinite ? min(Self.maxClockStep, max(0.0, raw)) : 0.0
        } else {
            dt = 0.0
        }
        lastDrawTime = now

        // On-demand redraws of a paused view keep the clock still.
        if isAnimating && !view.isPaused {
            lastRenderedTime += dt
        }

        if let onDrawTick {
            onDrawTick(min(0.05, dt), self, view)
        }

        let isOpaquePass = view.clearColor.alpha >= 1.0
        guard let activePipeline = activePipeline(opaque: isOpaquePass),
              let queue = commandQueue,
              let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable
        else { return }

        if isOpaquePass {
            rpd.colorAttachments[0].loadAction = .dontCare
        }

        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd)
        else { return }

        var u = uniforms
        let ptSize = view.bounds.size
        if ptSize.width > 0 && ptSize.height > 0 {
            u.resTimeDark.x = Float(ptSize.width)
            u.resTimeDark.y = Float(ptSize.height)
        }
        u.resTimeDark.z = Float(Self.wrapShaderTime(lastRenderedTime))
        if kind == .horizonAura {
            PrismNebulaLobes.write(time: lastRenderedTime, into: &u)
        }

        enc.setRenderPipelineState(activePipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<PrismUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()

        cmd.present(drawable)
        cmd.commit()
    }
}

#if os(macOS)
/// Pass-through MTKView so SwiftUI handles 100% of hover, drag, tap, and focus cleanly,
/// while capping its drawable to `maxBackingScale`.
final class NonInteractiveMTKView: MTKView {
    var onWindowAttached: ((MTKView) -> Void)?
    var maxBackingScale: CGFloat?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            updateScaledDrawableSize()
            onWindowAttached?(self)
        } else {
            isPaused = true
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateScaledDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScaledDrawableSize()
    }

    func updateScaledDrawableSize() {
        guard let cap = maxBackingScale else { return }
        let nativeScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let effScale = min(nativeScale, cap)
        let w = max(1, (bounds.width * effScale).rounded())
        let h = max(1, (bounds.height * effScale).rounded())
        if drawableSize.width != w || drawableSize.height != h {
            drawableSize = CGSize(width: w, height: h)
            if isPaused && enableSetNeedsDisplay {
                needsDisplay = true
            }
        }
    }
}

/// Layer settings shared by every Prism MTKView on macOS.
@MainActor
func prismConfigureMetalLayer(of view: MTKView) {
    // The shaders write sRGB-encoded values; without a colorspace macOS shows them as display P3,
    // which leaves a visible seam against SwiftUI backgrounds of the same color.
    view.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
    if let metalLayer = view.layer as? CAMetalLayer {
        metalLayer.presentsWithTransaction = false
        metalLayer.displaySyncEnabled = true
        metalLayer.maximumDrawableCount = 3
    }
}

public struct PrismMetalView: NSViewRepresentable {
    public let kind: PrismMetalShaderKind
    public let uniforms: PrismUniforms
    public let isAnimating: Bool
    /// Upper bound on the frame rate; 0 leaves it to `PrismEnergyPolicy` alone.
    public let preferredFPS: Int
    public let clearColor: MTLClearColor
    public let tracksWindowPointer: Bool
    /// What the view animates, for the energy policy; nil counts as `.interactive`.
    public let activity: PrismRenderActivity?
    public let onDrawTick: ((_ dt: Double, _ coordinator: PrismMetalCoordinator, _ view: MTKView) -> Void)?

    public init(
        kind: PrismMetalShaderKind,
        uniforms: PrismUniforms,
        isAnimating: Bool = true,
        preferredFPS: Int = 0,
        clearColor: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0),
        tracksWindowPointer: Bool = false,
        activity: PrismRenderActivity? = nil,
        onDrawTick: ((_ dt: Double, _ coordinator: PrismMetalCoordinator, _ view: MTKView) -> Void)? = nil
    ) {
        self.kind = kind
        self.uniforms = uniforms
        self.isAnimating = isAnimating
        self.preferredFPS = preferredFPS
        self.clearColor = clearColor
        self.tracksWindowPointer = tracksWindowPointer
        self.activity = activity
        self.onDrawTick = onDrawTick
    }

    public func makeCoordinator() -> PrismMetalCoordinator {
        PrismMetalCoordinator(
            kind: kind,
            uniforms: uniforms,
            isAnimating: isAnimating,
            requestedFPS: preferredFPS,
            activity: activity,
            tracksWindowPointer: tracksWindowPointer,
            onDrawTick: onDrawTick
        )
    }

    public func makeNSView(context: Context) -> MTKView {
        let view = NonInteractiveMTKView(frame: .zero, device: PrismMetalEngine.shared.device)
        let isOpaque = clearColor.alpha >= 1.0
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = clearColor
        view.framebufferOnly = true
        view.autoResizeDrawable = false
        view.maxBackingScale = 1.5
        view.wantsLayer = true
        view.layer?.isOpaque = isOpaque
        if !isOpaque {
            view.layer?.backgroundColor = NSColor.clear.cgColor
        }
        prismConfigureMetalLayer(of: view)
        view.preferredFramesPerSecond = max(1, context.coordinator.animatingFPS(for: view))
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = context.coordinator
        view.onWindowAttached = { [weak coord = context.coordinator] attached in
            coord?.installObservers(for: attached)
        }
        context.coordinator.installObservers(for: view)
        return view
    }

    public func updateNSView(_ nsView: MTKView, context: Context) {
        let coord = context.coordinator
        var nextUniforms = uniforms
        if tracksWindowPointer && coord.uniforms.pointerAccent.x > -2000 {
            nextUniforms.pointerAccent.x = coord.uniforms.pointerAccent.x
            nextUniforms.pointerAccent.y = coord.uniforms.pointerAccent.y
            nextUniforms.pointerAccent.z = max(uniforms.pointerAccent.z, 1.0)
        }
        let changed = coord.uniforms != nextUniforms
            || coord.isAnimating != isAnimating
            || coord.requestedFPS != preferredFPS
            || coord.activity != activity
        coord.basePointerAlpha = uniforms.pointerAccent.z
        coord.tracksWindowPointer = tracksWindowPointer
        coord.uniforms = nextUniforms
        coord.setAnimating(isAnimating)
        coord.updateStaticTimeIfNeeded(nextUniforms.resTimeDark.z)
        coord.requestedFPS = preferredFPS
        coord.activity = activity
        coord.onDrawTick = onDrawTick
        nsView.clearColor = clearColor
        nsView.layer?.isOpaque = clearColor.alpha >= 1.0
        coord.syncPointerTracking(for: nsView)
        coord.syncRenderMode(for: nsView, redraw: changed)
    }

    public static func dismantleNSView(_ nsView: MTKView, coordinator: PrismMetalCoordinator) {
        nsView.isPaused = true
        coordinator.tearDownObservers()
    }
}

#elseif os(iOS)
final class NonInteractiveIOSMTKView: MTKView {
    var onWindowAttached: ((MTKView) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            onWindowAttached?(self)
        } else {
            isPaused = true
        }
    }
}

public struct PrismMetalView: UIViewRepresentable {
    public let kind: PrismMetalShaderKind
    public let uniforms: PrismUniforms
    public let isAnimating: Bool
    public let preferredFPS: Int
    public let clearColor: MTLClearColor
    public let tracksWindowPointer: Bool
    public let activity: PrismRenderActivity?
    public let onDrawTick: ((_ dt: Double, _ coordinator: PrismMetalCoordinator, _ view: MTKView) -> Void)?

    public init(
        kind: PrismMetalShaderKind,
        uniforms: PrismUniforms,
        isAnimating: Bool = true,
        preferredFPS: Int = 0,
        clearColor: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0),
        tracksWindowPointer: Bool = false,
        activity: PrismRenderActivity? = nil,
        onDrawTick: ((_ dt: Double, _ coordinator: PrismMetalCoordinator, _ view: MTKView) -> Void)? = nil
    ) {
        self.kind = kind
        self.uniforms = uniforms
        self.isAnimating = isAnimating
        self.preferredFPS = preferredFPS
        self.clearColor = clearColor
        self.tracksWindowPointer = tracksWindowPointer
        self.activity = activity
        self.onDrawTick = onDrawTick
    }

    public func makeCoordinator() -> PrismMetalCoordinator {
        PrismMetalCoordinator(
            kind: kind,
            uniforms: uniforms,
            isAnimating: isAnimating,
            requestedFPS: preferredFPS,
            activity: activity,
            tracksWindowPointer: tracksWindowPointer,
            onDrawTick: onDrawTick
        )
    }

    public func makeUIView(context: Context) -> MTKView {
        let view = NonInteractiveIOSMTKView(frame: .zero, device: PrismMetalEngine.shared.device)
        let isOpaque = clearColor.alpha >= 1.0
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = clearColor
        view.framebufferOnly = true
        view.isOpaque = isOpaque
        view.backgroundColor = isOpaque ? nil : .clear
        view.isUserInteractionEnabled = false
        view.preferredFramesPerSecond = max(1, context.coordinator.animatingFPS(for: view))
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = context.coordinator
        view.onWindowAttached = { [weak coord = context.coordinator] attached in
            coord?.installObservers(for: attached)
        }
        context.coordinator.installObservers(for: view)
        return view
    }

    public func updateUIView(_ uiView: MTKView, context: Context) {
        let coord = context.coordinator
        let changed = coord.uniforms != uniforms
            || coord.isAnimating != isAnimating
            || coord.requestedFPS != preferredFPS
            || coord.activity != activity
        coord.uniforms = uniforms
        coord.setAnimating(isAnimating)
        coord.updateStaticTimeIfNeeded(uniforms.resTimeDark.z)
        coord.requestedFPS = preferredFPS
        coord.activity = activity
        coord.onDrawTick = onDrawTick
        uiView.clearColor = clearColor
        uiView.isOpaque = clearColor.alpha >= 1.0
        coord.syncRenderMode(for: uiView, redraw: changed)
    }

    public static func dismantleUIView(_ uiView: MTKView, coordinator: PrismMetalCoordinator) {
        uiView.isPaused = true
        coordinator.tearDownObservers()
    }
}
#endif
