import XCTest
final class OfflineAcceptanceTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    @MainActor func testOptionalServicesDoNotGateWorkoutAndSameStoreResumes() {
        let app = XCUIApplication(); app.launchArguments = ["-ui-testing", "-reset-local-store", "-fixture", "history-10-10-9", "-cloud-disabled", "-products-unavailable"]
        app.launch(); XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 15)); app.buttons["today.start"].tap()
        app.revealWorkoutControl(app.textFields["set.reps"])
        app.terminate(); app.launchArguments = ["-ui-testing", "-cloud-disabled", "-products-unavailable"]; app.launch()
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 15)); XCTAssertEqual(app.buttons["today.start"].label, "Resume workout")
        app.buttons["today.start"].tap(); app.revealWorkoutControl(app.textFields["set.reps"])
    }
    @MainActor func testLargeTextOnboardingKeepsRestoreAndConfirmReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-local-store", "-ui-large-text", "-ui-dark"]
        app.launch()
        let restore = app.buttons["onboarding.restore"]
        XCTAssertTrue(restore.waitForExistence(timeout: 15)); XCTAssertTrue(restore.isHittable)
        let confirm = app.buttons["onboarding.confirm"]
        XCTAssertTrue(confirm.exists); XCTAssertTrue(confirm.isHittable); XCTAssertFalse(confirm.isEnabled)
        let goal = app.buttons["onboarding.goal.size"]
        // Onboarding has its own pinned footer. Reach the whole Size row
        // inside the Form before tapping; a partial AX hit is insufficient.
        app.revealWorkoutControl(goal, pinnedFooter: confirm, scrollDistance: 100)
        XCTAssertTrue(goal.isHittable); goal.tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in goal.isSelected && confirm.isEnabled }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
        XCTAssertTrue(goal.isSelected)
        XCTAssertTrue(confirm.isHittable); XCTAssertTrue(confirm.isEnabled)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Large text onboarding pinned confirmation"; attachment.lifetime = .keepAlways; add(attachment)
        confirm.tap(); XCTAssertTrue(app.staticTexts["today.schedule"].waitForExistence(timeout: 15))
        app.revealWorkoutControl(app.buttons["today.start"])
    }
    @MainActor func testLargeTextDarkModeAndPrivacyLabels() {
        let app = XCUIApplication(); app.launchArguments = ["-ui-testing", "-reset-local-store", "-fixture", "history-10-10-9", "-ui-large-text", "-ui-dark"]
        app.launch(); app.selectNativeTab("Settings", identifier: "tab.settings"); app.buttons["settings.about"].tap()
        XCTAssertTrue(app.staticTexts["about.privacy"].exists)
        XCTAssertTrue(app.staticTexts["about.privacy"].label.contains("No account, no subscription, no telemetry"))
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Accessibility size dark privacy"; attachment.lifetime = .keepAlways; add(attachment)
    }
}

extension OfflineAcceptanceTests {
    @MainActor func testActualSystemReduceMotionKeepsLocalNavigationUsable() {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        let accessibility = settings.staticTexts["Accessibility"].firstMatch
        for _ in 0..<5 where !accessibility.isHittable { settings.swipeUp() }
        XCTAssertTrue(accessibility.waitForExistence(timeout: 10)); accessibility.tap()
        let motion = settings.staticTexts["Motion"].firstMatch
        XCTAssertTrue(motion.waitForExistence(timeout: 10)); motion.tap()
        let toggle = settings.switches["Reduce Motion"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        let original = toggle.value as? String
        defer {
            settings.activate()
            if original == "0", toggle.value as? String == "1" { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
            if let original {
                let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", original), object: toggle)
                XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 10), .completed)
            }
        }
        if original == "0" { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed)
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-local-store", "-fixture-exact-reps", "-cloud-disabled", "-products-unavailable"]
        app.launch(); XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 15)); app.buttons["today.start"].tap()
        let input = app.textFields["set.reps"]
        app.revealWorkoutControl(input)
        XCTAssertTrue(input.isHittable); XCTAssertTrue(app.buttons["problem.pain"].isHittable); XCTAssertTrue(app.buttons["problem.control_lost"].isHittable)
        let entry = XCTAttachment(screenshot: app.screenshot()); entry.name = "Actual system Reduce Motion exact blank entry and pinned stops"; entry.lifetime = .keepAlways; add(entry)
        app.buttons["workout.close"].tap(); app.selectNativeTab("History", identifier: "tab.history")
        app.buttons["history.first-workout"].tap()
        for _ in 0..<8 where !app.staticTexts["history.actual-reps"].exists { app.swipeUp() }
        XCTAssertEqual(app.staticTexts["history.actual-reps"].label, "10 / 10 / 9 reps")
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Actual system Reduce Motion history"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
