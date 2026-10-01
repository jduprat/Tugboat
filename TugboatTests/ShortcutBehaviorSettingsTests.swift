import Cocoa
import XCTest
@testable import Tugboat

/// The calculation factory keeps long-lived instances. Editing a shared
/// behavior setting must affect the next execution without relaunching the app.
final class ShortcutBehaviorSettingsTests: XCTestCase {
    private struct SavedPreference {
        let preference: Default
        let value: CodableDefault
        let storedObject: Any?
    }

    private var savedPreferences: [SavedPreference] = []
    private let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let floatingWindow = CGRect(x: 200, y: 200, width: 400, height: 300)

    override func setUp() {
        super.setUp()
        let preferences: [Default] = [
            Defaults.specifiedWidth, Defaults.specifiedHeight,
            Defaults.almostMaximizeWidth, Defaults.almostMaximizeHeight,
            Defaults.sizeOffset, Defaults.widthStepSize, Defaults.gapSize,
            Defaults.curtainChangeSize, Defaults.smallerShrinksMaximizedHeight,
            Defaults.minimumWindowWidth, Defaults.minimumWindowHeight
        ]
        savedPreferences = preferences.map {
            SavedPreference(preference: $0, value: $0.toCodable(),
                            storedObject: UserDefaults.standard.object(forKey: $0.key))
        }
        Defaults.specifiedWidth.value = 600
        Defaults.specifiedHeight.value = 400
        Defaults.almostMaximizeWidth.value = 0
        Defaults.almostMaximizeHeight.value = 0
        Defaults.sizeOffset.value = 30
        Defaults.widthStepSize.value = 30
        Defaults.gapSize.value = 0
        Defaults.curtainChangeSize.enabled = true
        Defaults.smallerShrinksMaximizedHeight.enabled = false
        Defaults.minimumWindowWidth.value = 0
        Defaults.minimumWindowHeight.value = 0
    }

    override func tearDown() {
        for saved in savedPreferences {
            // Restore both the live wrappers and the original on-disk presence
            // of each preference, including optional booleans and unset keys.
            saved.preference.load(from: saved.value)
            if let object = saved.storedObject {
                UserDefaults.standard.set(object, forKey: saved.preference.key)
            } else {
                UserDefaults.standard.removeObject(forKey: saved.preference.key)
            }
        }
        savedPreferences = []
        super.tearDown()
    }

    func testSpecifiedSizeChangesFromPixelsToDisplayFractionsWithoutRecreatingCalculation() {
        let calculation = SpecifiedCalculation()
        let parameters = params(.specified)
        XCTAssertEqual(calculation.calculateRect(parameters).rect,
                       CGRect(x: 200, y: 200, width: 600, height: 400))

        Defaults.specifiedWidth.value = 0.5
        Defaults.specifiedHeight.value = 0.25

        XCTAssertEqual(calculation.calculateRect(parameters).rect,
                       CGRect(x: 250, y: 300, width: 500, height: 200))
    }

    func testAlmostMaximizeChangesFromDefaultToConfiguredPercentagesWithoutRecreatingCalculation() {
        let calculation = AlmostMaximizeCalculation()
        let parameters = params(.almostMaximize)
        XCTAssertEqual(calculation.calculateRect(parameters).rect,
                       CGRect(x: 50, y: 40, width: 900, height: 720))

        Defaults.almostMaximizeWidth.value = 0.6
        Defaults.almostMaximizeHeight.value = 0.5

        XCTAssertEqual(calculation.calculateRect(parameters).rect,
                       CGRect(x: 200, y: 200, width: 600, height: 400))
    }

    func testResizeStepChangesWithoutRecreatingCalculation() {
        let calculation = ChangeSizeCalculation()
        let parameters = params(.larger)
        XCTAssertEqual(calculation.calculateRect(parameters).rect,
                       CGRect(x: 185, y: 185, width: 430, height: 330))

        Defaults.sizeOffset.value = 80

        XCTAssertEqual(calculation.calculateRect(parameters).rect,
                       CGRect(x: 160, y: 160, width: 480, height: 380))
    }

    func testWidthStepRemainsIndependentOfGeneralResizeStep() {
        let calculation = ChangeSizeCalculation()
        XCTAssertEqual(calculation.calculateRect(params(.largerWidth)).rect,
                       CGRect(x: 185, y: 200, width: 430, height: 300))

        Defaults.widthStepSize.value = 60
        Defaults.sizeOffset.value = 80

        XCTAssertEqual(calculation.calculateRect(params(.largerWidth)).rect,
                       CGRect(x: 170, y: 200, width: 460, height: 300))
        XCTAssertEqual(calculation.calculateRect(params(.largerHeight)).rect,
                       CGRect(x: 200, y: 160, width: 400, height: 380))
    }

    func testTurningOffEdgePreservationAffectsExistingCalculation() {
        let calculation = ChangeSizeCalculation()
        let parameters = params(.smaller, window: CGRect(x: 0, y: 0, width: 500, height: 800))
        XCTAssertEqual(calculation.calculateRect(parameters).rect,
                       CGRect(x: 0, y: 0, width: 470, height: 800))

        Defaults.curtainChangeSize.enabled = false

        XCTAssertEqual(calculation.calculateRect(parameters).rect,
                       CGRect(x: 15, y: 15, width: 470, height: 770))
    }

    func testFullHeightShrinkOptionAffectsExistingCalculation() {
        let calculation = ChangeSizeCalculation()
        let parameters = params(.smaller, window: CGRect(x: 0, y: 0, width: 500, height: 800))
        XCTAssertEqual(calculation.calculateRect(parameters).rect,
                       CGRect(x: 0, y: 0, width: 470, height: 800))

        Defaults.smallerShrinksMaximizedHeight.enabled = true

        XCTAssertEqual(calculation.calculateRect(parameters).rect,
                       CGRect(x: 0, y: 15, width: 470, height: 770))
    }

    func testGapChangeUpdatesEdgeDetectionOnExistingCalculation() {
        let calculation = ChangeSizeCalculation()
        let parameters = params(.smaller, window: CGRect(x: 10, y: 200, width: 400, height: 300))
        XCTAssertEqual(calculation.calculateRect(parameters).rect,
                       CGRect(x: 25, y: 215, width: 370, height: 270))

        Defaults.gapSize.value = 20

        XCTAssertEqual(calculation.calculateRect(parameters).rect,
                       CGRect(x: 20, y: 215, width: 370, height: 270))
    }

    private func params(_ action: WindowAction, window: CGRect? = nil) -> RectCalculationParameters {
        RectCalculationParameters(window: Window(id: 1, rect: window ?? floatingWindow),
                                  visibleFrameOfScreen: display,
                                  action: action, lastAction: nil)
    }
}
