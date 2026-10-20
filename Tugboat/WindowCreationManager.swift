import Cocoa

/// Fits newly created windows while their initial frames settle.
final class WindowCreationManager {
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> Void

    private struct Observation {
        let observer: AXObserver
        let application: AXUIElement
    }
    private struct PendingWindow {
        let token: UUID
        let pid: pid_t
        var cancelled = false
        var chosenOrigin: CGPoint?
        var chosenDisplay: CGRect?
        var reservedOrigin: CGPoint?
    }

    private var started = false
    private var observesSystem = false
    private var applicationsObservation: NSKeyValueObservation?
    private var interactionMonitor: EventMonitor?
    private var mouseDownWindow: AccessibilityElement?
    private var knownApplications: Set<pid_t> = []
    private var receivedApplicationSnapshot = false
    private var observations: [pid_t: Observation] = [:]
    private var registrationTokens: [pid_t: UUID] = [:]
    private var pendingWindows: [AccessibilityElement: PendingWindow] = [:]
    private let eligibleWindows: () -> [AccessibilityElement]
    private let visibleFrames: () -> [CGRect]
    private let windowAtLocation: (CGPoint) -> AccessibilityElement?
    private let pointerLocation: () -> CGPoint
    private let dragInProgress: () -> Bool
    private let schedule: Scheduler

