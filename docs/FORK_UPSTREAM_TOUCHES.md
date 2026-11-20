# Fork touches on upstream files

Files that exist in `ryanbr/noop` `main` and are edited by this fork, so a merge from upstream knows where
conflicts can appear. Logic lives in fork-only files wherever possible; the edits below are the minimum hooks.

- Totals are `added/removed` lines of `git diff upstream/main --numstat` on the branch (all fork work in that file).
- Perf-session edits are marked in source with `// fork-perf:` (`grep -rn "fork-perf:" Strand StrandiOS Packages`).
- Lines marked **`fork-perf: TEMP`** are measurement hooks and **must be removed** at the end of the perf work,
  together with the fork-only `Strand/System/PerfTrace.swift` and `StrandiOS/App/PerfDisplayKeeper.swift`
  (`grep -rn "fork-perf: TEMP" Strand StrandiOS`).

## Earlier fork work (Smart Wake, workouts, NOOP+ widget, watch)

| File | Total | Reason |
|---|---|---|
| `Strand/App/AppModel.swift` | +6/-1 | Smart Wake hooks (firmware alarm ownership, fallback alarms) |
| `Strand/BLE/BLEManager.swift` | +1/-0 | feed readable HR samples to Smart Wake |
| `Strand/BLE/LiveState.swift` | +2/-0 | expose readable HR samples to Smart Wake |
| `Strand/Data/BehaviorStore.swift` | +9/-0 | independent Smart Wake preferences |
| `Strand/Liquid/LiquidPrimitives.swift` | +1/-1 | live HR thread at 30 fps |
| `Strand/Screens/AutoWorkoutCard.swift` | +32/-25 | detected-workout review, scan anchoring |
| `Strand/Screens/JournalReminderCard.swift` | +13/-8 | fix card never loading |
| `Strand/Screens/SmartAlarmView.swift` | +17/-32 | Smart Wake card moved to its own view, cached formatters (perf: see A7) |
| `StrandiOS/Resources/Info.plist` | +2/-0 | AlarmKit usage description (restore with `git checkout` after `xcodegen generate`) |
| `StrandiOS/Widgets/WidgetPublish.swift` | +1/-0 | fork NOOP+ publish hook |
| `StrandiOSWidgets/NOOPWidgetBundle.swift` | +2/-0 | register NOOP+ widget and alarm Live Activity |
| `project.yml` | +5/-0 | AlarmKit plist key, Smart Wake test targets |
| `NOOPWatch/WatchBreatheView.swift`, `WatchGlanceView.swift`, `WatchIntervalView.swift`, `WatchLiveHR.swift`, `WatchWorkoutView.swift` | +142/-28 | watch: tickers only while a session runs, HR sampling, session recovery |

## Perf session: fixes that stay

Fork-only helper files (no merge conflict possible): `Strand/Liquid/LiquidSkyGate.swift`,
`Strand/Liquid/LiquidLoadMemo.swift`, `Strand/Screens/DayNavHintLabel.swift`,
`Strand/Screens/TrendsPerfMemo.swift`, `Strand/System/LoadSeqMemo.swift`,
`Strand/System/DiagnosticsSnapshot.swift`, `Strand/System/RepositoryHandle.swift`.

