import Combine
import Foundation

/// fork-perf: a per-view window onto a few `UserDefaults` keys that publishes only when one of THEM changes.
///
/// `@AppStorage` wakes its view on every `UserDefaults.didChangeNotification`, whatever key was written, so
/// a write of a key nobody reads re-evaluated the app root, the tab shell and Today (measured: 20 foreign
/// writes -> root.app 7-9, root.tabs 9-10, today.classic 18-20 body passes). This object keeps a snapshot of
/// only its own keys and sends `objectWillChange` when that snapshot differs.
///
/// The notification is used instead of KVO on purpose: KVO treats a dot in a key as a key path, and every key
/// here ("noop.onboarded", "units.system", ...) has one, so an observation would never fire.
///
/// Reads go straight to the store, so they are as fresh as `@AppStorage`'s. A write through `set` lands in the
/// store, whose notification publishes once; on the main thread that happens synchronously, inside the same
/// transaction (`withAnimation`, a Toggle), exactly as `@AppStorage` does. From another thread it is hopped to
/// the main queue.
@MainActor
final class DefaultsKeys: ObservableObject {
    private let defaults: UserDefaults
    private let keys: [String]
    private var snapshot: [String: Any] = [:]
    private var token: NSObjectProtocol?

    init(_ keys: [String], defaults: UserDefaults = .standard) {
        self.keys = keys
        self.defaults = defaults
        snapshot = takeSnapshot()
        token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil
        ) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.defaultsDidChange() }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.defaultsDidChange() } }
            }
        }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }

    func bool(_ key: String, default fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }

    func string(_ key: String, default fallback: String) -> String {
        defaults.object(forKey: key) as? String ?? fallback
    }

    /// Writes through the store; the publish comes from its notification.
    func set(_ value: Any, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    private func takeSnapshot() -> [String: Any] {
        var out: [String: Any] = [:]
        for key in keys { if let v = defaults.object(forKey: key) { out[key] = v } }
        return out
    }

    private func defaultsDidChange() {
        let now = takeSnapshot()
        guard now.count != snapshot.count
                || now.contains(where: { key, value in
                    guard let old = snapshot[key] else { return true }
                    return !(old as AnyObject).isEqual(value)
                })
        else { return }
        objectWillChange.send()
        snapshot = now
    }
}
