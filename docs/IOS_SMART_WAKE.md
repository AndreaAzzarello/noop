# iOS Smart Wake — live heart-rate integration

## Status

Implementation plan for the isolated iOS Smart Wake prototype on `feature/ios-smart-wake`.
The repository has GitHub Issues disabled, so this document records the issue-first safety
rationale in the branch instead. No new WHOOP command or BLE write is proposed.

## Goal

Feed fresh WHOOP 5.0 standard Heart Rate Measurement notifications (GATT 0x2A37) into
`SmartWakeEngine` without changing the existing alarm or the established BLE connection.

## Data path

`BLEManager.parseStandardHR` already decodes the standard HR measurement and checks
`LiveHeartRateReadability`. The integration should expose each readable decoded measurement
with its receive timestamp through a narrow in-memory callback on `LiveState`. The iOS-only
adapter consumes that callback and feeds the pure `SmartWakeEngine`.

Do not use `AppModel.bpm` as the detector input: it is a smoothed display value and is only
republished when its median changes. Do not use `LiveState.heartRate` as the sole event source:
it is also updated only when the integer value changes, so equal consecutive measurements
would disappear.

## Baseline and fail-safe behavior

- Keep a bounded, process-local buffer of fresh, readable HR samples before the wake window.
- At the start of the 30-minute window, construct the engine from the pre-window samples.
- Require the engine's configured minimum baseline (20 samples); if unavailable, early wake is
  disabled for that cycle.
- Reject invalid, duplicate, out-of-order, and stale samples.
- A sustained rise is a heuristic, not a sleep-stage classification.
- Missing data, background suspension, process termination, or a lost BLE connection must
  never cause an early wake.
- The maximum wake deadline remains an independent fallback and must not depend on HR delivery.

## Explicit non-goals

- No new BLE command, GATT write, haptic/vibration command, firmware alarm change, or second
  CoreBluetooth manager.
- No changes to `SmartAlarmView` or the existing alarm behavior.
- No background-execution guarantee is claimed. iOS may suspend or terminate the app; actual
  delivery and wake scheduling require separate iOS alarm/fallback work and real-device tests.
- No cloud, telemetry, or persistent storage of the temporary HR buffer.
- No edits to `main`, GitHub Actions, signing, TestFlight, or release configuration.

## Verification

Pure engine and adapter tests should cover sample delivery, equal consecutive readings,
baseline readiness, stale/missing data, and sustained-rise decisions. Build/test results must
be reported only after actually running them. Any BLE-path change still requires testing with a
real WHOOP 5.0 and iPhone; compile success alone is insufficient.
