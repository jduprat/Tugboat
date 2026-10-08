/// ShortcutEditorModel.swift

import Cocoa
import MASShortcut

/// A catalogue and persistence adapter for the compact shortcut editor. Drafts stay in the
/// view controller: merely opening the editor or selecting a command never writes defaults.
final class ShortcutEditorModel {
    enum Family: String, CaseIterable {
        case place = "Place"
        case arrange = "Arrange"
        case move = "Move"
        case resize = "Resize"
        case restore = "Restore"
        case record = "Record"
        case sidebar = "Sidebar"
        case access = "Access"
    }

    struct Command: Hashable {
        let defaultsKey: String
        let title: String
        let family: Family
        let windowAction: WindowAction?
        let summary: String

        var id: String { defaultsKey }

        /// Multi-window and app commands do not update the focused window's cycle history.
        var supportsSharedCycle: Bool {
            windowAction != nil && [.place, .move, .resize].contains(family)
        }
    }

    struct Binding {
        let command: Command
        let shortcut: MASShortcut
    }

    enum ConflictResolution {
        case reject
        case replaceConflicts
        case shareCycle
    }

    enum Preset: CaseIterable {
        case tugboat
        case compact
        case appTiling
    }

    enum SaveError: LocalizedError {
        case conflictingCommands([String])
        case unsupportedCycle
        case invalidShortcut
        case unavailableTransformer

        var errorDescription: String? {
            switch self {
            case .conflictingCommands(let titles):
                return "This shortcut is also assigned to " + titles.joined(separator: ", ") + "."
            case .unsupportedCycle:
                return "Only single-window placement, movement, and resizing commands can share a shortcut cycle."
            case .invalidShortcut:
                return "Record a shortcut before saving."
            case .unavailableTransformer:
                return "The shortcut could not be saved. Please reopen Settings and try again."
            }
        }
    }

    private let userDefaults: UserDefaults
    private let notificationCenter: NotificationCenter

    init(userDefaults: UserDefaults = .standard, notificationCenter: NotificationCenter = .default) {
        self.userDefaults = userDefaults
        self.notificationCenter = notificationCenter
    }

    static let catalog: [Command] = WindowAction.active.map { action in
        Command(defaultsKey: action.name,
                title: title(for: action),
                family: family(for: action),
                windowAction: action,
                summary: summary(for: action))
    } + [
        Command(defaultsKey: TodoManager.toggleDefaultsKey, title: "Toggle sidebar", family: .sidebar,
                windowAction: nil, summary: "Show or hide the reserved sidebar. Requires Sidebar to be enabled."),
        Command(defaultsKey: TodoManager.reflowDefaultsKey, title: "Reflow around sidebar", family: .sidebar,
                windowAction: nil, summary: "Fit windows around the reserved sidebar."),
        Command(defaultsKey: StackBadgeManager.toggleDefaultsKey, title: "Toggle stacked window badge", family: .access,
                windowAction: nil, summary: "Show or hide the badge for overlapping windows."),
        Command(defaultsKey: ArrangementManager.storeDefaultsKey, title: "Save window positions", family: .record,
                windowAction: nil, summary: "Save window positions for the connected displays."),
        Command(defaultsKey: ArrangementManager.restoreDefaultsKey, title: "Restore window positions", family: .restore,
                windowAction: nil, summary: "Restore saved window positions for the connected displays.")
    ]

    var assignedBindings: [Binding] {
        Self.catalog.compactMap { command in
            shortcut(for: command).map { Binding(command: command, shortcut: $0) }
        }
    }

    func shortcut(for command: Command) -> MASShortcut? {
        guard let shortcut = ShortcutCycle.shortcut(forDefaultsKey: command.defaultsKey, userDefaults: userDefaults),
              shortcut.keyCode >= 0 else { return nil }
        return shortcut
    }

    /// Returns every collision, including intentional shared cycles. The caller must explicitly
    /// choose to keep a cycle or replace its members; neither outcome is assumed silently.
    func conflicts(for shortcut: MASShortcut, assigning command: Command,
                   replacing oldCommand: Command? = nil) -> [Binding] {
        let identity = ShortcutCycle.ShortcutIdentity(shortcut)
        return assignedBindings.filter {
            $0.command.defaultsKey != command.defaultsKey
                && $0.command.defaultsKey != oldCommand?.defaultsKey
                && ShortcutCycle.ShortcutIdentity($0.shortcut) == identity
        }
    }

