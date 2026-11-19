import Foundation
import OSLog

/// TEMP (perf investigation): wraps an async step in an `OSSignposter` interval and, when the Test Centre
/// "Display" mode is on, writes one `perf <name> <ms> ms` line to the strap log through
/// `DisplayPerformanceMonitor.emit`. Wall time of the step as seen from the main actor, awaits included.
/// Remove together with its call sites once the on-device numbers are in.
enum PerfTrace {
    private static let signposter = OSSignposter(subsystem: Bundle.main.bundleIdentifier ?? "noop", category: "Perf")

    @MainActor
    static func measure<T>(_ name: StaticString, _ body: () async -> T) async -> T {
        let state = signposter.beginInterval(name)
        let start = CFAbsoluteTimeGetCurrent()
        let result = await body()
        signposter.endInterval(name, state)
        if let emit = DisplayPerformanceMonitor.shared.emit {
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            emit("perf \(name) \(String(format: "%.0f", ms)) ms")
        }
        return result
    }
}
