import Cocoa
import XCTest
@testable import Tugboat

final class WindowCreationManagerTests: XCTestCase {
    private final class Element: AccessibilityElement {
        var rect: CGRect
        let processID: pid_t
        var requestedFrames: [CGRect] = []
        var appliesFrames = true

        init(_ processID: pid_t, frame: CGRect) {
            self.processID = processID
            rect = frame
            super.init(AXUIElementCreateApplication(processID))
        }

        override var pid: pid_t? { processID }
        override var frame: CGRect { rect }
        override var minimumSize: CGSize? { .zero }
        override func isResizable() -> Bool { true }
        override func setFrame(_ frame: CGRect, adjustSizeFirst: Bool = true) {
            requestedFrames.append(frame)
            if appliesFrames { rect = frame }
        }
    }

    private final class Scheduler {
        private var now: TimeInterval = 0
        private var tasks: [(deadline: TimeInterval, action: () -> Void)] = []

        func schedule(_ delay: TimeInterval, action: @escaping () -> Void) {
            tasks.append((now + delay, action))
        }

        func advance(to time: TimeInterval) {
            while let index = tasks.indices.min(by: { tasks[$0].deadline < tasks[$1].deadline }),
                  tasks[index].deadline <= time {
                let task = tasks.remove(at: index)
                now = task.deadline
                task.action()
            }
            now = time
        }
    }

    private let display = CGRect(x: 0, y: 25, width: 1000, height: 700)

    private func mouseEvent(_ type: CGEventType) -> NSEvent {
        NSEvent(cgEvent: CGEvent(mouseEventSource: nil, mouseType: type,
                                mouseCursorPosition: .zero, mouseButton: .left)!)!
    }

    func testHeldClickIsNotTreatedAsADrag() {
        XCTAssertFalse(WindowCreationManager.isDragInProgress(leftButtonDown: true,
            secondsSinceMouseDown: 0.01, secondsSinceMouseDragged: 2))
        XCTAssertTrue(WindowCreationManager.isDragInProgress(leftButtonDown: true,
            secondsSinceMouseDown: 0.2, secondsSinceMouseDragged: 0.01))
        XCTAssertFalse(WindowCreationManager.isDragInProgress(leftButtonDown: false,
            secondsSinceMouseDown: 0.2, secondsSinceMouseDragged: 0.01))
    }

    func testOnlyTheCreatedWindowIsFitted() {
        let oversized = CGRect(x: 100, y: 100, width: 1400, height: 1000)
        let created = Element(20_001, frame: oversized)
        let existing = Element(20_002, frame: oversized)
        let scheduler = Scheduler()
        let manager = WindowCreationManager(eligibleWindows: { [created, existing] }, visibleFrames: { [self.display] },
            dragInProgress: { false },
            schedule: { scheduler.schedule($0, action: $1) })
        manager.start(observeSystem: false)
        manager.windowCreated(created)
        scheduler.advance(to: 1)

        XCTAssertTrue(display.contains(created.frame))
        XCTAssertEqual(created.frame.size, CGSize(width: 900, height: 630))
        XCTAssertEqual(created.requestedFrames.count, 1)
        XCTAssertEqual(existing.frame, oversized)
        XCTAssertTrue(existing.requestedFrames.isEmpty)
    }

    func testInitialFrameAndEligibilityCanSettleAfterCreation() {
        let created = Element(20_001, frame: .null)
        var eligible: [AccessibilityElement] = []
        let scheduler = Scheduler()
        let manager = WindowCreationManager(eligibleWindows: { eligible }, visibleFrames: { [self.display] },
            dragInProgress: { false },
            schedule: { scheduler.schedule($0, action: $1) })
        manager.start(observeSystem: false)
        manager.windowCreated(created)
        scheduler.advance(to: 0.1)

        created.rect = CGRect(x: 100, y: 100, width: 500, height: 300)
        eligible = [created]
        scheduler.advance(to: 0.4)
        XCTAssertTrue(created.requestedFrames.isEmpty)

        created.rect = CGRect(x: 100, y: 100, width: 1400, height: 1000)
        scheduler.advance(to: 1)
        XCTAssertTrue(display.contains(created.frame))
        XCTAssertEqual(created.frame.size, CGSize(width: 900, height: 630))
    }

