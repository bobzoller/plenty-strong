import XCTest
final class HistorySettingsTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    @MainActor private func seeded() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-local-store", "-fixture", "history-10-10-9", "-cloud-disabled"]
        app.launch(); return app
    }
    @MainActor private func revealSavedNextTarget(in app: XCUIApplication) {
        for _ in 0..<8 where !app.staticTexts["history.next-rep-ceiling"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["history.next-rep-ceiling"].isHittable)
    }
    @MainActor func testHistoryKeepsActualRepsSeparateFromNextPrescription() {
        let app = seeded()
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 15))
        let today = XCTAttachment(screenshot: app.screenshot()); today.name = "Candidate synthetic Today"; today.lifetime = .keepAlways; add(today)
        app.selectNativeTab("History", identifier: "tab.history")
        app.buttons["history.first-workout"].tap()
        XCTAssertEqual(app.staticTexts["history.actual-reps"].label, "10, 10, 9")
        XCTAssertTrue(app.staticTexts["history.coverage"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Stored actuals and next prescription"; attachment.lifetime = .keepAlways; add(attachment)
        revealSavedNextTarget(in: app)
        XCTAssertEqual(app.staticTexts["history.next-rep-ceiling"].label, "Up to 12 good reps")
        let nextTarget = XCTAttachment(screenshot: app.screenshot())
        nextTarget.name = "Candidate synthetic visible saved next target"
        nextTarget.lifetime = .keepAlways; add(nextTarget)
    }
    @MainActor func testStoredIdentityDisclosureKeepsActualsProminent() {
        let app = seeded()
        app.selectNativeTab("History", identifier: "tab.history")
        app.buttons["history.first-workout"].tap()
        XCTAssertTrue(app.staticTexts["history.actual-reps"].isHittable)
        revealSavedNextTarget(in: app)
        XCTAssertEqual(app.staticTexts["history.next-rep-ceiling"].label, "Up to 12 good reps")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Original setup identity:")).firstMatch.exists)
        let details = app.buttons.matching(NSPredicate(format: "label == %@", "Stored record details")).firstMatch
        XCTAssertTrue(details.exists)
        let collapsed = XCTAttachment(screenshot: app.screenshot()); collapsed.name = "Final fix original actuals with stored identity collapsed"; collapsed.lifetime = .keepAlways; add(collapsed)
        details.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Original setup identity:")).firstMatch.exists)
        let expanded = XCTAttachment(screenshot: app.screenshot()); expanded.name = "Final fix copyable stored identity expanded"; expanded.lifetime = .keepAlways; add(expanded)
    }
    @MainActor func testAcceptedLegacyArchiveIsReadOnlyExportableAndReopens() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-local-store", "-fixture", "legacy-numeric", "-cloud-disabled"]
        app.launch()
        XCTAssertTrue(app.staticTexts["archive.training-unavailable"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Synthetic archived lift"].exists)
        XCTAssertFalse(app.buttons["today.start"].exists)
        let archive = XCTAttachment(screenshot: app.screenshot()); archive.name = "Final fix accepted numeric archive read only"; archive.lifetime = .keepAlways; add(archive)
        app.swipeUp()
        XCTAssertTrue(app.buttons["Backup and restore"].waitForExistence(timeout: 10))
        app.buttons["Backup and restore"].tap(); app.buttons["backup.export"].tap()
        XCTAssertTrue(app.buttons["backup.share"].waitForExistence(timeout: 10))
        app.terminate(); app.launchArguments.removeAll { $0 == "-reset-local-store" }; app.launch()
        XCTAssertTrue(app.staticTexts["archive.training-unavailable"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["today.start"].exists)
    }
    @MainActor func testSettingsGoalAndBackupNavigation() {
        let app = seeded()
        app.selectNativeTab("Settings", identifier: "tab.settings")
        app.buttons["settings.program"].tap(); app.buttons["settings.goal.maintenance"].tap()
        app.buttons["settings.confirm-change"].firstMatch.tap()
        let changedGoal = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Maintenance"), object: app.staticTexts["settings.current-goal"])
        XCTAssertEqual(XCTWaiter.wait(for: [changedGoal], timeout: 15), .completed)
        app.navigationBars.buttons.firstMatch.tap(); app.buttons["settings.backup"].tap()
        app.buttons["backup.export"].tap()
        XCTAssertTrue(app.buttons["backup.share"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["backup.result"].label.contains("Lossless JSON"))
        app.buttons["backup.share"].tap()
        XCTAssertTrue(app.popovers.firstMatch.waitForExistence(timeout: 10))
        let filename = app.otherElements.matching(NSPredicate(format: "label == %@", "PlentyStrong-losslessJSON"))
        let fileType = app.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "JSON · "))
        let filenameReady = filename.firstMatch.waitForExistence(timeout: 10)
        let typeReady = fileType.firstMatch.waitForExistence(timeout: 10)
        print(app.debugDescription)
        XCTAssertTrue(filenameReady); XCTAssertTrue(typeReady)
        XCTAssertEqual(filename.count, 1); XCTAssertEqual(fileType.count, 1)
        XCTAssertFalse(fileType.firstMatch.label.isEmpty)
        let share = XCTAttachment(screenshot: app.screenshot()); share.name = "Native JSON share availability no destination selected"; share.lifetime = .keepAlways; add(share)
    }
    @MainActor func testDraftAndPendingEntrySurviveTabsAndSettingsLock() {
        let app = seeded()
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 15)); app.buttons["today.start"].tap()
        app.revealWorkoutControl(app.textFields["set.reps"])
        app.textFields["set.reps"].tap(); app.textFields["set.reps"].typeText("7")
        let keyboardEvidence = XCTAttachment(screenshot: app.screenshot()); keyboardEvidence.name = "Pending numeric entry keyboard M1 visible impact"; keyboardEvidence.lifetime = .keepAlways; add(keyboardEvidence)
        if app.buttons["keyboard.done"].exists { app.buttons["keyboard.done"].tap() }
        app.selectNativeTab("Settings", identifier: "tab.settings"); app.buttons["settings.program"].tap()
        XCTAssertTrue(app.staticTexts["settings.draft-lock"].exists)
        XCTAssertFalse(app.buttons["settings.goal.maintenance"].isEnabled)
        app.selectNativeTab("Today", identifier: "tab.today"); XCTAssertEqual(app.textFields["set.reps"].value as? String, "7")
    }
    @MainActor func testLocalFileDuplicateImportAndEmptyOnboardingRecovery() {
        let app = seeded()
        app.selectNativeTab("Settings", identifier: "tab.settings")
        app.buttons["settings.backup"].tap(); app.buttons["backup.export"].tap()
        XCTAssertTrue(app.buttons["backup.share"].waitForExistence(timeout: 10))
        app.swipeUp(); app.buttons["backup.restore-synthetic-file"].tap()
        let duplicate = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "0 accepted records, 2 already present"), object: app.staticTexts["backup.result"])
        XCTAssertEqual(XCTWaiter.wait(for: [duplicate], timeout: 15), .completed)
        app.terminate(); app.launchArguments = ["-ui-testing", "-reset-local-store"]; app.launch()
        XCTAssertTrue(app.buttons["onboarding.restore"].waitForExistence(timeout: 15)); app.buttons["onboarding.restore"].tap()
        app.swipeUp(); app.buttons["backup.restore-synthetic-file"].tap()
        app.selectNativeTab("History", identifier: "tab.history")
        let recovery = XCTAttachment(screenshot: app.screenshot()); recovery.name = "Empty-store restore screen"; recovery.lifetime = .keepAlways; add(recovery)

        app.buttons["history.first-workout"].tap()
        XCTAssertEqual(app.staticTexts["history.actual-reps"].label, "10, 10, 9")
        revealSavedNextTarget(in: app)
        XCTAssertEqual(app.staticTexts["history.next-rep-ceiling"].label, "Up to 12 good reps")
        app.terminate(); app.launchArguments = ["-ui-testing"]; app.launch()
        app.selectNativeTab("History", identifier: "tab.history")
        app.buttons["history.first-workout"].tap(); XCTAssertEqual(app.staticTexts["history.actual-reps"].label, "10, 10, 9")
    }
    @MainActor func testVoiceOverLabelsAndKeyboardRejectInvalidInput() {
        let app = seeded()
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 15)); app.buttons["today.start"].tap()
        let input = app.textFields["set.reps"]
        app.revealWorkoutControl(input); XCTAssertEqual(input.label, "Reps performed")
        app.tapWorkoutControl("load.choose.5")
        app.revealWorkoutControl(input); input.tap(); input.typeText("8")
        let valid = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: app.buttons["set.save"])
        XCTAssertEqual(XCTWaiter.wait(for: [valid], timeout: 15), .completed)
        input.typeText(XCUIKeyboardKey.delete.rawValue + "abc")
        XCTAssertFalse(app.buttons["set.save"].isEnabled)
        XCTAssertTrue(app.buttons["keyboard.done"].exists); app.buttons["keyboard.done"].tap()
        XCTAssertEqual(app.buttons["problem.pain"].label, "Pain — stop")
        XCTAssertEqual(app.buttons["problem.control_lost"].label, "Loss of control — stop")
    }
    @MainActor func testUnsupportedLocalFileShowsReadableErrorAndRetainsHistory() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-local-store", "-fixture", "history-10-10-9", "-ui-fixture-unsupported-backup"]
        app.launch(); app.selectNativeTab("Settings", identifier: "tab.settings")
        app.buttons["settings.backup"].tap(); app.swipeUp(); app.buttons["backup.restore-synthetic-file"].tap()
        XCTAssertTrue(app.staticTexts["backup.result"].waitForExistence(timeout: 10)); XCTAssertTrue(app.staticTexts["backup.result"].label.contains("unsupported or corrupt"))
        app.selectNativeTab("History", identifier: "tab.history"); app.buttons["history.first-workout"].tap()
        XCTAssertEqual(app.staticTexts["history.actual-reps"].label, "10, 10, 9")
    }
    @MainActor func testPausedReviewCancelAndExplicitSafeResume() {
        let app = seeded(); app.selectNativeTab("Settings", identifier: "tab.settings")
        app.buttons["settings.program"].tap()
        let base = "chest_supported_db_row_38_neutral"
        let movement = app.staticTexts["settings.movement.\(base)"]
        for _ in 0..<5 where !movement.isHittable { app.swipeUp() }
        XCTAssertTrue(movement.exists); XCTAssertTrue(movement.isHittable); movement.tap()
        let resume = app.buttons["settings.safe-resume.\(base)"]
        for _ in 0..<3 where !resume.isHittable { app.swipeUp() }
        if !resume.exists { print(app.debugDescription) }
        let paused = XCTAttachment(screenshot: app.screenshot()); paused.name = "Paused movement review controls"; paused.lifetime = .keepAlways; add(paused)
        XCTAssertTrue(resume.exists); resume.tap(); app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["settings.paused.\(base)"].exists)
        resume.tap(); app.buttons["settings.confirm-change"].firstMatch.tap()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.staticTexts["settings.paused.\(base)"])
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 15), .completed)
        XCTAssertFalse(app.staticTexts["save.error"].exists)
    }

}

