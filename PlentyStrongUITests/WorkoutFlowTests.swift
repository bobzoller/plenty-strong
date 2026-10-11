import XCTest

final class WorkoutFlowTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    @MainActor private func savePerformed(in app: XCUIApplication) {
        let reason = app.buttons["reason.other_unknown"]
        if reason.exists {
            app.revealWorkoutControl(reason); reason.tap()
        }
        let save = app.buttons["set.save"]
        app.revealWorkoutControl(save); save.tap()
    }

    @MainActor func testEasierModeIsAvailableBeforeWorkingSets() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-local-store", "-cloud-disabled", "-products-unavailable"]
        app.launch()
        app.selectInitialUpperProgram()
        app.tapReadyWorkoutStart()
        app.tapWorkoutControl("workout.easier")
        let easierMode = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label == %@", "Easier workout"),
            object: app.staticTexts["workout.session-mode"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [easierMode], timeout: 15), .completed)
        XCTAssertEqual(app.staticTexts["workout.session-mode"].label, "Easier workout")
        app.tapWorkoutControl("load.choose.5")
        app.enterPerformedReps("5", field: "set.reps")
        if app.buttons["keyboard.done"].exists { app.buttons["keyboard.done"].tap() }
        savePerformed(in: app)
        XCTAssertTrue(app.staticTexts["set.actual.0"].waitForExistence(timeout: 15))
        app.tapWorkoutControl("movement.partial-action"); app.confirmGuidedSummary()
        for _ in 0..<4 { app.tapWorkoutControl("movement.skip"); app.confirmGuidedSummary() }
        app.tapWorkoutControl("workout.finish")
        XCTAssertTrue(app.staticTexts["workout.saved"].waitForExistence(timeout: 15))

    }
}

extension WorkoutFlowTests {
    @MainActor private func start(_ goal: String = "size", reset: Bool = true, clockOffset: Int = 0) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-cloud-disabled", "-products-unavailable", "-ui-clock-offset", String(clockOffset)] + (reset ? ["-reset-local-store"] : [])
        app.launch()
        if reset {
            app.selectInitialUpperProgram(goal: goal)
        }
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 15))
        app.tapReadyWorkoutStart()
        XCTAssertTrue(app.buttons["workout.close"].waitForExistence(timeout: 15))
        return app
    }
    @MainActor func testFourGoalsEquipmentAndSchedule() {
        for goal in ["fat_loss", "size", "strength", "maintenance"] {
            let app = XCUIApplication()
            app.launchArguments = ["-ui-testing", "-reset-local-store"]
            app.launch()
            app.selectInitialUpperProgram(goal: goal, confirmSelection: false)
            app.revealWorkoutControl(app.staticTexts["onboarding.equipment"], pinnedFooter: app.buttons["onboarding.confirm"], scrollDistance: 100)
            XCTAssertTrue(app.staticTexts["onboarding.equipment"].label.contains("5–80 lb per dumbbell"))
            app.buttons["onboarding.confirm"].tap()
            XCTAssertTrue(app.staticTexts["today.schedule"].waitForExistence(timeout: 15))
            XCTAssertEqual(app.staticTexts["today.schedule"].label, "Sunday · Tuesday · Thursday · suggested cadence")
            app.terminate()
        }
    }
    @MainActor func testActualSetForceQuitResumeProblemAndFinishOffline() {
        let app = start()
        app.beginGuidedMovement(loadID: "load.choose.5")
        app.revealWorkoutControl(app.textFields["set.reps"])
        XCTAssertEqual(app.textFields["set.reps"].value as? String, "Reps performed")
        XCTAssertFalse(app.buttons["set.save"].isEnabled)
        app.enterPerformedReps("7", field: "set.reps")
        if app.buttons["keyboard.done"].exists { app.buttons["keyboard.done"].tap() }
        savePerformed(in: app)
        XCTAssertTrue(app.staticTexts["set.actual.0"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["workout.easier"].exists)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.staticTexts["set.actual.0"].exists)
        app.terminate()
        let resumed = start(reset: false, clockOffset: 90)
        XCTAssertEqual(resumed.staticTexts["set.actual.0"].label, "Set 1: 7 reps")
        XCTAssertEqual(resumed.staticTexts["rest.remaining"].label, "Rest: 30 seconds remaining")
        resumed.buttons["problem.pain"].tap()
        XCTAssertTrue(resumed.staticTexts["movement.stopped"].waitForExistence(timeout: 15))
        XCTAssertFalse(resumed.buttons["set.save"].exists)
        resumed.confirmGuidedSummary()
        for _ in 0..<4 { resumed.tapWorkoutControl("movement.skip"); resumed.confirmGuidedSummary() }
        XCTAssertTrue(resumed.buttons["workout.finish"].waitForExistence(timeout: 15))
        resumed.tapWorkoutControl("workout.finish")
        XCTAssertTrue(resumed.staticTexts["workout.saved"].waitForExistence(timeout: 10))
        XCTAssertTrue(resumed.staticTexts["workout.next-prescription"].exists)
    }
    @MainActor func testPartialAndExplicitLoadCorrectionCancelThenConfirm() {
        let app = start()
        app.tapWorkoutControl("load.choose.5")
        app.enterPerformedReps("4", field: "set.reps")
        if app.buttons["keyboard.done"].exists { app.buttons["keyboard.done"].tap() }
        savePerformed(in: app)
        app.tapWorkoutControl("load.correct")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["set.actual.0"].exists)
        app.tapWorkoutControl("load.correct")
        app.buttons["Keep observations; stop this movement"].tap()
        XCTAssertTrue(app.staticTexts["movement.partial"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["set.actual.0"].exists)
    }
}

