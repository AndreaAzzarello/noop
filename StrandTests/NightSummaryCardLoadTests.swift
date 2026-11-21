#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import Strand

/// Regression for the Night card that never appeared: its `.task` hung off an empty `Group`, so the load never
/// started. Hosting the card in a window and waiting for `onLoaded` proves the load now runs at all, whatever the
/// day or the alarm settings.
@MainActor
final class NightSummaryCardLoadTests: XCTestCase {

    func testTheLoadStartsOnAnEmptyFirstRender() {
        let loaded = expectation(description: "night summary load started")
        loaded.assertForOverFulfill = false
        let card = NightSummaryCard(style: .full, onLoaded: { loaded.fulfill() })
            .environmentObject(Repository(deviceId: "test-night-card-\(UUID().uuidString)"))
            .environmentObject(BehaviorStore())
        let host = NSHostingView(rootView: card)
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false // ARC owns it; the default double-releases on close
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        wait(for: [loaded], timeout: 10)
    }
}
#endif
