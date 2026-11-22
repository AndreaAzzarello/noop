# Fork touches on upstream files

Files that exist in `ryanbr/noop` `main` and are edited by this fork, so a merge from upstream knows where
conflicts can appear. Logic lives in fork-only files wherever possible; the edits below are the minimum hooks.

- Totals are `added/removed` lines of `git diff upstream/main --numstat` on the branch (all fork work in that file).
- Perf-session edits are marked in source with `// fork-perf:` (`grep -rn "fork-perf:" Strand StrandiOS Packages`).

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

## Perf session 3: fix that stays

| Fix | Upstream file | Lines touched | Reason |
|---|---|---|---|
| P5.1 | `StrandiOS/Resources/Info.plist` | +2/-0 | `CADisableMinimumFrameDurationOnPhone` carried in the committed plist (same key as `project.yml`), so restoring the plist after a local `xcodegen generate` no longer drops ProMotion |

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

## Perf session 5: fix that stays

Fork-only helper: `Strand/System/DefaultsKeys.swift` (tests: `StrandTests/DefaultsKeysTests.swift`).
A per-view observer of a few `UserDefaults` keys that publishes only when one of them changes (notification plus
snapshot compare; KVO is not usable because every key contains a dot).

| Fix | Upstream file | Lines touched | Reason |
|---|---|---|---|
| C | `StrandiOS/App/StrandiOSApp.swift` | +14/-14 | the six root `@AppStorage`s (appearance, chart style, accent, custom hex, effort scale, unit system) and the three `iOSRootView` gate keys read through `DefaultsKeys`; an `@AppStorage` re-evaluated the app root on every defaults write (probe: 20 foreign writes gave root.app 7-9) |
| C | `StrandiOS/App/RootTabView.swift` | +6/-4 | the four shell keys (Coach, bottom-bar auto-hide, More sections CSV, Liquid Today) read through `DefaultsKeys` (probe: root.tabs 9-10) |

Not changed in this session: the 28 `@AppStorage`s of `TodayView` (18-20 body passes in the pre-C probe). The 19 of
`LiquidTodayView` are handled in session 6 below.

## Session 6: Today cards (Night, workout stack, Effort target, repeated facts)

Fork-only files (no merge conflict possible), each with tests in `StrandTests/` unless noted:
`Strand/Data/StrainTargetBand.swift`, `NightSummary.swift`, `SmartWakeEarlyWakeRecord.swift`, `TodayFeatureStack.swift`,
`TodayDedup.swift`, `Strand/Screens/NightSummaryCard.swift` (preview), `StrainTargetArc.swift` (preview),
`TodayFeatureStackView.swift`, `Strand/System/ScopedAppStorage.swift`. New strings live in `Fork.xcstrings`.
Upstream hooks are marked `// fork` in source (`grep -rn "// fork" Strand`). Counts are `added/removed` by this session.

