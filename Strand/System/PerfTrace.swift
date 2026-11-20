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

    // MARK: publish counters (TEMP)
    // `objectWillChange` emissions per observed object since the last `frameSummary`, as `name=emissions/turns`:
    // `turns` counts distinct main-queue turns, so 40/3 is three bursts and 40/40 is forty separate publishes.
    private static var publishCounts: [String: Int] = [:]
    private static var publishTurns: [String: Int] = [:]
    private static var publishLastTurn: [String: Int] = [:]
    private static var turnId = 0
    private static var turnOpen = false
    private static var linkIntervalSum: Double = 0
    private static var linkIntervalCount = 0

    // MARK: defaults attribution (TEMP)
    // Which `UserDefaults.standard` keys changed behind each `didChangeNotification`, from a snapshot diff.
    // `defaultsSame` counts notifications that found no difference at observation time: a rewrite of an
    // equal value, or a write already folded into an earlier notification's diff (the notification is
    // delivered a turn late, so two writes can share one diff). `defaultsDiffMs` is what the diff itself
    // cost on the main thread, so this instrumentation can be discounted from the numbers it reports.
    private static var defaultsSnapshot: [String: Any]?
    private static var defaultsKeyChanges: [String: Int] = [:]
    private static var defaultsSame = 0
    private static var defaultsDiffSeconds: Double = 0

    /// Fold one `didChangeNotification` into the per-key counters.
    static func noteDefaultsNotification() {
        guard enabled else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        let now = UserDefaults.standard.dictionaryRepresentation()
        defer { defaultsDiffSeconds += CFAbsoluteTimeGetCurrent() - t0 }
        guard let before = defaultsSnapshot else {
            defaultsSnapshot = now
            return
        }
        var changed = 0
        for (key, value) in now {
            if let old = before[key], (old as AnyObject).isEqual(value) { continue }
            defaultsKeyChanges[key, default: 0] += 1
            changed += 1
        }
        for key in before.keys where now[key] == nil {
            defaultsKeyChanges[key, default: 0] += 1
            changed += 1
        }
        if changed == 0 { defaultsSame += 1 }
        defaultsSnapshot = now
    }

    /// Drop the snapshot so a monitor restart does not attribute the gap to one notification.
    static func resetDefaultsSnapshot() { defaultsSnapshot = nil }

    /// Writes `perf.probe` 20 times, one per main-queue turn 20 ms apart, so the next frame lines show whether
    /// a burst of foreign defaults writes alone re-evaluates `root.app` / `root.tabs` / the tabs (the question
    /// behind replacing the root `@AppStorage`s). The probe key is read by nothing.
    static func runDefaultsProbe() {
        guard enabled else { return }
        emit("perf probe defaults start writes=20")
        for i in 0..<20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02 * Double(i)) {
                UserDefaults.standard.set(i, forKey: "perf.probe")
                if i == 19 { emit("perf probe defaults end") }
            }
        }
    }

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

    /// Count one publish of `name` (an `ObservableObject`, a `@Published` seq, a defaults write).
    static func notePublish(_ name: String) {
        guard enabled else { return }
        if !turnOpen {
            turnOpen = true
            turnId += 1
            DispatchQueue.main.async { turnOpen = false }
        }
        publishCounts[name, default: 0] += 1
        if publishLastTurn[name] != turnId {
            publishLastTurn[name] = turnId
            publishTurns[name, default: 0] += 1
        }
    }

    /// Display-link frame interval as the system scheduled it (`targetTimestamp - timestamp`), in seconds.
    static func noteLinkInterval(_ seconds: Double) {
        guard seconds > 0, seconds < 1 else { return }
        linkIntervalSum += seconds
        linkIntervalCount += 1
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
        if withBodies {
            if !publishCounts.isEmpty {
                out += " publishes=" + publishCounts.sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)/\(publishTurns[$0.key] ?? 0)" }.joined(separator: ",")
                publishCounts.removeAll(keepingCapacity: true)
                publishTurns.removeAll(keepingCapacity: true)
            }
            if !defaultsKeyChanges.isEmpty || defaultsSame > 0 {
                out += " defaultsKeys=" + defaultsKeyChanges.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                    .prefix(6).map { "\($0.key)=\($0.value)" }.joined(separator: ",")
                out += " defaultsSame=\(defaultsSame)"
                out += " defaultsDiffMs=" + String(format: "%.1f", defaultsDiffSeconds * 1000)
                defaultsKeyChanges.removeAll(keepingCapacity: true)
                defaultsSame = 0
                defaultsDiffSeconds = 0
            }
            if linkIntervalCount > 0 {
                out += " refresh=" + String(format: "%.1f", linkIntervalSum / Double(linkIntervalCount) * 1000) + "ms"
                linkIntervalSum = 0
                linkIntervalCount = 0
            }
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

extension View {
    /// TEMP (fork-perf): count one body evaluation of the caller under `name`, without tagging a page.
    @MainActor
    func perfCount(_ name: String) -> some View {
        PerfTrace.bump(name)
        return self
    }
}
