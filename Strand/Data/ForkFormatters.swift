import Foundation

/// Cached formatters for view code that used to build a `DateFormatter` / `NumberFormatter` on every redraw.
/// Date formatters are keyed by template and the app-language locale, because `AppLanguage.activeLocale` can
/// change at runtime and a cached formatter must follow it. Thread-safe.
enum ForkFormatters {

    private static let lock = NSLock()
    private static var dateFormatters: [String: DateFormatter] = [:]
    private static var decimalFormatters: [Int: NumberFormatter] = [:]

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
}