    func canShareCycle(command: Command, conflicts: [Binding]) -> Bool {
        command.supportsSharedCycle && conflicts.allSatisfy { $0.command.supportsSharedCycle }
    }

    func save(command: Command, shortcut: MASShortcut, replacing oldCommand: Command? = nil,
              resolution: ConflictResolution = .reject) throws {
        guard shortcut.keyCode >= 0 else { throw SaveError.invalidShortcut }
        let collisions = conflicts(for: shortcut, assigning: command, replacing: oldCommand)
        switch resolution {
        case .reject:
            if !collisions.isEmpty {
                throw SaveError.conflictingCommands(collisions.map { $0.command.title })
            }
        case .shareCycle:
            guard canShareCycle(command: command, conflicts: collisions) else {
                throw SaveError.unsupportedCycle
            }
        case .replaceConflicts:
            break
        }

        // Prepare the value before changing any existing binding, so a failed save is inert.
        let dictionary = try encoded(shortcut)
        if let oldCommand, oldCommand.defaultsKey != command.defaultsKey {
            clearWithoutNotification(oldCommand)
        }
        if case .replaceConflicts = resolution {
            for collision in collisions {
                clearWithoutNotification(collision.command)
            }
        }
        removeLegacyAlias(for: command)
        userDefaults.set(dictionary, forKey: command.defaultsKey)
        notifyChanged()
    }

    func clear(_ command: Command) {
        clearWithoutNotification(command)
        notifyChanged()
    }

    /// Complete Tugboat defaults: the standard Rectangle set, Tugboat's tiling commands,
    /// and the sidebar reflow and saved-position defaults. General and snap settings
    /// are untouched, including the legacy alternateDefaultShortcuts preference.
    static var defaultShortcuts: [String: MASShortcut] {
        var defaults = WindowAction.active.reduce(into: [String: MASShortcut]()) { result, action in
            if let shortcut = action.alternateDefault {
                result[action.name] = shortcut.toMASSHortcut()
            }
        }
        defaults[TodoManager.reflowDefaultsKey] = MASShortcut(keyCode: kVK_ANSI_N, modifierFlags: [.control, .option])
        defaults.merge(ArrangementManager.defaultShortcuts) { _, arrangement in arrangement }
        return defaults
    }

    func restoreDefaultPreset() throws {
        try applyPreset(.tugboat)
    }

    func applyPreset(_ preset: Preset) throws {
        let shortcuts: [String: MASShortcut]
        switch preset {
        case .tugboat:
            shortcuts = Self.defaultShortcuts
        case .compact:
            let actions: [WindowAction] = [.leftHalf, .rightHalf, .topHalf, .bottomHalf, .maximize,
                                           .center, .previousDisplay, .nextDisplay, .restore]
            let keys = Set(actions.map(\.name))
            shortcuts = Self.defaultShortcuts.filter { keys.contains($0.key) }
        case .appTiling:
            let actions: [WindowAction] = [.tileRows, .tileColumns, .tileActiveAppRows, .tileActiveAppColumns, .tileActiveApp]
            let keys = Set(actions.map(\.name))
            shortcuts = Self.defaultShortcuts.filter { keys.contains($0.key) }
        }
        // Prepare all values before committing, and rebind once after the complete preset.
        let dictionaries = try shortcuts.mapValues { try encoded($0) }
        for command in Self.catalog {
            removeLegacyAlias(for: command)
            userDefaults.set(dictionaries[command.defaultsKey] ?? [:], forKey: command.defaultsKey)
        }
        notifyChanged()
    }

    private func encoded(_ shortcut: MASShortcut) throws -> [String: Any] {
        guard let transformer = ValueTransformer(forName: NSValueTransformerName(rawValue: MASDictionaryTransformerName)),
              let dictionary = transformer.reverseTransformedValue(shortcut) as? [String: Any] else {
            throw SaveError.unavailableTransformer
        }
        return dictionary
    }