    init(eligibleWindows: @escaping () -> [AccessibilityElement] = { ArrangementManager.liveWindows().map(\.element) },
         visibleFrames: @escaping () -> [CGRect] = { ConnectedDisplay.current().map(\.visibleFrame) },
         windowAtLocation: @escaping (CGPoint) -> AccessibilityElement? = AccessibilityElement.getWindowElement(at:),
         pointerLocation: @escaping () -> CGPoint = { NSEvent.mouseLocation.screenFlipped },
         dragInProgress: @escaping () -> Bool = {
             WindowCreationManager.isDragInProgress(
                 leftButtonDown: CGEventSource.buttonState(.combinedSessionState, button: .left),
                 secondsSinceMouseDown: CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown),
                 secondsSinceMouseDragged: CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDragged))
         },
         schedule: @escaping Scheduler = { delay, action in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
         }) {
        self.eligibleWindows = eligibleWindows
        self.visibleFrames = visibleFrames
        self.windowAtLocation = windowAtLocation
        self.pointerLocation = pointerLocation
        self.dragInProgress = dragInProgress
        self.schedule = schedule
    }

    static func isDragInProgress(leftButtonDown: Bool, secondsSinceMouseDown: TimeInterval,
                                 secondsSinceMouseDragged: TimeInterval) -> Bool {
        leftButtonDown && secondsSinceMouseDragged < secondsSinceMouseDown
    }

    func start(observeSystem: Bool = true) {
        guard !started else { return }
        started = true
        observesSystem = observeSystem
        guard observeSystem else { return }

        // Workspace launch notifications omit menu-bar apps. The observable list includes them.
        applicationsObservation = NSWorkspace.shared.observe(\.runningApplications, options: [.initial]) { [weak self] workspace, _ in
            // Indexed KVO changes contain only changed apps, so always capture the complete list.
            let applications = workspace.runningApplications
            DispatchQueue.main.async {
                self?.updateApplications(applications)
            }
        }
    }

    func stop() {
        guard started else { return }
        started = false
        observesSystem = false
        applicationsObservation?.invalidate()
        applicationsObservation = nil
        knownApplications.removeAll()
        receivedApplicationSnapshot = false
        for pid in Array(observations.keys) { removeApplication(pid) }
        registrationTokens.removeAll()
        pendingWindows.removeAll()
        stopInteractionMonitorIfIdle()
    }

    private func updateApplications(_ applications: [NSRunningApplication]) {
        guard started else { return }
        let current = Set(applications.map(\.processIdentifier))
        for pid in knownApplications.subtracting(current) { removeApplication(pid) }
        let added = applications.filter { !knownApplications.contains($0.processIdentifier) }
        knownApplications = current
        let initialSnapshot = !receivedApplicationSnapshot
        receivedApplicationSnapshot = true
        for app in added {
            // Existing windows are left alone when Tugboat starts, except apps still launching.
            observe(app, includeInitialWindows: !initialSnapshot || !app.isFinishedLaunching)
        }
    }

    private func observe(_ app: NSRunningApplication, includeInitialWindows: Bool) {
        let pid = app.processIdentifier
        guard started, pid != ProcessInfo.processInfo.processIdentifier, !app.isTerminated,
              app.activationPolicy != .prohibited || includeInitialWindows,
              observations[pid] == nil, registrationTokens[pid] == nil else { return }
        let token = UUID()
        registrationTokens[pid] = token
        attemptObservation(app, token: token, includeInitialWindows: includeInitialWindows, attempt: 0)
    }

    private func attemptObservation(_ app: NSRunningApplication, token: UUID,
                                    includeInitialWindows: Bool, attempt: Int) {
        let pid = app.processIdentifier
        guard started, registrationTokens[pid] == token, observations[pid] == nil, !app.isTerminated else { return }
        var createdObserver: AXObserver?
        var error = AXError.cannotComplete
        // A newly launched app can still be transitioning from a background process to a windowed app.
        if app.activationPolicy != .prohibited {
            error = AXObserverCreate(pid, windowCreatedCallback, &createdObserver)
            if error == .success, let observer = createdObserver {
                let application = AXUIElementCreateApplication(pid)
                error = AXObserverAddNotification(observer, application, kAXWindowCreatedNotification as CFString,
                                                  Unmanaged.passUnretained(self).toOpaque())
                if error == .success {
                    observations[pid] = Observation(observer: observer, application: application)
                    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
                    if includeInitialWindows { inspectInitialWindows(app, token: token) }
                    return
                }
            }
        }

        let retryDelays: [TimeInterval] = [0.25, 0.75, 1.5, 3]
        if error != .notificationUnsupported, error != .apiDisabled, attempt < retryDelays.count {
            schedule(retryDelays[attempt]) { [weak self] in
                self?.attemptObservation(app, token: token, includeInitialWindows: includeInitialWindows, attempt: attempt + 1)
            }
        } else if app.activationPolicy != .prohibited {
            Logger.log("New windows: could not observe \(app.bundleIdentifier ?? String(pid)) (AX error \(error.rawValue))")
        }
    }

    private func inspectInitialWindows(_ app: NSRunningApplication, token: UUID) {
        // A new app may create its first window before AX notification registration succeeds.
        let delays: [TimeInterval] = [0, 0.5, 1.5]
        for delay in delays {
            schedule(delay) { [weak self] in
                guard let self, self.started, !app.isTerminated,
                      self.registrationTokens[app.processIdentifier] == token else { return }
                for window in AccessibilityElement(app.processIdentifier).windowElements ?? [] {
                    self.windowCreated(window)
                }
            }
        }
    }

    private func removeApplication(_ pid: pid_t) {
        registrationTokens.removeValue(forKey: pid)
        pendingWindows = pendingWindows.filter { $0.value.pid != pid }
        stopInteractionMonitorIfIdle()
        guard let observation = observations.removeValue(forKey: pid) else { return }
        _ = AXObserverRemoveNotification(observation.observer, observation.application, kAXWindowCreatedNotification as CFString)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observation.observer), .commonModes)
    }

    func windowCreated(_ window: AccessibilityElement) {
        guard started, pendingWindows[window] == nil, let pid = window.pid else { return }
        let token = UUID()
        pendingWindows[window] = PendingWindow(token: token, pid: pid)
        startInteractionMonitorIfNeeded()
        cancelFittingForCurrentDrag(with: window)
        let delays: [TimeInterval] = [0.1, 0.4, 1]
        for delay in delays {
            schedule(delay) { [weak self] in
                guard let self, let pending = self.pendingWindows[window], pending.token == token, !pending.cancelled else { return }
                let eligible = self.eligibleWindows()
                guard let created = eligible.first(where: { $0 == window }) else { return }
                self.placeCreatedWindow(created, among: eligible, token: token)
            }
        }
        // Keep the token briefly after the last fit so duplicate creation notifications do not extend the sequence.
        schedule(2) { [weak self] in
            guard let self, self.pendingWindows[window]?.token == token else { return }
            self.pendingWindows.removeValue(forKey: window)
            self.stopInteractionMonitorIfIdle()
        }
    }

    private func placeCreatedWindow(_ window: AccessibilityElement, among eligibleWindows: [AccessibilityElement], token: UUID) {
        guard let pending = pendingWindows[window], pending.token == token, !pending.cancelled else { return }
        let frame = window.frame
        let displays = visibleFrames()
        let needsInitialOrigin = pending.chosenOrigin == nil
            || pending.chosenDisplay.map { !displays.contains($0) } == true
        var occupiedOrigins: [CGPoint] = []
        if needsInitialOrigin {
            occupiedOrigins = eligibleWindows.filter { $0 != window }.map { $0.frame.origin }
            occupiedOrigins += pendingWindows.compactMap { element, other in
                element != window && !other.cancelled ? other.reservedOrigin : nil
            }
        }
        guard let placement = NewWindowPlacement.target(for: frame, visibleFrames: displays,
            occupiedOrigins: occupiedOrigins, minimumSize: window.minimumSize ?? .zero,
            resizable: window.isResizable(), preferredOrigin: pending.chosenOrigin,
            preferredDisplay: pending.chosenDisplay) else { return }
        let target = placement.frame
        cancelFittingForCurrentDrag(with: window)
        guard pendingWindows[window]?.cancelled == false else { return }
        if needsInitialOrigin { pendingWindows[window]?.chosenOrigin = target.origin }
        pendingWindows[window]?.chosenDisplay = placement.display
        pendingWindows[window]?.reservedOrigin = target.origin
        guard target != frame else { return }
        window.setFrame(target)

        // An app may clamp the requested size. Re-clamp the achieved frame without resizing it again.
        let achieved = window.frame
        if let correction = NewWindowPlacement.target(for: achieved, visibleFrames: visibleFrames(),
            occupiedOrigins: [], resizable: false, preferredOrigin: target.origin,
            preferredDisplay: placement.display) {
            cancelFittingForCurrentDrag(with: window)
            guard pendingWindows[window]?.cancelled == false else { return }
            if correction.display != placement.display {
                pendingWindows[window]?.chosenOrigin = correction.frame.origin
                pendingWindows[window]?.chosenDisplay = correction.display
            }
            pendingWindows[window]?.reservedOrigin = correction.frame.origin
            if correction.frame != achieved { window.setFrame(correction.frame) }
        }
    }

    private func cancelPendingFitting(for window: AccessibilityElement) {
        guard var pending = pendingWindows[window] else { return }
        pending.cancelled = true
        pendingWindows[window] = pending
    }

    private func cancelFittingForCurrentDrag(with window: AccessibilityElement) {
        guard dragInProgress() else { return }
        let interactedWindow = mouseDownWindow ?? windowAtLocation(pointerLocation())
        if interactedWindow == window { cancelPendingFitting(for: window) }
    }

    private func startInteractionMonitorIfNeeded() {
        guard observesSystem, interactionMonitor == nil else { return }
        let monitor = PassiveEventMonitor(mask: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handleMouseEvent(event)
        }
        interactionMonitor = monitor
        monitor.start()
    }

    private func stopInteractionMonitorIfIdle() {
        guard pendingWindows.isEmpty else { return }
        interactionMonitor?.stop()
        interactionMonitor = nil
        mouseDownWindow = nil
    }

    func handleMouseEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            let location = event.cgEvent?.location ?? pointerLocation()
            mouseDownWindow = windowAtLocation(location).flatMap {
                pendingWindows[$0]?.cancelled == false ? $0 : nil
            }
        case .leftMouseDragged:
            if let window = mouseDownWindow {
                cancelPendingFitting(for: window)
                mouseDownWindow = nil
            }
        case .leftMouseUp:
            mouseDownWindow = nil
        default:
            break
        }
    }

    deinit { stop() }
}

