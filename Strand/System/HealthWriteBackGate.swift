import Foundation

/// Decides whether a Health pass owes ONE more write-back when it releases the bridge.
///
/// The bridge is single-flight. Two kinds of request can arrive while a pass owns it:
///
/// - **Fresh strap data** (`writeBackAfterNewData`, fired when an offload lands). It is a real reason to
///   write again, but only if the rows it banked are not already inside the pass that is running: a
///   write-back reads its source rows once, at its start, so data banked before that point is covered and
///   data banked after it is not.
/// - **A read-side sync** (`sync`, e.g. an observer wake) that finds the bridge busy. It asks for no write
///   at all, so it never owes one. It used to set the same pending flag, which turned every HealthKit
///   observer wake into a full second write-back; the wakes are largely caused by the write-back's own
///   samples, so each pass woke the next one (~10 s of extra work per pass, repeating).
///
/// Pure value type, no HealthKit, so the table of cases runs in `StrandTests`.
struct HealthWriteBackGate: Equatable {

    enum Decision: Equatable {
        /// Nothing was requested during the pass.
        case none
        /// Data arrived, but the pass read its rows afterwards (or will), so it already includes them.
        case covered
        /// Data arrived after the pass had read its rows: one more write-back is owed.
        case rerun
    }

    /// True once the current pass has begun reading the rows it writes.
    private(set) var readsBegan = false
    /// Fresh data announced before `readsBegan` (covered, provided the pass reaches its write-back).
    private var arrivedBeforeReads = false
    /// Fresh data announced after `readsBegan` (not covered).
    private var arrivedAfterReads = false

    /// The pass reached its write-back and is about to read the rows it writes.
    mutating func readsStarted() { readsBegan = true }

    /// Fresh strap data was announced while a pass owns the bridge.
    mutating func noteNewData() {
        if readsBegan { arrivedAfterReads = true } else { arrivedBeforeReads = true }
    }

    /// The pass is over. Returns what it owes and clears the gate for the next pass.
    ///
    /// Data announced before the reads still needs a rerun when the pass never got to its write-back
    /// (it failed or bailed earlier), because nothing wrote it.
    mutating func finishPass() -> Decision {
        defer { self = HealthWriteBackGate() }
        if arrivedAfterReads { return .rerun }
        if arrivedBeforeReads { return readsBegan ? .covered : .rerun }
        return .none
    }
}
