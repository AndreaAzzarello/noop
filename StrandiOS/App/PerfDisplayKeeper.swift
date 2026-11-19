import Combine
import SwiftUI
import UIKit

/// TEMP (perf investigation, fork-perf): keeps the Display frame monitor running app-wide while the Test
/// Centre "Display" mode is on, so frames are measured on every page and not only while the Test Centre is on
/// screen. Wires the same sinks the Test Centre uses, stops the display link in the background, and emits
/// `perf app.launchToFirstAppear` / `perf app.foregroundToMainIdle`. `model` is held without observation so
/// this never adds invalidations of its own. Remove with the other fork-perf: TEMP lines.
/// Subscriptions that count how often each shared object publishes (see `PerfTrace.notePublish`).
private final class PerfPublishWatch {
    var bag = Set<AnyCancellable>()
}

private struct PerfDisplayKeeper: ViewModifier {
    let model: AppModel
    let health: HealthKitBridge
    let router: NavRouter
    @Environment(\.scenePhase) private var scenePhase
    @State private var launchReported = false
    @State private var watch = PerfPublishWatch()

    func body(content: Content) -> some View {
        content
            .onAppear {
                PerfTrace.keepAlive = true
                startIfNeeded()
                if !launchReported {
                    launchReported = true
                    let ms = (CFAbsoluteTimeGetCurrent() - PerfTrace.launchStart) * 1000
                    PerfTrace.emit("perf app.launchToFirstAppear \(String(format: "%.0f", ms)) ms")
                }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    startIfNeeded()
                    let t0 = CFAbsoluteTimeGetCurrent()
                    // Two main-queue hops: how long the foreground work kept the main thread busy.
                    DispatchQueue.main.async {
                        DispatchQueue.main.async {
                            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                            PerfTrace.emit("perf app.foregroundToMainIdle \(String(format: "%.0f", ms)) ms")
                        }
                    }
                case .background:
                    watch.bag.removeAll()
                    DisplayPerformanceMonitor.shared.stop()
                default:
                    break
                }
            }
    }

    private func startIfNeeded() {
        guard TestCentre.active(.display), !DisplayPerformanceMonitor.shared.isRunning else { return }
        let live = model.live
        DisplayPerformanceMonitor.shared.emit = { [weak live] line in live?.append(log: line, domain: .display) }
        DisplayPerformanceMonitor.shared.dataVolumeProvider = { [weak model] in await model?.repo.dataVolumeSnapshot() }
        DisplayPerformanceMonitor.shared.start()
        PerfTrace.emit("perf display maxFps=\(UIScreen.main.maximumFramesPerSecond) "
            + "plistKey=\((Bundle.main.object(forInfoDictionaryKey: "CADisableMinimumFrameDurationOnPhone") as? Bool) == true ? 1 : 0) "
            + "lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0)")
        watchPublishes()
    }

    /// One sink per shared object; each emission is a `PerfTrace.notePublish`, drained into the next `frameSummary`.
    private func watchPublishes() {
        watch.bag.removeAll()
        func count<O: ObservableObject>(_ name: String, _ object: O) where O.ObjectWillChangePublisher == ObservableObjectPublisher {
            object.objectWillChange.sink { MainActor.assumeIsolated { PerfTrace.notePublish(name) } }.store(in: &watch.bag)
        }
        count("model", model)
        count("repo", model.repo)
        count("live", model.live)
        count("ble", model.ble)
        count("profile", model.profile)
        count("behavior", model.behavior)
        count("engine", model.intelligence)
        count("coach", model.coach)
        count("health", health)
        count("router", router)
        count("update", UpdateStore.shared)
        model.repo.$refreshSeq.sink { seq in
            MainActor.assumeIsolated {
                PerfTrace.notePublish("repoSeq")
                PerfTrace.emit("perf repo.seq \(seq)")
            }
        }.store(in: &watch.bag)
        model.$bpm.dropFirst().sink { _ in MainActor.assumeIsolated { PerfTrace.notePublish("bpm") } }.store(in: &watch.bag)
        health.$syncing.dropFirst().sink { syncing in
            MainActor.assumeIsolated { PerfTrace.emit("perf health.syncing \(syncing ? 1 : 0)") }
        }.store(in: &watch.bag)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { PerfTrace.notePublish("defaults") } }.store(in: &watch.bag)
    }
}

extension View {
    @MainActor func perfDisplayKeeper(model: AppModel, health: HealthKitBridge, router: NavRouter) -> some View {
        PerfTrace.bump("root.app")
        return modifier(PerfDisplayKeeper(model: model, health: health, router: router))
    }
}
