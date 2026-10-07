import XCTest
final class MovementSetupTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    @MainActor func testOpaqueModificationBaselineAndSavedSelection() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-local-store"]
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.goal.size"].waitForExistence(timeout: 15))
        app.buttons["onboarding.goal.size"].tap(); app.buttons["onboarding.confirm"].tap()
        app.buttons["today.start"].tap(); XCTAssertTrue(app.buttons["movement.setup"].waitForExistence(timeout: 15)); app.buttons["movement.setup"].tap()
        app.textFields["setup.modifications"].tap(); app.textFields["setup.modifications"].typeText("+25 lb")
        app.buttons["setup.new"].tap()
        XCTAssertTrue(app.staticTexts["movement.baseline"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["movement.modifications"].label, "+25 lb")
        let created = XCTAttachment(screenshot: app.screenshot())
        created.name = "Candidate synthetic independent setup baseline"
        created.lifetime = .keepAlways; add(created)
        app.buttons["movement.setup"].tap()
        let description = app.textFields["setup.modifications"]
        description.tap()
        // A native tap may place the cursor inside the original text. Select all
        // explicitly before replacement; never assume backspace starts at its end.
        description.press(forDuration: 1)
        let selectAll = app.menuItems["Select All"].exists ? app.menuItems["Select All"] : app.buttons["Select All"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5)); selectAll.tap()
        description.typeText("Demo neutral grip")
        XCTAssertEqual(description.value as? String, "Demo neutral grip")
        app.buttons["setup.correct-description"].tap()
        let corrected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Demo neutral grip"), object: app.staticTexts["movement.modifications"])
        XCTAssertEqual(XCTWaiter.wait(for: [corrected], timeout: 15), .completed)
        XCTAssertTrue(app.staticTexts["movement.baseline"].exists)
        app.buttons["movement.setup"].tap()
        let saved = app.buttons.matching(NSPredicate(format: "label == %@", "Demo neutral grip"))
        XCTAssertEqual(saved.count, 1); XCTAssertTrue(saved.firstMatch.isHittable)
        let picker = XCTAttachment(screenshot: app.screenshot())
        picker.name = "Candidate synthetic saved setups and description semantics"
        picker.lifetime = .keepAlways; add(picker)
        app.buttons["setup.select.default"].tap()
        XCTAssertEqual(app.staticTexts["movement.modifications"].label, "Default setup")
    }
}
