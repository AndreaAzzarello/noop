import Foundation

/// fork-perf: remembers the last completed Liquid Today load so that coming back to the tab (which restarts
/// `.task(id:)` with an unchanged id) does not repeat the whole load. Held in a `@State` of the view, so a new
/// view instance (layout toggle, relaunch) starts empty and always loads. Same freshness rule as the classic
/// Today cache: the same inputs and a result younger than `maxAge`.
final class LiquidLoadMemo {
    static let maxAge: TimeInterval = 20
    private var key: String?
    private var finishedAt = Date.distantPast

    func isFresh(for key: String, now: Date = Date()) -> Bool {
        self.key == key && now.timeIntervalSince(finishedAt) < Self.maxAge
    }

    func finish(key: String, now: Date = Date()) {
        self.key = key
        finishedAt = now
    }
}
