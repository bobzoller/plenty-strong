import XCTest

final class ExactRepFlowTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    @MainActor private func launch(_ mode: String = "normal", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-local-store", "-fixture-exact-reps", "-fixture-exact-mode", mode, "-cloud-disabled", "-products-unavailable"] + extra
        app.launch()
        XCTAssertTrue(app.staticTexts["today.schedule"].waitForExistence(timeout: 15))
        if extra.contains("-ui-large-text") { for _ in 0..<8 where !app.buttons["today.start"].exists { app.swipeUp() } }
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 15))
        app.tapReadyWorkoutStart()
        if app.buttons["workout.keep-original-date"].exists { reveal(app.buttons["workout.keep-original-date"], in: app); app.buttons["workout.keep-original-date"].tap() }
        return app
    }
    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        app.revealWorkoutControl(element)
    }
    @MainActor private func enter(_ value: String, in app: XCUIApplication, field: String = "set.reps") {
        app.continueGuidedRest()
        let input = app.textFields[field]; reveal(input, in: app); input.tap()
        if app.launchArguments.contains("-ui-large-text") {
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            app.revealWorkoutControl(input)
            app.assertWorkoutSafetyActions()
            input.tap()
            screenshot(app, "Exact accessibility5 dark keyboard entry and pinned stops")
        }
        input.typeText(value)
        if app.buttons["keyboard.done"].exists { app.buttons["keyboard.done"].tap() }
        XCTAssertEqual(input.value as? String, value)
    }
    @MainActor private func confirm(_ app: XCUIApplication) {
        app.beginGuidedMovement()
    }
    @MainActor private func screenshot(_ app: XCUIApplication, _ name: String) {
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = name; capture.lifetime = .keepAlways; add(capture)
    }
    @MainActor func testLastTodayActualAreIndependent() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-local-store", "-fixture-exact-reps"]
        app.launch()
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 15))
        app.tapReadyWorkoutStart()
        XCTAssertEqual(app.workoutText("movement.last-reps").label, "10 / 10 / 9 reps")
        XCTAssertEqual(app.workoutText("movement.goal-reps").label, "10 / 10 / 10 reps")
        confirm(app)
        XCTAssertEqual(app.staticTexts["set.goal"].label, "Set 1 goal: 10 reps")
        reveal(app.textFields["set.reps"], in: app)
        XCTAssertTrue(["", "Reps performed"].contains(app.textFields["set.reps"].value as? String ?? ""))
        screenshot(app, "Exact prior 10-10-9 and goal 10-10-10")
        app.buttons["workout.close"].tap()
        reveal(app.staticTexts["movement.goal-reps"].firstMatch, in: app)
        XCTAssertEqual(app.staticTexts["movement.goal-reps"].firstMatch.label, "10 / 10 / 10 reps")
        screenshot(app, "Exact Today issued 10-10-10 goal")
        app.selectNativeTab("History", identifier: "tab.history"); app.buttons["history.first-workout"].tap()
        reveal(app.staticTexts["history.issued-goal"], in: app)
        XCTAssertEqual(app.staticTexts["history.issued-goal"].label, "10 / 10 / 9 reps")
        reveal(app.staticTexts["history.actual-reps"], in: app)
        XCTAssertEqual(app.staticTexts["history.actual-reps"].label, "10 / 10 / 9 reps")
        reveal(app.staticTexts["history.next-goal"], in: app)
        XCTAssertEqual(app.staticTexts["history.next-goal"].label, "10 / 10 / 10 reps")
        screenshot(app, "Exact history original issued 10-10-9 actual and saved next 10-10-10")
        let explanation = app.staticTexts["history.explanation.exact_rep_increment"]; reveal(explanation, in: app)
        XCTAssertTrue(explanation.label.contains("one total rep")); XCTAssertTrue(explanation.label.contains("two reps per set"))
    }
    @MainActor func testShortfallReasonSkipMiddleSlotAndBlankAdvance() {
        let app = launch(); confirm(app); enter("9", in: app)
        XCTAssertTrue(app.staticTexts["set.miss-question"].exists); XCTAssertFalse(app.buttons["set.save"].isEnabled)
        let reason = app.buttons["reason.effort_limit"]; reveal(reason, in: app); reason.tap()
        let save = app.buttons["set.save"]; reveal(save, in: app); save.tap()
        app.assertGuidedActual("set.actual.0")
        app.continueGuidedRest()
        XCTAssertEqual(app.textFields["set.reps"].value as? String, "Reps performed")
        XCTAssertFalse(app.staticTexts["set.miss-question"].exists)
        app.tapWorkoutControl("set.skip")
        app.assertGuidedActual("set.skipped.1")
        XCTAssertEqual(app.staticTexts["set.goal"].label, "Set 3 goal: 10 reps")
        XCTAssertEqual(app.textFields["set.reps"].value as? String, "Reps performed")
        enter("10", in: app); app.tapWorkoutControl("set.save")
        XCTAssertTrue(app.buttons["summary.confirm"].waitForExistence(timeout: 15))
        app.assertGuidedActual("set.actual.2")
        XCTAssertFalse(app.staticTexts["set.actual.1"].exists)
        XCTAssertTrue(app.staticTexts["effort.question"].label.contains("working sets"))
        XCTAssertFalse(app.staticTexts["effort.meanings"].exists)
        app.tapWorkoutControl("effort.meanings-disclosure")
        app.revealWorkoutControl(app.staticTexts["effort.meanings"])
        XCTAssertTrue(app.staticTexts["effort.meanings"].label.contains("every set"))
        screenshot(app, "Exact indexed middle skip and all-set effort")
    }
    @MainActor func testPainWinsWithPendingShortfallAndSavedHistoryKeepsThreeValues() {
        let app = launch(); confirm(app); enter("9", in: app)
        XCTAssertTrue(app.staticTexts["set.miss-question"].exists)
        XCTAssertFalse(app.buttons["set.save"].isEnabled)
        app.tapWorkoutControl("problem.pain")
        XCTAssertTrue(app.staticTexts["movement.stopped"].waitForExistence(timeout: 15))
        app.assertGuidedActual("set.actual.0")
        app.confirmGuidedSummary()
        for _ in 0..<4 {
            app.tapWorkoutControl("movement.skip")
            app.confirmGuidedSummary()
        }
        let finish = app.buttons["workout.finish"]; reveal(finish, in: app); finish.tap()
        XCTAssertTrue(app.staticTexts["workout.saved"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "workout.saved.", "summary.slot.0")).firstMatch.label.contains("goal 10"))
        let issuedLoad = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "workout.saved.", "summary.goal-weight")).firstMatch
        XCTAssertTrue(issuedLoad.waitForExistence(timeout: 3))
        reveal(issuedLoad, in: app)
        XCTAssertEqual(issuedLoad.label, "Goal weight: 40 lb per hand")
        let actualLoad = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "workout.saved.", "summary.actual-weight")).firstMatch
        reveal(actualLoad, in: app)
        XCTAssertEqual(actualLoad.label, "Actual weight: 40 lb per hand")
        let savedNext = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "workout.next-goal.")).firstMatch
        reveal(savedNext, in: app)
        let originalSavedNext = savedNext.label
        XCTAssertFalse(originalSavedNext.isEmpty)
        app.selectNativeTab("Settings", identifier: "tab.settings")
        app.buttons["settings.program"].tap(); app.buttons["settings.goal.maintenance"].tap()
        app.buttons["settings.confirm-change"].firstMatch.tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Maintenance"), object: app.staticTexts["settings.current-goal"])
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 10), .completed)
        app.selectNativeTab("Today", identifier: "tab.today")
        app.tapWorkoutControl("today.saved-workout")
        reveal(savedNext, in: app)
        XCTAssertEqual(savedNext.label, originalSavedNext, "Completion keeps the exact next prescription saved by Finish")
        reveal(issuedLoad, in: app); XCTAssertEqual(issuedLoad.label, "Goal weight: 40 lb per hand")
        reveal(actualLoad, in: app); XCTAssertEqual(actualLoad.label, "Actual weight: 40 lb per hand")
        screenshot(app, "Exact saved independent issued goal and partial actual")
        let back = app.buttons["Back to Today"]; reveal(back, in: app); back.tap()
        app.selectNativeTab("History", identifier: "tab.history"); app.buttons["history.first-workout"].tap()
        XCTAssertEqual(app.staticTexts["history.issued-goal"].label, "10 / 10 / 10 reps")
        XCTAssertTrue(app.staticTexts["history.policy-basis"].exists)
        reveal(app.staticTexts["history.actual-reps"], in: app)
        XCTAssertEqual(app.staticTexts["history.actual-reps"].label, "9 reps")
        let retained = app.staticTexts["history.retained-goal"]; reveal(retained, in: app)
        XCTAssertTrue(retained.label.contains("10 / 10 / 10"))
        screenshot(app, "Exact history issued actual and retained normal goals")
    }
    @MainActor func testNoHistoryBaselineAndEasierInputsStayEmpty() {
        for mode in ["no-history", "baseline", "easier"] {
            let app = launch(mode)
            XCTAssertEqual(app.workoutText("movement.goal-reps").label, mode == "easier" ? "8 / 8 reps" : "8 / 8 / 8 reps")
            XCTAssertFalse(app.workoutText("movement.first-workout").exists)
            confirm(app)
            XCTAssertEqual(app.textFields["set.reps"].value as? String, "Reps performed")
            XCTAssertFalse(app.buttons["set.save"].isEnabled)
            XCTAssertFalse(app.workoutText("movement.goal-reps").exists)
            screenshot(app, "Exact \(mode) blank actual entry"); app.terminate()
        }
    }
    @MainActor func testLegacyUnfinishedKeepsCeilingAndOriginalFeedback() {
        let app = launch("legacy-unfinished"); confirm(app)
        XCTAssertTrue(app.staticTexts["set.goal"].label.contains("Up to 12 good reps"))
        enter("6", in: app)
        XCTAssertFalse(app.staticTexts["set.miss-question"].exists)
        app.tapWorkoutControl("set.save")
        XCTAssertTrue(app.staticTexts["rest.remaining"].waitForExistence(timeout: 15))
        app.openWorkoutSkip()
        XCTAssertFalse(app.buttons["load.mixed"].exists, "Archived legacy policy cannot record mixed loads")
        XCTAssertTrue(app.buttons["load.correct"].exists, "Existing legacy wrong-load stop remains supported")
        app.tapWorkoutControl("movement.partial-action")
        XCTAssertTrue(app.staticTexts["effort.question"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["set.actual.0"].label, "Set 1: 6 reps")
        XCTAssertEqual(app.staticTexts["effort.question"].label, "How hard was that?")
        XCTAssertTrue(app.buttons["effort.picker"].label.hasSuffix("Choose effort…"))
        app.tapWorkoutControl("effort.meanings-disclosure")
        app.revealWorkoutControl(app.staticTexts["effort.meanings"])
        XCTAssertTrue(app.staticTexts["effort.meanings"].label.contains("final working set"))
        XCTAssertTrue(app.staticTexts["effort.meanings"].label.contains("roughly two good reps"))
        app.tapWorkoutControl("effort.on_target")
        XCTAssertTrue(app.buttons["summary.confirm"].isEnabled)
        screenshot(app, "Legacy unfinished ceiling and original effort wording")
    }
    @MainActor func testPerSideRawMissingSideAndSetupReviewGate() {
        let app = launch("per-side")
        for _ in 0..<2 {
            app.tapWorkoutControl("movement.skip")
            app.confirmGuidedSummary()
        }
        XCTAssertTrue(app.workoutText("movement.goal-reps").label.contains("per side"))
        confirm(app)
        XCTAssertTrue(app.staticTexts["set.goal"].label.contains("per side"))
        enter("7", in: app, field: "set.left-reps")
        XCTAssertEqual(app.textFields["set.right-reps"].value as? String, "Right reps performed")
        app.tapWorkoutControl("problem.control_lost")
        app.assertGuidedActual("set.actual.0", equals: "Set 1: left 7, right unrecorded")
        screenshot(app, "Exact raw missing side preserved on control stop")
        app.confirmGuidedSummary()
        for _ in 0..<2 {
            app.tapWorkoutControl("movement.skip")
            app.confirmGuidedSummary()
        }
        let finish = app.buttons["workout.finish"]; reveal(finish, in: app); finish.tap()
        XCTAssertTrue(app.staticTexts["workout.saved"].waitForExistence(timeout: 15))
        app.selectNativeTab("History", identifier: "tab.history"); app.buttons["history.first-workout"].tap()
        let ordinaryRetained = app.staticTexts["history.retained-goal"]; reveal(ordinaryRetained, in: app)
        XCTAssertEqual(ordinaryRetained.label, "Retained normal goals when saved: 8 / 8 / 8 reps")
        let rawSides = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "history.actual-reps.", "Set 1: left 7, right unrecorded")).firstMatch
        reveal(rawSides, in: app)
        XCTAssertEqual(rawSides.label, "Set 1: left 7, right unrecorded")
        let retainedID = rawSides.identifier.replacingOccurrences(of: "history.actual-reps.", with: "history.retained-goal.")
        let retained = app.staticTexts[retainedID]; reveal(retained, in: app)
        screenshot(app, "Exact per-side retained normal goals preserve counting and raw missing side")
        XCTAssertEqual(retained.label, "Retained normal goals when saved: 8 / 8 / 8 reps per side")
        app.terminate()
        let review = launch("setup-review")
        XCTAssertTrue(review.buttons["movement.review-setup"].exists)
        XCTAssertFalse(review.textFields["set.reps"].exists)
        let setup = review.buttons["movement.review-setup"]; reveal(setup, in: review); setup.tap()
        XCTAssertTrue(review.textFields["setup.modifications"].waitForExistence(timeout: 10))
        screenshot(review, "Exact setup review uses existing movement setup")
    }
    @MainActor func testLargestTextDarkKeepsEntryAndStopControlsVisible() {
        let app = launch("normal", extra: ["-ui-large-text", "-ui-dark"])
        confirm(app)
        let input = app.textFields["set.reps"]; reveal(input, in: app)
        app.assertWorkoutSafetyActions()
        screenshot(app, "Exact accessibility5 dark blank entry and pinned stops")
        enter("9", in: app); XCTAssertTrue(app.staticTexts["set.miss-question"].exists)
        XCTAssertTrue(app.buttons["workout.skip"].isHittable)
        screenshot(app, "Exact accessibility5 dark pending reason and pinned stop")
        app.tapWorkoutControl("problem.control_lost")
        XCTAssertTrue(app.staticTexts["movement.stopped"].waitForExistence(timeout: 15))
    }
}
