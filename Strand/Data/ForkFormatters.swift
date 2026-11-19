import Foundation

/// Cached formatters for view code that used to build a `DateFormatter` / `NumberFormatter` on every redraw.
/// Date formatters are keyed by template and the app-language locale, because `AppLanguage.activeLocale` can
/// change at runtime and a cached formatter must follow it. Thread-safe.
enum ForkFormatters {

    private static let lock = NSLock()
    private static var dateFormatters: [String: DateFormatter] = [:]
    private static var decimalFormatters: [Int: NumberFormatter] = [:]
    private static var componentsFormatters: [String: DateComponentsFormatter] = [:]
    private static let relativeShortFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    /// A formatter for `template` (`setLocalizedDateFormatFromTemplate`) in the active app-language locale.
    static func dateFormatter(template: String) -> DateFormatter {
        let locale = AppLanguage.activeLocale
        let key = "\(locale.identifier)|\(template)"
        lock.lock(); defer { lock.unlock() }
        if let cached = dateFormatters[key] { return cached }
        let f = DateFormatter()
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate(template)
        dateFormatters[key] = f
        return f
    }

    /// A thousands-grouped decimal formatter with at most `maxFractionDigits` fraction digits
    /// (`nil` keeps `NumberFormatter`'s own default).
    static func decimalFormatter(maxFractionDigits: Int? = nil) -> NumberFormatter {
        let key = maxFractionDigits ?? -1
        lock.lock(); defer { lock.unlock() }
        if let cached = decimalFormatters[key] { return cached }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = .autoupdatingCurrent
        if let maxFractionDigits { f.maximumFractionDigits = maxFractionDigits }
        decimalFormatters[key] = f
        return f
    }

    /// The short relative-time formatter ("5 min. ago"), in the system locale like a freshly built one.
    static func relativeShort() -> RelativeDateTimeFormatter {
        lock.lock(); defer { lock.unlock() }
        return relativeShortFormatter
    }

    /// A full-style `DateComponentsFormatter` for day/hour/minute spans in the active app-language locale
    /// (zero units dropped, at most three units), the setup the Alarms countdown uses.
    static func dayHourMinuteSpan() -> DateComponentsFormatter {
        let locale = AppLanguage.activeLocale
        lock.lock(); defer { lock.unlock() }
        if let cached = componentsFormatters[locale.identifier] { return cached }
        let f = DateComponentsFormatter()
        var cal = Calendar.current
        cal.locale = locale
        f.calendar = cal
        f.unitsStyle = .full
        f.allowedUnits = [.day, .hour, .minute]
        f.zeroFormattingBehavior = .dropAll
        f.maximumUnitCount = 3
        componentsFormatters[locale.identifier] = f
        return f
    }
}
