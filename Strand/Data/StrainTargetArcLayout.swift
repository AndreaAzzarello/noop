import CoreGraphics
import Foundation

/// fork: where the optimal Effort band is drawn on an Effort ring, as fractions of the ring (0 = 12 o'clock, clockwise).
///
/// The band is a translucent stretch of the ring's own TRACK, so it can never sit outside the ring. The ring's progress
/// arc is drawn under this overlay, so the fill starts after the end of the progress (plus its round cap) and the two
/// thin edge ticks, drawn in a contrasting token, keep the band readable when Effort is already past it.
///
/// Pure value logic: the radius and line width come from the ring that is actually drawn, so a test pins them.
struct StrainTargetArcLayout: Equatable {
    /// The translucent fill, or nil when the progress already covers the whole band.
    let fill: ClosedRange<Double>?
    /// Start of each edge tick; every tick is `tickLength` long.
    let tickStarts: [Double]
    let tickLength: Double

    /// Width of an edge tick along the ring, in points.
    static let tickWidth: CGFloat = 1.5

    static func make(band: StrainTargetBand, progress: Double?, ringRadius: CGFloat, ringLineWidth: CGFloat) -> StrainTargetArcLayout {
        let circumference = max(1, 2 * .pi * ringRadius)
        let tick = Double(tickWidth / circumference)
        // The progress arc ends in a round cap that reaches half a line width past its end.
        let cap = Double((ringLineWidth / 2) / circumference)
        let low = band.fractionLow, high = band.fractionHigh
        var from = low
        if let p = progress, p > 0.001 { from = max(low, min(1, p + cap)) }
        let fill: ClosedRange<Double>? = from < high ? from...high : nil
        func start(_ f: Double) -> Double { min(max(0, f - tick / 2), 1 - tick) }
        return StrainTargetArcLayout(fill: fill, tickStarts: [start(low), start(high)], tickLength: tick)
    }
}
