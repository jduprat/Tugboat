import AppKit
import XCTest
@testable import Tugboat

final class WindowActivationCoordinatorTests: XCTestCase {
    func testRegisteringTheSameWindowTwiceDoesNotKeepItRegisteredAfterOneClose() {
        let harness = Harness()
        let window = makeWindow()

        harness.coordinator.register(window)
        harness.coordinator.register(window)
        XCTAssertEqual(harness.policies, [.regular])

        harness.close(window)
        XCTAssertEqual(harness.policies, [.regular])
        harness.runDeferred()
        XCTAssertEqual(harness.policies, [.regular, .accessory])
    }

    func testClosingEitherOfTwoWindowsKeepsRegularPolicyUntilTheOtherCloses() {
        for firstClosedIndex in 0...1 {
            let harness = Harness()
            let windows = [makeWindow(), makeWindow()]

            windows.forEach(harness.coordinator.register)
            XCTAssertEqual(harness.policies, [.regular])

            harness.close(windows[firstClosedIndex])
            harness.runDeferred()
            XCTAssertEqual(harness.policies, [.regular])

            harness.close(windows[1 - firstClosedIndex])
            harness.runDeferred()
            XCTAssertEqual(harness.policies, [.regular, .accessory])
        }
    }

    func testReopeningBeforeDeferredReconciliationPreventsDemotion() {
        let harness = Harness()
        let window = makeWindow()

        harness.coordinator.register(window)
        harness.close(window)
        harness.coordinator.register(window)
        harness.runDeferred()
        XCTAssertEqual(harness.policies, [.regular])

        harness.close(window)
        harness.runDeferred()
        XCTAssertEqual(harness.policies, [.regular, .accessory])
    }

    func testMinimizationKeepsTheWindowRegistered() {
        let harness = Harness()
        let window = makeWindow()

        harness.coordinator.register(window)
        harness.notificationCenter.post(name: NSWindow.didMiniaturizeNotification, object: window)
        harness.runDeferred()
        XCTAssertEqual(harness.policies, [.regular])

        harness.notificationCenter.post(name: NSWindow.didDeminiaturizeNotification, object: window)
        harness.close(window)
        harness.runDeferred()
        XCTAssertEqual(harness.policies, [.regular, .accessory])
    }

    private func makeWindow() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                 styleMask: [.titled, .miniaturizable], backing: .buffered, defer: true)
    }

    private final class Harness {
        let notificationCenter = NotificationCenter()
        var policies: [NSApplication.ActivationPolicy] = []
        private var deferredActions: [() -> Void] = []
        lazy var coordinator = WindowActivationCoordinator(
            notificationCenter: notificationCenter,
            setPolicy: { [weak self] policy in
                self?.policies.append(policy)
                return true
            },
            scheduleDeferred: { [weak self] action in
                self?.deferredActions.append(action)
            }
        )

        func close(_ window: NSWindow) {
            notificationCenter.post(name: NSWindow.willCloseNotification, object: window)
        }

        func runDeferred() {
            let actions = deferredActions
            deferredActions.removeAll()
            actions.forEach { $0() }
        }
    }
}
