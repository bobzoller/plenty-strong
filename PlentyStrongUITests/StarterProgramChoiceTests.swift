import XCTest

final class StarterProgramChoiceTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    @MainActor private func launch(_ extras: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-local-store", "-cloud-disabled", "-products-unavailable"] + extras
        app.launch()
        return app
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription); hierarchy.name = name + " AX hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
    }
    @MainActor private func revealCard(_ card: XCUIElement, in app: XCUIApplication) {
        let footer = app.buttons["onboarding.confirm"]
        if !app.launchArguments.contains("-ui-large-text") {
            app.revealWorkoutControl(card, pinnedFooter: footer, scrollDistance: 100)
            return
        }
        // Return to a known position before searching: lazy offscreen rows have
        // no frame, so an absent card cannot tell us which direction to scroll.
        let restore = app.buttons["onboarding.restore"]
        for _ in 0..<12 where !restore.isHittable { app.swipeDown() }
        XCTAssertTrue(restore.isHittable)
        // A large-text card can be taller than the viewport. Its full text stays
        // scrollable; verify a visible 44-point hit area without shrinking text.
        for _ in 0..<40 {
            let top = app.navigationBars.firstMatch.frame.maxY + 16
            let bottom = app.frame.maxY - 100
            let requiredVisible: CGFloat = card.exists ? min(360, card.frame.height) : 360
            if card.exists, card.isHittable, card.frame.minY >= top,
               min(card.frame.maxY, bottom) - card.frame.minY >= requiredVisible { return }
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let above = card.exists && card.frame.minY < top
            let deficit = card.exists ? (above ? top - card.frame.minY : max(40, card.frame.minY + requiredVisible - bottom)) : 200
            let distance = min(200, max(40, deficit))
            let start = origin.withOffset(CGVector(dx: app.frame.midX, dy: above ? top + 40 : bottom - 20))
            let end = origin.withOffset(CGVector(dx: app.frame.midX, dy: above ? top + 40 + distance : bottom - 20 - distance))
            start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
        }
        capture(app, "Unreachable large emphasis card")
        XCTFail("The card must expose a readable title and at least44-point visible hit area")
    }
    @MainActor private func tapCard(_ card: XCUIElement, in app: XCUIApplication) {
        if app.launchArguments.contains("-ui-large-text") {
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: card.frame.midX, dy: card.frame.minY + 50)).tap()
        } else { card.tap() }
    }
    @MainActor private func choice(_ choice: String, goal: String = "size", revealConfirmation: Bool = true, in app: XCUIApplication) {
        let confirm = app.buttons["onboarding.confirm"]
        let card = app.buttons["onboarding.program.\(choice)"]
        if !app.launchArguments.contains("-ui-large-text") { XCTAssertTrue(card.waitForExistence(timeout: 15)) }
        revealCard(card, in: app); tapCard(card, in: app)
        XCTAssertTrue(card.isSelected)
        let goalButton = app.buttons["onboarding.goal.\(goal)"]
        app.revealWorkoutControl(goalButton, pinnedFooter: app.launchArguments.contains("-ui-large-text") ? nil : confirm, scrollDistance: app.launchArguments.contains("-ui-large-text") ? 300 : 100); goalButton.tap()
        XCTAssertTrue(goalButton.isSelected)
        if revealConfirmation && app.launchArguments.contains("-ui-large-text") { app.revealWorkoutControl(confirm, scrollDistance: 300) }
        if revealConfirmation || !app.launchArguments.contains("-ui-large-text") { XCTAssertTrue(confirm.isEnabled) }
    }
    @MainActor private func openSettings(_ app: XCUIApplication) {
        app.selectNativeTab("Settings", identifier: "tab.settings")
        if !app.navigationBars["Program"].exists { app.buttons["settings.program"].tap() }
        for _ in 0..<8 where !app.staticTexts["settings.current-program"].isHittable { app.swipeDown() }
        app.revealWorkoutControl(app.staticTexts["settings.current-program"])
        XCTAssertTrue(app.staticTexts["settings.current-program"].exists)
    }
    @MainActor private func applyProgramChange(_ expectedTitle: String, in app: XCUIApplication) {
        app.buttons["settings.program-apply"].firstMatch.tap()
        let title = app.staticTexts["settings.current-program"]
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expectedTitle), object: title)
        let result = XCTWaiter.wait(for: [changed], timeout: 30)
        if result != .completed { capture(app, "Program change did not reach expected saved title") }
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(title.label, expectedTitle)
    }
    @MainActor func testSelectionRequiresEmphasisAndGoal() {
        let app = launch()
        XCTAssertFalse(app.buttons["onboarding.confirm"].isEnabled)
        capture(app, "Initial emphasis card accessibility")
        let glutes = app.buttons["onboarding.program.whole_body_glutes"]
        XCTAssertTrue(glutes.waitForExistence(timeout: 5))
        app.revealWorkoutControl(glutes, pinnedFooter: app.buttons["onboarding.confirm"], scrollDistance: 100); glutes.tap()
        XCTAssertFalse(app.buttons["onboarding.confirm"].isEnabled)
        app.revealWorkoutControl(app.buttons["onboarding.goal.size"], pinnedFooter: app.buttons["onboarding.confirm"], scrollDistance: 100)
        app.buttons["onboarding.goal.size"].tap()
        XCTAssertTrue(app.buttons["onboarding.confirm"].isEnabled)
        XCTAssertTrue(app.buttons["onboarding.program.upper_body"].exists)
        XCTAssertTrue(glutes.isSelected)
        XCTAssertEqual(glutes.descendants(matching: .button).count, 0, "Each card is one accessible button")
        capture(app, "Explicit independent emphasis and goal")
    }
    @MainActor func testEitherEmphasisCanPairWithEveryGoal() {
        for emphasis in ["upper_body", "whole_body_glutes"] {
            for goal in ["fat_loss", "size", "strength", "maintenance"] {
                let app = launch()
                XCTAssertTrue(app.buttons["onboarding.program.\(emphasis)"].waitForExistence(timeout: 15))
                XCTAssertFalse(app.buttons["onboarding.program.\(emphasis)"].isSelected)
                choice(emphasis, goal: goal, in: app)
                app.buttons["onboarding.confirm"].tap()
                XCTAssertTrue(app.staticTexts["today.schedule"].waitForExistence(timeout: 15))
                openSettings(app)
                XCTAssertEqual(app.staticTexts["settings.current-program"].label, emphasis == "upper_body" ? "Upper-body emphasis" : "Whole-body, glute emphasis")
                XCTAssertEqual(app.staticTexts["settings.current-goal"].label, ["fat_loss": "Fat loss", "size": "Size", "strength": "Strength", "maintenance": "Maintenance"][goal])
                app.terminate()
            }
        }
    }
    @MainActor func testProgramPreviewAndCardsAtLargestTextLightDarkAndReduceMotion() {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        let toggle = settings.switches["Reduce Motion"].firstMatch
        if !toggle.exists {
            let accessibility = settings.staticTexts["Accessibility"].firstMatch
            for _ in 0..<6 where !accessibility.exists && settings.navigationBars.buttons.firstMatch.exists {
                settings.navigationBars.buttons.firstMatch.tap()
            }
            for _ in 0..<5 where !accessibility.isHittable { settings.swipeUp() }
            XCTAssertTrue(accessibility.waitForExistence(timeout: 10)); accessibility.tap()
            settings.staticTexts["Motion"].firstMatch.tap()
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        let original = toggle.value as? String
        defer {
            settings.activate()
            if toggle.value as? String != original { toggle.tap() }
            XCTAssertEqual(toggle.value as? String, original)
            if settings.navigationBars.buttons["Accessibility"].exists { settings.navigationBars.buttons["Accessibility"].tap() }
            if settings.navigationBars.buttons["Settings"].exists { settings.navigationBars.buttons["Settings"].tap() }
            settings.terminate()
        }
        if original == "0" { toggle.tap() }
        XCTAssertEqual(toggle.value as? String, "1")
        for extras in [[], ["-ui-dark", "-ui-large-text"]] {
            let app = launch(extras)
            for emphasis in ["upper_body", "whole_body_glutes"] {
                let card = app.buttons["onboarding.program.\(emphasis)"]
                revealCard(card, in: app)
                XCTAssertGreaterThanOrEqual(card.frame.height, 44)
                XCTAssertTrue(card.label.contains(emphasis == "upper_body" ? "Upper-body emphasis" : "Whole-body, glute emphasis"))
                capture(app, "\(emphasis) \(extras.isEmpty ? "light" : "dark accessibility5") Reduce Motion unselected")
                tapCard(card, in: app); XCTAssertTrue(card.isSelected)
                capture(app, "\(emphasis) \(extras.isEmpty ? "light" : "dark accessibility5") Reduce Motion selected")
            }
            choice("whole_body_glutes", revealConfirmation: false, in: app)
            let preview = app.buttons["onboarding.preview"]
            app.revealWorkoutControl(preview, pinnedFooter: extras.isEmpty ? app.buttons["onboarding.confirm"] : nil, scrollDistance: extras.isEmpty ? 100 : 300); preview.tap()
            app.revealWorkoutControl(app.staticTexts["program.preview.duration"], scrollDistance: 200)
            XCTAssertTrue(app.staticTexts["program.preview.duration"].exists)
            XCTAssertEqual(app.staticTexts["program.preview.duration"].label, "Allow about 45–65 minutes; your time may vary.")
            capture(app, "Glute preview \(extras.isEmpty ? "light" : "dark accessibility5")")
            app.terminate()
        }
    }
    @MainActor func testRestoreKeepsItsStoredProgramWithoutNewSelection() {
        let app = launch(); choice("whole_body_glutes", goal: "maintenance", in: app); app.buttons["onboarding.confirm"].tap()
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 15))
        app.terminate(); app.launchArguments = ["-ui-testing", "-cloud-disabled"]; app.launch()
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["onboarding.confirm"].exists)
        openSettings(app)
        XCTAssertEqual(app.staticTexts["settings.current-program"].label, "Whole-body, glute emphasis")
        XCTAssertEqual(app.staticTexts["settings.current-goal"].label, "Maintenance")
    }
    @MainActor func testSwitchCancelAndDraftLockPreserveProgram() {
        let app = launch(); choice("upper_body", in: app); app.buttons["onboarding.confirm"].tap()
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 15)); openSettings(app)
        app.buttons["settings.change-program"].tap()
        app.buttons["settings.program.whole_body_glutes"].tap()
        app.buttons["settings.program-cancel"].tap()
        XCTAssertEqual(app.staticTexts["settings.current-program"].label, "Upper-body emphasis")
        app.buttons["settings.change-program"].tap()
        app.buttons["settings.program.whole_body_glutes"].tap(); app.tapWorkoutControl("settings.program-goal.size")
        app.tapWorkoutControl("settings.program-confirm"); applyProgramChange("Whole-body, glute emphasis", in: app)
        XCTAssertTrue(app.staticTexts["settings.current-program"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["settings.current-program"].label, "Whole-body, glute emphasis")
        app.selectNativeTab("Today", identifier: "tab.today"); app.buttons["today.start"].tap()
        XCTAssertTrue(app.buttons["workout.close"].waitForExistence(timeout: 15)); app.buttons["workout.close"].tap(); openSettings(app)
        let lock = app.staticTexts["settings.draft-lock"]
        for _ in 0..<8 where !lock.isHittable { app.swipeDown() }
        app.revealWorkoutControl(lock)
        XCTAssertTrue(lock.exists)
        capture(app, "Saved draft explains protected program changes")
        let change = app.buttons["settings.change-program"]
        app.revealWorkoutControl(change, scrollDistance: 100)
        XCTAssertFalse(change.isEnabled)
        capture(app, "Saved draft protects change program")
    }
    @MainActor func testPerSideEntryAndStopsWorkAtLargestTextWithKeyboard() {
        let app = launch(["-ui-dark", "-ui-large-text"])
        choice("whole_body_glutes", in: app); app.buttons["onboarding.confirm"].tap()
        XCTAssertTrue(app.staticTexts["today.schedule"].waitForExistence(timeout: 15)); app.tapWorkoutControl("today.start")
        app.tapWorkoutControl("load.choose.5")
        let left = app.textFields["set.left-reps"]
        app.revealWorkoutControl(left); left.tap(); left.typeText("8")
        app.revealWorkoutControl(left)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertTrue(left.isHittable)
        XCTAssertTrue(app.buttons["problem.pain"].isHittable)
        XCTAssertTrue(app.buttons["problem.control_lost"].isHittable)
        capture(app, "Largest per-side missing right with keyboard and reachable stops")
        app.buttons["keyboard.done"].tap(); app.tapWorkoutControl("set.save")
        XCTAssertEqual(app.staticTexts["set.actual.0"].label, "Set 1: left 8, right unrecorded")
        app.enterPerformedReps("8", field: "set.left-reps"); app.enterPerformedReps("7", field: "set.right-reps")
        app.tapWorkoutControl("reason.effort_limit"); app.tapWorkoutControl("set.save")
        XCTAssertEqual(app.staticTexts["set.actual.1"].label, "Set 2: left 8, right 7")
        app.revealWorkoutControl(app.staticTexts["set.actual.1"])
        capture(app, "Largest per-side raw unequal and missing actuals")
        app.tapWorkoutControl("movement.partial-action")
        XCTAssertFalse(app.buttons["movement.setup"].exists)
    }
    @MainActor func testBridgeAndStrengthChecksCreateOnlyTypedReviewedSetup() {
        let app = launch(); choice("whole_body_glutes", in: app); app.buttons["onboarding.confirm"].tap()
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 15)); openSettings(app)
        app.revealWorkoutControl(app.staticTexts["settings.movement.db_floor_glute_bridge"])
        app.staticTexts["settings.movement.db_floor_glute_bridge"].tap()
        app.tapWorkoutControl("settings.setup.db_floor_glute_bridge")
        XCTAssertTrue(app.buttons["setup.bridge.dumbbell"].exists)
        app.buttons["setup.bridge.bodyweight"].tap()
        XCTAssertTrue(app.buttons["settings.setup.db_floor_glute_bridge"].waitForExistence(timeout: 15))
        app.tapWorkoutControl("settings.setup.db_floor_glute_bridge")
        let modifications = app.textFields["setup.modifications"]
        app.revealWorkoutControl(modifications); modifications.tap(); modifications.typeText(" with future dumbbell notes")
        app.buttons["setup.keyboard-done"].tap()
        app.tapWorkoutControl("setup.new")
        XCTAssertTrue(app.buttons["settings.setup.db_floor_glute_bridge"].waitForExistence(timeout: 15))
        app.selectNativeTab("Today", identifier: "tab.today"); app.buttons["today.start"].tap()
        app.tapWorkoutControl("movement.skip"); app.tapWorkoutControl("movement.next")
        XCTAssertTrue(app.staticTexts["movement.modifications"].label.contains("future dumbbell notes"))
        XCTAssertFalse(app.buttons["load.choose.5"].exists)
        app.enterPerformedReps("10"); app.tapWorkoutControl("set.save")
        capture(app, "Bodyweight bridge modification retains null load and no numeric catalog")
        app.tapWorkoutControl("movement.partial-action"); app.tapWorkoutControl("movement.next")
        for _ in 0..<4 { app.tapWorkoutControl("movement.skip"); app.tapWorkoutControl("movement.next") }
        app.tapWorkoutControl("workout.finish")
        XCTAssertTrue(app.staticTexts["workout.saved"].waitForExistence(timeout: 15))
        capture(app, "Bodyweight bridge completion frozen loading metadata")
        app.revealWorkoutControl(app.buttons["Back to Today"]); app.buttons["Back to Today"].tap(); openSettings(app)
        app.buttons["settings.change-program"].tap(); app.buttons["settings.program.upper_body"].tap(); app.tapWorkoutControl("settings.program-goal.size")
        app.tapWorkoutControl("settings.program-confirm"); applyProgramChange("Upper-body emphasis", in: app)
        app.selectNativeTab("History", identifier: "tab.history"); app.buttons["history.first-workout"].tap()
        let bodyweightLabel = app.staticTexts["Actual load: bodyweight — no numeric load recorded"]
        app.revealWorkoutControl(bodyweightLabel)
        XCTAssertTrue(bodyweightLabel.exists)
        if bodyweightLabel.frame.maxY > app.buttons["tab.history"].frame.minY - 16 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
                .press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)), withVelocity: .slow, thenHoldForDuration: 0.5)
        }
        XCTAssertLessThanOrEqual(bodyweightLabel.frame.maxY, app.buttons["tab.history"].frame.minY - 16)
        capture(app, "Bodyweight bridge history after upper program switch")

        app.terminate()
        let strength = launch(); choice("whole_body_glutes", goal: "strength", in: strength); strength.buttons["onboarding.confirm"].tap()
        XCTAssertTrue(strength.buttons["today.start"].waitForExistence(timeout: 15)); openSettings(strength)
        let rowID = "chest_supported_db_row_30_neutral"
        strength.revealWorkoutControl(strength.staticTexts["settings.movement.\(rowID)"])
        strength.staticTexts["settings.movement.\(rowID)"].tap()
        strength.tapWorkoutControl("settings.setup.\(rowID)"); strength.buttons["setup.handling.standard"].tap()
        XCTAssertTrue(strength.buttons["settings.setup.\(rowID)"].waitForExistence(timeout: 15))
        strength.tapWorkoutControl("settings.setup.\(rowID)")
        strength.buttons["setup.handling-load"].tap(); strength.buttons["15 lb per hand"].tap()
        capture(strength, "Explicit first-load strength handling review")
        strength.buttons["setup.handling.low-rep"].tap()
        XCTAssertTrue(strength.buttons["settings.setup.\(rowID)"].waitForExistence(timeout: 15))
        strength.selectNativeTab("Today", identifier: "tab.today"); strength.buttons["today.start"].tap()
        for _ in 0..<2 { strength.tapWorkoutControl("movement.skip"); strength.tapWorkoutControl("movement.next") }
        XCTAssertEqual(strength.staticTexts["movement.goal-reps"].label, "4 / 4 reps")
        strength.tapWorkoutControl("load.choose.20")
        XCTAssertTrue(strength.staticTexts["save.error"].label.contains("not been reviewed"))
        strength.tapWorkoutControl("load.confirm-prescribed")
        capture(strength, "Reviewed load controls low-rep entry")
    }
    @MainActor func testIntroCompletionAndHistoryRemainPinnedAfterProgramChange() {
        let app = launch(["-fixture-starter-intro"])
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 15)); app.buttons["today.start"].tap()
        XCTAssertEqual(app.staticTexts["movement.goal-reps"].label, "9 / 8 reps")
        app.tapWorkoutControl("load.confirm-prescribed")
        for reps in ["9", "8"] { app.enterPerformedReps(reps); app.tapWorkoutControl("set.save") }
        app.tapWorkoutControl("movement.complete"); app.tapWorkoutControl("effort.on_target"); app.tapWorkoutControl("movement.next")
        for _ in 0..<5 { app.tapWorkoutControl("movement.skip"); app.tapWorkoutControl("movement.next") }
        app.tapWorkoutControl("workout.finish")
        XCTAssertTrue(app.staticTexts["workout.saved"].waitForExistence(timeout: 15))
        app.revealWorkoutControl(app.staticTexts["workout.completed-set-growth"])
        capture(app, "Intro actual two sets and saved next three-set baseline")
        app.revealWorkoutControl(app.buttons["Back to Today"]); app.buttons["Back to Today"].tap(); openSettings(app)
        app.buttons["settings.change-program"].tap(); app.buttons["settings.program.upper_body"].tap(); app.tapWorkoutControl("settings.program-goal.size")
        app.tapWorkoutControl("settings.program-confirm"); applyProgramChange("Upper-body emphasis", in: app)
        XCTAssertEqual(app.staticTexts["settings.current-program"].label, "Upper-body emphasis")
        app.selectNativeTab("History", identifier: "tab.history"); app.buttons["history.first-workout"].tap()
        XCTAssertEqual(app.staticTexts["history.actual-reps"].label, "9 / 8 reps")
        app.revealWorkoutControl(app.staticTexts["history.retained-goal"])
        XCTAssertEqual(app.staticTexts["history.retained-goal"].label, "Retained normal goals when saved: 9 / 8 / 7 reps")
        capture(app, "Frozen glute two-set actuals and three-set saved baseline after upper switch")
    }
}