| Fix | Upstream file | Lines touched by the fix | Reason |
|---|---|---|---|
| A1 | `Strand/Liquid/LiquidSky.swift` | +9/-0 | draw one frame at the last clock value instead of the 20 fps loop while the Today scroll view moves, the tab is off screen or the app is inactive |
| A1 | `Strand/Liquid/LiquidTodayView.swift` | +1/-0 | `.liquidSkyScrollGate()` on the Today `ScrollView` |
| A2 | `Strand/Liquid/LiquidTodayView.swift` | +8/-2 | skip an unchanged `load()` when returning to Today within 20 s (`loadKey`, `loadMemo`) |
| A3 | `Strand/Data/Repository.swift` | +12/-8 | test-mode `detectTrace` and shadow comparisons run in a detached task, same log order |
| A4 | `Strand/Screens/TodayView.swift` | +10/-27 | "Swipe"/"Tap" hint state moved into `DayNavHintLabel`; `StressModel` computed off the main actor |
| A5 | `Strand/Screens/SettingsView.swift` | +2/-1 | diagnostics sheet captured once (`DiagnosticsSnapshot`) |
| A6 | `Strand/Screens/SleepView.swift` | +10/-1 | skip the full reload on tab re-entry; `onChange(of: key)` reuses the model already built in the same body pass |
| A7 | `Strand/Screens/LiveView.swift`, `SmartAlarmView.swift`, `SettingsView.swift` (+ fork-only `Strand/Data/ForkFormatters.swift`) | +1/-3 each | cached relative-time, components and number formatters |
| A9 | `Strand/Screens/WorkoutsView.swift` | +5/-0 | list reload skipped on re-entry when `refreshSeq` is unchanged (`LoadSeqMemo`) |
| A10 | `Strand/Screens/WorkoutDetailView.swift` | +36/-30 | independent store reads in `load()` start together (`async let`) |
| A11 | `Strand/Screens/TrendsView.swift` | +11/-4 | year heat-strip parsed once per (refreshSeq, window, day count); sleep-performance series load skipped on re-entry |
| B1 | `Strand/Screens/TestCentreView.swift` | +14/-4 | captured-day count refreshed by a task (on toggle/appear, then every 5 s), not read from disk inside `body` |
| B5 | `Strand/Data/Repository.swift` | +21/-4 | registry list cached per store instance, dropped on any registry write |
| B5 | `Packages/WhoopStore/Sources/WhoopStore/DeviceRegistryStore.swift` | +39/-11 (+ test) | every registry write goes through `writeTracked`, which bumps `DeviceRegistryChangeCounter` |
| B9 | `StrandiOS/App/RootTabView.swift` | +4/-1 | shell holds the repository via the non-observing `repositoryHandle`; `StrandiOSApp.swift` +1 injects it |
| B10 | `StrandiOS/App/StrandiOSApp.swift` | +10/-0 | on foreground with data loaded, publish widget and watch immediately, then again after the Health sync |

## Perf session 2: fixes that stay

Fork-only helper files: `Strand/System/TabSeqGate.swift`, `Strand/System/RefreshCoalescer.swift`
(tests: `StrandTests/RefreshCoalescerTests.swift`). Counts are `added/removed` added by this session.

| Fix | Upstream file | Lines touched | Reason |
|---|---|---|---|
| P1.1 | `StrandiOS/App/StrandiOSApp.swift` | +1/-1 | root `\.locale` uses the memoised `AppClock.activeLocale`; a new `Locale` per App body pass invalidated every view reading it, hidden tabs included |
| P1.2 | `StrandiOS/Health/HealthKitBridge.swift` | +1/-1 | `lastError = nil` only when set (an equal assignment still publishes to the app root) |
| P1.3 | `StrandiOS/App/RootTabView.swift` | +6/-5 | `tab(...)` takes `index:` and injects `\.forkTabSelected` |
| P1.3 | `Strand/Screens/TodayView.swift`, `SleepView.swift`, `TrendsView.swift` | +3/-1 each | load `.task(id:)` keyed on `TabSeqGate.value(...)`, so a hidden tab keeps its key and does not reload on every refresh |
| P1.3, P2.2 | `Strand/Screens/AutoWorkoutSuggestionHost.swift` (fork-only) | +10/-3 | same gate; no scan before `repo.loaded` |
| P2.3 | `Strand/Screens/TodayView.swift` | +3/-0 | `loadAll` skips the history-wide pass until the first refresh has published |
| P2.4 | `Strand/Data/Repository.swift` | +21/-9 | `habitualMidsleepSec` memoised per (days, refreshSeq, offset, day); `dedupBlocks` and the pick run detached |
| P2.1 | `Strand/Data/Repository.swift` | +11/-1 | `refresh(days:)` goes through `RefreshCoalescer`; the old body is `refreshOnce(days:)` |

