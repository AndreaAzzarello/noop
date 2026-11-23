import Foundation
import SleepRecipe
import WhoopProtocol

// Dropout — graded, seeded data loss for a PSG subject, so a candidate can be asked "does this hold up better
// than the incumbent when the strap's data is worse, judged against polysomnography rather than against itself".
//
// A scenario names what is removed from the gravity stream and from the heart-rate stream. The damage is a pure
// function of the subject and of the scenario: the same samples go for every recipe being compared, which is the
// point (the quantity of interest is the DIFFERENCE between recipes under identical damage). Gravity can only be
// lost in holes — a contiguous gap, or several short bursts — because losing individual seconds at random leaves
// every 30 s epoch with plenty of the others and changes nothing a recipe could notice; heart rate can also lose
// individual samples.

enum Damage: Equatable {
    /// One contiguous hole of this many minutes, placed uniformly inside the night.
    case hole(minutes: Int)
    /// About this fraction of the night, removed in non-overlapping bursts of `burstSeconds`.
    case bursts(fraction: Double, burstSeconds: Int)
    /// Each sample removed independently with this probability (heart rate only).
    case sampleLoss(fraction: Double)
}

struct DropoutScenario {
    let name: String
    let gravity: Damage?
    let heartRate: Damage?

    /// The scenarios, in print order. Sizes bracket what a night with a flaky link plausibly loses; none is
    /// fitted to anything.
    static let all: [DropoutScenario] = [
        DropoutScenario(name: "gravity hole 15 min", gravity: .hole(minutes: 15), heartRate: nil),
        DropoutScenario(name: "gravity hole 30 min", gravity: .hole(minutes: 30), heartRate: nil),
        DropoutScenario(name: "gravity hole 60 min", gravity: .hole(minutes: 60), heartRate: nil),
        DropoutScenario(name: "gravity bursts 10 %", gravity: .bursts(fraction: 0.10, burstSeconds: 120), heartRate: nil),
        DropoutScenario(name: "gravity bursts 30 %", gravity: .bursts(fraction: 0.30, burstSeconds: 120), heartRate: nil),
        DropoutScenario(name: "gravity bursts 50 %", gravity: .bursts(fraction: 0.50, burstSeconds: 120), heartRate: nil),
        DropoutScenario(name: "HR hole 15 min", gravity: nil, heartRate: .hole(minutes: 15)),
        DropoutScenario(name: "HR hole 30 min", gravity: nil, heartRate: .hole(minutes: 30)),
        DropoutScenario(name: "HR hole 60 min", gravity: nil, heartRate: .hole(minutes: 60)),
        DropoutScenario(name: "HR samples lost 30 %", gravity: nil, heartRate: .sampleLoss(fraction: 0.30)),
        DropoutScenario(name: "HR samples lost 60 %", gravity: nil, heartRate: .sampleLoss(fraction: 0.60)),
        DropoutScenario(name: "gravity bursts 30 % + HR lost 30 %",
                        gravity: .bursts(fraction: 0.30, burstSeconds: 120), heartRate: .sampleLoss(fraction: 0.30)),
    ]

    /// The seed every subject's damage derives from. Fixed so a run reproduces on any machine.
    static let baseSeed: UInt64 = 0xD20_9047

    /// `subject` with this scenario's damage applied. Deterministic in (subject id, scenario name, `baseSeed`).
    func apply(to s: PSGSubject, seed: UInt64 = DropoutScenario.baseSeed) -> PSGSubject {
        let mixed = Perturb.seed(mixing: Perturb.seed(mixing: seed, with: name), with: s.id)
        var grav = s.grav, hr = s.hr
        if let g = gravity {
            grav = Perturb.gravityHoles(s.grav, holes(g, s, seed: mixed ^ 0x6A_5A7))
        }
        if let h = heartRate {
            switch h {
            case .sampleLoss(let fraction): hr = Perturb.dropHeartRate(s.hr, fraction: fraction, seed: mixed ^ 0x48_52)
            default: hr = Perturb.heartRateHoles(s.hr, holes(h, s, seed: mixed ^ 0x48_0735))
            }
        }
        return PSGSubject(id: s.id, start: s.start, end: s.end, grav: grav, hr: hr, truth: s.truth)
    }

    private func holes(_ d: Damage, _ s: PSGSubject, seed: UInt64) -> [(from: Int, to: Int)] {
        switch d {
        case .hole(let minutes):
            return [Perturb.singleHole(from: s.start, to: s.end, length: minutes * 60, seed: seed)]
        case .bursts(let fraction, let burstSeconds):
            return Perturb.burstHoles(from: s.start, to: s.end, fraction: fraction, burstSeconds: burstSeconds, seed: seed)
        case .sampleLoss:
            preconditionFailure("per-sample loss is a heart-rate damage; gravity is lost in holes")
        }
    }
}
