# Fork touches on upstream files

Files that exist in `ryanbr/noop` `main` and are edited by this fork, so a merge from upstream knows where
conflicts can appear. Line counts are `added/removed` against `upstream/main`. Logic lives in fork-only files
wherever possible; the edits below are the minimum hooks.

Perf-session edits are marked in the source with `// fork-perf:` (`grep -rn "fork-perf:" Strand StrandiOS`).
Lines marked `fork-perf: TEMP` are temporary measurement hooks and **must be removed** at the end of the perf
work together with `Strand/System/PerfTrace.swift` and `StrandiOS/App/PerfDisplayKeeper.swift` (fork-only).

## Smart Wake, workouts, widgets, watch (earlier work)

| File | Lines | Reason |
|---|---|---|
| `Strand/App/AppModel.swift` | +6/-1 | Smart Wake hooks (firmware alarm ownership, fallback alarms) |
| `Strand/BLE/BLEManager.swift` | +1/-0 | feed readable HR samples to Smart Wake |
| `Strand/BLE/LiveState.swift` | +2/-0 | expose readable HR samples to Smart Wake |
| `Strand/Data/BehaviorStore.swift` | +9/-0 | independent Smart Wake preferences |
| `Strand/Data/Repository.swift` | +18/-7 | auto-detect scan off the main actor, gating, tracing |
| `Strand/Liquid/LiquidPrimitives.swift` | +1/-1 | live HR thread at 30 fps |
| `Strand/Screens/AutoWorkoutCard.swift` | +32/-25 | detected-workout review, scan anchoring |
| `Strand/Screens/JournalReminderCard.swift` | +13/-8 | fix card never loading |
| `Strand/Screens/SmartAlarmView.swift` | +14/-20 | Smart Wake card moved to its own view, cached formatters |
| `Strand/Screens/WorkoutDetailView.swift` | +12/-4 | court-sport Effort/steps, zone-coloured HR curve |
| `StrandiOS/Resources/Info.plist` | +2/-0 | AlarmKit usage description (restore after `xcodegen generate`) |
| `StrandiOS/Widgets/WidgetPublish.swift` | +1/-0 | fork NOOP+ publish hook |
| `StrandiOSWidgets/NOOPWidgetBundle.swift` | +2/-0 | register NOOP+ widget and alarm Live Activity |
| `project.yml` | +5/-0 | AlarmKit plist key, Smart Wake test targets |
| `NOOPWatch/*` (5 files) | +142/-28 | watch: tickers only while a session runs, HR sampling, session recovery |

## Shared between earlier work and the perf session

| File | Lines | Reason |
|---|---|---|
| `Strand/Liquid/LiquidTodayView.swift` | +22/-15 | `LiquidFrameBox`, formatter cache, workout card placement; **perf: `.perfPage` (TEMP, 1 line)** |
| `Strand/Screens/TodayView.swift` | +14/-12 | workout summary / auto-workout cards, formatter cache; **perf: `.perfPage` + load span (TEMP, 2 lines)** |
| `Strand/Screens/SettingsView.swift` | +2/-0 | auto-detect thresholds; **perf: `.perfPage` (TEMP, 1 line)** |
| `Strand/Screens/WorkoutsView.swift` | +3/-1 | detected-workout review; **perf: `.perfPage` + load span (TEMP, 2 lines)** |
| `StrandiOS/App/RootTabView.swift` | +6/-2 | More search scope; **perf: launch refresh span (TEMP, 1 line changed)** |
| `StrandiOS/App/StrandiOSApp.swift` | +6/-0 | AlarmKit observer, Smart Wake wiring; **perf: launch stamp, keeper modifier, Health sync span (TEMP, 3 lines)** |

## Perf session (this work)

| File | Lines | Reason | Status |
|---|---|---|---|
| `Strand/System/DisplayPerformanceMonitor.swift` | +3/-3 | append layout/background/page context to `frameSummary` and `memoryHighWater` lines | TEMP, remove |
| `Strand/Screens/TestCentreView.swift` | +4/-3 | keep the Display monitor alive off-screen; time `capturedUnits`; `.perfPage` | TEMP, remove |
| `Strand/Screens/CoachView.swift` | +1/-0 | `.perfPage("coach")` | TEMP, remove |
| `Strand/Screens/LiveView.swift` | +1/-0 | `.perfPage("live")` | TEMP, remove |
| `Strand/Screens/SleepView.swift` | +3/-1 | `.perfPage`, load span, `buildModel` timing | TEMP, remove |
| `Strand/Screens/TrendsView.swift` | +2/-0 | `.perfPage`, series-load span | TEMP, remove |
| `Strand/Screens/SmartAlarmView.swift` | +1/-0 | `.perfPage("alarms")` | TEMP, remove |

## Perf fixes (kept)

| File | Lines | Reason |
|---|---|---|
| `Strand/Liquid/LiquidSky.swift` | +9/-0 | A1: while the Today scroll view moves, the tab is off screen or the app is inactive, draw one frame at the last clock value instead of the 20 fps loop (logic in fork-only `Strand/Liquid/LiquidSkyGate.swift`) |
| `Strand/Liquid/LiquidTodayView.swift` | +1/-0 | A1: `.liquidSkyScrollGate()` on the Today `ScrollView` |
| `Strand/Liquid/LiquidTodayView.swift` | +8/-2 | A2: skip an unchanged `load()` when returning to Today within 20 s (`loadKey`, `loadMemo`; memo in fork-only `LiquidLoadMemo.swift`) |
| `Strand/Data/Repository.swift` | +12/-8 | A3: with the Test Centre Workouts mode on, `detectTrace` and the shadow comparisons run in a detached task instead of on the main actor (log output and order unchanged); `AutoWorkoutSuggestionHost.swift` (fork-only) skips a rescan for an unchanged key under 20 s |
| `Strand/Screens/SleepView.swift` | +10/-1 | A6: re-entering the tab with an unchanged `refreshSeq` skips the full session/motion reload and model rebuild (the snap to the newest night is kept); the `onChange(of: key)` reuses the model this body pass already built |
| `Strand/Screens/SettingsView.swift` | +4/-1 | A5: the diagnostics sheet captures `IOSDiagnostics` once (`DiagnosticsSnapshot` in `Strand/System/`, fork-only) instead of re-reading the provisioning profile on every redraw |
| `Strand/Screens/TodayView.swift` | +10/-27 | A4: the periodic "Swipe"/"Tap" hint state and loop moved into fork-only `DayNavHintLabel` (its writes re-ran the whole classic body twice per 11.5 s); `StressModel` computed off the main actor as Liquid does |
| `Strand/Screens/TrendsView.swift` | +11/-4 | A11: year heat-strip days parsed once per (refreshSeq, window, day count) and the sleep-performance series load skipped on tab re-entry (memo in fork-only `TrendsPerfMemo.swift`) |
| `Strand/Screens/WorkoutsView.swift` | +5/-0 | A9: the list reload is skipped on re-entry when `refreshSeq` is unchanged (`LoadSeqMemo`, fork-only, `Strand/System/`) |

Later perf commits (real fixes, kept) are appended here as they land.
