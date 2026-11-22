#if os(iOS) && canImport(AlarmKit)
import SwiftUI
import StrandDesign

// fork: one Smart Wake alarm as a row: the time large, "days · early · insistent" under it, a switch on the right.
// Shared by the alarm list sheet and the Alarms screen panel so both read the same.

struct SmartWakeAlarmRow: View {
    let alarm: SmartWakeAlarm
    let onEdit: () -> Void
    let onToggle: (Bool) -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(SmartWakeAlarmText.time(minutes: alarm.wakeMinutes))
                        .font(StrandFont.number(34, weight: .light))
                        .foregroundStyle(alarm.isEnabled ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                    Text(SmartWakeAlarmText.summary(of: alarm))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Toggle(isOn: Binding(get: { alarm.isEnabled }, set: onToggle)) {
                Text(SmartWakeAlarmText.name(of: alarm))
            }
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(StrandPalette.accent)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(SmartWakeAlarmText.spoken(alarm)))
        .accessibilityAction(named: Text("Edit", tableName: "Fork"), onEdit)
        .accessibilityAction(named: Text("Delete", tableName: "Fork"), onDelete)
    }
}

/// Swipe left to reveal Delete, for rows that are not inside a `List` (which has `swipeActions`). The row also offers
/// Delete as an accessibility action and a context menu, so nothing depends on the gesture.
struct SmartWakeSwipeToDelete: ViewModifier {
    let onDelete: () -> Void
    @State private var offset: CGFloat = 0
    private let reveal: CGFloat = 84

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .background(alignment: .trailing) {
                Button(role: .destructive) {
                    withAnimation { offset = 0 }
                    onDelete()
                } label: {
                    Text("Delete", tableName: "Fork")
                        .font(StrandFont.footnote.weight(.semibold))
                        .foregroundStyle(StrandPalette.surfaceBase)
                        .frame(width: reveal)
                        .frame(maxHeight: .infinity)
                        .background(StrandPalette.statusCritical)
                }
                .opacity(offset < -4 ? 1 : 0)
                .allowsHitTesting(offset < -4)
                .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 24)
                    .onChanged { value in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        offset = min(0, max(-reveal, value.translation.width))
                    }
                    .onEnded { value in
                        withAnimation(.easeOut(duration: 0.15)) {
                            offset = value.translation.width < -reveal / 2 ? -reveal : 0
                        }
                    })
            .clipped()
    }
}
#endif
