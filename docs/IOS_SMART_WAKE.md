# iOS Smart Wake — live heart-rate integration

## Status

The isolated live-sample path is implemented on `feature/ios-smart-wake`. It observes readable
WHOOP 5.0 standard Heart Rate Measurement notifications (GATT 0x2A37) and feeds the pure
`SmartWakeEngine` through an in-memory, non-published callback. GitHub Issues are disabled in
this repository; this document records the safety rationale instead. No new WHOOP command or
BLE write has been introduced.

This is detector integration only: it does not wake the user, schedule an alarm, send haptics,
or replace the existing alarm.

## Configurable schedule

`SmartWakeSchedule` holds the selected maximum wake hour/minute, the early-wake window duration,
and the baseline lookback duration. The current 07:20 maximum and 30-minute window are defaults
only. The detector derives the window start from the configured maximum time; changing the
schedule does not change the detection principle. The schedule is injected into the controller,
so a future settings UI/persisted preference can supply different values without changing the
BLE pipeline or the engine logic.

## Data path

`BLEManager.parseStandardHR` decodes the standard HR measurement and checks
`LiveHeartRateReadability`. Only readable WHOOP 5.0 samples are forwarded with their receive
timestamp through `LiveState.onSmartWakeHeartRateSample`. The iOS root retains a
`SmartWakeLiveController`, which feeds the pure `SmartWakeEngine`.

The callback is not `@Published`, so it does not cause SwiftUI updates for every HR sample.
Do not use `AppModel.bpm` as detector input: it is a smoothed display value and is only
republished when its median changes. Do not use `LiveState.heartRate` as the sole event source:
it is also updated only when the integer value changes.

## Detection and fail-safe behavior

- Collect a bounded, process-local baseline before the configured detection window.
- Construct the engine at the beginning of the configured window.
- Require the engine's configured minimum baseline (20 samples); if unavailable, early wake is
  disabled for that cycle.
- Ignore invalid, duplicate, and out-of-order samples. The engine also enforces freshness and
  maximum sample gaps.
- A sustained rise is a heuristic, not a sleep-stage classification.
- The maximum wake deadline remains independent of HR detection and must be backed by a
  separately scheduled system alarm before real-world use.

## Explicit non-goals and limitations

- No new BLE command, GATT write, haptic/vibration command, firmware alarm change, or second
  CoreBluetooth manager.
- No changes to `SmartAlarmView` or the existing alarm behavior.
- No background-execution guarantee is claimed. iOS may suspend or terminate the app; HR
  samples are event-driven and may be unavailable while the process is suspended.
- The maximum-time detector decision is not yet connected to a real wake mechanism. A separate,
  independently scheduled system fallback and real-device verification are required before
  this can be used as an actual alarm.
- No cloud, telemetry, or persistent storage of the temporary HR buffer.
- No edits to `main`, GitHub Actions, signing, TestFlight, or release configuration.

## Verification

Unit tests cover the pure engine and live controller, including sustained rise, insufficient
baseline, out-of-order samples, late launch, and changing the maximum wake time/window. They
have been added but have **not yet been executed**. The BLE path still requires testing with a
real WHOOP 5.0 and iPhone; compile success alone is insufficient.
