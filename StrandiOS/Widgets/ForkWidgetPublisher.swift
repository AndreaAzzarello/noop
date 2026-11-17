#if os(iOS)
import Foundation
import OSLog
import StrandAnalytics
import StrandDesign
import WhoopStore
import WidgetKit

/// Writes the fork-only `ForkWidgetSnapshot` the NOOP+ widget reads, and reloads ONLY that widget.
///
/// Designed to be invisible to the upstream publish path:
///  - `requestPublish` returns immediately; the work runs in its own task, so nothing upstream awaits it.
///  - Overlapping requests coalesce into one follow-up pass instead of stacking queries.
///  - A cheap HR fingerprint (the same witness the stress curve uses) gates the bucket query, so an
///    unchanged day costs one indexed COUNT and nothing else.
///  - The bucket → zone-run conversion runs on a detached utility task, off the main actor.
///  - Every failure is logged and swallowed; the widget just keeps its previous data.
@MainActor
enum ForkWidgetPublisher {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "noop", category: "ForkWidget")
    private static var inFlight = false
    private static var pending = false

    // MARK: Full publish (sleep + today's HR curve)

    /// Fire-and-forget. Safe to call on every upstream publish.
    static func requestPublish(from model: AppModel) {
        if inFlight { pending = true; return }
        inFlight = true
        Task { @MainActor in
            repeat {
                pending = false
                await publish(from: model)
            } while pending
            inFlight = false
        }
    }

    private static func publish(from model: AppModel) async {
        let now = Date()
        let calendar = Calendar.current
        let day = WidgetSnapshot.localDayNumber(now, calendar: calendar)
        let from = Int(calendar.startOfDay(for: now).timeIntervalSince1970)
        let to = Int(now.timeIntervalSince1970)
        let zoneSet = model.profile.hrZoneSet
        let sleepMin = model.repo.today?.totalSleepMin.map { Int($0.rounded()) }

        let previous = ForkWidgetSnapshot.load()

        // Gate: same day, same HR rows, same zone boundaries → the curve cannot have changed.
        let fingerprint = await model.repo.hrFingerprintUnion(from: from, to: to)
        let gate = fingerprint.isEmpty ? nil : "\(day)|\(fingerprint)|\(zoneKey(zoneSet))"
        var hrDay: ForkHRDay?
        var hrGate = previous?.hrFingerprint
        if let gate, gate == previous?.hrFingerprint, previous?.hrDay?.day == day {
            hrDay = previous?.hrDay
        } else if let gate {
            let buckets = await model.repo.hrBuckets(from: from, to: to, bucketSeconds: bucketSeconds)
            hrDay = await Task.detached(priority: .utility) {
                buildHRDay(buckets: buckets, zoneSet: zoneSet, day: day)
            }.value
            hrGate = gate
        } else {
            // No store yet: keep whatever was there, but only if it is still today's.
            hrDay = previous?.hrDay?.day == day ? previous?.hrDay : nil
        }

        // Re-read after the awaits so a Smart Wake publish that landed meanwhile is not overwritten.
        var next = ForkWidgetSnapshot.load() ?? .empty
        let before = next
        next.sleepMin = sleepMin
        next.sleepDay = sleepMin == nil ? nil : day
        next.hrDay = hrDay
        next.hrFingerprint = hrGate
        commit(next, previous: before, now: now)
    }

    // MARK: Smart Wake

    /// Called when the Smart Wake schedule, toggle or recorded skip changes (fork-owned call sites only).
    static func publishSmartWake(from model: AppModel, schedule: SmartWakeSchedule) {
        let now = Date()
        let enabled = model.behavior.smartWakeEnabled
        // The SAME resolver the strap alarm re-arm uses; it also drops a spent skip, as it does there.
        let armFrom = SmartWakeFirmwareSkip.armFrom(now: now, smartWakeEnabled: enabled)
        var next = ForkWidgetSnapshot.load() ?? .empty
        let before = next
        next.smartWake = enabled ? schedule : nil
        next.smartWakeSkipUntil = enabled && armFrom > now ? armFrom : nil
        commit(next, previous: before, now: now)
    }

    // MARK: Shared

    /// Persist and reload the NOOP+ widget only when something it renders changed, or when the last
    /// confirmation is old enough that the "data is old" hint could otherwise appear for fresh data.
    private static func commit(_ next: ForkWidgetSnapshot, previous: ForkWidgetSnapshot, now: Date) {
        let unchanged = next.contentEquals(previous)
        let fresh = now.timeIntervalSince(previous.publishedAt) < ForkWidgetSnapshot.republishAfter
        if unchanged && fresh && next.hrFingerprint == previous.hrFingerprint { return }
        var out = next
        out.publishedAt = now
        guard out.save() else {
            log.error("fork widget snapshot not saved (App Group unavailable or encode failed)")
            return
        }
        if !unchanged || !fresh {
            WidgetCenter.shared.reloadTimelines(ofKind: ForkWidgetSnapshot.kind)
        }
    }

    /// Mean-bpm buckets, matching the Today trend chart.
    private static let bucketSeconds = 300

    private static func zoneKey(_ zoneSet: HRZoneSet) -> String {
        "\(Int(zoneSet.maxHR))/" + zoneSet.zones.map { String(Int($0.lower.rounded())) }.joined(separator: ",")
    }

    /// Pure and off-main: buckets → single-zone runs through the SAME model the workout chart uses
    /// (`HRZoneChartModel.runs`), so the widget cannot colour a stretch differently from the app.
    /// A gap longer than `HrTrace.gapSec` starts a new segment, so the pen lifts instead of drawing a
    /// line across missing data.
    nonisolated static func buildHRDay(buckets: [HRBucket], zoneSet: HRZoneSet, day: Int) -> ForkHRDay? {
        let sorted = buckets.filter { $0.bpm > 0 }.sorted { $0.ts < $1.ts }
        guard let last = sorted.last else { return nil }
        var points: [TrendPoint] = []
        var segment = 0
        for (i, b) in sorted.enumerated() {
            if i > 0, Int64(b.ts - sorted[i - 1].ts) > HrTrace.gapSec { segment += 1 }
            points.append(TrendPoint(date: Date(timeIntervalSince1970: TimeInterval(b.ts)),
                                     value: b.bpm, segment: String(segment)))
        }
        let runs: [ForkZoneRun]
        if let usable = HRZoneChartModel.usableZoneSet(zoneSet) {
            runs = HRZoneChartModel.runs(points, zoneSet: usable).map { run in
                ForkZoneRun(zone: run.zone, points: run.points.map(hrPoint))
            }
        } else {
            // Zones unusable: one neutral run per segment (zone 0 draws in the tertiary colour).
            runs = Dictionary(grouping: points, by: \.segment)
                .sorted { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }
                .map { ForkZoneRun(zone: 0, points: $0.value.map(hrPoint)) }
        }
        let lo = sorted.map(\.minBpm).min() ?? 0
        let hi = sorted.map(\.maxBpm).max() ?? 0
        return ForkHRDay(day: day, throughTs: Int64(last.ts), minBpm: Int(lo.rounded()),
                         maxBpm: Int(hi.rounded()), runs: runs)
    }

    private nonisolated static func hrPoint(_ p: TrendPoint) -> HrPoint {
        HrPoint(ts: Int64(p.date.timeIntervalSince1970), bpm: Int(p.value.rounded()))
    }
}
#endif
