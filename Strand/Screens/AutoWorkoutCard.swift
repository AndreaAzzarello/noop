import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Auto-detected workout prompt (Today screen)
//
// A single, dismissible Today card that appears ONLY when the opt-in "Auto-detect workouts"
// toggle is on and `Repository.autoDetectCandidate()` finds a recent sustained-elevated HR
// window that isn't already saved and wasn't previously dismissed.
//
// It only ever SUGGESTS: tapping Save creates a manual-style "Workout" for the window (via the
// same manual-save path the edit sheet uses); the X dismisses it durably so it never re-prompts.
// Nothing is created automatically. Design-Reset compliant — a flat NoopCard using NoopMetrics /
// StrandPalette / StrandFont, no gold, matching the other Today cards.

struct AutoWorkoutCard: View {

    @EnvironmentObject var repo: Repository

    /// Whether the toggle is on. Read here too so the card disappears the instant it's switched off.
    @AppStorage(PuffinExperiment.autoDetectWorkoutsKey) private var autoDetectEnabled = false

    /// The suggestion, loaded by `autoWorkoutSuggestionHost()` on the Today container (the scan must not
    /// hang off this view: with no candidate it renders nothing, so a task here would never start).
    @EnvironmentObject private var suggestion: AutoWorkoutSuggestionModel
    /// Guards the Save button while the write is in flight.
    @State private var saving = false
    /// The window being reviewed in `DetectedWorkoutReviewSheet`, nil when the sheet is closed.
    @State private var reviewing: DetectedWorkout?
    /// Set by the sheet when it saved or discarded; the card hides only once the sheet is gone, so it is
    /// never removed from under its own presentation.
    /// nil = sheet closed without a decision, true = saved, false = discarded.
    @State private var reviewOutcome: Bool?

    var body: some View {
        Group {
            if TodayFeatureStack.showsDetection(enabled: autoDetectEnabled, handledThisSession: suggestion.handledThisSession,
                                                hasCandidate: suggestion.candidate != nil), // fork: shared with the stack order
               let w = suggestion.candidate {
                card(for: w)
            }
        }
        .sheet(isPresented: Binding(get: { reviewing != nil },
                                    set: { if !$0 { reviewing = nil } }),
               onDismiss: {
            if let saved = reviewOutcome {
                reviewOutcome = nil
                suggestion.handledThisSession = true
                suggestion.candidate = nil
                // Refresh only after the sheet is gone: a sync bump re-scans and would empty this card
                // (and the sheet attached to it) while the sheet was still on screen.
                if saved { Task { await repo.refresh() } }
            }
        }) {
            if let w = reviewing {
                DetectedWorkoutReviewSheet(workout: w) { saved in reviewOutcome = saved }
            }
        }
    }

    @ViewBuilder
    private func card(for w: DetectedWorkout) -> some View {
        NoopCard(tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack(spacing: NoopMetrics.space2) {
                    Image(systemName: "figure.run")
                        .font(.system(size: 18))
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text("Looks like a workout")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Button {
                        dismiss(w)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .padding(NoopMetrics.space1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss this workout suggestion")
                }

                Text(promptText(w))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: NoopMetrics.space3) {
                    Button {
                        save(w)
                    } label: {
                        Label("Save it", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(StrandPalette.accent)
                    .disabled(saving)

                    Button("Edit") { reviewing = w }
                        .buttonStyle(.bordered)
                        .disabled(saving)

                    Button("Not a workout") { dismiss(w) }
                        .buttonStyle(.bordered)
                        .disabled(saving)
                    Spacer()
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// "Looks like a workout [yesterday ]around 14:05–14:32 (avg HR 148, 27 min). Save it?"
    /// Three whole-phrase variants (today / yesterday / dated, #719) so translators see complete
    /// sentences rather than a stitched day-label fragment.
    private func promptText(_ w: DetectedWorkout) -> String {
        let startDate = Date(timeIntervalSince1970: TimeInterval(w.startSec))
        let start = Self.timeFmt.string(from: startDate)
        let end = Self.timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(w.endSec)))
        let cal = Calendar.current
        if cal.isDateInToday(startDate) {
            return String(localized: "Looks like a workout around \(start)-\(end) (avg HR \(w.avgBpm), \(w.durationMin) min). Save it?")
        }
        if cal.isDateInYesterday(startDate) {
            return String(localized: "Looks like a workout yesterday around \(start)-\(end) (avg HR \(w.avgBpm), \(w.durationMin) min). Save it?")
        }
        return String(localized: "Looks like a workout on \(Self.dateFmt.string(from: startDate)) around \(start)-\(end) (avg HR \(w.avgBpm), \(w.durationMin) min). Save it?")
    }

    private func save(_ w: DetectedWorkout) {
        saving = true
        suggestion.handledThisSession = true
        Task {
            _ = await repo.saveDetectedWorkout(w)
            await repo.refresh()   // surfaces the new workout + drops it from re-suggestion
            saving = false
        }
    }

    private func dismiss(_ w: DetectedWorkout) {
        repo.dismissDetectedSuggestion(w)
        suggestion.handledThisSession = true
        suggestion.candidate = nil
    }

    /// HH:mm in the user's locale/timezone.
    /// #1821: routed through AppClock so the Clock format setting reaches this label. Was a `static
    /// let`, which would have frozen the reader's choice at first use until the app relaunched.
    private static var timeFmt: DateFormatter { AppClock.hourMinuteFormatter() }

    /// Localized medium date ("Jun 23, 2026") for a bout older than yesterday.
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppLanguage.activeLocale
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}
