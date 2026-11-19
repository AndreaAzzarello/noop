#if os(iOS)
import Foundation

/// Title of the AlarmKit alert. While an alarm rings, iOS draws the alert from `presentation.alert.title`
/// (the stop button passed at schedule time is no longer used), so the wake time has to be part of the title.
/// The title is fixed when the alarm is scheduled; it never takes part in sync or reconcile decisions.
enum SmartWakeAlarmTitle {

    /// "Smart Wake · 07:15" for an alarm that rings at a fixed time of day (the maximum-time fallbacks).
    static func wake(hour: Int, minute: Int) -> LocalizedStringResource {
        let date = Calendar.current.date(from: DateComponents(hour: hour, minute: minute)) ?? Date()
        return wake(at: date)
    }

    /// "Smart Wake · 07:15" for a one-shot alarm that rings at `date`.
    static func wake(at date: Date) -> LocalizedStringResource {
        LocalizedStringResource("Smart Wake · \(time(date))", table: "Fork")
    }

    /// "Early wake · 06:52" for the one-shot alarm armed after an early (light-sleep) wake.
    static func early(at date: Date) -> LocalizedStringResource {
        LocalizedStringResource("Early wake · \(time(date))", table: "Fork")
    }

    /// Hour and minute in the app language, following the reader's 12/24-hour setting.
    private static func time(_ date: Date) -> String {
        ForkFormatters.dateFormatter(template: "jj:mm").string(from: date)
    }
}
#endif