    func testDuplicateCreationEventsDoNotExtendTheSettlingPeriod() {
        let oversized = CGRect(x: 100, y: 100, width: 1400, height: 1000)
        let created = Element(20_001, frame: oversized)
        let scheduler = Scheduler()
        let manager = WindowCreationManager(eligibleWindows: { [created] }, visibleFrames: { [self.display] },
            dragInProgress: { false },
            schedule: { scheduler.schedule($0, action: $1) })
        manager.start(observeSystem: false)
        manager.windowCreated(created)
        scheduler.advance(to: 0.5)
        manager.windowCreated(created)
        scheduler.advance(to: 1)

        created.rect = oversized
        scheduler.advance(to: 1.6)
        XCTAssertEqual(created.frame, oversized)
        scheduler.advance(to: 10)
        XCTAssertEqual(created.frame, oversized)
    }

    func testStoppingCancelsPendingCreationChecks() {
        let oversized = CGRect(x: 100, y: 100, width: 1400, height: 1000)
        let created = Element(20_001, frame: oversized)
        let scheduler = Scheduler()
        let manager = WindowCreationManager(eligibleWindows: { [created] }, visibleFrames: { [self.display] },
            dragInProgress: { false },
            schedule: { scheduler.schedule($0, action: $1) })
        manager.start(observeSystem: false)
        manager.windowCreated(created)
        manager.stop()
        scheduler.advance(to: 10)

        XCTAssertEqual(created.frame, oversized)
        XCTAssertTrue(created.requestedFrames.isEmpty)
    }

    func testAWindowOutsideTheEligibleSnapshotIsLeftAlone() {
        let oversized = CGRect(x: 100, y: 100, width: 1400, height: 1000)
        let created = Element(20_001, frame: oversized)
        let scheduler = Scheduler()
        let manager = WindowCreationManager(eligibleWindows: { [] }, visibleFrames: { [self.display] },
            dragInProgress: { false },
            schedule: { scheduler.schedule($0, action: $1) })
        manager.start(observeSystem: false)
        manager.windowCreated(created)
        scheduler.advance(to: 10)

        XCTAssertEqual(created.frame, oversized)
        XCTAssertTrue(created.requestedFrames.isEmpty)
    }

    func testDraggingCancelsOnlyThatWindowAndCannotBeRearmedDuringSettling() {
        let dragged = Element(20_001, frame: CGRect(x: 100, y: 100, width: 500, height: 300))
        let other = Element(20_002, frame: CGRect(x: 100, y: 100, width: 1400, height: 1000))
        let scheduler = Scheduler()
        let manager = WindowCreationManager(eligibleWindows: { [dragged, other] }, visibleFrames: { [self.display] },
            windowAtLocation: { _ in dragged },
            dragInProgress: { false },
            schedule: { scheduler.schedule($0, action: $1) })
        manager.start(observeSystem: false)
        manager.windowCreated(dragged)
        manager.windowCreated(other)
        manager.handleMouseEvent(mouseEvent(.leftMouseDown))
        manager.handleMouseEvent(mouseEvent(.leftMouseDragged))
        let offscreen = CGRect(x: 800, y: 500, width: 500, height: 300)
        dragged.rect = offscreen
        scheduler.advance(to: 0.5)
        manager.windowCreated(dragged)
        scheduler.advance(to: 1.6)

        XCTAssertEqual(dragged.frame, offscreen)
        XCTAssertTrue(dragged.requestedFrames.isEmpty)
        XCTAssertTrue(display.contains(other.frame))
        XCTAssertEqual(other.frame.size, CGSize(width: 900, height: 630))
    }

    func testWindowDiscoveredDuringDragIsLeftAlone() {
        let offscreen = CGRect(x: 800, y: 500, width: 500, height: 300)
        let dragged = Element(20_001, frame: offscreen)
        let scheduler = Scheduler()
        let manager = WindowCreationManager(eligibleWindows: { [dragged] }, visibleFrames: { [self.display] },
            windowAtLocation: { _ in dragged }, pointerLocation: { .zero }, dragInProgress: { true },
            schedule: { scheduler.schedule($0, action: $1) })
        manager.start(observeSystem: false)
        manager.windowCreated(dragged)
        scheduler.advance(to: 1.6)

        XCTAssertEqual(dragged.frame, offscreen)
        XCTAssertTrue(dragged.requestedFrames.isEmpty)
    }

    func testDragStartingDuringEligibilityLookupCancelsFit() {
        let oversized = CGRect(x: 100, y: 100, width: 1400, height: 1000)
        let dragged = Element(20_001, frame: oversized)
        var dragging = false
        let scheduler = Scheduler()
        let manager = WindowCreationManager(eligibleWindows: {
            dragging = true
            return [dragged]
        }, visibleFrames: { [self.display] }, windowAtLocation: { _ in dragged },
            pointerLocation: { .zero }, dragInProgress: { dragging },
            schedule: { scheduler.schedule($0, action: $1) })
        manager.start(observeSystem: false)
        manager.windowCreated(dragged)
        scheduler.advance(to: 1.6)

        XCTAssertEqual(dragged.frame, oversized)
        XCTAssertTrue(dragged.requestedFrames.isEmpty)
    }

