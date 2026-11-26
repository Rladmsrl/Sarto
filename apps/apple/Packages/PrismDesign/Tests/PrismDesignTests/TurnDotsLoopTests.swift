import Foundation
import Testing
@testable import PrismDesign

@Suite("Turn dot Core Animation loops")
struct TurnDotsLoopTests {
    @Test("Each phase's keyframe loop period repeats dotOpacity exactly, so the CA loop has no seam")
    func periodsMatchPatterns() {
        let phases: [PrismTurnPhase] = [.thinking, .execute, .read, .search, .fetch, .edit, .writing, .compacting, .working]
        for phase in phases {
            let period = PrismTurnDotsView.period(for: phase)
            for y in 0..<3 {
                for x in 0..<3 {
                    for t in stride(from: 0.0, to: period, by: period / 7) {
                        let a = PrismTurnDotsView.dotOpacity(phase: phase, x: x, y: y, time: t)
                        let b = PrismTurnDotsView.dotOpacity(phase: phase, x: x, y: y, time: t + period)
                        #expect(abs(a - b) < 1e-6, "phase \(phase) dot \(x),\(y) at \(t)")
                    }
                }
            }
        }
        #expect(abs(PrismStepPulseDot.pulse(time: 0.3) - PrismStepPulseDot.pulse(time: 0.3 + PrismStepPulseDot.period)) < 1e-9)
    }
}
