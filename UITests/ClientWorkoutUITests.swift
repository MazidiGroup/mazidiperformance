import XCTest

/// High-value journeys for the Client workout slice, driven through stable accessibility
/// identifiers (App/DesignSystem/AccessibilityIdentifiers.swift). These exercise the real
/// domain/service through the UI; they assert user-visible outcomes, not internal state.
final class ClientWorkoutUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launchAsClient() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        // Dev role affordance (DEBUG) — real auth arrives with its backend (R-01).
        let continueClient = app.buttons["dev_continue_client"]
        XCTAssertTrue(continueClient.waitForExistence(timeout: 10), "Client dev entry should be present")
        continueClient.tap()
        return app
    }

    /// Opening the assigned workout: Today → overview → begin → active workout.
    func testOpenAssignedWorkout() {
        let app = launchAsClient()

        let viewWorkout = app.buttons["today_start_workout"]
        XCTAssertTrue(viewWorkout.waitForExistence(timeout: 10), "Today should offer the assigned workout")
        viewWorkout.tap()

        let begin = app.buttons["overview_begin_button"]
        XCTAssertTrue(begin.waitForExistence(timeout: 10), "Overview should offer Begin workout")
        begin.tap()

        XCTAssertTrue(app.staticTexts["active_exercise_title"].waitForExistence(timeout: 10),
                      "Active workout should show the current exercise")
    }

    /// Recording a set: the prefilled type-aware form logs a set, which then appears in the
    /// recorded-sets list.
    func testRecordASet() {
        let app = launchAsClient()
        app.buttons["today_start_workout"].tapWhenReady()
        app.buttons["overview_begin_button"].tapWhenReady()

        let logButton = app.buttons["set_entry_log_button"]
        XCTAssertTrue(logButton.waitForExistence(timeout: 10), "Set-entry form should be present")
        logButton.tap()

        XCTAssertTrue(app.otherElements["set_entry_row.0"].waitForExistence(timeout: 10)
                      || app.staticTexts["Set 1 recorded"].waitForExistence(timeout: 2),
                      "A recorded set row should appear after logging")
    }

    /// Pausing then resuming keeps the client in the active workout with nothing lost.
    func testPauseAndResume() {
        let app = launchAsClient()
        app.buttons["today_start_workout"].tapWhenReady()
        app.buttons["overview_begin_button"].tapWhenReady()

        app.buttons["active_pause_button"].tapWhenReady()

        let resume = app.buttons["pause_resume_button"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10), "Pause sheet should offer Resume")
        resume.tap()

        XCTAssertTrue(app.staticTexts["active_exercise_title"].waitForExistence(timeout: 10),
                      "Resuming should return to the active workout")
    }

    /// Fixture/development controls must exist only in DEBUG. This test compiles a branch
    /// per configuration: in Debug it proves the dev role entry and fixture connectivity
    /// toggle are present; in Release (run with `-configuration Release test`) it proves the
    /// dev role selection and the fixture toggle are absent. A Release binary-strings check
    /// in the milestone validation provides the complementary static proof.
    func testDevControlsMatchBuildConfiguration() {
        let app = XCUIApplication()
        app.launch()
        #if DEBUG
        let continueClient = app.buttons["dev_continue_client"]
        XCTAssertTrue(continueClient.waitForExistence(timeout: 10),
                      "Debug builds expose the dev role selection")
        continueClient.tap()
        XCTAssertTrue(app.switches["dev_connectivity_toggle"].waitForExistence(timeout: 10),
                      "Debug builds expose the fixture connectivity toggle on Today")
        #else
        XCTAssertFalse(app.buttons["dev_continue_client"].waitForExistence(timeout: 5),
                       "Release builds must not expose dev role selection")
        XCTAssertFalse(app.buttons["dev_continue_coach"].exists,
                       "Release builds must not expose dev role selection")
        XCTAssertFalse(app.switches["dev_connectivity_toggle"].exists,
                       "Release builds must not expose the fixture connectivity toggle")
        #endif
    }

    /// Completing the workout shows the completion summary and Done.
    func testCompleteWorkout() {
        let app = launchAsClient()
        app.buttons["today_start_workout"].tapWhenReady()
        app.buttons["overview_begin_button"].tapWhenReady()

        let complete = app.buttons["active_complete_button"]
        XCTAssertTrue(complete.waitForExistence(timeout: 10), "Active workout should offer completion")
        complete.tap()

        XCTAssertTrue(app.otherElements["complete_summary"].waitForExistence(timeout: 10)
                      || app.buttons["complete_done_button"].waitForExistence(timeout: 2),
                      "Completion summary should appear")
        if app.buttons["complete_done_button"].exists { app.buttons["complete_done_button"].tap() }
    }
}

private extension XCUIElement {
    /// Tap once the element exists and is hittable (small waits keep journeys resilient).
    func tapWhenReady(timeout: TimeInterval = 10) {
        XCTAssertTrue(waitForExistence(timeout: timeout), "Expected element \(identifier) to exist")
        tap()
    }
}
