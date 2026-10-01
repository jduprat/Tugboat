import Carbon.HIToolbox
import Cocoa
import XCTest
@testable import Tugboat

final class DefaultShortcutTests: XCTestCase {

    func testCleanTugboatInstallIncludesCompleteRectangleDefaults() throws {
        let previousInstallVersion = Defaults.installVersion.value
        defer { Defaults.installVersion.value = previousInstallVersion }
        Defaults.installVersion.value = "1"

        let controlOption: NSEvent.ModifierFlags = [.control, .option]
        let controlOptionShift: NSEvent.ModifierFlags = [.control, .option, .shift]
        let controlOptionCommand: NSEvent.ModifierFlags = [.control, .option, .command]

        // Rectangle's recommended preset, verified against its upstream WindowAction.swift.
        // https://github.com/rxhanson/Rectangle/blob/main/Rectangle/WindowAction.swift
        let expected: [WindowAction: (NSEvent.ModifierFlags, Int)] = [
            .leftHalf: (controlOption, kVK_LeftArrow),
            .rightHalf: (controlOption, kVK_RightArrow),
            .topHalf: (controlOption, kVK_UpArrow),
            .bottomHalf: (controlOption, kVK_DownArrow),
            .topLeft: (controlOption, kVK_ANSI_U),
            .topRight: (controlOption, kVK_ANSI_I),
            .bottomLeft: (controlOption, kVK_ANSI_J),
            .bottomRight: (controlOption, kVK_ANSI_K),
            .maximize: (controlOption, kVK_Return),
            .maximizeHeight: (controlOptionShift, kVK_UpArrow),
            .previousDisplay: (controlOptionCommand, kVK_LeftArrow),
            .nextDisplay: (controlOptionCommand, kVK_RightArrow),
            .larger: (controlOption, kVK_ANSI_Equal),
            .smaller: (controlOption, kVK_ANSI_Minus),
            .center: (controlOption, kVK_ANSI_C),
            .restore: (controlOption, kVK_Delete),
            .firstThird: (controlOption, kVK_ANSI_D),
            .firstTwoThirds: (controlOption, kVK_ANSI_E),
            .centerThird: (controlOption, kVK_ANSI_F),
            .centerTwoThirds: (controlOption, kVK_ANSI_R),
            .lastTwoThirds: (controlOption, kVK_ANSI_T),
            .lastThird: (controlOption, kVK_ANSI_G),
        ]

        for (action, (modifiers, keyCode)) in expected {
            XCTAssertTrue(WindowAction.active.contains(action), action.name)
            let shortcut = try XCTUnwrap(action.alternateDefault, action.name)
            XCTAssertEqual(shortcut.keyCode, keyCode, action.name)
            XCTAssertEqual(shortcut.modifierFlags, modifiers.rawValue, action.name)
        }

        let tugboatAdditions: Set<WindowAction> = [
            .tileRows, .tileColumns, .tileActiveAppRows, .tileActiveAppColumns, .tileActiveApp,
        ]
        let assignedActions = Set(WindowAction.active.filter { $0.alternateDefault != nil })
        XCTAssertEqual(assignedActions, Set(expected.keys).union(tugboatAdditions))
    }

    func testCenterTwoThirdsDefaultDoesNotDependOnUpstreamBuildNumbers() throws {
        let previousInstallVersion = Defaults.installVersion.value
        defer { Defaults.installVersion.value = previousInstallVersion }

        let installVersions: [String?] = [nil, "1", "94", "95", "100", "0.2.0"]
        for version in installVersions {
            Defaults.installVersion.value = version
            let shortcut = try XCTUnwrap(WindowAction.centerTwoThirds.alternateDefault,
                                         "Missing default for install version \(version ?? "unset")")
            XCTAssertEqual(shortcut.keyCode, kVK_ANSI_R)
            XCTAssertEqual(shortcut.modifierFlags, NSEvent.ModifierFlags([.control, .option]).rawValue)
        }

        // The optional Spectacle preset retains its own assignments.
        XCTAssertNil(WindowAction.centerTwoThirds.spectacleDefault)
    }
}
