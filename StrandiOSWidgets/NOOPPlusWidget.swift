import StrandDesign
import SwiftUI
import WidgetKit

// MARK: - Timeline

struct NOOPPlusEntry: TimelineEntry {
    let date: Date
    let widget: WidgetSnapshot
    let fork: ForkWidgetSnapshot
}

struct NOOPPlusProvider: TimelineProvider {
    func placeholder(in context: Context) -> NOOPPlusEntry {
        NOOPPlusEntry(date: Date(), widget: .placeholder, fork: .sample())
    }

    func getSnapshot(in context: Context, completion: @escaping (NOOPPlusEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
        } else {
            completion(NOOPPlusEntry(date: Date(), widget: WidgetSnapshot.load() ?? .unavailable,
                                     fork: ForkWidgetSnapshot.load() ?? .empty))
        }
    }

    /// Two small App Group reads, no database, no maths: the zone runs arrive pre-built from the app.
    /// Refreshes every 15 minutes like the upstream widget (the app also reloads this kind when its own
    /// data changes). Extra entries at the instants the picture changes by itself, all inside that same
    /// window and so free of extra reloads: the moment the data turns "old", and the moment a Smart Wake
    /// occurrence passes and the next one takes over.
    func getTimeline(in context: Context, completion: @escaping (Timeline<NOOPPlusEntry>) -> Void) {
        let now = Date()
        let widget = WidgetSnapshot.load() ?? .unavailable
        let fork = ForkWidgetSnapshot.load() ?? .empty
        let refresh = now.addingTimeInterval(15 * 60)

        var dates = [now]
        if let updated = fork.lastUpdate(widget: widget) {
            let turnsStale = updated.addingTimeInterval(ForkWidgetSnapshot.staleAfter + 1)
            if turnsStale > now && turnsStale < refresh { dates.append(turnsStale) }
        }
        if let wake = fork.nextWake(now: now) {
            let passed = wake.latest.addingTimeInterval(1)
            if passed > now && passed < refresh { dates.append(passed) }
        }
        let entries = dates.sorted().map { NOOPPlusEntry(date: $0, widget: widget, fork: fork) }
        completion(Timeline(entries: entries, policy: .after(refresh)))
    }
}

// MARK: - View

/// NOOP+: a fork-only widget with content chosen per family rather than one layout scaled down.
struct NOOPPlusView: View {
    @Environment(\.widgetFamily) private var environmentFamily
    @Environment(\.widgetRenderingMode) private var environmentRendering
    @Environment(\.showsWidgetContainerBackground) private var showsBackground
    let entry: NOOPPlusEntry
    /// Previews and snapshot checks only: the WidgetKit environment keys are read-only, so a fixed-size
    /// preview injects them here. Always nil in the real widget.
    var familyOverride: WidgetFamily? = nil
    var renderingOverride: WidgetRenderingMode? = nil

    private var family: WidgetFamily { familyOverride ?? environmentFamily }
    private var renderingMode: WidgetRenderingMode { renderingOverride ?? environmentRendering }

    private var style: ForkStyle { ForkStyle(renderingMode) }
    private var now: Date { entry.date }
    private var widget: WidgetSnapshot { entry.widget }
    private var fork: ForkWidgetSnapshot { entry.fork }
    private var wake: ForkNextWake? { fork.nextWake(now: now) }
    private var updated: Date? { fork.lastUpdate(widget: entry.widget) }
    private var hrToday: ForkHRDay? { fork.hrToday(now: now) }
    private var effortText: String? { widget.effortDisplay ?? widget.effort.map(String.init) }

