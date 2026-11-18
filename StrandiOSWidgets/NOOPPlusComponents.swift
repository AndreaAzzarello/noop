import StrandDesign
import SwiftUI
import WidgetKit

// MARK: - Localisation (fork table)
//
// Every NOOP+ string resolves against `ForkWidgets.xcstrings` (source `en`, translation `it`). A separate
// table, NOT `Localizable`, so the upstream widgets stay exactly as they were. Resolved against the
// extension's own bundle (`Bundle.main` inside an appex), which is why this works where the app's catalogue
// never reaches.
enum FL {
    static func s(_ key: String.LocalizationValue) -> String {
        String(localized: key, table: "ForkWidgets")
    }
}

// MARK: - Rendering-mode aware styles

/// Resolves colours per rendering mode, in one place.
///
/// `.fullColor` (Home Screen, gallery) uses the design tokens. Every other mode (`.accented` = tinted and
/// iOS 26 clear, `.vibrant` = Lock Screen and StandBy night) hands colour over to the system, which maps
/// only two hierarchy levels, so domain colours are dropped for `.primary`/`.secondary`; the information
/// they carried survives as shape (arc length) and, for HR zones, as opacity steps.
struct ForkStyle {
    let full: Bool

    init(_ mode: WidgetRenderingMode) { full = mode == .fullColor }

    var primary: AnyShapeStyle {
        full ? AnyShapeStyle(StrandPalette.textPrimary) : AnyShapeStyle(HierarchicalShapeStyle.primary)
    }
    var secondary: AnyShapeStyle {
        full ? AnyShapeStyle(StrandPalette.textSecondary) : AnyShapeStyle(HierarchicalShapeStyle.secondary)
    }
    var tertiary: AnyShapeStyle {
        full ? AnyShapeStyle(StrandPalette.textTertiary) : AnyShapeStyle(HierarchicalShapeStyle.secondary)
    }
    var track: AnyShapeStyle {
        full ? AnyShapeStyle(StrandPalette.textPrimary.opacity(0.10)) : AnyShapeStyle(Color.primary.opacity(0.22))
    }

    /// A domain colour in full colour, the primary hierarchy otherwise.
    func domain(_ color: Color) -> AnyShapeStyle {
        full ? AnyShapeStyle(color) : AnyShapeStyle(HierarchicalShapeStyle.primary)
    }

    /// HR zone ink. Same token as the app chart; zone 0 (below Zone 1) is the tertiary tone there too.
    /// Without colour the zone becomes an opacity step so intensity still reads.
    func zone(_ zone: Int) -> AnyShapeStyle {
        if full {
            return zone >= 1 ? AnyShapeStyle(StrandPalette.hrZoneColor(zone)) : AnyShapeStyle(StrandPalette.textTertiary)
        }
        let opacity = zone <= 0 ? 0.35 : 0.5 + 0.1 * Double(min(zone, 5))
        return AnyShapeStyle(Color.primary.opacity(opacity))
    }

    func battery(_ tier: ForkBatteryTier) -> AnyShapeStyle {
        guard full else { return primary }
        switch tier {
        case .normal: return primary
        case .warning: return AnyShapeStyle(StrandPalette.statusWarning)
        case .critical: return AnyShapeStyle(StrandPalette.statusCritical)
        }
    }
}

// MARK: - Formatting

enum ForkFormat {
    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "7h 12m" (localised through the fork table).
    static func duration(minutes: Int) -> String {
        FL.s("\(minutes / 60)h \(minutes % 60)m")
    }

    /// Time of a future wake: just the clock for today/tomorrow, weekday + clock beyond that.
    static func wakeClock(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        return days >= 2
            ? date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
            : clock(date)
    }

    /// "Wake 06:20–06:50" or, with `short`, only the latest time "Wake 06:50".
    static func wake(_ wake: ForkNextWake, now: Date, short: Bool) -> String {
        let latest = wakeClock(wake.latest, now: now)
        if !short, let start = wake.windowStart {
            return FL.s("Wake \(clock(start))–\(latest)")
        }
        return FL.s("Wake \(latest)")
    }

    /// "Updated at 09:41", or with the day when it is not today.
    static func updated(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return FL.s("Updated at \(clock(date))") }
        return FL.s("Updated \(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
    }

