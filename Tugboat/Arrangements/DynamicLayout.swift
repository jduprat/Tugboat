import Cocoa

/// Layout intent is independent of current frames and of recorded display arrangements.
struct DynamicLayout: Codable, Equatable {
    enum Kind: String, Codable { case rows, columns }
    struct Member: Codable, Equatable {
        var id: UUID
        var app: String
        var title: String?
        var subrole: String?
        var proportion: Double
    }
    var id: UUID
    var kind: Kind
    /// Nil means the windows explicitly selected on one display; otherwise an app bundle ID.
    var app: String?
    var preferredDisplay: String
    var members: [Member]

    /// Surviving slot IDs stay in order. Newly selected windows join at the end.
    static func orderedIDs(previous: [UUID], selected: [UUID]) -> [UUID] {
        let live = Set(selected)
        let surviving = previous.filter(live.contains)
        let known = Set(surviving)
        return surviving + selected.filter { !known.contains($0) }
    }

    /// Allocate weighted bands without dropping topology when minimum dimensions cannot fit.
    /// Infeasible constraints retain weighted targets; recovery then makes each title bar reachable.
    static func lengths(total: Int, weights: [Double], minimums: [Int], maximums: [Int]) -> [Int] {
        guard total > 0, !weights.isEmpty, minimums.count == weights.count,
              maximums.count == weights.count else { return [] }
        let sanitized = weights.map { $0.isFinite && $0 > 0 ? $0 : 1 }
        let largest = sanitized.max() ?? 1
        let weights = sanitized.map { max(1e-9, $0 / largest) }
        let feasible = minimums.reduce(0, +) <= total && maximums.reduce(0, +) >= total
            && zip(minimums, maximums).allSatisfy { $0 <= $1 }
        let lower = feasible ? minimums : Array(repeating: 0, count: weights.count)
        let upper = feasible ? maximums : Array(repeating: total, count: weights.count)
        var low = 0.0
        var high = Double(total) / (weights.min() ?? 1)
        for _ in 0..<80 {
            let scale = (low + high) / 2
            let used = weights.indices.reduce(0.0) {
                $0 + min(Double(upper[$1]), max(Double(lower[$1]), scale * weights[$1]))
            }
            if used > Double(total) { high = scale } else { low = scale }
        }
        let exact = weights.indices.map { min(Double(upper[$0]), max(Double(lower[$0]), low * weights[$0])) }
        var result = exact.map { Int(floor($0)) }
        let ranked = weights.indices.sorted {
            let first = exact[$0] - Double(result[$0]), second = exact[$1] - Double(result[$1])
            return first == second ? $0 < $1 : first > second
        }
        var remaining = total - result.reduce(0, +)
        for index in ranked where remaining > 0 && result[index] < upper[index] {
            result[index] += 1
            remaining -= 1
        }
        return result
    }
}

/// Global AX coordinates, whose y increases downwards. Recovery never changes saved intent.
enum WindowRecovery {
    static func target(for frame: CGRect, visibleFrames: [CGRect], minimumSize: CGSize = .zero,
                       resizable: Bool = true) -> CGRect? {
        guard valid(frame) else { return nil }
        let displays = visibleFrames.filter(valid)
        guard !displays.isEmpty else { return nil }
        // Require the leading title area and enough height to move/resize, not a visible sliver.
        let title = CGRect(x: frame.minX, y: frame.minY, width: min(240, frame.width), height: min(32, frame.height))
        if displays.contains(where: { $0.contains(title) && frame.intersection($0).height >= min(100, frame.height) }) {
            return nil
        }
        let display = displays.max { first, second in
            let a = overlap(frame, first), b = overlap(frame, second)
            if a != b { return a < b }
            return distance(frame, first) > distance(frame, second)
        }!
        var size = frame.size
        if resizable {
            let width = minimumSize.width.isFinite ? max(0, minimumSize.width) : 0
            let height = minimumSize.height.isFinite ? max(0, minimumSize.height) : 0
            size.width = max(width, min(frame.width, display.width))
            size.height = max(height, min(frame.height, display.height))
        }
        return CGRect(x: min(max(frame.minX, display.minX), max(display.minX, display.maxX - size.width)),
                      y: min(max(frame.minY, display.minY), max(display.minY, display.maxY - size.height)),
                      width: size.width, height: size.height)
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.minX.isFinite && rect.minY.isFinite
            && rect.width.isFinite && rect.height.isFinite && rect.width > 0 && rect.height > 0
    }
    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let dx = a.midX - b.midX, dy = a.midY - b.midY
        return dx * dx + dy * dy
    }
}
