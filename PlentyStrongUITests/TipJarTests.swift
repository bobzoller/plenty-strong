import XCTest
import StoreKitTest

final class TipJarTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    @MainActor func testTipPreservesTrainingCapabilitiesAndSavedActuals() throws {
        let session = try SKTestSession(configurationFileNamed: "Tips")
        session.resetToDefaultState(); session.clearTransactions(); session.disableDialogs = true
        defer { session.clearTransactions() }
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-local-store", "-fixture", "history-10-10-9", "-local-storekit-tips"]
        app.launch()
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 15)); app.buttons["today.start"].tap()
        capture("Tip training entry before bounded reveal", app: app)
        app.revealWorkoutControl(app.textFields["set.reps"])
        XCTAssertTrue(app.textFields["set.reps"].waitForExistence(timeout: 10))
        capture("Tip training entry fully revealed before purchase", app: app)
        let capabilities = [app.buttons["workout.easier"].exists, app.buttons["movement.partial-action"].exists, app.textFields["set.reps"].exists]
        XCTAssertEqual(capabilities, [true, true, true])
        XCTAssertEqual(app.staticTexts["workout.session-mode"].label, "Normal workout")
        let pendingEntry = app.textFields["set.reps"].value as? String
        app.selectNativeTab("Settings", identifier: "tab.settings"); app.buttons["settings.tips"].tap()
        XCTAssertTrue(app.staticTexts["tips.disclosure"].waitForExistence(timeout: 10))
        let tip = app.buttons["tips.product.us.zoller.PlentyStrong.tip.small"]
        XCTAssertTrue(tip.waitForExistence(timeout: 15)); XCTAssertTrue(tip.label.contains("$0.99")); tip.tap()
        XCTAssertTrue(app.staticTexts["tips.thank-you"].waitForExistence(timeout: 15))
        app.selectNativeTab("History", identifier: "tab.history"); app.buttons["history.first-workout"].tap()
        XCTAssertEqual(app.staticTexts["history.actual-reps"].label, "10, 10, 9")
        app.selectNativeTab("Today", identifier: "tab.today")
        app.revealWorkoutControl(app.textFields["set.reps"])
        capture("Tip training entry fully revealed after purchase", app: app)
        XCTAssertEqual([app.buttons["workout.easier"].exists, app.buttons["movement.partial-action"].exists, app.textFields["set.reps"].exists], capabilities)
        XCTAssertEqual(app.staticTexts["workout.session-mode"].label, "Normal workout")
        XCTAssertEqual(app.textFields["set.reps"].value as? String, pendingEntry)
        app.selectNativeTab("Settings", identifier: "tab.settings")
        app.navigationBars.buttons.firstMatch.tap(); app.buttons["settings.backup"].tap(); app.buttons["backup.export"].tap()
        XCTAssertTrue(app.buttons["backup.share"].waitForExistence(timeout: 10))
    }
    @MainActor private func capture(_ name: String, app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + " hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
    }
    @MainActor func testNativeLocalPurchaseCancellationKeepsTipsAndTrainingUsable() throws {
        let session = try SKTestSession(configurationFileNamed: "Tips")
        session.resetToDefaultState(); session.clearTransactions(); session.disableDialogs = false
        defer { session.clearTransactions() }
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-local-store", "-fixture", "history-10-10-9", "-local-storekit-tips"]
        app.launch(); app.selectNativeTab("Settings", identifier: "tab.settings"); app.buttons["settings.tips"].tap()
        let tip = app.buttons["tips.product.us.zoller.PlentyStrong.tip.small"]
        XCTAssertTrue(tip.waitForExistence(timeout: 15)); tip.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let cancel = springboard.buttons["dismiss"].firstMatch
        let purchase = springboard.buttons["Purchase"].firstMatch
        // Existence can precede the native sheet's presentation animation.
        // Wait for its lower purchase control to be hittable before dismissal.
        let presented = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            cancel.exists && purchase.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [presented], timeout: 10), .completed)
        cancel.tap()
        // Both observations share the original post-tap budget. A button-state
        // timeout alone cannot establish that the native sheet was dismissed.
        let idle = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !cancel.exists && tip.isEnabled
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [idle], timeout: 10), .completed)
        XCTAssertFalse(app.staticTexts["tips.thank-you"].exists); XCTAssertFalse(app.staticTexts["tips.failure"].exists)
        app.selectNativeTab("Today", identifier: "tab.today"); XCTAssertTrue(app.buttons["today.start"].exists)
    }
    @MainActor func testProductFailureLeavesBackupAndEasierPartialWorkoutUsable() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-local-store", "-fixture", "history-10-10-9", "-products-unavailable", "-cloud-disabled"]
        app.launch(); app.selectNativeTab("Settings", identifier: "tab.settings"); app.buttons["settings.tips"].tap()
        XCTAssertTrue(app.staticTexts["tips.failure"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tips.product.")).count, 0)
        app.navigationBars.buttons.firstMatch.tap(); app.buttons["settings.backup"].tap(); app.buttons["backup.export"].tap()
        XCTAssertTrue(app.buttons["backup.share"].waitForExistence(timeout: 10))
        app.selectNativeTab("Today", identifier: "tab.today")
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 10)); app.buttons["today.start"].tap()
        app.revealWorkoutControl(app.textFields["set.reps"])
        XCTAssertTrue(app.textFields["set.reps"].waitForExistence(timeout: 10))
        app.revealWorkoutControl(app.buttons["workout.easier"])
        app.buttons["workout.easier"].tap()
        let easier = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Easier workout"), object: app.staticTexts["workout.session-mode"])
        XCTAssertEqual(XCTWaiter.wait(for: [easier], timeout: 10), .completed)
    }
}
