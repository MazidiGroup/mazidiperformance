import XCTest

/// Health-data consent journeys (ADR-0013), driven through stable accessibility identifiers.
///
/// These assert the properties that make the flow lawful and honest, not implementation
/// detail: consent is asked for before anything is recorded, purposes are separate and start
/// unticked, withdrawal is reachable in the app, and withdrawing does not delete what was
/// already recorded.
final class HealthDataConsentUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    private func launchSignedOutClient(
        environment: [String: String] = ["MAZIDI_STORE_MODE": "ephemeral", "MAZIDI_AUTH_RESET": "1"]
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment.merge(environment) { _, new in new }
        app.launch()
        app.signInAsDevClient()
        return app
    }

    /// A fresh account is offered the choice on Today, before anything is recorded, and the
    /// consent screen starts with every purpose unticked.
    @MainActor
    func testConsentIsOfferedBeforeAnythingIsRecordedAndNothingIsPreTicked() {
        let app = launchSignedOutClient()

        XCTAssertTrue(app.descendants(matching: .any)[A11yUITestID.consentTodayCard].firstMatch.waitForExistence(timeout: 30),
                      "A fresh account should be offered the health-data choice on Today")
        XCTAssertTrue(app.buttons[A11yUITestID.consentOpenButton].firstMatch.waitForExistence(timeout: 10),
                      "The choice must be reachable from Today")

        app.buttons[A11yUITestID.consentOpenButton].firstMatch.tapWhenReady()

        for purpose in A11yUITestID.purposes {
            let toggle = app.switches["\(A11yUITestID.consentPurposeToggle).\(purpose)"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 15), "\(purpose) should have its own control")
            XCTAssertEqual(toggle.value as? String, "0", "\(purpose) must not be pre-ticked")
        }
        XCTAssertTrue(app.buttons[A11yUITestID.consentNotNowButton].exists,
                      "Declining must be a first-class option, not a dead end")
    }

    /// Declining leaves the app usable and recording switched off — and says so, rather than
    /// silently accepting sets that go nowhere.
    @MainActor
    func testDecliningLeavesRecordingOffAndSaysSo() {
        let app = launchSignedOutClient()
        app.buttons[A11yUITestID.consentOpenButton].firstMatch.tapWhenReady()
        let notNow = app.buttons[A11yUITestID.consentNotNowButton]
        XCTAssertTrue(notNow.waitForExistence(timeout: 20), "Declining must be offered")
        app.scrollUntilHittable(notNow)
        notNow.tapWhenReady()

        // The workout is still reachable; starting it routes back to the choice rather than
        // recording anything.
        app.buttons["today_start_workout"].tapWhenReady()
        app.buttons["overview_begin_button"].tapWhenReady()
        XCTAssertTrue(app.switches["\(A11yUITestID.consentPurposeToggle).performanceRecording"].waitForExistence(timeout: 15),
                      "Beginning a workout without consent must route to the choice, not record")
    }

    /// Granting only the performance purpose does not grant the effort-rating purpose: the
    /// effort control is absent, and the set logs without one.
    @MainActor
    func testPurposesAreUnbundledInTheRunningApp() {
        let app = launchSignedOutClient()
        app.grantHealthDataConsent(purposes: ["performanceRecording"])

        app.buttons["today_start_workout"].tapWhenReady()
        app.buttons["overview_begin_button"].tapWhenReady()

        XCTAssertTrue(app.buttons["set_entry_log_button"].waitForExistence(timeout: 15),
                      "Recording should be permitted after granting performanceRecording")
        XCTAssertFalse(app.switches["set_entry_field.rpe"].exists,
                       "The effort control must be absent while its own consent is not in force")
        app.buttons["set_entry_log_button"].tapWhenReady()
        XCTAssertTrue(app.otherElements["set_entry_row.0"].waitForExistence(timeout: 15),
                      "The set should record with the performance consent alone")
    }

    /// Withdrawal is reachable in the app (Art. 7(3)) and does not delete what was recorded.
    @MainActor
    func testWithdrawalStopsFutureRecordingButKeepsWhatWasRecorded() {
        let app = launchSignedOutClient()
        app.grantHealthDataConsent()

        // Record a set, then leave the workout.
        app.buttons["today_start_workout"].tapWhenReady()
        app.buttons["overview_begin_button"].tapWhenReady()
        app.buttons["set_entry_log_button"].tapWhenReady()
        XCTAssertTrue(app.otherElements["set_entry_row.0"].waitForExistence(timeout: 15),
                      "A set should be recorded before withdrawal")
        app.buttons["active_pause_button"].tapWhenReady()
        app.buttons["pause_exit_keep_button"].tapWhenReady()

        // Withdraw performance recording from the privacy surface.
        XCTAssertTrue(app.buttons[A11yUITestID.privacyOpenButton].waitForExistence(timeout: 20),
                      "Privacy must be reachable from Today")
        app.buttons[A11yUITestID.privacyOpenButton].tapWhenReady()
        let withdraw = app.buttons["\(A11yUITestID.privacyWithdrawButton).performanceRecording"].firstMatch
        XCTAssertTrue(withdraw.waitForExistence(timeout: 15), "An in-force purpose should offer withdrawal")
        app.scrollUntilHittable(withdraw)
        withdraw.tapWhenReady()
        // The confirmation is a system alert; its buttons are addressed by label. firstMatch
        // is required: the view declares more than one alert, so the query is ambiguous.
        let confirm = app.alerts.firstMatch.buttons["Turn off"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 15), "Withdrawal should ask for confirmation")
        confirm.tapWhenReady()

        // The purpose is now off, and re-granting is offered instead of withdrawal.
        XCTAssertTrue(app.buttons["\(A11yUITestID.privacyGrantButton).performanceRecording"].firstMatch.waitForExistence(timeout: 15),
                      "After withdrawal the purpose should read as off")

        // The recorded set survived: the unfinished session is still resumable with its set.
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 15), "Privacy should have a back control")
        back.tapWhenReady()
        XCTAssertTrue(app.buttons["today_resume_workout"].waitForExistence(timeout: 20),
                      "The recorded session must survive withdrawal")
        app.buttons["today_resume_workout"].tapWhenReady()
        XCTAssertTrue(app.otherElements["set_entry_row.0"].waitForExistence(timeout: 15),
                      "Withdrawal must not delete an already-recorded set")
        XCTAssertTrue(app.descendants(matching: .any)[A11yUITestID.consentRequiredNotice].firstMatch.waitForExistence(timeout: 15),
                      "With recording withdrawn, the form should be replaced by an honest notice")
    }

    /// Withdrawing coach sharing is reflected honestly in the sync status — never "Synced".
    @MainActor
    func testSharingOffIsReportedHonestlyInTheSyncStatus() {
        let app = launchSignedOutClient()
        app.grantHealthDataConsent(purposes: ["performanceRecording"])   // sharing deliberately not granted

        let badge = app.descendants(matching: .any)[A11yUITestID.syncStatusBadge].firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 20), "Today should show the sync status badge")
        let value = (badge.value as? String) ?? badge.label
        XCTAssertTrue(value.localizedCaseInsensitiveContains("sharing"),
                      "Without sharing consent the badge must say so, not claim a sync state — got \(value)")
    }
}

