import Foundation
import CoreGraphics

// fork: the pure rules behind the swipe-to-delete on the Smart Wake alarm rows. No UI types, so the thresholds and the
// tap/drag arbitration are covered by StrandTests without a device. `SmartWakeSwipeToDelete` only feeds this and draws.

enum SmartWakeSwipe {
    /// Width of the revealed Delete button.
    static let buttonWidth: CGFloat = 88
    /// A drag opens the row once it has revealed this fraction of the button.
    static let openFraction: CGFloat = 0.4
    /// A drag whose projected travel past the release point exceeds this (points) counts as a flick.
    static let flickProjection: CGFloat = 80
    /// Longest the row yields beyond the button while dragging (rubber band); never a full swipe.
    static let rubberBandLimit: CGFloat = 16
    /// A tap this soon after drag activity is the end of that drag, not a tap.
    static let tapGuard: TimeInterval = 0.35

    /// The drag is a horizontal swipe (not a scroll) when it travels more across than down.
    static func isHorizontal(_ translation: CGSize) -> Bool {
        abs(translation.width) > abs(translation.height)
    }

    /// How much of the button is revealed while the finger is down. `start` is 0 (closed) or `buttonWidth` (open);
    /// a leftward drag (negative width) reveals. Clamped at 0, with a damped give past the button unless motion is reduced.
    static func liveReveal(start: CGFloat, translation: CGFloat, rubberBand: Bool = true) -> CGFloat {
        let raw = start - translation
        if raw <= 0 { return 0 }
        if raw <= buttonWidth { return raw }
        return buttonWidth + (rubberBand ? min((raw - buttonWidth) * 0.25, rubberBandLimit) : 0)
    }

    /// Whether the row ends open. `projectedDelta` is the predicted end translation minus the release translation
    /// (negative = still travelling left). A flick decides alone; otherwise 40% of the button opens a closed row and
    /// an open row stays open until it has been dragged back by 40%.
    static func settle(reveal: CGFloat, projectedDelta: CGFloat, wasOpen: Bool) -> Bool {
        if projectedDelta <= -flickProjection { return true }
        if projectedDelta >= flickProjection { return false }
        return wasOpen ? reveal > buttonWidth * (1 - openFraction) : reveal >= buttonWidth * openFraction
    }

    enum TapOutcome: Equatable {
        case edit    // open the editor
        case close   // a row is open: this tap only closes it
        case ignore  // the tail of a drag
    }

    /// What a tap on a row body means. Drag activity wins, so releasing a swipe never opens the editor, and a tap
    /// while any row is open closes it instead of opening the editor.
    static func tap(openID: UUID?, lastDragActivity: Date?, now: Date) -> TapOutcome {
        if let last = lastDragActivity, now.timeIntervalSince(last) < tapGuard { return .ignore }
        return openID != nil ? .close : .edit
    }
}