| Fix | Upstream file | Lines touched | Reason |
|---|---|---|---|
| Texts | `Strand/Screens/DashboardCards.swift` | +2/-2 | "Estimated, updated weekly" and the fitness-age unit "yrs" read from the `Fork` table (the default catalog had no Italian entry for the first and the second was a literal) |
| Effort target | `Strand/Liquid/LiquidTodayView.swift` | +5/-1 | `target:` on the private `HeroScoreCell` and the arc overlay on its gauge; the Effort cell passes `StrainTargetBand.resolve(...)` |
| Effort target | `Strand/Screens/TodayView.swift` | +5/-0 | arc overlay on `effortRing` |
| Stack | `Strand/Liquid/LiquidTodayView.swift` | +6/-6 | the fallback block and the `.hero` arm render `TodayFeatureStackView` (detected workout, today's workout, Night card) instead of `AutoWorkoutCard` + `TodayWorkoutSummaryCard` |
| Stack | `Strand/Screens/TodayView.swift` | +2/-2 | the two `TodayWorkoutSummaryCard` sites render the stack (`includesDetection: false`; the classic keeps its own `AutoWorkoutCard`) |
| Stack | `Strand/Screens/AutoWorkoutCard.swift` | +3/-1 | the card's visibility goes through `TodayFeatureStack.showsDetection`, the same rule the stack order uses |
| Repeats | `Strand/Liquid/LiquidTodayView.swift` | +12/-2 | `shownKeyMetrics`, and `TodayDedup` gates on the Recovery Vitals and Last workouts sections |
| Repeats | `Strand/Screens/TodayView.swift` | +5/-4 | `TodayDedup` gate on Recovery Vitals, today's workouts left out of the 14-day list, Charge/Effort chart labels only when the rings are hidden |
| Perf | `Strand/Liquid/LiquidTodayView.swift` | +20/-19 | the 19 `@AppStorage` become `@ScopedAppStorage` (same declaration and `$` binding; wakes the view only for its own key) |
| Smart Wake | `StrandiOS/System/SmartWakeLiveWiring.swift` (fork-only) | +1/-0 | `SmartWakeEarlyWakeRecord.record` once an early wake has actually started; write-only, never read by scheduling, stop or skip |

Left out on purpose: SpO2 auto-hide on the classic Today (its carried value is resolved by a scan of the day rows,
which would run several times per body), and `SmartWakeFirmwareSkip` (the Night card reads its key through
`NightSkipPeek` so a display never deletes a spent value).

### Hooks that were missing from the earlier tables

Measured against `upstream/main` after session 6, minus what the tables above list: `TodayView.swift` has about
+8/-8 more, `LiquidTodayView.swift` about +17/-10 more (the workout summary card, `.autoWorkoutSuggestionHost()`,
`LiquidFrameBox` and `ForkFormatters` call sites), `RootTabView.swift` about +5/-1 more (`MoreQueryScope`;
`MoreDestination` changed from `private` to internal), and `AutoWorkoutCard.swift` carries the detected-workout review
(+32/-25, in the first table). These are approximate residuals, not a per-hunk audit.

### Pre-existing, to evaluate later (resolved in session 7: a failed delete now skips the save)

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


## Session 7: battery audit (iPhone, Apple Health, Apple Watch)

Fixes that stay (every hook is marked `// fork-perf:`; logic lives in fork-only files):

| Area | File | Lines (+/-) | What changed |
|---|---|---|---|
| Health | `StrandiOS/Health/HealthKitBridge.swift` | +110/-20 | `writeVitals`, `writeSleep`, `writeHeartRate`, `writeWorkouts` filter their candidates through `HealthWriteBackLedger` (only changed keys are deleted and saved), call `HealthWriteBackLedgerHK.delete` instead of `try?`, skip the save when that delete throws, and settle the ledger only after a successful save |
| Health | `Strand/Screens/TestCentreView.swift` | +2/-0 | two cards: the ledger switch (`ForkHealthLedgerCard`) and the TEMP energy report |
| Health | `StrandiOS/App/StrandiOSApp.swift` | +15/-1 | foreground sync goes through `HealthForegroundSyncState` (skip within 15 min, window = days since the last pass, full 30 days every 24 h); TEMP probe attach and flush |
| Watch | `NOOPWatch/WatchScoreStore.swift` | +9/-1 | `apply` returns early for a snapshot equal to the one shown (no persist, no complication reload) |
| Watch | `NOOPWatch/WatchLiveHR.swift` | +5/-2 | `bpm` and `denied` are assigned only when they change |

The Smart Wake night-window notice added earlier in this session was removed again: the detector reads the standard 0x2A37 heart rate, which the "Night only" gate does not stop (it only gates the realtime stream toggle).

Fork-only files: `Strand/System/HealthWriteBackLedger.swift`, `HealthForegroundSyncPolicy.swift`,
`StrandiOS/Health/HealthWriteBackLedgerHK.swift`,
`Strand/Screens/ForkHealthLedgerCard.swift`, their tests, and strings in `Fork.xcstrings`.

TEMP instrumentation (remove after the 24 h measurement; find it with `grep -rn "fork-perf: TEMP"`):
`Strand/System/ForkEnergyCounters.swift`, `ForkMetricKitDays.swift`, `ForkLedgerTelemetry.swift`,
`StrandiOS/System/ForkMetricKitProbe.swift`, `Strand/Screens/ForkEnergyReportCard.swift`,
`NOOPWatch/WatchEnergyCounters.swift`, `StrandTests/ForkEnergyCountersTests.swift`, plus one-line hooks in
`AppModel`, `WatchSessionBridge`, `CoachBriefScheduler`, `RescoreBackgroundScheduler`, `ScheduledDebugExport`,
`HealthWritebackBackgroundScheduler`, `StaleBatteryBackgroundScheduler`, `WidgetPublish`, `HealthKitBridge`,
`StrandiOSApp`, `TestCentreView` and the Watch files. `fgSyncRun` and `fgSyncSkipped` are TEMP counters too.

Proposed, not done: W3 (workout timer cadence in always-on), B2 (low refresh), B3 (buffer `StrapLogArchive`),
B4 (`logRevision` rate), MetricKit on watchOS (check the SDK first).

## Multiple Smart Wake alarms

The alarm list lives in fork-only files; the upstream files touched are two, both marked `// fork:`:

| File | Lines (+/-) | What changed |
|---|---|---|
| `Strand/App/AppModel.swift` | +2/-1 | `applySmartAlarm` first asks `SmartWakeArmHold.shared.swallows()` (a list change arms the strap once), and the strap alarm is not armed when Smart Wake is on and no alarm is active (`SmartWakeScheduleOwner.allowsStrapAlarm`) |
| `Strand/Screens/SmartAlarmView.swift` | +46/-34 in total | one computed property (`smartWakeListOwnsSchedule`), then plain `if`s: the strap alarm's time and day editors and "Different wake time per day" are replaced or hidden only while the list owns them; with Smart Wake off the screen is unchanged apart from one note; plus `import Combine`, one computed property (`smartWakeListChanges`, `Empty` outside iOS) and one `.onReceive` that re-reads the per-day times once the list's mirror has written them (the screen named Sunday at the base time from stale overrides); session 10: two computed properties (`smartWakeScreenActive`, `smartWakeScreen`, each a complete `#if`) and one plain `if/else` in `body`: with Smart Wake on, `SmartWakeAlarmsScreen` replaces the stacked cards (the else branch keeps them unchanged, only re-indented, +30/-8) |

Fork files touched or added: `Strand/Data/SmartWakeAlarmBook.swift`, `SmartWakeUpstreamMirror.swift`, `SmartWakeCommitDebouncer.swift`, `Strand/Screens/SmartWakeAlarmListView.swift`, `SmartWakeManagedScheduleRow.swift`, `SmartWakeCardView.swift`, `SmartWakeDiagnosticsView.swift`, `NightSummaryCard.swift` (the window of the alarm that rings, reload on list change), `StrandiOS/System/SmartWakeAlarmStore.swift`, `AppModel+SmartWake.swift`, `SmartWakeLiveWiring.swift`, `SmartWakeAlarmScheduler.swift`, `SmartWakeStrapAlarm.swift`, `SmartWakeAlarmTitle.swift`, `StrandiOS/Widgets/ForkWidgetPublisher.swift`, `StrandiOSShared/SmartWakeLiveController.swift`, `ForkWidgetSnapshot.swift`, their tests, and strings in `Fork.xcstrings`.

Not touched: `Strand/BLE/**` (including `armStrapAlarm`), `SmartWakeFirmwareSkip.swift`, `project.yml`, `.github`, `fastlane`, the entitlements, `NOOPWidget.swift`, `WidgetSnapshot.swift`, `Localizable.xcstrings`.

## Session 8: battery follow-up, Effort band, Night card

Edits to upstream files, each marked `// fork:` or `// fork-perf:` in source. Totals are the whole fork's `git diff upstream/main --numstat` for the file.

| File | Total | What this session added |
|---|---|---|
| `StrandiOS/Health/HealthKitBridge.swift` | +181/-31 | locked-store deferral: `deferIfLocked`, the unlock debt and observer, the protected-data gate in `writeBackAfterNewData`, delete outcomes at the four delete sites; TEMP CPU hook around `writeBack` |
| `Strand/App/AppModel.swift` | +20/-4 | `refreshAfterCompletedBackfill`: `hasUnscoredRawData` asked once, passed to the rescore as `nothingNewToScore`, widget publish behind `shouldPublishWidgetAfterOffload`; TEMP offload CPU counter |
| `Strand/Data/IntelligenceEngine.swift` | +12/-1 | `hasUnscoredRawData()` (the post-offload fingerprint comparison, asked without a pass); TEMP rescore CPU hook |
| `Strand/System/RescoreBackgroundScheduler.swift` | +15/-4 | `run(nothingNewToScore:)`: a deferral records no debt when nothing is new and none is already owed |
| `Strand/Data/Repository.swift` | +82/-29 | TEMP CPU hook in `refresh(days:)` |
| `StrandiOS/Widgets/WidgetPublish.swift` | +4/-0 | TEMP CPU hook in `publish(from:)` |
| `Strand/Liquid/LiquidPrimitives.swift` | +9/-3 | `LiquidRender.vesselGeometry(frame:)`, the one place the vessel's radius and line width are computed, so the Effort band cannot drift from the ring |
| `Strand/Liquid/LiquidTodayView.swift` | +75/-39 | the Effort band is drawn from the vessel's own geometry and hidden while Effort has no score |
| `Strand/Screens/TodayView.swift` | +37/-42 | classic ring passes its real radius, line width and progress to the band |
| `NOOPWatch/WatchIntervalView.swift`, `WatchBreatheView.swift`, `WatchWorkoutView.swift` | +11/-3, +37/-16, +66/-5 | timers stop off-screen (Intervals, Breathe); Always-On clock at one redraw a minute |

Fork-only files added: `Strand/System/HealthWriteBackDeferral.swift`, `OffloadWidgetPublishGate.swift`, `Strand/Data/StrainTargetArcLayout.swift`, `StrandiOS/System/AppModel+WidgetGate.swift`, their tests, and `NightCardStyle` in `Strand/Data/NightSummary.swift`.

TEMP (removed with the rest of the audit): the CPU counters and `nightCard*` counters in `ForkEnergyCounters`.

Not touched: `Strand/BLE/**`, `project.yml`, `.github`, `fastlane`, `Localizable.xcstrings`, `NOOPWidget.swift`, `WidgetSnapshot.swift`, the entitlements, `SmartWake*`. No Android change: the iOS-only paths (HealthKit, WidgetKit, BGTask) have no twin, and the Effort-band formula (`optimalStrainRange`) is unchanged.

## Session 9: widget reload budget, CPU attribution

| File | Lines (+/-) this session | What changed |
|---|---|---|
| `StrandiOS/Widgets/WidgetPublish.swift` | +19/-0 | `saveAndReloadIfChanged`: a change confined to the heart rate and the battery reloads at most every 30 minutes (a low-battery crossing at once); the snapshot is saved either way. `// fork:` |
| `Strand/Data/IntelligenceEngine.swift` | +4/-2 | TEMP: a re-score pass that returns at a gate no longer adds to `cpuRescoreMs`; it counts `rescoreGateSkipped` |

Fork files added: `Strand/System/WidgetReloadThrottle.swift`, their tests. TEMP: per-thread CPU counters (`cpuThr*`) in `ForkEnergyCounters`.

Not touched: `Strand/BLE/**`, `WidgetSnapshot.swift`, `NOOPWidget.swift`, `SmartWake*`, `project.yml`, `.github`, `fastlane`.

## Session 10: Night card, Alarms screen

| File | What changed |
|---|---|
| `Strand/Screens/SmartAlarmView.swift` | see the row above: `if smartWakeScreenActive { smartWakeScreen } else { …classic cards… }` |
| `Strand/Data/SmartWakeAlarmBook.swift` | `maxAlarms = 5`, `canAdd`, `Change.limitReached` (only adding is refused) |
| `Strand/Data/SmartWakeEarlyWakeRecord.swift`, `StrandiOS/System/SmartWakeLiveWiring.swift` | the maximum time stored with an early wake; a maximum-time wake-up recorded (write-only, for the Night card) |
| `StrandiOSShared/SmartWakeEngine.swift` | a light run that opens the window counts after >= 2 contiguous REM/deep epochs just before it |
| `Strand/Screens/SmartWakeAlarmListView.swift` | editor, conflict type and two helpers made internal; the row moved to `SmartWakeAlarmRow` |

Fork files added: `SmartWakeAlarmsScreen.swift`, `SmartWakeAlarmRow.swift`, `NightSummaryFigureTests.swift`.
