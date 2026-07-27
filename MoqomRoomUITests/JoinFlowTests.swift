// The only tests that run the SwiftUI layer.
//
// `MoqomKit`'s own suite covers the room model thoroughly, but it drives
// `RoomSession` directly and never renders anything. Everything between a view
// body and that actor — the `@Observable` bridge in `AppModel`, the phase
// switch in `MoqomRoomApp`, the toolbar wiring — had no coverage at all, and
// it is exactly the layer where a main-actor mistake or a binding that never
// updates hides until someone opens the app.
//
// These are deliberately shallow. They assert that each phase is reachable and
// renders, not that the room behaves correctly, because the room already has
// 103 tests that do not need a simulator to run.

import XCTest

final class JoinFlowTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        return app
    }

    func testJoiningARoomReachesTheRoomScreen() {
        let app = launch()

        let username = app.textFields["Username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10), "join screen never appeared")

        username.tap()
        username.typeText("elliott")

        // The room defaults to "demo", and the room screen titles itself with
        // the room name, so that title is the signal we actually got through
        // connect and join rather than stalling on the progress view.
        app.buttons["Join"].tap()

        XCTAssertTrue(
            app.navigationBars["demo"].waitForExistence(timeout: 15),
            "never reached the room screen"
        )

        // Nobody is broadcasting yet, so the grid is empty and says so. Worth
        // asserting because an empty grid and a grid that failed to render look
        // identical from the outside.
        XCTAssertTrue(app.staticTexts["Nobody on stage"].waitForExistence(timeout: 5))

        // The room actions are behind a toolbar menu, so they do not exist as
        // queryable elements until it opens. Proving the menu builds against a
        // live RoomModel is the point; the destructive item is the one that
        // could not exist in any other phase.
        app.buttons["Room"].tap()
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Record session"].exists)
    }

    func testJoinIsRefusedUntilThereIsAName() {
        let app = launch()

        let join = app.buttons["Join"]
        XCTAssertTrue(join.waitForExistence(timeout: 10))

        // `canJoin` trims before checking, so whitespace has to stay disabled
        // too. This is the assertion that would catch someone "simplifying"
        // that to isEmpty.
        XCTAssertFalse(join.isEnabled, "Join was enabled with no username")

        let username = app.textFields["Username"]
        username.tap()
        username.typeText("   ")
        XCTAssertFalse(join.isEnabled, "Join was enabled with only whitespace")

        username.typeText("elliott")
        XCTAssertTrue(join.isEnabled)
    }

    func testLeavingReturnsToTheJoinScreen() {
        let app = launch()

        let username = app.textFields["Username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))
        username.tap()
        username.typeText("elliott")
        app.buttons["Join"].tap()

        XCTAssertTrue(app.navigationBars["demo"].waitForExistence(timeout: 15))

        app.buttons["Room"].tap()
        let leave = app.buttons["Leave"]
        XCTAssertTrue(leave.waitForExistence(timeout: 5))
        leave.tap()

        XCTAssertTrue(
            app.textFields["Username"].waitForExistence(timeout: 10),
            "leaving did not return to the join screen"
        )
    }
}
