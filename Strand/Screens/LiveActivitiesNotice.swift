import SwiftUI
import StrandDesign
#if os(iOS)
import ActivityKit
import UIKit

/// Warning shown in the Smart Wake card when iOS Live Activities are switched off for NOOP. AlarmKit presents
/// the ringing alarm through a Live Activity, so with them off the iPhone alarm stays silent. Observes the
/// system setting itself (stream + return to foreground) so the card does not have to re-render for it.
struct LiveActivitiesNotice: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var enabled = ActivityAuthorizationInfo().areActivitiesEnabled

    var body: some View {
        Group {
            if !enabled { notice }
        }
        .task {
            for await value in ActivityAuthorizationInfo().activityEnablementUpdates { enabled = value }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { enabled = ActivityAuthorizationInfo().areActivitiesEnabled }
        }
    }

    private var notice: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(StrandPalette.statusWarning)
                    .accessibilityHidden(true)
                Text("Turn on Live Activities for NOOP, or the iPhone alarm won't ring", tableName: "Fork")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            } label: {
                Text("Open Settings", tableName: "Fork")
                    .font(StrandFont.footnote)
            }
            .buttonStyle(.bordered)
            .tint(StrandPalette.statusWarning)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#else
/// macOS has no Live Activities: nothing to show.
struct LiveActivitiesNotice: View {
    var body: some View { EmptyView() }
}
#endif
