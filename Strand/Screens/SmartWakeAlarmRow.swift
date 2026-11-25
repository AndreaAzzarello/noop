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
    /// VoiceOver's "Edit" action; defaults to `onEdit`. Separate so a tap guard on `onEdit` never swallows it.
    var onAccessibilityEdit: (() -> Void)? = nil

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
            .fixedSize()   // the text gives way at large Dynamic Type, never the switch
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(SmartWakeAlarmText.spoken(alarm)))
        .accessibilityAction(named: Text("Edit", tableName: "Fork"), onAccessibilityEdit ?? onEdit)
        .accessibilityAction(named: Text("Delete", tableName: "Fork"), onDelete)
    }
}

/// Swipe left to reveal Delete, for rows that are not inside a `List` (which has `swipeActions`). The row shrinks from the
/// right by the button width, so the time and the switch move together and nothing is clipped. One row is open at a time
/// (`openID`, owned by the screen); drag and tap are arbitrated by `SmartWakeSwipe`. The row also offers Delete as an
/// accessibility action, so nothing depends on the gesture.
struct SmartWakeSwipeToDelete: ViewModifier {
    let rowID: UUID
    @Binding var openID: UUID?
    @Binding var lastDragActivity: Date?
    let onDelete: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var live: CGFloat?
    @State private var horizontal: Bool?

    private var isOpen: Bool { openID == rowID }
    private var base: CGFloat { isOpen ? SmartWakeSwipe.buttonWidth : 0 }
    private var reveal: CGFloat { live ?? base }
    private var animation: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.35, dampingFraction: 0.85)
    }

    func body(content: Content) -> some View {
        content
            .padding(.trailing, reveal > 0 ? reveal + NoopMetrics.space2 : 0)
            .background(alignment: .trailing) { deleteButton }
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        if horizontal == nil {
                            horizontal = SmartWakeSwipe.isHorizontal(value.translation)
                            if horizontal == true, let open = openID, open != rowID {
                                withAnimation(animation) { openID = nil }
                            }
                        }
                        guard horizontal == true else { return }
                        lastDragActivity = Date()
                        live = SmartWakeSwipe.liveReveal(start: base, translation: value.translation.width,
                                                         rubberBand: !reduceMotion)
                    }
                    .onEnded { value in
                        defer { horizontal = nil }
                        guard horizontal == true else { return }
                        lastDragActivity = Date()
                        let open = SmartWakeSwipe.settle(
                            reveal: live ?? base,
                            projectedDelta: value.predictedEndTranslation.width - value.translation.width,
                            wasOpen: isOpen)
                        withAnimation(animation) {
                            if open { openID = rowID } else if openID == rowID { openID = nil }
                            live = nil
                        }
                    })
    }

    private var deleteButton: some View {
        let progress = min(1, reveal / (SmartWakeSwipe.buttonWidth * 0.6))
        return Button(role: .destructive) {
            withAnimation(animation) { openID = nil }
            onDelete()
        } label: {
            VStack(spacing: NoopMetrics.space1) {
                Image(systemName: "trash.fill")
                Text("Delete", tableName: "Fork").lineLimit(1).minimumScaleFactor(0.7)
            }
            .font(StrandFont.footnote.weight(.semibold))
            .foregroundStyle(StrandPalette.surfaceBase)
            .opacity(progress)
            .frame(width: max(reveal, 0))
            .frame(maxHeight: .infinity)
            .background(StrandPalette.statusCritical, in: RoundedRectangle(cornerRadius: NoopMetrics.cardRadius * 0.6, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(reveal > 1 ? 1 : 0)
        .allowsHitTesting(reveal > 1)
        .accessibilityHidden(true)
    }
}
#endif