/// Initial placement is independent of saved layouts and later manual movement.
enum NewWindowPlacement {
    struct Result {
        let frame: CGRect
        let display: CGRect
    }

    private static let offsets: [CGPoint] = [
        .zero, CGPoint(x: 32, y: 32), CGPoint(x: 64, y: 64),
        CGPoint(x: -32, y: 32), CGPoint(x: 32, y: -32), CGPoint(x: -32, y: -32),
        CGPoint(x: -64, y: 64), CGPoint(x: 64, y: -64), CGPoint(x: -64, y: -64)
    ]

    static func target(for frame: CGRect, visibleFrames: [CGRect], occupiedOrigins: [CGPoint],
                       minimumSize: CGSize = .zero, resizable: Bool = true,
                       preferredOrigin: CGPoint? = nil, preferredDisplay: CGRect? = nil) -> Result? {
        guard valid(frame) else { return nil }
        let displays = visibleFrames.filter(valid)
        let retainedDisplay = preferredDisplay.flatMap { displays.contains($0) ? $0 : nil }
        guard let display = retainedDisplay ?? displays.max(by: { first, second in
            let firstOverlap = overlap(frame, first), secondOverlap = overlap(frame, second)
            if firstOverlap != secondOverlap { return firstOverlap < secondOverlap }
            return distance(frame, first) > distance(frame, second)
        }) else { return nil }

        var size = frame.size
        if resizable {
            let minimumWidth = minimumSize.width.isFinite ? max(0, minimumSize.width) : 0
            let minimumHeight = minimumSize.height.isFinite ? max(0, minimumSize.height) : 0
            if size.width > display.width {
                size.width = min(size.width, max(minimumWidth, max(1, floor(display.width * 0.9))))
            }
            if size.height > display.height {
                size.height = min(size.height, max(minimumHeight, max(1, floor(display.height * 0.9))))
            }
        }

        func clamped(_ origin: CGPoint) -> CGPoint {
            CGPoint(x: min(max(origin.x, display.minX), max(display.minX, display.maxX - size.width)),
                    y: min(max(origin.y, display.minY), max(display.minY, display.maxY - size.height)))
        }
        let canUseSavedOrigin = preferredDisplay == nil || retainedDisplay != nil
        let savedOrigin = canUseSavedOrigin ? preferredOrigin.flatMap { $0.x.isFinite && $0.y.isFinite ? $0 : nil } : nil
        let base = clamped(savedOrigin ?? frame.origin)
        if savedOrigin != nil { return Result(frame: CGRect(origin: base, size: size), display: display) }

        let occupied = occupiedOrigins.filter { $0.x.isFinite && $0.y.isFinite }
        var candidates: [CGPoint] = []
        for offset in offsets {
            let candidate = clamped(CGPoint(x: base.x + offset.x, y: base.y + offset.y))
            if !candidates.contains(candidate) { candidates.append(candidate) }
        }
        let origin = candidates.first { candidate in
            occupied.allSatisfy { abs(candidate.x - $0.x) >= 16 || abs(candidate.y - $0.y) >= 16 }
        } ?? base
        return Result(frame: CGRect(origin: origin, size: size), display: display)
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.minX.isFinite && rect.minY.isFinite
            && rect.width.isFinite && rect.height.isFinite && rect.width > 0 && rect.height > 0
    }

    private static func overlap(_ first: CGRect, _ second: CGRect) -> CGFloat {
        let intersection = first.intersection(second)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private static func distance(_ first: CGRect, _ second: CGRect) -> CGFloat {
        let x = first.midX - second.midX, y = first.midY - second.midY
        return x * x + y * y
    }
}

private let windowCreatedCallback: AXObserverCallback = { _, element, notification, context in
    guard notification as String == kAXWindowCreatedNotification, let context else { return }
    let manager = Unmanaged<WindowCreationManager>.fromOpaque(context).takeUnretainedValue()
    manager.windowCreated(AccessibilityElement(element))
}
