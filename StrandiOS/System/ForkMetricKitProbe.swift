#if os(iOS)
import Foundation
import MetricKit

// fork-perf: TEMP — second MetricKit subscriber for the energy audit. `MetricKitLog` stays as it is.

/// Saves one `ForkMetricKitDay` per delivered payload (and per past payload at launch) for the Test Centre.
///
/// MetricKit offers no "wakeups" metric: wakes are counted by `ForkEnergyCounters` instead. There is no
/// separate energy diagnostic either; background CPU overruns arrive as CPU exception diagnostics, counted here.
final class ForkMetricKitProbe: NSObject, MXMetricManagerSubscriber {
    static let shared = ForkMetricKitProbe()
    private let queue = DispatchQueue(label: "fork.metrickit.probe")

    func attach() {
        MXMetricManager.shared.add(self)
        let past = MXMetricManager.shared.pastPayloads
        let pastDiag = MXMetricManager.shared.pastDiagnosticPayloads
        queue.async { [self] in
            past.forEach(store)
            pastDiag.forEach(store)
        }
    }

    func didReceive(_ payloads: [MXMetricPayload]) { queue.async { [self] in payloads.forEach(store) } }
    func didReceive(_ payloads: [MXDiagnosticPayload]) { queue.async { [self] in payloads.forEach(store) } }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func current(day key: String, version: String?) -> ForkMetricKitDay {
        ForkMetricKitDays.load().first { $0.day == key } ?? ForkMetricKitDay(day: key, appVersion: version)
    }

    private func store(_ p: MXMetricPayload) {
        let key = Self.dayFormatter.string(from: p.timeStampBegin)
        var d = current(day: key, version: p.latestApplicationVersion)
        d.appVersion = p.latestApplicationVersion
        d.foregroundSec = p.applicationTimeMetrics?.cumulativeForegroundTime.converted(to: .seconds).value
        d.backgroundSec = p.applicationTimeMetrics?.cumulativeBackgroundTime.converted(to: .seconds).value
        d.backgroundLocationSec = p.applicationTimeMetrics?.cumulativeBackgroundLocationTime.converted(to: .seconds).value
        d.cpuSec = p.cpuMetrics?.cumulativeCPUTime.converted(to: .seconds).value
        if let n = p.networkTransferMetrics {
            d.wifiBytes = n.cumulativeWifiUpload.converted(to: .bytes).value + n.cumulativeWifiDownload.converted(to: .bytes).value
            d.cellularBytes = n.cumulativeCellularUpload.converted(to: .bytes).value + n.cumulativeCellularDownload.converted(to: .bytes).value
        }
        d.diskWriteBytes = p.diskIOMetrics?.cumulativeLogicalWrites.converted(to: .bytes).value
        d.avgPixelLuminance = p.displayMetrics?.averagePixelLuminance?.averageMeasurement.value
        if let exits = p.applicationExitMetrics {
            let fg = exits.foregroundExitData, bg = exits.backgroundExitData
            d.exits = [
                "cpuLimit": bg.cumulativeCPUResourceLimitExitCount,
                "memLimit": fg.cumulativeMemoryResourceLimitExitCount + bg.cumulativeMemoryResourceLimitExitCount,
                "memPressure": bg.cumulativeMemoryPressureExitCount,
                "bgTaskTimeout": bg.cumulativeBackgroundTaskAssertionTimeoutExitCount,
                "lockedFile": bg.cumulativeSuspendedWithLockedFileExitCount,
                "watchdog": fg.cumulativeAppWatchdogExitCount + bg.cumulativeAppWatchdogExitCount,
            ].filter { $0.value > 0 }
        }
        ForkMetricKitDays.save(ForkMetricKitDays.merged(ForkMetricKitDays.load(), with: d))
    }

    private func store(_ p: MXDiagnosticPayload) {
        let key = Self.dayFormatter.string(from: p.timeStampBegin)
        var d = current(day: key, version: nil)
        d.cpuExceptions = p.cpuExceptionDiagnostics?.count ?? 0
        d.diskWriteExceptions = p.diskWriteExceptionDiagnostics?.count ?? 0
        d.hangs = p.hangDiagnostics?.count ?? 0
        d.crashes = p.crashDiagnostics?.count ?? 0
        ForkMetricKitDays.save(ForkMetricKitDays.merged(ForkMetricKitDays.load(), with: d))
    }
}
#endif
