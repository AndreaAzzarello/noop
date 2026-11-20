import SwiftUI
import StrandDesign

/// fork: a faint arc on an Effort ring marking the day's optimal Effort band, with a solid tick at its lower
/// end ("reach at least this much"). Drawn just outside the ring so it never covers the progress arc.
///
/// Carries its own VoiceOver element ("Effort target 10–14"); the shape itself is decorative.
struct StrainTargetArc: View {
    let band: StrainTargetBand
    /// Diameter of the ring this arc surrounds.
    let ringDiameter: CGFloat

    private static let gap: CGFloat = 5
    private static let lineWidth: CGFloat = 3

    var body: some View {
        let size = ringDiameter + 2 * (Self.gap + Self.lineWidth / 2)
        ZStack {
            Circle()
                .trim(from: band.fractionLow, to: band.fractionHigh)
                .stroke(StrandPalette.effortColor.opacity(0.35),
                        style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
            Circle()
                .trim(from: band.fractionLow, to: min(1, band.fractionLow + 0.012))
                .stroke(StrandPalette.effortColor,
                        style: StrokeStyle(lineWidth: Self.lineWidth + 2, lineCap: .butt))
        }
        .rotationEffect(.degrees(-90))
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(band.accessibilityText))
    }
}

#if DEBUG
#Preview("Strain target arc (fake data)") {
    HStack(spacing: 28) {
        ForEach([30.0, 50.0, 85.0], id: \.self) { recovery in
            if let band = StrainTargetBand.resolve(recovery: recovery, scale: .whoop) {
                Circle().stroke(StrandPalette.effortColor.opacity(0.2), lineWidth: 8)
                    .frame(width: 80, height: 80)
                    .overlay { StrainTargetArc(band: band, ringDiameter: 80) }
            }
        }
    }
    .padding(30)
}
#endif
