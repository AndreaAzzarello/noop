import SwiftUI
import StrandDesign
import WhoopStore

/// fork: renders `TodayFeatureStack.items` under the Today rings: the detected-workout card, today's workout
/// summary and the Night card, in that priority order.
///
/// Must sit inside `.autoWorkoutSuggestionHost()` (both Today screens already do), which supplies the suggestion
/// model. The only defaults key it watches is the auto-detect toggle, through `DefaultsKeys`, so an unrelated
/// `UserDefaults` write does not re-evaluate it.
struct TodayFeatureStackView: View {

    let workouts: [WorkoutRow]
    let isViewingToday: Bool
    /// An instant of the selected calendar day (`selectedLogicalDay`); ignored while viewing today.
    let day: Date
    /// False on the classic Today, which keeps its own detected-workout card above the sections.
    let includesDetection: Bool

    @EnvironmentObject private var suggestion: AutoWorkoutSuggestionModel
    @StateObject private var keys = DefaultsKeys([PuffinExperiment.autoDetectWorkoutsKey])

    var body: some View {
        let now = Date()
        let shownDay = isViewingToday ? now : day
        let items = TodayFeatureStack.items(
            showsDetection: TodayFeatureStack.showsDetection(
                enabled: keys.bool(PuffinExperiment.autoDetectWorkoutsKey, default: false),
                handledThisSession: suggestion.handledThisSession,
                hasCandidate: suggestion.candidate != nil),
            includesDetection: includesDetection,
            hasWorkoutOnDay: !TodayWorkoutSummary.workouts(workouts, onDayOf: shownDay, now: now).isEmpty,
            isViewingToday: isViewingToday,
            now: now)
        ForEach(items, id: \.self) { item in
            switch item {
            case .detected: AutoWorkoutCard()
            case .workout: TodayWorkoutSummaryCard(workouts: workouts, isViewingToday: isViewingToday, day: shownDay)
            case .night(let style): NightSummaryCard(style: style)
            }
        }
    }
}
