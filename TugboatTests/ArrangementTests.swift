/// ArrangementTests.swift

import XCTest
@testable import Tugboat

class ArrangementTests: XCTestCase {

    private func display(_ uuid: String, pixels: [Int] = [2560, 1440], origin: [Double] = [0, 0],
                         points: [Double] = [2560, 1440], builtIn: Bool = false, name: String = "Monitor") -> DisplayIdentity {
        DisplayIdentity(uuid: uuid, name: name, builtIn: builtIn, vendor: 1, model: 2, serial: 0,
                        pixels: pixels, points: points, origin: origin, main: origin == [0, 0])
    }

    /// A connected display whose visible frame loses a 25-point menu bar at the top.
    private func connected(_ identity: DisplayIdentity) -> ConnectedDisplay {
        let bounds = CGRect(x: identity.origin[0], y: identity.origin[1], width: identity.points[0], height: identity.points[1])
        return ConnectedDisplay(identity: identity, bounds: bounds,
                                visibleFrame: CGRect(x: bounds.minX, y: bounds.minY + 25, width: bounds.width, height: bounds.height - 25))
    }

    private func record(_ app: String, title: String?, ordinal: Int = 0, display: String = "A", pattern: String? = nil,
                        points: CGRect = CGRect(x: 0, y: 25, width: 100, height: 100)) -> WindowRecord {
        WindowRecord(app: app, title: title, titlePattern: pattern, subrole: "AXStandardWindow", ordinal: ordinal,
                     display: display, frame: RecordRect(x: 0, y: 0, w: 0.5, h: 1), points: RecordRect(points),
                     lastAction: nil, lastSeen: Date(timeIntervalSince1970: 0), pinned: false)
    }

    private func live(_ app: String, title: String?, x: CGFloat = 0, y: CGFloat = 25) -> LiveWindow {
        LiveWindow(app: app, title: title, subrole: "AXStandardWindow", frame: CGRect(x: x, y: y, width: 100, height: 100))
    }

    func testExactMatchIgnoresOrderAndFallbackNeedsSamePixelSizes() {
        let laptop = display("L", pixels: [3024, 1964], builtIn: true)
        let studio = display("S", pixels: [5120, 2880], origin: [1512, -458])
        XCTAssertTrue(DisplaySetMatch.isExact([laptop, studio], [studio, laptop]))
        XCTAssertFalse(DisplaySetMatch.isExact([laptop, studio], [laptop]))

        var reconnected = studio
        reconnected.uuid = "S2"
        XCTAssertFalse(DisplaySetMatch.isExact([laptop, studio], [laptop, reconnected]))
        XCTAssertTrue(DisplaySetMatch.isFallback([laptop, studio], [reconnected, laptop]))
        var other = studio
        other.pixels = [3840, 2160]
        XCTAssertFalse(DisplaySetMatch.isFallback([laptop, studio], [laptop, other]))
    }

    func testLookupPrefersMostRecentExactMatchThenAdoptsFallback() throws {
        let a = display("A")
        func entry(_ name: String, seen: TimeInterval) -> ArrangementStore.Entry {
            ArrangementStore.Entry(url: URL(fileURLWithPath: "/tmp/\(name).json"),
                                   arrangement: Arrangement(name: name, lastSeen: Date(timeIntervalSince1970: seen),
                                                            displays: [a], windows: [record("app", title: "t")]))
        }
        let old = entry("old", seen: 1)
        let recent = entry("recent", seen: 2)

        guard case .exact(let found)? = ArrangementStore.lookup([a], in: [old, recent]) else { return XCTFail("no exact match") }
        XCTAssertEqual(found.arrangement.name, "recent")

        var reconnected = a
        reconnected.uuid = "A2"
        reconnected.origin = [100, 0]
        guard case .adopted(let adopted)? = ArrangementStore.lookup([reconnected], in: [old]) else { return XCTFail("no fallback") }
        XCTAssertEqual(adopted.arrangement.displays.map(\.uuid), ["A2"])
        XCTAssertEqual(adopted.arrangement.displays[0].origin, [0, 0], "keeps the geometry the windows were saved on")
        XCTAssertEqual(adopted.arrangement.windows[0].display, "A2")
    }

    func testFileNamesPutBuiltInFirstDropBadCharactersAndCount() {
        let laptop = display("L", builtIn: true, name: "Built-in Retina Display")
        let left = display("X", origin: [-2560, 0], name: "DELL U2723QE")
        let right = display("Y", origin: [1512, 0], name: "LG: 27/UL")
        XCTAssertEqual(DisplaySetMatch.fileName(for: [right, left, laptop], taken: []),
                       "Built-in Retina Display + DELL U2723QE + LG 27UL.json")
        XCTAssertEqual(DisplaySetMatch.fileName(for: [laptop], taken: ["built-in retina display.json"]),
                       "Built-in Retina Display (2).json")
    }

