import SwiftUI
import StrandDesign

/// fork: the Today "Night" card: last night's sleep, the next alarm and tonight's latest bedtime.
///
/// Every figure comes from the app (`repo.today`, the main-night span, the early-wake record, the alarm
/// settings) through `NightSummary`, which holds all the rules. Loading happens in `.task`, never in `body`,
/// and only when `repo.refreshSeq` or an alarm setting changes.
struct NightSummaryCard: View {
    #if os(iOS) && canImport(AlarmKit)
    @ObservedObject private var alarmStore = SmartWakeAlarmStore.shared   // fork: reload when the alarm list changes
    #endif

    typealias Style = TodayFeatureStack.NightStyle

    let style: Style
    /// Preview only: a fixed summary that is never reloaded.
    private let frozen: Bool

    init(style: Style, onLoaded: (() -> Void)? = nil) {
        self.style = style
        self.frozen = false
        self.onLoaded = onLoaded
    }

    /// fork: called after every completed load. Lets a test prove the load starts at all.
    private let onLoaded: (() -> Void)?

    #if DEBUG
    init(style: Style, previewSummary: NightSummary) {
        self.style = style
        self.frozen = true
        self.onLoaded = nil
        _summary = State(initialValue: previewSummary)
        _loaded = State(initialValue: true)
    }
    #endif

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var behavior: BehaviorStore
    @State private var summary: NightSummary?
    @State private var loaded = false

    private struct LoadKey: Equatable {
        let refreshSeq: Int
        let smartWake: Bool
        let strapAlarm: Bool
        let minutes: Int
        let window: Int
        /// Changes whenever the Smart Wake alarm list does (iOS; always 0 elsewhere).
        let alarms: Int
        let need: Int
    }

    private var alarmListRevision: Int {
        #if os(iOS) && canImport(AlarmKit)
        return alarmStore.revision
        #else
        return 0
        #endif
    }

    private var loadKey: LoadKey {
        LoadKey(refreshSeq: repo.refreshSeq, smartWake: behavior.smartWakeEnabled,
                strapAlarm: behavior.smartAlarmEnabled, minutes: behavior.smartAlarmMinutes,
                window: behavior.smartWakeWindowMinutes, alarms: alarmListRevision, need: WindDownNudge.sleepNeedMinutes)
    }

    var body: some View {
        // fork: the root must exist before the first load. A `Group` whose only child is a false `if` has nothing
        // for `.task` to attach to, so the load never started, `loaded` stayed false and the card never appeared
        // (a Saturday with no alarm was only the first morning anybody looked). The zero-height anchor is always there.
        ZStack {
            Color.clear.frame(height: 0).accessibilityHidden(true)
            if loaded, let summary {
                switch style {
                case .full: fullCard(summary)
                case .compact: compactCard(summary)
                }
            }
        }
        .task(id: loadKey) { if !frozen { await load() } }
    }

    // MARK: Full

