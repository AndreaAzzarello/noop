# iOS Smart Wake

## Status

The iOS Smart Wake path is implemented on `feature/ios-smart-wake` as an opt-in feature:

- It consumes only readable WHOOP 5.0 standard Heart Rate Measurement notifications (GATT 0x2A37): heart rate at about 1 Hz and, when present, the RR intervals of the same packet.
- Two pure rules run in the window and the first to fire wins:
  - a **light-sleep estimate** (a causal variant of the V2 sleep stager, see below);
  - a **sustained heart-rate rise** (the older rule, which indicates the user is already awake).
- AlarmKit schedules the independent maximum-time phone alarm. It is recurring, with one system alarm per selected weekday.
- When either rule fires, the strap vibrates straight away and NOOP schedules a one-shot AlarmKit alert, replacing that weekday's maximum-time fallback only after the one-shot is accepted. Dismissing the early alert schedules the next week's occurrence; the normal weekly recurrence resumes after that alarm is dismissed.
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

## Strap vibration

The mapped WHOOP protocol has **no vibration intensity control**. `RUN_HAPTICS_PATTERN` (79) carries a pattern id and a loop count; on a 5.0/MG `send` remaps it to the maverick buzz (0x13) whose body is the fixed effect pair 47/152 and a loop count clamped to 1...8. `STOP_HAPTICS` is not on the 5.0/MG allowlist, so a started pattern cannot be cancelled.

The strongest effect available is therefore a longer, denser train. A wake-up burst is three `runHapticsPattern [2, 8, 0, 0, 0]` commands, five seconds apart, written with response. How strong that feels, and how long one pulse lasts, can only be judged on a strap.

## Insistent strap alarm (optional, off by default)

The Smart Wake card has an "Insistent strap alarm" switch. With it off, an early wake sends one burst. With it on:

- an early wake, or the maximum time when no early wake happened, starts a burst;
- if the user does not double-tap the strap, a new burst starts 5 minutes after the previous one ended;
- a double tap stops the repetition at once, and also stops NOOP's AlarmKit alarm if it is ringing (`AlarmManager.stop(id:)`);
- after 6 repetitions (7 bursts, about 35 minutes) it stops by itself.

