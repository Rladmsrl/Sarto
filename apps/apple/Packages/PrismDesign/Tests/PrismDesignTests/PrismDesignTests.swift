import Foundation
import Metal
import Testing
@testable import PrismDesign

@Suite("PrismDesign System, Metal Shaders, High-Refresh Physics & i18n Tests")
struct PrismDesignTests {
    @Test("All 4 Obsidian Prism palettes resolve with expected color scheme and radii")
    func palettesResolveCleanly() {
        #expect(PrismPalette.allCases.count == 4)
        for palette in PrismPalette.allCases {
            let tokens = PrismTokens.resolved(palette: palette, accent: .model, radiusBase: 6)
            #expect(tokens.palette == palette)
            #expect(tokens.rMicro == 2)
            #expect(tokens.rXS == 4)
            #expect(tokens.rSM == 6)
            #expect(tokens.rMD == 8)
            #expect(tokens.rLG == 10)
            #expect(tokens.heatColors.count == 6)
        }
        #expect(PrismPalette.obsidian.isDark == true)
        #expect(PrismPalette.warm.isDark == true)
        #expect(PrismPalette.crystal.isDark == false)
        #expect(PrismPalette.alabaster.isDark == false)

        // Custom accent hex round-trips cleanly and encodes bit-exact negative shader codes
        let custom = PrismAccentMode(rawValue: "#2E9E72")
        #expect(custom == .custom(0x2E9E72))
        #expect(custom?.rawValue == "#2E9E72")
        #expect(PrismAccentMode(rawValue: "custom:#1499a6") == .custom(0x1499A6))
        #expect(PrismAccentMode(rawValue: "invalid") == nil)
        let customTokens = PrismTokens.resolved(palette: .obsidian, accent: .custom(0xFFFFFF))
        #expect(customTokens.shaderAccentCode == -16_777_216.0)
        #expect(PrismTokens.resolvedPrimaryHex(palette: .alabaster, accent: .model) == 0xC96442)
    }

    @Test("Spring presets match motion-engine.js parameters and honor reduce-motion")
    func springPresets() {
        #expect(PrismSpringSpec.snappy.stiffness == 420)
        #expect(PrismSpringSpec.snappy.damping == 30)
        #expect(PrismSpringSpec.snappy.mass == 0.9)
        #expect(PrismSpringSpec.default.animation(tier: .off) == nil)
        #expect(PrismSpringSpec.default.animation(tier: .ultra, reduceMotion: true) == nil)
        #expect(PrismSpringSpec.default.animation(tier: .ultra, reduceMotion: false) != nil)
    }

    /// Calls the synchronous Metal overload so Swift 6 on macOS 15 SDK never sends non-Sendable MTLLibrary across actors.
    private static func makeLibrarySync(device: MTLDevice, source: String) throws -> MTLLibrary {
        try device.makeLibrary(source: source, options: nil)
    }

