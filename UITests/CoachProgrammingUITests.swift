import XCTest

/// Coach→Client programming journeys (ADR-0009), driven through the DEBUG development
/// provider and the DEBUG assignment relay (the documented backend stand-in). Each test
/// uses a unique durable store base directory, so accounts, relaunches and journeys are
/// fully isolated. All waits are condition-based.
final class CoachProgrammingUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    private func launch(base: String, resetAuth: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MAZIDI_STORE_DIR"] = base
        if resetAuth { app.launchEnvironment["MAZIDI_AUTH_RESET"] = "1" }
        app.launch()
        return app
    }

    @MainActor
    private func signIn(_ app: XCUIApplication, via buttonID: String, expecting expectedID: String) {
        let entry = app.buttons[buttonID]
        XCTAssertTrue(entry.waitForExistence(timeout: 20), "\(buttonID) should exist")
        let expected = app.descendants(matching: .any)[expectedID].firstMatch
        for _ in 0..<3 where !expected.exists {
            entry.tap()
            if expected.waitForExistence(timeout: 8) { break }
        }
        XCTAssertTrue(expected.waitForExistence(timeout: 8),
                      "\(expectedID) should appear after signing in via \(buttonID)")
    }

    /// Coach signs out from wherever the coach shell currently is.
    @MainActor
    private func coachSignOut(_ app: XCUIApplication) {
        app.buttons["coach_sign_out"].tapWhenReady()
        XCTAssertTrue(app.buttons["dev_continue_client"].waitForExistence(timeout: 20),
                      "Sign-out should return to the signed-out surface")
    }

    /// Create → title → add exercise → publish → assign to dev-client-001 → back to list.
    ///
    /// The new-workout alert needs care on iOS 18/26 simulators: the system exposes the
    /// alert action twice in the accessibility tree, so every alert element goes through
    /// `firstMatch`, and opening the alert is retried (a cold shell can swallow the
    /// first toolbar tap).
    @MainActor
    private func coachCreatesPublishesAndAssigns(_ app: XCUIApplication, title: String) {
        let alert = app.alerts.firstMatch
        let createButton = app.buttons["coach_create_workout"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 15), "Create control should exist")
        for _ in 0..<3 where !alert.exists {
            createButton.tap()
            if alert.waitForExistence(timeout: 6) { break }
        }
        XCTAssertTrue(alert.waitForExistence(timeout: 6), "New-workout alert should appear")
        let titleField = alert.textFields.firstMatch
        XCTAssertTrue(titleField.waitForExistence(timeout: 10), "New-workout title field should appear")
        titleField.tap()
        titleField.typeText(title)
        let confirm = alert.buttons["Create"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "Create action should exist")
        confirm.tap()

        app.buttons["editor_add_exercise"].tapWhenReady()
        // Catalogue-backed picker: search narrows the 206-exercise catalogue so the
        // canonical option becomes hittable, then select it by stable slug identifier.
        let search = app.textFields["coach_exercise_search"]
        XCTAssertTrue(search.waitForExistence(timeout: 15), "Catalogue search field should appear")
        search.tap()
        search.typeText("barbell squat")
        app.buttons["exercise_option.barbell-squat"].tapWhenReady()
        XCTAssertTrue(app.buttons["editor_exercise_row.barbell-squat"].waitForExistence(timeout: 10),
                      "The exercise should join the draft")

        app.buttons["editor_publish"].tapWhenReady()
        XCTAssertTrue(app.buttons["editor_assign"].waitForExistence(timeout: 10),
                      "Publishing should enable assignment")
        app.buttons["editor_assign"].tapWhenReady()
        app.buttons["assign_client.dev-client-001"].tapWhenReady()

        // Back to the workout list, where statuses and the sign-out control live.
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 10), "Back control should exist")
        back.tap()
        XCTAssertTrue(app.buttons["coach_create_workout"].waitForExistence(timeout: 10),
                      "Should return to the workout list")
    }

    /// The complete workflow: coach authors, publishes, assigns; the client sees it,
    /// executes it through the existing session flow; the coach sees the completion.
    @MainActor
    func testCoachToClientAssignmentJourney() {
        let base = NSTemporaryDirectory() + "mazidi-coach-e2e-\(UUID().uuidString)"

        // Coach: create, publish, assign.
        let app = launch(base: base, resetAuth: true)
        signIn(app, via: "dev_continue_coach", expecting: "coach_create_workout")
        coachCreatesPublishesAndAssigns(app, title: "Slice Lower")
        // The queued state is honest — never presented as delivered.
        XCTAssertTrue(
            app.descendants(matching: .any)["coach_assignment_status.dev-client-001.queued"]
                .firstMatch.waitForExistence(timeout: 15),
            "The assignment should show as queued (not delivered) on the coach list"
        )
        coachSignOut(app)

        // Client: the assignment appears on Today and starts through the normal flow.
        signIn(app, via: "dev_continue_client", expecting: "today_assigned_badge")
        app.buttons["today_start_workout"].tapWhenReady()
        XCTAssertTrue(app.staticTexts["Slice Lower"].firstMatch.waitForExistence(timeout: 10),
                      "The overview should show the coach's workout title")
        app.buttons["overview_begin_button"].tapWhenReady()
        XCTAssertTrue(app.staticTexts["active_exercise_title"].waitForExistence(timeout: 15),
                      "The assignment should start through the existing session flow")
        // Record one set, then finish early — completion linkage is what's under test.
        app.buttons["set_entry_log_button"].tapWhenReady()
        XCTAssertTrue(app.otherElements["set_entry_row.0"].waitForExistence(timeout: 15),
                      "The set should record against the assignment's session")
        app.buttons["rest_timer_skip_button"].tapWhenReady()
        app.buttons["active_complete_button"].tapWhenReady()
        app.buttons["complete_done_button"].tapWhenReady()
        app.buttons["client_sign_out"].tapWhenReady()
        XCTAssertTrue(app.buttons["dev_continue_coach"].waitForExistence(timeout: 20))

        // Coach: the assignment now shows completed (real client-recorded fact pulled
        // by the dev relay).
        signIn(app, via: "dev_continue_coach", expecting: "coach_create_workout")
        XCTAssertTrue(
            app.descendants(matching: .any)["coach_assignment_status.dev-client-001.completed"].firstMatch
                .waitForExistence(timeout: 15),
            "The coach should see the completed status"
        )
    }

    /// Drafts and assignments are durable: both survive termination and session
    /// restoration on relaunch.
    @MainActor
    func testRelaunchPreservesDraftAndAssignment() {
        let base = NSTemporaryDirectory() + "mazidi-coach-relaunch-\(UUID().uuidString)"

        let app = launch(base: base, resetAuth: true)
        signIn(app, via: "dev_continue_coach", expecting: "coach_create_workout")
        coachCreatesPublishesAndAssigns(app, title: "Durable Plan")
        app.terminate()

        // Relaunch: the coach session restores; the published workout and its queued
        // assignment are still there.
        let relaunched = launch(base: base, resetAuth: false)
        XCTAssertTrue(relaunched.buttons["coach_create_workout"].waitForExistence(timeout: 20),
                      "The coach session should restore on relaunch")
        XCTAssertTrue(
            relaunched.descendants(matching: .any)["coach_workout_row.Durable Plan"].firstMatch
                .waitForExistence(timeout: 15),
            "The draft/published workout should survive relaunch"
        )
        XCTAssertTrue(
            relaunched.descendants(matching: .any)["coach_assignment_status.dev-client-001.queued"].firstMatch
                .waitForExistence(timeout: 15),
            "The queued assignment should survive relaunch"
        )
        coachSignOut(relaunched)

        // Client relaunch: the delivered assignment also survives on the client side.
        signIn(relaunched, via: "dev_continue_client", expecting: "today_assigned_badge")
        relaunched.terminate()
        let clientRelaunch = launch(base: base, resetAuth: false)
        XCTAssertTrue(
            clientRelaunch.descendants(matching: .any)["today_assigned_badge"].firstMatch
                .waitForExistence(timeout: 20),
            "The assignment should survive the client's relaunch"
        )
    }

    /// Account boundaries: an assignment addressed to client-001 must never appear for
    /// client-002.
    @MainActor
    func testAssignmentIsNotVisibleToAnotherClientAccount() {
        let base = NSTemporaryDirectory() + "mazidi-coach-isolation-\(UUID().uuidString)"

        let app = launch(base: base, resetAuth: true)
        signIn(app, via: "dev_continue_coach", expecting: "coach_create_workout")
        coachCreatesPublishesAndAssigns(app, title: "Only For One")
        coachSignOut(app)

        // The other client sees the plain fixture Today — no coach assignment badge.
        signIn(app, via: "dev_continue_client_2", expecting: "today_start_workout")
        XCTAssertFalse(app.descendants(matching: .any)["today_assigned_badge"].firstMatch.exists,
                       "Client 2 must not see an assignment addressed to client 1")
    }
}

private extension XCUIElement {
    @MainActor
    func tapWhenReady(timeout: TimeInterval = 15) {
        let ready = NSPredicate(format: "exists == true AND isHittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: ready, object: self)
        let outcome = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(outcome, .completed, "Expected element \(identifier) to be hittable")
        tap()
    }
}
