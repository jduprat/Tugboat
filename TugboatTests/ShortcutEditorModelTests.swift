/// ShortcutEditorModelTests.swift

import Cocoa
import MASShortcut
import XCTest
@testable import Tugboat

final class ShortcutEditorModelTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var notifications: NotificationCenter!
    private var model: ShortcutEditorModel!

    override func setUpWithError() throws {
        _ = MASShortcutBinder.shared()
        suiteName = "ShortcutEditorModelTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        // Mask the running host's registered defaults without editing its preferences.
        for command in ShortcutEditorModel.catalog {
            defaults.set([String: Any](), forKey: command.defaultsKey)
        }
        notifications = NotificationCenter()
        model = ShortcutEditorModel(userDefaults: defaults, notificationCenter: notifications)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        model = nil
        defaults = nil
        notifications = nil
    }

    func testCatalogCoversEveryActionAndAncillaryBindingExactlyOnce() {
        let catalog = ShortcutEditorModel.catalog
        let expectedKeys = WindowAction.active.map(\.name)
            + TodoManager.defaultsKeys + StackBadgeManager.defaultsKeys + ArrangementManager.defaultsKeys
        XCTAssertEqual(Set(catalog.map(\.defaultsKey)), Set(expectedKeys))
        XCTAssertEqual(catalog.count, expectedKeys.count)
        XCTAssertTrue(catalog.allSatisfy { !$0.title.isEmpty && !$0.summary.isEmpty })
        XCTAssertTrue(model.assignedBindings.isEmpty)
    }

    func testOpeningEditorPreservesCustomAndExplicitlyClearedPreferences() throws {
        let custom = MASShortcut(keyCode: kVK_ANSI_P, modifierFlags: [.control, .option, .shift])
        try store(custom, key: WindowAction.leftHalf.name)
        let before = try XCTUnwrap(defaults.persistentDomain(forName: suiteName)) as NSDictionary

        let reopened = ShortcutEditorModel(userDefaults: defaults, notificationCenter: notifications)
        XCTAssertEqual(reopened.assignedBindings.count, 1)
        XCTAssertEqual(reopened.assignedBindings.first?.command.windowAction, .leftHalf)
        XCTAssertEqual(ShortcutCycle.ShortcutIdentity(try XCTUnwrap(reopened.shortcut(for: command(.leftHalf)))),
                       ShortcutCycle.ShortcutIdentity(custom))
        XCTAssertEqual(before, defaults.persistentDomain(forName: suiteName)! as NSDictionary)
    }

    func testClearMasksRegisteredDefaultAndRemovesLegacyAlias() throws {
        let action = WindowAction.leftHalf
        let entry = command(action)
        let shortcut = MASShortcut(keyCode: kVK_ANSI_D, modifierFlags: [.control, .option])
        defaults.removeObject(forKey: entry.defaultsKey)
        defaults.register(defaults: [entry.defaultsKey: try encoded(shortcut)])
        let alias = try XCTUnwrap(action.aliasName)
        try store(shortcut, key: alias)
        XCTAssertNotNil(model.shortcut(for: entry))

        model.clear(entry)

        XCTAssertNil(model.shortcut(for: entry))
        XCTAssertEqual(defaults.dictionary(forKey: entry.defaultsKey)?.count, 0)
        XCTAssertNil(defaults.object(forKey: alias))
    }

    func testChangingCommandCommitsOldClearAndNewBindingOnlyOnSave() throws {
        let old = command(.leftHalf)
        let new = command(.tileActiveAppColumns)
        let shortcut = MASShortcut(keyCode: kVK_ANSI_P, modifierFlags: [.control, .option])
        try store(shortcut, key: old.defaultsKey)
        var changeCount = 0
        let observer = notifications.addObserver(forName: .configImported, object: nil, queue: nil) { _ in
            changeCount += 1
        }
        defer { notifications.removeObserver(observer) }

        XCTAssertTrue(model.conflicts(for: shortcut, assigning: new, replacing: old).isEmpty)
        XCTAssertNotNil(model.shortcut(for: old))
        XCTAssertNil(model.shortcut(for: new))
        XCTAssertEqual(changeCount, 0)

        try model.save(command: new, shortcut: shortcut, replacing: old)

        XCTAssertNil(model.shortcut(for: old))
        XCTAssertEqual(defaults.dictionary(forKey: old.defaultsKey)?.count, 0)
        XCTAssertEqual(ShortcutCycle.ShortcutIdentity(try XCTUnwrap(model.shortcut(for: new))),
                       ShortcutCycle.ShortcutIdentity(shortcut))
        XCTAssertEqual(changeCount, 1)
    }

    func testConflictReportingIncludesEveryCycleMemberAndAncillaryCommand() throws {
        let shortcut = MASShortcut(keyCode: kVK_ANSI_P, modifierFlags: [.control, .option])
        let keys = [WindowAction.leftHalf.name, WindowAction.rightHalf.name,
                    TodoManager.toggleDefaultsKey, StackBadgeManager.toggleDefaultsKey,
                    ArrangementManager.storeDefaultsKey]
        for key in keys { try store(shortcut, key: key) }

        let collisions = model.conflicts(for: shortcut, assigning: command(.center))
        XCTAssertEqual(Set(collisions.map { $0.command.defaultsKey }), Set(keys))
        XCTAssertFalse(model.canShareCycle(command: command(.center), conflicts: collisions))
    }

    func testRejectedSaveLeavesBothOriginalAndConflictingCommandsUntouched() throws {
        let oldShortcut = MASShortcut(keyCode: kVK_ANSI_P, modifierFlags: [.control, .option])
        let proposedShortcut = MASShortcut(keyCode: kVK_ANSI_O, modifierFlags: [.control, .option])
        try store(oldShortcut, key: WindowAction.leftHalf.name)
        try store(proposedShortcut, key: WindowAction.rightHalf.name)
        let before = try XCTUnwrap(defaults.persistentDomain(forName: suiteName)) as NSDictionary

        XCTAssertThrowsError(try model.save(command: command(.center), shortcut: proposedShortcut,
                                           replacing: command(.leftHalf)))

        XCTAssertEqual(before, defaults.persistentDomain(forName: suiteName)! as NSDictionary)
    }

    func testSharedCycleRequiresExplicitChoiceAndPreservesOtherMembers() throws {
        let shortcut = MASShortcut(keyCode: kVK_ANSI_P, modifierFlags: [.control, .option])
        try store(shortcut, key: WindowAction.leftHalf.name)
        try store(shortcut, key: WindowAction.rightHalf.name)
        let center = command(.center)
        let collisions = model.conflicts(for: shortcut, assigning: center)

        XCTAssertTrue(model.canShareCycle(command: center, conflicts: collisions))
        XCTAssertThrowsError(try model.save(command: center, shortcut: shortcut))
        try model.save(command: center, shortcut: shortcut, resolution: .shareCycle)

        let groups = ShortcutCycle.groups(shortcutsByAction: ShortcutCycle.shortcutsByAction(userDefaults: defaults))
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.actions, [.leftHalf, .rightHalf, .center])
        XCTAssertEqual(groups.first?.action(after: .leftHalf), .rightHalf)
    }

    func testReplaceConflictsClearsAllOtherOwnersIncludingAncillary() throws {
        let shortcut = MASShortcut(keyCode: kVK_ANSI_P, modifierFlags: [.control, .option])
        let existingKeys = [WindowAction.leftHalf.name, WindowAction.rightHalf.name,
                            ArrangementManager.restoreDefaultsKey]
        for key in existingKeys { try store(shortcut, key: key) }

        try model.save(command: command(.tileActiveAppColumns), shortcut: shortcut, resolution: .replaceConflicts)

        XCTAssertEqual(model.assignedBindings.map { $0.command.windowAction }, [.tileActiveAppColumns])
        for key in existingKeys {
            XCTAssertEqual(defaults.dictionary(forKey: key)?.count, 0)
        }
    }

    func testAppAndMultiWindowCommandsCannotBeAddedToSharedCycles() throws {
        let shortcut = MASShortcut(keyCode: kVK_ANSI_P, modifierFlags: [.control, .option])
        try store(shortcut, key: WindowAction.leftHalf.name)
        let before = try XCTUnwrap(defaults.persistentDomain(forName: suiteName)) as NSDictionary
        let saveArrangement = try XCTUnwrap(ShortcutEditorModel.catalog.first {
            $0.defaultsKey == ArrangementManager.storeDefaultsKey
        })

        XCTAssertThrowsError(try model.save(command: command(.tileActiveAppColumns), shortcut: shortcut,
                                           resolution: .shareCycle))
        XCTAssertThrowsError(try model.save(command: saveArrangement, shortcut: shortcut, resolution: .shareCycle))
        XCTAssertEqual(before, defaults.persistentDomain(forName: suiteName)! as NSDictionary)
    }

    func testRestorePresetChangesOnlyShortcutPreferences() throws {
        let unrelatedValues: [String: Any] = ["alternateDefaultShortcuts": false, "gapSize": 19,
                                              "snapAreas": ["left": 7], "customUnrelatedSetting": "keep"]
        for (key, value) in unrelatedValues { defaults.set(value, forKey: key) }
        let custom = MASShortcut(keyCode: kVK_ANSI_P, modifierFlags: [.command, .control])
        try store(custom, key: WindowAction.topLeftSixteenth.name)
        try store(custom, key: TodoManager.toggleDefaultsKey)
        try store(custom, key: StackBadgeManager.toggleDefaultsKey)

        try model.restoreDefaultPreset()

        XCTAssertEqual(model.assignedBindings.count, 30)
        XCTAssertEqual(model.shortcut(for: command(.leftHalf))?.keyCode, kVK_LeftArrow)
        XCTAssertEqual(model.shortcut(for: command(.leftHalf))?.modifierFlags, [.control, .option])
        XCTAssertNotNil(model.shortcut(for: command(.centerTwoThirds)))
        XCTAssertNotNil(model.shortcut(for: command(.tileActiveAppColumns)))
        XCTAssertNil(model.shortcut(for: command(.topLeftSixteenth)))
        XCTAssertEqual(defaults.dictionary(forKey: TodoManager.toggleDefaultsKey)?.count, 0)
        XCTAssertNotNil(ShortcutCycle.shortcut(forDefaultsKey: TodoManager.reflowDefaultsKey, userDefaults: defaults))
        XCTAssertEqual(defaults.dictionary(forKey: StackBadgeManager.toggleDefaultsKey)?.count, 0)
        for (key, value) in unrelatedValues {
            XCTAssertEqual(defaults.object(forKey: key) as? NSObject, value as? NSObject)
        }
    }

    func testPresetsCommitOnceAndClearCommandsOutsideTheSelectedSet() throws {
        var changeCount = 0
        let observer = notifications.addObserver(forName: .configImported, object: nil, queue: nil) { _ in
            changeCount += 1
        }
        defer { notifications.removeObserver(observer) }

        try model.applyPreset(.compact)
        XCTAssertEqual(changeCount, 1)
        XCTAssertEqual(Set(model.assignedBindings.compactMap { $0.command.windowAction }),
                       Set([.leftHalf, .rightHalf, .topHalf, .bottomHalf, .maximize, .center,
                            .previousDisplay, .nextDisplay, .restore]))

        try model.applyPreset(.appTiling)
        XCTAssertEqual(changeCount, 2)
        XCTAssertEqual(Set(model.assignedBindings.compactMap { $0.command.windowAction }),
                       Set([.tileRows, .tileColumns, .tileActiveAppRows, .tileActiveAppColumns, .tileActiveApp]))
        XCTAssertNil(model.shortcut(for: command(.leftHalf)))
        XCTAssertEqual(defaults.dictionary(forKey: WindowAction.leftHalf.name)?.count, 0)
    }

    func testConfigRoundTripPreservesExplicitlyClearedWindowAndAncillaryShortcuts() throws {
        let removedKeys = [WindowAction.leftHalf.name, TodoManager.toggleDefaultsKey,
                           ArrangementManager.restoreDefaultsKey]
        let registered = MASShortcut(keyCode: kVK_ANSI_P, modifierFlags: [.control, .option])
        for key in removedKeys { defaults.register(defaults: [key: try encoded(registered)]) }
        let custom = MASShortcut(keyCode: kVK_ANSI_O, modifierFlags: [.command, .control])
        try model.save(command: command(.rightHalf), shortcut: custom)

        let snapshot = Config.shortcutSnapshot(userDefaults: defaults)
        let config = Config(bundleId: "io.github.jduprat.Tugboat", version: "test",
                            shortcuts: snapshot.shortcuts, defaults: [:], clearedShortcuts: snapshot.clearedShortcuts)
        let reimported = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        XCTAssertTrue(Set(removedKeys).isSubset(of: Set(try XCTUnwrap(reimported.clearedShortcuts))))

        for key in removedKeys { defaults.removeObject(forKey: key) }
        defaults.removeObject(forKey: WindowAction.rightHalf.name)
        XCTAssertNotNil(ShortcutCycle.shortcut(forDefaultsKey: WindowAction.leftHalf.name, userDefaults: defaults))
        reimported.applyShortcutPreferences(userDefaults: defaults)

        for key in removedKeys {
            XCTAssertNil(ShortcutCycle.shortcut(forDefaultsKey: key, userDefaults: defaults))
            XCTAssertEqual(defaults.dictionary(forKey: key)?.count, 0)
        }
        XCTAssertEqual(ShortcutCycle.ShortcutIdentity(try XCTUnwrap(model.shortcut(for: command(.rightHalf)))),
                       ShortcutCycle.ShortcutIdentity(custom))
    }

    func testLegacyConfigStillRestoresRegisteredDefaultsForMissingKeys() throws {
        let key = WindowAction.leftHalf.name
        let registered = MASShortcut(keyCode: kVK_LeftArrow, modifierFlags: [.control, .option])
        defaults.register(defaults: [key: try encoded(registered)])
        let config = Config(bundleId: "io.github.jduprat.Tugboat", version: "legacy", shortcuts: [:], defaults: [:])
        let data = try JSONEncoder().encode(config)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["clearedShortcuts"])
        let decoded = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertNil(decoded.clearedShortcuts)

        decoded.applyShortcutPreferences(userDefaults: defaults)

        XCTAssertNil(defaults.persistentDomain(forName: suiteName)?[key])
        XCTAssertEqual(ShortcutCycle.ShortcutIdentity(try XCTUnwrap(model.shortcut(for: command(.leftHalf)))),
                       ShortcutCycle.ShortcutIdentity(registered))
    }

    func testExplicitConfigClearWinsOverShortcutAndRemovesStaleAlias() throws {
        let action = WindowAction.leftHalf
        let alias = try XCTUnwrap(action.aliasName)
        let shortcut = MASShortcut(keyCode: kVK_ANSI_P, modifierFlags: [.control, .option])
        try store(shortcut, key: alias)
        let config = Config(bundleId: "io.github.jduprat.Tugboat", version: "test",
                            shortcuts: [action.name: Shortcut(masShortcut: shortcut)], defaults: [:],
                            clearedShortcuts: [action.name])

        config.applyShortcutPreferences(userDefaults: defaults)

        XCTAssertNil(defaults.object(forKey: alias))
        XCTAssertNil(model.shortcut(for: command(action)))
        XCTAssertEqual(defaults.dictionary(forKey: action.name)?.count, 0)
    }

    private func command(_ action: WindowAction) -> ShortcutEditorModel.Command {
        ShortcutEditorModel.catalog.first { $0.windowAction == action }!
    }

    private func encoded(_ shortcut: MASShortcut) throws -> [String: Any] {
        let transformer = try XCTUnwrap(ValueTransformer(forName: NSValueTransformerName(rawValue: MASDictionaryTransformerName)))
        return try XCTUnwrap(transformer.reverseTransformedValue(shortcut) as? [String: Any])
    }

    private func store(_ shortcut: MASShortcut, key: String) throws {
        defaults.set(try encoded(shortcut), forKey: key)
    }
}