    @Test("Static audit of PrismMetalSource.librarySource eliminates MSL UB and compiles all shaders")
    @MainActor
    func mslStaticAuditAndCompilation() async throws {
        let source = PrismMetalSource.librarySource
        #expect(source.contains("inline float pk_sq(float x)"))

        // 1. Verify zero pow(..., 2.0f) calls remain anywhere in the MSL library
        let sqPowPattern = try Regex(#"pow\s*\([^;]*,\s*2(?:\.0*)?f?\s*\)"#)
        #expect(source.firstMatch(of: sqPowPattern) == nil)

        // 2. Verify every remaining pow(...) call guards its base with max(...)
        let lines = source.components(separatedBy: .newlines)
        for (idx, line) in lines.enumerated() where line.contains("pow(") {
            #expect(
                line.contains("pow(max("),
                "Unguarded pow() call on MSL line \(idx + 1): \(line)"
            )
        }

        // 3. Verify zero literal or constant-offset inverted smoothstep(edge0, edge1, x) calls remain
        let literalSmoothstep = try Regex(#"smoothstep\s*\(\s*([+-]?\d+(?:\.\d+)?f?)\s*,\s*([+-]?\d+(?:\.\d+)?f?)\s*,"#)
        for match in source.matches(of: literalSmoothstep) {
            let s0 = String(match.output[1].substring ?? "").replacingOccurrences(of: "f", with: "")
            let s1 = String(match.output[2].substring ?? "").replacingOccurrences(of: "f", with: "")
            if let e0 = Double(s0), let e1 = Double(s1) {
                #expect(e0 < e1, "Inverted literal smoothstep(\(e0), \(e1), ...)")
            }
        }

        let offsetSmoothstep = try Regex(#"smoothstep\s*\(\s*([A-Z_]+)\s*([+-])\s*(\d+(?:\.\d+)?)f?\s*,\s*\1\s*([+-])\s*(\d+(?:\.\d+)?)f?\s*,"#)
        for match in source.matches(of: offsetSmoothstep) {
            let sign0 = match.output[2].substring == "-" ? -1.0 : 1.0
            let val0 = (Double(String(match.output[3].substring ?? "")) ?? 0) * sign0
            let sign1 = match.output[4].substring == "-" ? -1.0 : 1.0
            let val1 = (Double(String(match.output[5].substring ?? "")) ?? 0) * sign1
            #expect(val0 < val1, "Inverted constant-offset smoothstep(\(val0), \(val1), ...)")
        }

        // 4. Runtime Metal compilation & entrypoint verification
        #expect(MemoryLayout<PrismUniforms>.stride == 160)
        if let device = MTLCreateSystemDefaultDevice() {
            let library = try Self.makeLibrarySync(device: device, source: source)
            #expect(library.makeFunction(name: "pk_fullscreen_vertex") != nil)
            for kind in PrismMetalShaderKind.allCases {
                #expect(
                    library.makeFunction(name: kind.rawValue) != nil,
                    "Missing Metal fragment entrypoint \(kind.rawValue)"
                )
            }

            // The engine compiles off the main thread and builds pipelines on demand, so build every
            // variant explicitly: one shader that fails to build must fail this test, not just log.
            let engine = PrismMetalEngine.shared
            #expect(await engine.prepare() == true)
            for kind in PrismMetalShaderKind.allCases {
                for opaque in [false, true] {
                    let state = await engine.preparePipeline(for: kind, opaque: opaque)
                    #expect(state != nil, "Pipeline \(kind.rawValue) opaque=\(opaque) failed: \(engine.compilationError ?? "-")")
                }
            }
            #expect(await engine.preparePipeline(.asciiNebula) != nil)
            #expect(await engine.prepareStageBackdrop() == true)
            #expect(engine.compilationError == nil)
            #expect(engine.isReady == true)
            #expect(engine.pipelines.count == PrismMetalShaderKind.allCases.count)
            #expect(engine.opaquePipelines.count == PrismMetalShaderKind.allCases.count)
            #expect(engine.glyphAtlasTexture != nil)
        }
    }

    @Test("Shader time wrapping keeps sub-millisecond Float32 precision and loops every in-shader period")
    @MainActor
    func shaderTimePrecisionAndSmoothWake() {
        let period = PrismMetalCoordinator.shaderTimeWrapPeriod
        let fiveDays: Double = 5.0 * 86_400.0 + 123.456
        let wrapped = PrismMetalCoordinator.wrapShaderTime(fiveDays)
        #expect(abs(wrapped - 123.456) < 1e-6)
        #expect(PrismMetalCoordinator.wrapShaderTime(.nan) == 0.0)
        #expect(PrismMetalCoordinator.wrapShaderTime(.infinity) == 0.0)
        #expect(PrismMetalCoordinator.wrapShaderTime(-10.0) == period - 10.0)

        // The Float32 step just below the wrap stays far under one 144 Hz frame (6.9 ms).
        #expect(Float(period).ulp <= 0.0005)

        // Every fixed period evaluated in-shader divides the wrap, so those terms loop without a seam.
        let inShaderPeriods: [Double] = [100.0 / 31, 100.0 / 47, 100.0 / 23, 100.0 / 37, 3.125, 12.5, 50.0 / 17, 6.25, 1.0, 1.0 / 7]
        for p in inShaderPeriods {
            let cycles = period / p
            #expect(abs(cycles - cycles.rounded()) < 1e-6, "wrap \(period) is not a multiple of \(p)")
        }

        let coord = PrismMetalCoordinator(
            kind: .horizonAura,
            uniforms: PrismUniforms(time: 2.4),
            isAnimating: false,
            requestedFPS: 24
        )
        #expect(abs(coord.lastRenderedTime - 2.4) < 1e-5)
        coord.setAnimating(true)
        #expect(abs(coord.lastRenderedTime - 2.4) < 1e-5)
        coord.setAnimating(false)
        #expect(abs(coord.lastRenderedTime - 2.4) < 1e-5)
    }

    @Test("EffortLevel localization, 14pt track inset geometry, idle FPS step-down, and calm heatmap baseline")
    @MainActor
    func effortPaletteAndIdleStepDown() {
        let en = PrismL10n(language: .en)
        let zh = PrismL10n(language: .zhHans)

        #expect(EffortLevel.auto.localizedTitle(en) == "Auto")
        #expect(EffortLevel.low.localizedTitle(en) == "Low")
        #expect(EffortLevel.medium.localizedTitle(en) == "Medium")
        #expect(EffortLevel.high.localizedTitle(en) == "High")
        #expect(EffortLevel.extra.localizedTitle(en) == "Extra")

        #expect(EffortLevel.auto.localizedTitle(zh) == "Auto")
        #expect(EffortLevel.low.localizedTitle(zh) == "低")
        #expect(EffortLevel.medium.localizedTitle(zh) == "中")
        #expect(EffortLevel.high.localizedTitle(zh) == "高")
        #expect(EffortLevel.extra.localizedTitle(zh) == "极高")

        // 14pt horizontal track inset alignment
        #expect(EffortSliderView.normalizedProgress(for: 14, width: 228) == 0.0)
        #expect(abs(EffortSliderView.normalizedProgress(for: 114, width: 228) - 0.5) < 1e-9)
        #expect(EffortSliderView.normalizedProgress(for: 214, width: 228) == 1.0)
        #expect(EffortSliderView.normalizedProgress(for: 2, width: 228) == 0.0)
        #expect(EffortSliderView.normalizedProgress(for: 226, width: 228) == 1.0)

        // Crystal wake decay settles cleanly over 0.5s
        let wake = EffortCrystalWakeState()
        wake.trigger(motionActive: true)
        #expect(wake.crystalWake == 1.0)
        #expect(wake.step(dt: 0.25) == false)
        #expect(abs(wake.crystalWake - 0.5) < 0.02)
        #expect(wake.step(dt: 0.26) == true)
        #expect(wake.crystalWake == 0.0)

        // Dynamic idle FPS step-down (24fps calm vs native active)
        #expect(PrismHorizonView.resolvedPreferredFPS(auraState: .idle, bottomFocus: false, activeFPS: 120) == 24)
        #expect(PrismHorizonView.resolvedPreferredFPS(auraState: .running, bottomFocus: false, activeFPS: 120) == 120)
        #expect(PrismHorizonView.resolvedPreferredFPS(auraState: .start, bottomFocus: true, activeFPS: 120) == 120)

        // Deterministic calm heatmap baseline (zero fake spikes when empty) + optional 7d normalized activity
        let emptyGrid = TokenHeatmapMatrix.computeLevels(dailyTokens: Array(repeating: 0, count: 182))
        #expect(emptyGrid.count == 26)
        #expect(emptyGrid.allSatisfy { col in col.count == 7 && col.allSatisfy { $0 == 0 } })

        let weekGrid = TokenHeatmapMatrix.computeLevels(
            dailyTokens: Array(repeating: 0, count: 182),
            weeklyActivity: [0.0, 0.10, 0.25, 0.50, 0.75, 0.95, 0.0]
        )
        #expect(weekGrid[25] == [0, 1, 2, 3, 4, 5, 0])
        #expect(weekGrid[0].allSatisfy { $0 == 0 })

        // Real model effort resolution
        let piResolved = PrismEffortLevelResolver.resolve(
            optionId: "thought_level",
            optionName: "Thinking",
            choices: [
                .init(value: "off", name: "Thinking: off"),
                .init(value: "low", name: "Thinking: low"),
                .init(value: "high", name: "Thinking: high"),
                .init(value: "max", name: "Thinking: max"),
            ],
            currentValue: "max"
        )
        #expect(piResolved?.levels.map(\.id) == ["off", "low", "high", "max"])
        #expect(piResolved?.levels.map(\.label) == ["off", "low", "high", "max"])
        #expect(piResolved?.selectedID == "max")
        #expect(piResolved?.selectedOption?.tier == .max)

        let defaultResolved = PrismEffortLevelResolver.resolve(
            optionId: "effort",
            optionName: "Effort",
            choices: [
                .init(value: "default", name: "Default (Extra High)"),
                .init(value: "low", name: "Low"),
                .init(value: "high", name: "High"),
                .init(value: "xhigh", name: "Extra High"),
            ],
            currentValue: "default"
        )
        #expect(defaultResolved?.levels.map(\.id) == ["low", "high", "xhigh"])
        #expect(defaultResolved?.selectedID == "xhigh")
        #expect(defaultResolved?.selectedOption?.tier == .high)

        #expect(PrismEffortLevelResolver.resolve(optionId: "effort", optionName: "Effort", choices: [], currentValue: nil) == nil)

        // Sarto 9-dot turn phase indicator bounds & center stillness in chase pattern
        for phase in [PrismTurnPhase.thinking, .execute, .read, .search, .fetch, .edit, .writing, .compacting, .working, .waiting] {
            for y in 0..<3 {
                for x in 0..<3 {
                    let a = PrismTurnDotsView.dotOpacity(phase: phase, x: x, y: y, time: 0.42)
                    #expect(a >= 0.22 - 1e-6 && a <= 1.0 + 1e-6)
                }
            }
        }
        #expect(abs(PrismTurnDotsView.dotOpacity(phase: .execute, x: 1, y: 1, time: 0.37) - 0.22) < 1e-9)
    }

    @Test("English and Simplified Chinese localization catalogs have 100% key parity and PrismPalette language override")
    func localizationParityAndRuntimeSwitching() {
        let enTable = PrismL10n.rawStringsTable(lproj: "en")
        let zhTable = PrismL10n.rawStringsTable(lproj: "zh-Hans")
        #expect(enTable != nil)
        #expect(zhTable != nil)

        if let enTable, let zhTable {
            let enKeys = Set(enTable.keys)
            let zhKeys = Set(zhTable.keys)
            #expect(enKeys == zhKeys)
            #expect(enKeys.count >= 80)
            for (k, v) in enTable {
                #expect(!v.isEmpty, "Empty en value for key \(k)")
            }
            for (k, v) in zhTable {
                #expect(!v.isEmpty, "Empty zh-Hans value for key \(k)")
            }
        }

        let en = PrismL10n(language: .en)
        let zh = PrismL10n(language: .zhHans)
        #expect(en.tr("sidebar.studioHome") == "Studio Home")
        #expect(zh.tr("sidebar.studioHome") == "Studio 主页")
        #expect(en.tr("studio.daysAgo", 5) == "5 days ago")
        #expect(zh.tr("studio.daysAgo", 5) == "5 天前")

        for palette in PrismPalette.allCases {
            #expect(!palette.localizedName(language: .en).isEmpty)
            #expect(!palette.localizedName(language: .zhHans).isEmpty)
            #expect(palette.localizedName(language: .en) != palette.localizedName(language: .zhHans))
        }
        #expect(PrismPalette.obsidian.localizedName(en) == "Obsidian Dark")
        #expect(PrismPalette.obsidian.localizedName(zh) == "深空黑曜")
        #expect(PrismPalette.obsidian.localizedName(language: .en) == "Obsidian Dark")
        #expect(PrismPalette.obsidian.localizedName(language: .zhHans) == "深空黑曜")

        let suiteName = "dev.sarto.tests.lang.\(UUID().uuidString)"
        if let customDefaults = UserDefaults(suiteName: suiteName) {
            defer { customDefaults.removePersistentDomain(forName: suiteName) }
            customDefaults.set("zh-Hans", forKey: PrismLanguage.legacyStorageKey)
            #expect(PrismLanguage.loadSaved(defaults: customDefaults) == .zhHans)
            customDefaults.set("en", forKey: PrismLanguage.storageKey)
            #expect(PrismLanguage.loadSaved(defaults: customDefaults) == .en)
        }
    }
}
