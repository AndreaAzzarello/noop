import Foundation

/// Single-slot memo for a value derived from view state. The workout review / quick-edit sheets scan up to
/// 50k HR samples per derived value; reading them from several places in `body` repeated that scan on every
/// redraw. A reference type held in `@State`: filling the slot never invalidates the view.
final class SheetMemo<Value> {
    private var slot: (key: String, value: Value)?

    func value(for key: String, make: () -> Value) -> Value {
        if let slot, slot.key == key { return slot.value }
        let made = make()
        slot = (key, made)
        return made
    }
}
