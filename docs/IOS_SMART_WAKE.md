# iOS Smart Wake

## Status

The iOS Smart Wake path is implemented on `feature/ios-smart-wake` as an opt-in feature:

- It consumes only readable WHOOP 5.0 standard Heart Rate Measurement notifications (GATT 0x2A37).
- The pure detector looks for a sustained rise above a robust baseline. It is a heuristic, not sleep-stage classification.
- AlarmKit schedules the independent maximum-time phone alarm. It is recurring, with one system alarm per selected weekday.
- When the detector finds a valid early trigger, NOOP schedules a one-shot AlarmKit alert and only then replaces that weekday's maximum-time fallback. Dismissing the early alert schedules the next week's occurrence; the normal weekly recurrence resumes after that alarm is dismissed.
- If HR samples are missing, stale, insufficient, or interrupted by iOS suspension, the maximum-time AlarmKit alarm remains scheduled.

AlarmKit requires iOS 26 or later and the user's explicit alarm authorization. The app declares `NSAlarmKitUsageDescription`; if authorization is denied or unavailable, Smart Wake cannot be enabled. AlarmKit alerts can break through Silent mode and Focus when authorized, as documented by Apple.

## Shared wake schedule

Smart Wake does not maintain a second maximum-wake-time setting. It reads the existing WHOOP alarm settings:

- Base wake time: `BehaviorStore.smartAlarmMinutes`.
- Active weekdays: `BehaviorStore.smartAlarmWeekdays` (empty means every day).
- Per-weekday overrides: `WindDownNudge.perDayWakeOverrides`.
- Early window: independent Smart Wake preference, selectable as 15, 20, 30, 45, or 60 minutes.

The WHOOP firmware alarm and phone Smart Wake have separate enable switches. Changing the shared time, weekday selection, or per-day override reconciles the AlarmKit schedule without sending an additional BLE command. The existing WHOOP alarm implementation is not replaced.

AlarmKit keeps a separate weekly fallback for each weekday so an early wake can replace only the current weekday's fallback. When the user dismisses the early alert, its `LiveActivityIntent` skips the current day's maximum-time occurrence and schedules the same weekday for the following week. After that one-shot fires, its stop intent restores the normal weekly recurrence. The other weekdays remain scheduled.

## Data path

`BLEManager.parseStandardHR` decodes the standard HR measurement and checks `LiveHeartRateReadability`. Only readable WHOOP 5.0 samples are forwarded with their receive timestamp through `LiveState.onSmartWakeHeartRateSample`. The iOS root feeds them to `SmartWakeLiveController`.

The callback is not `@Published`, so it does not cause SwiftUI updates for every HR sample. Do not use `AppModel.bpm` as detector input: it is a smoothed display value and is only republished when its median changes.

The controller retains a bounded local baseline in UserDefaults, periodically persisted, so a process relaunch does not automatically discard the entire pre-window baseline. It retains samples across midnight for schedules whose detection window crosses the day boundary. The baseline is filtered to the configured lookback before it is passed to the engine. If there are fewer than 20 valid baseline samples, early wake is disabled for that cycle.

## Detection and safety

- Baseline: median of valid pre-window samples.
- Early trigger: at least 3 consecutive elevated samples, at least 6 BPM above baseline, spanning at least 120 seconds.
- Sample validity: 30–220 BPM; duplicates and out-of-order samples are ignored.
- Maximum sample age: 300 seconds; maximum gap between elevated samples: 180 seconds.
- Missing/poor data never causes an early wake.
- The maximum-time alarm is scheduled independently by AlarmKit, not by an in-process timer.
- An early AlarmKit alarm is scheduled before the current weekday's fallback is cancelled. If scheduling the early alert fails, the maximum-time fallback remains.
- The WHOOP BLE path remains read-only for this feature: no new command, GATT write, haptic/vibration command, firmware alarm change, or second CoreBluetooth manager.
- The existing WHOOP firmware alarm retains its own switch and code path.

## iOS lifecycle and limitations

CoreBluetooth state restoration and the `bluetooth-central` background mode can deliver BLE events while the app is backgrounded, but iOS does not promise continuous execution. The detector can only evaluate samples delivered to the process. The system-owned AlarmKit maximum-time fallback is what protects against suspension, disconnection, force quit, or missing HR data.

AlarmKit is available only on iOS 26+. On earlier iOS versions, the Smart Wake control is not compiled when the SDK lacks AlarmKit, and enabling it is rejected when the runtime OS is earlier than iOS 26. The one-shot fallback immediately after an early wake uses an absolute date for the following week; the normal recurring schedule then returns to AlarmKit's timezone-relative weekly schedule.

The AlarmKit fallback and early-alert lifecycle still require physical-device verification, including authorization denied/granted, phone locked, Focus/Silent mode, background suspension, reconnect, early dismissal, and weekly recurrence. AlarmKit's actual behavior must be checked on the target iOS release.

## Verification

Unit tests cover the pure engine and live controller, including sustained rise, insufficient baseline, out-of-order samples, late launch, configurable windows, weekday overrides, midnight-crossing windows, and restoration of the local baseline after controller recreation.

**The tests have been added but have not yet been executed.** This environment has no Xcode/iOS SDK or connected iPhone/WHOOP hardware, so no iOS build or hardware test is claimed. No GitHub Actions, TestFlight, signing, release, merge, or changes to `main` have been performed.