// Native TabContent metadata is retained in the app. On this SDK some initial
// launches expose only the visible native label; this verifies user navigation
// without changing the app hierarchy or claiming the identifier check passed.
extension XCUIApplication {
    @MainActor func selectInitialUpperProgram(goal: String = "size", confirmSelection: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
        let footer = buttons["onboarding.confirm"]
        let card = buttons["onboarding.program.upper_body"]
        XCTAssertTrue(card.waitForExistence(timeout: 15), file: file, line: line)
        revealWorkoutControl(card, pinnedFooter: footer, scrollDistance: 100, file: file, line: line)
        card.tap()
        let goalButton = buttons["onboarding.goal.\(goal)"]
        revealWorkoutControl(goalButton, pinnedFooter: footer, scrollDistance: 100, file: file, line: line)
        goalButton.tap()
        XCTAssertTrue(footer.isEnabled, file: file, line: line)
        if confirmSelection { footer.tap() }
    }
    @MainActor func revealWorkoutControl(_ element: XCUIElement, pinnedFooter: XCUIElement? = nil, scrollDistance: CGFloat = 320, file: StaticString = #filePath, line: UInt = #line) {
        func footer() -> XCUIElement? {
            if let pinnedFooter { return pinnedFooter }
            let stop = buttons["problem.pain"]
            return stop.exists && !buttons["workout.keep-original-date"].exists ? stop : nil
        }
        func reachable() -> Bool {
            guard element.exists else { return false }
            let bounds = element.frame
            guard [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy(\.isFinite), bounds.width > 0, bounds.height > 0,
                  bounds.intersects(frame) else { return false }
            if (element.elementType == .textField || element.elementType == .button), !element.identifier.hasPrefix("problem.") {
                // AX can expose a cached offscreen frame before a valid hit point.
                // Check the complete control inside content before hittability.
                let bottom = footer().map { $0.frame.minY - 32 } ?? frame.maxY
                guard bounds.minY >= navigationBars.firstMatch.frame.maxY, bounds.maxY < bottom else { return false }
            }
            return element.isHittable
        }
        for _ in 0..<24 {
            if reachable() { break }
            let bottom = footer().map { $0.frame.minY - 48 } ?? frame.maxY - 150
            let origin = coordinate(withNormalizedOffset: .zero)
            let navigationBottom = navigationBars.firstMatch.frame.maxY
            let bounds = element.exists ? element.frame : .zero
            let hasFrame = [bounds.minY, bounds.height].allSatisfy(\.isFinite) && bounds.height > 0
            let above = hasFrame && bounds.minY < navigationBottom
            let keyboardOpen = keyboards.firstMatch.exists && pinnedFooter == nil && footer() != nil
            var distance = scrollDistance
            if keyboardOpen, hasFrame {
                let usableDragHeight = bottom - navigationBottom - 32
                guard usableDragHeight > 0 else { break }
                let requiredShift = above ? navigationBottom - bounds.minY : max(0, bounds.maxY - (bottom + 16))
                distance = min(scrollDistance, usableDragHeight / 2, max(24, requiredShift + 12))
                print("Bounded keyboard reveal: frame=\(bounds) above=\(above) requiredShift=\(requiredShift) usableDragHeight=\(usableDragHeight) distance=\(distance)")
            }
            let top = max(navigationBottom + 32, bottom - distance)
            let start = origin.withOffset(CGVector(dx: frame.midX, dy: above ? top : bottom))
            let end = origin.withOffset(CGVector(dx: frame.midX, dy: above ? bottom : top))
            if pinnedFooter != nil {
                print("Bounded explicit-footer reveal: exists=\(element.exists) frame=\(element.exists ? element.frame : .zero) footer=\(pinnedFooter!.frame) start=\(start.screenPoint) end=\(end.screenPoint)")
                // The short onboarding Form needs a held slow drag: release
                // inertia can otherwise jump the target between both edges.
                start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
            } else if keyboardOpen {
                // Focus shrinks the viewport: correct the observed frame deficit
                // without flinging the field between navigation and safety stops.
                start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
            } else { start.press(forDuration: 0.01, thenDragTo: end) }
        }
        if !reachable() {
            XCTContext.runActivity(named: "Unreached control") { activity in
                let hierarchy = XCTAttachment(string: debugDescription); hierarchy.name = "Unreached control hierarchy"; hierarchy.lifetime = .keepAlways; activity.add(hierarchy)
                let capture = XCTAttachment(screenshot: screenshot()); capture.name = "Unreached control viewport"; capture.lifetime = .keepAlways; activity.add(capture)
            }
        }
        XCTAssertTrue(reachable(), "Reach the full control above the pinned safety area", file: file, line: line)
    }
    @MainActor func tapWorkoutControl(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let control = buttons[identifier]; revealWorkoutControl(control, file: file, line: line); control.tap()
    }
    @MainActor func enterPerformedReps(_ value: String, field: String = "set.reps", file: StaticString = #filePath, line: UInt = #line) {
        let input = textFields[field]; revealWorkoutControl(input, file: file, line: line); input.tap(); input.typeText(value)
        if buttons["keyboard.done"].exists { buttons["keyboard.done"].tap() }
        XCTAssertEqual(input.value as? String, value, file: file, line: line)
    }
    @MainActor func selectNativeTab(_ title: String, identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let matches = buttons.matching(NSPredicate(format: "label == %@", title))
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 15), file: file, line: line)
        XCTAssertEqual(matches.count, 1, "Native tab label must be unique", file: file, line: line)
        let button = matches.element(boundBy: 0)
        XCTAssertTrue(button.isHittable, file: file, line: line)
        print("O8 native tab \(title): identifier \(identifier) observed=\(buttons[identifier].exists); visible label navigation")
        button.tap()
    }
}
