import Foundation

/// Does the "Night only" window of continuous HRV capture end before a Smart Wake window has finished?
///
/// Informational only: nothing here schedules, starts, stops or skips anything. `BLEManager` arms the dense heart-rate
/// stream from `ContinuousHrvSchedule` (the notification quiet hours, 22:00–07:00 by default) and Smart Wake's own window
/// is `[maximum wake − early window, maximum wake]`; when the first ends inside the second, Smart Wake may be left with
/// no heart-rate samples for the end of its window. Whether it is (the strap's standard heart-rate notifications may
/// flow without the dense stream) is a property of the hardware this cannot know, so the warning says "may".
///
/// Pure and in `Strand/System` so `StrandTests` covers it.
enum SmartWakeStreamWindowCheck {

    /// True when, for any of `wakeMinutes` (minutes since midnight of each active day's maximum wake time), a minute
    /// strictly before the maximum time but inside its early window lies outside `[startMin, endMin)` (wrap-aware, the
    /// same membership `ContinuousHrvSchedule.streamWanted` uses). The maximum minute itself is not checked: at that
    /// time the AlarmKit and firmware alarms take over regardless of samples.
    static func windowEndsBeforeAlarm(wakeMinutes: [Int], windowMinutes: Int, startMin: Int, endMin: Int) -> Bool {
        guard windowMinutes > 0 else { return false }
        for wake in wakeMinutes {
            for back in 1...windowMinutes {
                let minute = (((wake - back) % 1440) + 1440) % 1440
                if !ContinuousHrvSchedule.windowContains(minute, startMin: startMin, endMin: endMin) { return true }
            }
        }
        return false
    }
}
