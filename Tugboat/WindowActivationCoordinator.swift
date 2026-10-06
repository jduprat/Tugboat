import AppKit

/// Keeps Tugboat in the application switcher while a qualifying window is open.
/// Registration follows show/close events, so minimizing or hiding a window does not remove it.
final class WindowActivationCoordinator {
    typealias PolicySetter = (NSApplication.ActivationPolicy) -> Bool
    typealias DeferredScheduler = (@escaping () -> Void) -> Void

    private let notificationCenter: NotificationCenter
    private let setPolicy: PolicySetter
    private let scheduleDeferred: DeferredScheduler
    private var closeObservers: [ObjectIdentifier: NSObjectProtocol] = [:]
    private var lastAppliedPolicy: NSApplication.ActivationPolicy?
    private var reconciliationScheduled = false

    init(notificationCenter: NotificationCenter = .default,
         setPolicy: @escaping PolicySetter = { NSApp.setActivationPolicy($0) },
         scheduleDeferred: @escaping DeferredScheduler = { action in
             DispatchQueue.main.async { action() }
         }) {
        self.notificationCenter = notificationCenter
        self.setPolicy = setPolicy
        self.scheduleDeferred = scheduleDeferred
    }

    deinit {
        for observer in closeObservers.values {
            notificationCenter.removeObserver(observer)
        }
    }

    /// Call immediately before activating and showing a Settings or Authorization window.
    func register(_ window: NSWindow) {
        let identity = ObjectIdentifier(window)
        if closeObservers[identity] == nil {
            closeObservers[identity] = notificationCenter.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: nil
            ) { [weak self] _ in
                self?.unregister(identity)
            }
        }
        reconcilePolicy()
    }

    private func unregister(_ identity: ObjectIdentifier) {
        guard let observer = closeObservers.removeValue(forKey: identity) else { return }
        notificationCenter.removeObserver(observer)
        guard !reconciliationScheduled else { return }
        reconciliationScheduled = true
        scheduleDeferred { [weak self] in
            guard let self else { return }
            self.reconciliationScheduled = false
            self.reconcilePolicy()
        }
    }

    private func reconcilePolicy() {
        let desiredPolicy: NSApplication.ActivationPolicy = closeObservers.isEmpty ? .accessory : .regular
        guard desiredPolicy != lastAppliedPolicy else { return }
        if setPolicy(desiredPolicy) {
            lastAppliedPolicy = desiredPolicy
        }
    }
}