    private func clearWithoutNotification(_ command: Command) {
        removeLegacyAlias(for: command)
        // Removing the key would expose a registered default and unexpectedly re-enable it.
        userDefaults.set([String: Any](), forKey: command.defaultsKey)
    }

    private func removeLegacyAlias(for command: Command) {
        if let alias = command.windowAction?.aliasName {
            userDefaults.removeObject(forKey: alias)
        }
    }

    private func notifyChanged() {
        notificationCenter.post(name: .configImported, object: nil)
    }

    private static func family(for action: WindowAction) -> Family {
        switch action {
        case .tileAll, .tileRows, .tileColumns, .tileActiveAppRows, .tileActiveAppColumns,
             .tileActiveApp, .cascadeAll, .cascadeActiveApp, .reverseAll:
            return .arrange
        case .center, .centerProminently, .nextDisplay, .previousDisplay,
             .displayOne, .displayTwo, .displayThree, .displayFour, .displayFive,
             .displaySix, .displaySeven, .displayEight, .displayNine,
             .moveLeft, .moveRight, .moveUp, .moveDown:
            return .move
        case .maximizeHeight, .almostMaximize, .larger, .smaller, .largerWidth, .smallerWidth,
             .largerHeight, .smallerHeight, .doubleHeightUp, .doubleHeightDown, .doubleWidthLeft,
             .doubleWidthRight, .halveHeightUp, .halveHeightDown, .halveWidthLeft, .halveWidthRight, .specified:
            return .resize
        case .restore:
            return .restore
        case .leftTodo, .rightTodo:
            return .sidebar
        default:
            return .place
        }
    }

    private static func title(for action: WindowAction) -> String {
        if let title = action.displayName { return title }
        switch action {
        case .specified: return "Set configured size"
        case .reverseAll: return "Reverse window order"
        case .tileAll: return "Tile all windows in a grid"
        case .cascadeAll: return "Cascade all windows"
        case .cascadeActiveApp: return "Cascade current app windows"
        case .tileActiveApp: return "Tile current app windows in a grid"
        case .leftTodo: return "Reflow sidebar windows (left)"
        case .rightTodo: return "Reflow sidebar windows (right)"
        case .topVerticalThird: return "Top third"
        case .middleVerticalThird: return "Middle third"
        case .bottomVerticalThird: return "Bottom third"
        case .topVerticalTwoThirds: return "Top two thirds"
        case .bottomVerticalTwoThirds: return "Bottom two thirds"
        case .displayOne, .displayTwo, .displayThree, .displayFour, .displayFive,
             .displaySix, .displaySeven, .displayEight, .displayNine:
            return "Move to display \(action.rawValue - WindowAction.displayOne.rawValue + 1)"
        default:
            return action.name
        }
    }

    private static func summary(for action: WindowAction) -> String {
        switch action {
        case .tileActiveAppRows: return "Arrange visible windows of the chosen app in rows on the active display. Application defaults to the current app."
        case .tileActiveAppColumns: return "Arrange visible windows of the chosen app in columns on the active display. Application defaults to the current app."
        case .tileActiveApp: return "Arrange visible windows of the current app in a grid on this display."
        case .tileRows: return "Arrange visible windows in rows on this display."
        case .tileColumns: return "Arrange visible windows in columns on this display."
        case .restore: return "Return the focused window to its previous position."
        case .specified: return "Resize the focused window using the configured dimensions."
        case .topLeftNinth: return "Place the window in a ninth of the display. Repeat this shortcut to cycle through the 3 × 3 grid."
        case .topLeftTwelfth: return "Place the window in a twelfth of the display. Repeat this shortcut to cycle through the 4 × 3 grid."
        case .topLeftSixteenth: return "Place the window in a sixteenth of the display. Repeat this shortcut to cycle through the 4 × 4 grid."
        default:
            switch family(for: action) {
            case .place: return "Place the focused window in the selected screen region."
            case .arrange: return "Arrange visible windows on the current display."
            case .move: return "Move the focused window."
            case .resize: return "Resize the focused window."
            case .sidebar: return "Fit windows around the reserved sidebar."
            case .restore, .record, .access: return ""
            }
        }
    }
}
