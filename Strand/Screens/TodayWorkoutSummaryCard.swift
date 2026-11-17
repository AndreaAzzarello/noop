import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Today: summary of today's workouts
//
// The most recent workout of TODAY in full (header, average HR, a one-line zone summary, the zone-coloured
// HR curve) and up to three more as compact rows. A tap opens `WorkoutDetailView`; the pencil opens the
// same `ManualWorkoutSheet` the Workouts list uses, for the rows that list lets the user edit.
//
// The caller passes the workout rows it already loaded (`TodayView.workouts` / `LiquidTodayView.workouts`)
// instead of this card querying again, which has two consequences:
//  - the card appears the moment Today's own refresh (`repo.refreshSeq`) delivers the new row, e.g. right
//    after `AutoWorkoutCard` saved a detected activity, with no extra trigger;
//  - when there is nothing to show the body is an `if` with no branch, so it adds no spacing to the Today
//    stack (an always-present zero-size placeholder would add one gap).
//
// HR samples and zone minutes are read once per workout (and per zone set) and kept in `@State`; every
// string and formatter is built in the loader, never in `body`.

struct TodayWorkoutSummaryCard: View {

    /// Workout rows already loaded by the host screen (any order, any range).
    let workouts: [WorkoutRow]
    /// False while browsing a past day: today's workouts are not shown over another day's data.
    let isViewingToday: Bool

    /// Most compact rows shown below the featured workout.
    private static let maxCompactRows = 3

    var body: some View {
        if isViewingToday {
            let today = TodayWorkoutSummary.todaysWorkouts(workouts, now: Date())
            if let featured = today.first {
                TodayWorkoutSummaryContent(featured: featured,
                                           others: Array(today.dropFirst().prefix(Self.maxCompactRows)))
            }
        }
    }
}

// MARK: - Content

private struct TodayWorkoutSummaryContent: View {

    let featured: WorkoutRow
    let others: [WorkoutRow]

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var intelligence: IntelligenceEngine

    private struct RowTarget: Identifiable {
        let row: WorkoutRow
        let id = UUID()
    }
    @State private var detailTarget: RowTarget?
    @State private var editTarget: RowTarget?

    /// HR samples of the featured workout, read once for (row, zone set).
    private struct Samples {
        let row: WorkoutRow
        let zoneSet: HRZoneSet
        let points: [TrendPoint]
        let derivedMinutes: [Double]?
    }
    @State private var samples: Samples?

    /// The Effort scale the user picked; part of `LoadKey` so a change re-formats the Effort figure.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue

    /// Everything the body shows, precomputed by `makeDisplay`.
    private struct Display {
        struct Compact: Identifiable {
            let row: WorkoutRow
            let name: String
            let line: String
            var id: String { "\(row.startTs)-\(row.sport)-\(row.source)" }
        }
        let name: String
        let header: String
        let avgHr: Int?
        /// Effort and energy of the featured workout; nil (and not drawn) when the row has none.
        let effort: WorkoutWindowMetrics.Effort?
        let kcal: String?
        let sentence: String?
        let points: [TrendPoint]
        let range: ClosedRange<Double>
        let axis: ClosedRange<Date>?
        let timeFormatter: DateFormatter
        let compact: [Compact]
    }
    @State private var display: Display?

    /// Re-runs the loader when the rows or the zone set change; an empty read is retried on a refresh.
    private struct LoadKey: Equatable {
        let rows: [WorkoutRow]
        let zoneSet: HRZoneSet
        let retrySeq: Int
        let effortScaleRaw: String
    }

    private var zoneSet: HRZoneSet { profile.hrZoneSet }

    private var loadKey: LoadKey {
        let empty = samples.map { $0.points.isEmpty } ?? true
        return LoadKey(rows: [featured] + others, zoneSet: zoneSet, retrySeq: empty ? repo.refreshSeq : 0,
                       effortScaleRaw: effortScaleRaw)
    }

    // MARK: Body

