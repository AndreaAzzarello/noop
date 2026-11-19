import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics

// MARK: - Zone-coloured heart-rate curve (workout detail)
//
// The workout HR curve with every stretch coloured by the heart-rate zone it falls in, dashed rules at
// the zone thresholds (bpm on the trailing axis) and a small legend. It uses the SAME `HRZoneSet` the
// "HR Zones" bar on that screen is built from (`ProfileStore.hrZoneSet`) and the same
// `StrandPalette.hrZoneColor`, so the chart and the bar cannot disagree about a threshold or a colour.
//
// Colouring: the series is split into single-zone runs, with an interpolated point on every threshold a
// segment crosses, so a run never bleeds into the next band. `TrendChart` is untouched (shared by other
// screens); when the zones are not usable this view renders exactly the previous `TrendChart`.

// MARK: Pure model

enum HRZoneChartModel {

    /// One unbroken stretch of the series that stays inside a single zone (0 = below Zone 1).
    struct Run: Identifiable {
        let id: Int
        let zone: Int
        let points: [TrendPoint]
    }

    /// A zone's lower threshold, as drawn on the chart.
    struct Threshold: Identifiable {
        let zone: Int
        /// Exact lower bound (bpm); where the rule is drawn and where a run is split.
        let value: Double
        var id: Int { zone }
        /// Whole-bpm label, rounded up like `HRZones.defaultLowerBounds`, so the number shown is the first
        /// integer reading that lands in the zone.
        var label: Int { Int(ceil(value)) }
    }

    /// The zone set when it can drive the chart (positive finite HRmax, five finite, strictly increasing
    /// lower bounds); nil otherwise, so the caller falls back to the plain chart.
    static func usableZoneSet(_ zoneSet: HRZoneSet) -> HRZoneSet? {
        guard zoneSet.maxHR.isFinite, zoneSet.maxHR > 0, zoneSet.zones.count == 5 else { return nil }
        let lowers = zoneSet.zones.map(\.lower)
        guard lowers.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        for i in 1..<lowers.count where lowers[i] <= lowers[i - 1] { return nil }
        return zoneSet
    }

    /// Splits the series into single-zone runs. Whenever two consecutive points sit in different zones, a
    /// point interpolated linearly in time lands on each threshold crossed (a jump over several zones
    /// crosses several) and is shared by the run it closes and the run it opens. A change of
    /// `TrendPoint.segment` is a gap: the run ends there with no interpolation.
    static func runs(_ input: [TrendPoint], zoneSet: HRZoneSet) -> [Run] {
        let pts = input.sorted { $0.date < $1.date }
        guard let first = pts.first else { return [] }
        // edges[k] is the boundary between zone k and zone k + 1 (k = 0 separates "below Zone 1" from Z1).
        let edges = zoneSet.zones.map(\.lower)

        var runs: [Run] = []
        var current: [TrendPoint] = [first]
        var currentZone = zoneSet.zoneNumber(forBPM: first.value)

        func add(_ p: TrendPoint, to run: inout [TrendPoint]) {
            if let last = run.last, last.date == p.date { return }
            run.append(p)
        }

        for i in 1..<max(pts.count, 1) {
            let a = pts[i - 1], b = pts[i]
            if a.segment != b.segment {
                runs.append(Run(id: runs.count, zone: currentZone, points: current))
                current = [b]
                currentZone = zoneSet.zoneNumber(forBPM: b.value)
                continue
            }
            let zb = zoneSet.zoneNumber(forBPM: b.value)
            if zb != currentZone {
                let za = currentZone
                let ascending = zb > za
                let crossed: [Int] = ascending ? Array(za..<zb) : Array((zb..<za).reversed())
                for k in crossed {
                    let threshold = edges[k]
                    let span = b.value - a.value
                    let t = span == 0 ? 1 : min(max((threshold - a.value) / span, 0), 1)
                    let date = a.date.addingTimeInterval(t * b.date.timeIntervalSince(a.date))
                    let mark = TrendPoint(date: date, value: threshold, segment: a.segment)
                    add(mark, to: &current)
                    runs.append(Run(id: runs.count, zone: currentZone, points: current))
                    current = [mark]
                    currentZone = ascending ? k + 1 : k
                }
            }
            add(b, to: &current)
        }
        runs.append(Run(id: runs.count, zone: currentZone, points: current))
        return runs
    }

    /// Zone lower thresholds strictly inside the plotted domain (a rule on the edge would clip its label).
    static func thresholds(_ zoneSet: HRZoneSet, in domain: ClosedRange<Double>) -> [Threshold] {
        zoneSet.zones
            .filter { $0.lower > domain.lowerBound && $0.lower < domain.upperBound }
            .map { Threshold(zone: $0.number, value: $0.lower) }
    }

