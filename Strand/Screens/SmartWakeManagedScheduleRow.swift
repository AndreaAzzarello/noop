import SwiftUI
import StrandDesign

// fork: what the Alarms screen shows in place of the strap alarm's time and day editors while the Smart Wake alarm list
// owns them, so the same fact is never editable in two places.

#if os(iOS) && canImport(AlarmKit)
enum SmartWakeScheduleOwnership {
    /// True while Smart Wake is on and the alarm list exists. The list is then the one place times and days are edited.
    @MainActor
    static func listOwns(smartWakeEnabled: Bool) -> Bool {
        smartWakeEnabled && !SmartWakeAlarmStore.shared.book.alarms.isEmpty
    }
}
#endif

/// Shown instead of the time and day editors. `next` is the resolved "next buzz" text the screen already uses.
struct SmartWakeManagedScheduleRow: View {
    let next: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Times and days come from your Smart Wake alarms.", tableName: "Fork")
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let next {
                Text("Next buzz \(next).", tableName: "Fork")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Text("Change them in the Smart Wake card below.", tableName: "Fork")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// With Smart Wake off the editors are back, showing the values the list last mirrored. This line says so, but only when
/// those values differ from the ones the list was made from.
struct SmartWakeMirroredNote: View {
    let minutes: Int
    let weekdays: Set<Int>
    let overrides: [Int: Int]

    var body: some View {
        if SmartWakeAlarmMigration.mirroredValuesDiffer(
            snapshot: SmartWakeAlarmBookStorage.loadSnapshot(), minutes: minutes, weekdays: weekdays, overrides: overrides) {
            Text("Times updated from your Smart Wake alarms.", tableName: "Fork")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