    /// The compact form: the time alone (with the day when it is not today).
    static func updatedShort(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        calendar.isDate(date, inSameDayAs: now)
            ? clock(date)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

// MARK: - Score ring

/// Static score ring (no draw-in animation: WidgetKit timelines do not reliably fire `onAppear`).
/// Same tokens as upstream's private `WidgetScoreRing`, plus accent handling for tinted/clear.
struct ForkScoreRing: View {
    let text: String?
    let fraction: Double?
    let label: String
    let color: Color
    let diameter: CGFloat
    let lineWidth: CGFloat
    var labelFont: Font = .caption2
    let outOf: Int
    let style: ForkStyle

    private var clamped: CGFloat { CGFloat(min(max(fraction ?? 0, 0), 1)) }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                // Inset by half the stroke so the ring's OUTER edge is the frame: a centred stroke bleeds
                // lineWidth/2 past it and neighbouring rings touch on narrow families.
                Circle().inset(by: lineWidth / 2)
                    .stroke(style.track, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                if fraction != nil {
                    Circle().inset(by: lineWidth / 2)
                        .trim(from: 0, to: max(0.0001, clamped))
                        .stroke(style.domain(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .widgetAccentable()
                }
                Text(text ?? "–")
                    .font(StrandFont.rounded(diameter * 0.34, weight: .bold))
                    .foregroundStyle(text == nil ? style.tertiary : style.primary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, lineWidth + 2)
            }
            .frame(width: diameter, height: diameter)
            Text(label)
                .font(labelFont)
                .foregroundStyle(style.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(text.map { FL.s("\($0) out of \(outOf)") } ?? FL.s("no data")))
    }
}

// MARK: - Zone-coloured HR chart

private struct ForkRunPath: Shape {
    let points: [HrPoint]
    let t0: Int64
    let t1: Int64
    let lo: Int
    let hi: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !points.isEmpty, rect.width > 0, rect.height > 0 else { return path }
        let span = CGFloat(max(t1 - t0, 1))
        let range = CGFloat(hi - lo)
        func point(_ p: HrPoint) -> CGPoint {
            CGPoint(x: rect.minX + CGFloat(p.ts - t0) / span * rect.width,
                    // A flat day runs along the vertical middle rather than pinned to an edge.
                    y: range <= 0 ? rect.midY : rect.maxY - CGFloat(p.bpm - lo) / range * rect.height)
        }
        if points.count == 1 {
            let c = point(points[0])
            path.addEllipse(in: CGRect(x: c.x - 1.5, y: c.y - 1.5, width: 3, height: 3))
            return path
        }
        path.move(to: point(points[0]))
        for p in points.dropFirst() { path.addLine(to: point(p)) }
        return path
    }
}

/// Today's heart rate, every stretch inked by the zone it falls in. The app already resolved the zones
/// (`HRZoneChartModel.runs`), so this only strokes paths. Simplified relative to the app chart: no
/// threshold rules. `axes` adds the min/max readout and the time axis, the first thing to go on a short
/// widget.
struct ForkZoneHRChart: View {
    let day: ForkHRDay
    let height: CGFloat
    let axes: Bool
    let style: ForkStyle
    /// Extra-large only: `height` becomes the minimum and the plot takes whatever room is left (up to
    /// `maxFlexibleHeight`). Off by default, so the other families keep their fixed height.
    var flexible = false
    private let maxFlexibleHeight: CGFloat = 240

    private var all: [HrPoint] {
        var seen = Set<Int64>()
        return day.runs.flatMap(\.points).filter { seen.insert($0.ts).inserted }.sorted { $0.ts < $1.ts }
    }

    var body: some View {
        let pts = all
        let t0 = pts.first?.ts ?? 0
        let t1 = pts.last?.ts ?? 1
        let lo = pts.map(\.bpm).min() ?? 0
        let hi = pts.map(\.bpm).max() ?? 0
        let plot = ZStack {
            ForEach(Array(day.runs.enumerated()), id: \.offset) { _, run in
                ForkRunPath(points: run.points, t0: t0, t1: t1, lo: lo, hi: hi)
                    .stroke(style.zone(run.zone),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
        .widgetAccentable()
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity)
        VStack(spacing: 2) {
            if flexible {
                plot.frame(minHeight: height, maxHeight: maxFlexibleHeight)
            } else {
                plot.frame(height: height)
            }
            if axes {
                let ticks = HrTrace.timeTicks(pts)
                if ticks.count >= 2 {
                    HStack {
                        ForEach(Array(ticks.enumerated()), id: \.offset) { i, ts in
                            Text(ForkFormat.clock(Date(timeIntervalSince1970: TimeInterval(ts))))
                                .font(.system(size: 9))
                                .foregroundStyle(style.tertiary)
                                .lineLimit(1)
                            if i < ticks.count - 1 { Spacer(minLength: 0) }
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(FL.s("Heart rate today, minimum \(day.minBpm), maximum \(day.maxBpm)")))
    }
}

/// Shown instead of a flat line at zero when there is no heart rate today.
struct ForkEmptyChart: View {
    let height: CGFloat
    let style: ForkStyle

    var body: some View {
        Text(FL.s("No heart rate today"))
            .font(.caption2)
            .foregroundStyle(style.tertiary)
            .frame(maxWidth: .infinity)
            .frame(height: height)
    }
}

// MARK: - Freshness

/// "Updated at 09:41", discreet; past `ForkWidgetSnapshot.staleAfter` it gains a warning glyph.
struct ForkFreshness: View {
    let updated: Date?
    let now: Date
    let short: Bool
    let style: ForkStyle

    var body: some View {
        if let updated {
            let stale = ForkWidgetSnapshot.isStale(updated, now: now)
            HStack(spacing: 3) {
                Image(systemName: stale ? "exclamationmark.triangle.fill" : "arrow.clockwise")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(stale && style.full ? AnyShapeStyle(StrandPalette.statusWarning) : style.tertiary)
                Text(short ? ForkFormat.updatedShort(updated, now: now) : ForkFormat.updated(updated, now: now))
                    .font(.system(size: 10))
                    .foregroundStyle(stale && style.full ? AnyShapeStyle(StrandPalette.statusWarning) : style.tertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(stale
                ? FL.s("\(ForkFormat.updated(updated, now: now)), data may be out of date")
                : ForkFormat.updated(updated, now: now)))
        }
    }
}

// MARK: - Extra-large blocks

/// The stress curve of today, one subpath per contiguous run of scored hours. The geometry comes from the
/// same `StressTrace.segments` the upstream stress widget uses, so the two curves cannot differ.
private struct ForkStressShape: Shape {
    let series: [StressPoint]
    let filled: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for run in StressTrace.segments(series, width: rect.width, height: rect.height) {
            guard let first = run.first else { continue }
            if run.count == 1 {
                guard !filled else { continue }
                let r: CGFloat = 2.5
                path.addEllipse(in: CGRect(x: max(first.x, r) - r, y: first.y - r, width: r * 2, height: r * 2))
                continue
            }
            path.move(to: CGPoint(x: first.x, y: first.y))
            for p in run.dropFirst() { path.addLine(to: CGPoint(x: p.x, y: p.y)) }
            if filled {
                path.addLine(to: CGPoint(x: run[run.count - 1].x, y: rect.maxY))
                path.addLine(to: CGPoint(x: first.x, y: rect.maxY))
                path.closeSubpath()
            }
        }
        return path
    }
}

/// Today's stress, with the readout of the latest and the highest scored hour. Drawn only when there is
/// at least one scored hour; the caller hides the whole block otherwise.
struct ForkStressBlock: View {
    let series: [StressPoint]
    /// Minimum height of the plot; it grows into spare room up to `maxHeight`.
    let height: CGFloat
    let style: ForkStyle
    private let maxHeight: CGFloat = 130

    private var latest: Double? { series.last(where: { $0.level != nil })?.level }
    private var peak: Double? { StressTrace.stats(series)?.peak.level }

    private var ramp: LinearGradient {
        LinearGradient(colors: [StrandPalette.statusWarning, StrandPalette.statusPositive, StrandPalette.accent],
                       startPoint: .top, endPoint: .bottom)
    }

    private var spoken: String {
        guard let latest, let peak else { return FL.s("Stress today") }
        return FL.s("Stress today, now \(StressTrace.formatLevel(latest)), peak \(StressTrace.formatLevel(peak))")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 10))
                    .foregroundStyle(style.full ? AnyShapeStyle(StrandPalette.stressColor) : style.secondary)
                Text(FL.s("Stress today"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(style.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let latest, let peak {
                    Text(FL.s("now \(StressTrace.formatLevel(latest)) · peak \(StressTrace.formatLevel(peak))"))
                        .font(.system(size: 10))
                        .foregroundStyle(style.tertiary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            ZStack {
                ForkStressShape(series: series, filled: true)
                    .fill(style.full
                          ? AnyShapeStyle(LinearGradient(colors: [StrandPalette.stressColor.opacity(0.28), .clear],
                                                         startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(LinearGradient(colors: [Color.primary.opacity(0.22), .clear],
                                                         startPoint: .top, endPoint: .bottom)))
                ForkStressShape(series: series, filled: false)
                    .stroke(style.full ? AnyShapeStyle(ramp) : style.primary,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            .widgetAccentable()
            .frame(maxWidth: .infinity)
            .frame(minHeight: height, maxHeight: maxHeight)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(spoken))
    }
}

/// Last night's stages as one proportional bar with a legend. In tinted/clear modes the stages become
/// opacity steps, like the HR zones.
struct ForkSleepStagesBar: View {
    let stages: ForkSleepStages
    let style: ForkStyle

    private var total: Double { Double(max(stages.deepMin + stages.remMin + stages.lightMin, 1)) }

    private func ink(_ stage: SleepStage, step: Double) -> AnyShapeStyle {
        style.full ? AnyShapeStyle(StrandPalette.sleepStageColor(stage)) : AnyShapeStyle(Color.primary.opacity(step))
    }

    private var parts: [(label: String, minutes: Int, ink: AnyShapeStyle)] {
        [(FL.s("Deep"), stages.deepMin, ink(.deep, step: 0.9)),
         (FL.s("REM"), stages.remMin, ink(.rem, step: 0.65)),
         (FL.s("Light"), stages.lightMin, ink(.light, step: 0.4))]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let gap: CGFloat = 2
                let usable = geo.size.width - gap * 2
                HStack(spacing: gap) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(part.ink)
                            .frame(width: max(usable * Double(part.minutes) / total, 0))
                    }
                }
            }
            .widgetAccentable()
            .frame(height: 10)
            ViewThatFits(in: .horizontal) {
                legend(withNames: true)
                legend(withNames: false)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(FL.s("Sleep stages, deep \(ForkFormat.duration(minutes: stages.deepMin)), REM \(ForkFormat.duration(minutes: stages.remMin)), light \(ForkFormat.duration(minutes: stages.lightMin))")))
    }

    private func legend(withNames: Bool) -> some View {
        HStack(spacing: 10) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                HStack(spacing: 3) {
                    Circle().fill(part.ink).frame(width: 6, height: 6)
                    Text(withNames ? "\(part.label) \(ForkFormat.duration(minutes: part.minutes))"
                                   : ForkFormat.duration(minutes: part.minutes))
                        .font(.system(size: 10))
                        .foregroundStyle(style.secondary)
                        .lineLimit(1)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The newest workout of today: glyph, name, start and duration, then the figures the row actually has.
/// Wider lines are tried first and the figures are dropped from the end, so nothing is ever truncated.
struct ForkWorkoutBlock: View {
    let workout: ForkWorkout
    let style: ForkStyle

    private var start: String { ForkFormat.clock(Date(timeIntervalSince1970: TimeInterval(workout.startTs))) }

    private func figures(_ level: Int) -> String {
        var parts: [String] = []
        if let e = workout.effortText { parts.append(FL.s("Effort \(e)")) }
        if let avg = workout.avgHr {
            switch (level, workout.maxHr) {
            case (0, let max?): parts.append(FL.s("HR avg \(avg) · max \(max)"))
            case (1, let max?): parts.append(FL.s("HR \(avg)/\(max)"))
            default: parts.append(FL.s("\(avg) bpm"))
            }
        }
        if level <= 1, let k = workout.kcal { parts.append(FL.s("\(k) kcal")) }
        return parts.joined(separator: " · ")
    }

    private func figureLine(_ level: Int) -> some View {
        Text(figures(level))
            .font(.system(size: 10))
            .foregroundStyle(style.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: sportSymbol(workout.sport))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(style.full ? AnyShapeStyle(StrandPalette.effortColor) : style.primary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(workout.sportName) · \(start) · \(FL.s("\(workout.durationMin) min"))")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(style.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                ViewThatFits(in: .horizontal) {
                    figureLine(0)
                    figureLine(1)
                    figureLine(2)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(workout.sportName), \(start), \(FL.s("\(workout.durationMin) min")), \(figures(0))"))
    }
}

/// Seven days of Charge, Effort and Rest as three small bar groups. A day without a score is a short
/// faint stub, never a bar at zero.
struct ForkTrendBars: View {
    let trend: ForkTrend
    let style: ForkStyle
    let height: CGFloat

    private func column(_ label: String, color: Color, values: [Int?]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                    ZStack(alignment: .bottom) {
                        Color.clear
                        if let v {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(style.domain(color))
                                .frame(height: max(height * Double(min(max(v, 0), 100)) / 100, 3))
                        } else {
                            RoundedRectangle(cornerRadius: 2).fill(style.track).frame(height: 3)
                        }
                    }
                }
            }
            .widgetAccentable()
            .frame(height: height)
            Text(label).font(.system(size: 10)).foregroundStyle(style.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(FL.s("7 days"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(style.secondary)
                .lineLimit(1)
            HStack(alignment: .top, spacing: 14) {
                column(FL.s("Charge"), color: StrandPalette.chargeColor, values: trend.days.map(\.charge))
                column(FL.s("Effort"), color: StrandPalette.effortColor, values: trend.days.map(\.effort))
                column(FL.s("Rest"), color: StrandPalette.restColor, values: trend.days.map(\.rest))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(FL.s("Last 7 days of Charge, Effort and Rest")))
    }
}

// MARK: - Sample data (previews and gallery only; fictional)

extension ForkWidgetSnapshot {
    /// A fictional day, never read from a user's data.
    static func sample(now: Date = Date(), calendar: Calendar = .current) -> ForkWidgetSnapshot {
        let start = Int64(calendar.startOfDay(for: now).timeIntervalSince1970)
        let nowTs = Int64(now.timeIntervalSince1970)
        let lowers = [95, 114, 133, 152, 171]
        func zone(_ bpm: Int) -> Int { lowers.lastIndex(where: { bpm >= $0 }).map { $0 + 1 } ?? 0 }
        var runs: [ForkZoneRun] = []
        var current: [HrPoint] = []
        var currentZone = -1
        var ts = start
        while ts <= nowTs {
            let h = Double(ts - start) / 3600
            let bpm = Int(64 + 16 * sin(h * 0.9) + (h > 7 && h < 8 ? 95 * sin((h - 7) * .pi) : 0) + 6 * sin(h * 7))
            let z = zone(bpm)
            let p = HrPoint(ts: ts, bpm: bpm)
            if z != currentZone {
                if !current.isEmpty { current.append(p); runs.append(ForkZoneRun(zone: currentZone, points: current)) }
                current = [p]
                currentZone = z
            } else {
                current.append(p)
            }
            ts += 600
        }
        if !current.isEmpty { runs.append(ForkZoneRun(zone: currentZone, points: current)) }
        let all = runs.flatMap(\.points).map(\.bpm)
        var snap = ForkWidgetSnapshot(publishedAt: now)
        snap.sleepMin = 432
        snap.sleepDay = WidgetSnapshot.localDayNumber(now, calendar: calendar)
        snap.smartWake = SmartWakeSchedule(wakeMinutes: 6 * 60 + 50, windowDuration: 30 * 60)
        snap.hrDay = ForkHRDay(day: WidgetSnapshot.localDayNumber(now, calendar: calendar), throughTs: nowTs,
                               minBpm: all.min() ?? 0, maxBpm: all.max() ?? 0, runs: runs)
        let today = WidgetSnapshot.localDayNumber(now, calendar: calendar)
        snap.vitals = ForkVitals(day: today, respText: "14.2", skinText: "34.2 °C")
        snap.sleepStages = ForkSleepStages(day: today, deepMin: 80, remMin: 105, lightMin: 247, efficiencyPct: 91)
        snap.workout = ForkWorkout(day: today, sport: "running", sportName: "Running", startTs: start + 7 * 3600 + 600,
                                   durationMin: 42, effortText: "11.8", effortWhoop: true, avgHr: 148, maxHr: 176, kcal: 520)
        snap.trend = ForkTrend(day: today, days: [
            ForkTrendDay(charge: 62, effort: 48, rest: 71), ForkTrendDay(charge: 74, effort: 63, rest: 80),
            ForkTrendDay(charge: 55, effort: 82, rest: 66), ForkTrendDay(charge: nil, effort: nil, rest: nil),
            ForkTrendDay(charge: 81, effort: 40, rest: 88), ForkTrendDay(charge: 68, effort: 57, rest: 74),
            ForkTrendDay(charge: 77, effort: 59, rest: 85)])
        return snap
    }
}
