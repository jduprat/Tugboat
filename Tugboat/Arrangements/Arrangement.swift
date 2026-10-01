/// Arrangement.swift

import Foundation

/// All the window records for one display set: the contents of one file in the Arrangements folder.
struct Arrangement: Codable {
    var version = 1
    var name: String
    var lastSeen: Date
    var displays: [DisplayIdentity]
    var windows: [WindowRecord]
}

/// A rectangle as the file stores it.
struct RecordRect: Codable, Equatable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    init(_ rect: CGRect) {
        self.init(x: Double(rect.minX), y: Double(rect.minY), w: Double(rect.width), h: Double(rect.height))
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

/// One remembered window: how to recognise it again, which display it belongs on, and where it goes.
struct WindowRecord: Codable, Equatable {
    var app: String
    var title: String?
    /// An ICU regular expression a person can add for apps whose titles carry changing content.
    var titlePattern: String?
    var subrole: String?
    /// Rank by x then y among the app's windows with the same title.
    var ordinal: Int
    /// UUID of the display the window belongs on.
    var display: String
    /// Fractions of that display's visible frame, top-left origin.
    var frame: RecordRect
    /// Absolute frame in global points, top-left origin.
    var points: RecordRect
    var lastAction: String?
    var lastSeen: Date
    /// Capture never overwrites a pinned record; only a person changes it.
    var pinned: Bool

    enum CodingKeys: String, CodingKey {
        case app, title, titlePattern, subrole, ordinal, display, frame, points, lastAction, lastSeen, pinned
    }
}

// Files are edited by hand, so optional-looking keys may be missing, and empty keys are still
// written so people can see what there is to edit.
extension WindowRecord {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        app = try container.decode(String.self, forKey: .app)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        titlePattern = try container.decodeIfPresent(String.self, forKey: .titlePattern)
        subrole = try container.decodeIfPresent(String.self, forKey: .subrole)
        ordinal = try container.decodeIfPresent(Int.self, forKey: .ordinal) ?? 0
        display = try container.decode(String.self, forKey: .display)
        frame = try container.decode(RecordRect.self, forKey: .frame)
        points = try container.decode(RecordRect.self, forKey: .points)
        lastAction = try container.decodeIfPresent(String.self, forKey: .lastAction)
        lastSeen = try container.decodeIfPresent(Date.self, forKey: .lastSeen) ?? Date()
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(app, forKey: .app)
        try container.encode(title, forKey: .title)
        try container.encode(titlePattern, forKey: .titlePattern)
        try container.encode(subrole, forKey: .subrole)
        try container.encode(ordinal, forKey: .ordinal)
        try container.encode(display, forKey: .display)
        try container.encode(frame, forKey: .frame)
        try container.encode(points, forKey: .points)
        try container.encode(lastAction, forKey: .lastAction)
        try container.encode(lastSeen, forKey: .lastSeen)
        try container.encode(pinned, forKey: .pinned)
    }
}

/// A window on screen now, as the matcher sees it.
struct LiveWindow: Equatable {
    var app: String
    var title: String?
    var subrole: String?
    /// Global points, top-left origin.
    var frame: CGRect
}

/// Pairs live windows with window records.
enum WindowMatcher {

    private struct GroupKey: Hashable {
        let app: String
        let detail: String
    }

    /// Each window's rank by x then y among the app's windows with the same title, which tells two
    /// Terminal windows both titled "bash" apart.
    static func ordinals(of windows: [LiveWindow]) -> [Int] {
        var result = [Int](repeating: 0, count: windows.count)
        let groups = Dictionary(grouping: windows.indices) { GroupKey(app: windows[$0].app, detail: windows[$0].title ?? "") }
        for indices in groups.values {
            let ordered = indices.sorted { precedes(windows[$0].frame, windows[$1].frame) }
            for (rank, index) in ordered.enumerated() {
                result[index] = rank
            }
        }
        return result
    }

    /// Pairs each live window with at most one record of the same app, and each record with at most
    /// one window, in this order: title pattern, exact title, then accessibility subrole. Within a
    /// rule, windows in x-then-y order meet records in ordinal order. Returns record index by window index.
    static func match(_ windows: [LiveWindow], to records: [WindowRecord]) -> [Int: Int] {
        var pairs = [Int: Int]()
        var usedRecords = Set<Int>()

        let patterned = records.indices
            .filter { records[$0].titlePattern?.isEmpty == false }
            .sorted { (records[$0].app, records[$0].ordinal) < (records[$1].app, records[$1].ordinal) }
        for recordIndex in patterned {
            let record = records[recordIndex]
            guard let pattern = record.titlePattern,
                  let regex = try? NSRegularExpression(pattern: pattern)
            else { continue }
            let candidate = windows.indices
                .filter { index in
                    guard pairs[index] == nil, windows[index].app == record.app,
                          let title = windows[index].title else { return false }
                    return regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil
                }
                .min { precedes(windows[$0].frame, windows[$1].frame) }
            if let candidate {
                pairs[candidate] = recordIndex
                usedRecords.insert(recordIndex)
            }
        }

        func pairUp(windowKey: (LiveWindow) -> GroupKey?, recordKey: (WindowRecord) -> GroupKey?) {
            let windowGroups = Dictionary(grouping: windows.indices.filter { pairs[$0] == nil }) { windowKey(windows[$0]) }
            let recordGroups = Dictionary(grouping: records.indices.filter { !usedRecords.contains($0) }) { recordKey(records[$0]) }
            for (key, windowIndices) in windowGroups {
                guard key != nil, let recordIndices = recordGroups[key] else { continue }
                let orderedWindows = windowIndices.sorted { precedes(windows[$0].frame, windows[$1].frame) }
                let orderedRecords = recordIndices.sorted {
                    (records[$0].ordinal, records[$0].points.x, records[$0].points.y)
                        < (records[$1].ordinal, records[$1].points.x, records[$1].points.y)
                }
                for (windowIndex, recordIndex) in zip(orderedWindows, orderedRecords) {
                    pairs[windowIndex] = recordIndex
                    usedRecords.insert(recordIndex)
                }
            }
        }

        pairUp(windowKey: { window in window.title.flatMap { $0.isEmpty ? nil : GroupKey(app: window.app, detail: $0) } },
               recordKey: { record in record.title.flatMap { $0.isEmpty ? nil : GroupKey(app: record.app, detail: $0) } })
        pairUp(windowKey: { GroupKey(app: $0.app, detail: $0.subrole ?? "") },
               recordKey: { GroupKey(app: $0.app, detail: $0.subrole ?? "") })
        return pairs
    }

