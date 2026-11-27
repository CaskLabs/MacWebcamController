import AppKit
import XCTest
@testable import MacWebcamController

final class ControlSliderTests: XCTestCase {
    @MainActor
    func testAccessibilityActionsSendHardwareFacingActionOnValidGrid() {
        let slider = ResettableNSSlider()
        let target = SliderActionTarget()
        slider.minValue = 3
        slider.maxValue = 24
        slider.valueStep = 5
        slider.doubleValue = 8
        slider.target = target
        slider.action = #selector(SliderActionTarget.changed(_:))

        XCTAssertTrue(slider.accessibilityPerformIncrement())
        XCTAssertEqual(target.values, [13])
        XCTAssertTrue(slider.accessibilityPerformDecrement())
        XCTAssertEqual(target.values, [13, 8])
        slider.doubleValue = 23
        XCTAssertTrue(slider.accessibilityPerformIncrement())
        XCTAssertEqual(slider.doubleValue, 23)
        slider.isEnabled = false
        XCTAssertFalse(slider.accessibilityPerformDecrement())
        XCTAssertEqual(target.values, [13, 8, 23])
    }

    @MainActor
    func testArrowKeySendsActionWithoutMouseTracking() throws {
        let slider = ResettableNSSlider()
        let target = SliderActionTarget()
        slider.minValue = 3
        slider.maxValue = 23
        slider.valueStep = 5
        slider.doubleValue = 8
        slider.target = target
        slider.action = #selector(SliderActionTarget.changed(_:))
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{F703}",
            charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124
        ))
        slider.keyDown(with: event)
        XCTAssertEqual(target.values, [13])
        XCTAssertFalse(slider.isTrackingMouse)
    }
}

@MainActor
private final class SliderActionTarget: NSObject {
    var values: [Double] = []
    @objc func changed(_ sender: NSSlider) { values.append(sender.doubleValue) }
}