    func testWindowOpeningPastRightEdgeIsMovedFullyOnScreenWithoutResizing() {
        let created = Element(20_001, frame: CGRect(x: 900, y: 100, width: 500, height: 300))
        let scheduler = Scheduler()
        let manager = WindowCreationManager(eligibleWindows: { [created] }, visibleFrames: { [self.display] },
            dragInProgress: { false }, schedule: { scheduler.schedule($0, action: $1) })
        manager.start(observeSystem: false)
        manager.windowCreated(created)
        scheduler.advance(to: 1)

        XCTAssertEqual(created.frame, CGRect(x: 500, y: 100, width: 500, height: 300))
        XCTAssertEqual(created.requestedFrames.count, 1)
    }

    func testNewWindowUsesOneStableOffsetWithoutResizing() {
        let original = CGRect(x: 100, y: 100, width: 500, height: 300)
        let created = Element(20_001, frame: original)
        let existing = Element(20_002, frame: original)
        let scheduler = Scheduler()
        let manager = WindowCreationManager(eligibleWindows: { [created, existing] }, visibleFrames: { [self.display] },
            dragInProgress: { false }, schedule: { scheduler.schedule($0, action: $1) })
        manager.start(observeSystem: false)
        manager.windowCreated(created)
        scheduler.advance(to: 1)

        XCTAssertTrue(display.contains(created.frame))
        XCTAssertEqual(created.frame.size, original.size)
        XCTAssertNotEqual(created.frame.origin, original.origin)
        XCTAssertEqual(created.requestedFrames.count, 1)
        XCTAssertEqual(existing.frame, original)
    }

    func testRapidCreationsReserveDifferentOriginsBeforeFramesUpdate() throws {
        let original = CGRect(x: 100, y: 100, width: 500, height: 300)
        let first = Element(20_001, frame: original)
        let second = Element(20_002, frame: original)
        first.appliesFrames = false
        second.appliesFrames = false
        let scheduler = Scheduler()
        let manager = WindowCreationManager(eligibleWindows: { [first, second] }, visibleFrames: { [self.display] },
            dragInProgress: { false }, schedule: { scheduler.schedule($0, action: $1) })
        manager.start(observeSystem: false)
        manager.windowCreated(first)
        manager.windowCreated(second)
        scheduler.advance(to: 0.1)

        let firstTarget = try XCTUnwrap(first.requestedFrames.first)
        let secondTarget = try XCTUnwrap(second.requestedFrames.first)
        XCTAssertNotEqual(firstTarget.origin, secondTarget.origin)
        XCTAssertTrue(display.contains(firstTarget))
        XCTAssertTrue(display.contains(secondTarget))
    }

    func testOversizedNewWindowRespectsMinimumSize() {
        let target = NewWindowPlacement.target(for: CGRect(x: 100, y: 100, width: 1400, height: 1000),
            visibleFrames: [display], occupiedOrigins: [], minimumSize: CGSize(width: 950, height: 680))
        XCTAssertEqual(target?.frame.size, CGSize(width: 950, height: 680))
        XCTAssertTrue(target.map { display.contains($0.frame) } == true)
    }

    func testPartialFrameUpdateKeepsTheChosenDisplay() throws {
        let left = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let right = CGRect(x: 1000, y: 0, width: 1000, height: 700)
        let first = try XCTUnwrap(NewWindowPlacement.target(
            for: CGRect(x: 500, y: 100, width: 1800, height: 300),
            visibleFrames: [left, right], occupiedOrigins: []))
        XCTAssertEqual(first.display, right)

        let partial = CGRect(x: 500, y: 100, width: 900, height: 300)
        let correction = try XCTUnwrap(NewWindowPlacement.target(for: partial,
            visibleFrames: [left, right], occupiedOrigins: [], resizable: false,
            preferredOrigin: first.frame.origin, preferredDisplay: first.display))
        XCTAssertEqual(correction.display, right)
        XCTAssertTrue(right.contains(correction.frame))

        let disconnected = try XCTUnwrap(NewWindowPlacement.target(for: partial,
            visibleFrames: [left], occupiedOrigins: [], resizable: false,
            preferredOrigin: first.frame.origin, preferredDisplay: first.display))
        XCTAssertEqual(disconnected.display, left)
        XCTAssertTrue(left.contains(disconnected.frame))
    }
}
