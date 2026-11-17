#if DEBUG
import StrandDesign
import SwiftUI
import WidgetKit

// Previews use fictional data only. The `.fixed` previews render the view at the iPhone SE widget size
// (292x311 large, 292x141 medium, 141x141 small) so truncation or overlap on the smallest phone is visible.

private enum PreviewData {
    static let now = Date()
    static var full: NOOPPlusEntry { NOOPPlusEntry(date: now, widget: .placeholder, fork: .sample(now: now)) }
    static var empty: NOOPPlusEntry { NOOPPlusEntry(date: now, widget: .unavailable, fork: .empty) }
    /// Data last confirmed 3 hours ago, Smart Wake off, low battery.
    static var old: NOOPPlusEntry {
        var w = WidgetSnapshot.placeholder
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
#endif
