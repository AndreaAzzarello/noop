#if os(iOS)
import SwiftUI
import StrandDesign

/// Shows, on the Smart Wake card and its diagnostics, when continuous HRV capture is set to "Night only" and the end of
/// that window falls before the end of an active Smart Wake window. Display only: it reads settings and changes none.
///
/// Where the window is set: Settings → HRV → "Night only" (the switch), and the end time is the "Quiet hours" end under
/// the notification settings (`notif.quietEndMinutes`), which the stream shares with the quiet hours.
struct SmartWakeStreamNotice: View {
    @EnvironmentObject private var behavior: BehaviorStore
    /// Per-day wake overrides, handed down by the card that already holds them.
    let overrides: [Int: Int]

    @AppStorage(PuffinExperiment.keepRealtimeForDataKey) private var continuousHrv = false
    /// Unset means ON, the same reading as `PuffinExperiment.continuousHrvOvernightOnlyEnabled`.
    @AppStorage(PuffinExperiment.continuousHrvOvernightOnlyKey) private var overnightChoice: Bool?
    @AppStorage(ContinuousHrvSchedule.quietStartKey) private var quietStart: Int?
    @AppStorage(ContinuousHrvSchedule.quietEndKey) private var quietEnd: Int?

    private var windowEndsBeforeAlarm: Bool {
        guard behavior.smartWakeEnabled, behavior.smartAlarmEnabled, continuousHrv, overnightChoice ?? true else { return false }
        let schedule = SmartWakeSchedule(
            wakeMinutes: behavior.smartAlarmMinutes, weekdays: behavior.smartAlarmWeekdays, overrides: overrides,
            windowDuration: TimeInterval(behavior.smartWakeWindowMinutes * 60))
        let wakes = (1...7).filter(schedule.isEnabled(onWeekday:)).map(schedule.wakeMinutes(onWeekday:))
        return SmartWakeStreamWindowCheck.windowEndsBeforeAlarm(
            wakeMinutes: wakes, windowMinutes: behavior.smartWakeWindowMinutes,
            startMin: quietStart ?? ContinuousHrvSchedule.defaultStartMinutes,
            endMin: quietEnd ?? ContinuousHrvSchedule.defaultEndMinutes)
    }

    var body: some View {
        if windowEndsBeforeAlarm {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(StrandPalette.statusWarning)
                Text("The night window ends before the alarm: Smart Wake may not receive heart rate", tableName: "Fork")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
#endif
