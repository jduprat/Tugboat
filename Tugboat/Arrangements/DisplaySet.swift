/// DisplaySet.swift

import Cocoa

/// A display as an arrangement file records it. The UUID is the identity; the other fields let the
/// fallback match work and tell a person reading the file which monitor is which.
struct DisplayIdentity: Codable, Equatable {
    var uuid: String
    var name: String
    var builtIn: Bool
    var vendor: UInt32
    var model: UInt32
    var serial: UInt32
    /// Native panel size in pixels, which survives a change of scaled resolution.
    var pixels: [Int]
    /// Size in points in the current mode.
    var points: [Double]
    /// Top-left corner in the global coordinates the Accessibility API uses.
    var origin: [Double]
    var main: Bool

    /// Same place and same size in points, so absolute frames saved on it still land where they were.
    func hasSameGeometry(as other: DisplayIdentity) -> Bool {
        func close(_ a: [Double], _ b: [Double]) -> Bool {
            a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 0.5 }
        }
        return close(origin, other.origin) && close(points, other.points)
    }
}

/// A display connected right now, with the frames needed to place windows on it.
struct ConnectedDisplay {
    let identity: DisplayIdentity
    /// Full bounds, global coordinates with a top-left origin.
    let bounds: CGRect
    /// Bounds without the menu bar and Dock, same coordinates.
    let visibleFrame: CGRect

    static func current() -> [ConnectedDisplay] {
        NSScreen.screens.compactMap { screen -> ConnectedDisplay? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            // A mirror set counts once, as its primary.
            guard CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
            else { return nil }
            let bounds = CGDisplayBounds(id)
            let identity = DisplayIdentity(
                uuid: CFUUIDCreateString(nil, uuid) as String,
                name: screen.localizedName,
                builtIn: CGDisplayIsBuiltin(id) != 0,
                vendor: CGDisplayVendorNumber(id),
                model: CGDisplayModelNumber(id),
                serial: CGDisplaySerialNumber(id),
                pixels: nativePixelSize(id),
                points: [Double(bounds.width), Double(bounds.height)],
                origin: [Double(bounds.minX), Double(bounds.minY)],
                main: CGDisplayIsMain(id) != 0)
            return ConnectedDisplay(identity: identity, bounds: bounds, visibleFrame: screen.visibleFrame.screenFlipped)
        }
    }

    private static func nativePixelSize(_ id: CGDirectDisplayID) -> [Int] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
        let nativeFlag: UInt32 = 0x0200_0000 // kDisplayModeNativeFlag in IOGraphicsTypes.h
        if let native = modes.first(where: { $0.ioFlags & nativeFlag != 0 }) {
            return [native.pixelWidth, native.pixelHeight]
        }
        if let mode = CGDisplayCopyDisplayMode(id) {
            return [mode.pixelWidth, mode.pixelHeight]
        }
        return [Int(CGDisplayPixelsWide(id)), Int(CGDisplayPixelsHigh(id))]
    }
}

/// How a stored display set is recognised among the connected displays.
enum DisplaySetMatch {

    /// Exactly the same displays, in any order.
    static func isExact(_ stored: [DisplayIdentity], _ connected: [DisplayIdentity]) -> Bool {
        stored.count == connected.count && Set(stored.map(\.uuid)) == Set(connected.map(\.uuid))
    }

    /// Same number of displays with the same pixel sizes. This covers docks and KVMs that hand out a
    /// fresh UUID on every reconnect.
    static func isFallback(_ stored: [DisplayIdentity], _ connected: [DisplayIdentity]) -> Bool {
        stored.count == connected.count && sortedSizes(stored) == sortedSizes(connected)
    }

    private static func sortedSizes(_ displays: [DisplayIdentity]) -> [[Int]] {
        displays.map(\.pixels).sorted { $0.lexicographicallyPrecedes($1) }
    }

    /// For a fallback match, the connected display that takes the place of each stored one, keyed by
    /// the stored UUID: same pixel size, built-in for built-in where possible, then the nearest origin.
    static func adoption(of stored: [DisplayIdentity], by connected: [DisplayIdentity]) -> [String: DisplayIdentity] {
        var available = connected
        var mapping = [String: DisplayIdentity]()
        for display in stored {
            let candidates = available.indices.filter { available[$0].pixels == display.pixels }
            guard let best = candidates.min(by: { rank(available[$0], for: display) < rank(available[$1], for: display) })
            else { continue }
            mapping[display.uuid] = available.remove(at: best)
        }
        return mapping
    }

    private static func rank(_ candidate: DisplayIdentity, for display: DisplayIdentity) -> (Int, Double) {
        let dx = (candidate.origin.first ?? 0) - (display.origin.first ?? 0)
        let dy = (candidate.origin.last ?? 0) - (display.origin.last ?? 0)
        return (candidate.builtIn == display.builtIn ? 0 : 1, dx * dx + dy * dy)
    }

    /// The file name for a new arrangement: display names, built-in first and then left to right,
    /// joined with " + ", without characters macOS rejects in file names, and with a counter when a
    /// file of that name already exists. Only used once, when the file is created.
    static func fileName(for displays: [DisplayIdentity], taken: Set<String>) -> String {
        func order(_ d: DisplayIdentity) -> (Int, Double, Double) {
            (d.builtIn ? 0 : 1, d.origin.first ?? 0, d.origin.last ?? 0)
        }
        var base = displays.sorted { order($0) < order($1) }
            .map(\.name)
            .joined(separator: " + ")
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: ":", with: "")
            .trimmingCharacters(in: .whitespaces)
        while base.hasPrefix(".") { base.removeFirst() }
        if base.isEmpty { base = "Displays" }

        let takenNames = Set(taken.map { $0.lowercased() })
        var name = base + ".json"
        var counter = 2
        while takenNames.contains(name.lowercased()) {
            name = "\(base) (\(counter)).json"
            counter += 1
        }
        return name
    }
}
