/// ArrangementStore.swift

import Foundation

/// The Arrangements folder: one JSON file per display set. File names are labels for people; the
/// display UUIDs inside each file are the identity. The folder is read on every use, so files added,
/// renamed or edited by hand are picked up without a relaunch.
final class ArrangementStore {

    struct Entry {
        var url: URL
        var arrangement: Arrangement
    }

    enum Lookup {
        /// A file listing exactly the connected displays.
        case exact(Entry)
        /// A file with the same pixel sizes but other UUIDs, already rewritten to the connected displays.
        case adopted(Entry)
    }

    let directory: URL

    init(directory: URL = ArrangementStore.defaultDirectory) {
        self.directory = directory
    }

    static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Tugboat/Arrangements", isDirectory: true)
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// Every readable arrangement in the folder. A file that does not parse or lists no displays is
    /// skipped with a line in the log.
    func loadAll() -> [Entry] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                do {
                    let arrangement = try Self.decoder.decode(Arrangement.self, from: Data(contentsOf: url))
                    guard !arrangement.displays.isEmpty else {
                        Logger.log("Arrangements: skipping \(url.lastPathComponent), it lists no displays")
                        return nil
                    }
                    return Entry(url: url, arrangement: arrangement)
                } catch {
                    Logger.log("Arrangements: skipping \(url.lastPathComponent): \(error)")
                    return nil
                }
            }
    }

    /// The arrangement for the connected displays: the file listing exactly their UUIDs (the most
    /// recently seen one when several do), otherwise a file with the same pixel sizes, adopted.
    static func lookup(_ connected: [DisplayIdentity], in entries: [Entry]) -> Lookup? {
        func mostRecent(_ candidates: [Entry]) -> Entry? {
            candidates.max { $0.arrangement.lastSeen < $1.arrangement.lastSeen }
        }
        let exact = entries.filter { DisplaySetMatch.isExact($0.arrangement.displays, connected) }
        if exact.count > 1 {
            Logger.log("Arrangements: \(exact.map(\.url.lastPathComponent)) claim the same displays; using the most recent")
        }
        if let entry = mostRecent(exact) {
            return .exact(entry)
        }
        let fallback = entries.filter { DisplaySetMatch.isFallback($0.arrangement.displays, connected) }
        if var entry = mostRecent(fallback) {
            entry.arrangement = adopt(entry.arrangement, to: connected)
            return .adopted(entry)
        }
        return nil
    }

    /// Rewrites a fallback match to the connected displays' identities. Each display keeps the geometry
    /// it had when the windows were saved, so their absolute frames are only used if nothing moved.
    static func adopt(_ arrangement: Arrangement, to connected: [DisplayIdentity]) -> Arrangement {
        let mapping = DisplaySetMatch.adoption(of: arrangement.displays, by: connected)
        var adopted = arrangement
        adopted.displays = arrangement.displays.map { old in
            guard var new = mapping[old.uuid] else { return old }
            new.origin = old.origin
            new.points = old.points
            return new
        }
        adopted.windows = arrangement.windows.map { record in
            var record = record
            if let new = mapping[record.display] {
                record.display = new.uuid
            }
            return record
        }
        return adopted
    }

    /// A path for a new arrangement file, named after the displays.
    func newFileURL(for displays: [DisplayIdentity]) -> URL {
        let taken = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        return directory.appendingPathComponent(DisplaySetMatch.fileName(for: displays, taken: taken))
    }

    /// Writes atomically: to a temporary file, then renamed over the old one.
    func write(_ arrangement: Arrangement, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(arrangement).write(to: url, options: .atomic)
    }
}
