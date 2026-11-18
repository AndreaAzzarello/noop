#if canImport(AlarmKit)
import ActivityKit
import AlarmKit
import StrandDesign
import SwiftUI
import WidgetKit

/// Widget-extension twin of the app's metadata type.
///
/// The app declares its own `SmartWakeAlarmMetadata` (empty, file-private, in `SmartWakeAlarmScheduler.swift`)
/// and is left untouched on purpose: every alarm already scheduled was created with it. ActivityKit pairs an
/// activity with its `ActivityConfiguration` by the unqualified type name, the same way it pairs
/// `NOOPActivityAttributes` compiled into both modules, so a type of the same name, shape and (empty) coding
/// in this module is all the extension needs. Keep the name and the empty body in step with the app's copy.
struct SmartWakeAlarmMetadata: AlarmMetadata {}

/// Lock Screen and Dynamic Island presentation of the Smart Wake alarm.
///
/// Before this existed the system started an activity for the alarm that had no layout to draw, which showed
/// as an empty black pill. The alarm itself (schedule, Stop, skip, re-arm) is untouched: this only draws what
/// the system reports. The Stop button on the alert is the system's own.
///
/// Deliberately plain: static, no animation, only `StrandPalette` tokens. The wake time is read from the
/// activity state (`AlarmPresentationState`), never recomputed here.
@available(iOS 26.0, *)
struct SmartWakeAlarmLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<SmartWakeAlarmMetadata>.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "alarm.fill")
                    .font(.title2)
                    .foregroundStyle(StrandPalette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(FL.s("Smart Wake"))
                        .font(.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                    SmartWakeAlarmTime(state: context.state)
                        .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                Spacer(minLength: 0)
            }
            .padding()
            .activityBackgroundTint(StrandPalette.surfaceBase)
            .activitySystemActionForegroundColor(StrandPalette.textPrimary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "alarm.fill").foregroundStyle(StrandPalette.accent)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(FL.s("Smart Wake")).font(.caption).foregroundStyle(StrandPalette.textSecondary)
                        SmartWakeAlarmTime(state: context.state)
                            .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                    }
                }
            } compactLeading: {
                Image(systemName: "alarm.fill").foregroundStyle(StrandPalette.accent)
            } compactTrailing: {
                SmartWakeAlarmTime(state: context.state).font(.caption.monospacedDigit())
            } minimal: {
                Image(systemName: "alarm.fill").foregroundStyle(StrandPalette.accent)
            }
        }
    }
}

/// The time the activity is about: the alert's clock time, or the countdown's end if the system reports one.
/// Anything else (a paused countdown) shows nothing rather than an invented figure.
@available(iOS 26.0, *)
private struct SmartWakeAlarmTime: View {
    let state: AlarmPresentationState

    var body: some View {
        switch state.mode {
        case .alert(let alert):
            Text(clock(hour: alert.time.hour, minute: alert.time.minute))
        case .countdown(let countdown):
            Text(countdown.fireDate, style: .time)
        default:
            EmptyView()
        }
    }

    private func clock(hour: Int, minute: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}
#endif