Stopping the iPhone alarm from the iPhone does not stop the strap. There is no pattern choice. `InsistentWakeAlarm` is the pure schedule; `SmartWakeStrapAlarm` sends the commands, ticks from the heart-rate callback and a one-second timer, and consumes the double tap only while a run is in progress or a single burst is awaiting its confirmation (otherwise the tap reaches the user's own double-tap action).

## WHOOP firmware alarm after an early wake

After a confirmed early wake (a double tap, or the repeating vibration running out) the strap's firmware alarm would still vibrate at the maximum time. `SmartWakeFirmwareSkip` remembers the maximum time that was replaced, and `AppModel.applySmartAlarm()` searches for the next firmware occurrence after it instead of after "now" (one changed argument). `armStrapAlarm` and `disableStrapAlarm` are not modified. The skip lasts at most 24 hours and applies only while Smart Wake is on; with Smart Wake off, or nothing recorded, the firmware alarm behaves exactly as before.

`applySmartAlarm()` also schedules a backup local notification at the maximum time. That notification is not covered by the skip.

## Detection and safety

- Rise rule baseline: median of valid pre-window samples. Trigger: at least 3 consecutive elevated samples, at least 6 BPM above baseline, spanning at least 120 seconds.
- Sample validity: 30–220 BPM; duplicates and out-of-order samples are ignored.
- Maximum sample age: 300 seconds; maximum gap between elevated samples: 180 seconds.
- Missing/poor data never causes an early wake.
- The maximum-time alarm is scheduled independently by AlarmKit, not by an in-process timer.
- An early AlarmKit alarm is scheduled before the current weekday's fallback is cancelled. If scheduling the early alert fails, the maximum-time fallback remains.
- BLE: the only commands added are `runHapticsPattern` writes, the same command and payload shape as the existing buzz, which are reversible and non-destructive. No new opcode, no firmware or alarm write, no second CoreBluetooth manager.

## iOS lifecycle and limitations

CoreBluetooth state restoration and the `bluetooth-central` background mode can deliver BLE events while the app is backgrounded, but iOS does not promise continuous execution. The detectors and the vibration schedule can only act on samples delivered to the process.

- **App suspended but connected:** each heart-rate notification wakes the process briefly, so detection and the repeating vibration continue; a timer alone would not.
- **Strap out of range or disconnected:** no heart rate, so no early wake and no vibration from the app. The AlarmKit maximum-time alarm and the firmware alarm remain.
- **App force-quit:** iOS does not relaunch it for BLE events. No early wake, no vibration, no double-tap handling from NOOP. The AlarmKit maximum-time alarm still rings.
- A double tap while the app has no process is handled by the strap firmware only (it ends the firmware alarm).

AlarmKit is available only on iOS 26+. On earlier iOS versions, the Smart Wake control is not compiled when the SDK lacks AlarmKit, and enabling it is rejected when the runtime OS is earlier than iOS 26. The one-shot fallback immediately after an early wake uses an absolute date for the following week; the normal recurring schedule then returns to AlarmKit's timezone-relative weekly schedule.

Apple documents that AlarmKit alerts break through Silent mode and Focus when authorized. However, developers have reported delayed or missed overnight AlarmKit alerts on iOS 26 and early iOS 27 builds. This is not proof that the issue remains in iOS 27.2, but it means the system alarm must not be treated as infallible until tested on the actual device and OS version. Keep the iPhone Clock alarm as a backup during validation.

The AlarmKit fallback and early-alert lifecycle still require physical-device verification, including authorization denied/granted, phone locked, Focus/Silent mode, background suspension, reconnect, early dismissal, and weekly recurrence. Whether `AlarmManager.stop(id:)` on a ringing one-shot also runs its stop intent is not documented and must be checked on the device; the alarm observer restores the fallback either way.

## Verification

Unit tests cover the pure engine, the live controller, the light-sleep rule's gating (reference, window, holes, restarted count), its scoring pieces and respiration feature, the vibration schedule (vibrate, wait 5 minutes, vibrate again, double tap, repeat limit, duplicate and late ticks), and the firmware skip.

The light-sleep tests use synthetic data: they cover the gating, the 4-epoch requirement, and the transition decision (a pure function, `SmartWakeLightSleepDetector.enteredLight`), not the numeric calibration. A synthetic heart-rate trace cannot be steered into a run that starts after a REM epoch, so the positive case of the transition rule is exercised by the replay, not by a unit test. `Tools/SmartWakeReplay` checks the thresholds offline on recorded nights:

```bash
unzip -p ~/Backup.noopbak noop-backup.sqlite > /tmp/noop.sqlite
python3 Tools/SmartWakeReplay/export.py /tmp/noop.sqlite /tmp/smartwake-nights
swiftc -O StrandiOSShared/SmartWakeEngine.swift StrandiOSShared/SmartWakeLiveController.swift \
    Tools/SmartWakeReplay/main.swift -o /tmp/swr
/tmp/swr /tmp/smartwake-nights --window 30 --offsets 0,-60,-120
```

It runs each night through the real controller as the app feeds it, with a simulated maximum wake time at the session end plus each offset, and reports how early the rule woke, the distribution of wake times inside the window, and the after-the-night V2 stage and the strap's own `sleep_state` at that moment, next to each stage's share of the window. If most wakes land in the first minutes of the window, or in V2 deep sleep, the rule is not tracking sleep depth. The exported files hold personal health data: write them outside the repository and delete them afterwards.

**Not yet verified:** nothing has been tested on a strap or an iPhone. The rule was calibrated offline on nine nights (see above). No GitHub Actions, TestFlight, signing, release, merge, or changes to `main` have been performed.
