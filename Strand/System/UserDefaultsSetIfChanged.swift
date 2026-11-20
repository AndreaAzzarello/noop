import Foundation

extension UserDefaults {
    /// Writes `value` only when the stored value differs, and says whether it wrote.
    ///
    /// Every `set` on `UserDefaults.standard` posts `didChangeNotification` whether or not the value
    /// changed, and SwiftUI's `@AppStorage` observers are woken by it. A latch or cursor that is
    /// re-asserted on each event (a battery reading, a HealthKit wake, a re-score pass) therefore costs a
    /// notification per event for a value that did not move. An absent key counts as changed, so the first
    /// write still creates it.
    ///
    /// For property-list scalars (`Bool`, `Int`, `Double`, `String`, `Data`, `Date`). Not for values whose
    /// equality is not the persisted meaning, and not for timestamps that are meant to move on every call.
    @discardableResult
    func setIfChanged<T: Equatable>(_ value: T, forKey key: String) -> Bool {
        if let current = object(forKey: key) as? T, current == value { return false }
        set(value, forKey: key)
        return true
    }
}
