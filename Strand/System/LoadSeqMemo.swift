import Foundation

/// fork-perf: remembers the `refreshSeq` a page last finished loading for. `.task(id: refreshSeq)` restarts
/// every time its view appears, so without this a tab or pop-back repeats a load whose inputs have not changed.
/// A reference type kept in `@State` (no extra body pass when it is written); a new view instance starts empty.
final class LoadSeqMemo {
    private var seq: Int?
    func isCurrent(_ value: Int) -> Bool { seq == value }
    func finish(_ value: Int) { seq = value }
}