// MARK: - Shared identifiers and helpers

/// Mirrors `App/DesignSystem/AccessibilityIdentifiers.swift`. UI tests cannot import the app
/// target, so the contract is restated here — deliberately, since these strings are the
/// contract and a silent rename should break the tests.
enum A11yUITestID {
    static let consentTodayCard = "consent_today_card"
    static let consentOpenButton = "consent_open_button"
    static let consentPurposeToggle = "consent_purpose_toggle"
    static let consentSaveButton = "consent_save_button"
    static let consentNotNowButton = "consent_not_now_button"
    static let consentRequiredNotice = "consent_required_notice"
    static let privacyOpenButton = "privacy_open_button"
    static let privacyWithdrawButton = "privacy_withdraw_button"
    static let privacyGrantButton = "privacy_grant_button"
    static let privacyWithdrawConfirmButton = "privacy_withdraw_confirm_button"
    static let syncStatusBadge = "sync_status_badge"

    static let purposes = ["performanceRecording", "perceivedExertionRecording", "coachSharing"]
}

private extension XCUIElement {
    /// Tap once the element is present AND hittable — a real wait condition, not a delay, so
    /// a tap issued mid-transition is never silently dropped.
    @MainActor
    func tapWhenReady(timeout: TimeInterval = 15) {
        let ready = NSPredicate(format: "exists == true AND isHittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: ready, object: self)
        let outcome = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(outcome, .completed, "Expected element \(identifier) to be hittable")
        tap()
    }
}

extension XCUIApplication {
    /// Select the dev Client role and wait for Today. The very first cold-launch tap can land
    /// after the control is hittable but before SwiftUI has wired its action, so it is
    /// silently dropped — retry until Today appears (a bounded condition wait, not a delay).
    @MainActor
    func signInAsDevClient(entry: String = "dev_continue_client") {
        let devEntry = buttons[entry]
        XCTAssertTrue(devEntry.waitForExistence(timeout: 20), "Client dev entry should appear")
        let today = buttons["today_start_workout"]
        for _ in 0..<3 where !today.exists {
            devEntry.tap()
            if today.waitForExistence(timeout: 8) { break }
        }
        XCTAssertTrue(today.waitForExistence(timeout: 8), "Client Today should appear")
    }

