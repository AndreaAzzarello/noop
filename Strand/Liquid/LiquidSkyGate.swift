import SwiftUI

/// fork-perf: decides when the animated Liquid sky (`LiquidSky`, 20 fps Canvas) must stand still: while the
/// Today scroll view is moving, while the tab is not on screen, and while the app is not active. The sky
/// observes this object; nothing else does, so flipping it re-renders the sky only. Paused means the sky is
/// drawn as one frame at the clock value it had when it stopped, so nothing jumps when it resumes.
@MainActor
final class LiquidSkyGate: ObservableObject {
    static let shared = LiquidSkyGate()
    private init() {}

    @Published private(set) var paused = false
    private var scrolling = false
    private var visible = true
    private var active = true

    func set(scrolling: Bool? = nil, visible: Bool? = nil, active: Bool? = nil) {
        if let scrolling { self.scrolling = scrolling }
        if let visible { self.visible = visible }
        if let active { self.active = active }
        let next = self.scrolling || !self.visible || !self.active
        if next != paused { paused = next }
    }
}

/// Last animation clock value the sky drew, kept in a reference box (written every frame, never observed).
final class LiquidSkyClock {
    var now: Double = 0
    func record(_ value: Double) { now = value }
}

private struct LiquidSkyScrollGate: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        scrollAware(content)
            .onAppear { LiquidSkyGate.shared.set(visible: true) }
            .onDisappear { LiquidSkyGate.shared.set(visible: false) }
            .onChangeCompat(of: scenePhase) { phase in
                LiquidSkyGate.shared.set(active: phase == .active)
            }
    }

    @ViewBuilder private func scrollAware(_ content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content.onScrollPhaseChange { _, phase in
                LiquidSkyGate.shared.set(scrolling: phase != .idle)
            }
        } else {
            content
        }
    }
}

extension View {
    /// Apply to the Today `ScrollView`: pauses the animated sky while it scrolls, is off screen or inactive.
    func liquidSkyScrollGate() -> some View { modifier(LiquidSkyScrollGate()) }
}
