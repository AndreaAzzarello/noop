import SwiftUI
import StrandDesign

#if os(iOS)
/// fork-perf: the date in the Today top bar that periodically flashes a one-word "Swipe" / "Tap" hint. The hint
/// state used to live on `TodayView`, so each of its two writes per cycle re-ran the whole Today body; here it
/// is private to this label, so only the label re-evaluates. Same text, colours, animation and cadence.
struct DayNavHintLabel: View {
    let dateText: String
    @State private var hint: String?

    private static var hints: [String] { [String(localized: "Swipe", table: "Fork"), String(localized: "Tap", table: "Fork")] }

    var body: some View {
        Text(hint ?? dateText)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(hint != nil ? StrandPalette.accent : StrandPalette.textPrimary)
            .lineLimit(1)
            .fixedSize()
            .contentTransition(.opacity)
            // Cycle the swipe/tap hint: roughly every 10s flash a one-word hint for ~1.5s, alternating "Swipe" /
            // "Tap", then return to the date. One async loop, auto-cancelled when the label goes away.
            .task {
                var i = 0
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    if Task.isCancelled { break }
                    withAnimation(.easeInOut(duration: 0.3)) { hint = Self.hints[i % Self.hints.count] }
                    i += 1
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    withAnimation(.easeInOut(duration: 0.3)) { hint = nil }
                }
            }
    }
}
#endif