    /// Grant health-data consent through the real consent screen (ADR-0013). Every journey
    /// that records health data must pass through this, because the app genuinely requires it
    /// — there is no test-only bypass, by design.
    @MainActor
    func grantHealthDataConsent(purposes: [String] = A11yUITestID.purposes) {
        // Today must be up first: the consent card renders with the rest of the screen, so
        // querying before then races the initial load rather than testing anything.
        XCTAssertTrue(waitForToday(timeout: 60), "Client Today should be up before choosing")
        let open = buttons[A11yUITestID.consentOpenButton].firstMatch
        guard open.waitForExistence(timeout: 30) else {
            // No card means recording consent is already in force for this account — the
            // journey's precondition is met, so there is nothing to grant.
            return
        }
        open.tapWhenReady()
        for purpose in purposes {
            let toggle = switches["\(A11yUITestID.consentPurposeToggle).\(purpose)"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 20), "\(purpose) control should be present")
            if toggle.value as? String != "1" { toggle.tapWhenReady() }
        }
        let save = buttons[A11yUITestID.consentSaveButton]
        scrollUntilHittable(save)
        save.tapWhenReady()
        XCTAssertTrue(waitForToday(timeout: 30), "Saving the choices should return to Today")
    }

    /// Scroll the screen until `element` is hittable. The consent screen is deliberately
    /// long — three purposes, each with its own explanation — so the save control sits below
    /// the fold at default type size and further still at accessibility sizes.
    @MainActor
    func scrollUntilHittable(_ element: XCUIElement, attempts: Int = 8) {
        for _ in 0..<attempts {
            if element.exists && element.isHittable { return }
            swipeUp()
        }
    }

    /// True once the Client Today screen is showing (either entry point).
    @MainActor
    func waitForToday(timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if buttons["today_start_workout"].exists || buttons["today_resume_workout"].exists { return true }
            _ = buttons["today_start_workout"].waitForExistence(timeout: 2)
        }
        return buttons["today_start_workout"].exists || buttons["today_resume_workout"].exists
    }
}