    /// The bpm span a legend entry states for one zone.
    enum BPMRange: Equatable {
        /// Zone 0: strictly under the Zone 1 start.
        case below(Int)
        /// Zones 1...4: first and last whole bpm that still count as the zone.
        case between(Int, Int)
        /// Zone 5: from its start upwards (it includes HRmax).
        case atLeast(Int)
    }

    /// bpm span of `zone` read from the SAME `HRZoneSet` that colours the curve. Bounds are rounded up
    /// (`ceil`) exactly as the trailing axis labels are, so a legend range and its dashed rule always agree.
    /// A reading sits in zone n from `ceil(lower_n)` up to the whole bpm before `ceil(lower_n+1)`.
    static func range(forZone zone: Int, in zoneSet: HRZoneSet) -> BPMRange? {
        let lowers = zoneSet.zones.map { Int(ceil($0.lower)) }
        guard lowers.count == 5 else { return nil }
        switch zone {
        case 0: return .below(lowers[0])
        case 1...4: return .between(lowers[zone - 1], max(lowers[zone - 1], lowers[zone] - 1))
        case 5: return .atLeast(lowers[4])
        default: return nil
        }
    }

    /// The plotted Y domain with headroom for the threshold rules. A rule whose bpm sits within the top
    /// margin of `domain` would run along the plot's upper edge, under the card's subtitle, so the upper
    /// bound is raised to leave one margin above it. Raising it can bring a higher threshold inside the
    /// domain, so this repeats until no rule is left in the margin. The lower bound never moves.
    static func paddedDomain(_ domain: ClosedRange<Double>, zoneSet: HRZoneSet) -> ClosedRange<Double> {
        let span = domain.upperBound - domain.lowerBound
        guard span.isFinite, span > 0 else { return domain }
        let margin = max(4, 0.06 * span)
        let lowers = zoneSet.zones.map(\.lower).filter { $0.isFinite && $0 > domain.lowerBound }
        var upper = domain.upperBound
        var changed = true
        while changed {
            changed = false
            for lower in lowers where lower < upper && lower > upper - margin {
                upper = lower + margin
                changed = true
            }
        }
        return domain.lowerBound...upper
    }

    /// Reading nearest to `date` in a date-sorted series (binary search; a tie picks the earlier one).
    /// Same rule as `TrendChart`'s, whose copy is internal to the StrandDesign package.
    static func nearest(to date: Date, in points: [TrendPoint]) -> TrendPoint? {
        guard !points.isEmpty else { return nil }
        var lower = 0, upper = points.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if points[middle].date < date { lower = middle + 1 } else { upper = middle }
        }
        if lower == 0 { return points[0] }
        if lower == points.count { return points[lower - 1] }
        let before = points[lower - 1], after = points[lower]
        return date.timeIntervalSince(before.date) <= after.date.timeIntervalSince(date) ? before : after
    }
}

// MARK: View

struct ZoneColoredHRChart: View {

    private let points: [TrendPoint]
    private let valueRange: ClosedRange<Double>
    /// `valueRange` with headroom above the highest threshold rule (zoned chart only).
    private let plotRange: ClosedRange<Double>
    private let valueFormat: (Double) -> String
    private let dateFormat: (Date) -> String
    private let accessibilityLabel: String?
    private let workoutTimeAxis: ClosedRange<Date>?
    private let height: CGFloat

    /// nil = zones unusable (or too few points): the plain `TrendChart` is shown instead.
    private let zoneSet: HRZoneSet?
    private let runs: [HRZoneChartModel.Run]
    private let thresholds: [HRZoneChartModel.Threshold]
    private let legendZones: [Int]
    private let a11yValue: String

    @State private var hoverX: CGFloat? = nil

