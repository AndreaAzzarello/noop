import Foundation

// fork: the list of Smart Wake alarms. Pure Foundation (no AlarmKit, no UI), so it compiles for macOS and iOS and is
// covered by `StrandTests`. Rule of the model: at most ONE enabled alarm per weekday. That makes the list compile to a
// weekday -> alarm map, which is exactly the shape the AlarmKit scheduler already works in (two slots per weekday).

/// One Smart Wake alarm, the way the Clock app shows one: a time, the weekdays it repeats on, a label.
struct SmartWakeAlarm: Codable, Equatable, Identifiable {
    static let windowChoices = [15, 20, 30, 45, 60]
    static let defaultWindowMinutes = 30
    static let maximumLabelLength = 32

    var id: UUID
    /// Optional name ("Work"). Trimmed, at most `maximumLabelLength` characters; empty means none.
    var label: String
    var isEnabled: Bool
    /// Latest wake time, minutes since local midnight.
    var wakeMinutes: Int
    /// Per-weekday times that replace `wakeMinutes`. Only weekdays in `weekdays` count. Kept so the migration from the
    /// single schedule (which had per-day overrides) loses nothing.
    var dayOverrides: [Int: Int]
    /// Calendar weekdays (1 = Sunday ... 7 = Saturday). Never empty in a valid alarm: upstream's "empty = every day"
    /// is spelled out as 1...7 here.
    var weekdays: Set<Int>
    /// Early-wake window before the latest time: 15, 20, 30, 45 or 60.
    var windowMinutes: Int
    /// "Insistent strap alarm" for this alarm: the strap vibrates again every 5 minutes until a double tap.
    var insistent: Bool
    /// Tie-break when stored data disagrees with itself (two enabled alarms on one day): the older one wins.
    var createdAt: Date

    init(id: UUID = UUID(), label: String = "", isEnabled: Bool = true, wakeMinutes: Int = 7 * 60,
         dayOverrides: [Int: Int] = [:], weekdays: Set<Int> = Set(1...7),
         windowMinutes: Int = SmartWakeAlarm.defaultWindowMinutes, insistent: Bool = false,
         createdAt: Date = Date()) {
        self.id = id
        self.label = label
        self.isEnabled = isEnabled
        self.wakeMinutes = wakeMinutes
        self.dayOverrides = dayOverrides
        self.weekdays = weekdays
        self.windowMinutes = windowMinutes
        self.insistent = insistent
        self.createdAt = createdAt
        self = sanitized()
    }

    /// The wake time on `weekday`, or nil when the alarm does not repeat on it.
    func minutes(onWeekday weekday: Int) -> Int? {
        guard weekdays.contains(weekday) else { return nil }
        return dayOverrides[weekday] ?? wakeMinutes
    }

    /// The same alarm with every field forced into its valid range.
    func sanitized() -> SmartWakeAlarm {
        var copy = self
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.label = String(trimmed.prefix(Self.maximumLabelLength))
        copy.wakeMinutes = min(max(wakeMinutes, 0), 24 * 60 - 1)
        copy.weekdays = Set(weekdays.filter { (1...7).contains($0) })
        copy.dayOverrides = dayOverrides.filter {
            copy.weekdays.contains($0.key) && (0..<24 * 60).contains($0.value)
        }
        if !Self.windowChoices.contains(windowMinutes) { copy.windowMinutes = Self.defaultWindowMinutes }
        // Whole seconds, so encode -> decode returns the identical value and the stored bytes never drift.
        copy.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
        return copy
    }

    // Overrides are written with string keys and weekdays sorted, so the same alarm always encodes to the same bytes
    // (a plain `[Int: Int]` encodes as a flat array in dictionary order, which would defeat `setIfChanged`).
    private enum CodingKeys: String, CodingKey {
        case id, label, isEnabled, wakeMinutes, dayOverrides, weekdays, windowMinutes, insistent, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawOverrides = try c.decodeIfPresent([String: Int].self, forKey: .dayOverrides) ?? [:]
        var overrides: [Int: Int] = [:]
        for (key, value) in rawOverrides { if let day = Int(key) { overrides[day] = value } }
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            label: try c.decodeIfPresent(String.self, forKey: .label) ?? "",
            isEnabled: try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
            wakeMinutes: try c.decode(Int.self, forKey: .wakeMinutes),
            dayOverrides: overrides,
            weekdays: Set(try c.decode([Int].self, forKey: .weekdays)),
            windowMinutes: try c.decodeIfPresent(Int.self, forKey: .windowMinutes) ?? Self.defaultWindowMinutes,
            insistent: try c.decodeIfPresent(Bool.self, forKey: .insistent) ?? false,
            createdAt: try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(wakeMinutes, forKey: .wakeMinutes)
        try c.encode(Dictionary(uniqueKeysWithValues: dayOverrides.map { (String($0.key), $0.value) }), forKey: .dayOverrides)
        try c.encode(weekdays.sorted(), forKey: .weekdays)
        try c.encode(windowMinutes, forKey: .windowMinutes)
        try c.encode(insistent, forKey: .insistent)
        try c.encode(createdAt, forKey: .createdAt)
    }
}

