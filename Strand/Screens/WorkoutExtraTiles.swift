import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Workout detail: extra stat tiles
//
// Same `StatTile` as DURATION / AVG HR / MAX HR / CALORIES, dropped into that grid by `WorkoutDetailView`.
// Each draws nothing when it has no figure, so the grid never shows a placeholder or a zero for them.

/// The session's Effort. Its body is empty when the row carries no strain.
struct WorkoutEffortTile: View {
    let strain: Double?
    let scale: EffortScale

    var body: some View {
        if let effort = WorkoutWindowMetrics.effort(strain: strain, scale: scale) {
            StatTile(label: "Effort",
                     value: effort.value,
                     caption: effort.scale == .whoop ? String(localized: "of 21") : String(localized: "of 100"),
                     accent: StrandPalette.effortColor)
        }
    }
}

/// Steps for a court or field sport. Its body is empty unless a source counted steps in the window.
struct WorkoutCourtStepsTile: View {
    let steps: WorkoutWindowMetrics.Steps?

    private static let countFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    var body: some View {
        if let steps {
            StatTile(label: "Steps",
                     value: Self.countFormatter.string(from: NSNumber(value: steps.count)) ?? "\(steps.count)",
                     caption: Self.caption(steps.source),
                     accent: StrandPalette.metricCyan)
        }
    }

    private static func caption(_ source: WorkoutWindowMetrics.StepSource) -> String {
        switch source {
        case .imported: return String(localized: "Imported")
        case .strap: return String(localized: "strap")
        case .phone: return String(localized: "phone")
        }
    }
}
