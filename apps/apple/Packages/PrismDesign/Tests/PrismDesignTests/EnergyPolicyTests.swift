import Foundation
import Testing
@testable import PrismDesign

@Suite("Metal energy policy and shader clock")
struct EnergyPolicyTests {
    private let lowPower = PrismPowerConditions(isLowPowerModeEnabled: true)
    private let serious = PrismPowerConditions(thermalState: .serious)
    private let critical = PrismPowerConditions(thermalState: .critical)
    private let fair = PrismPowerConditions(thermalState: .fair)

    @Test("Low Power Mode and serious or critical thermal states constrain rendering; fair does not")
    func constrainedConditions() {
        #expect(PrismPowerConditions.nominal.isConstrained == false)
        #expect(fair.isConstrained == false)
        #expect(lowPower.isConstrained == true)
        #expect(serious.isConstrained == true)
        #expect(critical.isConstrained == true)
    }

    @Test("Frame rate per activity on a 120 Hz display")
    func frameRatePerActivity() {
        func fps(_ activity: PrismRenderActivity, _ surface: PrismRenderSurface = .widget, _ conditions: PrismPowerConditions = .nominal) -> Int {
            PrismEnergyPolicy.framesPerSecond(for: activity, surface: surface, displayMaxFPS: 120, conditions: conditions)
        }

        #expect(fps(.still) == 0)
        #expect(fps(.ambient) == 10)
        #expect(fps(.streaming) == 30)
        #expect(fps(.interactive) == 120)
        #expect(fps(.interactive, .fullWindow) == 60)
        #expect(fps(.streaming, .fullWindow) == 30)
        #expect(fps(.ambient, .fullWindow) == 10)

        for constrained in [lowPower, serious, critical] {
            #expect(fps(.still, .widget, constrained) == 0)
            #expect(fps(.ambient, .widget, constrained) == 0)
            #expect(fps(.streaming, .widget, constrained) == 0)
            #expect(fps(.interactive, .widget, constrained) == 30)
            #expect(fps(.ambient, .fullWindow, constrained) == 0)
            #expect(fps(.streaming, .fullWindow, constrained) == 0)
            #expect(fps(.interactive, .fullWindow, constrained) == 0)
        }

        for activity in PrismRenderActivity.allCases {
            #expect(fps(activity, .fullWindow, fair) == fps(activity, .fullWindow))
        }
    }

    @Test("Policy rates never exceed the display and caller caps only lower them")
    func displayAndCallerCaps() {
        for display in [60, 120, 144] {
            for activity in PrismRenderActivity.allCases {
                for surface in [PrismRenderSurface.widget, .fullWindow] {
                    let rate = PrismEnergyPolicy.framesPerSecond(for: activity, surface: surface, displayMaxFPS: display)
                    #expect(rate >= 0 && rate <= display)
                }
            }
        }
        #expect(PrismEnergyPolicy.framesPerSecond(for: .interactive, displayMaxFPS: 144) == 144)
        #expect(PrismEnergyPolicy.framesPerSecond(for: .interactive, surface: .fullWindow, displayMaxFPS: 144) == 60)

        #expect(PrismEnergyPolicy.capped(10, requestedFPS: 24) == 10)
        #expect(PrismEnergyPolicy.capped(120, requestedFPS: 60) == 60)
        #expect(PrismEnergyPolicy.capped(30, requestedFPS: 0) == 30)
        #expect(PrismEnergyPolicy.capped(0, requestedFPS: 60) == 0)
    }

    @Test("Stage backdrop: capped while streaming, slow when idle, still in session or when motion is off")
    func stageBackdropActivity() {
        func activity(
            motion: Bool = true,
            interactive: Bool = false,
            waves: Bool = false,
            pointer: Bool = false,
            streaming: Bool = false
        ) -> PrismRenderActivity {
            PrismEnergyPolicy.stageBackdropActivity(
                motionActive: motion,
                interactiveRipples: interactive,
                hasActiveWaves: waves,
                pointerAwake: pointer,
                isStreaming: streaming
            )
        }

        #expect(activity() == .still)
        #expect(activity(interactive: true) == .ambient)
        #expect(activity(streaming: true) == .streaming)
        #expect(activity(interactive: true, streaming: true) == .streaming)
        #expect(activity(waves: true) == .interactive)
        #expect(activity(interactive: true, pointer: true) == .interactive)
        #expect(activity(motion: false, interactive: true, waves: true, pointer: true, streaming: true) == .still)

        func backdropFPS(_ activity: PrismRenderActivity, _ conditions: PrismPowerConditions = .nominal) -> Int {
            PrismEnergyPolicy.framesPerSecond(for: activity, surface: .fullWindow, displayMaxFPS: 120, conditions: conditions)
        }
        // A whole agent turn on a ProMotion display draws at 30 fps, not 120.
        #expect(backdropFPS(activity(streaming: true)) == 30)
        #expect(backdropFPS(activity(interactive: true)) == 10)
        #expect(backdropFPS(activity(interactive: true, pointer: true)) == 60)
        #expect(backdropFPS(activity(streaming: true), lowPower) == 0)
        #expect(backdropFPS(activity(waves: true), serious) == 0)
        #expect(backdropFPS(activity(interactive: true), critical) == 0)
    }

    @Test("Nebula lobes come from unwrapped Double time and stay continuous where the shader clock wraps")
    func nebulaLobesAreContinuous() {
        let frame = 1.0 / 120.0
        for t in [0.0, 2.4, PrismMetalCoordinator.shaderTimeWrapPeriod, 86_400.0, 5.0 * 86_400.0] {
            for i in 0..<3 {
                let a = PrismNebulaLobes.lobe(i, at: t - frame)
                let b = PrismNebulaLobes.lobe(i, at: t)
                #expect(abs(a.x - b.x) < 0.01 && abs(a.y - b.y) < 0.01, "lobe \(i) center jumps at \(t)")
                #expect(abs(a.z - b.z) < 0.01, "lobe \(i) strength jumps at \(t)")
                let hueStep = abs(a.w - b.w)
                #expect(min(hueStep, 1 - hueStep) < 0.01, "lobe \(i) hue jumps at \(t)")
                #expect(b.z >= 0.14 - 1e-4 && b.z <= 1.0 + 1e-4)
                #expect(b.w >= 0 && b.w < 1)
                #expect(b.x > 0.0 && b.x < 1.0 && b.y > 0.0 && b.y < 1.0)
            }
        }
        #expect(PrismNebulaLobes.lobe(0, at: .nan) == PrismNebulaLobes.lobe(0, at: 0))
    }
}
