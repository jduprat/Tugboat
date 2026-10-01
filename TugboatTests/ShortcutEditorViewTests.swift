import Cocoa
import MASShortcut
import XCTest
@testable import Tugboat

/// Exercises the real AppKit controls using isolated preferences. A window is shown only
/// for the opt-in visual check; no system keyboard events or accessibility actions run.
final class ShortcutEditorViewTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var model: ShortcutEditorModel!
    private var controller: PrefsViewController!

    override func setUpWithError() throws {
        _ = MASShortcutBinder.shared()
        suiteName = "ShortcutEditorViewTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        for command in ShortcutEditorModel.catalog {
            defaults.set([String: Any](), forKey: command.defaultsKey)
        }
        model = ShortcutEditorModel(userDefaults: defaults, notificationCenter: NotificationCenter())
    }

    override func tearDownWithError() throws {
        controller?.viewWillDisappear()
        controller = nil
        model = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    func testNewShortcutCanBeCancelledWithoutWritingPreferences() throws {
        try store(.leftHalf, key: kVK_ANSI_J)
        openEditor()
        let before = try persistentPreferences()

        try button("＋").performClick(nil)
        let recorder = try control(MASShortcutView.self)
        recorder.shortcutValue = shortcut(kVK_ANSI_P)
        try chooseFamily(.arrange)

        XCTAssertEqual(try persistentPreferences(), before)
        try button("Cancel").performClick(nil)
        XCTAssertEqual(try persistentPreferences(), before)
        XCTAssertEqual(try control(NSTableView.self).numberOfRows, 1)
    }

    func testChangingCommandCommitsOnlyAfterSave() throws {
        try store(.leftHalf, key: kVK_ANSI_J)
        openEditor()
        try chooseFamily(.arrange)
        let target = try XCTUnwrap(ShortcutEditorModel.catalog.first { $0.family == .arrange })

        XCTAssertNotNil(model.shortcut(for: command(.leftHalf)))
        XCTAssertNil(model.shortcut(for: target))
        XCTAssertTrue(try button("Save Shortcut").isEnabled)
        try button("Save Shortcut").performClick(nil)

        XCTAssertNil(model.shortcut(for: command(.leftHalf)))
        XCTAssertEqual(identity(model.shortcut(for: target)), identity(shortcut(kVK_ANSI_J)))
    }

    func testDraftSurvivesSelectionChangesAndCancelRestoresSavedKey() throws {
        try store(.leftHalf, key: kVK_ANSI_J)
        try store(.rightHalf, key: kVK_ANSI_K)
        openEditor()
        let recorder = try control(MASShortcutView.self)
        recorder.shortcutValue = shortcut(kVK_ANSI_P)
        let table = try control(NSTableView.self)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        XCTAssertEqual(identity(recorder.shortcutValue), identity(shortcut(kVK_ANSI_P)))
        XCTAssertEqual(identity(model.shortcut(for: command(.leftHalf))), identity(shortcut(kVK_ANSI_J)))
        try button("Cancel").performClick(nil)
        XCTAssertEqual(identity(recorder.shortcutValue), identity(shortcut(kVK_ANSI_J)))
    }

    func testConflictingKeyRequiresExplicitResolutionBeforeSave() throws {
        try store(.leftHalf, key: kVK_ANSI_J)
        try store(.rightHalf, key: kVK_ANSI_K)
        openEditor()
        try control(MASShortcutView.self).shortcutValue = shortcut(kVK_ANSI_K)

        let save = try button("Save Shortcut")
        XCTAssertFalse(save.isEnabled)
        let resolution = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSPopUpButton }
            .first { $0.itemTitles.contains("Replace conflicting shortcuts") })
        resolution.selectItem(withTitle: "Replace conflicting shortcuts")
        resolution.sendAction(resolution.action, to: resolution.target)
        XCTAssertTrue(save.isEnabled)
        save.performClick(nil)

        XCTAssertEqual(identity(model.shortcut(for: command(.leftHalf))), identity(shortcut(kVK_ANSI_K)))
        XCTAssertNil(model.shortcut(for: command(.rightHalf)))
    }

    func testUntouchedSelectionRefreshesAfterExternalPreferenceChange() throws {
        try store(.leftHalf, key: kVK_ANSI_J)
        try store(.rightHalf, key: kVK_ANSI_K)
        openEditor()
        try store(.leftHalf, key: kVK_ANSI_P)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)

        XCTAssertEqual(identity(try control(MASShortcutView.self).shortcutValue), identity(shortcut(kVK_ANSI_P)),
                       "An untouched editor must not retain a key from before import or a legacy-editor change.")
    }

    func testClearingRecordedKeyDisablesSaveWithoutRemovingSavedShortcut() throws {
        try store(.leftHalf, key: kVK_ANSI_J)
        openEditor()
        try control(MASShortcutView.self).shortcutValue = nil

        XCTAssertFalse(try button("Save Shortcut").isEnabled)
        XCTAssertNotNil(model.shortcut(for: command(.leftHalf)))
        try button("Cancel").performClick(nil)
        XCTAssertEqual(identity(try control(MASShortcutView.self).shortcutValue), identity(shortcut(kVK_ANSI_J)))
    }

    func testSearchCannotHighlightOneBindingWhileEditingAnother() throws {
        try store(.leftHalf, key: kVK_ANSI_J)
        try store(.rightHalf, key: kVK_ANSI_K)
        openEditor()
        let search = try control(NSSearchField.self)
        search.stringValue = command(.rightHalf).title
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))

        let table = try control(NSTableView.self)
        XCTAssertEqual(table.numberOfRows, 1)
        if table.selectedRow >= 0 {
            XCTAssertEqual(identity(try control(MASShortcutView.self).shortcutValue), identity(shortcut(kVK_ANSI_K)),
                           "The inspector must match the highlighted search result.")
        }
    }

    func testLeavingEditorEndsRecordingAndResumesShortcutNotifications() throws {
        try store(.leftHalf, key: kVK_ANSI_J)
        openEditor()
        var changes = [Bool]()
        let observer = NotificationCenter.default.addObserver(forName: .shortcutRecording, object: nil, queue: nil) {
            if let value = $0.object as? Bool { changes.append(value) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let recorder = try control(MASShortcutView.self)
        recorder.isRecording = true
        controller.viewWillDisappear()

        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(changes, [true, false])
    }

    func testOffscreenEditorHasUsableLayoutAndRetainsAllActionFamilies() throws {
        try store(.leftHalf, key: kVK_ANSI_J)
        openEditor()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 560),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.contentViewController = nil; window.close() }
        window.appearance = NSAppearance(named: .aqua)
        controller.view.layoutSubtreeIfNeeded()

        let recorder = try control(MASShortcutView.self)
        let recorderBounds = recorder.convert(recorder.bounds, to: controller.view)
        XCTAssertGreaterThan(recorderBounds.width, 100)
        XCTAssertTrue(controller.view.bounds.contains(recorderBounds))
        XCTAssertGreaterThan(try control(NSTableView.self).visibleRect.height, 100)
        let family = try familyPicker()
        XCTAssertEqual(family.itemTitles, ShortcutEditorModel.Family.allCases.map(\.rawValue))

        // Opt-in native visual inspection uses isolated preferences and holds only this window.
        if ProcessInfo.processInfo.environment["TUGBOAT_EDITOR_VISUAL_TEST"] == "1" {
            window.title = "Tugboat Shortcut Editor — Visual Check"
            window.makeKeyAndOrderFront(nil)
            window.displayIfNeeded()
            controller.view.displayIfNeeded()
            NSApp.activate(ignoringOtherApps: true)
            RunLoop.current.run(until: Date().addingTimeInterval(45))
        }

        // The snapshot is attached to the native test result for visual review.
        let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let image = NSImage(size: controller.view.bounds.size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Shortcut editor at 800 by 560"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openEditor() {
        controller = PrefsViewController(nibName: nil, bundle: nil)
        controller.model = model
        _ = controller.view
    }

    private func shortcut(_ key: Int) -> MASShortcut {
        MASShortcut(keyCode: key, modifierFlags: [.control, .option, .shift])
    }

    private func command(_ action: WindowAction) -> ShortcutEditorModel.Command {
        ShortcutEditorModel.catalog.first { $0.windowAction == action }!
    }

    private func store(_ action: WindowAction, key: Int) throws {
        let transformer = try XCTUnwrap(ValueTransformer(forName: NSValueTransformerName(rawValue: MASDictionaryTransformerName)))
        defaults.set(transformer.reverseTransformedValue(shortcut(key)), forKey: action.name)
    }

    private func identity(_ shortcut: MASShortcut?) -> ShortcutCycle.ShortcutIdentity? {
        shortcut.map(ShortcutCycle.ShortcutIdentity.init)
    }

    private func persistentPreferences() throws -> NSDictionary {
        try XCTUnwrap(defaults.persistentDomain(forName: suiteName)) as NSDictionary
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func control<T: NSView>(_ type: T.Type) throws -> T {
        try XCTUnwrap(descendants(controller.view).compactMap { $0 as? T }.first)
    }

    private func button(_ title: String) throws -> NSButton {
        try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == title })
    }

    private func familyPicker() throws -> NSPopUpButton {
        try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSPopUpButton }
            .first { $0.itemTitles == ShortcutEditorModel.Family.allCases.map(\.rawValue) })
    }

    private func chooseFamily(_ family: ShortcutEditorModel.Family) throws {
        let picker = try familyPicker()
        picker.selectItem(withTitle: family.rawValue)
        picker.sendAction(picker.action, to: picker.target)
    }
}
