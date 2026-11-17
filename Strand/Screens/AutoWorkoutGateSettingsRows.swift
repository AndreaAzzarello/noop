import SwiftUI
import StrandDesign

/// The two choices that shape the auto-detect confirmation gate (`AutoWorkoutMotionGate`): the shortest workout it
/// will suggest and whether movement is required. Shown under the "Auto-detect workouts" switch, only while it is on.
/// Reuses existing localized labels; design tokens only.
struct AutoWorkoutGateSettingsRows: View {
    var enabled: Bool

    @AppStorage(AutoWorkoutMotionGate.minMinutesKey) private var minMinutes = AutoWorkoutMotionGate.defaultMinMinutes
    @AppStorage(AutoWorkoutMotionGate.requireMotionKey) private var requireMotion = true

    var body: some View {
        if enabled {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Duration")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: 12)
                    Picker("Duration", selection: $minMinutes) {
                        ForEach(AutoWorkoutMotionGate.durationChoices, id: \.self) { minutes in
                            Text("\(minutes) min").tag(minutes)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }

                Toggle(isOn: $requireMotion) {
                    Text("Movement")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
            }
        }
    }
}