extension WorkoutFlowTests {
    @MainActor private func waitEnabled(_ element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed)
    }
    @MainActor func testNormalPerformedWorkoutAndEqualSidesFinishLocally() {
        let app = start("maintenance")
        for movement in 0..<5 {
            // Fixed synthetic Tuesday: Hanging Leg Raise is bodyweight; the
            // third (split squat) and fifth (hammer curl) count each side.
            if movement != 3 { app.tapWorkoutControl("load.choose.5") }
            let perSide = movement == 2 || movement == 4
            app.beginGuidedMovement()
            let input = app.textFields[perSide ? "set.left-reps" : "set.reps"]
            app.revealWorkoutControl(input); waitEnabled(input)
            for set in 0..<2 {
                if perSide {
                    app.enterPerformedReps("10", field: "set.left-reps")
                    app.enterPerformedReps("10", field: "set.right-reps")
                } else { app.enterPerformedReps("10", field: "set.reps") }
                if app.buttons["keyboard.done"].exists { app.buttons["keyboard.done"].tap() }
                waitEnabled(app.buttons["set.save"])
                savePerformed(in: app)
                XCTAssertTrue(app.staticTexts["set.actual.\(set)"].waitForExistence(timeout: 15))
            }
            app.tapWorkoutControl("effort.on_target"); waitEnabled(app.buttons["summary.confirm"])
            XCTAssertTrue(app.buttons["summary.confirm"].waitForExistence(timeout: 15))
            app.confirmGuidedSummary()
            if movement < 4 { app.revealWorkoutControl(app.buttons["movement.partial-action"]) }
        }
        app.tapWorkoutControl("workout.finish")
        XCTAssertTrue(app.staticTexts["workout.saved"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["workout.next-prescription"].label, "Next: THU, 2026-10-08")
        let actualLoad = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "workout.completed-actual-load.")).firstMatch
        app.revealWorkoutControl(actualLoad)
        XCTAssertEqual(actualLoad.label, "Actual load: 5 lb per hand")
        let bodyweightLoad = app.staticTexts["Actual load: bodyweight / your setup — no numeric load recorded"]
        app.revealWorkoutControl(bodyweightLoad); XCTAssertTrue(bodyweightLoad.isHittable)
    }
    @MainActor func testTypedPendingRepsProblemMidnightCannotDiscardSafetyObservation() {
        let app = start()
        app.beginGuidedMovement(loadID: "load.choose.5")
        app.enterPerformedReps("6", field: "set.reps")
        if app.buttons["keyboard.done"].exists { app.buttons["keyboard.done"].tap() }
        app.buttons["problem.pain"].tap()
        XCTAssertTrue(app.staticTexts["set.actual.0"].waitForExistence(timeout: 15))
        app.buttons["workout.close"].tap()
        app.terminate()
        let later = start(reset: false, clockOffset: 86400)
        XCTAssertTrue(later.buttons["workout.keep-original-date"].waitForExistence(timeout: 15))
        XCTAssertFalse(later.buttons["workout.discard-restart"].isEnabled)
        later.buttons["workout.keep-original-date"].tap()
        later.buttons["workout.review"].tap()
        XCTAssertEqual(later.staticTexts["set.actual.0"].label, "Set 1: 6 reps")
        XCTAssertTrue(later.staticTexts["movement.stopped"].exists)
        XCTAssertFalse(later.buttons["movement.setup"].exists)
        XCTAssertFalse(later.buttons["set.save"].exists)
    }
}

