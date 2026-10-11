import XCTest

final class GuidedWorkoutFlowTests: XCTestCase {
    @MainActor func testStoppedCorrectionOmitsEmptySecondaryActions() {
        let app = launch(); begin(app)
        app.enterPerformedReps("9"); app.tapWorkoutControl("problem.control_lost")
        XCTAssertTrue(app.staticTexts["movement.stopped"].waitForExistence(timeout: 15))
        app.tapWorkoutControl("summary.correct.0")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.buttons["correction.save"].exists && !app.buttons["summary.confirm"].exists &&
                app.textFields["set.reps"].value as? String == "9"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        XCTAssertFalse(app.buttons["workout.skip"].exists, "No secondary entry when all contextual actions are unavailable")
        XCTAssertTrue(app.buttons["correction.save"].isEnabled)
    }
    @MainActor func testMixedLoadsKeepSavedObservationsWithoutNewAttempt() {
        let app = launch(); begin(app)
        app.enterPerformedReps("10"); app.tapWorkoutControl("set.save")
        app.enterPerformedReps("9")
        app.openWorkoutSkip()
        XCTAssertFalse(app.buttons["load.mixed"].exists, "Mixed-load command cannot atomically retain pending reps")
        XCTAssertFalse(app.buttons["set.skip"].exists)
        app.cancelWorkoutSkip()
        XCTAssertEqual(app.textFields["set.reps"].value as? String, "9")
        app.replacePerformedReps("abc")
        app.openWorkoutSkip()
        XCTAssertFalse(app.buttons["load.mixed"].exists)
        XCTAssertFalse(app.buttons["set.skip"].exists)
        app.cancelWorkoutSkip()
        XCTAssertEqual(app.textFields["set.reps"].value as? String, "abc")
        let input = app.textFields["set.reps"]
        input.tap(); input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3))
        if app.buttons["keyboard.done"].exists { app.buttons["keyboard.done"].tap() }
        XCTAssertTrue(["", "Reps performed"].contains(input.value as? String ?? ""))
        app.tapWorkoutControl("load.mixed")
        XCTAssertTrue(app.staticTexts["movement.summary"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["set.actual.0"].label, "Set 1: 10 reps")
        XCTAssertFalse(app.staticTexts["set.actual.1"].exists)
        XCTAssertEqual(app.staticTexts["summary.outcome"].label, "Outcome: partial")
        XCTAssertFalse(app.buttons["set.save"].exists)
    }
    @MainActor func testCorrectionSafetyKeepsOriginalObservationAndNoNewAttempt() {
        let app = launch(); begin(app)
        app.enterPerformedReps("10"); app.tapWorkoutControl("set.save")
        app.tapWorkoutControl("guided.back"); app.tapWorkoutControl("summary.correct.0")
        let correctionReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !app.buttons["summary.confirm"].exists && app.buttons["correction.save"].exists &&
                app.textFields["set.reps"].value as? String == "10"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [correctionReady], timeout: 15), .completed)
        app.replacePerformedReps("9")
        app.openWorkoutSkip()
        XCTAssertFalse(app.buttons["set.skip"].exists)
        XCTAssertFalse(app.buttons["movement.partial-action"].exists)
        XCTAssertFalse(app.buttons["load.correct"].exists)
        app.tapWorkoutControl("problem.pain")
        app.navigationBars.buttons["BackButton"].tap(); waitForCorrectionReturn(app)
        XCTAssertTrue(app.staticTexts["movement.stopped"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["set.actual.0"].label, "Set 1: 10 reps")
        XCTAssertFalse(app.staticTexts["set.actual.1"].exists)
        XCTAssertFalse(app.buttons["set.save"].exists)
    }
    @MainActor func testSkipDialogPerSidePainRetainsMissingSideWithoutReason() {
        let app = launch(mode: "per-side")
        for _ in 0..<2 { app.tapWorkoutControl("movement.skip"); app.confirmGuidedSummary() }
        app.beginGuidedMovement(weight: "5")
        app.enterPerformedReps("7", field: "set.left-reps")
        XCTAssertFalse(app.buttons["set.save"].isEnabled)
        guard app.buttons["workout.skip"].waitForExistence(timeout: 5) else { XCTFail("Missing contextual Skip"); return }
        app.tapWorkoutControl("workout.skip"); app.tapWorkoutControl("problem.pain")
        XCTAssertTrue(app.staticTexts["movement.stopped"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["set.actual.0"].label, "Set 1: left 7, right unrecorded")
        XCTAssertFalse(app.buttons["set.save"].exists)
    }
    @MainActor func testSkipDialogCancelRetainsInputAndPartialKeepsRawShortfall() {
        let app = launch(); begin(app)
        XCTAssertFalse(app.buttons["load.correct"].exists)
        XCTAssertEqual(app.staticTexts["set.weight"].label, "Weight: 40 lb per hand")
        app.enterPerformedReps("9")
        XCTAssertFalse(app.buttons["set.save"].isEnabled)
        XCTAssertTrue(app.buttons["reason.effort_limit"].exists)
        guard app.buttons["workout.skip"].waitForExistence(timeout: 5) else { XCTFail("Missing contextual Skip"); return }
        app.tapWorkoutControl("workout.skip")
        XCTAssertFalse(app.buttons["set.skip"].exists, "Pending reps cannot silently become a skipped set")
        capture(app, "Native contextual Skip cancellation with pending reps")
        app.cancelWorkoutSkip()
        XCTAssertEqual(app.textFields["set.reps"].value as? String, "9")
        XCTAssertFalse(app.buttons["set.save"].isEnabled)
        app.replacePerformedReps("abc")
        app.tapWorkoutControl("workout.skip")
        XCTAssertFalse(app.buttons["set.skip"].exists, "Invalid typed input cannot become a skipped slot")
        app.buttons["movement.partial-action"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["save.error"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["set.reps"].value as? String, "abc")
        app.replacePerformedReps("9")
        app.tapWorkoutControl("workout.skip")
        app.buttons["movement.partial-action"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["movement.summary"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["set.actual.0"].label, "Set 1: 9 reps")
        XCTAssertEqual(app.staticTexts["summary.outcome"].label, "Outcome: partial")
        XCTAssertFalse(app.buttons["set.save"].exists)
    }

    @MainActor func testSkipEmptySetAndNextSetDuringRestKeepIndexedSlots() {
        let app = launch(); begin(app)
        guard app.buttons["workout.skip"].waitForExistence(timeout: 5) else { XCTFail("Missing contextual Skip"); return }
        app.tapWorkoutControl("workout.skip"); app.buttons["set.skip"].firstMatch.tap()
        let second = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Set 2 goal: 10 reps"), object: app.staticTexts["set.goal"])
        XCTAssertEqual(XCTWaiter.wait(for: [second], timeout: 15), .completed)
        app.enterPerformedReps("10"); app.tapWorkoutControl("set.save")
        XCTAssertTrue(app.staticTexts["rest.remaining"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["set.actual.1"].exists, "Rest shows a compact next preview")
        app.tapWorkoutControl("workout.skip"); app.buttons["set.skip"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["movement.summary"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["set.skipped.0"].label, "Set 1: skipped")
        XCTAssertEqual(app.staticTexts["set.actual.1"].label, "Set 2: 10 reps")
        XCTAssertEqual(app.staticTexts["set.skipped.2"].label, "Set 3: skipped")
    }

    @MainActor func testBetweenRestSkipTargetsUpcomingMovementAndSafetyNamesSource() {
        let app = launch(); begin(app)
        app.enterPerformedReps("10"); app.tapWorkoutControl("set.save"); app.tapWorkoutControl("movement.partial-action"); app.tapWorkoutControl("effort.unknown"); app.tapWorkoutControl("summary.confirm")
        XCTAssertTrue(app.staticTexts["rest.remaining"].waitForExistence(timeout: 15))
        guard app.buttons["workout.skip"].waitForExistence(timeout: 5) else { XCTFail("Missing contextual Skip"); return }
        app.tapWorkoutControl("workout.skip")
        XCTAssertFalse(app.buttons["load.correct"].exists, "Acknowledged source cannot accept load correction")
        XCTAssertFalse(app.buttons["load.mixed"].exists)
        XCTAssertEqual(app.buttons["movement.skip"].firstMatch.label, "Skip Chin-ups")
        XCTAssertEqual(app.buttons["problem.pain"].firstMatch.label, "Pain — stop Incline DB Press")
        app.buttons["movement.skip"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["movement.summary"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["summary.outcome"].label, "Outcome: skipped")
        XCTAssertEqual(app.staticTexts["set.unrecorded.0"].label, "Set 1: unrecorded")
    }

    @MainActor func testBodyweightRestHasNoLoadCorrectionAndSourcePainStillWorks() {
        let app = launch(mode: "per-side")
        for _ in 0..<3 { app.tapWorkoutControl("movement.skip"); app.confirmGuidedSummary() }
        app.beginGuidedMovement(); app.enterPerformedReps("8"); app.tapWorkoutControl("set.save"); app.tapWorkoutControl("movement.partial-action"); app.tapWorkoutControl("effort.unknown"); app.tapWorkoutControl("summary.confirm")
        XCTAssertTrue(app.staticTexts["rest.remaining"].waitForExistence(timeout: 15))
        guard app.buttons["workout.skip"].waitForExistence(timeout: 5) else { XCTFail("Missing contextual Skip"); return }
        app.tapWorkoutControl("workout.skip")
        XCTAssertFalse(app.buttons["load.correct"].exists)
        XCTAssertFalse(app.buttons["load.mixed"].exists)
        app.tapWorkoutControl("problem.pain")
        XCTAssertTrue(app.staticTexts["movement.stopped"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["set.actual.0"].label, "Set 1: 8 reps")
        XCTAssertFalse(app.buttons["set.save"].exists)
    }
    @MainActor func testSetAndRestKeepOnlyCurrentContentAndHideNormalMode() {
        let app = launch(); begin(app)
        XCTAssertEqual(app.staticTexts["set.goal"].label, "Set 1 goal: 10 reps")
        XCTAssertEqual(app.staticTexts["set.weight"].label, "Weight: 40 lb per hand")
        XCTAssertFalse(app.staticTexts["workout.session-mode"].exists)
        XCTAssertFalse(app.workoutText("movement.last-reps").exists)
        XCTAssertFalse(app.workoutText("movement.goal-reps").exists)
        XCTAssertFalse(app.staticTexts["set.actual.0"].exists)
        capture(app, "Focused current set with goal and confirmed weight")
        app.enterPerformedReps("10"); app.tapWorkoutControl("set.save")
        XCTAssertTrue(app.staticTexts["rest.remaining"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["rest.remaining"].label, "Rest: 120 seconds remaining")
        XCTAssertTrue(app.staticTexts["Next: Set 2"].exists)
        XCTAssertFalse(app.staticTexts["workout.session-mode"].exists)
        XCTAssertFalse(app.staticTexts["set.actual.0"].exists)
        XCTAssertFalse(app.workoutText("movement.last-reps").exists)
        capture(app, "Focused original rest deadline and compact next preview")
    }
    override func setUp() { continueAfterFailure = false }
    @MainActor func testFirstPreparationHidesEmptyComparisonsAndNormalLabel() {
        let app = launch(mode: "no-history")
        XCTAssertFalse(app.buttons["workout.easier"].exists)
        XCTAssertFalse(app.workoutText("workout.session-mode").exists)
        XCTAssertFalse(app.workoutText("movement.first-workout").exists)
        XCTAssertFalse(app.workoutText("movement.actual-reps").exists)
        XCTAssertEqual(app.workoutText("movement.goal-reps").label, "8 / 8 / 8 reps")
    }
    @MainActor func testPreparationRequiresExplicitWeightConfirmationAndReconfirmation() {
        let app = launch(mode: "no-history")
        XCTAssertTrue(app.buttons["load.picker"].exists)
        XCTAssertTrue(app.buttons["load.picker"].label.contains("40 lb per hand"))
        XCTAssertFalse(app.buttons["guided.next"].isEnabled)
        capture(app, "Compact first preparation with local unconfirmed weight")
        app.tapWorkoutControl("load.confirm")
        let confirmed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["guided.next"])
        XCTAssertEqual(XCTWaiter.wait(for: [confirmed], timeout: 15), .completed)
        app.selectGuidedWeight(amount: "10")
        XCTAssertFalse(app.buttons["guided.next"].isEnabled)
        app.selectGuidedWeight(amount: "40")
        XCTAssertFalse(app.buttons["guided.next"].isEnabled, "Returning to the saved weight still requires a fresh confirmation")
        app.tapWorkoutControl("load.confirm")
        let reconfirmed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["guided.next"])
        XCTAssertEqual(XCTWaiter.wait(for: [reconfirmed], timeout: 15), .completed)
        app.tapWorkoutControl("workout.close"); app.terminate()
        let resumed = launch(mode: "no-history", reset: false)
        XCTAssertTrue(resumed.buttons["guided.next"].isEnabled, "Explicit durable confirmation survives resume")
        resumed.tapWorkoutControl("guided.next")
        XCTAssertTrue(resumed.textFields["set.reps"].waitForExistence(timeout: 15))
    }
    @MainActor func testBodyweightPreparationHasNoWeightPicker() {
        let app = launch(mode: "per-side")
        for _ in 0..<3 { app.tapWorkoutControl("movement.skip"); app.confirmGuidedSummary() }
        XCTAssertFalse(app.buttons["load.picker"].exists)
        XCTAssertFalse(app.buttons["load.confirm"].exists)
        XCTAssertTrue(app.buttons["guided.next"].isEnabled)
        capture(app, "Bodyweight preparation without numeric weight controls")
        app.beginGuidedMovement()
        XCTAssertTrue(app.textFields["set.reps"].waitForExistence(timeout: 15))
    }
    @MainActor private func launch(mode: String = "normal", reset: Bool = true, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-fixture-exact-reps", "-fixture-exact-mode", mode, "-cloud-disabled", "-products-unavailable"] + (reset ? ["-reset-local-store"] : []) + extra
        app.launch()
        if extra.contains("-ui-large-text") { app.revealWorkoutControl(app.buttons["today.start"]) }
        app.tapReadyWorkoutStart()
        XCTAssertTrue(app.buttons["workout.close"].waitForExistence(timeout: 15))
        if app.buttons["workout.keep-original-date"].exists { app.tapWorkoutControl("workout.keep-original-date") }
        return app
    }
    @MainActor private func begin(_ app: XCUIApplication) {
        app.tapWorkoutControl("load.confirm")
        app.tapWorkoutControl("guided.next")
        XCTAssertTrue(app.textFields["set.reps"].waitForExistence(timeout: 15))
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor func testSheetResumeAcrossTabsAndRelaunch() {
        let app = launch(); begin(app)
        XCTAssertEqual(app.textFields["set.reps"].value as? String, "Reps performed")
        XCTAssertEqual(app.staticTexts["set.goal"].label, "Set 1 goal: 10 reps")
        app.enterPerformedReps("9")
        app.tapWorkoutControl("reason.effort_limit")
        app.buttons["workout.close"].tap()
        app.selectNativeTab("History", identifier: "tab.history")
        XCTAssertTrue(app.buttons["workout.resume"].isHittable)
        app.buttons["workout.resume"].tap()
        XCTAssertEqual(app.textFields["set.reps"].value as? String, "9")
        app.buttons["workout.close"].tap(); app.terminate()
        let resumed = launch(reset: false)
        XCTAssertEqual(resumed.textFields["set.reps"].value as? String, "9")
        XCTAssertTrue(resumed.buttons["set.save"].isEnabled)
        XCTAssertEqual(resumed.staticTexts["set.goal"].label, "Set 1 goal: 10 reps")
        XCTAssertFalse(resumed.staticTexts["set.actual.0"].exists)
    }
    @MainActor func testImmediatePerSideMissReasonClearsAndRequiresFreshAnswer() {
        let app = launch(mode: "per-side")
        for _ in 0..<2 { app.tapWorkoutControl("movement.skip"); app.tapWorkoutControl("summary.confirm") }
        app.beginGuidedMovement(weight: "5")
        app.enterPerformedReps("8", field: "set.left-reps")
        app.enterPerformedReps("6", field: "set.right-reps")
        XCTAssertTrue(app.buttons["reason.effort_limit"].exists)
        XCTAssertFalse(app.buttons["set.save"].isEnabled)
        app.tapWorkoutControl("reason.effort_limit")
        app.replacePerformedReps("8", field: "set.right-reps")
        XCTAssertFalse(app.buttons["reason.effort_limit"].exists)
        app.replacePerformedReps("6", field: "set.right-reps")
        XCTAssertFalse(app.buttons["set.save"].isEnabled)
        app.tapWorkoutControl("reason.time_interruption")
        app.tapWorkoutControl("set.save")
        XCTAssertTrue(app.staticTexts["rest.remaining"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["effort.question"].exists)
        app.tapWorkoutControl("guided.next")
        XCTAssertEqual(app.textFields["set.left-reps"].value as? String, "Left reps performed")
        XCTAssertEqual(app.textFields["set.right-reps"].value as? String, "Right reps performed")
    }
    @MainActor func testSummaryCorrectionFromReviewReturnsWithoutReplay() {
        let app = launch(); begin(app)
        app.enterPerformedReps("10"); app.tapWorkoutControl("set.save")
        app.tapWorkoutControl("guided.next"); app.tapWorkoutControl("set.skip")
        let nextSet = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Set 3 goal: 10 reps"), object: app.staticTexts["set.goal"])
        XCTAssertEqual(XCTWaiter.wait(for: [nextSet], timeout: 15), .completed)
        app.enterPerformedReps("10"); app.tapWorkoutControl("set.save")
        XCTAssertTrue(app.staticTexts["movement.summary"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["set.skipped.1"].label, "Set 2: skipped")
        XCTAssertFalse(app.staticTexts["summary.corrected.0"].exists)
        XCTAssertFalse(app.buttons["summary.corrections.0"].exists)
        XCTAssertTrue(app.staticTexts["summary.slot.0"].label.contains("goal 10"))
        XCTAssertTrue(app.staticTexts["summary.slot.2"].exists)
        XCTAssertEqual(app.staticTexts["set.actual.2"].label, "Set 3: 10 reps")
        app.tapWorkoutControl("effort.unknown"); capture(app, "Guided summary all intended slots and explicit unknown effort")
        app.tapWorkoutControl("summary.confirm")
        XCTAssertTrue(app.staticTexts["rest.remaining"].waitForExistence(timeout: 15))
        let deadlineLabel = app.staticTexts["rest.remaining"].label
        app.buttons["guided.back"].tap()
        app.tapWorkoutControl("summary.correct.0")
        app.replacePerformedReps("9")
        XCTAssertTrue(app.buttons["correction.save"].isEnabled, "Acknowledged partial replacement may preserve an unknown reason")
        app.tapWorkoutControl("reason.effort_limit")
        capture(app, "Guided acknowledged partial correction with explicit optional reason")
        let nativeBack = app.navigationBars.buttons["BackButton"]
        XCTAssertTrue(nativeBack.waitForExistence(timeout: 5))
        nativeBack.tap()
        waitForCorrectionReturn(app)
        XCTAssertTrue(app.staticTexts["movement.summary"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["set.actual.0"].label, "Set 1: 10 reps")
        app.tapWorkoutControl("summary.correct.0")
        app.replacePerformedReps("9")
        app.tapWorkoutControl("reason.effort_limit")
        app.tapWorkoutControl("correction.save")
        waitForCorrectionReturn(app)
        XCTAssertTrue(app.staticTexts["movement.partial"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["set.actual.0"].label, "Set 1: 9 reps")
        XCTAssertTrue(app.staticTexts["summary.corrected.0"].exists)
        app.tapWorkoutControl("summary.corrections.0")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Original: 10 reps", "Replacement: 9 reps")).firstMatch.waitForExistence(timeout: 5))
        capture(app, "Pre-Finish correction provenance beside effective actual")
        app.tapWorkoutControl("effort.unknown"); app.tapWorkoutControl("summary.confirm")
        XCTAssertTrue(app.staticTexts["rest.remaining"].exists)
        XCTAssertFalse(app.textFields["set.reps"].exists)
        XCTAssertFalse(deadlineLabel.isEmpty)
    }
    @MainActor private func waitForCorrectionReturn(_ app: XCUIApplication) {
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["correction.save"])
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 15), .completed)
    }
    @MainActor func testCompletedCorrectionRequiresReasonDemotesAndKeepsForwardRest() {
        let app = launch(); begin(app)
        for index in 0..<3 {
            app.enterPerformedReps("10"); app.tapWorkoutControl("set.save")
            if index < 2 { XCTAssertTrue(app.staticTexts["rest.remaining"].waitForExistence(timeout: 15)) }
        }
        app.tapWorkoutControl("effort.unknown"); app.tapWorkoutControl("summary.confirm")
        XCTAssertTrue(app.staticTexts["rest.remaining"].waitForExistence(timeout: 15))
        app.buttons["guided.back"].tap(); app.tapWorkoutControl("summary.correct.0")
        app.replacePerformedReps("9")
        XCTAssertEqual(app.staticTexts["set.goal"].label, "Set 1 goal: 10 reps")
        XCTAssertFalse(app.buttons["correction.save"].isEnabled)
        app.tapWorkoutControl("reason.effort_limit")
        XCTAssertTrue(app.buttons["correction.save"].isEnabled)
        capture(app, "Guided completed correction required reason before partial demotion")
        app.tapWorkoutControl("correction.save"); waitForCorrectionReturn(app)
        XCTAssertEqual(app.staticTexts["set.actual.0"].label, "Set 1: 9 reps")
        XCTAssertEqual(app.staticTexts["summary.outcome"].label, "Outcome: completed", "Positive completed actuals with an explicit shortfall reason remain qualified")
        app.tapWorkoutControl("summary.correct.0")
        app.replacePerformedReps("0")
        XCTAssertEqual(app.staticTexts["set.goal"].label, "Set 1 goal: 10 reps")
        XCTAssertFalse(app.buttons["correction.save"].isEnabled)
        app.tapWorkoutControl("reason.effort_limit")
        XCTAssertTrue(app.buttons["correction.save"].isEnabled)
        capture(app, "Guided zero correction with required reason and original goal")
        app.tapWorkoutControl("correction.save"); waitForCorrectionReturn(app)
        XCTAssertEqual(app.staticTexts["set.actual.0"].label, "Set 1: 0 reps")
        XCTAssertTrue(app.staticTexts["movement.partial"].exists)
        app.tapWorkoutControl("effort.unknown"); app.tapWorkoutControl("summary.confirm")
        XCTAssertTrue(app.staticTexts["rest.remaining"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.textFields["set.reps"].exists)
        app.tapWorkoutControl("guided.next")
        XCTAssertEqual(app.buttons["guided.next"].label, "Start movement")
        XCTAssertFalse(app.textFields["set.reps"].exists)
    }
    @MainActor func testDuplicateNextShowsBusyAndRecordsOnlyOneActual() {
        let app = launch(extra: ["-ui-slow-save"]); begin(app)
        app.enterPerformedReps("10")
        let next = app.buttons["set.save"]
        next.doubleTap()
        XCTAssertTrue(app.descendants(matching: .any)["workout.busy"].waitForExistence(timeout: 5))
        XCTAssertFalse(next.isEnabled)
        XCTAssertFalse(app.buttons["workout.skip"].isEnabled)
        XCTAssertTrue(app.staticTexts["rest.remaining"].waitForExistence(timeout: 15))
        app.assertGuidedActual("set.actual.0", equals: "Set 1: 10 reps")
        app.tapWorkoutControl("guided.back")
        XCTAssertFalse(app.staticTexts["set.actual.1"].exists)
        app.navigationBars.buttons["BackButton"].tap()
        app.tapWorkoutControl("guided.next")
        XCTAssertEqual(app.staticTexts["set.goal"].label, "Set 2 goal: 10 reps")
        XCTAssertEqual(app.textFields["set.reps"].value as? String, "Reps performed")
    }
    @MainActor func testExpiredRestNeverAutoAdvances() {
        let app = launch(); begin(app)
        app.enterPerformedReps("10"); app.tapWorkoutControl("set.save")
        XCTAssertTrue(app.staticTexts["rest.remaining"].waitForExistence(timeout: 15))
        app.buttons["workout.close"].tap(); app.terminate()
        let resumed = launch(reset: false, extra: ["-ui-clock-offset", "180"])
        if resumed.buttons["workout.keep-original-date"].exists { resumed.tapWorkoutControl("workout.keep-original-date") }
        XCTAssertEqual(resumed.staticTexts["rest.remaining"].label, "Rest: 0 seconds remaining")
        XCTAssertFalse(resumed.textFields["set.reps"].exists)
        resumed.tapWorkoutControl("guided.next")
        XCTAssertEqual(resumed.staticTexts["set.goal"].label, "Set 2 goal: 10 reps")
        XCTAssertFalse(resumed.buttons["set.save"].isEnabled)
    }
    @MainActor func testKeyboardLargeTextAndReduceMotionKeepActionsReachable() {
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
        XCTAssertEqual(toggle.value as? String, "1")
        let app = launch(extra: ["-ui-large-text", "-ui-dark"]); begin(app)
        let input = app.textFields["set.reps"]; app.revealWorkoutControl(input); input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["workout.skip"].isHittable)
        app.assertWorkoutSafetyActions()
        XCTAssertTrue(app.buttons["set.save"].isHittable)
        capture(app, "Guided system Reduce Motion accessibility5 keyboard pinned actions and safety")
        input.tap()
        input.typeText("9")
        app.buttons["keyboard.done"].tap()
        app.tapWorkoutControl("problem.control_lost")
        XCTAssertTrue(app.staticTexts["movement.stopped"].waitForExistence(timeout: 15))
        app.tapWorkoutControl("effort.unknown")
        app.revealWorkoutControl(app.staticTexts["summary.slot.0"])
        capture(app, "Guided accessibility5 Summary original goal current slots")
        app.revealWorkoutControl(app.staticTexts["summary.outcome"])
        capture(app, "Guided accessibility5 stopped Summary outcome")
        app.tapWorkoutControl("summary.correct.0")
        let correctionInput = app.textFields["set.reps"]
        XCTAssertTrue(correctionInput.waitForExistence(timeout: 15))
        XCTAssertEqual(correctionInput.value as? String, "9")
        app.revealWorkoutControl(correctionInput); correctionInput.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["correction.save"].isHittable)
        XCTAssertFalse(app.buttons["workout.skip"].exists, "Already-stopped correction has no admitted secondary actions")
        capture(app, "Guided accessibility5 correction keyboard original actual and pinned Save")
        app.buttons["keyboard.done"].tap()
        app.navigationBars.buttons["BackButton"].tap(); waitForCorrectionReturn(app)
        XCTAssertEqual(app.staticTexts["set.actual.0"].label, "Set 1: 9 reps")
        XCTAssertTrue(app.staticTexts["movement.stopped"].exists)
        app.tapWorkoutControl("summary.correct.0")
        app.replacePerformedReps("8")
        app.tapWorkoutControl("correction.save"); waitForCorrectionReturn(app)
        app.tapWorkoutControl("summary.corrections.0")
        let largeDetail = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Correction 1. Original:")).firstMatch
        app.revealWorkoutControl(largeDetail)
        XCTAssertTrue(largeDetail.label.contains("Original: 9 reps"))
        XCTAssertTrue(largeDetail.label.contains("Replacement: 8 reps"))
        capture(app, "Guided accessibility5 before-Finish correction disclosure")
        app.tapWorkoutControl("summary.confirm")
    }
    @MainActor func testStoppedRawCorrectionKeepsMissingSideZeroAndNoInventedReason() {
        let app = launch(mode: "per-side")
        for _ in 0..<2 { app.tapWorkoutControl("movement.skip"); app.confirmGuidedSummary() }
        app.beginGuidedMovement(weight: "5")
        app.enterPerformedReps("7", field: "set.left-reps")
        app.tapWorkoutControl("problem.control_lost")
        XCTAssertTrue(app.staticTexts["movement.stopped"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["set.actual.0"].label, "Set 1: left 7, right unrecorded")
        app.tapWorkoutControl("summary.correct.0")
        app.replacePerformedReps("0", field: "set.left-reps")
        XCTAssertEqual(app.textFields["set.right-reps"].value as? String, "Right reps performed")
        XCTAssertEqual(app.staticTexts["set.goal"].label, "Set 1 goal: 8 reps per side")
        XCTAssertTrue(app.buttons["correction.save"].isEnabled, "Authoritative stopped raw correction does not demand an invented reason")
        app.tapWorkoutControl("correction.save")
        waitForCorrectionReturn(app)
        XCTAssertTrue(app.staticTexts["movement.stopped"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["set.actual.0"].label, "Set 1: left 0, right unrecorded")
        app.tapWorkoutControl("summary.corrections.0")
        let rawDetail = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Correction 1. Original:")).firstMatch
        app.revealWorkoutControl(rawDetail)
        XCTAssertTrue(rawDetail.label.contains("Original: left 7, right unrecorded"))
        XCTAssertTrue(rawDetail.label.contains("Replacement: left 0, right unrecorded"))
        XCTAssertTrue(rawDetail.label.contains("Reason: Not recorded"))
        XCTAssertFalse(app.buttons["set.save"].exists)
        XCTAssertTrue(app.staticTexts["summary.slot.0"].label.contains("goal 8"))
        capture(app, "Guided stopped raw correction zero and missing side remain truthful")
    }
    @MainActor func testDemoSwitchRestoresOnlyItsOwnDraft() {
        let app = launch(); begin(app); app.enterPerformedReps("9")
        app.buttons["workout.close"].tap(); app.selectNativeTab("Settings", identifier: "tab.settings")
        let toggle = app.switches["developer.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.alerts.buttons["Use demo data"].tap()
        XCTAssertTrue(app.staticTexts["developer.demo-banner"].waitForExistence(timeout: 120))
        app.tapReadyWorkoutStart()
        XCTAssertFalse(app.textFields["set.reps"].exists)
        app.buttons["workout.close"].tap(); app.selectNativeTab("Settings", identifier: "tab.settings")
        app.switches["developer.toggle"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["workout.resume"].waitForExistence(timeout: 20))
        app.buttons["workout.resume"].tap()
        XCTAssertEqual(app.textFields["set.reps"].value as? String, "9")
        XCTAssertFalse(app.staticTexts["set.actual.0"].exists)
    }
}

extension XCUIApplication {
    @MainActor func replacePerformedReps(_ value: String, field: String = "set.reps") {
        let input = textFields[field]; revealWorkoutControl(input); input.tap()
        let old = input.value as? String ?? ""
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + value)
        if buttons["keyboard.done"].exists { buttons["keyboard.done"].tap() }
        XCTAssertEqual(input.value as? String, value)
    }
}
