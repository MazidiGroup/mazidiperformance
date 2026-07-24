import XCTest

/// UI test target placeholder — real journeys land with slice 1's UI (Phase 2 step 3).
/// Accessibility identifiers (e.g. `dev_continue_client`) are already in place for them.
final class PlaceholderUITests: XCTestCase {
    @MainActor
    func testAppLaunches() throws {
        let app = XCUIApplication()
        // Fresh in-memory store (DEBUG) — smoke launches never touch the durable database.
        app.launchEnvironment["MAZIDI_STORE_MODE"] = "ephemeral"
        app.launch()
        XCTAssertTrue(app.exists)
    }
}
