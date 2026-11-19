import SwiftUI

// fork-perf: a tab that is not on screen should not restart its data load on every `refreshSeq` bump.
// `TabView` keeps visited tabs alive, and each load writes `@State` after every `await`, so one refresh
// used to re-render Today, Sleep and Trends together even while only one of them was visible.

private struct ForkTabSelectedKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether this tab root is the selected tab. Defaults to `true`, so the macOS shell and any screen
    /// outside the iOS tab shell behave exactly as before.
    var forkTabSelected: Bool {
        get { self[ForkTabSelectedKey.self] }
        set { self[ForkTabSelectedKey.self] = newValue }
    }
}

/// Holds the last value a tab saw while it was selected. Reference type on purpose: it is read from `body`
/// and must not publish. Keep it in a `@State` so it survives view re-creation.
final class TabSeqGate {
    private var last: Int?

    /// `current` while the tab is selected (and on the very first call, so the first load always runs);
    /// otherwise the value last seen while selected, so a `.task(id:)` keyed on it does not restart.
    func value(_ current: Int, selected: Bool) -> Int {
        if selected || last == nil { last = current }
        return last ?? current
    }
}
