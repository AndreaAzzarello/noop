import Foundation
import OSLog
import SwiftUI
import StrandDesign
#if canImport(UIKit)
import UIKit
#endif

/// TEMP (perf investigation, fork-perf): timing and context for the on-device measurements. Everything here
/// is gated on the Display monitor actually running (`DisplayPerformanceMonitor.isRunning`), so with the Test
/// Centre "Display" mode off it costs one Bool read. Lines carry only durations in ms, counts and flags: no
/// health data. Remove together with its call sites (`grep -rn "fork-perf: TEMP"`) once the numbers are in.
///
/// - `measure` / `measureSync`: one `perf <name> <ms> ms` line (wall time, awaits included) plus a signpost.
/// - `perfPage(_:)`: tags the page on screen and counts how often its parent body is evaluated; the counts
///   ride on the next `frameSummary` line as `bodies=name=N,...`.
/// - `decorate`: appends `page=… layout=… bg=… sky=… dark=… skyCards=…` to `frameSummary` lines so every
///   frame window can be attributed to a layout/background combination.
@MainActor
enum PerfTrace {
    private static let signposter = OSSignposter(subsystem: Bundle.main.bundleIdentifier ?? "noop", category: "Perf")

    /// Moment the app began initialising (touched from `StrandiOSApp.init`); lazily set on first use otherwise.
    static let launchStart = CFAbsoluteTimeGetCurrent()

    /// Page currently on screen, set by `perfPage(_:)`.
    static var page = "-"

    /// While true the Test Centre must not stop the display monitor when it disappears, so frames are
    /// measured on every page, not only on the Test Centre.
    static var keepAlive = false

    private static var bodyCounts: [String: Int] = [:]

    static var enabled: Bool { DisplayPerformanceMonitor.shared.isRunning }

    static func emit(_ line: String) {
        guard enabled, let sink = DisplayPerformanceMonitor.shared.emit else { return }
        sink(line)
    }

    static func measure<T>(_ name: StaticString, _ body: () async -> T) async -> T {
        let state = signposter.beginInterval(name)
        let start = CFAbsoluteTimeGetCurrent()
        let result = await body()
        signposter.endInterval(name, state)
        if enabled { emit("perf \(name) \(String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - start) * 1000)) ms") }
        return result
    }

    static func measureSync<T>(_ name: StaticString, _ body: () -> T) -> T {
        let state = signposter.beginInterval(name)
        let start = CFAbsoluteTimeGetCurrent()
        let result = body()
        signposter.endInterval(name, state)
        if enabled { emit("perf \(name) \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - start) * 1000)) ms") }
        return result
    }

    /// A span closed with `defer`, so one inserted line times a whole `load()` or `.task` body, early returns
    /// included: `let perfSpan = PerfTrace.span("sleep.load"); defer { perfSpan.end() }`.
    @MainActor struct Span {
        fileprivate let name: StaticString
        fileprivate let state: OSSignpostIntervalState
        fileprivate let start: CFAbsoluteTime
        func end() {
            signposter.endInterval(name, state)
            if enabled { emit("perf \(name) \(String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - start) * 1000)) ms") }
        }
    }

    static func span(_ name: StaticString) -> Span {
        Span(name: name, state: signposter.beginInterval(name), start: CFAbsoluteTimeGetCurrent())
    }

    static func bump(_ name: String) {
        guard enabled else { return }
        bodyCounts[name, default: 0] += 1
    }

    /// Context suffix for a `frameSummary` line. `withBodies` also drains the per-page body counters.
    static func decorate(_ line: String, withBodies: Bool = true) -> String {
        var out = line + " " + context()
        if withBodies, !bodyCounts.isEmpty {
            out += " bodies=" + bodyCounts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
            bodyCounts.removeAll(keepingCapacity: true)
        }
        return out
    }

    private static func flag(_ key: String, default def: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? def
    }

    private static func context() -> String {
        let liquid = flag("noop.liquidTodayEnabled", default: true)
        let bg = flag(SceneBackgroundPrefs.enabledKey, default: true)
        let skyCards = flag(SkyBehindCardsPrefs.enabledKey, default: true)
        var dark = "?"
        var sky = "?"
        #if os(iOS)
        let isDark = UITraitCollection.current.userInterfaceStyle == .dark
            || (UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow?
                .traitCollection.userInterfaceStyle == .dark)
        dark = isDark ? "1" : "0"
        if BackgroundImageStore.shared.isActive {
            sky = "image"
        } else if !bg {
            sky = "none"
        } else if !liquid {
            sky = "scene"
        } else {
            let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
            let hour = Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
            let still = LiquidSky.pausesFrames(hour: hour, light: !isDark,
                                               poseStill: NoopMotionState.shared.poseStill(UIAccessibility.isReduceMotionEnabled))
            sky = still ? "still" : "anim"
        }
        #endif
        return "page=\(page) layout=\(liquid ? "liquid" : "classic") bg=\(bg ? "on" : "off") sky=\(sky) dark=\(dark) skyCards=\(skyCards ? 1 : 0)"
    }
}

private struct PerfPageModifier: ViewModifier {
    let name: String
    func body(content: Content) -> some View {
        content
            .onAppear { PerfTrace.page = name }
            .onDisappear { if PerfTrace.page == name { PerfTrace.page = "-" } }
    }
}

extension View {
    /// TEMP (fork-perf): tag this page for the perf lines and count one body evaluation of the caller.
    @MainActor
    func perfPage(_ name: String) -> some View {
        PerfTrace.bump(name)
        return modifier(PerfPageModifier(name: name))
    }
}
