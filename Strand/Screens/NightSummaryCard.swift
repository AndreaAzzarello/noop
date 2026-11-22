import SwiftUI
import StrandDesign

/// fork: the Today "Night" card: last night's sleep, the next alarm and tonight's latest bedtime.
///
/// Every figure comes from the app (`repo.today`, the main-night span, the early-wake record, the alarm
/// settings) through `NightSummary`, which holds all the rules. Loading happens in `.task`, never in `body`,
/// and only when the night's figures, the hour or an alarm setting change (see `NightKey`).
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
    /// fork: the style actually drawn; `style` is only what the clock asks for (see `NightCardStyle`).
    @State private var shownStyle: Style?

    /// fork: what a load reads of the night. Replaces `refreshSeq`, which moves on every data refresh (44 loads a day
    /// for a card that was shown twice): the card reloads when the night's own figures change, when the hour turns
    /// (the bedtime and the next alarm age) or when an alarm setting changes.
    private struct NightKey: Equatable {
        let day: String
        let total: Double?
        let efficiency: Double?
        let deep: Double?
        let rem: Double?
        let light: Double?
        let disturbances: Int?
        let restingHr: Int?
        let avgHrv: Double?
        let sleepSessions: Int
        /// The ends of both ends of the (sorted) session list: whichever is the newest, a new night moves one of them.
        let sleepEnds: [Int?]
    }

    private struct LoadKey: Equatable {
        let night: NightKey
        let hour: Int
        let smartWake: Bool
        let strapAlarm: Bool
        let minutes: Int
        let window: Int
        /// Changes whenever the Smart Wake alarm list does (iOS; always 0 elsewhere).
        let alarms: Int
        /// The strap alarm's day set and per-day times: a change to either moves the next alarm the card names.
        let weekdays: Set<Int>
        let overrides: [Int: Int]
        let need: Int
        /// The local day, so a card left open across midnight reloads for the new night.
        let day: String
    }

    private var alarmListRevision: Int {
        #if os(iOS) && canImport(AlarmKit)
        return alarmStore.revision
        #else
        return 0
        #endif
    }

    private var nightKey: NightKey {
        let t = repo.today
        return NightKey(day: t?.day ?? "", total: t?.totalSleepMin, efficiency: t?.efficiency, deep: t?.deepMin,
                        rem: t?.remMin, light: t?.lightMin, disturbances: t?.disturbances, restingHr: t?.restingHr,
                        avgHrv: t?.avgHrv, sleepSessions: repo.sleeps.count, sleepEnds: [repo.sleeps.first?.endTs, repo.sleeps.last?.endTs])
    }

    private var loadKey: LoadKey {
        LoadKey(night: nightKey, hour: Int(Date().timeIntervalSince1970 / 3600), smartWake: behavior.smartWakeEnabled,
                strapAlarm: behavior.smartAlarmEnabled, minutes: behavior.smartAlarmMinutes,
                window: behavior.smartWakeWindowMinutes, alarms: alarmListRevision,
                weekdays: behavior.smartAlarmWeekdays, overrides: WindDownNudge.perDayWakeOverrides,
                need: WindDownNudge.sleepNeedMinutes,
                day: Repository.dayString(Date()))
    }

    var body: some View {
        // fork: the root exists before the first load, so `.task` never hangs off an empty `Group`. A hardening only:
        // hosting the card on macOS starts the load with either root, so this is not the proven cause of a card that
        // failed to show. The energy counters (`nightCard*`) tell on a device where it stops.
        ZStack {
            Color.clear.frame(height: 0).accessibilityHidden(true)
            if loaded, let summary {
                Group {
                    switch shownStyle ?? style {
                    case .full: fullCard(summary)
                    case .compact: compactCard(summary)
                    }
                }
                .onAppear { ForkEnergyCounters.shared.note(.nightCardShown) } // fork-perf: TEMP
            }
        }
        .task(id: loadKey) {
            ForkEnergyCounters.shared.note(.nightCardTask) // fork-perf: TEMP
            if !frozen { await load() }
        }
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
                stageLegend(stages, awake: s.awakeMinutes)
            }
            if let line = Self.qualityLine(s) { detailLine(line) }
            detailLine(Self.needLine(s))
            if let line = Self.vitalsLine(s) { detailLine(line) }
            if let outcome = s.outcome {
                Label {
                    Text(verbatim: Self.outcomeText(outcome))
                } icon: {
                    Image(systemName: "alarm")
                }
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

    private func detailLine(_ text: String) -> some View {
        Text(verbatim: text)
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textSecondary)
    }

    /// A Fork-table string as a `String`; the key is the interpolated literal, so catalog keys carry `%lld` / `%@`.
    private static func fork(_ resource: LocalizedStringResource) -> String { String(localized: resource) }

    /// "Efficiency 94% · Wake-ups: 3"; nil when neither is known.
    static func qualityLine(_ s: NightSummary) -> String? {
        var parts: [String] = []
        if let eff = s.efficiencyPct { parts.append(Self.fork(LocalizedStringResource("Efficiency \(eff)%", table: "Fork"))) }
        if let wakings = s.wakings { parts.append(Self.fork(LocalizedStringResource("Wake-ups: \(wakings)", table: "Fork"))) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The need next to what was slept. The need is the one that drives the bedtime below, so the two agree.
    static func needLine(_ s: NightSummary) -> String {
        let need = CoupledView.hoursMinutes(Double(s.sleepNeedMinutes))
        guard let delta = s.needDelta, abs(delta) >= 5 else {
            return Self.fork(LocalizedStringResource("Need \(need) · met", table: "Fork"))
        }
        let amount = CoupledView.hoursMinutes(Double(abs(delta)))
        return delta < 0 ? Self.fork(LocalizedStringResource("Need \(need) · \(amount) short", table: "Fork"))
                         : Self.fork(LocalizedStringResource("Need \(need) · \(amount) over", table: "Fork"))
    }

    static func vitalsLine(_ s: NightSummary) -> String? {
        var parts: [String] = []
        if let hr = s.restingHr { parts.append(Self.fork(LocalizedStringResource("Lowest HR \(hr) bpm", table: "Fork"))) }
        if let hrv = s.hrvMs { parts.append(Self.fork(LocalizedStringResource("HRV \(hrv) ms", table: "Fork"))) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func outcomeText(_ outcome: NightSummary.WakeOutcome) -> String {
        switch outcome {
        case let .early(at, minutes?):
            return Self.fork(LocalizedStringResource("Woke at \(timeText(at)), \(minutes) min early", table: "Fork"))
        case let .early(at, nil):
            return String(format: String(localized: "Early wake at %@", table: "Fork"), timeText(at))
        case let .maximum(at):
            return Self.fork(LocalizedStringResource("Woke at the maximum time, \(timeText(at))", table: "Fork"))
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

    private func stageLegend(_ stages: NightSummary.Stages, awake: Int?) -> some View {
        HStack(spacing: NoopMetrics.space3) {
            legendItem(.deep, name: Text("Deep", tableName: "Fork"), minutes: stages.deepMin)
            legendItem(.rem, name: Text("REM", tableName: "Fork"), minutes: stages.remMin)
            legendItem(.light, name: Text("Light", tableName: "Fork"), minutes: stages.lightMin)
            if let awake {   // fork: time in bed not asleep
                legendItem(.awake, name: Text("Awake", tableName: "Fork"), minutes: awake)
            }
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

    private static let seenDayKey = "fork.nightCard.seenDay"
    private static let seenAtKey = "fork.nightCard.seenAt"

    private static func loadSeen() -> NightCardStyle.Seen? {
        let d = UserDefaults.standard
        guard let day = d.string(forKey: seenDayKey), d.object(forKey: seenAtKey) != nil else { return nil }
        return NightCardStyle.Seen(nightDay: day, firstSeenAt: Date(timeIntervalSince1970: d.double(forKey: seenAtKey)))
    }

    private static func saveSeen(_ seen: NightCardStyle.Seen) {
        let d = UserDefaults.standard
        d.set(seen.nightDay, forKey: seenDayKey)
        d.set(seen.firstSeenAt.timeIntervalSince1970, forKey: seenAtKey)
    }

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
            sleepNeedMinutes: WindDownNudge.sleepNeedMinutes, now: now,
            disturbances: today?.disturbances, restingHr: today?.restingHr, avgHrv: today?.avgHrv,
            earlyWakeMaximum: SmartWakeEarlyWakeRecord.maximumWake(inNight: span?.start, wakeTs: span?.end),
            maximumTimeAt: SmartWakeEarlyWakeRecord.maximumTimeAt(inNight: span?.start, wakeTs: span?.end))
        // fork: a superseded load (the key changed while it awaited) must not overwrite the newer one with older data.
        guard !Task.isCancelled else { return }
        let made = NightSummary.make(inputs)
        let nightDay = span.map { Repository.dayString(Date(timeIntervalSince1970: Double($0.end))) }
        let resolution = NightCardStyle.resolve(requested: style, hasSleep: made.sleepMinutes != nil,
                                                nightDay: nightDay, seen: Self.loadSeen(), now: now)
        if let record = resolution.record { Self.saveSeen(record) }
        shownStyle = resolution.style
        summary = made
        loaded = true
        ForkEnergyCounters.shared.note(.nightCardLoaded) // fork-perf: TEMP
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
