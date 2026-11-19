import Foundation

// MARK: - Quick search in the More tab: static index and matching
//
// Pure logic behind `MoreSearchSection` (iPhone). The index lists every screen the More tab links to plus the
// main settings and the Smart Wake controls, each with English + Italian keywords, and the matcher is
// case-, accent- and width-insensitive. An entry names its destination by a ROUTE id (the case name of the
// More tab's `MoreDestination`), so this file needs no UI and the tests run without the iOS target.
// Titles are existing catalogue keys, looked up when a query runs (so a language change is honoured);
// the keywords are folded once.

enum MoreSearch {

    /// Which string table holds an entry's title.
    enum Table { case main, fork }

    struct Entry: Equatable {
        /// Unique and stable.
        let id: String
        /// The More destination this opens.
        let route: Route
        /// English catalogue key of the title.
        let title: String
        let table: Table
        /// English catalogue key of the screen the entry lives on ("More", "Settings", "Alarms").
        let parent: String
        /// SF Symbol.
        let symbol: String
        /// Extra words (Italian and English) that should find the entry, as typed.
        let keywords: [String]
    }

    /// Every destination the More tab can open, named like the cases of its `MoreDestination` (`coach` has no
    /// row). The iOS side maps each case to its destination with an exhaustive `switch`, so a route added here
    /// does not compile until it is wired.
    enum Route: String, CaseIterable {
        case insightsHub, intelligence, insights, explore, compare
        case live, workouts, liftLog, health, labBook, stress, breathe, intervals, rhythm
        case fusedRecord, appleHealth, miBand, dataSources, backupSync, shortcutsExport, noopLimitations
        case alarms, automations, testCentre, siriShortcuts, powerSaving, settings
    }

    // MARK: Index

    private static func row(_ route: Route, _ title: String, _ symbol: String, _ keywords: [String]) -> Entry {
        Entry(id: "more.\(route.rawValue)", route: route, title: title, table: .main, parent: "More",
              symbol: symbol, keywords: keywords)
    }

    private static func setting(_ id: String, _ title: String, _ symbol: String, _ keywords: [String],
                                route: Route = .settings, parent: String = "Settings",
                                table: Table = .main) -> Entry {
        Entry(id: "setting.\(id)", route: route, title: title, table: table, parent: parent,
              symbol: symbol, keywords: keywords)
    }

