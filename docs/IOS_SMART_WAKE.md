# iOS Smart Wake

## Status

The iOS Smart Wake path is implemented on `feature/ios-smart-wake` as an opt-in feature:

- It consumes only readable WHOOP 5.0 standard Heart Rate Measurement notifications (GATT 0x2A37): heart rate at about 1 Hz and, when present, the RR intervals of the same packet.
- Two pure rules run in the window and the first to fire wins:
  - a **light-sleep estimate** (a causal variant of the V2 sleep stager, see below);
  - a **sustained heart-rate rise** (the older rule, which indicates the user is already awake).
- AlarmKit schedules the independent maximum-time phone alarm. It is recurring, with one system alarm per selected weekday.
- When either rule fires and the strap is connected, the strap vibrates through its **firmware alarm** (silent on the phone), and the iPhone's AlarmKit alarm is only a **backup** that rings 5 minutes later. The weekday's maximum-time alarm stays armed throughout. A strap double tap cancels the backup and moves the maximum-time alarm to next week; without one, both alarms ring. With no usable strap connection the iPhone alarm rings straight away (one-shot, replacing the weekday's fallback only after the one-shot is accepted, as before). See "Strap wake-up".
- If HR samples are missing, stale, insufficient, or interrupted by iOS suspension, the maximum-time AlarmKit alarm remains scheduled.

AlarmKit requires iOS 26 or later and the user's explicit alarm authorization. The app declares `NSAlarmKitUsageDescription`; if authorization is denied or unavailable, Smart Wake cannot be enabled. AlarmKit alerts can break through Silent mode and Focus when authorized, as documented by Apple.

## Alarm list and the schedule

Smart Wake has a list of alarms, like the Clock app: each has a switch, a latest wake time, repeat days, an optional label (up to 32 characters), an early window (15, 20, 30, 45 or 60 minutes) and its own "Insistent strap alarm" switch. **At most one active alarm per weekday**: switching on or saving an alarm that shares a day with another active one is refused with a message that names the other alarm and its days, and offers "Switch off X and turn this on". Nothing is ever switched off silently.

While Smart Wake is on, the list is the source of the schedule:

- `SmartWakeAlarmBook` (`Strand/Data/SmartWakeAlarmBook.swift`) holds the list (`smartWake.alarms.v1`, JSON, versioned; an unreadable blob is kept in `smartWake.alarms.v1.corrupt` and the list is rebuilt from the upstream settings). `effectiveDays()` maps each weekday to the alarm that rings on it.
- `SmartWakeSchedule.compiled(days:)` turns that map into the schedule the detector, AlarmKit, the widget and the Night card already read: the most frequent time and window are the schedule-wide ones, the other days carry overrides, labels and insistence are per weekday. No active alarm means no schedule: nothing is armed and the detector stays idle.
- **First launch with the list:** the current configuration (`BehaviorStore.smartAlarmMinutes`, `smartAlarmWeekdays`, `WindDownNudge.perDayWakeOverrides`, the early window, the old insistent switch) becomes the first alarm. It compiles to the same schedule as before, so the sync plan is "nothing" and AlarmKit is not called. The upstream values are saved once in `smartWake.alarms.preMigrationUpstream`.
- **Upstream mirror** (`SmartWakeUpstreamMirror`): the upstream alarm settings are kept equal to what the list resolves to (and only written when they differ), so `applySmartAlarm()`, the strap's firmware alarm, the backup notification, the "next buzz" line and the evening reminder see the next occurrence among all active alarms. `SmartWakeArmHold` makes one list change arm the strap once, on the complete settings, however many `onChange` echoes the writes cause. Overrides of days that are not active are kept (the evening reminder reads them).
- With Smart Wake off nothing changes: the Alarms screen is the one it always was (plus a note when the mirrored values differ from the original ones). With the list in charge, the strap alarm's time, day and per-day editors are replaced by a line that points to the Smart Wake card.
- The WHOOP firmware alarm and phone Smart Wake keep separate enable switches. The firmware alarm is disarmed when Smart Wake is on and no alarm is active.

AlarmKit keeps a separate weekly fallback for each weekday so an early wake can replace only the current weekday's fallback. The alarm ids (slot A/B per weekday) are unchanged. `SmartWakeSyncPlan` compares what each weekday actually asks of AlarmKit (time and label): a change of window or insistence only updates the saved schedule ("metadata updated, no alarm change"); a changed alarm reinstalls only its weekdays, through the idle slot as before. Several changes in a row (the time picker, a switch, a foreground) are merged into one sync after 1.5 s of quiet, or when the app goes to the background; the alarms already installed stay armed meanwhile.

The detector uses the window of the weekday that rings (also across midnight), and sample retention uses the longest window of the active days. The strap's insistent repeat is decided per morning by the alarm that rings (with no list, by the old global switch). When the user dismisses the early alert, its `LiveActivityIntent` skips the current day's maximum-time occurrence and schedules the same weekday for the following week; after that one-shot fires, its stop intent restores the normal weekly recurrence.

## Data path

`BLEManager.parseStandardHR` decodes the standard HR measurement and checks `LiveHeartRateReadability`. RR intervals go to `LiveState.rr` / `rrSeq`, then only readable WHOOP 5.0 samples are forwarded with their receive timestamp through `LiveState.onSmartWakeHeartRateSample`. The iOS root feeds them, and the RR of the packet when `rrSeq` changed, to `SmartWakeLiveController` (`SmartWakeLiveWiring`).

The callback is not `@Published`, so it does not cause SwiftUI updates for every HR sample. Do not use `AppModel.bpm` as detector input: it is a smoothed display value and is only republished when its median changes.

Gravity (motion) is **not** available live on a WHOOP 5.0: it arrives only with the history download, every 15 minutes or more. The live IMU stream is deliberately stopped by `BLEManager.stopUnexpectedRealtimeImu`. The live rules therefore use heart rate and RR only.

The controller retains a bounded local baseline in UserDefaults, periodically persisted, so a process relaunch does not automatically discard the entire pre-window baseline. It retains samples across midnight for schedules whose detection window crosses the day boundary. The baseline is filtered to the configured lookback before it is passed to the engine. If there are fewer than 20 valid baseline samples, the rise rule is disabled for that cycle. The persisted baseline holds heart rate only, so the RR of the reference epochs is not retained across a relaunch.

## Light-sleep rule

`SmartWakeLightSleepDetector` (`StrandiOSShared/SmartWakeEngine.swift`) is a causal variant of `SleepStagerV2` for the live window. V2 itself cannot run on a night in progress: its z-scores and percentiles span the whole night, its features look up to 390 s ahead, and it decodes with two Viterbi passes.

What it keeps from V2 (same constants): 30 s epochs, heart-rate mean, heart-rate spread over trailing 5 and 11 minute windows, respiration regularity from the RR (RSA peakedness), the log-priors, the sleep-cycle prior and the transition matrix. What it changes: the windows are trailing, normalisation is against the epochs seen so far, the position in the night is estimated from the time left to the maximum wake time, and decoding is a forward filter instead of Viterbi.

Without motion, V2's "still wrist" case applies to every epoch, so a raised heart rate alone never votes "awake": the live rule separates deep, REM and light, not wake.

Rule: at least 60 reference epochs before the window, then `P(light) >= 0.60` for 4 consecutive valid epochs (2 minutes; an epoch needs at least 20 samples and no hole above 10 s; a missing or unusable epoch restarts the count), **and** the run must be an entry into light sleep: at least one of the 10 window epochs before the run began must have been REM or deep (`transitionLookbackEpochs`). Epochs before the window do not count, so the rule cannot fire until the window itself has shown a non-light epoch.

**Why the transition condition.** Without movement, light is close to the model's prior and `P(light)` was already at or above 0.60 on the first window epoch in 15 of 27 replayed windows, so the earlier rule (`0.60` for 3 epochs, no transition) woke 58% of the time within 3 minutes of the window opening, whatever the sleep stage. Raising the threshold or the duration alone did not fix that (33-52% of wakes in the first 3 minutes across window lengths, with many windows no longer firing); an observation period at the start of the window moved the wakes to just after it instead of spreading them.

**What the replay shows, and its limits.** Nine recorded nights, 27 windows per configuration (the configurations re-use the same nights, so they are not independent), with the stage computed afterwards by V2 as the reference. It is not polysomnography. The rule was chosen on 30-minute windows ending 0 / 60 / 120 minutes after the session end and checked on other offsets and on 20 and 45 minute windows:

| | 30 min, tuning | 30 min, other offsets | 20 min | 45 min |
|---|---|---|---|---|
| Windows that fire early | 19/27 | 18/27 | 16/27 | 22/27 |
| Wakes in the first 3 min (earlier rule) | 5% (58%) | 0% (41%) | 6% (48%) | 5% (52%) |
| V2 light at the wake (light share of the window) | 42% (39%) | 72% (46%) | 56% (38%) | 59% (42%) |
| V2 deep at the wake (earlier rule) | 0% (4%) | 0% (9%) | 0% (9%) | 5% (4%) |

- In the windows where the rule does not fire, the maximum-time alarm is the guarantee, as before.
- The light share at the wake is above the window's own light share in every configuration but it did not reach the 60% target in the tuning set (42%) nor on 20 and 45 minute windows (56-59%). With only heart rate and RR, `P(light)` separates light from REM (mean 0.52 against 0.30) but **not** light from deep (0.52 against 0.51; AUC 0.70-0.74 for light against REM and deep). A higher light share would need movement, which is not available live on a WHOOP 5.0.
- "Wake" at the wake in the replay comes mostly from the few windows where the heart-rate-rise rule fired, i.e. the user was already awake.
- A single wake moves a percentage by 4-7 points. Read the table as a direction, not as a precision.

The rule has **not** been tested on a strap or in a real night.

Diagnostics: at the end of each window the Smart Wake window summary also carries why the rule did or did not wake early (reference epochs, window epochs, unusable epochs, the highest P(light), the stage counts, and the wake time or the reason for none).

## Strap wake-up (firmware alarm)

**The app never sends haptic commands for the wake-up.** On 2026-11-17 an early wake sent three stacked `runHapticsPattern` commands (8 loops each, 5 s apart) to a WHOOP 5.0 and the strap vibrated continuously for over 15 minutes, with Bluetooth off, until it was restarted from Devices. The double tap reached the app but did not stop the strap: `STOP_HAPTICS` is not on the 5.0/MG allowlist and a pattern the app started is not cancelled by the gesture. It happened at every early wake, with the insistent option off too.

The vibration is now the WHOOP firmware alarm, whose chain was captured on a 5/MG (#864): `STRAP_DRIVEN_ALARM_EXECUTED` (57), then `HAPTICS_FIRED` (60), dismissed by `DOUBLE_TAP`. `SmartWakeStrapAlarm` calls the existing `BLEManager.armStrapAlarm(at:)` (unchanged) for **now + 30 s**:

- 30 s covers the write and ack, the strap-clock skew set at connect, and a late 1 Hz tick; the "Test strap alarm" button checks it on the real strap.
- On a 5/MG the arm needs Protocol probes (Test Centre), exactly as the normal firmware alarm does. If the strap is not connected and bonded, or probes are off, the firmware alarm is "not usable" and the iPhone alarm rings straight away.
- The firmware alarm is one absolute instant that `AppModel.applySmartAlarm()` re-arms on every foreground, reconnect and settings change. While a wake-up run is live, `SmartWakeFirmwareWake` stores the instant and `applySmartAlarm()` re-sends it instead of the normal time (one line in `AppModel`). The override is dropped when the run ends and 120 s after its instant at the latest, so a stale value can never block the normal alarm.
- Event 57 during a run is consumed by the run: no "smart alarm" notification sound and no re-arm of tomorrow's alarm until the run ends. Event 60 is not routed to any callback (it would need a BLE change) and stays visible in the strap log. If event 57 is not seen within 90 s of the armed instant, the run logs "not observed" and carries on as if the alarm had fired.

## Strap wake-up lifecycle

`InsistentWakeAlarm` (pure) states: **armed** (waiting for 57) → **fired** (vibrating, waiting for a double tap) → stopped by **double tap**, **repeat limit** or **expired**.

- Default: one vibration. If nobody double-taps within 5 minutes of it, the run expires.
- "Insistent strap alarm" (card switch, off by default): a fired alarm with no double tap within 5 minutes is armed again for now + 30 s, up to 6 repeats (7 vibrations, about 35 minutes), then the run ends. It also starts at the maximum time when no early wake happened (the firmware alarm is already armed for that instant, so nothing is sent).
- A double tap ends the run at once: the override is cleared, anything NOOP's AlarmKit has ringing is stopped, and the normal firmware alarm is armed again through `applySmartAlarm()` (with `SmartWakeFirmwareSkip` for an early wake, below). A double tap with no run in progress goes to the user's own double-tap action.

Every step is written to Smart Wake diagnostics: armed for HH:mm:ss (first or repeat n), strap alarm fired (event 57), event 57 not observed, double tap, repeat limit, expired, test started and test ended.

## iPhone alarm order after an early wake

1. Strap connected and usable: the strap vibrates alone, silently. The AlarmKit one-shot is scheduled for **early wake + 5 minutes** (`SmartWakeBackupPlan`); no backup is scheduled when that would not be before the maximum time, because the maximum-time alarm covers it.
2. The weekday's maximum-time alarm is **not** removed when the backup is scheduled, and the reconcile step is told not to cancel it while the backup exists (iOS can deliver `alarmUpdates` late with the app suspended, so a stale list must never remove it).
3. A strap double tap runs `confirmEarlyWakeFromStrap` in-process (the BLE callback keeps the app alive; it does not wait for `alarmUpdates`): the next week's maximum-time alarm is scheduled **before** today's is removed, and the backup is cancelled only after that succeeded. If scheduling fails, everything stays armed: at worst a spare alarm, never zero.
4. No double tap: the backup rings at +5 minutes and the maximum-time alarm remains. Stopping the backup from the iPhone is handled by the existing dismissal path (it skips today's maximum time).
5. Strap not connected at the early wake: the iPhone one-shot rings after 8 s and replaces the weekday's fallback, as before.

## Testing the strap alarm

Smart Wake card, Diagnostics, **Test strap alarm in 1 minute**: arms the firmware alarm for now + 60 s without touching the iPhone alarms. Check on the strap that it vibrates and that a double tap stops it. The normal alarm is restored when the test ends (double tap, or 5 minutes after the instant), and the log shows armed, event 57, double tap and "normal alarm restored". Do this in daylight before trusting a real night.

## WHOOP firmware alarm after an early wake

After an early wake ends (a double tap, or the repeating vibration running out or expiring) the strap's firmware alarm would still vibrate at the maximum time. `SmartWakeFirmwareSkip` remembers the maximum time that was replaced, and `AppModel.applySmartAlarm()` searches for the next firmware occurrence after it instead of after "now" (one changed argument). `armStrapAlarm` and `disableStrapAlarm` are not modified. The skip lasts at most 24 hours and applies only while Smart Wake is on; with Smart Wake off, or nothing recorded, the firmware alarm behaves exactly as before.

`applySmartAlarm()` also schedules a backup local notification at the maximum time. That notification is not covered by the skip.

## Detection and safety

- Rise rule baseline: median of valid pre-window samples. Trigger: at least 3 consecutive elevated samples, at least 6 BPM above baseline, spanning at least 120 seconds.
- Sample validity: 30–220 BPM; duplicates and out-of-order samples are ignored.
- Maximum sample age: 300 seconds; maximum gap between elevated samples: 180 seconds.
- Missing/poor data never causes an early wake.
- The maximum-time alarm is scheduled independently by AlarmKit, not by an in-process timer.
- An early AlarmKit alarm is scheduled before the current weekday's fallback is cancelled. If scheduling the early alert fails, the maximum-time fallback remains.
- BLE: no haptic command is sent for the wake-up. The strap is driven only through the existing, unchanged `armStrapAlarm` (SET_ALARM_TIME), the same call the normal alarm uses, which a double tap dismisses. No new opcode, no change to `Strand/BLE/`, no second CoreBluetooth manager.

## iOS lifecycle and limitations

CoreBluetooth state restoration and the `bluetooth-central` background mode can deliver BLE events while the app is backgrounded, but iOS does not promise continuous execution. The detectors and the vibration schedule can only act on samples delivered to the process.

- **App suspended but connected:** each heart-rate notification wakes the process briefly, so detection, the repeat re-arm and the double-tap handling continue; a timer alone would not.
- **Strap out of range or disconnected:** no heart rate, so no early wake from the app. The AlarmKit maximum-time alarm and the firmware alarm remain. A repeat arm that cannot be sent is queued and sent on the next connect.
- **App force-quit:** iOS does not relaunch it for BLE events. No early wake, no repeats, no double-tap handling from NOOP. An alarm already armed on the strap still fires and a double tap still ends it (firmware only); the AlarmKit maximum-time alarm still rings.
- **iOS 27 and `alarmUpdates`:** updates can arrive late while the app is suspended. The backup flow therefore never relies on them: the maximum-time alarm is not cancelled until a double tap has been handled in-process, and the reconcile step leaves it in place while the backup exists.
- A double tap while the app has no process is handled by the strap firmware only (it ends the firmware alarm).

AlarmKit is available only on iOS 26+. On earlier iOS versions, the Smart Wake control is not compiled when the SDK lacks AlarmKit, and enabling it is rejected when the runtime OS is earlier than iOS 26. The one-shot fallback immediately after an early wake uses an absolute date for the following week; the normal recurring schedule then returns to AlarmKit's timezone-relative weekly schedule.

Apple documents that AlarmKit alerts break through Silent mode and Focus when authorized. However, developers have reported delayed or missed overnight AlarmKit alerts on iOS 26 and early iOS 27 builds. This is not proof that the issue remains in iOS 27.2, but it means the system alarm must not be treated as infallible until tested on the actual device and OS version. Keep the iPhone Clock alarm as a backup during validation.

The AlarmKit fallback and early-alert lifecycle still require physical-device verification, including authorization denied/granted, phone locked, Focus/Silent mode, background suspension, reconnect, early dismissal, and weekly recurrence. Whether `AlarmManager.stop(id:)` on a ringing one-shot also runs its stop intent is not documented and must be checked on the device; the alarm observer restores the fallback either way.

## Verification

Unit tests cover the pure engine, the live controller, the light-sleep rule's gating (reference, window, holes, restarted count), its scoring pieces and respiration feature, the strap wake-up schedule (arm, fired, event not observed, repeat after 5 minutes, exactly 6 repeats then the limit, double tap while armed or fired, expiry, duplicate and late ticks, and that it can only ever ask to arm the firmware alarm), the firmware-alarm override and the backup date, and the firmware skip.

The light-sleep tests use synthetic data: they cover the gating, the 4-epoch requirement, and the transition decision (a pure function, `SmartWakeLightSleepDetector.enteredLight`), not the numeric calibration. A synthetic heart-rate trace cannot be steered into a run that starts after a REM epoch, so the positive case of the transition rule is exercised by the replay, not by a unit test. `Tools/SmartWakeReplay` checks the thresholds offline on recorded nights:

```bash
unzip -p ~/Backup.noopbak noop-backup.sqlite > /tmp/noop.sqlite
python3 Tools/SmartWakeReplay/export.py /tmp/noop.sqlite /tmp/smartwake-nights
swiftc -O StrandiOSShared/SmartWakeEngine.swift StrandiOSShared/SmartWakeLiveController.swift \
    Tools/SmartWakeReplay/main.swift -o /tmp/swr
/tmp/swr /tmp/smartwake-nights --window 30 --offsets 0,-60,-120
```

It runs each night through the real controller as the app feeds it, with a simulated maximum wake time at the session end plus each offset, and reports how early the rule woke, the distribution of wake times inside the window, and the after-the-night V2 stage and the strap's own `sleep_state` at that moment, next to each stage's share of the window. If most wakes land in the first minutes of the window, or in V2 deep sleep, the rule is not tracking sleep depth. The exported files hold personal health data: write them outside the repository and delete them afterwards.

The alarm list is covered by tests for the model and its Codable form, the overlap rule, the migration (a grid of configurations compiles to the same schedule, with zero writes to the upstream keys and zero AlarmKit calls), the mirror, the arm hold, the sync plan, the debouncer, per-weekday windows and insistence, and the widget's next wake. The list UI, AlarmKit and the strap path are verified only on the phone.

**Not yet verified:** the alarm list on a phone (migration of the current alarm, a second alarm, a refused overlap, two non-overlapping alarms active together, both test buttons, the widget and the Night card, a few real nights with a backup alarm in the Clock app). Nothing has been tested on a strap or an iPhone after the move to the firmware alarm (the 2026-11-17 stuck vibration is what it replaces). Run the test button first.

Before that: nothing had been tested on a strap or an iPhone. The rule was calibrated offline on nine nights (see above). No GitHub Actions, TestFlight, signing, release, merge, or changes to `main` have been performed.
