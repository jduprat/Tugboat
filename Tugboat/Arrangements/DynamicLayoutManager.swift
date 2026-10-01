import Cocoa

/// Maintains ordered row/column groups across display changes. All AX work runs on the main thread.
final class DynamicLayoutManager {
    static let shared = DynamicLayoutManager()
    private(set) var layouts: [DynamicLayout] = []
    private var elements: [UUID: AccessibilityElement] = [:]
    private var observers: [NSObjectProtocol] = []
    private var pending: DispatchWorkItem?
    private var revision = 0
    private var started = false
    private(set) var isSettling = false
    private let url: URL
    private let connectedDisplays: () -> [ConnectedDisplay]
    private let screens: () -> [NSScreen]
    private let eligibleWindows: () -> [AccessibilityElement]
    private let layoutEnabled: () -> Bool

    init(url: URL = ArrangementStore.defaultDirectory.deletingLastPathComponent().appendingPathComponent("DynamicLayouts.json"),
         connectedDisplays: @escaping () -> [ConnectedDisplay] = ConnectedDisplay.current,
         screens: @escaping () -> [NSScreen] = { NSScreen.screens },
         eligibleWindows: @escaping () -> [AccessibilityElement] = { ArrangementManager.liveWindows().map(\.element) },
         layoutEnabled: @escaping () -> Bool = { !Defaults.maintainTiledLayouts.userDisabled }) {
        self.url = url
        self.connectedDisplays = connectedDisplays
        self.screens = screens
        self.eligibleWindows = eligibleWindows
        self.layoutEnabled = layoutEnabled
    }

