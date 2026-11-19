import SwiftUI

/// fork-perf: a way to hold the `Repository` in a view WITHOUT subscribing to it. `@EnvironmentObject`
/// re-runs the view's body on every `@Published` change of the object (10 of them), which is wrong for a view
/// that only calls methods on it, such as the tab shell that rebuilds all five tab roots. The app root
/// injects the same instance next to `.environmentObject(model.repo)`.
private struct RepositoryHandleKey: EnvironmentKey {
    static let defaultValue: Repository? = nil
}

extension EnvironmentValues {
    var repositoryHandle: Repository? {
        get { self[RepositoryHandleKey.self] }
        set { self[RepositoryHandleKey.self] = newValue }
    }
}