    func testMatchingUsesTitleThenOrdinalThenSubrole() {
        let records = [
            record("com.apple.Terminal", title: "bash", ordinal: 1, points: CGRect(x: 500, y: 25, width: 100, height: 100)),
            record("com.apple.Terminal", title: "bash", ordinal: 0),
            record("com.apple.Safari", title: "Old title"),
        ]
        let windows = [
            live("com.apple.Terminal", title: "bash", x: 800),
            live("com.apple.Safari", title: "New title"),
            live("com.apple.Terminal", title: "bash", x: 10),
        ]
        XCTAssertEqual(WindowMatcher.match(windows, to: records), [2: 1, 0: 0, 1: 2])
    }

    func testTitlePatternIsTriedBeforeExactTitle() {
        let records = [
            record("com.apple.Safari", title: "GitHub", pattern: "^GitHub - "),
            record("com.apple.Safari", title: "GitHub - jduprat/Tugboat"),
        ]
        XCTAssertEqual(WindowMatcher.match([live("com.apple.Safari", title: "GitHub - jduprat/Tugboat")], to: records), [0: 0])
    }

    func testOrdinalsRankSameTitledWindowsLeftToRight() {
        let windows = [live("t", title: "bash", x: 300), live("t", title: "bash", x: 0), live("t", title: "zsh", x: 100)]
        XCTAssertEqual(WindowMatcher.ordinals(of: windows), [1, 0, 0])
    }

    func testRestoreUsesAbsoluteFrameOnlyWhileDisplayGeometryIsUnchanged() {
        let stored = display("A")
        let screen = connected(stored)
        let window = live("app", title: "doc", x: 1280)
        var arrangement = Arrangement(name: "A", lastSeen: Date(), displays: [stored], windows: [])
        arrangement.capture([window], on: [screen], at: Date())

        XCTAssertEqual(arrangement.windows.count, 1)
        XCTAssertEqual(arrangement.windows[0].frame, RecordRect(x: 0.5, y: 0, w: 100.0 / 2560, h: 100.0 / 1415))
        XCTAssertEqual(arrangement.placements(for: [window], on: [screen]), [0: window.frame])

        var rescaled = stored
        rescaled.points = [1280, 720]
        XCTAssertEqual(arrangement.placements(for: [window], on: [connected(rescaled)])[0]?.minX, 640)
    }

    func testCaptureKeepsClosedWindowsAndLeavesPinnedRecordsAlone() {
        let a = display("A")
        var pinned = record("app", title: "pinned", points: CGRect(x: 10, y: 35, width: 50, height: 50))
        pinned.pinned = true
        let closed = record("other", title: "closed")
        var arrangement = Arrangement(name: "A", lastSeen: Date(timeIntervalSince1970: 0), displays: [a], windows: [pinned, closed])
        arrangement.capture([live("app", title: "pinned", x: 900)], on: [connected(a)], at: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(arrangement.windows.count, 2)
        XCTAssertEqual(arrangement.windows[0].points, pinned.points)
        XCTAssertEqual(arrangement.windows[0].lastSeen, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(arrangement.windows[1], closed)
    }

    func testFileRoundTripsAndToleratesMissingKeys() throws {
        let arrangement = Arrangement(name: "A", lastSeen: Date(timeIntervalSince1970: 1_000_000),
                                      displays: [display("A")], windows: [record("app", title: nil)])
        let data = try ArrangementStore.encoder.encode(arrangement)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"titlePattern\" : null"))
        let decoded = try ArrangementStore.decoder.decode(Arrangement.self, from: data)
        XCTAssertEqual(decoded.windows, arrangement.windows)
        XCTAssertEqual(decoded.displays, arrangement.displays)

        let handWritten = #"{"app": "x", "display": "A", "frame": {"x": 0, "y": 0, "w": 1, "h": 1}, "points": {"x": 0, "y": 0, "w": 10, "h": 10}}"#
        let minimal = try ArrangementStore.decoder.decode(WindowRecord.self, from: Data(handWritten.utf8))
        XCTAssertEqual(minimal.ordinal, 0)
        XCTAssertFalse(minimal.pinned)
    }

    func testStoreSkipsUnreadableFilesAndNamesNewOnesUniquely() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ArrangementStore(directory: directory)
        let arrangement = Arrangement(name: "Monitor", lastSeen: Date(timeIntervalSince1970: 0), displays: [display("A")], windows: [])
        try store.write(arrangement, to: store.newFileURL(for: arrangement.displays))
        try Data("not json".utf8).write(to: directory.appendingPathComponent("broken.json"))

        XCTAssertEqual(store.loadAll().map(\.url.lastPathComponent), ["Monitor.json"])
        XCTAssertEqual(store.newFileURL(for: arrangement.displays).lastPathComponent, "Monitor (2).json")
    }
}
