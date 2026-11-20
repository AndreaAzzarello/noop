import Foundation

/// fork: the optimal Effort band of the day, ready to be drawn on an Effort ring.
///
/// The band itself is NOT computed here: `CoupledView.optimalStrainRange(recovery:)` is the single source
/// (the same call `AppModel.evaluateStrainTarget` makes for the notification), so the ring and the
/// notification cannot disagree. This type only converts it to what a ring needs: fractions of the axis and
/// the figures on the user's Effort scale.
///
/// Recovery is passed in as the SCORED value of the displayed day, never a carried one: a band derived from
/// yesterday's recovery would be a guess presented as today's target. nil recovery -> nil band.
struct StrainTargetBand: Equatable {
    /// Band ends on the WHOOP 0-21 axis, as `optimalStrainRange` returns them.
    let low21: Int
    let high21: Int
    /// The band ends expressed on the user's chosen Effort scale (21 or 100), whole numbers.
    let displayLow: Int
    let displayHigh: Int

    /// The 0-21 axis the band is defined on.
    static let axisMax: Double = 21

    /// Position of the band ends along the ring, 0...1. Identical on both Effort scales, because the ring
    /// fraction is value / scale max and the two scales are proportional.
    var fractionLow: Double { Double(low21) / Self.axisMax }
    var fractionHigh: Double { Double(high21) / Self.axisMax }

    static func resolve(recovery: Double?, scale: EffortScale) -> StrainTargetBand? {
        guard let band = CoupledView.optimalStrainRange(recovery: recovery) else { return nil }
        let lo = band.lowerBound, hi = band.upperBound
        switch scale {
        case .whoop:
            return StrainTargetBand(low21: lo, high21: hi, displayLow: lo, displayHigh: hi)
        case .hundred:
            return StrainTargetBand(low21: lo, high21: hi,
                                    displayLow: Int((Double(lo) * 100 / axisMax).rounded()),
                                    displayHigh: Int((Double(hi) * 100 / axisMax).rounded()))
        }
    }

    /// VoiceOver text, e.g. "Effort target 10–14".
    var accessibilityText: String {
        String(format: String(localized: "Effort target %1$@–%2$@", table: "Fork"),
               String(displayLow), String(displayHigh))
    }
}
