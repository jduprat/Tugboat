import Cocoa
import XCTest
@testable import Tugboat

final class DynamicLayoutTests: XCTestCase {
    private final class Element: AccessibilityElement {
        var rect: CGRect
        let name: String
        init(_ index: Int, title: String, frame: CGRect) {
            self.name = title; self.rect = frame
            super.init(AXUIElementCreateApplication(pid_t(20_000 + index)))
        }
        override var frame: CGRect { rect }
        override var bundleIdentifier: String? { "com.apple.Terminal" }
        override var title: String? { name }
        override var subrole: NSAccessibility.Subrole? { .standardWindow }
        override var minimumSize: CGSize? { .zero }
        override func isResizable() -> Bool { true }
        override func setFrame(_ frame: CGRect, adjustSizeFirst: Bool = true) { rect = frame }
    }
    private final class Screen: NSScreen {
        let rect: CGRect
        init(_ rect: CGRect) { self.rect = rect; super.init() }
        override var frame: CGRect { rect }
        override var visibleFrame: CGRect { rect }
        override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }
        override var backingScaleFactor: CGFloat { 1 }
        override func convertRectToBacking(_ rect: CGRect) -> CGRect { rect }
        override func convertRectFromBacking(_ rect: CGRect) -> CGRect { rect }
    }
    private func snapshot(_ element: Element) -> MultiWindowManager.TilingWindow {
        .init(element: element, frame: element.frame, windowId: nil, pid: nil, isFocused: false)
    }
    private func display(_ screen: NSScreen) -> ConnectedDisplay {
        let bounds = screen.frame.screenFlipped
        return ConnectedDisplay(identity: DisplayIdentity(uuid: "External", name: "Monitor", builtIn: false,
            vendor: 1, model: 1, serial: 1, pixels: [3000, 2000], points: [Double(bounds.width), Double(bounds.height)],
            origin: [Double(bounds.minX), Double(bounds.minY)], main: true), bounds: bounds, visibleFrame: bounds)
    }

    func testSurvivorsRetainSlotsAndNewMembersAppend() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        XCTAssertEqual(DynamicLayout.orderedIDs(previous: [a,b,c], selected: [c,d,a]), [a,c,d])
    }

    func testWeightedBandsKeepProportionsAndFillEveryPixel() {
        XCTAssertEqual(DynamicLayout.lengths(total: 1000, weights: [1,2,1], minimums: [0,0,0], maximums: [1000,1000,1000]), [250,500,250])
        let small = DynamicLayout.lengths(total: 601, weights: [1,2,1], minimums: [0,0,0], maximums: [601,601,601])
        XCTAssertEqual(small.reduce(0,+), 601)
        XCTAssertEqual(small, [150,301,150])
    }

    func testWeightedBandsRespectFixedSizesAndMinimumsWhenFeasible() {
        XCTAssertEqual(DynamicLayout.lengths(total: 1000, weights: [1,1,1], minimums: [400,100,0], maximums: [1000,100,1000]), [450,100,450])
        XCTAssertEqual(DynamicLayout.lengths(total: 1000, weights: [1,1,1], minimums: [600,0,0], maximums: [1000,1000,1000]), [600,200,200])
    }

    func testImpossibleMinimumsKeepDeclaredColumnTargets() {
        XCTAssertEqual(DynamicLayout.lengths(total: 600, weights: [1,2,1], minimums: [400,400,400], maximums: [600,600,600]), [150,300,150])
    }

    func testSameSessionOrderSurvivesShuffledGeometryAndTemporaryReflowDoesNotOverwriteIntent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let big = Screen(CGRect(x: 0,y: 0,width: 2000,height: 1200))
        let manager = DynamicLayoutManager(url: directory.appendingPathComponent("groups.json"), connectedDisplays: { [self.display(big)] }, layoutEnabled: { true })
        manager.start(observeDisplays: false)
        let a = Element(1, title: "bash", frame: CGRect(x: 0,y: 0,width: 500,height: 1200))
        let b = Element(2, title: "bash", frame: CGRect(x: 500,y: 0,width: 1000,height: 1200))
        let c = Element(3, title: "bash", frame: CGRect(x: 1500,y: 0,width: 500,height: 1200))
        manager.remember([a,b,c].map(snapshot), kind: .columns, app: "com.apple.Terminal", screen: big)
        let saved = manager.layouts
        let savedData = try Data(contentsOf: directory.appendingPathComponent("groups.json"))
        a.rect.origin.x = 1000; b.rect.origin.x = 50; c.rect.origin.x = 300
        let ordered = manager.ordered([b,c,a].map(snapshot), kind: .columns, screen: big)
        XCTAssertEqual(ordered.map(\.element), [a,b,c])
        let small = Screen(CGRect(x: -900,y: -600,width: 900,height: 600))
        let members = zip(saved[0].members, [a,b,c]).map { ($0.0, $0.1 as AccessibilityElement) }
        manager.apply(members, kind: .columns, screen: small)
        XCTAssertLessThan(a.frame.minX, b.frame.minX); XCTAssertLessThan(b.frame.minX, c.frame.minX)
        XCTAssertEqual(a.frame.width, 225); XCTAssertEqual(b.frame.width, 450)
        XCTAssertEqual(manager.layouts, saved)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("groups.json")), savedData)
        manager.apply(members, kind: .columns, screen: big)
        XCTAssertEqual(a.frame.width, 500); XCTAssertEqual(b.frame.width, 1000)
        manager.release(b)
        XCTAssertEqual(manager.layouts[0].members.map(\.id), [saved[0].members[0].id,saved[0].members[2].id])
    }

    func testReconnectRestoresPreferredDisplayAndMovingGroupUpdatesOnlyExplicitIntent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let big = Screen(CGRect(x: 1000,y: 0,width: 2000,height: 1200))
        let laptop = Screen(CGRect(x: 0,y: 0,width: 900,height: 600))
        let detectedLaptop = display(laptop)
        var laptopIdentity = detectedLaptop.identity; laptopIdentity.uuid = "Laptop"
        let laptopDisplay = ConnectedDisplay(identity: laptopIdentity, bounds: detectedLaptop.bounds, visibleFrame: detectedLaptop.visibleFrame)
        let external = display(big)
        var screens: [NSScreen] = [big,laptop]
        var connected = [external,laptopDisplay]
        let a = Element(1, title: "A", frame: CGRect(x: 1000,y: 0,width: 1000,height: 1200))
        let b = Element(2, title: "B", frame: CGRect(x: 2000,y: 0,width: 1000,height: 1200))
        let manager = DynamicLayoutManager(url: directory.appendingPathComponent("groups.json"),
            connectedDisplays: { connected }, screens: { screens }, eligibleWindows: { [a,b] }, layoutEnabled: { true })
        manager.start(observeDisplays: false)
        manager.remember([a,b].map(snapshot), kind: .columns, app: "com.apple.Terminal", screen: big)
        let intent = manager.layouts
        screens = [laptop]; connected = [laptopDisplay]
        a.rect.origin.x = 500; b.rect.origin.x = 0
        manager.reflow(restoringRecordedPositions: false)
        XCTAssertEqual(a.frame.minX, 0); XCTAssertEqual(b.frame.minX, 450)
        XCTAssertEqual(manager.layouts, intent)
        screens = [laptop,big]; connected = [laptopDisplay,external]
        manager.reflow(restoringRecordedPositions: false)
        XCTAssertEqual(a.frame.minX, 1000); XCTAssertEqual(b.frame.minX, 2000)
        XCTAssertEqual(manager.layouts, intent)
        XCTAssertTrue(manager.moveGroup(containing: b, to: laptop))
        XCTAssertEqual(manager.layouts[0].preferredDisplay, "Laptop")
        XCTAssertEqual(manager.layouts[0].members, intent[0].members)
        XCTAssertEqual(a.frame.minX, 0); XCTAssertEqual(b.frame.minX, 450)
    }

    func testRelaunchUsesUniqueTitlesButDoesNotGuessRepeatedTitleOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screen = Screen(CGRect(x: 0,y: 0,width: 1200,height: 800))
        let url = directory.appendingPathComponent("groups.json")
        let first = DynamicLayoutManager(url: url, connectedDisplays: { [self.display(screen)] }, layoutEnabled: { true })
        first.start(observeDisplays: false)
        let old = [Element(1,title: "unique",frame: CGRect(x: 0,y: 0,width: 400,height: 800)),
                   Element(2,title: "bash",frame: CGRect(x: 400,y: 0,width: 400,height: 800)),
                   Element(3,title: "bash",frame: CGRect(x: 800,y: 0,width: 400,height: 800))]
        first.remember(old.map(snapshot), kind: .columns, app: "com.apple.Terminal", screen: screen)
        let second = DynamicLayoutManager(url: url, layoutEnabled: { true })
        second.start(observeDisplays: false)
        let new = [Element(4,title: "bash",frame: old[0].frame),Element(5,title: "unique",frame: old[1].frame),
                   Element(6,title: "bash",frame: old[2].frame)]
        second.resolveMembers(from: new)
        XCTAssertEqual(second.memberIDs(for: new), [nil, first.layouts[0].members[0].id, nil])
    }

    func testCorruptSavedGroupsAreIgnoredAndExtremeWeightsRemainSafe() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let member = DynamicLayout.Member(id: UUID(), app: "app", title: nil, subrole: nil, proportion: 1)
        let group = DynamicLayout(id: UUID(), kind: .columns, app: "app", preferredDisplay: "D", members: [member,member])
        try JSONEncoder().encode([group]).write(to: url)
        let manager = DynamicLayoutManager(url: url, layoutEnabled: { true })
        manager.start(observeDisplays: false)
        XCTAssertTrue(manager.layouts.isEmpty)
        let lengths = DynamicLayout.lengths(total: 600, weights: [1e-300,1e300], minimums: [0,0], maximums: [600,600])
        XCTAssertEqual(lengths.reduce(0,+), 600)
        XCTAssertEqual(lengths, [0,600])
    }

    func testRecoveryNeedsReachableTitleBarAndKeepsSafeWindowsAlone() {
        let display = CGRect(x: 0,y: 25,width: 1000,height: 700)
        let safe = CGRect(x: 100,y: 100,width: 500,height: 300)
        XCTAssertNil(WindowRecovery.target(for: safe, visibleFrames: [display]))
        let sliver = CGRect(x: 990,y: 100,width: 500,height: 300)
        XCTAssertEqual(WindowRecovery.target(for: sliver, visibleFrames: [display]), CGRect(x: 500,y: 100,width: 500,height: 300))
        let buriedTitle = CGRect(x: 200,y: -300,width: 500,height: 500)
        XCTAssertEqual(WindowRecovery.target(for: buriedTitle, visibleFrames: [display])?.minY, 25)
    }

    func testRecoveryHandlesNegativeOriginsAndOversizedFixedWindows() {
        let display = CGRect(x: -900,y: -700,width: 900,height: 600)
        let lost = CGRect(x: 3000,y: 2000,width: 1400,height: 1000)
        let target = WindowRecovery.target(for: lost, visibleFrames: [display], minimumSize: CGSize(width: 1200,height: 800))
        XCTAssertEqual(target, CGRect(x: -900,y: -700,width: 1200,height: 800))
        let fixed = WindowRecovery.target(for: lost, visibleFrames: [display], resizable: false)
        XCTAssertEqual(fixed?.size, lost.size)
        XCTAssertEqual(fixed?.origin, display.origin)
    }

    func testRecoveryIgnoresInvalidFramesAndEmptyDisplays() {
        XCTAssertNil(WindowRecovery.target(for: .null, visibleFrames: [CGRect(x: 0,y: 0,width: 100,height: 100)]))
        XCTAssertNil(WindowRecovery.target(for: CGRect(x: 0,y: 0,width: 100,height: 100), visibleFrames: []))
    }
}
