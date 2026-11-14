#if os(iOS)
import Foundation
import OSLog

/// Local, copyable record of what Smart Wake did and why.
///
/// Every line goes to the unified log (`category: SmartWake`) and to a bounded ring buffer in
/// UserDefaults, which the Smart Wake card shows and copies. Lines carry times, counts and alarm
/// state only: no heart-rate values, no identifiers beyond short slot labels.
enum SmartWakeDiagnostics {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "noop",
        category: "SmartWake"
    )
    private static let logKey = "smartWake.diagnostics.log"
    private static let maximumLines = 50

    /// Wired once at launch to mirror each line into NOOP's strap log.
    static var onRecord: ((String) -> Void)?

    static func record(_ message: String, defaults: UserDefaults = .standard) {
        logger.info("\(message, privacy: .public)")
        let line = "\(timestamp()) \(message)"
        var lines = defaults.stringArray(forKey: logKey) ?? []
        lines.append(line)
        if lines.count > maximumLines {
            lines.removeFirst(lines.count - maximumLines)
        }
        defaults.set(lines, forKey: logKey)
        onRecord?("SmartWake: \(message)")
    }

    static func lines(defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: logKey) ?? []
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: logKey)
    }

    /// The text shown in the Diagnostics section and put on the pasteboard.
    static func report(snapshot: String, windowStats: String?, defaults: UserDefaults = .standard) -> String {
        var parts = ["Smart Wake diagnostics", snapshot]
        if let windowStats {
            parts.append("Last HR window: \(windowStats)")
        }
        let recent = lines(defaults: defaults)
        parts.append(recent.isEmpty ? "No events recorded yet." : "Events (oldest first):\n" + recent.joined(separator: "\n"))
        return parts.joined(separator: "\n\n")
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }
}
#endif
