import XCTest

final class DeveloperDemoModeUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    @MainActor private func startOrResume(_ app: XCUIApplication) {
        let started = Date()
        app.buttons["today.start"].tap()
        XCTAssertTrue(app.buttons["workout.close"].waitForExistence(timeout: 15))
        print("DEMO_UI_START_OR_RESUME_SECONDS \(Date().timeIntervalSince(started))")
    }
    @MainActor private func toggle(_ app: XCUIApplication, enabled: Bool, confirm: Bool = false) {
        let toggle = app.switches["developer.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 20))
        let started = Date()
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        if confirm {
            XCTAssertTrue(app.alerts["Switch to demo data?"].waitForExistence(timeout: 5))
            app.alerts.buttons["Use demo data"].tap()
        }
        if enabled {
            XCTAssertTrue(app.descendants(matching: .any)["developer.switching"].waitForExistence(timeout: 5))
            let progress = XCTAttachment(screenshot: app.screenshot())
            progress.name = "Synthetic demo seed progress"; progress.lifetime = .keepAlways; add(progress)
            XCTAssertTrue(app.staticTexts["developer.demo-banner"].waitForExistence(timeout: 120))
            let ready = XCTAttachment(screenshot: app.screenshot())
            ready.name = "Synthetic demo ready with persistent label"; ready.lifetime = .keepAlways; add(ready)
            print("DEMO_UI_ACTIVATION_SECONDS \(Date().timeIntervalSince(started))")
        }
        else {
            let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.staticTexts["developer.demo-banner"])
            XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 20), .completed)
        }
    }
    @MainActor func testEmptyRealStoreRestoresOnboardingAndRelaunchKeepsDemoDraft() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-local-store", "-cloud-disabled"]
        app.launch()
        toggle(app, enabled: true, confirm: true)
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 15))
        app.selectNativeTab("History", identifier: "tab.history")
        XCTAssertTrue(app.buttons["history.first-workout"].waitForExistence(timeout: 10))
        app.buttons["history.first-workout"].tap()
        XCTAssertTrue(app.staticTexts["history.actual-reps"].waitForExistence(timeout: 5))
        app.selectNativeTab("Today", identifier: "tab.today")
        startOrResume(app)
        app.terminate()
        app.launchArguments = ["-ui-testing", "-cloud-disabled"]
        app.launch()
        XCTAssertTrue(app.staticTexts["developer.demo-banner"].waitForExistence(timeout: 120))
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["today.start"].label, "Resume workout")
        app.selectNativeTab("Settings", identifier: "tab.settings")
        toggle(app, enabled: false)
        XCTAssertTrue(app.buttons["onboarding.confirm"].waitForExistence(timeout: 10))
        toggle(app, enabled: true)
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["today.start"].label, "Start workout")
    }
    @MainActor func testTerminationDuringSeedLeavesRealOnboardingAccessible() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-local-store", "-cloud-disabled"]
        app.launch()
        XCTAssertTrue(app.switches["developer.toggle"].waitForExistence(timeout: 20))
        app.switches["developer.toggle"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.alerts.buttons["Use demo data"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["developer.switching"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["-ui-testing", "-cloud-disabled"]
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.confirm"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["developer.demo-banner"].exists)
        toggle(app, enabled: true, confirm: true)
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 10))
    }
    @MainActor func testPopulatedRealSavedDraftReturnsAndRetainedNavigationResets() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-local-store", "-fixture", "history-10-10-9", "-cloud-disabled"]
        app.launch()
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 20))
        startOrResume(app)
        app.selectNativeTab("Settings", identifier: "tab.settings")
        toggle(app, enabled: true, confirm: true)
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 10))
        app.selectNativeTab("History", identifier: "tab.history")
        app.buttons["history.first-workout"].tap()
        app.selectNativeTab("Settings", identifier: "tab.settings")
        toggle(app, enabled: false)
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["today.start"].label, "Resume workout")
        startOrResume(app)
        XCTAssertFalse(app.staticTexts["developer.demo-banner"].exists)
    }
}
