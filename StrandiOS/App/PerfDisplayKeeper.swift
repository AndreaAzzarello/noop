import SwiftUI
import UIKit

/// TEMP (perf investigation, fork-perf): keeps the Display frame monitor running app-wide while the Test
/// Centre "Display" mode is on, so frames are measured on every page and not only while the Test Centre is on
/// screen. Wires the same sinks the Test Centre uses, stops the display link in the background, and emits
/// `perf app.launchToFirstAppear` / `perf app.foregroundToMainIdle`. `model` is held without observation so
/// this never adds invalidations of its own. Remove with the other fork-perf: TEMP lines.
private struct PerfDisplayKeeper: ViewModifier {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var launchReported = false

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
    }
}

extension View {
    func perfDisplayKeeper(model: AppModel) -> some View { modifier(PerfDisplayKeeper(model: model)) }
}
