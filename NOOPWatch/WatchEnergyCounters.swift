import Foundation

// fork-perf: TEMP — Watch energy audit counters. Remove with the TEMP commit.

/// Light per-day counters for the Watch app, kept in its own UserDefaults and shown by a long press on the glance.
///
/// Counts only, from a closed vocabulary: no health values, no timestamps of samples. Nothing is sent to the phone,
/// so this adds no WatchConnectivity traffic. The Watch target does not compile `Strand/`, hence a small twin of
/// `ForkEnergyCounters` rather than a shared file (project.yml is not touched).
enum WatchEnergyCounters {
    enum Counter: String, CaseIterable {
        case appLaunch, contextReceived, contextDuplicate, complicationReload
        case workoutStart, workoutEnd, workoutRecovered
        case hrQueryStart, hrQueryStop
    }

    private static let key = "fork.watchEnergy.v1"
    private static let keptDays = 7
    private static let lock = NSLock()

    static func note(_ counter: Counter, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        let defaults = UserDefaults.standard
        var all = defaults.dictionary(forKey: key) as? [String: [String: Int]] ?? [:]
        let day = dayKey(now)
        all[day, default: [:]][counter.rawValue, default: 0] += 1
        if all.count > keptDays {
            for stale in all.keys.sorted().dropLast(keptDays) { all[stale] = nil }
        }
        defaults.set(all, forKey: key)
    }

    static func report() -> String {
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Int]] ?? [:]
        guard !all.isEmpty else { return "No counts yet." }
        return all.keys.sorted().map { day in
            let counts = all[day] ?? [:]
            let body = Counter.allCases.compactMap { c in counts[c.rawValue].map { "\(c.rawValue)=\($0)" } }
            return "\(day) " + body.joined(separator: " ")
        }.joined(separator: "\n")
    }

    private static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

import SwiftUI

/// Long press on the view shows the counts. One modifier so the glance needs a single hook line.
private struct WatchEnergyReportModifier: ViewModifier {
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .onLongPressGesture(minimumDuration: 1.5) { shown = true }
            .sheet(isPresented: $shown) {
                ScrollView {
                    Text(verbatim: WatchEnergyCounters.report())
                        .font(.system(size: 11, design: .monospaced))
                }
            }
    }
}

extension View {
    func watchEnergyReport() -> some View { modifier(WatchEnergyReportModifier()) }
}
