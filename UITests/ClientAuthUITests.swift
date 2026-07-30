import XCTest

/// Authentication, role-routing, and account-boundary journeys (ADR-0008), driven
/// through the DEBUG development provider under explicit UI-test configuration. All
/// waits are condition-based (existence/hittability predicates) — no fixed sleeps.
final class ClientAuthUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Fresh signed-out launch: ephemeral store + auth reset (the simulator Keychain
    /// outlives launches, so tests always state their starting condition explicitly).
    @MainActor
    private func launchSignedOut(extraEnvironment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MAZIDI_STORE_MODE"] = "ephemeral"
        app.launchEnvironment["MAZIDI_AUTH_RESET"] = "1"
        app.launchEnvironment.merge(extraEnvironment) { _, new in new }
        app.launch()
        XCTAssertTrue(app.buttons["dev_continue_client"].waitForExistence(timeout: 20),
                      "Fresh launch should show the signed-out surface")
        return app
    }

    /// Sign in via a dev identity button, retrying the first cold-launch tap (an early
    /// tap can land before SwiftUI wires the action) until `expectedID` appears.
    @MainActor
    private func signIn(_ app: XCUIApplication, via buttonID: String, expecting expectedID: String) {
        let entry = app.buttons[buttonID]
        XCTAssertTrue(entry.waitForExistence(timeout: 20), "\(buttonID) should exist")
        let expected = app.descendants(matching: .any)[expectedID]
        for _ in 0..<3 where !expected.exists {
            entry.tap()
            if expected.waitForExistence(timeout: 8) { break }
        }
        XCTAssertTrue(expected.waitForExistence(timeout: 8),
                      "\(expectedID) should appear after signing in via \(buttonID)")
    }

    /// Development Client sign-in reaches the Client shell; sign-out returns to the
    /// signed-out surface with no client content remaining.
    @MainActor
    func testClientSignInAndSignOut() {
        let app = launchSignedOut()
        signIn(app, via: "dev_continue_client", expecting: "today_start_workout")

        app.buttons["client_sign_out"].tapWhenReady()
        XCTAssertTrue(app.buttons["dev_continue_client"].waitForExistence(timeout: 20),
                      "Sign-out should return to the signed-out surface")
        XCTAssertFalse(app.buttons["today_start_workout"].exists,
                       "No client content may remain visible after sign-out")
    }

    /// Development Coach sign-in routes to the Coach shell (never the Client shell),
    /// shows the coach identity, and signs out cleanly.
    @MainActor
    func testCoachSignInRoutesToCoachShellOnly() {
        let app = launchSignedOut()
        signIn(app, via: "dev_continue_coach", expecting: "coach_account_label")

        XCTAssertTrue(app.staticTexts["coach_account_label"].label.contains("dev-coach-001"),
                      "Coach shell should show the signed-in coach identity")
        XCTAssertFalse(app.buttons["today_start_workout"].exists,
                       "A coach session must never expose Client navigation")

        app.buttons["coach_sign_out"].tapWhenReady()
        XCTAssertTrue(app.buttons["dev_continue_coach"].waitForExistence(timeout: 20),
                      "Coach sign-out should return to the signed-out surface")
    }

    /// Account boundaries: client-001 starts a workout; after switching to client-002
    /// the previous account's workout is NOT visible; switching back to client-001
    /// still offers it. Uses a durable store base so isolation is proved on disk.
    @MainActor
    func testAccountSwitchDoesNotExposePreviousAccountsWorkout() {
        let base = NSTemporaryDirectory() + "mazidi-auth-uitest-\(UUID().uuidString)"
        let app = launchSignedOut(extraEnvironment: [
            "MAZIDI_STORE_DIR": base,
            "MAZIDI_STORE_MODE": "durable-base", // any value ≠ "ephemeral": use the dir
        ])

        // Client 1 records a set and exits mid-workout.
        signIn(app, via: "dev_continue_client", expecting: "today_start_workout")
        // Recording is gated on health-data consent (ADR-0013). Granting it here also proves
        // the consent ledger is account-scoped: client 2 below is asked afresh.
        app.grantHealthDataConsent()
        app.buttons["today_start_workout"].tapWhenReady()
        app.buttons["overview_begin_button"].tapWhenReady()
        app.buttons["set_entry_log_button"].tapWhenReady()
        XCTAssertTrue(app.otherElements["set_entry_row.0"].waitForExistence(timeout: 15),
                      "Client 1's set should be recorded")
        app.buttons["active_pause_button"].tapWhenReady()
        app.buttons["pause_exit_keep_button"].tapWhenReady()
        XCTAssertTrue(app.buttons["today_resume_workout"].waitForExistence(timeout: 15),
                      "Client 1 should have a resumable workout")

        // Switch to client 2: a different account must see a fresh Today — never the
        // previous account's unfinished workout.
        app.buttons["client_sign_out"].tapWhenReady()
        signIn(app, via: "dev_continue_client_2", expecting: "today_start_workout")
        XCTAssertFalse(app.buttons["today_resume_workout"].exists,
                       "Client 2 must not see client 1's unfinished workout")

        // Switch back to client 1: the workout is still there (preserved, not deleted).
        app.buttons["client_sign_out"].tapWhenReady()
        signIn(app, via: "dev_continue_client", expecting: "today_resume_workout")
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
