import XCTest

/// Local device test profile journeys (ADR-0014). These prove the three things the
/// TestFlight build depends on: the app is reachable **without any sign-in**, the device
/// identity is **stable across launches** (so a tester's data is still there), and a role
/// switch **tears down and rebuilds** cleanly with no data crossing between the shells.
///
/// The profile exists only in `LOCAL_IDENTITY` builds (Debug + Staging). These tests run in
/// Debug; the Release boundary is proved on the binary itself by
/// `Scripts/check-release-isolation.sh`.
final class LocalDeviceIdentityUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// A durable, per-test store base so identity stability is proved on disk rather than
    /// in a process-lifetime store. CI builds the app unsigned, so the Keychain is
    /// unavailable and the DEBUG file-backed credential/profile stores stand in (the same
    /// seam ADR-0008 §6 already uses).
    @MainActor
    private func launch(base: String, resetSession: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MAZIDI_STORE_DIR"] = base
        app.launchEnvironment["MAZIDI_STORE_MODE"] = "durable-base" // any value ≠ "ephemeral"
        if resetSession { app.launchEnvironment["MAZIDI_AUTH_RESET"] = "1" }
        app.launch()
        return app
    }

    /// Choose a local profile role, retrying the first cold-launch tap (an early tap can
    /// land before SwiftUI wires the action) until the expected shell marker appears.
    @MainActor
    private func chooseLocalProfile(
        _ app: XCUIApplication,
        button: String,
        expecting expectedID: String
    ) {
        let entry = app.buttons[button]
        XCTAssertTrue(entry.waitForExistence(timeout: 30), "\(button) should exist on the signed-out surface")
        let expected = app.descendants(matching: .any)[expectedID]
        for _ in 0..<3 where !expected.exists {
            entry.tap()
            if expected.waitForExistence(timeout: 10) { break }
        }
        XCTAssertTrue(expected.waitForExistence(timeout: 10),
                      "\(expectedID) should appear after choosing \(button)")
    }

    /// Put the client account into a resumable-workout state, so later assertions can tell
    /// "this account's data" from "the other account's data".
    @MainActor
    private func startAndExitWorkout(_ app: XCUIApplication) {
        app.grantHealthDataConsent()
        app.buttons["today_start_workout"].tapWhenReadyLocalProfile()
        app.buttons["overview_begin_button"].tapWhenReadyLocalProfile()
        app.buttons["set_entry_log_button"].tapWhenReadyLocalProfile()
        XCTAssertTrue(app.otherElements["set_entry_row.0"].waitForExistence(timeout: 20),
                      "The set should be recorded")
        app.buttons["active_pause_button"].tapWhenReadyLocalProfile()
        app.buttons["pause_exit_keep_button"].tapWhenReadyLocalProfile()
        XCTAssertTrue(app.buttons["today_resume_workout"].waitForExistence(timeout: 20),
                      "The account should now have a resumable workout")
    }

    /// The app is usable with no sign-in at all: the local profile chooser is on the
    /// signed-out surface and opens a shell, which then states honestly what it is.
    @MainActor
    func testLocalProfileOpensAShellWithoutSigningIn() {
        let base = NSTemporaryDirectory() + "mazidi-local-identity-\(UUID().uuidString)"
        let app = launch(base: base, resetSession: true)

        XCTAssertTrue(app.staticTexts["state_local_profile_chooser"].waitForExistence(timeout: 30),
                      "The signed-out surface should offer a local test profile")

        chooseLocalProfile(app, button: "local_profile_continue_client", expecting: "today_start_workout")

        // The shell must say what the profile is — never present it as an account.
        XCTAssertTrue(app.buttons["local_profile_switch_role"].waitForExistence(timeout: 20),
                      "The shell should carry the local-profile banner and its role switch")
    }

    /// Same device → same identity: after terminating and relaunching WITHOUT a session
    /// reset, the profile restores into the same account and its data is still there.
    @MainActor
    func testLocalProfileIdentityIsStableAcrossLaunches() {
        let base = NSTemporaryDirectory() + "mazidi-local-identity-\(UUID().uuidString)"
        let app = launch(base: base, resetSession: true)
        chooseLocalProfile(app, button: "local_profile_continue_client", expecting: "today_start_workout")
        startAndExitWorkout(app)

        app.terminate()
        let relaunched = launch(base: base, resetSession: false)

        // Restored straight into the client shell: no chooser, no sign-in, same account.
        XCTAssertTrue(relaunched.buttons["today_resume_workout"].waitForExistence(timeout: 40),
                      "A relaunch should restore the same local profile and its data")
        XCTAssertFalse(relaunched.staticTexts["state_local_profile_chooser"].exists,
                       "A restored profile should not ask the tester to choose again")
    }

    /// Switching role is a full account switch: the client shell is torn down, the coach
    /// shell shows none of its data, and switching back finds the client's data intact
    /// (preserved, never deleted).
    @MainActor
    func testRoleSwitchTearsDownAndKeepsTheTwoShellsIsolated() {
        let base = NSTemporaryDirectory() + "mazidi-local-identity-\(UUID().uuidString)"
        let app = launch(base: base, resetSession: true)
        chooseLocalProfile(app, button: "local_profile_continue_client", expecting: "today_start_workout")
        startAndExitWorkout(app)

        // Client → Coach.
        app.buttons["local_profile_switch_role"].tapWhenReadyLocalProfile()
        XCTAssertTrue(app.buttons["coach_sign_out"].waitForExistence(timeout: 40),
                      "Switching role should open the coach shell")
        XCTAssertFalse(app.buttons["today_resume_workout"].exists,
                       "The coach shell must never show the client profile's workout")
        XCTAssertFalse(app.buttons["today_start_workout"].exists,
                       "A coach session must never expose client navigation")

        // Coach → Client: the client account's data is still on the device.
        app.buttons["local_profile_switch_role"].tapWhenReadyLocalProfile()
        XCTAssertTrue(app.buttons["today_resume_workout"].waitForExistence(timeout: 40),
                      "Switching back should find the client profile's workout preserved")
        XCTAssertFalse(app.buttons["coach_sign_out"].exists,
                       "No coach navigation may remain after switching back")
    }
}

private extension XCUIElement {
    @MainActor
    func tapWhenReadyLocalProfile(timeout: TimeInterval = 20) {
        let ready = NSPredicate(format: "exists == true AND isHittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: ready, object: self)
        let outcome = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(outcome, .completed, "Expected element \(identifier) to be hittable")
        tap()
    }
}