extension WorkoutFlowTests {
    @MainActor func testAccessiblePerHandPerSideTotalAndBodyweightLabelsInLandscape() {
        let app = start("maintenance")
        XCTAssertEqual(app.buttons["load.choose.5"].label, "5 lb per hand")
        XCTAssertTrue(app.workoutText("movement.instruction").label.contains("Aim for the listed reps"))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["problem.pain"].exists)
        XCUIDevice.shared.orientation = .portrait
        for _ in 0..<2 { app.tapWorkoutControl("movement.skip"); app.confirmGuidedSummary() }
        XCTAssertTrue(app.workoutText("movement.goal-reps").label.contains("per side"))
        app.tapWorkoutControl("load.choose.5")
        app.enterPerformedReps("7", field: "set.left-reps")
        app.enterPerformedReps("5", field: "set.right-reps")
        if app.buttons["keyboard.done"].exists { app.buttons["keyboard.done"].tap() }
        savePerformed(in: app)
        XCTAssertTrue(app.staticTexts["set.actual.0"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["set.actual.0"].label, "Set 1: left 7, right 5")
        let perSide = XCTAttachment(screenshot: app.screenshot())
        perSide.name = "Candidate synthetic per-side actuals and stopping controls"; perSide.lifetime = .keepAlways; add(perSide)
        app.tapWorkoutControl("movement.partial-action"); app.confirmGuidedSummary()
        XCTAssertFalse(app.buttons["load.choose.5"].exists)
        app.terminate()
        let thursday = start("maintenance", clockOffset: 172800)
        for _ in 0..<4 { thursday.tapWorkoutControl("movement.skip"); thursday.confirmGuidedSummary() }
        XCTAssertEqual(thursday.buttons["load.choose.5"].label, "5 lb total")
    }
}

extension WorkoutFlowTests {
    @MainActor func testReviewRetainsVisiblePendingRepsForPartialAndProblemAfterReopen() {
        for problem in [false, true] {
            let app = start()
            app.beginGuidedMovement(loadID: "load.choose.5")
            app.enterPerformedReps("6", field: "set.reps")
            if app.buttons["keyboard.done"].exists { app.buttons["keyboard.done"].tap() }
            app.buttons["workout.review"].tap()
            app.buttons["Cancel"].tap()
            app.tapWorkoutControl(problem ? "problem.pain" : "movement.partial-action")
            XCTAssertTrue(app.staticTexts["set.actual.0"].waitForExistence(timeout: 15))
            app.terminate()
            let resumed = start(reset: false)
            XCTAssertEqual(resumed.staticTexts["set.actual.0"].label, "Set 1: 6 reps")
            XCTAssertTrue(resumed.staticTexts[problem ? "movement.stopped" : "movement.partial"].exists)
            resumed.confirmGuidedSummary()
            for _ in 0..<4 { resumed.tapWorkoutControl("movement.skip"); resumed.confirmGuidedSummary() }
            resumed.tapWorkoutControl("workout.finish")
            XCTAssertTrue(resumed.staticTexts["workout.saved"].waitForExistence(timeout: 15))
            XCTAssertEqual(resumed.staticTexts["workout.next-prescription"].label, "Next: THU, 2026-10-08")
            resumed.terminate()
        }
    }
    @MainActor func testCorrectionStopRetainsSavedAndPendingSecondSetAfterReopen() {
        let app = start()
        app.tapWorkoutControl("load.choose.5")
        app.enterPerformedReps("7", field: "set.reps")
        if app.buttons["keyboard.done"].exists { app.buttons["keyboard.done"].tap() }
        savePerformed(in: app)
        XCTAssertTrue(app.staticTexts["set.actual.0"].waitForExistence(timeout: 15))
        app.enterPerformedReps("5", field: "set.reps")
        if app.buttons["keyboard.done"].exists { app.buttons["keyboard.done"].tap() }
        app.tapWorkoutControl("load.correct")
        app.buttons["Keep observations; stop this movement"].tap()
        XCTAssertTrue(app.staticTexts["set.actual.1"].waitForExistence(timeout: 15))
        app.terminate()
        let resumed = start(reset: false)
        XCTAssertEqual(resumed.staticTexts["set.actual.0"].label, "Set 1: 7 reps")
        XCTAssertEqual(resumed.staticTexts["set.actual.1"].label, "Set 2: 5 reps")
        XCTAssertTrue(resumed.staticTexts["movement.partial"].exists)
    }
}