/// What one weekday resolves to once the list is compiled.
struct SmartWakeEffectiveDay: Equatable {
    let alarmID: UUID
    let label: String
    let minutes: Int
    let windowMinutes: Int
    let insistent: Bool
}

/// The ordered list of alarms, versioned for storage.
struct SmartWakeAlarmBook: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var alarms: [SmartWakeAlarm]

    init(version: Int = SmartWakeAlarmBook.currentVersion, alarms: [SmartWakeAlarm] = []) {
        self.version = version
        self.alarms = alarms
    }

    var enabledAlarms: [SmartWakeAlarm] { alarms.filter(\.isEnabled) }

    /// Oldest first, so a conflict in stored data always resolves the same way.
    private var enabledByAge: [SmartWakeAlarm] {
        enabledAlarms.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    /// weekday -> the alarm that rings on it. Only enabled alarms count. If stored data puts two enabled alarms on
    /// one weekday (the UI never does), the older one wins and `doubleBookedDays` reports the day.
    func effectiveDays() -> [Int: SmartWakeEffectiveDay] {
        var days: [Int: SmartWakeEffectiveDay] = [:]
        for alarm in enabledByAge {
            for weekday in alarm.weekdays.sorted() where days[weekday] == nil {
                days[weekday] = SmartWakeEffectiveDay(
                    alarmID: alarm.id, label: alarm.label, minutes: alarm.minutes(onWeekday: weekday) ?? alarm.wakeMinutes,
                    windowMinutes: alarm.windowMinutes, insistent: alarm.insistent)
            }
        }
        return days
    }

    /// Weekdays claimed by more than one enabled alarm. Empty unless stored data is inconsistent.
    func doubleBookedDays() -> Set<Int> {
        var seen = Set<Int>()
        var twice = Set<Int>()
        for alarm in enabledAlarms {
            for weekday in alarm.weekdays { if !seen.insert(weekday).inserted { twice.insert(weekday) } }
        }
        return twice
    }

    /// True when at least one alarm is enabled and has a weekday.
    var hasActiveAlarm: Bool { enabledAlarms.contains { !$0.weekdays.isEmpty } }

    // MARK: Changes (all pure: they return the new book)

    enum Change: Equatable {
        /// The change is valid; this is the resulting book.
        case applied(SmartWakeAlarmBook)
        /// Enabling the alarm would put two alarms on the same weekday. Nothing was changed.
        case conflicts([SmartWakeAlarmOverlap.Conflict])
        /// The alarm has no weekday. Nothing was changed.
        case needsWeekday
    }

    /// Inserts or replaces `alarm` (matched by id). Refuses, changing nothing, when the alarm is enabled and shares a
    /// weekday with another enabled alarm. The caller shows the conflicts and may call `forcing`.
    func saving(_ alarm: SmartWakeAlarm) -> Change {
        let clean = alarm.sanitized()
        guard !clean.weekdays.isEmpty else { return .needsWeekday }
        if clean.isEnabled {
            let conflicts = SmartWakeAlarmOverlap.conflicts(activating: clean, in: alarms)
            if !conflicts.isEmpty { return .conflicts(conflicts) }
        }
        return .applied(upserting(clean))
    }

    /// Like `saving`, but first switches off every alarm that overlaps. Only ever called after the user chose to.
    func forcing(_ alarm: SmartWakeAlarm) -> SmartWakeAlarmBook {
        let clean = alarm.sanitized()
        guard clean.isEnabled else { return upserting(clean) }
        let losing = Set(SmartWakeAlarmOverlap.conflicts(activating: clean, in: alarms).map(\.alarmID))
        var next = self
        for index in next.alarms.indices where losing.contains(next.alarms[index].id) { next.alarms[index].isEnabled = false }
        return next.upserting(clean)
    }

    func deleting(id: UUID) -> SmartWakeAlarmBook {
        var next = self
        next.alarms.removeAll { $0.id == id }
        return next
    }

    private func upserting(_ alarm: SmartWakeAlarm) -> SmartWakeAlarmBook {
        var next = self
        if let index = next.alarms.firstIndex(where: { $0.id == alarm.id }) {
            next.alarms[index] = alarm
        } else {
            next.alarms.append(alarm)
        }
        return next
    }
}

/// The "one alarm per weekday" rule.
enum SmartWakeAlarmOverlap {
    struct Conflict: Equatable {
        let alarmID: UUID
        let label: String
        /// The weekdays both alarms want.
        let days: Set<Int>
    }

