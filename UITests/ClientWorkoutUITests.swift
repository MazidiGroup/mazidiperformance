import XCTest

/// High-value journeys for the Client workout slice, driven through stable accessibility
/// identifiers (App/DesignSystem/AccessibilityIdentifiers.swift). These exercise the real
/// domain/service through the UI; they assert user-visible outcomes, not internal state.
final class ClientWorkoutUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    private func launchAsClient() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        // Dev role affordance (DEBUG) — real auth arrives with its backend (R-01).
        let devEntry = app.buttons["dev_continue_client"]
        XCTAssertTrue(devEntry.waitForExistence(timeout: 20), "Client dev entry should appear")
        // The very first cold-launch tap can land after the control is hittable but before
        // SwiftUI has wired its action, so it is silently dropped and the role never
        // switches. Retry until Today actually appears — a bounded condition wait, not a
        // fixed delay — and assert the role switch happened.
        let todayEntry = app.buttons["today_start_workout"]
        for _ in 0..<3 where !todayEntry.exists {
            devEntry.tap()
            if todayEntry.waitForExistence(timeout: 8) { break }
        }
        XCTAssertTrue(todayEntry.waitForExistence(timeout: 8),
                      "Client Today should appear after selecting the dev client role")
        return app
    }

    /// Opening the assigned workout: Today → overview → begin → active workout.
    @MainActor
    func testOpenAssignedWorkout() {
        let app = launchAsClient()

        app.buttons["today_start_workout"].tapWhenReady()   // Today → overview
        app.buttons["overview_begin_button"].tapWhenReady() // overview → active

        XCTAssertTrue(app.staticTexts["active_exercise_title"].waitForExistence(timeout: 15),
                      "Active workout should show the current exercise")
    }

    /// Recording a set: the prefilled type-aware form logs a set, which then appears in the
    /// recorded-sets list.
    @MainActor
    func testRecordASet() {
        let app = launchAsClient()
        app.buttons["today_start_workout"].tapWhenReady()
        app.buttons["overview_begin_button"].tapWhenReady()

        let logButton = app.buttons["set_entry_log_button"]
        XCTAssertTrue(logButton.waitForExistence(timeout: 15), "Set-entry form should be present")
        logButton.tapWhenReady()

        XCTAssertTrue(app.otherElements["set_entry_row.0"].waitForExistence(timeout: 10)
                      || app.staticTexts["Set 1 recorded"].waitForExistence(timeout: 2),
                      "A recorded set row should appear after logging")
    }

    /// Pausing then resuming keeps the client in the active workout with nothing lost.
    @MainActor
    func testPauseAndResume() {
        let app = launchAsClient()
        app.buttons["today_start_workout"].tapWhenReady()
        app.buttons["overview_begin_button"].tapWhenReady()

        app.buttons["active_pause_button"].tapWhenReady()

        let resume = app.buttons["pause_resume_button"]
        XCTAssertTrue(resume.waitForExistence(timeout: 15), "Pause sheet should offer Resume")
        resume.tapWhenReady()

        XCTAssertTrue(app.staticTexts["active_exercise_title"].waitForExistence(timeout: 15),
                      "Resuming should return to the active workout")
    }

    /// Fixture/development controls must exist only in DEBUG. This test compiles a branch
    /// per configuration: in Debug it proves the dev role entry and fixture connectivity
    /// toggle are present; in Release (run with `-configuration Release test`) it proves the
    /// dev role selection and the fixture toggle are absent. A Release binary-strings check
    /// in the milestone validation provides the complementary static proof.
    @MainActor
    func testDevControlsMatchBuildConfiguration() {
        #if DEBUG
        // Debug exposes the dev role entry (via launchAsClient) and the fixture toggle.
        let app = launchAsClient()
        XCTAssertTrue(app.switches["dev_connectivity_toggle"].waitForExistence(timeout: 15),
                      "Debug builds expose the fixture connectivity toggle on Today")
        #else
        let app = XCUIApplication()
        app.launch()
        XCTAssertFalse(app.buttons["dev_continue_client"].waitForExistence(timeout: 5),
                       "Release builds must not expose dev role selection")
        XCTAssertFalse(app.buttons["dev_continue_coach"].exists,
                       "Release builds must not expose dev role selection")
        XCTAssertFalse(app.switches["dev_connectivity_toggle"].exists,
                       "Release builds must not expose the fixture connectivity toggle")
        #endif
    }

    /// Completing the workout shows the completion summary and Done.
    @MainActor
    func testCompleteWorkout() {
        let app = launchAsClient()
        app.buttons["today_start_workout"].tapWhenReady()
        app.buttons["overview_begin_button"].tapWhenReady()

        let complete = app.buttons["active_complete_button"]
        XCTAssertTrue(complete.waitForExistence(timeout: 15), "Active workout should offer completion")
        complete.tapWhenReady()

        XCTAssertTrue(app.otherElements["complete_summary"].waitForExistence(timeout: 15)
                      || app.buttons["complete_done_button"].waitForExistence(timeout: 2),
                      "Completion summary should appear")
        if app.buttons["complete_done_button"].exists { app.buttons["complete_done_button"].tapWhenReady() }
    }
}

private extension XCUIElement {
    /// Tap once the element is present AND hittable. Waiting for hittability (not just
    /// existence) synchronises against navigation-push and sheet-present animations — a
    /// tap issued mid-transition is silently dropped, which is the main source of flakiness
    /// on slower CI simulators. This is a real wait condition, not a fixed delay, and it
    /// still asserts the element became actionable.
    @MainActor
    func tapWhenReady(timeout: TimeInterval = 15) {
        let ready = NSPredicate(format: "exists == true AND isHittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: ready, object: self)
        let outcome = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(outcome, .completed, "Expected element \(identifier) to be hittable")
        tap()
    }
}