    /// The whole index, in the order the More tab lists its rows, then the deeper settings.
    static let entries: [Entry] = [
        row(.insightsHub, "What Moves You", "wand.and.sparkles",
            ["influenze", "fattori", "correlazioni", "influences", "drivers", "correlations"]),
        row(.intelligence, "Intelligence", "brain.head.profile",
            ["ai", "analisi", "analysis", "intelligenza artificiale"]),
        row(.insights, "Insights", "lightbulb.fill", ["tendenze", "trends", "pattern"]),
        row(.explore, "Explore", "square.grid.2x2.fill", ["metriche", "grafici", "metrics", "charts"]),
        row(.compare, "Compare", "rectangle.split.2x1.fill", ["confronto", "sovrapposizione", "versus", "overlay"]),
        row(.live, "Live", "waveform.path.ecg",
            ["tempo reale", "frequenza cardiaca", "battito", "fc", "real time", "heart rate"]),
        row(.workouts, "Workouts", "figure.run",
            ["allenamento", "sessioni", "sport", "corsa", "workout", "training", "running"]),
        row(.liftLog, "Lift Log", "dumbbell.fill", ["pesi", "palestra", "forza", "serie", "weights", "gym", "strength"]),
        row(.health, "Health", "heart.text.square.fill", ["salute", "spo2", "temperatura", "vitals", "temperature"]),
        row(.labBook, "Lab Book", "books.vertical.fill",
            ["esami", "analisi del sangue", "biomarcatori", "lab", "blood test", "biomarkers"]),
        row(.stress, "Stress", "bolt.heart.fill", ["relax", "tensione"]),
        row(.breathe, "Breathe", "wind", ["respirazione", "meditazione", "breathing", "meditation"]),
        row(.intervals, "Intervals", "timer", ["timer", "intervallo", "hiit", "tabata"]),
        row(.rhythm, "Rhythm", "waveform.path", ["ritmo", "regolarita", "regularity", "rr", "beat to beat"]),
        row(.fusedRecord, "Your Data, Fused", "square.stack.3d.up.fill",
            ["fusi", "registro", "unificati", "merged", "unified", "record"]),
        row(.appleHealth, "Apple Health", "heart.fill", ["healthkit", "salute", "importa", "import"]),
        row(.miBand, "Mi Band", "figure.walk.motion", ["xiaomi", "fascia xiaomi"]),
        row(.dataSources, "Data Sources", "externaldrive.fill",
            ["sorgenti", "fonti", "dispositivi", "sources", "devices", "import"]),
        row(.backupSync, "Backup & Sync", "externaldrive.fill.badge.icloud",
            ["backup", "ripristino", "sincronizzazione", "esporta", "restore", "sync", "icloud", "export", "noopbak"]),
        row(.shortcutsExport, "Shortcuts Export", "square.and.arrow.up.fill",
            ["comandi rapidi", "esporta", "file", "shortcuts", "export", "siri"]),
        row(.noopLimitations, "NOOP Limitations", "list.bullet.rectangle",
            ["limiti", "limitazioni", "compatibilita", "differenze", "capabilities", "4.0", "5.0", "mg"]),
        row(.alarms, "Alarms", "alarm.fill",
            ["sveglia", "allarme", "vibrazione", "alarm", "wake", "smart alarm", "haptic"]),
        row(.automations, "Automations", "wand.and.stars",
            ["automazione", "notifiche", "polso", "notifications", "wrist"]),
        row(.testCentre, "Test Centre", "stethoscope",
            ["centro test", "diagnostica", "segnala", "bug", "log", "diagnostics", "report", "debug"]),
        row(.siriShortcuts, "Siri & Shortcuts", "mic.fill", ["siri", "comandi rapidi", "voce", "shortcuts", "voice"]),
        row(.powerSaving, "Power saving", "battery.25",
            ["batteria", "risparmio", "energia", "autonomia", "battery", "power"]),
        row(.settings, "Settings", "gearshape.fill", ["impostazioni", "preferenze", "opzioni", "preferences", "options"]),

        setting("smartWake", "Smart Wake", "alarm.waves.left.and.right.fill",
                ["sveglia intelligente", "finestra di risveglio", "sonno leggero", "risveglio",
                 "wake window", "light sleep", "smart alarm"],
                route: .alarms, parent: "Alarms", table: .fork),
        setting("profile", "Profile", "person.crop.circle",
                ["profilo", "eta", "peso", "altezza", "sesso", "fc max", "data di nascita",
                 "age", "weight", "height", "sex", "max hr", "hrmax", "birthday"]),
        setting("customZones", "Custom HR zones", "heart.circle",
                ["zone", "zone cardio", "soglie", "fc massima", "zones", "hr zones", "thresholds", "max hr"]),
        setting("units", "Units", "ruler",
                ["unita", "chilometri", "miglia", "celsius", "fahrenheit", "metric", "imperial", "miles", "kg", "lb"]),
        setting("appearance", "Appearance", "paintpalette",
                ["tema", "scuro", "chiaro", "colore", "orologio", "theme", "dark", "light", "accent", "clock", "24h"]),
        setting("language", "Language", "globe", ["lingua", "italiano", "idioma", "english", "translation"]),
        setting("strap", "Strap", "applewatch",
                ["fascia", "whoop", "bracciale", "accoppia", "bluetooth", "connessione", "pair", "connection"]),
        setting("liveNotifications", "Live notifications", "bell.badge",
                ["notifiche", "live activity", "dynamic island", "schermata di blocco", "lock screen"]),
        setting("recovery", "Recovery", "arrow.counterclockwise",
                ["recupero", "charge", "baseline", "readiness"]),
        setting("features", "Features", "switch.2", ["funzionalita", "funzioni", "opzioni", "toggle"]),
        setting("autoDetect", "Auto-detect workouts", "figure.run.circle",
                ["rilevamento allenamenti", "rilevamento automatico", "durata minima", "movimento", "rileva",
                 "workout detection", "auto detect", "minimum duration", "motion"]),
        setting("hrv", "HRV", "waveform.path.ecg.rectangle", ["variabilita", "rmssd", "variability"]),
        setting("sleepStaging", "Sleep staging", "bed.double", ["sonno", "fasi", "profondo", "sleep", "stages", "rem", "deep"]),
        setting("liveSessions", "Live Sessions (beta)", "shield.lefthalf.filled",
                ["avvia sessione", "sessioni live", "start session", "live sessions", "coach", "guardian", "vibra"]),
        setting("diagnostics", "Diagnostics", "stethoscope.circle", ["diagnostica", "log", "debug", "trace"]),
        setting("backupRestore", "Backup & restore", "arrow.triangle.2.circlepath",
                ["backup", "ripristino", "esporta", "importa", "restore", "export", "noopbak"]),
        setting("sync", "Sync", "arrow.triangle.2.circlepath.circle",
                ["sincronizza", "importa", "csv", "sync", "import", "whoop export"]),
        setting("about", "About", "info.circle",
                ["informazioni", "versione", "licenza", "crediti", "version", "license", "credits", "build"]),
    ]

