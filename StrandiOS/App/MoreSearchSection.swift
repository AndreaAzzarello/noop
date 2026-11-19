import SwiftUI
import StrandDesign

// MARK: - Quick search in the More tab
//
// A search field above the More list. With text in it, the groups give way to a card of matches from
// `MoreSearch` (the More rows plus the main settings and Smart Wake); a tap pushes the destination on the
// More tab's own path, exactly as tapping the row would. The field is the design system's own
// `NoopLiquidGlassSearchField`: the More tab draws its own header and hides the navigation bar, so a
// navigation-bar `.searchable` would have nowhere to appear. Design tokens only.

struct MoreSearchSection: View {

    @Binding var query: String
    @Binding var path: NavigationPath

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            NoopLiquidGlassSearchField(text: $query,
                                       prompt: String(localized: "Search More and Settings", table: "Fork"),
                                       isFocused: $focused)
            if MoreSearch.isActive(query) {
                let matches = MoreSearch.results(for: query)
                if matches.isEmpty { emptyState } else { resultsCard(matches) }
            }
        }
    }

    private func resultsCard(_ matches: [MoreSearch.Entry]) -> some View {
        NoopCard(padding: 0) {
            VStack(spacing: 0) {
                ForEach(matches, id: \.id) { entry in resultRow(entry) }
            }
            .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
        }
    }

    private func resultRow(_ entry: MoreSearch.Entry) -> some View {
        Button {
            open(entry)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: entry.symbol)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(StrandPalette.accent)
                    .frame(width: 26, alignment: .center)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: MoreSearch.localizedTitle(entry))
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(verbatim: MoreSearch.localizedParent(entry))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle().fill(StrandPalette.hairline).frame(height: 1).padding(.leading, 16)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        VStack(spacing: NoopMetrics.space2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
            Text("No results for “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”", tableName: "Fork")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
                .multilineTextAlignment(.center)
            Text("Try another word, for example alarm or backup.", tableName: "Fork")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, NoopMetrics.space6)
        .accessibilityElement(children: .combine)
    }

    private func open(_ entry: MoreSearch.Entry) {
        focused = false
        path.append(MoreDestination(searchRoute: entry.route))
        query = ""
    }
}

extension MoreDestination {

    /// The destination a `MoreSearch` route names. Exhaustive: a new route cannot compile unwired.
    init(searchRoute: MoreSearch.Route) {
        switch searchRoute {
        case .insightsHub: self = .insightsHub
        case .intelligence: self = .intelligence
        case .insights: self = .insights
        case .explore: self = .explore
        case .compare: self = .compare
        case .live: self = .live
        case .workouts: self = .workouts
        case .liftLog: self = .liftLog
        case .health: self = .health
        case .labBook: self = .labBook
        case .stress: self = .stress
        case .breathe: self = .breathe
        case .intervals: self = .intervals
        case .rhythm: self = .rhythm
        case .fusedRecord: self = .fusedRecord
        case .appleHealth: self = .appleHealth
        case .miBand: self = .miBand
        case .dataSources: self = .dataSources
        case .backupSync: self = .backupSync
        case .shortcutsExport: self = .shortcutsExport
        case .noopLimitations: self = .noopLimitations
        case .alarms: self = .alarms
        case .automations: self = .automations
        case .testCentre: self = .testCentre
        case .siriShortcuts: self = .siriShortcuts
        case .powerSaving: self = .powerSaving
        case .settings: self = .settings
        }
    }
}