    var body: some View {
        NoopCard(tint: StrandPalette.effortColor) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                featuredBlock
                if let compact = display?.compact, !compact.isEmpty {
                    Divider().overlay(StrandPalette.hairline)
                    ForEach(compact) { item in compactRow(item) }
                }
            }
        }
        .task(id: loadKey) { await load() }
        .sheet(item: $detailTarget) { target in
            NavigationStack {
                WorkoutDetailView(row: target.row)
                    .environmentObject(repo)
            }
            #if os(iOS)
            .noopSheetPresentation(largeFirst: true)
            #else
            .frame(width: 620, height: 720)
            #endif
        }
        .sheet(item: $editTarget) { target in
            ManualWorkoutSheet(editing: target.row) { row, replacing in
                Task {
                    await repo.saveManualWorkout(row, replacing: replacing)
                    await intelligence.analyzeRecent()
                    await repo.refresh()
                }
            }
        }
    }

    // MARK: Featured workout

    private var featuredBlock: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                detailTarget = RowTarget(row: featured)
            } label: {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    header
                    statsRow
                    if let sentence = display?.sentence { zoneSummary(sentence) }
                    chart
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(LiquidPressStyle())

            if TodayWorkoutSummary.isEditable(featured) {
                Button {
                    editTarget = RowTarget(row: featured)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Edit…"))
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: NoopMetrics.space3) {
            Image(systemName: sportSymbol(featured.sport))
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(StrandPalette.effortColor)
                .frame(width: 40, height: 40)
                .background(StrandPalette.effortColor.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(display?.name ?? WorkoutSource.displaySport(featured.sport)))
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                if let line = display?.header {
                    Text(line)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            Spacer(minLength: 0)
            // Room for the pencil, which sits above this label so its tap is its own.
            if TodayWorkoutSummary.isEditable(featured) {
                Color.clear.frame(width: 36, height: 36)
            }
        }
    }

    /// Avg HR, then Effort and energy when the row has them. Nothing is drawn for a missing figure.
    @ViewBuilder private var statsRow: some View {
        let avg = display?.avgHr, effort = display?.effort, kcal = display?.kcal
        if avg != nil || effort != nil || kcal != nil {
            HStack(alignment: .bottom, spacing: NoopMetrics.space4) {
                if let avg { averageBlock(avg) }
                if let effort {
                    secondaryStat("Effort", value: effort.value,
                                  caption: effort.scale == .whoop ? String(localized: "of 21", table: "Fork")
                                                                  : String(localized: "of 100"))
                }
                if let kcal { secondaryStat("Calories", value: kcal, caption: "kcal") }
            }
        }
    }

    private func secondaryStat(_ label: LocalizedStringKey, value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).strandOverline()
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: value)
                    .font(StrandFont.number(22))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(verbatim: caption)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func averageBlock(_ avg: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Avg HR").strandOverline()
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "\(avg)")
                    .font(StrandFont.number(34))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("bpm")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func zoneSummary(_ sentence: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("HR Zones").strandOverline()
            Text(sentence)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var chart: some View {
        if let d = display, d.points.count > 1 {
            ZoneColoredHRChart(
                points: d.points,
                zoneSet: zoneSet,
                valueRange: d.range,
                height: 150,
                valueFormat: { String(localized: "\(Int($0.rounded())) bpm") },
                dateFormat: { [formatter = d.timeFormatter] in formatter.string(from: $0) },
                accessibilityLabel: String(localized: "Heart rate during \(d.name)"),
                workoutTimeAxis: d.axis
            )
        }
    }

    // MARK: Compact rows

    private func compactRow(_ item: Display.Compact) -> some View {
        Button {
            detailTarget = RowTarget(row: item.row)
        } label: {
            HStack(spacing: NoopMetrics.space3) {
                Image(systemName: sportSymbol(item.row.sport))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StrandPalette.effortColor)
                    .frame(width: 28, height: 28)
                    .background(StrandPalette.effortColor.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(LocalizedStringKey(item.name))
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                    Text(item.line)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(LiquidPressStyle())
    }

    // MARK: Loading (off the render path)

    private func load() async {
        let zoneSet = self.zoneSet
        let row = featured

        // Sample-independent part first, so the header and compact rows never wait on the database.
        let scale = UnitPrefs.resolveEffortScale(effortScaleRaw)
        let base = Self.makeDisplay(featured: row, others: others, samples: samples?.row == row ? samples : nil,
                                    zoneSet: zoneSet, effortScale: scale)
        display = base

        if let cached = samples, cached.row == row, cached.zoneSet == zoneSet, !cached.points.isEmpty {
            return
        }
        let buckets = await repo.workoutHrBuckets(from: row.startTs, to: row.endTs, source: row.source)
        let points = buckets.map { TrendPoint(date: Date(timeIntervalSince1970: TimeInterval($0.ts)), value: $0.bpm) }
        var derived: [Double]?
        if WorkoutZones.percents(row.zonesJSON) == nil {
            derived = await repo.workoutZoneMinutes(from: row.startTs, to: row.endTs, zoneSet: zoneSet,
                                                    source: row.source)
        }
        guard !Task.isCancelled else { return }
        let loaded = Samples(row: row, zoneSet: zoneSet, points: points, derivedMinutes: derived)
        samples = loaded
        display = Self.makeDisplay(featured: row, others: others, samples: loaded, zoneSet: zoneSet,
                                   effortScale: scale)
    }

    private static func makeDisplay(featured row: WorkoutRow, others: [WorkoutRow],
                                    samples: Samples?, zoneSet: HRZoneSet,
                                    effortScale: EffortScale) -> Display {
        let formatter = AppClock.hourMinuteFormatter()
        let system = distanceSystem()
        let points = samples?.points ?? []

        let avg: Int? = row.avgHr ?? {
            guard !points.isEmpty else { return nil }
            return Int((points.map(\.value).reduce(0, +) / Double(points.count)).rounded())
        }()

        var sentence: String?
        if let samples,
           let minutes = TodayWorkoutSummary.zoneMinutes(row: row, derived: samples.derivedMinutes) {
            sentence = TodayWorkoutSummary.sentence(TodayWorkoutSummary.highlights(minutes),
                                                    locale: AppLanguage.activeLocale)
        }

        let values = points.map(\.value)
        let lo = max(0, (values.min() ?? 60) - 8)
        let hi = (values.max() ?? 180) + 8
        let axis: ClosedRange<Date>? = row.endTs > row.startTs
            ? Date(timeIntervalSince1970: TimeInterval(row.startTs))...Date(timeIntervalSince1970: TimeInterval(row.endTs))
            : nil

        return Display(
            name: WorkoutSource.displaySport(row.sport),
            header: line(for: row, includeToday: true, includeAvg: false, formatter: formatter, system: system),
            avgHr: avg,
            effort: WorkoutWindowMetrics.effort(strain: row.strain, scale: effortScale),
            kcal: row.energyKcal.flatMap { $0.isFinite && $0 > 0 ? Self.kcalFormatter.string(from: NSNumber(value: Int($0.rounded()))) : nil },
            sentence: sentence,
            points: points,
            range: lo...max(hi, lo + 1),
            axis: axis,
            timeFormatter: formatter,
            compact: others.map {
                Display.Compact(row: $0, name: WorkoutSource.displaySport($0.sport),
                                line: line(for: $0, includeToday: false, includeAvg: true,
                                           formatter: formatter, system: system))
            })
    }

    /// "Today · 07:12 · 52m · 6.2 km" for the featured row, "12:30 · 34m · 128 bpm" for a compact one.
    private static func line(for row: WorkoutRow, includeToday: Bool, includeAvg: Bool,
                             formatter: DateFormatter, system: UnitSystem) -> String {
        var parts: [String] = []
        if includeToday { parts.append(String(localized: "Today")) }
        parts.append(formatter.string(from: Date(timeIntervalSince1970: TimeInterval(row.startTs))))
        let secs = row.durationS ?? Double(max(row.endTs - row.startTs, 0))
        let mins = Int((secs / 60).rounded())
        if mins > 0 {
            parts.append(mins >= 60 ? String(localized: "\(mins / 60)h \(mins % 60)m")
                                    : String(localized: "\(mins)m"))
        }
        if let m = row.distanceM, m > 0 {
            parts.append(UnitFormatter.distanceFromMeters(m, system: system))
        }
        if includeAvg, let avg = row.avgHr { parts.append(String(localized: "\(avg) bpm")) }
        return parts.joined(separator: " · ")
    }

    private static let kcalFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        f.locale = AppLanguage.activeLocale
        return f
    }()

    /// The same resolution `WorkoutDetailView` applies to its two `@AppStorage` unit keys.
    private static func distanceSystem() -> UnitSystem {
        let defaults = UserDefaults.standard
        let base = UnitSystem(rawValue: defaults.string(forKey: UnitPrefs.systemKey) ?? "") ?? .metric
        return UnitPrefs.resolveDistance(system: base,
                                         override: defaults.string(forKey: UnitPrefs.distanceSystemKey) ?? "")
    }
}
