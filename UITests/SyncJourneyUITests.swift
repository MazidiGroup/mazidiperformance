import XCTest

/// Sync-status journeys against the new push/pull engines (ADR-0012). Deterministic waits,
/// local fixtures, no live internet. The engines run behind the DEBUG fake backend.
final class SyncJourneyUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    private func launch(base: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MAZIDI_STORE_DIR"] = base
        app.launchEnvironment["MAZIDI_AUTH_RESET"] = "1"
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
        XCTAssertTrue(expected.waitForExistence(timeout: 8), "\(expectedID) should appear")
    }

    /// The Coach shell surfaces an HONEST account-level sync status badge driven by the real
    /// push engine + durable outbox: it shows "Up to date" or "Saved on this phone", and
    /// never falsely claims delivered/synced while outbox items remain (per-aggregate
    /// ordering means a template's ops drain across several passes).
    @MainActor
    func testCoachSyncStatusIsHonest() {
        let app = launch(base: NSTemporaryDirectory() + "mazidi-sync-coach-\(UUID().uuidString)")
        signIn(app, via: "dev_continue_coach", expecting: "coach_create_workout")
        XCTAssertTrue(app.descendants(matching: .any)["coach_sync_status"].firstMatch.waitForExistence(timeout: 15),
                      "The coach shell should show an honest sync-status badge")

        // Create → add a canonical exercise → publish (drains the outbox).
        let alert = app.alerts.firstMatch
        let createButton = app.buttons["coach_create_workout"]
        for _ in 0..<3 where !alert.exists { createButton.tap(); if alert.waitForExistence(timeout: 6) { break } }
        let titleField = alert.textFields.firstMatch
        XCTAssertTrue(titleField.waitForExistence(timeout: 10))
        titleField.tap(); titleField.typeText("Sync Plan")
        alert.buttons["Create"].firstMatch.tap()

        app.buttons["editor_add_exercise"].tapWhenReady()
        let search = app.textFields["coach_exercise_search"]
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        search.tap(); search.typeText("barbell squat")
        app.buttons["exercise_option.barbell-squat"].tapWhenReady()
        app.buttons["editor_publish"].tapWhenReady()
        XCTAssertTrue(app.buttons["editor_assign"].waitForExistence(timeout: 10), "Publish should enable assign")

        // Back to the list; the badge should read up to date (outbox drained, autoAck online).
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 10)); back.tap()
        let badge = app.descendants(matching: .any)["coach_sync_status"].firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 10))
        // An honest state — "Up to date" or "Saved on this phone · N queued" — never a false
        // "Delivered"/"Synced" while items remain.
        let honest = NSPredicate(format: "value CONTAINS[c] 'up to date' OR value CONTAINS[c] 'phone' OR value CONTAINS[c] 'offline'")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: honest, object: badge)], timeout: 15), .completed,
                       "Coach sync status should show an honest outbox state")
        let falseClaim = NSPredicate(format: "value CONTAINS[c] 'delivered'")
        XCTAssertFalse(falseClaim.evaluate(with: badge), "The badge must never claim 'delivered' at the outbox level")
    }

    /// The Client Today surface shows the honest sync-status badge (offline never claims synced).
    @MainActor
    func testClientSyncStatusBadgeIsShown() {
        let app = launch(base: NSTemporaryDirectory() + "mazidi-sync-client-\(UUID().uuidString)")
        signIn(app, via: "dev_continue_client", expecting: "today_start_workout")
        XCTAssertTrue(app.descendants(matching: .any)["sync_status_badge"].firstMatch.waitForExistence(timeout: 15),
                      "The client Today surface should show the honest sync-status badge")
        // The DEBUG connectivity toggle exists and does not crash the status flow.
        XCTAssertTrue(app.switches["dev_connectivity_toggle"].waitForExistence(timeout: 10))
    }
}

private extension XCUIElement {
    @MainActor
    func tapWhenReady(timeout: TimeInterval = 15) {
        let ready = NSPredicate(format: "exists == true AND isHittable == true")
        let outcome = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: ready, object: self)], timeout: timeout)
        XCTAssertEqual(outcome, .completed, "Expected \(identifier) hittable")
        tap()
    }
}
