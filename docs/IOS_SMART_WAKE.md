# iOS Smart Wake — live heart-rate integration

## Status

The isolated live-sample path is implemented on `feature/ios-smart-wake`. It observes readable
WHOOP 5.0 standard Heart Rate Measurement notifications (GATT 0x2A37) and feeds the pure
`SmartWakeEngine` through an in-memory, non-published callback. GitHub Issues are disabled in
this repository; this document records the safety rationale instead. No new WHOOP command or
BLE write has been introduced.

This is detector integration only: it does not wake the user, schedule an alarm, send haptics,
or replace the existing alarm.

## Data path

`BLEManager.parseStandardHR` decodes the standard HR measurement and checks
`LiveHeartRateReadability`. Only readable WHOOP 5.0 samples are forwarded with their receive
timestamp through `LiveState.onSmartWakeHeartRateSample`. The iOS root retains a
`SmartWakeLiveController`, which feeds the pure `SmartWakeEngine`.

The callback is not `@Published`, so it does not cause SwiftUI updates for every HR sample.
Do not use `AppModel.bpm` as detector input: it is a smoothed display value and is only
republished when its median changes. Do not use `LiveState.heartRate` as the sole event source:
it is also updated only when the integer value changes.

## Current detector behavior

- Maximum wake time is fixed at 07:20 local time; the detection window is 06:50–07:20.
- Keep a bounded, process-local buffer of readable HR samples from the preceding 60 minutes.
- At the first sample in the window, construct the engine from the pre-window samples.
- Require the engine's configured minimum baseline (20 samples); if unavailable, early wake is
  disabled for that cycle.
- Ignore invalid, duplicate, and out-of-order samples. The engine also enforces freshness and
  maximum sample gaps.
- A sustained rise is a heuristic, not a sleep-stage classification.
- The controller can evaluate the 07:20 hard deadline when explicitly called, but no timer,
  notification, AlarmKit alarm, or fallback wake is wired in this phase.

## Explicit non-goals and limitations

- No new BLE command, GATT write, haptic/vibration command, firmware alarm change, or second
  CoreBluetooth manager.
- No changes to `SmartAlarmView` or the existing alarm behavior.
- No background-execution guarantee is claimed. iOS may suspend or terminate the app; HR
  samples are event-driven and may be unavailable while the process is suspended.
- The 07:20 detector decision is not yet connected to a real wake mechanism. A separate,
  independently scheduled system fallback and real-device verification are required before
  this can be used as an actual alarm.
- No cloud, telemetry, or persistent storage of the temporary HR buffer.
- No edits to `main`, GitHub Actions, signing, TestFlight, or release configuration.

## Verification

Unit tests cover the pure engine and live controller, including sustained rise, insufficient
baseline, out-of-order samples, and late launch. They have been added but have **not yet been
executed**. Build/test results must be reported only after actually running them. The BLE path
still requires testing with a real WHOOP 5.0 and iPhone; compile success alone is insufficient.
