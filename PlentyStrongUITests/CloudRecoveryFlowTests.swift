import XCTest

final class CloudRecoveryFlowTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    @MainActor private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
    @MainActor private func launch(_ fixture: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-local-store", "-fixture", fixture]
        app.launch(); return app
    }
    @MainActor func testPendingUploadDoesNotClaimRecoveryComplete() {
        let app = launch("cloud-pending")
        app.selectNativeTab("Settings", identifier: "tab.settings")
        app.buttons["settings.cloud-recovery"].tap()
        XCTAssertEqual(app.staticTexts["sync.pending-count"].label, "1 completed workout waiting to upload")
        XCTAssertFalse(app.staticTexts["sync.all-uploaded"].exists)
        XCTAssertTrue(app.staticTexts["sync.draft-disclosure"].exists)
    }
    @MainActor func testDeclineRecoveryAndFinishOnboardingOffline() {
        let app = launch("cloud-no-account")
        XCTAssertTrue(app.buttons["onboarding.cloud-recovery"].waitForExistence(timeout: 15))
        app.buttons["onboarding.cloud-recovery"].tap()
        app.buttons["sync.enable"].tap()
        XCTAssertTrue(app.staticTexts["sync.account-unavailable"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["sync.account-unavailable"].label.contains("iOS Settings"))
        app.buttons["sync.disable"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["onboarding.goal.size"].tap(); app.buttons["onboarding.confirm"].tap()
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 15))
    }
    @MainActor func testFullStorageOffersExportAndRetainsHistoryWhenDisabled() {
        let app = launch("cloud-quota")
        app.selectNativeTab("Settings", identifier: "tab.settings"); app.buttons["settings.cloud-recovery"].tap()
        XCTAssertTrue(app.staticTexts["sync.retry-reason"].label.contains("storage is full"))
        XCTAssertFalse(app.staticTexts["sync.all-uploaded"].exists)
        scrollTo(app.buttons["sync.export"], in: app); app.buttons["sync.export"].tap()
        XCTAssertTrue(app.buttons["sync.share"].waitForExistence(timeout: 10))
        scrollTo(app.buttons["sync.export-staged"], in: app); app.buttons["sync.export-staged"].tap()
        XCTAssertTrue(app.buttons["sync.share-staged"].waitForExistence(timeout: 10))
        for _ in 0..<8 where !app.buttons["sync.disable"].isHittable { app.swipeDown() }
        app.buttons["sync.disable"].tap()
        app.selectNativeTab("History", identifier: "tab.history"); app.buttons["history.first-workout"].tap()
        XCTAssertEqual(app.staticTexts["history.actual-reps"].label, "10, 10, 9")
    }
}

extension CloudRecoveryFlowTests {
    @MainActor func testPartialRecoveryBlocksAffectedProgressionAndOffersExport() {
        let app = launch("cloud-partial")
        XCTAssertTrue(app.staticTexts["store.health"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["today.start"].isEnabled)
        app.selectNativeTab("Settings", identifier: "tab.settings"); app.buttons["settings.cloud-recovery"].tap()
        XCTAssertTrue(app.staticTexts["sync.incomplete"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["sync.all-uploaded"].exists)
        scrollTo(app.buttons["sync.export"], in: app); XCTAssertTrue(app.buttons["sync.export"].exists)
    }
    @MainActor func testConflictComparisonPreservesActualsAndSafetyDisclosure() {
        let app = launch("cloud-conflict")
        app.selectNativeTab("Settings", identifier: "tab.settings"); app.buttons["settings.cloud-recovery"].tap()
        let program = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sync.program.")).firstMatch
        for _ in 0..<6 where !program.isHittable { app.swipeUp() }
        XCTAssertTrue(program.isHittable); program.tap(); app.buttons["sync.compare-branches"].tap()
        XCTAssertTrue(app.staticTexts["sync.safety-union"].label.contains("cannot clear a pause"))
        let branches = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sync.branch-details."))
        XCTAssertEqual(branches.count, 2)
        branches.firstMatch.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Paused")).firstMatch.exists || app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "No stored pause")).firstMatch.exists)
        let history = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "recorded sets")).firstMatch
        for _ in 0..<5 where !history.isHittable { app.swipeUp() }
        XCTAssertTrue(history.isHittable); history.tap()
        XCTAssertEqual(app.staticTexts["history.actual-reps"].label, "10, 10, 9")
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Original conflict actuals under stored rules"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
