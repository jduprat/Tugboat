/// ArrangementManager.swift

import Cocoa
import MASShortcut

/// Save Window Positions and Restore Window Positions, from the menu or a shortcut: the manual half of
/// arrangements. Positions are kept per display set in the Arrangements folder.
class ArrangementManager {

    static let storeDefaultsKey = "storeArrangement"
    static let restoreDefaultsKey = "restoreArrangement"
    static let defaultsKeys = [storeDefaultsKey, restoreDefaultsKey]

    static let defaultShortcuts: [String: MASShortcut] = [
        storeDefaultsKey: MASShortcut(keyCode: kVK_ANSI_S, modifierFlags: [.control, .option, .shift]),
        restoreDefaultsKey: MASShortcut(keyCode: kVK_ANSI_R, modifierFlags: [.control, .option, .shift]),
    ]

    private static let store = ArrangementStore()
    private static var started = false
    private static var shortcutBindingsSessionActive = true
    private static var shortcutBindingsSuspended = false
    private static var configImportObserver: NSObjectProtocol?

    /// Called once Accessibility is granted, after ShortcutManager has configured the shared binder.
    static func start() {
        guard !started else { return }
        started = true
        MASShortcutBinder.shared()?.registerDefaultShortcuts(defaultShortcuts)
        configImportObserver = NotificationCenter.default.addObserver(forName: .configImported, object: nil, queue: .main) { _ in
            registerUnregisterShortcuts()
        }
        registerUnregisterShortcuts()
    }

    // MARK: Shortcuts

    /// Breaks each binding first so re-evaluation can't stack a second action on a defaults key.
    private static func registerUnregisterShortcuts() {
        for key in defaultsKeys {
            MASShortcutBinder.shared()?.breakBinding(withDefaultsKey: key)
            guard started, shortcutBindingsSessionActive, !shortcutBindingsSuspended, isBindable(key) else { continue }
            MASShortcutBinder.shared()?.bindShortcut(withDefaultsKey: key, toAction: {
                key == storeDefaultsKey ? storeArrangement() : restoreArrangement()
            })
        }
    }

    static func setShortcutBindingsSessionActive(_ isActive: Bool) {
        guard shortcutBindingsSessionActive != isActive else { return }
        shortcutBindingsSessionActive = isActive
        registerUnregisterShortcuts()
    }

    static func setShortcutBindingsSuspended(_ suspended: Bool) {
        guard shortcutBindingsSuspended != suspended else { return }
        shortcutBindingsSuspended = suspended
        registerUnregisterShortcuts()
    }

    private static func isBindable(_ key: String) -> Bool {
        guard let shortcut = ShortcutCycle.shortcut(forDefaultsKey: key) else { return true }
        return AppShortcutConflict.conflict(for: shortcut, ignoringDefaultsKey: key) == nil
    }

    static func keyEquivalent(for key: String) -> (String?, NSEvent.ModifierFlags)? {
        guard let shortcut = ShortcutCycle.shortcut(forDefaultsKey: key) else { return nil }
        return (shortcut.keyCodeStringForKeyEquivalent, shortcut.modifierFlags)
    }

    // MARK: Save and restore

    static func hasArrangementForCurrentDisplays() -> Bool {
        ArrangementStore.lookup(ConnectedDisplay.current().map(\.identity), in: store.loadAll()) != nil
    }

    static func storeArrangement() {
        let connected = ConnectedDisplay.current()
        guard !connected.isEmpty else {
            NSSound.beep()
            Logger.log("Arrangements: no displays found")
            return
        }
        let identities = connected.map(\.identity)
        var entry: ArrangementStore.Entry
        switch ArrangementStore.lookup(identities, in: store.loadAll()) {
        case .exact(let found)?, .adopted(let found)?:
            entry = found
        case nil:
            let url = store.newFileURL(for: identities)
            let arrangement = Arrangement(name: url.deletingPathExtension().lastPathComponent, lastSeen: Date(),
                                          displays: identities, windows: [])
            entry = ArrangementStore.Entry(url: url, arrangement: arrangement)
        }

        let live = liveWindows().map(\.window)
        entry.arrangement.capture(live, on: connected, at: Date())
        do {
            try store.write(entry.arrangement, to: entry.url)
            Logger.log("Arrangements: saved \(live.count) windows to \(entry.url.lastPathComponent)")
        } catch {
            NSSound.beep()
            Logger.log("Arrangements: could not write \(entry.url.path): \(error)")
        }
    }

    static func restoreArrangement() {
        let connected = ConnectedDisplay.current()
        guard let lookup = ArrangementStore.lookup(connected.map(\.identity), in: store.loadAll()) else {
            NSSound.beep()
            Logger.log("Arrangements: nothing saved for the connected displays")
            return
        }
        let entry: ArrangementStore.Entry
        switch lookup {
        case .exact(let found):
            entry = found
        case .adopted(let found):
            entry = found
            Logger.log("Arrangements: \(found.url.lastPathComponent) adopted for displays with new UUIDs")
            try? store.write(found.arrangement, to: found.url)
        }

        let live = liveWindows()
        let placements = entry.arrangement.placements(for: live.map(\.window), on: connected)
        var moved = [(element: AccessibilityElement, target: CGRect)]()
        for (index, target) in placements where !framesClose(live[index].element.frame, target) {
            live[index].element.setFrame(target)
            moved.append((live[index].element, target))
        }
        Logger.log("Arrangements: moved \(moved.count) of \(placements.count) remembered windows from \(entry.url.lastPathComponent)")

        // macOS sometimes puts a window back or clamps it on the way between displays; check once and retry.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            for (element, target) in moved where !framesClose(element.frame, target) {
                element.setFrame(target)
            }
        }
    }

    /// Windows that can be saved and moved: those on the current Space, except Tugboat's own, ignored
    /// apps, the Todo window, sheets, dialogs, and minimized, hidden or full-screen windows.
    private static func liveWindows() -> [(element: AccessibilityElement, window: LiveWindow)] {
        let onScreen = WindowUtil.getWindowList(forceRefresh: true)
        let onScreenIds = Set(onScreen.map(\.id))
        let ownPid = ProcessInfo.processInfo.processIdentifier
        let ignoredApps = Defaults.disabledApps.typedValue ?? []
        return AccessibilityElement.getAllWindowElements(from: onScreen).compactMap { element -> (element: AccessibilityElement, window: LiveWindow)? in
            guard element.isWindow == true, element.isSheet != true, element.isSystemDialog != true,
                  element.isMinimized != true, element.isHidden != true, element.isFullScreen != true,
                  let pid = element.pid, pid != ownPid,
                  let app = element.bundleIdentifier, !ignoredApps.contains(app),
                  !(Defaults.todo.userEnabled && TodoManager.isTodoWindow(element))
            else { return nil }
            // Windows on other Spaces cannot be moved; the on-screen list covers the current Space.
            if let windowId = element.windowId, !onScreenIds.contains(windowId) { return nil }
            let frame = element.frame
            guard !frame.isNull, frame.width > 0, frame.height > 0 else { return nil }
            return (element, LiveWindow(app: app, title: element.title, subrole: element.subrole?.rawValue, frame: frame))
        }
    }

    private static func framesClose(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2
            && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }
}
