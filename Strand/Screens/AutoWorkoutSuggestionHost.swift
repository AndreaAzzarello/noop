import SwiftUI
import StrandAnalytics

// MARK: - Auto-detected workout suggestion: state + always-present scan trigger
//
// `AutoWorkoutCard` used to run its scan from a `.task` attached to a `Group` whose only content was
// conditional on the scan's own result. A `Group` is not a real container: modifiers are distributed to
// its children, and with no candidate there is no child, so the task never started and the candidate
// stayed nil forever. The scan is therefore anchored to the Today container (always present) through
// `autoWorkoutSuggestionHost()`, and the card only reads the shared model.

/// Holds the current suggestion for the Today screen. One instance per Today container.
@MainActor
final class AutoWorkoutSuggestionModel: ObservableObject {
    /// The current suggestion. nil → nothing to show.
    @Published var candidate: DetectedWorkout?
    /// Hide immediately on Save/dismiss without waiting for the next reload (avoids a flash of the old card).
    @Published var handledThisSession = false

    /// Re-scan. A fresh scan resets the session guard so a NEW window can surface after one is handled.
    func reload(repo: Repository) async {
        let next = await repo.autoDetectCandidate()
        if next != candidate { handledThisSession = false }
        candidate = next
    }
}

/// Reload key: a new sync (seq) or a toggle flip re-runs detection.
struct AutoWorkoutLoadKey: Equatable {
    let seq: Int
    let enabled: Bool
}

/// Runs the scan on appear, after every sync (`refreshSeq`) and when the toggle flips, and shares the
/// model with `AutoWorkoutCard` through the environment.
struct AutoWorkoutSuggestionHost: ViewModifier {
    @EnvironmentObject private var repo: Repository
    @AppStorage(PuffinExperiment.autoDetectWorkoutsKey) private var autoDetectEnabled = false
    @StateObject private var model = AutoWorkoutSuggestionModel()

    func body(content: Content) -> some View {
        content
            .environmentObject(model)
            .task(id: AutoWorkoutLoadKey(seq: repo.refreshSeq, enabled: autoDetectEnabled)) {
                await model.reload(repo: repo)
            }
    }
}

extension View {
    /// Attach once to the always-present Today container that hosts `AutoWorkoutCard`.
    func autoWorkoutSuggestionHost() -> some View {
        modifier(AutoWorkoutSuggestionHost())
    }
}