    init(
        points: [TrendPoint],
        zoneSet: HRZoneSet,
        valueRange: ClosedRange<Double>,
        height: CGFloat = 220,
        valueFormat: @escaping (Double) -> String,
        dateFormat: @escaping (Date) -> String,
        accessibilityLabel: String? = nil,
        workoutTimeAxis: ClosedRange<Date>? = nil
    ) {
        let sorted = points.sorted { $0.date < $1.date }
        self.points = sorted
        self.valueRange = valueRange
        self.height = height
        self.valueFormat = valueFormat
        self.dateFormat = dateFormat
        self.accessibilityLabel = accessibilityLabel
        self.workoutTimeAxis = workoutTimeAxis

        let usable = sorted.count > 1 ? HRZoneChartModel.usableZoneSet(zoneSet) : nil
        self.zoneSet = usable
        if let usable {
            // Same vertex budget as TrendChart; the hover still reads the full-resolution `points`.
            let drawn = ChartDownsample.minMaxBucketed(sorted, threshold: ChartDownsample.markThreshold,
                                                       targetCount: ChartDownsample.targetVertices)
            let runs = HRZoneChartModel.runs(drawn, zoneSet: usable)
            self.runs = runs
            let padded = HRZoneChartModel.paddedDomain(valueRange, zoneSet: usable)
            self.plotRange = padded
            self.thresholds = HRZoneChartModel.thresholds(usable, in: padded)
            self.legendZones = Array(Set(runs.map(\.zone))).sorted()
        } else {
            self.plotRange = valueRange
            self.runs = []
            self.thresholds = []
            self.legendZones = []
        }
        let values = sorted.map(\.value)
        if let lo = values.min(), let hi = values.max() {
            self.a11yValue = "\(valueFormat(lo)) – \(valueFormat(hi))"
        } else {
            self.a11yValue = ""
        }
    }

    // MARK: Colours and names (existing tokens / existing catalogue keys only)

    private static func color(forZone zone: Int) -> Color {
        zone >= 1 ? StrandPalette.hrZoneColor(zone) : StrandPalette.textTertiary
    }

    private static func name(forZone zone: Int) -> String {
        switch zone {
        case 1: return String(localized: "Recovery")
        case 2: return String(localized: "Fat burn")
        case 3: return String(localized: "Aerobic")
        case 4: return String(localized: "Threshold")
        case 5: return String(localized: "Maximum")
        default: return String(localized: "Below Zone 1")
        }
    }

    private static func elapsedLabel(_ date: Date, start: Date) -> String {
        let minutes = max(0, Int(date.timeIntervalSince(start))) / 60
        if minutes >= 60 { return String(format: "%d:%02d", minutes / 60, minutes % 60) }
        return String(localized: "\(minutes) min")
    }

    // MARK: Body

    var body: some View {
        if let zoneSet {
            zoned(zoneSet)
        } else {
            // Fallback: byte-for-byte the call WorkoutDetailView made before this view existed.
            TrendChart(
                points: points,
                gradient: StrandPalette.effortGradient,
                valueRange: valueRange,
                showsArea: true,
                valueFormat: valueFormat,
                dateFormat: dateFormat,
                accessibilityLabel: accessibilityLabel,
                workoutTimeAxis: workoutTimeAxis
            )
        }
    }

