import SwiftUI
import StrandDesign

// MARK: - Sport chips for the quick workout edit
//
// A wrapping row of capsule chips: the generic "Activity", the current choice, recent choices and the common
// sports, plus a last "More…" chip that opens the full searchable activity browser. The selection is the
// English stored name; chips show it localized. Design tokens only.

struct SportChipPicker: View {

    @Binding var sport: String

    @State private var showAll = false

    private var options: [String] {
        SportChipOptions.options(selected: sport,
                                 recents: RecentSportsPrefs.recent(),
                                 common: WorkoutsView.relabelSports)
    }

    var body: some View {
        SportChipFlow(spacing: NoopMetrics.space2) {
            ForEach(options, id: \.self) { name in chip(name) }
            moreChip
        }
        .sheet(isPresented: $showAll) {
            StartWorkoutSheet(title: String(localized: "Choose an activity", table: "Fork"),
                              subtitle: String(localized: "Search the full list of activities.", table: "Fork"),
                              actionVerb: String(localized: "Select", table: "Fork")) { name in
                sport = name
            }
        }
    }

    private func chip(_ name: String) -> some View {
        let selected = SportChipOptions.same(name, sport)
        return Button {
            sport = name
        } label: {
            Text(verbatim: SportDisplayName.localized(name))
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, NoopMetrics.space3)
                .frame(minHeight: 36)
                .background(Capsule(style: .continuous)
                    .fill(selected ? StrandPalette.accent.opacity(0.18) : StrandPalette.surfaceOverlay))
                .overlay(Capsule(style: .continuous)
                    .stroke(selected ? StrandPalette.accent : StrandPalette.hairline, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var moreChip: some View {
        Button {
            showAll = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold))
                Text("More…", tableName: "Fork")
            }
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textSecondary)
            .padding(.horizontal, NoopMetrics.space3)
            .frame(minHeight: 36)
            .overlay(Capsule(style: .continuous)
                .stroke(StrandPalette.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("More activities", tableName: "Fork"))
    }
}

/// Left-to-right wrapping layout for the chips: a new line starts when the next chip does not fit.
private struct SportChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        return arrange(width: width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placed = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in placed.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                                  proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (origins, CGSize(width: maxX, height: y + rowHeight))
    }
}
