import Foundation

/// fork-perf: one-time capture for the Settings diagnostics sheet. `IOSDiagnostics.capture()` reads the
/// embedded provisioning profile from disk and parses it; holding the result in a `@StateObject` (whose
/// initial value is built once) keeps it from re-running every time the parent view redraws.
@MainActor
final class DiagnosticsSnapshot: ObservableObject {
    let lines: [String] = IOSDiagnostics.capture().summaryLines()
}