extension WorkoutFlowTests {
    @MainActor func testRestoredMalformedCompletionExplicitRepairReopensAndFinalizesOriginalProblem() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-local-store", "-ui-fixture-malformed-completion"]
        app.launch()
        app.selectInitialUpperProgram()
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 15))
        app.tapReadyWorkoutStart()
        XCTAssertTrue(app.buttons["workout.finish"].waitForExistence(timeout: 15))
        app.tapWorkoutControl("workout.finish")
        XCTAssertTrue(app.buttons["workout.repair-completion"].waitForExistence(timeout: 15))
        app.buttons["workout.repair-completion"].tap()
        XCTAssertTrue(app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Affected movements:")).firstMatch.waitForExistence(timeout: 15))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["workout.repair-completion"].exists)
        app.buttons["workout.repair-completion"].tap()
        app.buttons["Keep observations and repair outcomes"].tap()
        let repaired = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["workout.repair-completion"])
        XCTAssertEqual(XCTWaiter.wait(for: [repaired], timeout: 15), .completed)
        app.buttons["workout.review"].tap()
        XCTAssertEqual(app.staticTexts["set.actual.0"].label, "Set 1: 4 reps")
        XCTAssertTrue(app.staticTexts["movement.stopped"].exists)
        XCTAssertFalse(app.staticTexts["summary.corrected.0"].exists)
        XCTAssertFalse(app.buttons["summary.corrections.0"].exists)
        XCTAssertEqual(app.buttons["summary.confirm"].label, "Return to review")
        app.tapWorkoutControl("effort.too_hard")
        app.tapWorkoutControl("summary.confirm")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "workout.summary.")).firstMatch.waitForExistence(timeout: 15))
        app.terminate()
        let resumed = start(reset: false)
        resumed.tapWorkoutControl("workout.review")
        XCTAssertEqual(resumed.staticTexts["set.actual.0"].label, "Set 1: 4 reps")
        XCTAssertTrue(resumed.staticTexts["movement.stopped"].exists)
        XCTAssertTrue(resumed.buttons["effort.too_hard"].isSelected, "Legacy effort edit survives force quit without changing the repaired outcome")
        XCTAssertEqual(resumed.buttons["summary.confirm"].label, "Return to review")
        resumed.navigationBars.buttons["BackButton"].tap()
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: resumed.buttons["summary.confirm"])
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 15), .completed)
        let summaries = resumed.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "workout.summary.")).allElementsBoundByIndex.map(\.identifier)
        XCTAssertEqual(summaries.count, 5)
        XCTAssertEqual(resumed.scrollViews.count, 1, "The active Workout review owns the scroll viewport")
        let reviewScroll = resumed.scrollViews.firstMatch
        let finish = resumed.buttons["workout.finish"], navigation = resumed.navigationBars["Workout"]
        func fullyVisible(_ control: XCUIElement) -> Bool {
            let bounds = control.frame
            return [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy(\.isFinite) &&
                bounds.width > 0 && bounds.height > 0 && reviewScroll.frame.contains(bounds) &&
                bounds.minY >= navigation.frame.maxY && bounds.maxY < finish.frame.minY && control.isHittable
        }
        for identifier in summaries.dropFirst() {
            let control = resumed.buttons[identifier]
            for _ in 0..<24 {
                if fullyVisible(control) { break }
                if control.frame.minY < navigation.frame.maxY { reviewScroll.swipeDown() }
                else { reviewScroll.swipeUp() }
            }
            XCTAssertTrue(control.isHittable)
            XCTAssertTrue(reviewScroll.frame.contains(control.frame))
            XCTAssertGreaterThanOrEqual(control.frame.minY, navigation.frame.maxY)
            XCTAssertLessThan(control.frame.maxY, finish.frame.minY)
            resumed.tapWorkoutControl(identifier); resumed.confirmGuidedSummary()
        }
        resumed.tapWorkoutControl("workout.finish")
        XCTAssertTrue(resumed.staticTexts["workout.saved"].waitForExistence(timeout: 15))
        XCTAssertEqual(resumed.staticTexts["workout.next-prescription"].label, "Next: THU, 2026-10-08")
    }
}

