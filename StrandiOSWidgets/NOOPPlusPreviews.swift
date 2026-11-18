#if DEBUG
import StrandDesign
import SwiftUI
import WidgetKit

// Previews use fictional data only. The `.fixed` previews render the view at the iPhone SE widget size
// (292x311 large, 292x141 medium, 141x141 small) so truncation or overlap on the smallest phone is visible.

private enum PreviewData {
    static let now = Date()
    /// The upstream placeholder carries no stress curve; a fictional one, so the XL stress block has data.
    static var widgetWithStress: WidgetSnapshot {
        var w = WidgetSnapshot.placeholder
        let start = Int64(Calendar.current.startOfDay(for: now).timeIntervalSince1970)
        w.stressSeries = (7..<Int(now.timeIntervalSince1970 - Double(start)) / 3600).map { h in
            StressPoint(ts: start + Int64(h) * 3600, level: 0.9 + 0.8 * abs(sin(Double(h) * 0.7)))
        }
        w.stressDay = WidgetSnapshot.localDayNumber(now)
        return w
    }
    static var full: NOOPPlusEntry { NOOPPlusEntry(date: now, widget: widgetWithStress, fork: .sample(now: now)) }
    static var empty: NOOPPlusEntry { NOOPPlusEntry(date: now, widget: .unavailable, fork: .empty) }
    /// Data last confirmed 3 hours ago, Smart Wake off, low battery.
    static var old: NOOPPlusEntry {
        var w = widgetWithStress
        w.updated = now.addingTimeInterval(-3 * 3600)
        w.batteryPct = 12
        var f = ForkWidgetSnapshot.sample(now: now)
        f.publishedAt = now.addingTimeInterval(-3 * 3600)
        f.smartWake = nil
        return NOOPPlusEntry(date: now, widget: w, fork: f)
    }
}

#Preview("Large", as: .systemLarge) { NOOPPlusWidget() } timeline: { PreviewData.full; PreviewData.old; PreviewData.empty }
#Preview("Medium", as: .systemMedium) { NOOPPlusWidget() } timeline: { PreviewData.full; PreviewData.old; PreviewData.empty }
#Preview("Small", as: .systemSmall) { NOOPPlusWidget() } timeline: { PreviewData.full; PreviewData.old; PreviewData.empty }
#Preview("Circular", as: .accessoryCircular) { NOOPPlusWidget() } timeline: { PreviewData.full; PreviewData.empty }
#Preview("Rectangular", as: .accessoryRectangular) { NOOPPlusWidget() } timeline: { PreviewData.full; PreviewData.old }
#Preview("Inline", as: .accessoryInline) { NOOPPlusWidget() } timeline: { PreviewData.full; PreviewData.old; PreviewData.empty }

private func fixed(_ entry: NOOPPlusEntry, _ family: WidgetFamily, _ size: CGSize) -> some View {
    NOOPPlusView(entry: entry, familyOverride: family)
        .frame(width: size.width, height: size.height)
        .background(StrandPalette.surfaceBase)
}

#Preview("SE large", traits: .sizeThatFitsLayout) { fixed(PreviewData.full, .systemLarge, CGSize(width: 292, height: 311)) }
#Preview("SE large old", traits: .sizeThatFitsLayout) { fixed(PreviewData.old, .systemLarge, CGSize(width: 292, height: 311)) }
#Preview("SE medium", traits: .sizeThatFitsLayout) { fixed(PreviewData.full, .systemMedium, CGSize(width: 292, height: 141)) }
#Preview("SE small", traits: .sizeThatFitsLayout) { fixed(PreviewData.full, .systemSmall, CGSize(width: 141, height: 141)) }

// Extra-large portrait exists from the iOS 27 SDK (Xcode 27 / Swift 6.4); older compilers never see it.
#if compiler(>=6.4)
@available(iOS 27.0, *)
#Preview("XL", as: .systemExtraLargePortrait) { NOOPPlusWidget() } timeline: { PreviewData.full; PreviewData.old; PreviewData.empty }
#Preview("XL fixed", traits: .sizeThatFitsLayout) {
    if #available(iOS 27.0, *) {
        fixed(PreviewData.full, .systemExtraLargePortrait, CGSize(width: 364, height: 740))
    }
}
#endif
#endif
