import Foundation

/// Pure schedule of the strap vibration for a Smart Wake wake-up.
///
/// The WHOOP 5/MG vibration has no intensity control in the mapped protocol and a started pattern cannot be
/// stopped (`STOP_HAPTICS` is not on the 5/MG allowlist), so the strongest effect available is a longer, denser
/// train: a burst is `commandsPerBurst` haptic commands `commandSpacing` apart. With `repeats` on, a new burst
/// starts `repeatInterval` after the previous one ended, until the user double-taps the strap or
/// `maximumRepeats` repeats have run.
///
/// The type only decides WHEN a command is due; the caller sends it. It is driven entirely by the `now` it is
/// handed, so duplicate or late ticks never produce duplicate commands, and after a suspension it sends one
/// command and carries on (missed bursts are dropped, never replayed).
struct InsistentWakeAlarm {
    struct Configuration: Equatable {
        var commandsPerBurst = 3
        var commandSpacing: TimeInterval = 5
        /// Wait between the last command of a burst and the first of the next.
        var repeatInterval: TimeInterval = 5 * 60
        /// Bursts that follow the first one; 6 repeats keep the strap going for about half an hour.
        var maximumRepeats = 6
        /// False: one burst only (the plain Smart Wake wake-up).
        var repeats: Bool

        static let insistent = Configuration(repeats: true)
        static let single = Configuration(repeats: false)
    }

    enum StopReason: Equatable {
        case doubleTap
        case repeatLimit
        case singleBurstDone
    }

    enum Phase: Equatable {
        case idle
        case active
        case stopped(StopReason)
    }

    enum Action: Equatable {
        /// Send one haptic command. `burst` counts from 0, `index` is the command inside the burst.
        case sendBuzz(burst: Int, index: Int)
        case stopped(StopReason)
    }

    let configuration: Configuration
    private(set) var phase = Phase.idle
    private var burst = 0
    private var commandsSent = 0
    private var nextCommandAt: Date?

    init(configuration: Configuration = .insistent) {
        self.configuration = configuration
    }

    var isActive: Bool { phase == .active }

    /// Begins the first burst. Ignored unless idle, so a repeated trigger cannot restart a morning that ran.
    mutating func start(at now: Date) -> [Action] {
        guard phase == .idle else { return [] }
        phase = .active
        burst = 0
        commandsSent = 0
        nextCommandAt = now
        return tick(now: now)
    }

    /// Returns the command due at `now`, if any: at most one per call.
    mutating func tick(now: Date) -> [Action] {
        guard phase == .active, let due = nextCommandAt, now >= due else { return [] }
        let send = Action.sendBuzz(burst: burst, index: commandsSent)
        commandsSent += 1

        if commandsSent < configuration.commandsPerBurst {
            nextCommandAt = now.addingTimeInterval(configuration.commandSpacing)
            return [send]
        }

        // The burst is complete.
        guard configuration.repeats else { return [send, finish(.singleBurstDone)] }
        guard burst < configuration.maximumRepeats else { return [send, finish(.repeatLimit)] }
        burst += 1
        commandsSent = 0
        nextCommandAt = now.addingTimeInterval(configuration.repeatInterval)
        return [send]
    }

    /// A double tap on the strap. `consumed` is true only while a vibration run is in progress; otherwise the tap
    /// belongs to whoever else handles it.
    mutating func doubleTap() -> (consumed: Bool, actions: [Action]) {
        guard phase == .active else { return (false, []) }
        return (true, [finish(.doubleTap)])
    }

    private mutating func finish(_ reason: StopReason) -> Action {
        phase = .stopped(reason)
        nextCommandAt = nil
        return .stopped(reason)
    }
}