extension WorkoutFlowTests {
    @MainActor func testReviewNavigationExplicitlyKeepsPendingEntryBeforeLeavingMovement() {
        let app = start()
        app.tapWorkoutControl("movement.skip"); app.confirmGuidedSummary()
        app.beginGuidedMovement(loadID: "load.choose.5")
        app.enterPerformedReps("9", field: "set.reps")
        if app.buttons["keyboard.done"].exists { app.buttons["keyboard.done"].tap() }
        app.buttons["workout.review"].tap(); app.buttons["Cancel"].tap()
        XCTAssertEqual(app.textFields["set.reps"].value as? String, "9")
        app.buttons["workout.review"].tap(); app.buttons["Keep entry as partial and review"].tap()
        XCTAssertTrue(app.buttons["summary.confirm"].waitForExistence(timeout: 15))
        app.tapWorkoutControl("summary.confirm")
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Set 1: 9 reps"), object: app.staticTexts["set.actual.0"])
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 15), .completed)
        XCTAssertEqual(app.staticTexts["set.actual.0"].label, "Set 1: 9 reps")
        XCTAssertTrue(app.staticTexts["movement.partial"].exists)
        app.terminate()
        let resumed = start(reset: false)
        resumed.buttons["workout.review"].tap(); resumed.tapWorkoutControl("summary.confirm")
        let reopenedReturn = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Set 1: 9 reps"), object: resumed.staticTexts["set.actual.0"])
        XCTAssertEqual(XCTWaiter.wait(for: [reopenedReturn], timeout: 15), .completed)
        XCTAssertEqual(resumed.staticTexts["set.actual.0"].label, "Set 1: 9 reps")
        XCTAssertTrue(resumed.staticTexts["movement.partial"].exists)
    }
}


extension WorkoutFlowTests {
    @MainActor func testProgramAndStartShowBusyFeedbackWhileSaving() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-local-store", "-ui-slow-save", "-cloud-disabled", "-products-unavailable"]
        app.launch()
        app.selectInitialUpperProgram(confirmSelection: false)
        app.buttons["onboarding.confirm"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["onboarding.busy"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["onboarding.confirm"].isEnabled)
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 15))
        app.tapReadyWorkoutStart(waitForWorkout: false)
        XCTAssertTrue(app.descendants(matching: .any)["today.busy"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["today.start"].isEnabled)
        XCTAssertTrue(app.staticTexts["workout.session-mode"].waitForExistence(timeout: 15))
    }
    @MainActor func testConfirmPrescribedLoadShowsBusyFeedbackWhileSaving() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-local-store", "-fixture-exact-reps", "-ui-slow-save", "-cloud-disabled", "-products-unavailable"]
        app.launch()
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 30))
        app.tapReadyWorkoutStart()
        app.tapWorkoutControl("load.confirm-prescribed")
        XCTAssertTrue(app.descendants(matching: .any)["workout.busy"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["load.confirm-prescribed"].isEnabled)
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["load.confirm-prescribed"])
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 15), .completed)
    }
}
