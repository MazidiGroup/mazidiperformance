import XCTest

/// Catalogue-backed exercise picker journeys (ADR-0011): search, category/equipment
/// filters, preview, and selecting a canonical (non-fixture) exercise then publishing.
/// All waits are condition-based; everything resolves from the bundled catalogue + client
/// content — no live internet. Each test uses an isolated durable store base.
final class CoachCatalogueUITests: XCTestCase {
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
    private func signInCoach(_ app: XCUIApplication) {
        let entry = app.buttons["dev_continue_coach"]
        XCTAssertTrue(entry.waitForExistence(timeout: 20), "Coach dev entry should exist")
        let expected = app.buttons["coach_create_workout"]
        for _ in 0..<3 where !expected.exists {
            entry.tap()
            if expected.waitForExistence(timeout: 8) { break }
        }
        XCTAssertTrue(expected.waitForExistence(timeout: 8), "Coach shell should appear")
    }

    /// Sign in, create a workout, and open the catalogue picker (search field visible).
    @MainActor
    private func openPicker(_ app: XCUIApplication, title: String) {
        signInCoach(app)
        let alert = app.alerts.firstMatch
        let createButton = app.buttons["coach_create_workout"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 15), "Create control should exist")
        for _ in 0..<3 where !alert.exists {
            createButton.tap()
            if alert.waitForExistence(timeout: 6) { break }
        }
        let titleField = alert.textFields.firstMatch
        XCTAssertTrue(titleField.waitForExistence(timeout: 10), "New-workout title field should appear")
        titleField.tap()
        titleField.typeText(title)
        alert.buttons["Create"].firstMatch.tap()

        app.buttons["editor_add_exercise"].tapWhenReady()
        XCTAssertTrue(app.textFields["coach_exercise_search"].waitForExistence(timeout: 15),
                      "The catalogue picker search field should appear")
    }

    /// Searching finds a canonical exercise that is NOT one of the bundled fixture slugs —
    /// proving the picker searches the full catalogue, not the old hardcoded list.
    @MainActor
    func testSearchFindsNonFixtureCatalogueExercise() {
        let app = launch(base: NSTemporaryDirectory() + "mazidi-cat-search-\(UUID().uuidString)")
        openPicker(app, title: "Search Test")
        let search = app.textFields["coach_exercise_search"]
        search.tap()
        search.typeText("abdominals")
        XCTAssertTrue(app.buttons["exercise_option.abdominals-stretch-variation-four"].waitForExistence(timeout: 15),
                      "A non-fixture canonical exercise should be searchable")
        // A fixture-only slug should not match this query.
        XCTAssertFalse(app.buttons["exercise_option.barbell-squat"].exists,
                       "Unrelated exercises should be filtered out by the query")
    }

    /// Category (movement pattern) filter narrows results deterministically.
    @MainActor
    func testCategoryFilterNarrowsResults() {
        let app = launch(base: NSTemporaryDirectory() + "mazidi-cat-cat-\(UUID().uuidString)")
        openPicker(app, title: "Category Test")
        app.buttons["coach_filter_category"].tapWhenReady()
        app.buttons["Mobility"].firstMatch.tapWhenReady()
        // A Mobility exercise is present; a Squat-pattern exercise is not.
        XCTAssertTrue(app.buttons["exercise_option.abdominals-stretch-variation-four"].waitForExistence(timeout: 15),
                      "A Mobility exercise should remain after filtering to Mobility")
        XCTAssertFalse(app.buttons["exercise_option.barbell-squat"].exists,
                       "A Squat-pattern exercise should be filtered out of Mobility")
    }

    /// Equipment filter narrows results deterministically.
    @MainActor
    func testEquipmentFilterNarrowsResults() {
        let app = launch(base: NSTemporaryDirectory() + "mazidi-cat-equip-\(UUID().uuidString)")
        openPicker(app, title: "Equipment Test")
        app.buttons["coach_filter_equipment"].tapWhenReady()
        app.buttons["Barbell"].firstMatch.tapWhenReady()
        // Assert on the alphabetically-first Barbell exercise so it renders at the top of
        // the lazily-loaded results list (deterministic, not scroll-dependent).
        XCTAssertTrue(app.buttons["exercise_option.barbell-banded-back-squat"].waitForExistence(timeout: 15),
                      "A Barbell exercise should remain after filtering to Barbell")
        XCTAssertFalse(app.buttons["exercise_option.abdominals-stretch-variation-four"].exists,
                       "A Bodyweight exercise should be filtered out of Barbell")
    }

    /// Opening an exercise preview shows the detail sheet with an Add action.
    @MainActor
    func testOpensExercisePreview() {
        let app = launch(base: NSTemporaryDirectory() + "mazidi-cat-preview-\(UUID().uuidString)")
        openPicker(app, title: "Preview Test")
        let search = app.textFields["coach_exercise_search"]
        search.tap()
        search.typeText("barbell squat")
        app.buttons["exercise_preview.barbell-squat"].tapWhenReady()
        XCTAssertTrue(app.descendants(matching: .any)["coach_exercise_preview"].firstMatch.waitForExistence(timeout: 15),
                      "The exercise preview should open")
        XCTAssertTrue(app.buttons["preview_add_exercise"].waitForExistence(timeout: 10),
                      "The preview should offer an Add action")
    }

    /// Selecting a canonical (non-fixture) exercise adds it by stable slug and publishes.
    @MainActor
    func testSelectCanonicalExerciseAndPublish() {
        let app = launch(base: NSTemporaryDirectory() + "mazidi-cat-select-\(UUID().uuidString)")
        openPicker(app, title: "Publish Test")
        let search = app.textFields["coach_exercise_search"]
        search.tap()
        search.typeText("abdominals")
        app.buttons["exercise_option.abdominals-stretch-variation-four"].tapWhenReady()
        XCTAssertTrue(app.buttons["editor_exercise_row.abdominals-stretch-variation-four"].waitForExistence(timeout: 10),
                      "The canonical exercise should join the draft by its stable slug")
        app.buttons["editor_publish"].tapWhenReady()
        XCTAssertTrue(app.buttons["editor_assign"].waitForExistence(timeout: 10),
                      "Publishing a canonical-exercise workout should enable assignment")
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
