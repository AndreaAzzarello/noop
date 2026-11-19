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
    /// Start of the pass now running, and the id of the run that owns `inFlight`.
    private static var passStartedAt: Date?
    private static var generation = 0
    /// A pass older than this is presumed stuck (e.g. awaiting a store open that never returns).
    static let stuckAfter: TimeInterval = 120

    // MARK: Full publish (sleep + today's HR curve)

    /// Fire-and-forget. Safe to call on every upstream publish.
    ///
    /// Only one run owns `inFlight`. If its current pass has been going for more than `stuckAfter`, the next
    /// request takes over under a new generation; the abandoned run can no longer commit, loop again or
    /// release the flag, so two publishes never write at the same time.
    static func requestPublish(from model: AppModel) {
        if inFlight {
            guard let started = passStartedAt, Date().timeIntervalSince(started) > stuckAfter else {
                pending = true
                return
            }
            log.error("fork widget publish pass stuck for over \(Int(stuckAfter))s; starting a new one")
        }
        generation += 1
        let mine = generation
        inFlight = true
        pending = false
        Task { @MainActor in
            defer {
                if generation == mine { inFlight = false; passStartedAt = nil }
            }
            while generation == mine {
                pending = false
                passStartedAt = Date()
                await publish(from: model, generation: mine)
                if !pending { break }
            }
        }
    }

    private static func publish(from model: AppModel, generation token: Int) async {
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

        // Extra-large blocks. Vitals and stages come from rows already in memory; the workout and the
        // 7-day strip need a database read, which only runs when `extrasKey` moved.
        let extras = await buildExtras(from: model, now: now, day: day, hrGate: gate, previous: previous)

        // A run that was replaced while it waited must not write over the newer one.
        guard token == generation else { return }
        // Re-read after the awaits so a Smart Wake publish that landed meanwhile is not overwritten.
        let before = ForkWidgetSnapshot.load() ?? .empty
        let next = before.applyingFullPublish(
            sleepMin: sleepMin, sleepDay: sleepMin == nil ? nil : day, hrDay: hrDay, hrFingerprint: hrGate,
            vitals: extras.vitals, sleepStages: extras.sleepStages, workout: extras.workout,
            trend: extras.trend, extrasKey: extras.key)
        commit(next, previous: before, now: now)
    }

    // MARK: Extra-large extras

    private struct Extras {
        var vitals: ForkVitals?
        var sleepStages: ForkSleepStages?
        var workout: ForkWorkout?
        var trend: ForkTrend?
        var key: String?
    }

    /// The same resolvers the Today screen uses for each figure, so a widget block and the app card cannot
    /// disagree: `Repository.lastRespDay` (bounded carry), `SkinTempDisplay.leadReading` (absolute first,
    /// the user's Settings choice), `TodayWorkoutSummary.todaysWorkouts`, `WorkoutWindowMetrics.effort`.
    private static func buildExtras(from model: AppModel, now: Date, day: Int, hrGate: String?,
                                    previous: ForkWidgetSnapshot?) async -> Extras {
        let repo = model.repo
        var out = Extras()
        let defaults = UserDefaults.standard

        // Vitals (in memory).
        let row = repo.today
        let todayKey = row?.day ?? max(Repository.logicalDayKey(now), Repository.localDayKey(now))
        let resp = row?.respRateBpm ?? Repository.lastRespDay(days: repo.days, todayKey: todayKey)?.respRateBpm
        let skinRow = [row, Repository.lastVitalsDay(days: repo.days, todayKey: todayKey),
                       Repository.lastSkinTempReadingDay(days: repo.days, todayKey: todayKey)]
            .compactMap { $0 }
            .first { $0.skinTempC != nil || $0.skinTempDevC != nil }
        let preferred = SkinTempDisplay.Kind(rawValue: defaults.string(forKey: UnitPrefs.skinTempDisplayKey) ?? "") ?? .absolute
        let system = UnitSystem(rawValue: defaults.string(forKey: UnitPrefs.systemKey) ?? "") ?? .metric
        let fahrenheit = UnitPrefs.resolveTemperature(
            system: system, override: defaults.string(forKey: UnitPrefs.temperatureKey) ?? "") == .fahrenheit
        let skinText = SkinTempDisplay.leadReading(absC: skinRow?.skinTempC, devC: skinRow?.skinTempDevC, prefer: preferred)
            .map { ForkDecimal.localize(SkinTempDisplay.formatReading($0, fahrenheit: fahrenheit),
                                        locale: AppLanguage.activeLocale) }
        let respText = resp.map { String(format: "%.1f", locale: AppLanguage.activeLocale, $0) }
        if respText != nil || skinText != nil {
            out.vitals = ForkVitals(day: day, respText: respText, skinText: skinText)
        }

        // Sleep stages (in memory). Hidden when the night has no stage minutes at all.
        if let r = row, let deep = r.deepMin, let rem = r.remMin, let light = r.lightMin, deep + rem + light > 0 {
            let eff = r.efficiency.map { $0 <= 1.0 ? $0 * 100 : $0 }
            out.sleepStages = ForkSleepStages(day: day, deepMin: Int(deep.rounded()), remMin: Int(rem.rounded()),
                                              lightMin: Int(light.rounded()), efficiencyPct: eff.map { Int($0.rounded()) })
        }

        // Workout and 7-day strip: database reads, gated.
        let scaleRaw = defaults.string(forKey: UnitPrefs.effortScaleKey) ?? ""
        let key = "\(day)|\(hrGate ?? "")|\(repo.refreshSeq)|\(scaleRaw)"
        out.key = key
        // A snapshot from another format version is rebuilt once, whatever the gate says.
        if key == previous?.extrasKey, previous?.formatVersion == ForkWidgetSnapshot.currentFormat {
            out.workout = previous?.workout
            out.trend = previous?.trend
            return out
        }

        let scale = UnitPrefs.resolveEffortScale(scaleRaw)
        let rows = await repo.workoutRows(days: 2)
        if let w = TodayWorkoutSummary.todaysWorkouts(rows, now: now).first {
            let effortText: String? = w.strain.flatMap { strain in
                guard strain.isFinite else { return nil }
                return scale == .whoop
                    ? ForkDecimal.localize(UnitFormatter.effortDisplay(strain, scale: scale), locale: AppLanguage.activeLocale)
                    : String(Int(strain.rounded()))
            }
            let seconds = w.durationS ?? Double(w.endTs - w.startTs)
            out.workout = ForkWorkout(
                day: day, sport: w.sport,
                sportName: Bundle.main.localizedString(forKey: WorkoutSource.displaySport(w.sport),
                                                       value: WorkoutSource.displaySport(w.sport), table: nil),
                startTs: Int64(w.startTs), durationMin: max(1, Int((seconds / 60).rounded())),
                effortText: effortText,
                effortWhoop: scale == .whoop,
                avgHr: w.avgHr, maxHr: w.maxHr,
                kcal: w.energyKcal.flatMap { $0.isFinite && $0 > 0 ? Int($0.rounded()) : nil })
        }

        let restSeries = await repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
        let restByDay = Dictionary(restSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        let byDay = Dictionary(repo.days.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })
        let calendar = Calendar.current
        let strip: [ForkTrendDay] = (0..<7).reversed().map { back in
            let date = calendar.date(byAdding: .day, value: -back, to: now) ?? now
            let k = Repository.localDayKey(date)
            let m = byDay[k]
            return ForkTrendDay(charge: m?.recovery.map { Int($0.rounded()) },
                                effort: m?.strain.map { Int($0.rounded()) },
                                rest: restByDay[k].map { Int($0.rounded()) })
        }
        out.trend = ForkTrend(day: day, days: strip)
        return out
    }

    // MARK: Smart Wake

    /// Called when the Smart Wake schedule, toggle or recorded skip changes (fork-owned call sites only).
    static func publishSmartWake(from model: AppModel, schedule: SmartWakeSchedule) {
        let now = Date()
        let enabled = model.behavior.smartWakeEnabled
        // The SAME resolver the strap alarm re-arm uses; it also drops a spent skip, as it does there.
        let armFrom = SmartWakeFirmwareSkip.armFrom(now: now, smartWakeEnabled: enabled)
        let before = ForkWidgetSnapshot.load() ?? .empty
        let next = before.applyingSmartWake(schedule: enabled ? schedule : nil,
                                            skipUntil: enabled && armFrom > now ? armFrom : nil)
        commit(next, previous: before, now: now)
    }

    // MARK: Shared

    /// Persist and reload the NOOP+ widget only when something it renders changed, or when the last
    /// confirmation is old enough that the "data is old" hint could otherwise appear for fresh data.
    private static func commit(_ next: ForkWidgetSnapshot, previous: ForkWidgetSnapshot, now: Date) {
        let decision = ForkWidgetSnapshot.commitDecision(next: next, previous: previous, now: now)
        guard decision.save else { return }
        var out = next
        out.publishedAt = now
        guard out.save() else {
            log.error("fork widget snapshot not saved (App Group unavailable or encode failed)")
            return
        }
        if decision.reload {
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
