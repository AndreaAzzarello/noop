import SwiftUI
import StrandDesign

/// fork: the day's optimal Effort band, drawn INSIDE the Effort ring's track as a translucent stretch with a thin
/// edge tick at each end ("reach at least this much, no more than that").
///
/// It takes the radius and line width of the ring that is actually drawn, so it can never leave the ring, whatever the
/// Dynamic Type size or the background. The overlay sits above the ring: the fill starts after the end of the progress
/// arc (`StrainTargetArcLayout`) and the ticks stay visible when Effort has already passed the band.
///
/// Carries its own VoiceOver element ("Effort target 10–14"); the shape itself is decorative.
struct StrainTargetArc: View {
    let band: StrainTargetBand
    /// Radius of the ring's path (the centre of its stroke) and the ring's stroke width.
    let ringRadius: CGFloat
    let ringLineWidth: CGFloat
    /// Effort progress on the ring, 0...1; nil when there is no score.
    var progress: Double?

    var body: some View {
        let layout = StrainTargetArcLayout.make(band: band, progress: progress,
                                                ringRadius: ringRadius, ringLineWidth: ringLineWidth)
        let size = 2 * ringRadius + ringLineWidth
        ZStack {
            if let fill = layout.fill {
                Circle().inset(by: ringLineWidth / 2)
                    .trim(from: fill.lowerBound, to: fill.upperBound)
                    .stroke(StrandPalette.effortColor.opacity(0.30),
                            style: StrokeStyle(lineWidth: ringLineWidth, lineCap: .butt))
            }
            ForEach(Array(layout.tickStarts.enumerated()), id: \.offset) { _, start in
                Circle().inset(by: ringLineWidth / 2)
                    .trim(from: start, to: start + layout.tickLength)
                    .stroke(StrandPalette.textPrimary.opacity(0.85),
                            style: StrokeStyle(lineWidth: ringLineWidth, lineCap: .butt))
            }
        }
        .rotationEffect(.degrees(-90))
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(band.accessibilityText))
    }
}

#if DEBUG
#Preview("Strain target band (fake data)") {
    HStack(spacing: 28) {
        ForEach([(30.0, 0.2), (50.0, 0.6), (85.0, 0.95)], id: \.0) { recovery, progress in
            if let band = StrainTargetBand.resolve(recovery: recovery, scale: .whoop) {
                ZStack {
                    Circle().stroke(StrandPalette.textPrimary.opacity(0.10), lineWidth: 8)
                    Circle().trim(from: 0, to: progress).rotation(.degrees(-90))
                        .stroke(StrandPalette.effortColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                }
                .frame(width: 80, height: 80)
                .overlay { StrainTargetArc(band: band, ringRadius: 40, ringLineWidth: 8, progress: progress) }
            }
        }
    }
    .padding(30)
}
#endif
