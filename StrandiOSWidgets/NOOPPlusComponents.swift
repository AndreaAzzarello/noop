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
        VStack(spacing: 2) {
            ZStack {
                ForEach(Array(day.runs.enumerated()), id: \.offset) { _, run in
                    ForkRunPath(points: run.points, t0: t0, t1: t1, lo: lo, hi: hi)
                        .stroke(style.zone(run.zone),
                                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
            .widgetAccentable()
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity)
            .frame(height: height)
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
        return snap
    }
}
