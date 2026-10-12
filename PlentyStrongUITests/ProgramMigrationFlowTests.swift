import XCTest

final class ProgramMigrationFlowTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-local-store", "-cloud-disabled", "-products-unavailable", "-fixture-migration"]
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.migration"].waitForExistence(timeout: 15))
        app.buttons["onboarding.migration"].tap()
        XCTAssertTrue(app.buttons["migration.synthetic-file"].waitForExistence(timeout: 10))
        app.buttons["migration.synthetic-file"].tap()
        XCTAssertTrue(app.staticTexts["migration.source-counts"].waitForExistence(timeout: 10))
        return app
    }
    @MainActor private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        // Form virtualizes rows. An earlier offscreen choice can disappear from
        // AX after inspecting Preview; start from the top before forward search.
        if !element.exists {
            for _ in 0..<16 {
                if app.buttons["migration.choose-file"].isHittable { break }
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
            }
        }
        app.revealWorkoutControl(element, scrollDistance: 250)
        XCTAssertTrue(element.isHittable)
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor func testGoalBasisPreviewImportAdoptAndReopen() {
        let app = launch()
        let preview = app.buttons["migration.preview"]
        reveal(preview, app: app); XCTAssertFalse(preview.isEnabled)
        let goal = app.buttons["migration.goal.fat_loss"]
        reveal(goal, app: app); goal.tap()
        let basis = app.buttons["migration.basis.db_triceps_extension"]
        reveal(basis, app: app); basis.tap()
        XCTAssertTrue(app.staticTexts["Future basis selected: 25 lb total"].waitForExistence(timeout: 5))
        let acknowledgement = app.switches["migration.acknowledge"]
        reveal(acknowledgement, app: app)
        acknowledgement.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(acknowledgement.value as? String, "1")
        capture(app, "Synthetic explicit future basis and acknowledgement")
        reveal(preview, app: app); XCTAssertTrue(preview.isEnabled); preview.tap()
        let imported = app.buttons["migration.import"]
        reveal(imported, app: app); XCTAssertTrue(imported.waitForExistence(timeout: 15))
        capture(app, "Synthetic migrated range and policy preview")
        imported.tap()
        let adopt = app.buttons["migration.adopt"]
        reveal(adopt, app: app); XCTAssertTrue(adopt.waitForExistence(timeout: 15)); adopt.tap()
        XCTAssertTrue(app.buttons["tab.today"].waitForExistence(timeout: 15))
        app.terminate()
        app.launchArguments = ["-ui-testing", "-cloud-disabled", "-products-unavailable"]
        app.launch()
        XCTAssertTrue(app.buttons["tab.today"].waitForExistence(timeout: 15))
        app.selectNativeTab("History", identifier: "tab.history")
        let external = app.buttons["history.source.source-day:1"]
        XCTAssertTrue(external.waitForExistence(timeout: 10)); external.tap()
        XCTAssertTrue(app.staticTexts["5.5/BW"].waitForExistence(timeout: 10))
        capture(app, "Synthetic external-origin observation detail")
    }
    @MainActor func testSourceDoesNotChooseGoalOrFutureBasis() {
        let app = launch()
        let preview = app.buttons["migration.preview"]
        let acknowledgement = app.switches["migration.acknowledge"]
        reveal(acknowledgement, app: app)
        acknowledgement.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(acknowledgement.value as? String, "1")
        reveal(preview, app: app); XCTAssertFalse(preview.isEnabled)
        let goal = app.buttons["migration.goal.strength"]
        reveal(goal, app: app); goal.tap()
        reveal(preview, app: app); XCTAssertFalse(preview.isEnabled)
        XCTAssertFalse(app.buttons["migration.import"].exists)
        capture(app, "Synthetic unresolved future basis remains protected")
    }
    @MainActor func testExistingDraftKeepsMigrationProtected() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-local-store", "-cloud-disabled", "-products-unavailable",
            "-fixture-migration", "-fixture-exact-reps", "-fixture-exact-mode", "legacy-unfinished"]
        app.launch()
        XCTAssertTrue(app.buttons["tab.settings"].waitForExistence(timeout: 15))
        app.selectNativeTab("Settings", identifier: "tab.settings")
        let migration = app.buttons["settings.migration"]
        XCTAssertTrue(migration.waitForExistence(timeout: 10)); migration.tap()
        app.buttons["migration.synthetic-file"].tap()
        XCTAssertTrue(app.staticTexts["migration.source-counts"].waitForExistence(timeout: 10))
        let lock = app.staticTexts["migration.draft-lock"]
        reveal(lock, app: app)
        let preview = app.buttons["migration.preview"]
        reveal(preview, app: app); XCTAssertFalse(preview.isEnabled)
        XCTAssertFalse(app.buttons["migration.import"].exists)
        capture(app, "Synthetic existing workout blocks migration")
    }

}
