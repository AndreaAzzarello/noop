import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopProtocol
import WhoopStore

// MARK: - Quick edit of a workout (the pencil on Today's workout card)
//
// Activity type, start and end in ONE screen, over the zone-coloured heart-rate curve of the window: the same
// controls the review sheet of a detected workout offers, for a workout that is already saved. Saving goes
// through the same path as `ManualWorkoutSheet` (`WorkoutSource.buildManualRowFromSpan`, captured fields
// carried over, the old row replaced), so name, icon and calculations update exactly as before. Distance,
// calories and the rest stay reachable through "More details…", which opens the full `ManualWorkoutSheet`.
// Design-system only: StrandPalette / StrandFont / NoopMetrics.

struct WorkoutQuickEditSheet: View {

    let row: WorkoutRow
    /// Called with the validated row and the original it replaces, once the user taps Save.
    let onSave: (_ row: WorkoutRow, _ replacing: WorkoutRow?) -> Void

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var samples: [HRSample] = []
    @State private var loaded = false
    @State private var start: Date
    @State private var end: Date
    @State private var sport: String
    @State private var showFullEditor = false
    /// Fixed at open so every clamp uses the same clock (the edited span may never end in the future).
    private let nowSec: Int
    /// The saved span as a detected-window value, so the review's limits and statistics apply unchanged.
    private let window: DetectedWorkout

    init(row: WorkoutRow, onSave: @escaping (_ row: WorkoutRow, _ replacing: WorkoutRow?) -> Void) {
        self.row = row
        self.onSave = onSave
        _start = State(initialValue: Date(timeIntervalSince1970: TimeInterval(row.startTs)))
        _end = State(initialValue: Date(timeIntervalSince1970: TimeInterval(row.endTs)))
        _sport = State(initialValue: WorkoutSource.editableSport(row.sport))
        nowSec = Int(Date().timeIntervalSince1970)
        window = DetectedWorkout(startSec: row.startTs, endSec: row.endTs, avgBpm: row.avgHr ?? 0,
                                 peakBpm: row.maxHr ?? 0, durationMin: Int((row.durationS ?? 0) / 60))
    }

    // MARK: Derived

    private var startSec: Int { Int(start.timeIntervalSince1970) }
    private var endSec: Int { Int(end.timeIntervalSince1970) }

    private var bounds: DetectedWorkoutReview.Bounds { DetectedWorkoutReview.bounds(for: window, now: nowSec) }

    private var stats: DetectedWorkoutReview.Stats? {
        DetectedWorkoutReview.stats(samples: samples, start: startSec, end: endSec)
    }

    /// The average HR that will be saved, and the one the footer shows (see `WorkoutQuickEdit.avgHr`).
    private var savedAvg: Int? { WorkoutQuickEdit.avgHr(row: row, start: startSec, end: endSec, samples: samples) }

    private var windowPoints: [TrendPoint] {
        samples
            .filter { $0.ts >= startSec && $0.ts <= endSec }
            .map { TrendPoint(date: Date(timeIntervalSince1970: TimeInterval($0.ts)), value: Double($0.bpm)) }
    }

    /// The row Save would write, or nil when the values cannot make an honest one (Save is then disabled).
    private var builtRow: WorkoutRow? {
        WorkoutQuickEdit.rebuilt(row: row, start: start, end: end, sport: sport, samples: samples)
    }

    /// Both bindings route through `clamp`, so the pickers can never leave the allowed range or cross.
    private var startBinding: Binding<Date> {
        Binding(get: { start }, set: { newValue in
            let c = DetectedWorkoutReview.clamp(start: Int(newValue.timeIntervalSince1970), end: endSec,
                                                for: window, now: nowSec)
            start = Date(timeIntervalSince1970: TimeInterval(c.start))
            end = Date(timeIntervalSince1970: TimeInterval(c.end))
        })
    }

    private var endBinding: Binding<Date> {
        Binding(get: { end }, set: { newValue in
            let c = DetectedWorkoutReview.clamp(start: startSec, end: Int(newValue.timeIntervalSince1970),
                                                for: window, now: nowSec)
            start = Date(timeIntervalSince1970: TimeInterval(c.start))
            end = Date(timeIntervalSince1970: TimeInterval(c.end))
        })
    }

    private var pickerRange: ClosedRange<Date> {
        Date(timeIntervalSince1970: TimeInterval(bounds.earliest))...Date(timeIntervalSince1970: TimeInterval(bounds.latest))
    }

    // MARK: Body

    var body: some View {
        #if os(macOS)
        content
            .padding(NoopMetrics.space6)
            .frame(width: 460)
            .background(NoopChromeSurface())
        #else
        ScrollView { content.padding(NoopMetrics.space6) }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .frame(maxWidth: .infinity)
            .noopSheetPresentation(largeFirst: true)
            .background(NoopChromeSurface())
        #endif
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space5) {
            header
            chartCard
            field(String(localized: "Sport")) { SportChipPicker(sport: $sport) }
            field(String(localized: "Start", table: "Fork")) {
                DatePicker("", selection: startBinding, in: pickerRange,
                           displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
            }
            field(String(localized: "End")) {
                DatePicker("", selection: endBinding, in: pickerRange,
                           displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
            }
            actions
        }
        .task { await load() }
        .sheet(isPresented: $showFullEditor) {
            ManualWorkoutSheet(editing: row) { newRow, replacing in
                onSave(newRow, replacing)
                dismiss()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: NoopMetrics.space3) {
            Image(systemName: "pencil")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(StrandPalette.accent)
                .frame(width: 30, height: 30)
                .background(StrandPalette.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            Text("Edit Workout")
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: 0)
            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    @ViewBuilder private var chartCard: some View {
        let points = windowPoints
        let values = points.map(\.value)
        let lo = max(0, (values.min() ?? 60) - 8)
        let hi = (values.max() ?? 180) + 8
        // Built per render (not a static) so the Clock format setting reaches the tooltip, as on the card.
        let timeFmt = AppClock.hourMinuteFormatter()
        ChartCard(
            title: "HEART RATE",
            trailing: savedAvg.map { String(localized: "avg \($0)") },
            tint: StrandPalette.effortColor
        ) {
            if points.count > 1 {
                ZoneColoredHRChart(
                    points: points,
                    zoneSet: profile.hrZoneSet,
                    valueRange: lo...hi,
                    valueFormat: { String(localized: "\(Int($0.rounded())) bpm") },
                    dateFormat: { timeFmt.string(from: $0) },
                    accessibilityLabel: String(localized: "Heart rate"),
                    workoutTimeAxis: start...end
                )
            } else if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        } footer: {
            ChartFooter([
                ("Duration", String(localized: "\(max(0, (endSec - startSec) / 60)) min")),
                ("Avg HR", savedAvg.map { String(localized: "\($0) bpm") } ?? "–"),
            ])
        }
    }

    private var actions: some View {
        VStack(spacing: NoopMetrics.space3) {
            Button {
                save()
            } label: {
                Label("Save", systemImage: "checkmark").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(StrandPalette.accent)
            .disabled(builtRow == nil)

            Button {
                showFullEditor = true
            } label: {
                Text("More details…", tableName: "Fork")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.plain)
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).strandOverline()
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Actions

    private func load() async {
        samples = await repo.hrSamples(from: bounds.earliest, to: bounds.latest, limit: 50_000)
        loaded = true
    }

    private func save() {
        guard let built = builtRow else { return }
        // A confirmed save is a real selection: fold the sport into the recents, as the full editor does.
        RecentSportsPrefs.recordSelection(built.sport)
        onSave(built, row)
        dismiss()
    }
}