    // MARK: Matching

    /// Lower-cased, accent- and width-insensitive, trimmed: "Svéglia " and "SVEGLIA" fold to the same text.
    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Keywords folded once.
    private static let foldedKeywords: [String: String] = Dictionary(
        uniqueKeysWithValues: entries.map { ($0.id, $0.keywords.map(normalize).joined(separator: " ")) })

    /// The entry's title in the app language.
    static func localizedTitle(_ entry: Entry) -> String {
        localized(entry.title, table: entry.table)
    }

    /// The parent screen's title in the app language.
    static func localizedParent(_ entry: Entry) -> String {
        localized(entry.parent, table: .main)
    }

    private static func localized(_ key: String, table: Table) -> String {
        switch table {
        case .main: return String(localized: String.LocalizationValue(key))
        case .fork: return String(localized: String.LocalizationValue(key), table: "Fork")
        }
    }

    /// True when a query has anything to search for.
    static func isActive(_ query: String) -> Bool { !normalize(query).isEmpty }

    /// Entries matching every word of `query`, best first: a title that starts with the query, then a title
    /// that contains it, then a keyword hit; index order within a rank. Empty for an empty query.
    static func results(for query: String,
                        in index: [Entry] = entries,
                        title: (Entry) -> String = localizedTitle) -> [Entry] {
        let folded = normalize(query)
        guard !folded.isEmpty else { return [] }
        let words = folded.split(whereSeparator: \.isWhitespace).map(String.init)
        var ranked: [(rank: Int, position: Int, entry: Entry)] = []
        for (position, entry) in index.enumerated() {
            let localTitle = normalize(title(entry))
            let haystack = [localTitle, normalize(entry.title), foldedKeywords[entry.id] ?? entry.keywords.map(normalize).joined(separator: " ")]
                .joined(separator: " ")
            guard words.allSatisfy({ haystack.contains($0) }) else { continue }
            let rank = localTitle.hasPrefix(folded) || normalize(entry.title).hasPrefix(folded) ? 0
                : (localTitle.contains(folded) || normalize(entry.title).contains(folded) ? 1 : 2)
            ranked.append((rank, position, entry))
        }
        return ranked.sorted { ($0.rank, $0.position) < ($1.rank, $1.position) }.map(\.entry)
    }
}
