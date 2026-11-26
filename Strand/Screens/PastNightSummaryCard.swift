import SwiftUI
import StrandDesign
import WhoopStore

/// fork: the Today "Night" card for a PAST day: the sleep of the night that ended on that day.
///
/// Read-only and sleep-only. It reads the day's `DailyMetric` and the sleep sessions, never an alarm: no
/// `SmartWakeAlarmStore`, no `BehaviorStore`, no wake record. The live `NightSummaryCard` is a separate view and
/// stays the only one that knows about tonight. The figures come through `PastNight` and `NightSummary`.
struct PastNightSummaryCard: View {

    let metric: DailyMetric
    /// Start of the selected calendar day.
    let dayStart: Date

    @EnvironmentObject private var repo: Repository
    @State private var summary: NightSummary?

    private struct LoadKey: Equatable {
        let metric: DailyMetric
        let dayStart: Date
        let sleepSessions: Int
    }

    private var loadKey: LoadKey {
        LoadKey(metric: metric, dayStart: dayStart, sleepSessions: repo.sleeps.count)
    }

    var body: some View {
        // The root exists before the first load, so `.task` never hangs off an empty `Group`.
        ZStack {
            Color.clear.frame(height: 0).accessibilityHidden(true)
            if let summary, let minutes = summary.sleepMinutes {
                card(summary, minutes: minutes)
            }
        }
        .task(id: loadKey) { await load() }
    }

    private func card(_ s: NightSummary, minutes: Int) -> some View {
        NoopCard(tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("Night", tableName: "Fork")
                    .font(StrandFont.overline).tracking(1.6)
                    .foregroundStyle(StrandPalette.textTertiary)
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: CoupledView.hoursMinutes(Double(minutes)))
                            .font(StrandFont.number(30))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer(minLength: NoopMetrics.space2)
                        if let range = bedWakeText(s) {
                            Text(verbatim: range)
                                .font(StrandFont.captionNumber)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                    if let shares = s.stageShares, let stages = s.stages {
                        stageBar(shares)
                        stageLegend(stages, awake: s.awakeMinutes)
                    }
                    if let line = NightSummaryCard.qualityLine(s) { detailLine(line) }
                    detailLine(NightSummaryCard.needLine(s))
                    if let line = NightSummaryCard.vitalsLine(s) { detailLine(line) }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func detailLine(_ text: String) -> some View {
        Text(verbatim: text)
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textSecondary)
    }

    private func bedWakeText(_ s: NightSummary) -> String? {
        guard let bed = s.bedTs, let wake = s.wakeTs else { return nil }
        let formatter = AppClock.hourMinuteFormatter()
        return "\(formatter.string(from: Date(timeIntervalSince1970: Double(bed)))) → \(formatter.string(from: Date(timeIntervalSince1970: Double(wake))))"
    }

    // MARK: Stage bar and legend (the live card's layout, kept private to this view)

    private func stageBar(_ shares: [(stage: String, fraction: Double)]) -> some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(Array(shares.enumerated()), id: \.offset) { _, share in
                    if share.fraction > 0 {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(StrandPalette.sleepStageColor(Self.stage(share.stage)))
                            .frame(width: max(3, geo.size.width * share.fraction - 2))
                    }
                }
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }

    private struct LegendEntry {
        let stage: SleepStage
        let name: Text
        let minutes: Int
    }

    /// One row of four, else two rows of two, else one column: the first layout that fits, so no entry is ever cut.
    private func stageLegend(_ stages: NightSummary.Stages, awake: Int?) -> some View {
        let items = legendEntries(stages, awake: awake)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: NoopMetrics.space3) {
                ForEach(items.indices, id: \.self) { legendItem(items[$0]) }
            }
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                ForEach(stride(from: 0, to: items.count, by: 2).map { $0 }, id: \.self) { start in
                    HStack(spacing: NoopMetrics.space3) {
                        ForEach(start..<min(start + 2, items.count), id: \.self) { legendItem(items[$0]) }
                    }
                }
            }
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                ForEach(items.indices, id: \.self) { legendItem(items[$0]) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func legendEntries(_ stages: NightSummary.Stages, awake: Int?) -> [LegendEntry] {
        var items = [
            LegendEntry(stage: .deep, name: Text("Deep", tableName: "Fork"), minutes: stages.deepMin),
            LegendEntry(stage: .rem, name: Text("REM", tableName: "Fork"), minutes: stages.remMin),
            LegendEntry(stage: .light, name: Text("Light", tableName: "Fork"), minutes: stages.lightMin),
        ]
        if let awake {
            items.append(LegendEntry(stage: .awake, name: Text("Awake", tableName: "Fork"), minutes: awake))
        }
        return items
    }

    private func legendItem(_ entry: LegendEntry) -> some View {
        HStack(spacing: 4) {
            Circle().fill(StrandPalette.sleepStageColor(entry.stage)).frame(width: 7, height: 7).accessibilityHidden(true)
            entry.name.font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            Text(verbatim: NightSummaryCard.shortDuration(entry.minutes))
                .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textPrimary)
        }
        .lineLimit(1)
        .fixedSize()
    }

    private static func stage(_ key: String) -> SleepStage {
        switch key {
        case "deep": return .deep
        case "rem": return .rem
        default: return .light
        }
    }

    // MARK: Load

    private func load() async {
        let now = Date()
        let daysBack = max(0, Calendar.current.dateComponents([.day], from: dayStart, to: now).day ?? 0)
        let all = await repo.allSleepSessions(days: daysBack + 3)
        let habitual = await repo.habitualMidsleepSec()
        let span = SleepView.mainNightSpan(PastNight.windowSessions(all, dayStart: dayStart),
                                           habitualMidsleepSec: habitual)
        // A superseded load (the day changed while it awaited) must not overwrite the newer one.
        guard !Task.isCancelled else { return }
        summary = PastNight.summary(metric: metric, span: span,
                                    sleepNeedMinutes: WindDownNudge.sleepNeedMinutes, now: now)
    }
}