    /// Live HR with the same age rule as the upstream trace widget (dimmed after 2 min, dropped after 15).
    private var liveHR: (bpm: Int?, stale: Bool) {
        HrDisplay.resolve(bpm: widget.bpm, newestPointTs: widget.hrSeries?.last?.ts, now: now)
    }

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryInline: inline
        case .accessoryRectangular: rectangular
        case .systemLarge: large
        case .systemMedium: medium
        default: small
        }
    }

    // MARK: Colours

    private var chargeColor: Color { widget.recovery != nil ? StrandPalette.chargeColor : StrandPalette.textTertiary }
    private var effortColor: Color { widget.effort != nil ? StrandPalette.effortColor : StrandPalette.textTertiary }
    private var restColor: Color { widget.rest != nil ? StrandPalette.restColor : StrandPalette.textTertiary }

    // MARK: Rings

    private func rings(diameter: CGFloat, lineWidth: CGFloat, labelFont: Font) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForkScoreRing(text: widget.recovery.map(String.init), fraction: widget.recovery.map { Double($0) / 100 },
                          label: FL.s("Charge"), color: chargeColor, diameter: diameter, lineWidth: lineWidth,
                          labelFont: labelFont, outOf: 100, style: style)
            ForkScoreRing(text: effortText, fraction: widget.effort.map { Double($0) / 100 },
                          label: FL.s("Effort"), color: effortColor, diameter: diameter, lineWidth: lineWidth,
                          labelFont: labelFont, outOf: widget.effortWhoop == true ? 21 : 100, style: style)
            ForkScoreRing(text: widget.rest.map(String.init), fraction: widget.rest.map { Double($0) / 100 },
                          label: FL.s("Rest"), color: restColor, diameter: diameter, lineWidth: lineWidth,
                          labelFont: labelFont, outOf: 100, style: style)
        }
    }

    private var header: some View {
        HStack {
            Text("NOOP+")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(style.secondary)
            Spacer()
            Circle()
                .fill(widget.bonded && style.full ? AnyShapeStyle(StrandPalette.statusPositive)
                      : widget.bonded ? AnyShapeStyle(HierarchicalShapeStyle.primary)
                      : style.full ? AnyShapeStyle(StrandPalette.statusCritical)
                      : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                .frame(width: 8, height: 8)
                .accessibilityLabel(Text(widget.bonded ? FL.s("Strap connected") : FL.s("Strap disconnected")))
        }
    }

    // MARK: systemSmall

    private var small: some View {
        VStack(spacing: 6) {
            // StandBy removes the container background: drop the chrome and let the rings carry the glance.
            if showsBackground { header }
            Spacer(minLength: 0)
            rings(diameter: showsBackground ? 38 : 40, lineWidth: 4, labelFont: .system(size: 9, weight: .medium))
            Spacer(minLength: 0)
            ViewThatFits(in: .horizontal) {
                ForkFreshness(updated: updated, now: now, short: false, style: style)
                ForkFreshness(updated: updated, now: now, short: true, style: style)
            }
        }
        .padding(10)
    }

    // MARK: systemMedium (variant A: rings left, today's HR right)

    private var medium: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 6) {
                rings(diameter: 40, lineWidth: 4, labelFont: .system(size: 9, weight: .medium))
                Spacer(minLength: 0)
                ViewThatFits(in: .horizontal) {
                    mediumFooter(wake: true, shortUpdated: false)
                    mediumFooter(wake: true, shortUpdated: true)
                    mediumFooter(wake: false, shortUpdated: true)
                }
            }
            .frame(width: 132)
            VStack(alignment: .leading, spacing: 4) {
                hrCaption(withRange: true)
                if let day = hrToday {
                    ForkZoneHRChart(day: day, height: 78, axes: false, style: style)
                    Spacer(minLength: 0)
                } else {
                    ForkEmptyChart(height: 78, style: style)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(12)
    }

    private func mediumFooter(wake showWake: Bool, shortUpdated: Bool) -> some View {
        HStack(spacing: 6) {
            if showWake, let wake {
                HStack(spacing: 2) {
                    Image(systemName: "alarm").font(.system(size: 9, weight: .semibold))
                    Text(ForkFormat.wakeClock(wake.latest, now: now)).font(.system(size: 10))
                }
                .foregroundStyle(style.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(ForkFormat.wake(wake, now: now, short: true)))
            }
            ForkFreshness(updated: updated, now: now, short: shortUpdated, style: style)
        }
    }

    private func hrCaption(withRange: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "heart.fill")
                .font(.system(size: 10))
                .foregroundStyle(style.full ? AnyShapeStyle(StrandPalette.zone5) : style.secondary)
            Text(FL.s("HR today"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(style.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if withRange, let day = hrToday {
                Text(FL.s("max \(day.maxBpm)"))
                    .font(.system(size: 10))
                    .foregroundStyle(style.tertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    // MARK: systemLarge

    /// Content is dropped in an explicit order when the widget is short (iPhone SE), first to last:
    ///  1. min/max readout and the time axis of the chart,
    ///  2. "Updated at 09:41" shrinks to the bare time,
    ///  3. the chart gets shorter.
    /// `ViewThatFits` takes the first variant whose ideal size fits, so nothing is ever truncated or
    /// overlapped: a variant either fits whole or is skipped.
    private var large: some View {
        ViewThatFits(in: .vertical) {
            largeBody(axes: true, shortUpdated: false, chartHeight: 96)
            largeBody(axes: false, shortUpdated: false, chartHeight: 96)
            largeBody(axes: false, shortUpdated: true, chartHeight: 96)
            largeBody(axes: false, shortUpdated: true, chartHeight: 84)
            largeBody(axes: false, shortUpdated: true, chartHeight: 64)
            largeBody(axes: false, shortUpdated: true, chartHeight: 44)
        }
        .padding(14)
    }

    private func largeBody(axes: Bool, shortUpdated: Bool, chartHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            rings(diameter: 56, lineWidth: 6, labelFont: .caption2)
            Divider()
            statsRow
            VStack(alignment: .leading, spacing: 3) {
                largeChartCaption(axes: axes)
                if let day = hrToday {
                    ForkZoneHRChart(day: day, height: chartHeight, axes: axes, style: style)
                } else {
                    ForkEmptyChart(height: chartHeight, style: style)
                }
            }
            Spacer(minLength: 0)
            bottomRows(shortUpdated: shortUpdated)
        }
    }

    private func largeChartCaption(axes: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "heart.fill")
                .font(.system(size: 10))
                .foregroundStyle(style.full ? AnyShapeStyle(StrandPalette.zone5) : style.secondary)
            Text(axes ? (hrToday.map { FL.s("HR today · until \(ForkFormat.clock(Date(timeIntervalSince1970: TimeInterval($0.throughTs))))") }
                         ?? FL.s("HR today"))
                      : FL.s("HR today"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(style.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if axes, let day = hrToday {
                Text(FL.s("min \(day.minBpm) · max \(day.maxBpm)"))
                    .font(.system(size: 10))
                    .foregroundStyle(style.tertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    private var statsRow: some View {
        let battery = widget.batteryPct
        return HStack(alignment: .top, spacing: 0) {
            statCell(FL.s("HRV"), value: widget.hrv.map(String.init), unit: "ms",
                     spoken: widget.hrv.map { FL.s("\($0) milliseconds") })
            statCell(FL.s("Rest HR"), value: widget.restingHr.map(String.init), unit: "bpm",
                     spoken: widget.restingHr.map { FL.s("\($0) beats per minute") })
            statCell(FL.s("HR"), value: liveHR.bpm.map(String.init), unit: "bpm",
                     dim: liveHR.stale, spoken: liveHR.bpm.map { FL.s("\($0) beats per minute") })
            statCell(FL.s("Battery"), value: battery.map { "\($0)%" }, unit: nil,
                     tint: battery.map { style.battery(ForkBatteryTier.tier(forPercent: $0)) },
                     spoken: battery.map { FL.s("\($0) percent") })
        }
    }

    private func statCell(_ label: String, value: String?, unit: String?, dim: Bool = false,
                          tint: AnyShapeStyle? = nil, spoken: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value ?? "–")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(value == nil ? style.tertiary : dim ? style.secondary : (tint ?? style.primary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let unit, value != nil {
                    Text(unit).font(.system(size: 10)).foregroundStyle(style.tertiary).lineLimit(1)
                }
            }
            Text(label).font(.system(size: 10)).foregroundStyle(style.tertiary).lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(spoken ?? FL.s("no data")))
    }

    private func bottomRows(shortUpdated: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ViewThatFits(in: .horizontal) {
                sleepWakeRow(wakeShort: false)
                sleepWakeRow(wakeShort: true)
            }
            HStack {
                Spacer(minLength: 0)
                ForkFreshness(updated: updated, now: now, short: shortUpdated, style: style)
            }
        }
    }

    private func sleepWakeRow(wakeShort: Bool) -> some View {
        HStack(spacing: 10) {
            if let sleep = fork.sleepMinutes(now: now) {
                Label(FL.s("Sleep \(ForkFormat.duration(minutes: sleep))"), systemImage: "moon.fill")
                    .foregroundStyle(style.secondary)
                    .accessibilityLabel(Text(FL.s("Sleep last night \(ForkFormat.duration(minutes: sleep))")))
            }
            if let wake {
                Label(ForkFormat.wake(wake, now: now, short: wakeShort), systemImage: "alarm")
                    .foregroundStyle(style.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Lock Screen accessories

    private var circular: some View {
        Gauge(value: Double(widget.recovery ?? 0), in: 0...100) {
            Text(FL.s("Charge"))
        } currentValueLabel: {
            Text(widget.recovery.map(String.init) ?? "–")
        }
        .gaugeStyle(.accessoryCircular)
        .widgetAccentable()
        .accessibilityLabel(Text(FL.s("Charge")))
        .accessibilityValue(Text(widget.recovery.map { FL.s("\($0) out of 100") } ?? FL.s("no data")))
    }

    private var rectangular: some View {
        VStack(spacing: 2) {
            if let wake {
                Label(ForkFormat.wake(wake, now: now, short: false), systemImage: "alarm")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .top, spacing: 0) {
                accessoryScore(FL.s("Charge"), symbol: "figure.mind.and.body", text: widget.recovery.map { "\($0)%" })
                accessoryScore(FL.s("Effort"), symbol: "figure.strengthtraining.traditional", text: effortText)
                accessoryScore(FL.s("Rest"), symbol: "moon.fill", text: widget.rest.map { "\($0)%" })
            }
        }
    }

    /// Glyph over value; `.primary`/`.secondary` only, the two levels the Lock Screen maps.
    private func accessoryScore(_ label: String, symbol: String, text: String?) -> some View {
        VStack(spacing: 1) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(text ?? "–")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(text == nil ? .secondary : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(text ?? FL.s("no data")))
    }

    private var inline: some View {
        ViewThatFits(in: .horizontal) {
            Text(inlineText(short: false))
            Text(inlineText(short: true))
        }
    }

    /// "Charge 77 · Wake 06:50", without the wake part when Smart Wake is off; "NOOP+" when empty.
    private func inlineText(short: Bool) -> String {
        var parts: [String] = []
        if let r = widget.recovery { parts.append(FL.s("Charge \(r)")) }
        if let wake { parts.append(short ? ForkFormat.wakeClock(wake.latest, now: now)
                                         : FL.s("Wake \(ForkFormat.wakeClock(wake.latest, now: now))")) }
        if parts.isEmpty, let bpm = liveHR.bpm { parts.append(FL.s("HR \(bpm)")) }
        return parts.isEmpty ? "NOOP+" : parts.joined(separator: " · ")
    }
}

// MARK: - Widget

struct NOOPPlusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ForkWidgetSnapshot.kind, provider: NOOPPlusProvider()) { entry in
            NOOPPlusView(entry: entry)
                .containerBackground(StrandPalette.surfaceBase, for: .widget)
        }
        .configurationDisplayName(LocalizedStringResource("NOOP+", table: "ForkWidgets"))
        .description(LocalizedStringResource("Charge, Effort and Rest, today's heart rate by zone, sleep and the next Smart Wake.",
                                             table: "ForkWidgets"))
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryCircular, .accessoryInline, .accessoryRectangular
        ])
    }
}
