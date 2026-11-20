import SwiftUI

/// fork-perf: a drop-in for `@AppStorage` (Bool, Int and String values) that wakes its view only when ITS key changes.
///
/// `@AppStorage` re-evaluates its view on every `UserDefaults.didChangeNotification`, whatever key was written; on a
/// screen with many of them (the Liquid Today has 19) an unrelated write re-ran the whole body. This keeps the same
/// declaration shape, `@ScopedAppStorage("key") var x = default`, and the same `$x` binding, but the invalidation
/// comes from a one-key `DefaultsKeys`, which publishes only when that key's value actually differs.
///
/// Reads go straight to the store (as fresh as `@AppStorage`'s); a write lands in the store, whose notification
/// publishes synchronously on the main thread, inside the same transaction, exactly as `@AppStorage` does.
@MainActor
@propertyWrapper
struct ScopedAppStorage<Value>: DynamicProperty {
    @StateObject private var keys: DefaultsKeys
    private let key: String
    private let fallback: Value
    private let defaults: UserDefaults

    init(wrappedValue: Value, _ key: String, store: UserDefaults = .standard) {
        self.key = key
        self.fallback = wrappedValue
        self.defaults = store
        _keys = StateObject(wrappedValue: DefaultsKeys([key], defaults: store))
    }

    var wrappedValue: Value {
        get { defaults.object(forKey: key) as? Value ?? fallback }
        nonmutating set { defaults.set(newValue, forKey: key) }
    }

    var projectedValue: Binding<Value> {
        Binding(get: { self.wrappedValue }, set: { self.wrappedValue = $0 })
    }
}
