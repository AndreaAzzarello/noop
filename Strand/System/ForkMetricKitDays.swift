import Foundation

// fork-perf: TEMP — daily MetricKit summary store for the energy audit.

/// One day of what iOS measured for NOOP, saved by `ForkMetricKitProbe` and shown in the Test Centre.
///
/// Numbers only (seconds, bytes, counts). No health data. Pure and shared so `StrandTests` covers the
/// encoding and the summary line; the subscriber that fills it is iOS-only.
struct ForkMetricKitDay: Codable, Equatable {
    var day: String                  // yyyy-MM-dd of the payload's begin, local
    var appVersion: String?
    var foregroundSec: Double?
    var backgroundSec: Double?
    var backgroundLocationSec: Double?
    var cpuSec: Double?
    var wifiBytes: Double?           // upload + download
    var cellularBytes: Double?
    var diskWriteBytes: Double?
    var avgPixelLuminance: Double?
    var exits: [String: Int] = [:]   // reason → count (background exits that matter for battery)
    var cpuExceptions = 0
    var diskWriteExceptions = 0
    var hangs = 0
    var crashes = 0

    func line() -> String {
        func n(_ v: Double?, _ f: String = "%.0f") -> String { v.map { String(format: f, $0) } ?? "?" }
        var parts = ["\(day)",
                     "fg=\(n(foregroundSec))s", "bg=\(n(backgroundSec))s", "cpu=\(n(cpuSec))s",
                     "bgLoc=\(n(backgroundLocationSec))s",
                     "wifi=\(n(wifiBytes.map { $0 / 1_048_576 }, "%.1f"))MB",
                     "cell=\(n(cellularBytes.map { $0 / 1_048_576 }, "%.1f"))MB",
                     "diskW=\(n(diskWriteBytes.map { $0 / 1_048_576 }, "%.1f"))MB",
                     "lum=\(n(avgPixelLuminance, "%.0f"))"]
        if !exits.isEmpty {
            parts.append("exits[" + exits.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",") + "]")
        }
        parts.append("cpuExc=\(cpuExceptions) diskExc=\(diskWriteExceptions) hangs=\(hangs) crashes=\(crashes)")
        return parts.joined(separator: " ")
    }
}

enum ForkMetricKitDays {
    static let keptDays = 14

    static func defaultFileURL() -> URL? {
        ForkEnergyCounters.defaultFileURL()?.deletingLastPathComponent().appendingPathComponent("metrickit-days.json")
    }

    /// Insert or replace by `day`, newest last, bounded.
    static func merged(_ existing: [ForkMetricKitDay], with day: ForkMetricKitDay) -> [ForkMetricKitDay] {
        var out = existing.filter { $0.day != day.day }
        out.append(day)
        out.sort { $0.day < $1.day }
        return Array(out.suffix(keptDays))
    }

    static func load(from url: URL? = defaultFileURL()) -> [ForkMetricKitDay] {
        guard let url, let data = try? Data(contentsOf: url),
              let days = try? JSONDecoder().decode([ForkMetricKitDay].self, from: data) else { return [] }
        return days
    }

    static func save(_ days: [ForkMetricKitDay], to url: URL? = defaultFileURL()) {
        guard let url, let data = try? JSONEncoder().encode(days) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func report(_ days: [ForkMetricKitDay]) -> String {
        guard !days.isEmpty else { return "MetricKit: no daily payload received yet (iOS delivers about one per day)." }
        return (["MetricKit daily summary"] + days.map { $0.line() }).joined(separator: "\n")
    }
}