## Perf session 2: TEMP hooks (remove at the end)

| File | Lines | What |
|---|---|---|
| `Strand/System/RefreshCoalescer.swift` (fork-only) | +1 | `perf repo.refresh.coalesced n= days=` line |
| `StrandiOS/Health/HealthKitBridge.swift` | +9 | `healthSync.aggregates/.workouts/.upsert/.caffeineAndHourlySteps/.writeBack` spans |
| `StrandiOS/App/StrandiOSApp.swift` | +2 | `healthSync.sync` and `healthSync.refresh` spans |

## Perf session 3: fix that stays

| Fix | Upstream file | Lines touched | Reason |
|---|---|---|---|
| P5.1 | `StrandiOS/Resources/Info.plist` | +2/-0 | `CADisableMinimumFrameDurationOnPhone` carried in the committed plist (same key as `project.yml`), so restoring the plist after a local `xcodegen generate` no longer drops ProMotion |

## Perf session 3: TEMP hooks (remove at the end)

Fork-only (delete the whole file or the added blocks): `Strand/System/PerfTrace.swift` (publish counters, `perfCount`,
link interval) and `StrandiOS/App/PerfDisplayKeeper.swift` (publish sinks, `perf display` line).

| File | Lines | What |
|---|---|---|
| `Strand/System/DisplayPerformanceMonitor.swift` | +1 | `PerfTrace.noteLinkInterval(...)` in `onFrame` (feeds `refresh=` on `frameSummary`) |
| `StrandiOS/App/RootTabView.swift` | +1 | `.perfCount("root.tabs")` |
| `StrandiOS/App/StrandiOSApp.swift` | +0/-0 | `.perfDisplayKeeper(model:health:router:)` (same TEMP line, new arguments) |
| `StrandiOS/Health/HealthKitBridge.swift` | +16 | `healthSync.wb.migrate/vitals/sleep/hr/workouts` spans, `healthSync.wb.counts` lines, `healthSync.writeBackAfterNewData` span |

## Perf session 4: fixes that stay

Fork-only helpers: `Strand/System/HealthWriteBackGate.swift` (tests: `StrandTests/HealthWriteBackGateTests.swift`),
`Strand/System/UserDefaultsSetIfChanged.swift` (tests: `StrandTests/UserDefaultsSetIfChangedTests.swift`).

| Fix | Upstream file | Lines touched | Reason |
|---|---|---|---|
| A | `StrandiOS/Health/HealthKitBridge.swift` | +15/-7 | `writeBackPending` becomes `writeBackGate`: a `sync` that finds the bridge busy no longer queues a write-back (the observer wakes it answers are mostly our own write-back samples); fresh strap data reruns only when it arrived after the pass read its rows |
| B1 | `StrandiOS/Health/HealthKitBridge.swift` | +5/-2 | `persistAnchor` and the HR write cursor use `setIfChanged` (cursor still advances per chunk so an interrupted first run keeps its progress) |
| B1 | `Strand/System/BatteryNotifier.swift` | +5/-5 | the five alert latches use `setIfChanged` |
| B1 | `Strand/System/RescoreBackgroundScheduler.swift` | +4/-4 | `owed` and `owedAfterCompletedPass` use `setIfChanged` (token and timestamps stay `set`) |
| B1 | `Strand/Data/IntelligenceEngine.swift` | +1/-1 | analyze watermark uses `setIfChanged` |

## Perf session 4: TEMP hooks (remove at the end)

