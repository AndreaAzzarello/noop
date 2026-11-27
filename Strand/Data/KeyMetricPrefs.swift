import Foundation
import SwiftUI

// MARK: - Editable Key-Metrics layout (#251)
//
// The Today screen's "Key Metrics" grid was a fixed list of ten tiles in one order. This lets the user
// choose WHICH tiles show and in WHAT order, with the default being the original order so nothing changes
// for anyone who never opens the editor. Persistence is display-only — no metric is computed or stored
// differently; this just decides which of the already-computed tiles render and in what sequence.
//
// Stored as a single comma-joined string of metric keys in @AppStorage (UserDefaults), the same
// mechanism every other macOS NOOP preference uses. The Android side mirrors this exactly in
// KeyMetricPrefs.kt (SharedPreferences "today.keyMetrics"). Unknown keys are dropped on read and any
// known key missing from the saved list is appended (disabled) so a future tile addition can't be lost.

/// One of the Today screen's Key-Metric tiles. The rawValue is the stable persisted identifier — keep it
/// byte-identical to the Android `KeyMetric` enum so a backup/restore reads the same layout on either OS.
enum KeyMetric: String, CaseIterable, Identifiable {
    case charge
    case effort
    case rest
    case hrv
    case restingHr
    case bloodOxygen
    case respiratory
    case steps
    case weight
    case calories
    /// Added 2026-08-24 (queue 11c follow-up): Skin Temp was already a "Your Cards" (`DashboardCard`)
    /// option, but was never offered as a Key Metrics tile — not a bug, just never added. New case, NOT
    /// added to `defaultOrder` below, so an existing user's saved layout (and a fresh install's default)
    /// is byte-identical to before; only opts in via the layout editor.
    case skinTemp

    var id: String { rawValue }

    /// The tile's display label — matches the `StatTile(label:)` text rendered on the grid.
    var title: String {
        switch self {
        case .charge:      return String(localized: "Charge")
        case .effort:      return String(localized: "Effort")
        case .rest:        return String(localized: "Rest")
        case .hrv:         return "HRV"
        case .restingHr:   return String(localized: "Resting HR")
        case .bloodOxygen: return String(localized: "Blood Oxygen")
        case .respiratory: return String(localized: "Respiratory")
        case .steps:       return String(localized: "Steps")
        case .weight:      return String(localized: "Weight")
        case .calories:    return String(localized: "Calories")
        // Same short label the sibling "Your Cards" tile (`DashboardCard.skinTemp`) already uses —
        // reuses its translation key rather than adding a new "Skin Temperature" one for this tile.
        case .skinTemp:    return String(localized: "Skin Temp")
        }
    }

    /// The original, hard-coded grid order — the default when the user hasn't customised the layout.
    static let defaultOrder: [KeyMetric] = [
        .charge, .effort, .rest, .hrv, .restingHr,
        .bloodOxygen, .respiratory, .steps, .weight, .calories,
    ]

    /// What the editor offers: every tile except the three scores the rings already show (Rest, Effort, Charge), plus
    /// Skin Temp. Eight tiles, so the grid can be filled to 6 or 8.
    static let editorOptions: [KeyMetric] = defaultOrder.filter { !TodayDedup.ringTiles.contains($0) } + [.skinTemp]
}

/// The rule that keeps the Key Metrics grid balanced: two columns, so always 6 or 8 tiles, never a lone one in a row.
/// The editor only saves a selection of 6 or 8; this normalizes what is already stored (a layout saved before the rule,
/// a hand-edited value, a default) when it is read, so the grid on screen and the editor can never disagree.
enum KeyMetricGrid {
    static let allowedCounts = [6, 8]
    static var maxCount: Int { allowedCounts.last ?? 8 }

    static func isValidSelection(count: Int) -> Bool { allowedCounts.contains(count) }

    /// The tiles to draw for a stored selection: ring tiles dropped (the rings show them), duplicates dropped, order kept;
    /// more than 8 cut to the first 8; fewer than 6 (or 7) completed from `KeyMetric.editorOptions` in their order.
    static func normalized(_ selected: [KeyMetric]) -> [KeyMetric] {
        var seen = Set<KeyMetric>()
        var out = selected.filter { !TodayDedup.ringTiles.contains($0) && seen.insert($0).inserted }
        if out.count > maxCount { out = Array(out.prefix(maxCount)) }
        let target = out.count <= (allowedCounts.first ?? 6) ? (allowedCounts.first ?? 6) : maxCount
        for metric in KeyMetric.editorOptions where out.count < target && !out.contains(metric) { out.append(metric) }
        return out
    }
}

/// Display-only persistence for the Key-Metrics layout. Holds an ORDERED list of the enabled tiles; a
/// tile not in the list is hidden. Mirrors the macOS @AppStorage("today.keyMetrics") + Android side.
enum KeyMetricPrefs {
    /// UserDefaults key — a comma-joined list of `KeyMetric` rawValues in display order.
    static let layoutKey = "today.keyMetrics"

    /// Encode an ordered list of enabled tiles into the stored comma-joined string.
    static func encode(_ metrics: [KeyMetric]) -> String {
        metrics.map(\.rawValue).joined(separator: ",")
    }

    /// The tiles the grid draws for a stored string: `decodeEnabled` through `KeyMetricGrid.normalized`.
    static func decodeGrid(_ raw: String) -> [KeyMetric] {
        KeyMetricGrid.normalized(decodeEnabled(raw))
    }

    /// Decode the stored string into an ordered list of enabled tiles. An empty/unset string yields the
    /// full default order (so a fresh install shows every tile). Unknown tokens are ignored; this returns
    /// ONLY the enabled tiles in their saved order — the editor pairs it with the disabled remainder.
    static func decodeEnabled(_ raw: String) -> [KeyMetric] {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return KeyMetric.defaultOrder }
        var seen = Set<KeyMetric>()
        var result: [KeyMetric] = []
        for token in trimmed.split(separator: ",") {
            // #1518: trim EACH token, not just the whole string. `KeyMetric(rawValue:)` matches exactly, so
            // "charge, effort" dropped `effort` on the space alone. Kotlin's twin already does this
            // (`KeyMetric.fromRaw(token.trim())`), as does `DashboardCards.decodeEnabled`, so Swift was the
            // only decoder that could lose a tile the user had enabled.
            //
            // Latent rather than live: `encode` joins rawValues with no spaces, and this key is not in the
            // `.noopbak` whitelist, so nothing in the app writes a spaced value today. It is fixed because
            // a decoder that silently drops what it cannot parse should not also be picky about a space —
            // the capabilities decoder in this same change was exactly that, and there it WAS reachable.
            let raw = token.trimmingCharacters(in: .whitespaces)
            if let m = KeyMetric(rawValue: raw), seen.insert(m).inserted {
                result.append(m)
            }
        }
        return result
    }
}
