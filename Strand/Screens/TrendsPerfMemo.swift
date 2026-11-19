import Foundation
import StrandDesign

/// fork-perf: reference-type memo for `TrendsView`, held in a `@State` so a new view instance starts empty.
/// - The year heat-strip parsed a date for every day of history (365 up to 2000+) on every body pass; the
///   parsed days are now kept per (refreshSeq, window, day count).
/// - The sleep-performance series load restarts with every tab visit; it is skipped when the same
///   (day count, refreshSeq) has already been loaded.
final class TrendsPerfMemo {
    private var stripKey = ""
    private var stripDays: [RecoveryDay] = []
    private var sleepPerfKey = ""

    func yearStripDays(for key: String, build: () -> [RecoveryDay]) -> [RecoveryDay] {
        if key != stripKey {
            stripDays = build()
            stripKey = key
        }
        return stripDays
    }

    func sleepPerfLoaded(for key: String) -> Bool { sleepPerfKey == key }
    func markSleepPerfLoaded(_ key: String) { sleepPerfKey = key }
}