| File | Lines | What |
|---|---|---|
| `Strand/System/PerfTrace.swift` (fork-only) | +61 | B0: per-key diff of `UserDefaults.standard` per notification (`defaultsKeys=`, `defaultsSame=`, `defaultsDiffMs=` on `frameSummary`), `runDefaultsProbe()` (writes `perf.probe` 20 times) |
| `StrandiOS/App/PerfDisplayKeeper.swift` (fork-only) | +7/-1 | feeds `noteDefaultsNotification()` from the `didChangeNotification` sink, `resetDefaultsSnapshot()` on start |
| `Strand/System/DisplayPerformanceMonitor.swift` | +4 | D: `preferredFrameRateRange` 60-120 Hz on the monitor's `CADisplayLink` (keeps the panel at up to 120 Hz while the monitor runs; read `refresh=` against 8.3 ms) |
| `Strand/Screens/TestCentreView.swift` | +3 | "Defaults probe" button in `DisplayReadoutPanel` (`Text(verbatim:)`, no localized string) |
| `StrandiOS/Health/HealthKitBridge.swift` | +2 | `perf healthSync.pending source=sync dropped=1` (busy `sync`) and `source=newData rerun=0\|1` (`finishHealthPass`) |

The `perf probe defaults start/end` and `perf healthSync.pending` lines are emitted through `PerfTrace.emit`, so they
disappear with the hooks above; the `perf.probe` defaults key is read by nothing and can be left to expire.

### Pre-existing, to evaluate later (not changed)

`HealthKitBridge.writeHeartRate` deletes our previous samples in the window with `try? await store.deleteObjects(...)`
before saving the fresh batch. If the delete fails, the error is swallowed and the save still runs, so the window
holds the old and the new samples: duplicates in Apple Health. Candidate fix: skip the save (and keep the cursor) when
the delete throws. Needs a decision on whether a repeatedly failing delete should surface in `lastError`.

Proposed, not done: P4.2 (per-workout route/HR/steps fetch in a task group), B2 (bpm in a leaf-observed model),
B8/C5 (single `LoadResult` for Today), `CADisableMinimumFrameDurationOnPhone` (`project.yml`, owner adds it).

Not done (needs your decision, see the final report): A8 (Smart Wake diagnostics reload also runs
`SmartWakeTestAlarm.sweep()`, which is Smart Wake logic), the `.id(refreshToken)` rebuild in the Test Centre,
the list row identity in Workouts (`startTs|sport` is not guaranteed unique), `ProfileStore` duplication in
the workout detail (a missing environment object would crash).

## Perf session: TEMP hooks (remove at the end)

| Upstream file | Lines | What |
|---|---|---|
| `Strand/System/DisplayPerformanceMonitor.swift` | +3/-3 | append page/layout/background context to `frameSummary` and `memoryHighWater` lines |
| `Strand/Screens/TestCentreView.swift` | +3 | keep the Display monitor alive when the Test Centre is left; `.perfPage("testCentre")` |
| `Strand/Screens/TodayView.swift` | +2 | `.perfPage("today.classic")` and a load span |
| `Strand/Liquid/LiquidTodayView.swift` | +1 | `.perfPage("today.liquid")` (the `PerfTrace.measure` around `load()` and the `PerfTrace.emit` skip line are TEMP too) |
| `Strand/Screens/TrendsView.swift` | +2 | `.perfPage("trends")`, series-load span |
| `Strand/Screens/SleepView.swift` | +3 | `.perfPage("sleep")`, load span, `buildModel` timing |
| `Strand/Screens/WorkoutsView.swift` | +2 | `.perfPage("workouts")`, load span |
| `Strand/Screens/WorkoutDetailView.swift` | +2 | `.perfPage("workoutDetail")`, load span |
| `Strand/Screens/CoachView.swift`, `LiveView.swift`, `SettingsView.swift`, `SmartAlarmView.swift` | +1 each | `.perfPage(...)` |
| `StrandiOS/App/RootTabView.swift` | +1/-1 | span around the launch `repo.refresh()` |
| `StrandiOS/App/StrandiOSApp.swift` | +3 | launch stamp, `.perfDisplayKeeper(model:)`, Health sync span |
| `Strand/Screens/AutoWorkoutSuggestionHost.swift` (fork-only) | — | `PerfTrace.measure` / skip line inside the model |