    func start(observeDisplays: Bool = true) {
        guard !started else { return }
        started = true
        if let data = try? Data(contentsOf: url) {
            do {
                let decoded = try JSONDecoder().decode([DynamicLayout].self, from: data)
                let memberIDs = decoded.flatMap(\.members).map(\.id)
                guard Set(decoded.map(\.id)).count == decoded.count,
                      Set(memberIDs).count == memberIDs.count,
                      decoded.allSatisfy({ !$0.preferredDisplay.isEmpty && !$0.members.isEmpty
                        && $0.members.allSatisfy { !$0.app.isEmpty && $0.proportion.isFinite && $0.proportion > 0 } }) else {
                    Logger.log("Dynamic layouts: ignoring invalid saved groups")
                    throw CocoaError(.coderReadCorrupt)
                }
                layouts = decoded
            }
            catch { Logger.log("Dynamic layouts: could not read saved groups: \(error)") }
        }
        guard observeDisplays else { return }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.scheduleReflow() })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in self?.scheduleReflow() })
        // Read saved groups lazily; starting Tugboat alone must not move windows.
    }

    func remember(_ windows: [MultiWindowManager.TilingWindow], kind: DynamicLayout.Kind,
                  app: String?, screen: NSScreen) {
        guard started, layoutEnabled(), !windows.isEmpty, let display = display(for: screen) else { return }
        // An explicit tiling command supersedes any older group containing these windows.
        let old = layouts.first { $0.app == app && $0.preferredDisplay == display.identity.uuid && $0.kind == kind }
        let selected = windows.map { candidate -> DynamicLayout.Member in
            if var oldMember = old?.members.first(where: { elements[$0.id] == candidate.element }) {
                oldMember.title = candidate.element.title
                oldMember.proportion = Double(kind == .columns ? candidate.element.frame.width : candidate.element.frame.height)
                return oldMember
            }
            return DynamicLayout.Member(id: UUID(), app: candidate.element.bundleIdentifier ?? "",
                title: candidate.element.title, subrole: candidate.element.subrole?.rawValue,
                proportion: Double(kind == .columns ? candidate.element.frame.width : candidate.element.frame.height))
        }
        let order = DynamicLayout.orderedIDs(previous: old?.members.map(\.id) ?? [], selected: selected.map(\.id))
        let members = order.compactMap { id in selected.first { $0.id == id } }
        for (index, member) in selected.enumerated() { elements[member.id] = windows[index].element }
        let selectedElements = Set(windows.map(\.element))
        for index in layouts.indices {
            layouts[index].members.removeAll { member in
                elements[member.id].map(selectedElements.contains) == true
            }
        }
        layouts.removeAll { $0.members.isEmpty || $0.id == old?.id }
        layouts.append(DynamicLayout(id: old?.id ?? UUID(), kind: kind, app: app,
            preferredDisplay: display.identity.uuid, members: members))
        persist()
    }

    func cancelPendingReflow() {
        isSettling = false
        revision &+= 1
        pending?.cancel()
    }

    /// Explicit single-window commands release that window from automatic reflow.
    func release(_ window: AccessibilityElement) {
        guard started else { return }
        let ids = Set(elements.filter { $0.value == window }.map(\.key))
        guard !ids.isEmpty else { return }
        for index in layouts.indices { layouts[index].members.removeAll { ids.contains($0.id) } }
        layouts.removeAll { $0.members.isEmpty }
        for id in ids { elements.removeValue(forKey: id) }
        persist()
    }

    func ordered(_ windows: [MultiWindowManager.TilingWindow], kind: DynamicLayout.Kind,
                 screen: NSScreen) -> [MultiWindowManager.TilingWindow] {
        guard started, layoutEnabled(), let display = display(for: screen) else { return windows }
        let matching = layouts.filter { $0.kind == kind && $0.preferredDisplay == display.identity.uuid }
        let saved = matching.flatMap(\.members).compactMap { elements[$0.id] }
        let known = saved.compactMap { element in windows.first { $0.element == element } }
        return known + windows.filter { candidate in !known.contains { $0.element == candidate.element } }
    }

    private func scheduleReflow() {
        isSettling = true
        revision &+= 1
        pending?.cancel()
        let token = revision
        let work = DispatchWorkItem { [weak self] in self?.reflow(token: token) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func reflow(restoringRecordedPositions: Bool = true) {
        reflow(token: revision, restoringRecordedPositions: restoringRecordedPositions)
    }

    private func reflow(token: Int, restoringRecordedPositions: Bool = true) {
        guard token == revision else { return }
        let connected = connectedDisplays()
        guard !connected.isEmpty else { return }
        let live = eligibleWindows()
        resolveMembers(from: live)
        let managed = !layoutEnabled() ? Set<AccessibilityElement>()
            : Set(layouts.flatMap(\.members).compactMap { elements[$0.id] })
        if restoringRecordedPositions {
            ArrangementManager.restoreArrangement(automatically: true, excluding: managed,
                isCurrent: { [weak self] in self?.revision == token })
        }
        applyKnownLayouts(live: live)
        recover(live, connected: connected)
        // Retry against a fresh eligible snapshot, cancelled by a newer display change or command.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.revision == token else { return }
            let fresh = self.eligibleWindows()
            self.applyKnownLayouts(live: fresh)
            self.recover(fresh, connected: self.connectedDisplays())
            self.isSettling = false
        }
    }

    private func applyKnownLayouts(live: [AccessibilityElement]) {
        guard layoutEnabled() else { return }
        for layout in layouts {
            let screen = screens().first { display(for: $0)?.identity.uuid == layout.preferredDisplay }
                ?? screens().first
            guard let screen else { continue }
            let eligible = Set(live)
            let members = layout.members.compactMap { member -> (DynamicLayout.Member, AccessibilityElement)? in
                guard let element = elements[member.id], eligible.contains(element) else { return nil }
                return (member, element)
            }
            guard !members.isEmpty else { continue }
            apply(members, kind: layout.kind, screen: screen)
        }
    }

    /// Next/previous-display commands carry the whole active tiled group with its slot order.
    func moveGroup(containing window: AccessibilityElement, to screen: NSScreen) -> Bool {
        guard started, layoutEnabled(),
              let index = layouts.firstIndex(where: { $0.members.contains { elements[$0.id] == window } }),
              let destination = display(for: screen) else { return false }
        cancelPendingReflow()
        let eligible = Set(eligibleWindows())
        let members = layouts[index].members.compactMap { member -> (DynamicLayout.Member, AccessibilityElement)? in
            guard let element = elements[member.id], eligible.contains(element) else { return nil }
            return (member, element)
        }
        guard !members.isEmpty else { return false }
        layouts[index].preferredDisplay = destination.identity.uuid
        apply(members, kind: layouts[index].kind, screen: screen)
        recover(members.map { $0.1 }, connected: connectedDisplays())
        persist()
        return true
    }

    func memberIDs(for windows: [AccessibilityElement]) -> [UUID?] {
        windows.map { window in elements.first { $0.value == window }?.key }
    }

    func resolveMembers(from live: [AccessibilityElement]) {
        var used = Set(elements.values.filter(live.contains))
        for layout in layouts {
            for member in layout.members where elements[member.id].map(live.contains) != true {
                // After an app relaunch, only a unique app/title/subrole pair is safe. Ambiguous
                // repeated titles remain dormant rather than reconstructing order from new geometry.
                let matches = live.filter { !used.contains($0) && $0.bundleIdentifier == member.app
                    && $0.title == member.title && $0.subrole?.rawValue == member.subrole }
                let duplicate = layouts.flatMap(\.members).filter { $0.app == member.app && $0.title == member.title
                    && $0.subrole == member.subrole }.count > 1
                if matches.count == 1 && !duplicate {
                    elements[member.id] = matches[0]
                    used.insert(matches[0])
                }
            }
        }
    }

    func apply(_ members: [(DynamicLayout.Member, AccessibilityElement)], kind: DynamicLayout.Kind, screen: NSScreen) {
        let frame = screen.adjustedVisibleFrame()
        let bounds = MultiWindowManager.BackingPixelBounds(screen.convertRectToBacking(frame))
        let direction: MultiWindowManager.BandDirection = kind == .rows ? .rows : .columns
        let total = bounds.extent(direction)
        let minimums = members.map { member -> Int in
            let size = member.1.isResizable() ? member.1.minimumSize ?? .zero : member.1.frame.size
            let backing = screen.convertRectToBacking(CGRect(origin: .zero, size: size))
            return max(0, Int(ceil(kind == .rows ? backing.height : backing.width)))
        }
        let constraints = members.enumerated().map { index, member -> MultiWindowManager.BandConstraint in
            member.1.isResizable() ? .resizable(minimum: minimums[index], maximum: total) : .fixed(minimums[index])
        }
        let snapshots = members.map { member in
            MultiWindowManager.TilingWindow(element: member.1, frame: member.1.frame,
                windowId: member.1.windowId, pid: member.1.pid, isFocused: false)
        }
        MultiWindowManager.applyBandTiling(snapshots, bounds: bounds, direction: direction,
            constraints: constraints, weights: members.map { $0.0.proportion },
            pointFrame: { screen.convertRectFromBacking($0).screenFlipped },
            backingFrame: { screen.convertRectToBacking($0.screenFlipped) })
    }

    private func recover(_ windows: [AccessibilityElement], connected: [ConnectedDisplay]) {
        for element in windows {
            if let target = WindowRecovery.target(for: element.frame, visibleFrames: connected.map(\.visibleFrame),
                minimumSize: element.minimumSize ?? .zero, resizable: element.isResizable()) {
                element.setFrame(target)
                // An app may clamp the requested size. Translate its achieved frame again, without resizing.
                if let translation = WindowRecovery.target(for: element.frame, visibleFrames: connected.map(\.visibleFrame), resizable: false) {
                    element.setFrame(translation)
                }
            }
        }
    }

    private func display(for screen: NSScreen) -> ConnectedDisplay? {
        connectedDisplays().first { $0.bounds == screen.frame.screenFlipped }
    }
    deinit {
        pending?.cancel()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(layouts).write(to: url, options: .atomic)
        } catch { Logger.log("Dynamic layouts: could not save groups: \(error)") }
    }
}
