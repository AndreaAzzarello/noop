import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopProtocol

// MARK: - Review a detected workout (opened from AutoWorkoutCard)
//
// Shows the HR of the detected window (zone-coloured), lets the user pick the activity type and nudge
// the start/end within `DetectedWorkoutReview.bounds`, recomputes duration / avg / max HR as they move,
// then Save (with the chosen sport and span) or Discard (durable dismiss, same as the card's X).
// Pure limits and stats live in `DetectedWorkoutReview`; this view only presents them.
// Design-system only: StrandPalette / StrandFont / NoopMetrics, existing localized strings.

struct DetectedWorkoutReviewSheet: View {

    let workout: DetectedWorkout
    /// Called once the workout was saved (true) or discarded (false). The card hides itself and, after a
    /// save, refreshes once this sheet is gone.
    let onFinish: (Bool) -> Void

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var samples: [HRSample] = []
    @State private var loaded = false
    @State private var start: Date
    @State private var end: Date
    @State private var sport = "Activity"
    @State private var saving = false
    @State private var statsMemo = SheetMemo<DetectedWorkoutReview.Stats?>()
    @State private var pointsMemo = SheetMemo<[TrendPoint]>()
    /// Fixed at open so every clamp uses the same clock (the edited span may never end in the future).
    private let nowSec: Int

    init(workout: DetectedWorkout, onFinish: @escaping (Bool) -> Void) {
        self.workout = workout
        self.onFinish = onFinish
        _start = State(initialValue: Date(timeIntervalSince1970: TimeInterval(workout.startSec)))
        _end = State(initialValue: Date(timeIntervalSince1970: TimeInterval(workout.endSec)))
        nowSec = Int(Date().timeIntervalSince1970)
    }

    // MARK: Derived

    private var startSec: Int { Int(start.timeIntervalSince1970) }
    private var endSec: Int { Int(end.timeIntervalSince1970) }

    private var bounds: DetectedWorkoutReview.Bounds {
        DetectedWorkoutReview.bounds(for: workout, now: nowSec)
    }

    private var windowKey: String { "\(startSec)|\(endSec)|\(samples.count)" }

    private var stats: DetectedWorkoutReview.Stats? {
        statsMemo.value(for: windowKey) {
            DetectedWorkoutReview.stats(samples: samples, start: startSec, end: endSec)
        }
    }

    private var windowPoints: [TrendPoint] {
        pointsMemo.value(for: windowKey) {
            samples
                .filter { $0.ts >= startSec && $0.ts <= endSec }
                .map { TrendPoint(date: Date(timeIntervalSince1970: TimeInterval($0.ts)), value: Double($0.bpm)) }
        }
    }

    /// Both bindings route through `clamp`, so the pickers can never leave the allowed range or cross.
    private var startBinding: Binding<Date> {
        Binding(get: { start }, set: { newValue in
            let c = DetectedWorkoutReview.clamp(start: Int(newValue.timeIntervalSince1970), end: endSec,
                                                for: workout, now: nowSec)
            start = Date(timeIntervalSince1970: TimeInterval(c.start))
            end = Date(timeIntervalSince1970: TimeInterval(c.end))
        })
    }

    private var endBinding: Binding<Date> {
        Binding(get: { end }, set: { newValue in
            let c = DetectedWorkoutReview.clamp(start: startSec, end: Int(newValue.timeIntervalSince1970),
                                                for: workout, now: nowSec)
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
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                field(String(localized: "Sport")) { sportPicker }
                field(String(localized: "Start", table: "Fork")) {
                    DatePicker("", selection: startBinding, in: pickerRange, displayedComponents: [.hourAndMinute])
                        .labelsHidden()
                }
                field(String(localized: "End")) {
                    DatePicker("", selection: endBinding, in: pickerRange, displayedComponents: [.hourAndMinute])
                        .labelsHidden()
                }
            }
            actions
        }
        .task { await load() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: NoopMetrics.space3) {
            Image(systemName: "figure.run")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(StrandPalette.accent)
                .frame(width: 30, height: 30)
                .background(StrandPalette.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            Text("Looks like a workout")
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: 0)
            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .disabled(saving)
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
            trailing: stats.map { String(localized: "avg \($0.avgBpm)") },
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
                ("Duration", stats.map { String(localized: "\($0.durationMin) min") } ?? "–"),
                ("Avg HR", stats.map { String(localized: "\($0.avgBpm) bpm") } ?? "–"),
                ("Max HR", stats.map { String(localized: "\($0.maxBpm) bpm") } ?? "–"),
            ])
        }
    }

    /// Chips instead of a menu: the common sports are one tap away beside Start and End, "More…" opens the
    /// full searchable list. The stored value stays the English name; only the labels are localized.
    private var sportPicker: some View { SportChipPicker(sport: $sport) }

    private var actions: some View {
        VStack(spacing: NoopMetrics.space3) {
            Button {
                save()
            } label: {
                Label("Save it", systemImage: "checkmark").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(StrandPalette.accent)
            .disabled(saving)

            Button {
                discard()
            } label: {
                Text("Not a workout").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(saving)
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
        samples = await repo.reviewSamples(for: workout)
        loaded = true
    }

    private func save() {
        saving = true
        let s = start, e = end, chosen = sport, avg = stats?.avgBpm
        Task {
            let ok = await repo.saveReviewedDetectedWorkout(sport: chosen, start: s, end: e, avgHr: avg)
            if ok {
                onFinish(true)
                dismiss()
            } else {
                saving = false
            }
        }
    }

    private func discard() {
        repo.dismissDetectedSuggestion(workout)
        onFinish(false)
        dismiss()
    }
}