    private func fullCard(_ s: NightSummary) -> some View {
        NoopCard(tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("Last night", tableName: "Fork")
                    .font(StrandFont.overline).tracking(1.6)
                    .foregroundStyle(StrandPalette.textTertiary)
                if let minutes = s.sleepMinutes {
                    sleepBlock(s, minutes: minutes)
                } else {
                    Text("No sleep recorded last night", tableName: "Fork")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                if s.nextAlarm != nil || s.bedtime != nil || !s.hasSleep {
                    if s.hasSleep { Divider().overlay(StrandPalette.hairline) }
                    alarmBlock(s)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func sleepBlock(_ s: NightSummary, minutes: Int) -> some View {
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
                stageLegend(stages)
            }
            if let eff = s.efficiencyPct {
                Text("Efficiency \(eff)%", tableName: "Fork")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            if let early = s.earlyWakeAt {
                Label {
                    Text(String(format: String(localized: "Early wake at %@", table: "Fork"), Self.timeText(early)))
                } icon: {
                    Image(systemName: "alarm")
                }
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

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

    private func stageLegend(_ stages: NightSummary.Stages) -> some View {
        HStack(spacing: NoopMetrics.space3) {
            legendItem(.deep, name: Text("Deep", tableName: "Fork"), minutes: stages.deepMin)
            legendItem(.rem, name: Text("REM", tableName: "Fork"), minutes: stages.remMin)
            legendItem(.light, name: Text("Light", tableName: "Fork"), minutes: stages.lightMin)
        }
        .accessibilityElement(children: .combine)
    }

    private func legendItem(_ stage: SleepStage, name: Text, minutes: Int) -> some View {
        HStack(spacing: 4) {
            Circle().fill(StrandPalette.sleepStageColor(stage)).frame(width: 7, height: 7).accessibilityHidden(true)
            name.font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            Text(verbatim: CoupledView.hoursMinutes(Double(minutes)))
                .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textPrimary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    @ViewBuilder
    private func alarmBlock(_ s: NightSummary) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            if let next = s.nextAlarm {
                row(Text("Next alarm", tableName: "Fork"), value: Self.alarmText(next))
            } else {
                Text("No alarm set", tableName: "Fork")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            }
            if let bedtime = s.bedtime {
                row(Text("Bedtime tonight", tableName: "Fork"), value: Self.timeText(bedtime))
            } else if s.nextAlarm == nil {
                Text("Turn on an alarm to get a bedtime", tableName: "Fork")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private func row(_ label: Text, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            label.font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: NoopMetrics.space2)
            Text(verbatim: value).font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Compact (afternoon and evening)

    private func compactCard(_ s: NightSummary) -> some View {
        NoopCard(tint: StrandPalette.restColor) {
            HStack(spacing: NoopMetrics.space2) {
                Image(systemName: "moon.stars")
                    .foregroundStyle(StrandPalette.restColor)
                    .accessibilityHidden(true)
                Text(verbatim: compactLine(s))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
        }
    }

    private func compactLine(_ s: NightSummary) -> String {
        var parts: [String] = []
        if let bedtime = s.bedtime {
            parts.append(String(format: String(localized: "Tonight in bed by %@", table: "Fork"), Self.timeText(bedtime)))
        }
        if let next = s.nextAlarm { parts.append(Self.alarmText(next)) }
        if let minutes = s.sleepMinutes { parts.append(CoupledView.hoursMinutes(Double(minutes))) }
        if parts.isEmpty { return String(localized: "Turn on an alarm to get a bedtime", table: "Fork") }
        return parts.joined(separator: " · ")
    }

    // MARK: Formatting

    private func bedWakeText(_ s: NightSummary) -> String? {
        guard let bed = s.bedTs, let wake = s.wakeTs else { return nil }
        return "\(Self.timeText(Date(timeIntervalSince1970: Double(bed)))) → \(Self.timeText(Date(timeIntervalSince1970: Double(wake))))"
    }

    private static func timeText(_ date: Date) -> String { AppClock.hourMinuteFormatter().string(from: date) }

    /// "07:15", with the weekday ahead of it when it is not today; a Smart Wake window reads "06:45–07:15".
    private static func alarmText(_ next: NightSummary.NextAlarm) -> String {
        var time = timeText(next.latest)
        if let start = next.windowStart { time = "\(timeText(start))–\(time)" }
        guard !Calendar.current.isDateInToday(next.latest) else { return time }
        return "\(ForkFormatters.dateFormatter(template: "EEE").string(from: next.latest)) \(time)"
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
        let nowTs = Int(now.timeIntervalSince1970)
        let today = repo.today
        let recent = await repo.allSleepSessions(days: 2).filter { $0.endTs > nowTs - 36 * 3600 }
        let span = SleepView.mainNightSpan(recent, habitualMidsleepSec: await repo.habitualMidsleepSec())
        let alarms = NightAlarmResolver.resolve(behavior: behavior, now: now)
        let inputs = NightSummary.Inputs(
            totalSleepMin: today?.totalSleepMin, efficiency: today?.efficiency,
            deepMin: today?.deepMin, remMin: today?.remMin, lightMin: today?.lightMin,
            bedTs: span?.start, wakeTs: span?.end,
            earlyWakeAt: SmartWakeEarlyWakeRecord.firedAt(inNight: span?.start, wakeTs: span?.end),
            smartWake: alarms.smartWake, strapAlarm: alarms.strapAlarm,
            sleepNeedMinutes: WindDownNudge.sleepNeedMinutes, now: now)
        summary = NightSummary.make(inputs)
        loaded = true
        onLoaded?()
    }
}

/// fork: the next wake-up, resolved through the SAME paths the alarms themselves use: Smart Wake from
/// `SmartWakeLiveWiring.makeSchedule` (the schedule the detector and the AlarmKit fallbacks are armed from),
/// the strap alarm from `AppModel.nextSmartAlarmDate` with the arguments `applySmartAlarm` passes. Both start
/// from the firmware-skip instant, read without deleting it. Smart Wake exists on iOS only.
@MainActor
enum NightAlarmResolver {
    static func resolve(behavior: BehaviorStore, now: Date) -> (smartWake: NightSummary.NextAlarm?, strapAlarm: Date?) {
        let from = NightSkipPeek.searchStart(now: now, smartWakeEnabled: behavior.smartWakeEnabled)
        var smartWake: NightSummary.NextAlarm?
        #if os(iOS)
        if behavior.smartWakeEnabled {
            if let schedule = SmartWakeLiveWiring.makeSchedule(from: behavior),
               let latest = schedule.nextMaximumWakeTime(after: from, calendar: .current) {
                let window = schedule.windowDuration(for: latest, calendar: .current)   // fork: that alarm's own window
                smartWake = NightSummary.NextAlarm(latest: latest,
                                                   windowStart: window > 0 ? latest.addingTimeInterval(-window) : nil)
            }
        }
        #endif
        var strapAlarm: Date?
        if behavior.smartAlarmEnabled {
            strapAlarm = AppModel.nextSmartAlarmDate(minutes: behavior.smartAlarmMinutes,
                                                     weekdays: behavior.smartAlarmWeekdays,
                                                     overrides: WindDownNudge.perDayWakeOverrides,
                                                     from: from)
        }
        return (smartWake, strapAlarm)
    }
}

#if DEBUG
#Preview("Night card (fake data)") {
    let now = Date()
    let cal = Calendar.current
    let wake = cal.date(bySettingHour: 7, minute: 15, second: 0, of: now.addingTimeInterval(86_400)) ?? now
    let full = NightSummary.make(.init(
        totalSleepMin: 452, efficiency: 91, deepMin: 80, remMin: 105, lightMin: 267,
        bedTs: Int(now.addingTimeInterval(-9 * 3600).timeIntervalSince1970),
        wakeTs: Int(now.addingTimeInterval(-3600).timeIntervalSince1970),
        earlyWakeAt: now.addingTimeInterval(-3700),
        smartWake: .init(latest: wake, windowStart: wake.addingTimeInterval(-1800)), strapAlarm: nil,
        sleepNeedMinutes: 480, now: now))
    let empty = NightSummary.make(.init(
        totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil, bedTs: nil, wakeTs: nil,
        earlyWakeAt: nil, smartWake: nil, strapAlarm: nil, sleepNeedMinutes: 480, now: now))
    return ScrollView {
        VStack(spacing: 16) {
            NightSummaryCard(style: .full, previewSummary: full)
            NightSummaryCard(style: .compact, previewSummary: full)
            NightSummaryCard(style: .full, previewSummary: empty)
        }.padding()
    }
}
#endif