    /// The other ENABLED alarms that share a weekday with `alarm`, oldest first. Disabled alarms and `alarm` itself are
    /// never conflicts. Pure.
    static func conflicts(activating alarm: SmartWakeAlarm, in alarms: [SmartWakeAlarm]) -> [Conflict] {
        alarms
            .filter { $0.id != alarm.id && $0.isEnabled }
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
            .compactMap { other in
                let shared = other.weekdays.intersection(alarm.weekdays)
                return shared.isEmpty ? nil : Conflict(alarmID: other.id, label: other.label, days: shared)
            }
    }
}

/// First launch with the list: the current single schedule becomes the first alarm.
enum SmartWakeAlarmMigration {
    /// The upstream values the first alarm was made from, kept so the app can tell later whether mirroring the list
    /// back changed them.
    struct UpstreamSnapshot: Codable, Equatable {
        var minutes: Int
        var weekdays: [Int]
        var overrides: [String: Int]

        init(minutes: Int, weekdays: Set<Int>, overrides: [Int: Int]) {
            self.minutes = minutes
            self.weekdays = weekdays.filter { (1...7).contains($0) }.sorted()
            self.overrides = Dictionary(uniqueKeysWithValues: overrides.map { (String($0.key), $0.value) })
        }
    }

    /// One enabled alarm with the same days, per-day times, window and insistence as the current configuration.
    /// An empty weekday set (upstream: every day) becomes 1...7. Overrides of days the alarm does not repeat on are
    /// not part of the alarm (they stay in the upstream store, where the evening reminder reads them).
    static func make(minutes: Int, weekdays: Set<Int>, overrides: [Int: Int], windowMinutes: Int, insistent: Bool,
                     id: UUID = UUID(), now: Date = Date()) -> SmartWakeAlarmBook {
        let valid = Set(weekdays.filter { (1...7).contains($0) })
        let days = (weekdays.isEmpty || valid.isEmpty) ? Set(1...7) : valid
        let alarm = SmartWakeAlarm(id: id, label: "", isEnabled: true, wakeMinutes: minutes, dayOverrides: overrides,
                                   weekdays: days, windowMinutes: windowMinutes, insistent: insistent, createdAt: now)
        return SmartWakeAlarmBook(alarms: [alarm])
    }
}

/// Storage of the book in UserDefaults. A blob that cannot be read is kept under a second key (never silently
/// replaced) and the caller migrates again from the upstream settings.
///
/// Every byte that goes in comes from `encoder()` and every byte that comes out goes through `decoder()`, so the two
/// can never disagree about the date format or the key order (a stored blob must round-trip to the same bytes, or
/// `setIfChanged` would rewrite it on every save).
enum SmartWakeAlarmBookStorage {
    static let key = "smartWake.alarms.v1"
    static let corruptKey = "smartWake.alarms.v1.corrupt"
    static let preMigrationKey = "smartWake.alarms.preMigrationUpstream"

    enum Loaded: Equatable {
        case absent
        case book(SmartWakeAlarmBook)
        /// Unreadable or from a newer version. The raw bytes were preserved under `corruptKey`.
        case unreadable
    }

    /// The one encoder: sorted keys (deterministic bytes) and dates as seconds since 1970.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    /// The one decoder: the exact inverse of `encoder()`.
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    static func encode(_ book: SmartWakeAlarmBook) -> Data? {
        try? encoder().encode(book)
    }

    static func decode(_ data: Data) -> SmartWakeAlarmBook? {
        guard let book = try? decoder().decode(SmartWakeAlarmBook.self, from: data),
              book.version == SmartWakeAlarmBook.currentVersion else { return nil }
        return SmartWakeAlarmBook(version: book.version, alarms: book.alarms.map { $0.sanitized() })
    }

    static func load(defaults: UserDefaults = .standard) -> Loaded {
        guard let data = defaults.data(forKey: key) else { return .absent }
        if let book = decode(data) { return .book(book) }
        defaults.set(data, forKey: corruptKey)
        defaults.removeObject(forKey: key)
        return .unreadable
    }

    /// Writes only when the encoded bytes differ. Returns whether it wrote.
    @discardableResult
    static func save(_ book: SmartWakeAlarmBook, defaults: UserDefaults = .standard) -> Bool {
        guard let data = encode(book) else { return false }
        return defaults.setIfChanged(data, forKey: key)
    }

    static func saveSnapshot(_ snapshot: SmartWakeAlarmMigration.UpstreamSnapshot, defaults: UserDefaults = .standard) {
        // Same rule as the book: sorted keys, so the same snapshot is the same bytes.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(snapshot) { defaults.setIfChanged(data, forKey: preMigrationKey) }
    }

    static func loadSnapshot(defaults: UserDefaults = .standard) -> SmartWakeAlarmMigration.UpstreamSnapshot? {
        defaults.data(forKey: preMigrationKey).flatMap { try? JSONDecoder().decode(SmartWakeAlarmMigration.UpstreamSnapshot.self, from: $0) }
    }
}
