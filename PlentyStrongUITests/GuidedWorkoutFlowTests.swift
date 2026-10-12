import XCTest

final class GuidedWorkoutFlowTests: XCTestCase {
    @MainActor func testPolishWholeEditorCommitAndCenter() {
        let app = launch()
        app.confirmGuidedWeight(); app.beginGuidedMovement()
        let reps = app.textFields["set.reps"]
        app.revealWorkoutControl(reps); reps.tap()
        let first = ProcessInfo.processInfo.systemUptime
        reps.typeText("1")
        print("POLISH native first key seconds=\(ProcessInfo.processInfo.systemUptime - first)")
        let reasonInsertedWhileTyping = app.buttons["reason.effort_limit"].exists
        capture(app, "Polish typing first of eleven")
        let second = ProcessInfo.processInfo.systemUptime
        reps.typeText("1")
        print("POLISH native second key seconds=\(ProcessInfo.processInfo.systemUptime - second)")
        XCTAssertFalse(reasonInsertedWhileTyping, "Typing 1 of 11 must not insert the reason")
        XCTAssertEqual(reps.value as? String, "11")
        XCTAssertFalse(app.buttons["reason.effort_limit"].exists)
        XCTAssertEqual(app.buttons["set.save"].frame.midX, app.frame.midX, accuracy: 2)
        app.buttons["keyboard.done"].tap()
        reps.tap(); reps.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2) + "9")
        XCTAssertFalse(app.buttons["reason.effort_limit"].exists)
        app.buttons["set.save"].tap() // Commit only; this tap intentionally stays on the editor.
        XCTAssertTrue(app.buttons["reason.effort_limit"].exists)
        XCTAssertTrue(app.textFields["set.reps"].exists, "First Next commits but cannot save without reason")
        capture(app, "Polish committed below goal reason and centered Next")
        app.tapWorkoutControl("reason.effort_limit"); app.tapWorkoutControl("set.save")
        XCTAssertTrue(app.staticTexts["rest.remaining"].waitForExistence(timeout: 15))
        capture(app, "Polish 02 minute timer")
    }

    @MainActor func testPolishEarlyEndSummaryUsesExistingAnchor() {
        let app = launch()
        app.confirmGuidedWeight(); app.beginGuidedMovement()
        app.enterPerformedReps("10"); app.tapWorkoutControl("set.save")
        XCTAssertEqual(app.staticTexts["rest.remaining"].label, "Rest: 02:00")
        app.tapWorkoutControl("movement.partial-action")
        XCTAssertTrue(app.staticTexts["movement.summary"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["rest.remaining"].label, "Rest: 03:00")
        capture(app, "Polish early boundary Summary uses same-set 03 minute anchor")
        app.confirmGuidedSummary(continueRest: false)
        XCTAssertEqual(app.staticTexts["rest.remaining"].label, "Rest: 03:00")
    }

    @MainActor func testPolishRejectedFinishStaysInReview() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-local-store", "-ui-fixture-malformed-completion", "-cloud-disabled", "-products-unavailable"]
        app.launch(); app.selectInitialUpperProgram(); app.tapReadyWorkoutStart()
        XCTAssertTrue(app.buttons["workout.finish"].waitForExistence(timeout: 15))
        app.tapWorkoutControl("workout.finish")
        XCTAssertTrue(app.buttons["workout.repair-completion"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons["workout.finish"].label, "Retry Finish")
        XCTAssertTrue(app.staticTexts["save.error"].exists)
        XCTAssertFalse(app.buttons["today.start"].isHittable)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier CONTAINS %@", "workout.card.", ".correct.")).count, 0)
        capture(app, "Polish rejected Finish retains frozen review and error")
    }

    @MainActor func testFinalCardsKeepGoalsActualsAndConfirmCorrectionsInline() { finalCards(extra: []) }
    @MainActor func testFinalCardsAccessibilityStackedComparisonsAndSavedResults() { finalCards(extra: ["-ui-large-text", "-ui-dark"]) }
    @MainActor private func finalCards(extra: [String]) {
        let app = launch(extra: extra)
        capture(app, "Final matrix introduction " + (extra.isEmpty ? "normal" : "accessibility5"))
        app.confirmGuidedWeight(amount: "20"); app.beginGuidedMovement()
        app.revealWorkoutControl(app.textFields["set.reps"]); app.textFields["set.reps"].tap()
        capture(app, "Final matrix set keyboard " + (extra.isEmpty ? "normal" : "accessibility5"))
        app.buttons["keyboard.done"].tap()
        app.enterPerformedReps("10"); app.tapWorkoutControl("set.save")
        capture(app, "Final matrix within-movement rest " + (extra.isEmpty ? "normal" : "accessibility5"))
        app.tapWorkoutControl("movement.partial-action")
        capture(app, "Final matrix movement summary " + (extra.isEmpty ? "normal" : "accessibility5"))
        app.tapWorkoutControl("effort.unknown")
        app.tapWorkoutControl("workout.stop"); app.buttons["workout.stop-confirm"].firstMatch.tap()
        XCTAssertTrue(app.buttons["workout.finish"].waitForExistence(timeout: 15))
        let actualWeight = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "workout.card.", "summary.actual-weight")).firstMatch
        app.revealWorkoutControl(actualWeight)
        XCTAssertEqual(actualWeight.label, "20 lb per hand")
        let prefix = String(actualWeight.identifier.dropLast("summary.actual-weight".count))
        XCTAssertEqual(app.staticTexts[prefix + "summary.goal-weight"].label, "40 lb per hand")
        XCTAssertEqual(app.staticTexts[prefix + "set.actual.0"].label, "10 reps")
        XCTAssertEqual(app.staticTexts[prefix + "set.unrecorded.1"].label, "Unrecorded")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "workout.summary.")).count, 0)
        XCTAssertFalse(app.buttons["workout.review"].exists)
        capture(app, "Final cards goal40 actual20 distinct and no routine Review " + (extra.isEmpty ? "normal" : "accessibility5"))
        app.revealWorkoutControl(app.buttons[prefix + "correct.0"])
        XCTAssertGreaterThanOrEqual(app.buttons[prefix + "correct.0"].frame.height, 44)
        app.tapWorkoutControl(prefix + "correct.0"); app.replacePerformedReps("7")
        app.tapWorkoutControl("reason.effort_limit"); app.tapWorkoutControl("correction.save")
        waitForCorrectionReturn(app)
        XCTAssertFalse(app.staticTexts["movement.summary"].exists)
        app.revealWorkoutControl(app.staticTexts[prefix + "set.actual.0"])
        XCTAssertEqual(app.staticTexts[prefix + "set.actual.0"].label, "7 reps")
        XCTAssertEqual(app.staticTexts[prefix + "outcome"].label, "Outcome: partial")
        XCTAssertFalse(app.buttons["workout.finish"].isEnabled)
        app.revealWorkoutControl(app.buttons[prefix + "effort.picker"])
        XCTAssertTrue(app.buttons[prefix + "effort.picker"].label.hasSuffix("I'm not sure"), "Known explicit local answer survives correction")
        app.tapWorkoutControl(prefix + "corrections.0")
        let detail = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Correction 1. Original:")).firstMatch
        app.revealWorkoutControl(detail)
        XCTAssertTrue(detail.label.contains("Original: 10 reps") && detail.label.contains("Replacement: 7 reps"))
        capture(app, "Final inline correction provenance and explicit confirmation " + (extra.isEmpty ? "normal" : "accessibility5"))
        app.revealWorkoutControl(app.buttons[prefix + "confirm"])
        XCTAssertGreaterThanOrEqual(app.buttons[prefix + "confirm"].frame.height, 44)
        XCTAssertTrue(app.buttons[prefix + "confirm"].isHittable)
        app.terminate()
        let resumed = launch(reset: false, extra: extra)
        resumed.revealWorkoutControl(resumed.buttons[prefix + "effort.picker"])
        XCTAssertTrue(resumed.buttons[prefix + "effort.picker"].label.hasSuffix("Choose effort…"), "Pending unknown after relaunch is not an explicit answer")
        XCTAssertFalse(resumed.buttons[prefix + "confirm"].isEnabled)
        XCTAssertFalse(resumed.buttons["workout.finish"].isEnabled)
        resumed.tapWorkoutControl(prefix + "effort.picker"); resumed.buttons[prefix + "effort.unknown"].firstMatch.tap()
        resumed.tapWorkoutControl(prefix + "confirm")
        let confirmed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: resumed.buttons[prefix + "confirm"])
        XCTAssertEqual(XCTWaiter.wait(for: [confirmed], timeout: 15), .completed)
        XCTAssertTrue(resumed.buttons["workout.finish"].isEnabled)
        resumed.buttons["workout.close"].tap()
        resumed.selectNativeTab("History", identifier: "tab.history")
        resumed.tapWorkoutControl("workout.resume")
        resumed.tapWorkoutControl("workout.finish")
        XCTAssertTrue(resumed.staticTexts["today.schedule"].waitForExistence(timeout: 15))
        XCTAssertFalse(resumed.staticTexts["workout.saved"].exists)
        XCTAssertFalse(resumed.buttons["today.saved-workout"].exists)
        capture(resumed, "Accepted Finish immediately selects Today " + (extra.isEmpty ? "normal" : "accessibility5"))
        resumed.selectNativeTab("History", identifier: "tab.history")
        resumed.tapWorkoutControl("history.first-workout")
        let actual = resumed.staticTexts["history.actual-reps"]
        resumed.revealWorkoutControl(actual)
        XCTAssertEqual(actual.label, "7 reps")
        let correction = resumed.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "history.corrections.")).firstMatch
        resumed.revealWorkoutControl(correction); correction.tap()
        let retained = resumed.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Correction 1. Original:")).firstMatch
        resumed.revealWorkoutControl(retained)
        XCTAssertTrue(retained.label.contains("Original: 10 reps") && retained.label.contains("Replacement: 7 reps"))
        capture(resumed, "Accepted History retains exact audit " + (extra.isEmpty ? "normal" : "accessibility5"))
    }

    @MainActor func testFinalPerSideCardsKeepSkippedUnrecordedAndStoppedRawSlots() {
        let app = launch(mode: "per-side")
        for _ in 0..<2 { app.tapWorkoutControl("movement.skip"); app.confirmGuidedSummary() }
        app.beginGuidedMovement(weight: "5")
        app.tapWorkoutControl("set.skip")
        app.enterPerformedReps("0", field: "set.left-reps")
        app.tapWorkoutControl("problem.pain")
        XCTAssertEqual(app.staticTexts["set.actual.1"].label, "Left 0, right unrecorded")
        app.tapWorkoutControl("effort.unknown")
        app.tapWorkoutControl("workout.stop"); app.buttons["workout.stop-confirm"].firstMatch.tap()
        XCTAssertTrue(app.buttons["workout.finish"].waitForExistence(timeout: 15))
        let actual = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "workout.card.", "set.actual.1")).firstMatch
        app.revealWorkoutControl(actual)
        let prefix = String(actual.identifier.dropLast("set.actual.1".count))
        XCTAssertEqual(actual.label, "Left 0, right unrecorded")
        XCTAssertEqual(app.staticTexts[prefix + "set.skipped.0"].label, "Skipped")
        XCTAssertEqual(app.staticTexts[prefix + "set.unrecorded.2"].label, "Unrecorded")
        XCTAssertTrue(app.staticTexts[prefix + "summary.slot.1"].label.contains("8 reps per side"))
        XCTAssertEqual(app.staticTexts[prefix + "summary.goal-weight"].label, "Unknown load")
        XCTAssertEqual(app.staticTexts[prefix + "outcome"].label, "Outcome: stopped")
        XCTAssertEqual(app.staticTexts[prefix + "problem"].label, "Safety: pain")
        capture(app, "Final per side raw zero missing right skipped versus unrecorded slots")
        app.tapWorkoutControl("workout.finish")
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 15))
        app.selectNativeTab("History", identifier: "tab.history"); app.tapWorkoutControl("history.first-workout")
        let raw = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "left 0, right unrecorded")).firstMatch
        app.revealWorkoutControl(raw); XCTAssertTrue(raw.exists)
        capture(app, "Accepted History retains zero and missing right")
    }

    @MainActor func testBetweenMovementRestNormalAndAccessibilityActionsReachable() {
        for extra in [[], ["-ui-large-text", "-ui-dark"]] {
            let app = launch(extra: extra)
            app.confirmGuidedWeight(); app.beginGuidedMovement()
            app.enterPerformedReps("10"); app.tapWorkoutControl("set.save")
            XCTAssertTrue(app.staticTexts["rest.next-goal"].waitForExistence(timeout: 5))
            app.revealWorkoutControl(app.staticTexts["rest.next-goal"])
            XCTAssertEqual(app.staticTexts["rest.next-goal"].label, "Goal: 10 reps")
            XCTAssertEqual(app.staticTexts["rest.next-weight"].label, "Weight: 40 lb per hand")
            XCTAssertGreaterThanOrEqual(app.buttons["workout.skip"].frame.height, 44)
            capture(app, "Final rebuilt within-movement goal and confirmed weight " + (extra.isEmpty ? "normal" : "accessibility5"))
            app.tapWorkoutControl("movement.partial-action")
            XCTAssertTrue(app.buttons["summary.confirm"].waitForExistence(timeout: 15))
            app.revealWorkoutControl(app.staticTexts["summary.goal-weight"])
            XCTAssertGreaterThanOrEqual(app.buttons["workout.stop"].frame.height, 44)
            XCTAssertTrue(app.buttons["workout.stop"].isHittable)
            capture(app, "Final rebuilt movement summary and trailing Stop " + (extra.isEmpty ? "normal" : "accessibility5"))
            app.confirmGuidedSummary(continueRest: false)
            XCTAssertTrue(app.staticTexts["rest.remaining"].waitForExistence(timeout: 15))
            app.revealWorkoutControl(app.staticTexts["rest.next-weight"])
            XCTAssertEqual(app.staticTexts["rest.next-weight"].label, "Your assistance setup — no numeric load is inferred")
            XCTAssertTrue(app.buttons["guided.next"].isHittable)
            XCTAssertTrue(app.buttons["workout.skip"].isHittable)
            capture(app, "Final matrix between-movement rest " + (extra.isEmpty ? "normal" : "accessibility5"))
            app.openWorkoutSkip()
            XCTAssertTrue(app.buttons["movement.skip"].firstMatch.waitForExistence(timeout: 5))
            capture(app, "Final matrix native between-movement Skip " + (extra.isEmpty ? "normal" : "accessibility5"))
            app.cancelWorkoutSkip(); app.terminate()
        }
    }

    @MainActor func testRestPreviewDistinguishesUnknownExternalLoadFromBodyweight() {
        let app = launch(mode: "per-side", extra: ["-ui-large-text", "-ui-dark"])
        app.tapWorkoutControl("movement.skip"); app.confirmGuidedSummary()
        app.beginGuidedMovement(weight: "5")
        app.enterPerformedReps("8"); app.tapWorkoutControl("set.save")
        app.tapWorkoutControl("movement.partial-action"); app.confirmGuidedSummary(continueRest: false)
        revealRestPreview(app, identifier: "rest.next-weight")
        XCTAssertEqual(app.staticTexts["rest.next-weight"].label, "Weight: Unknown load")
        XCTAssertTrue(app.buttons["guided.next"].isHittable)
        XCTAssertTrue(app.buttons["workout.skip"].isHittable)
        capture(app, "Final accessibility5 external unknown load full-width rest preview")
        app.continueGuidedRest(); app.beginGuidedMovement(weight: "5")
        app.enterPerformedReps("8", field: "set.left-reps"); app.enterPerformedReps("8", field: "set.right-reps")
        app.tapWorkoutControl("set.save")
        revealRestPreview(app, identifier: "rest.next-goal")
        XCTAssertEqual(app.staticTexts["rest.next-goal"].label, "Goal: 8 reps per side")
        capture(app, "Final accessibility5 visible within-rest exact per-side goal")
        revealRestPreview(app, identifier: "rest.next-weight")
        XCTAssertEqual(app.staticTexts["rest.next-weight"].label, "Weight: 5 lb per hand")
        capture(app, "Final accessibility5 visible within-rest confirmed actual weight")
        app.tapWorkoutControl("movement.partial-action"); app.confirmGuidedSummary(continueRest: false)
        revealRestPreview(app, identifier: "rest.next-weight")
        XCTAssertEqual(app.staticTexts["rest.next-weight"].label, "Bodyweight / your setup — no numeric load is inferred")
        capture(app, "Final accessibility5 bodyweight rest preview distinct from unknown external load")
    }

    @MainActor func testRestNextLabelAfterPreviewScroll() {
        let app = launch(extra: ["-ui-large-text", "-ui-dark"])
        app.confirmGuidedWeight(); app.beginGuidedMovement()
        app.enterPerformedReps("10"); app.tapWorkoutControl("set.save")
        XCTAssertTrue(app.staticTexts["rest.next-weight"].waitForExistence(timeout: 5))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.otherElements["workout.busy"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        capture(app, "Stable final accessibility rest Next before preview scroll")
        revealRestPreview(app, identifier: "rest.next-weight")
        let next = app.buttons["guided.next"]
        XCTAssertEqual(next.label, "Next")
        XCTAssertTrue(next.isEnabled && next.isHittable)
        XCTContext.runActivity(named: "Stable final rest Next after preview scroll") { activity in
            let hierarchy = XCTAttachment(string: app.debugDescription); hierarchy.name = "Stable Next rest AX"; hierarchy.lifetime = .keepAlways; activity.add(hierarchy)
            let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Stable final accessibility rest Next after preview scroll"; screenshot.lifetime = .keepAlways; activity.add(screenshot)
        }
        app.tapWorkoutControl("guided.next")
        XCTAssertTrue(app.textFields["set.reps"].waitForExistence(timeout: 15))
    }

    @MainActor func testFinalCardCompactCorrectionAndConfirmationTouchTargets() {
        let app = launch()
        XCTAssertTrue(app.buttons["workout.skip"].waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(app.buttons["workout.skip"].frame.height, 44)
        XCTAssertTrue(app.buttons["workout.skip"].isHittable)
        app.confirmGuidedWeight(); app.beginGuidedMovement()
        XCTAssertGreaterThanOrEqual(app.buttons["workout.skip"].frame.height, 44)
        app.enterPerformedReps("10"); app.tapWorkoutControl("set.save")
        XCTAssertGreaterThanOrEqual(app.buttons["workout.skip"].frame.height, 44)
        app.tapWorkoutControl("movement.partial-action"); app.tapWorkoutControl("effort.unknown")
        XCTAssertGreaterThanOrEqual(app.buttons["workout.stop"].frame.height, 44)
        XCTAssertTrue(app.buttons["workout.stop"].isHittable)
        app.tapWorkoutControl("workout.stop"); app.buttons["workout.stop-confirm"].firstMatch.tap()
        XCTAssertTrue(app.buttons["workout.finish"].waitForExistence(timeout: 15))
        let correct = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "workout.card.", ".correct.0")).firstMatch
        app.revealWorkoutControl(correct)
        XCTAssertGreaterThanOrEqual(correct.frame.height, 44)
        XCTAssertTrue(correct.isHittable)
        let prefix = String(correct.identifier.dropLast("correct.0".count))
        correct.tap(); app.replacePerformedReps("9"); app.tapWorkoutControl("reason.effort_limit")
        app.tapWorkoutControl("correction.save"); waitForCorrectionReturn(app)
        let confirm = app.buttons[prefix + "confirm"]
        app.revealWorkoutControl(confirm)
        XCTAssertGreaterThanOrEqual(confirm.frame.height, 44)
        XCTAssertTrue(confirm.isHittable)
        XCTAssertFalse(app.buttons["workout.finish"].isEnabled)
        capture(app, "Final normal compact native correction and inline Confirm 44-point targets")
        confirm.tap()
        let confirmed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: confirm)
        XCTAssertEqual(XCTWaiter.wait(for: [confirmed], timeout: 15), .completed)
        XCTAssertTrue(app.buttons["workout.finish"].isEnabled)
    }

    @MainActor func testSummaryRequiresNativeExplicitEffortAndAtomicStop() {
        let app = launch(); begin(app)
        app.enterPerformedReps("10"); app.tapWorkoutControl("set.save")
        app.tapWorkoutControl("movement.partial-action")
        XCTAssertTrue(app.buttons["summary.confirm"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["summary.confirm"].isEnabled)
        XCTAssertTrue(app.buttons["effort.picker"].exists, "Summary requires a native explicit-selection menu")
        XCTAssertFalse(app.buttons["workout.skip"].exists)
        XCTAssertTrue(app.buttons["workout.stop"].exists)
        XCTAssertEqual(app.staticTexts["summary.goal-weight"].label, "40 lb per hand")
        XCTAssertEqual(app.staticTexts["summary.actual-weight"].label, "40 lb per hand")
        XCTAssertLessThan(app.staticTexts["rest.remaining"].frame.minY, app.staticTexts["movement.summary"].frame.minY)
        XCTAssertFalse(app.staticTexts["effort.meanings"].exists)
        XCTAssertFalse(app.workoutText("movement.first-workout").exists)
        app.tapWorkoutControl("effort.meanings-disclosure")
        app.revealWorkoutControl(app.staticTexts["effort.meanings"])
        XCTAssertTrue(app.staticTexts["effort.meanings"].label.contains("every set"))
        for option in ["too_easy", "on_target", "too_hard", "unknown"] {
            app.tapWorkoutControl("effort.picker")
            app.buttons["effort.\(option)"].firstMatch.tap()
            XCTAssertTrue(app.buttons["summary.confirm"].isEnabled, "Each explicit option is a valid answer")
        }
        app.tapWorkoutControl("effort.placeholder")
        XCTAssertFalse(app.buttons["summary.confirm"].isEnabled, "The nil placeholder remains distinct from explicit unknown")
        app.tapWorkoutControl("effort.unknown")
        XCTAssertTrue(app.buttons["effort.picker"].label.hasSuffix("I'm not sure"))
        capture(app, "Compact summary with top deadline and explicit unknown effort")
        app.tapWorkoutControl("workout.stop")
        XCTAssertTrue(app.sheets["Stop workout?"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["problem.pain"].firstMatch.label.contains("Incline DB Press"))
        capture(app, "Native Stop workout confirmation with named source safety")
        app.cancelWorkoutDialog("Stop workout?")
        XCTAssertTrue(app.buttons["summary.confirm"].exists)
        XCTAssertTrue(app.buttons["effort.picker"].label.hasSuffix("I'm not sure"))
        XCTAssertFalse(app.buttons["workout.finish"].exists)
        app.tapWorkoutControl("workout.stop")
        app.buttons["workout.stop-confirm"].firstMatch.tap()
        XCTAssertTrue(app.buttons["workout.finish"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["summary.confirm"].exists)
        capture(app, "Atomic Stop keeps results and opens explicit final review")
        app.terminate()
        let resumed = launch(reset: false)
        XCTAssertTrue(resumed.buttons["workout.finish"].waitForExistence(timeout: 15))
        let effort = resumed.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "workout.card.", ".effort-saved")).firstMatch
        resumed.revealWorkoutControl(effort)
        XCTAssertEqual(effort.label, "Effort: I'm not sure")
        XCTAssertFalse(resumed.buttons["workout.review"].exists)
        XCTAssertFalse(resumed.buttons["summary.confirm"].exists)
        XCTAssertFalse(resumed.buttons["workout.stop"].exists)

    }

    @MainActor func testSummaryStopSafetySavesWithoutInventedEffort() {
        let app = launch(); begin(app)
        app.enterPerformedReps("10"); app.tapWorkoutControl("set.save")
        app.tapWorkoutControl("movement.partial-action")
        let deadline = app.staticTexts["rest.remaining"].label
        app.tapWorkoutControl("workout.stop")
        XCTAssertFalse(app.buttons["workout.stop-confirm"].exists && app.buttons["workout.stop-confirm"].firstMatch.isEnabled)
        XCTAssertTrue(app.buttons["problem.pain"].firstMatch.label.contains("Incline DB Press"))
        app.buttons["problem.pain"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["movement.stopped"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["summary.confirm"].isEnabled)
        XCTAssertTrue(app.buttons["effort.picker"].label.hasSuffix("Choose effort…"))
        XCTAssertFalse(app.buttons["workout.stop"].exists, "No tappable zero-action Stop dialog after safety with nil effort")
        XCTAssertTrue(app.staticTexts["summary.effort-required"].exists)
        XCTAssertEqual(app.staticTexts["set.actual.0"].label, "10 reps")
        XCTAssertEqual(app.staticTexts["rest.remaining"].label, deadline)
        XCTAssertFalse(app.buttons["workout.finish"].exists)
        capture(app, "Immediate safety retains original deadline and pending effort")
    }
    @MainActor func testEmptySummaryStopNeedsNoEffortAndRetainsSkippedSlots() {
        let app = launch(); app.tapWorkoutControl("movement.skip")
        XCTAssertTrue(app.staticTexts["movement.summary"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["effort.picker"].exists)
        XCTAssertTrue(app.buttons["summary.confirm"].isEnabled)
        XCTAssertTrue(app.staticTexts["set.unrecorded.0"].exists)
        capture(app, "Compact all-skipped summary without effort")
        app.tapWorkoutControl("workout.stop")
        XCTAssertTrue(app.buttons["workout.stop-confirm"].firstMatch.isEnabled)
        app.buttons["workout.stop-confirm"].firstMatch.tap()
        XCTAssertTrue(app.buttons["workout.finish"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["set.actual.0"].exists)
        capture(app, "All-skipped atomic Stop without invented observations or effort")
    }

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
        XCTAssertEqual(app.staticTexts["set.actual.0"].label, "10 reps")
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
        XCTAssertEqual(app.staticTexts["set.actual.0"].label, "10 reps")
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
        XCTAssertEqual(app.staticTexts["set.actual.0"].label, "Left 7, right unrecorded")
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
        XCTAssertEqual(app.staticTexts["set.actual.0"].label, "9 reps")
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
        XCTAssertEqual(app.staticTexts["set.actual.1"].label, "10 reps")
        XCTAssertEqual(app.staticTexts["set.skipped.2"].label, "Skipped")
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
        XCTAssertEqual(app.staticTexts["set.unrecorded.0"].label, "Unrecorded")
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
        XCTAssertEqual(app.staticTexts["set.actual.0"].label, "8 reps")
        XCTAssertEqual(app.staticTexts["summary.goal-weight"].label, "Bodyweight")
        XCTAssertEqual(app.staticTexts["summary.actual-weight"].label, "Bodyweight")
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
        XCTAssertEqual(app.staticTexts["rest.remaining"].label, "Rest: 02:00")
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
    /// Preview captures require visible pixels above the actual pinned footer;
    /// AX can report an obscured static label as hittable before it is readable.
    @MainActor private func revealRestPreview(_ app: XCUIApplication, identifier: String) {
        let text = app.staticTexts[identifier], footer = app.buttons["guided.next"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        let deadline = app.staticTexts["rest.remaining"].label
        func visible() -> Bool {
            let bounds = text.frame
            let top = app.navigationBars.allElementsBoundByIndex.map(\.frame.maxY).max() ?? app.frame.minY
            return bounds.minY >= top + 8 && bounds.maxY <= footer.frame.minY - 16 && text.isHittable
        }
        for _ in 0..<12 {
            if visible() { break }
            let bounds = text.frame
            let top = (app.navigationBars.allElementsBoundByIndex.map(\.frame.maxY).max() ?? app.frame.minY) + 16
            let bottom = footer.frame.minY - 32
            let above = bounds.minY < top
            let shift = above ? top - bounds.minY : bounds.maxY - (bottom + 16)
            let distance = min(bottom - top - 32, max(24, shift + 12))
            XCTAssertGreaterThan(distance, 0)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let startY = above ? top : bottom
            let endY = above ? top + distance : bottom - distance
            origin.withOffset(CGVector(dx: app.frame.midX, dy: startY)).press(forDuration: 0.01, thenDragTo: origin.withOffset(CGVector(dx: app.frame.midX, dy: endY)))
        }
        XCTAssertTrue(visible(), "Show the complete preview between navigation and the pinned Next")
        XCTAssertEqual(app.staticTexts["rest.remaining"].label, deadline, "Inspection does not restart the original deadline")
    }
    @MainActor private func launch(mode: String = "normal", reset: Bool = true, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-fixture-exact-reps", "-fixture-exact-mode", mode, "-cloud-disabled", "-products-unavailable"] + (reset ? ["-reset-local-store"] : []) + extra
        app.launch()
        if extra.contains("-ui-large-text"), mode == "per-side" || !reset {
            // This restored synthetic draft parks behind the actual Resume
            // affordance; Today Start is absent at this text size.
            XCTAssertTrue(app.buttons["workout.resume"].waitForExistence(timeout: 15))
            app.tapWorkoutControl("workout.resume")
        } else {
            if extra.contains("-ui-large-text") { app.revealWorkoutControl(app.buttons["today.start"]) }
            app.tapReadyWorkoutStart()
        }
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
        let left = app.textFields["set.left-reps"], right = app.textFields["set.right-reps"]
        app.revealWorkoutControl(left); left.tap(); left.typeText("8")
        app.revealWorkoutControl(right); right.tap(); right.typeText("6")
        XCTAssertFalse(app.buttons["reason.effort_limit"].exists, "Left-to-right focus remains one editor")
        XCTAssertEqual(left.value as? String, "8"); XCTAssertEqual(right.value as? String, "6")
        app.buttons["set.save"].tap() // Commit only; this tap intentionally stays on the editor.
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
        XCTAssertEqual(app.staticTexts["set.skipped.1"].label, "Skipped")
        XCTAssertFalse(app.staticTexts["summary.corrected.0"].exists)
        XCTAssertFalse(app.buttons["summary.corrections.0"].exists)
        XCTAssertTrue(app.staticTexts["summary.slot.0"].label.contains("10"))
        XCTAssertTrue(app.staticTexts["summary.slot.2"].exists)
        XCTAssertEqual(app.staticTexts["set.actual.2"].label, "10 reps")
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
        XCTAssertEqual(app.staticTexts["set.actual.0"].label, "10 reps")
        app.tapWorkoutControl("summary.correct.0")
        app.replacePerformedReps("9")
        app.tapWorkoutControl("reason.effort_limit")
        app.tapWorkoutControl("correction.save")
        waitForCorrectionReturn(app)
        XCTAssertTrue(app.staticTexts["movement.partial"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["set.actual.0"].label, "9 reps")
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
        app.tapWorkoutControl("effort.too_hard"); app.tapWorkoutControl("summary.confirm")
        XCTAssertTrue(app.staticTexts["rest.remaining"].waitForExistence(timeout: 15))
        app.buttons["guided.back"].tap()
        XCTAssertTrue(app.buttons["effort.picker"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["effort.picker"].label.hasSuffix("Too hard"), "Primary confirmation saves the local explicit selection for review")
        app.tapWorkoutControl("summary.correct.0")
        app.replacePerformedReps("9")
        XCTAssertEqual(app.staticTexts["set.goal"].label, "Set 1 goal: 10 reps")
        XCTAssertFalse(app.buttons["correction.save"].isEnabled)
        app.tapWorkoutControl("reason.effort_limit")
        XCTAssertTrue(app.buttons["correction.save"].isEnabled)
        capture(app, "Guided completed correction required reason before partial demotion")
        app.tapWorkoutControl("correction.save"); waitForCorrectionReturn(app)
        XCTAssertEqual(app.staticTexts["set.actual.0"].label, "9 reps")
        XCTAssertEqual(app.staticTexts["summary.outcome"].label, "Outcome: completed", "Positive completed actuals with an explicit shortfall reason remain qualified")
        app.tapWorkoutControl("summary.correct.0")
        app.replacePerformedReps("0")
        XCTAssertEqual(app.staticTexts["set.goal"].label, "Set 1 goal: 10 reps")
        XCTAssertFalse(app.buttons["correction.save"].isEnabled)
        app.tapWorkoutControl("reason.effort_limit")
        XCTAssertTrue(app.buttons["correction.save"].isEnabled)
        capture(app, "Guided zero correction with required reason and original goal")
        app.tapWorkoutControl("correction.save"); waitForCorrectionReturn(app)
        XCTAssertEqual(app.staticTexts["set.actual.0"].label, "0 reps")
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
        XCTAssertEqual(resumed.staticTexts["rest.remaining"].label, "Rest: 00:00")
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
        XCTAssertEqual(app.staticTexts["set.actual.0"].label, "9 reps")
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
        XCTAssertEqual(app.staticTexts["set.actual.0"].label, "Left 7, right unrecorded")
        app.tapWorkoutControl("summary.correct.0")
        app.replacePerformedReps("0", field: "set.left-reps")
        XCTAssertEqual(app.textFields["set.right-reps"].value as? String, "Right reps performed")
        XCTAssertEqual(app.staticTexts["set.goal"].label, "Set 1 goal: 8 reps per side")
        XCTAssertTrue(app.buttons["correction.save"].isEnabled, "Authoritative stopped raw correction does not demand an invented reason")
        app.tapWorkoutControl("correction.save")
        waitForCorrectionReturn(app)
        XCTAssertTrue(app.staticTexts["movement.stopped"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["set.actual.0"].label, "Left 0, right unrecorded")
        app.tapWorkoutControl("summary.corrections.0")
        let rawDetail = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Correction 1. Original:")).firstMatch
        app.revealWorkoutControl(rawDetail)
        XCTAssertTrue(rawDetail.label.contains("Original: left 7, right unrecorded"))
        XCTAssertTrue(rawDetail.label.contains("Replacement: left 0, right unrecorded"))
        XCTAssertTrue(rawDetail.label.contains("Reason: Not recorded"))
        XCTAssertFalse(app.buttons["set.save"].exists)
        XCTAssertTrue(app.staticTexts["summary.slot.0"].label.contains("8"))
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
