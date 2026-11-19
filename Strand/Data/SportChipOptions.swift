import Foundation

// MARK: - Sports offered by the quick-edit chip picker, and their localized names
//
// Pure helpers behind `SportChipPicker`. The STORED value of a sport is always its English name (or the
// "Activity" token); only the label shown on a chip follows the app language. No clock, no I/O.

enum SportChipOptions {

    /// The generic, locale-stable token for a detected workout whose sport is not known yet.
    static let activityToken = "Activity"

    /// Chips in order: the generic token, the current choice when it is not already offered, the recent
    /// choices (`RecentSportsPrefs`), then the common sports the Workouts screen offers for re-labelling.
    /// Duplicates are dropped case-insensitively, keeping the first spelling.
    static func options(selected: String, recents: [String], common: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        func add(_ name: String) {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { return }
            out.append(trimmed)
        }
        add(activityToken)
        add(selected)
        recents.forEach(add)
        common.forEach(add)
        return out
    }

    /// Case-insensitive equality of two sport names, as the chips and the recents use it.
    static func same(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(b.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }
}

enum SportDisplayName {

    /// The label to show for a stored sport: the main catalogue first (existing translations such as
    /// "Running"), then the fork table, then the English name itself. "detected" reads as "Activity" and
    /// camelCase names are split into words, exactly as the rest of the app displays them.
    static func localized(_ sport: String) -> String {
        let key = WorkoutSource.displaySport(sport)
        let main = String(localized: String.LocalizationValue(key))
        if main != key { return main }
        return String(localized: String.LocalizationValue(key), table: "Fork")
    }
}
