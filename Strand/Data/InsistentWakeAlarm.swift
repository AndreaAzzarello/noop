import Foundation

/// Pure schedule of the strap vibration for a Smart Wake wake-up, driven through the WHOOP FIRMWARE alarm.
///
/// Why not app-commanded haptics: stacking `runHapticsPattern` commands left a WHOOP 5.0 vibrating
/// continuously for over 15 minutes (2026-11-17). On the 5/MG `STOP_HAPTICS` is not allowed and a pattern the
/// app started is not stopped by a double tap. The firmware alarm is the one vibration whose chain is
/// documented end to end (`STRAP_DRIVEN_ALARM_EXECUTED` 57, `HAPTICS_FIRED` 60, dismissed by `DOUBLE_TAP`), so
/// this type only ever asks the caller to ARM that alarm for "a moment from now". It never asks for a haptic.
///
/// States: idle, armed (waiting for event 57), fired (vibrating, waiting for a double tap), stopped.
/// With `maximumRepeats > 0` a fired alarm that gets no double tap within `repeatInterval` is armed again, up
/// to `maximumRepeats` times, then the run ends. A double tap ends the run at once.
///
/// Driven entirely by the `now` it is handed: duplicate or late ticks never produce duplicate actions, and
/// after a suspension it returns one action per call and carries on (missed repeats are dropped, never replayed).
struct InsistentWakeAlarm {
    struct Configuration: Equatable {
        /// How far ahead of "now" the firmware alarm is armed. Covers the write, the strap clock skew and a late tick.
        var firmwareMargin: TimeInterval = 30
        /// After the armed instant, how long to wait for event 57 before treating the alarm as fired anyway.
        var notObservedGrace: TimeInterval = 90
        /// Wait between a fired alarm and the next arm (or the end of the run when there are no repeats).
        var repeatInterval: TimeInterval = 5 * 60
        /// Arms that follow the first one; 0 = the plain Smart Wake wake-up (one vibration).
        var maximumRepeats = 6

        static let insistent = Configuration(maximumRepeats: 6)
        static let single = Configuration(maximumRepeats: 0)
        /// The "test the strap alarm" button: armed a minute ahead, one vibration, no repeats.
        static let test = Configuration(firmwareMargin: 60, maximumRepeats: 0)
    }

    enum StopReason: Equatable {
        case doubleTap
        case repeatLimit
        /// A single vibration that nobody confirmed within `repeatInterval`.
        case expired
    }

    enum Phase: Equatable {
        case idle
        case armed(fireAt: Date, attempt: Int)
        case fired(at: Date, attempt: Int)
        case stopped(StopReason)
    }

    enum Action: Equatable {
        /// Arm the firmware alarm for this instant. `attempt` counts from 0.
        case armFirmware(at: Date, attempt: Int)
        /// The armed instant passed with no event 57; the run goes on as if it had fired.
        case firedNotObserved(attempt: Int)
        case stopped(StopReason)
    }

    let configuration: Configuration
    private(set) var phase = Phase.idle

    init(configuration: Configuration = .insistent) {
        self.configuration = configuration
    }

    /// True while a run is in progress (armed or fired).
    var isActive: Bool {
        switch phase {
        case .armed, .fired: return true
        case .idle, .stopped: return false
        }
    }

    /// Begins the run. Ignored unless idle, so a repeated trigger cannot restart a morning that ran.
    /// `firstFireAt`: an instant the firmware alarm is ALREADY armed for (the maximum time), so nothing is sent.
    mutating func start(at now: Date, firstFireAt: Date? = nil) -> [Action] {
        guard phase == .idle else { return [] }
        if let firstFireAt {
            phase = .armed(fireAt: firstFireAt, attempt: 0)
            return []
        }
        let fireAt = now.addingTimeInterval(configuration.firmwareMargin)
        phase = .armed(fireAt: fireAt, attempt: 0)
        return [.armFirmware(at: fireAt, attempt: 0)]
    }

    /// Event 57 arrived. Returns true while a run is active, so the caller keeps the event to itself.
    mutating func firmwareFired(now: Date) -> Bool {
        switch phase {
        case let .armed(_, attempt):
            phase = .fired(at: now, attempt: attempt)
            return true
        case .fired:
            return true
        case .idle, .stopped:
            return false
        }
    }

    /// Returns the action due at `now`, if any: at most one per call.
    mutating func tick(now: Date) -> [Action] {
        switch phase {
        case let .armed(fireAt, attempt):
            guard now >= fireAt.addingTimeInterval(configuration.notObservedGrace) else { return [] }
            phase = .fired(at: now, attempt: attempt)
            return [.firedNotObserved(attempt: attempt)]
        case let .fired(at, attempt):
            guard now >= at.addingTimeInterval(configuration.repeatInterval) else { return [] }
            if configuration.maximumRepeats == 0 { return [finish(.expired)] }
            if attempt >= configuration.maximumRepeats { return [finish(.repeatLimit)] }
            let fireAt = now.addingTimeInterval(configuration.firmwareMargin)
            phase = .armed(fireAt: fireAt, attempt: attempt + 1)
            return [.armFirmware(at: fireAt, attempt: attempt + 1)]
        case .idle, .stopped:
            return []
        }
    }

    /// A double tap on the strap. `consumed` is true only while a run is in progress; otherwise the tap belongs
    /// to whoever else handles it.
    mutating func doubleTap() -> (consumed: Bool, actions: [Action]) {
        guard isActive else { return (false, []) }
        return (true, [finish(.doubleTap)])
    }

    private mutating func finish(_ reason: StopReason) -> Action {
        phase = .stopped(reason)
        return .stopped(reason)
    }
}