    private static func precedes(_ a: CGRect, _ b: CGRect) -> Bool {
        (a.minX, a.minY) < (b.minX, b.minY)
    }
}

/// Frames between global points and a display's visible frame.
enum ArrangementGeometry {

    static func relative(_ frame: CGRect, in visibleFrame: CGRect) -> RecordRect {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return RecordRect(x: 0, y: 0, w: 1, h: 1) }
        return RecordRect(x: Double((frame.minX - visibleFrame.minX) / visibleFrame.width),
                          y: Double((frame.minY - visibleFrame.minY) / visibleFrame.height),
                          w: Double(frame.width / visibleFrame.width),
                          h: Double(frame.height / visibleFrame.height))
    }

    static func absolute(_ rect: RecordRect, in visibleFrame: CGRect) -> CGRect {
        CGRect(x: visibleFrame.minX + CGFloat(rect.x) * visibleFrame.width,
               y: visibleFrame.minY + CGFloat(rect.y) * visibleFrame.height,
               width: CGFloat(rect.w) * visibleFrame.width,
               height: CGFloat(rect.h) * visibleFrame.height)
    }

    /// The display a window mostly covers, or the nearest one when it is off every display.
    static func displayIndex(for frame: CGRect, among bounds: [CGRect]) -> Int? {
        let areas = bounds.map { display -> CGFloat in
            let overlap = display.intersection(frame)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        if let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 {
            return best
        }
        func distance(_ display: CGRect) -> CGFloat {
            let dx = display.midX - frame.midX
            let dy = display.midY - frame.midY
            return dx * dx + dy * dy
        }
        return bounds.indices.min { distance(bounds[$0]) < distance(bounds[$1]) }
    }

    /// Where a record puts its window: the absolute frame when the display is where it was and as big
    /// as it was when the record was written, otherwise the relative frame on its visible frame now.
    static func target(for record: WindowRecord, stored: DisplayIdentity?, on display: ConnectedDisplay) -> CGRect {
        if let stored, stored.hasSameGeometry(as: display.identity) {
            return record.points.cgRect
        }
        return absolute(record.frame, in: display.visibleFrame)
    }
}

extension Arrangement {

    /// Records the windows on screen now. Matched records are updated (pinned ones are only marked as
    /// seen), new windows are added, and records of windows that are not open stay in the file.
    mutating func capture(_ live: [LiveWindow], on connected: [ConnectedDisplay], at date: Date) {
        let previousDisplays = displays
        let originalCount = windows.count
        let matches = WindowMatcher.match(live, to: windows)
        let ordinals = WindowMatcher.ordinals(of: live)
        var refreshed = Set<Int>()

        for (index, window) in live.enumerated() {
            guard let displayIndex = ArrangementGeometry.displayIndex(for: window.frame, among: connected.map(\.bounds))
            else { continue }
            let display = connected[displayIndex]
            var fresh = WindowRecord(
                app: window.app, title: window.title, titlePattern: nil, subrole: window.subrole,
                ordinal: ordinals[index], display: display.identity.uuid,
                frame: ArrangementGeometry.relative(window.frame, in: display.visibleFrame),
                points: RecordRect(window.frame), lastAction: nil, lastSeen: date, pinned: false)
            if let recordIndex = matches[index] {
                if windows[recordIndex].pinned {
                    windows[recordIndex].lastSeen = date
                } else {
                    fresh.titlePattern = windows[recordIndex].titlePattern
                    windows[recordIndex] = fresh
                    refreshed.insert(recordIndex)
                }
            } else {
                windows.append(fresh)
            }
        }

        // A record left as it was keeps its relative frame. If its display has moved or changed size,
        // its absolute frame is recomputed so it stays valid next to the new display geometry.
        for index in 0..<originalCount where !refreshed.contains(index) {
            let uuid = windows[index].display
            guard let before = previousDisplays.first(where: { $0.uuid == uuid }),
                  let now = connected.first(where: { $0.identity.uuid == uuid }),
                  !before.hasSameGeometry(as: now.identity)
            else { continue }
            windows[index].points = RecordRect(ArrangementGeometry.absolute(windows[index].frame, in: now.visibleFrame))
        }

        displays = connected.map(\.identity)
        lastSeen = date
    }

    /// Where each live window goes, by window index, for windows whose record is on a connected display.
    func placements(for live: [LiveWindow], on connected: [ConnectedDisplay]) -> [Int: CGRect] {
        var result = [Int: CGRect]()
        for (windowIndex, recordIndex) in WindowMatcher.match(live, to: windows) {
            let record = windows[recordIndex]
            guard let display = connected.first(where: { $0.identity.uuid == record.display }) else { continue }
            let stored = displays.first { $0.uuid == record.display }
            result[windowIndex] = ArrangementGeometry.target(for: record, stored: stored, on: display)
        }
        return result
    }
}