    private func zoned(_ zoneSet: HRZoneSet) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            chart(zoneSet)
            legend(zoneSet)
        }
    }

    private func chart(_ zoneSet: HRZoneSet) -> some View {
        Chart {
            ForEach(runs) { run in
                if run.points.count > 1 {
                    ForEach(run.points.indices, id: \.self) { i in
                        AreaMark(
                            x: .value("Time", run.points[i].date),
                            yStart: .value("Floor", plotRange.lowerBound),
                            yEnd: .value("Heart rate", run.points[i].value),
                            series: .value("Run", "area-\(run.id)")
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Self.color(forZone: run.zone).opacity(0.18))
                    }
                }
            }
            ForEach(thresholds) { t in
                RuleMark(y: .value("Zone threshold", t.value))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(Self.color(forZone: t.zone).opacity(0.55))
            }
            ForEach(runs) { run in
                if run.points.count > 1 {
                    ForEach(run.points.indices, id: \.self) { i in
                        LineMark(
                            x: .value("Time", run.points[i].date),
                            y: .value("Heart rate", run.points[i].value),
                            series: .value("Run", "line-\(run.id)")
                        )
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(Self.color(forZone: run.zone))
                    }
                } else if let only = run.points.first {
                    // A lone reading between two gaps is real data, not a gap.
                    PointMark(x: .value("Time", only.date), y: .value("Heart rate", only.value))
                        .symbolSize(18)
                        .foregroundStyle(Self.color(forZone: run.zone))
                }
            }
        }
        .chartYScale(domain: plotRange)
        .chartPlotStyle { $0.clipped() }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine().foregroundStyle(StrandPalette.hairline.opacity(0.4))
                AxisValueLabel {
                    if let date = value.as(Date.self), let start = workoutTimeAxis?.lowerBound ?? points.first?.date {
                        Text(Self.elapsedLabel(date, start: start))
                    }
                }
                .foregroundStyle(StrandPalette.textTertiary)
                .font(StrandFont.footnote)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: thresholds.map(\.value)) { value in
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(verbatim: "\(Int(ceil(v)))")
                    }
                }
                .foregroundStyle(StrandPalette.textTertiary)
                .font(StrandFont.footnote)
            }
        }
        .modifier(WorkoutXDomain(range: workoutTimeAxis))
        .chartOverlay { proxy in hoverOverlay(proxy, zoneSet: zoneSet) }
        // Flexible, not fixed: a host that hands this view a bounded height (ChartCard gives 220) gets the
        // legend its natural height first and the plot the rest, instead of a plot + legend taller than
        // the slot that overflows onto the card's subtitle and footer. An unbounded host uses `height`.
        .frame(minHeight: min(120, height), idealHeight: height, maxHeight: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityLabel ?? ""))
        .accessibilityValue(Text(verbatim: a11yValue))
    }

    private func hoverOverlay(_ proxy: ChartProxy, zoneSet: HRZoneSet) -> some View {
        GeometryReader { geo in
            let plot = proxy.plotRectCompat(in: geo)
            ZStack(alignment: .topLeading) {
                if let hx = hoverX,
                   let date: Date = proxy.value(atX: hx - plot.minX),
                   let p = HRZoneChartModel.nearest(to: date, in: points),
                   let px = proxy.position(forX: p.date),
                   let py = proxy.position(forY: p.value) {
                    let cx = px + plot.minX
                    let cy = py + plot.minY
                    let color = Self.color(forZone: zoneSet.zoneNumber(forBPM: p.value))
                    CrosshairRule(x: cx, height: geo.size.height)
                    HighlightDot(color: color).position(x: cx, y: cy)
                    PositionedTooltip(
                        anchor: CGPoint(x: cx, y: cy),
                        container: geo.size,
                        tooltip: ChartTooltip(value: valueFormat(p.value), label: dateFormat(p.date), accent: color)
                    )
                }
            }
            .animation(StrandMotion.fade, value: hoverX)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                // Non-animating transaction, as in TrendChart (#104): entering/leaving must not replay the
                // line's draw-on animation.
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) {
                    switch phase {
                    case .active(let location): hoverX = location.x
                    case .ended: hoverX = nil
                    }
                }
            }
        }
    }

    /// Two flexible columns; each entry stacks the zone name over its bpm span, so a long Italian name wraps
    /// instead of truncating on a small phone.
    private func legend(_ zoneSet: HRZoneSet) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12, alignment: .topLeading),
                            GridItem(.flexible(), spacing: 12, alignment: .topLeading)],
                  alignment: .leading, spacing: 8) {
            ForEach(legendZones, id: \.self) { zone in
                let title = zone >= 1 ? "Z\(zone) · \(Self.name(forZone: zone))" : Self.name(forZone: zone)
                let range = HRZoneChartModel.range(forZone: zone, in: zoneSet)
                HStack(alignment: .top, spacing: 6) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Self.color(forZone: zone))
                        .frame(width: 9, height: 9)
                        .padding(.top, 3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: title)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                        if let range {
                            Text(verbatim: Self.rangeLabel(range))
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: Self.spokenLabel(zone: zone, range: range)))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
    }

    private static func rangeLabel(_ range: HRZoneChartModel.BPMRange) -> String {
        switch range {
        case .below(let hi): return String(localized: "< \(hi) bpm", table: "Fork")
        case .between(let lo, let hi): return String(localized: "\(lo)–\(hi) bpm", table: "Fork")
        case .atLeast(let lo): return String(localized: "≥ \(lo) bpm", table: "Fork")
        }
    }

    private static func spokenLabel(zone: Int, range: HRZoneChartModel.BPMRange?) -> String {
        let name = name(forZone: zone)
        switch range {
        case .below(let hi)?:
            return String(localized: "\(name), under \(hi) beats per minute", table: "Fork")
        case .between(let lo, let hi)?:
            return String(localized: "Zone \(zone), \(name), \(lo) to \(hi) beats per minute", table: "Fork")
        case .atLeast(let lo)?:
            return String(localized: "Zone \(zone), \(name), \(lo) beats per minute or more", table: "Fork")
        case nil:
            return zone >= 1 ? String(localized: "Zone \(zone), \(name)", table: "Fork") : name
        }
    }
}

/// Pins the x domain to the workout window when one is given (no-op otherwise).
private struct WorkoutXDomain: ViewModifier {
    let range: ClosedRange<Date>?

    @ViewBuilder func body(content: Content) -> some View {
        if let range { content.chartXScale(domain: range) } else { content }
    }
}
