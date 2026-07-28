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

// XCUIElement and friends are `@MainActor` in the Xcode 16 SDK and not in 26's,
// so leaving this off compiles locally on 26 and fails on CI's 16.4 with three
// dozen isolation errors. Annotating is right on both: the proxy talks to the
// app over an XPC connection that is main-thread-bound either way.
@MainActor
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

    func testGoingLiveAndPublishingAudio() {
        let app = launch()

        let username = app.textFields["Username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))
        username.tap()
        username.typeText("elliott")
        app.buttons["Join"].tap()
        XCTAssertTrue(app.navigationBars["demo"].waitForExistence(timeout: 15))

        // Going live is what puts this device in its own roster, so the empty
        // state disappearing is the signal that publish actually reached the
        // relay rather than the button merely flipping its label.
        app.buttons["Go live"].tap()
        if app.alerts.firstMatch.waitForExistence(timeout: 5) {
            XCTFail("go live failed: \(app.alerts.firstMatch.staticTexts.allElementsBoundByIndex.map(\.label))")
        }
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Nobody on stage"].exists)

        // Audio is a separate act from video, and the SDK treats it as one:
        // there is no path where starting a camera starts a microphone.
        app.buttons["Audio"].tap()
        XCTAssertTrue(app.buttons["Mute"].waitForExistence(timeout: 10))

        // The tile is the only place a whole-pipeline failure shows up: the
        // roster, the buttons, and the catalog can all be right while nothing
        // ever draws. Attached rather than asserted on, because pixel
        // comparison in CI is a source of flakes rather than of confidence.
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "live"
        shot.lifetime = .keepAlways
        add(shot)

        app.buttons["Stop"].tap()
        XCTAssertTrue(app.buttons["Go live"].waitForExistence(timeout: 10))
    }

    func testSwitchingToTheAudioRoomLayout() {
        let app = launch()

        let username = app.textFields["Username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))
        username.tap()
        username.typeText("elliott")
        app.buttons["Join"].tap()
        XCTAssertTrue(app.navigationBars["demo"].waitForExistence(timeout: 15))

        // The audio room is a different session category as well as a different
        // layout — a listener holds no microphone — so the switch reconfigures the
        // audio graph underneath. Worth one shallow test: if that throws, the
        // model surfaces an alert and this catches it.
        app.buttons["Room"].tap()
        let audioRoom = app.buttons["Audio room"]
        XCTAssertTrue(audioRoom.waitForExistence(timeout: 5))
        audioRoom.tap()

        XCTAssertFalse(
            app.alerts.firstMatch.waitForExistence(timeout: 3),
            "switching layout raised: \(app.alerts.firstMatch.staticTexts.allElementsBoundByIndex.map(\.label))"
        )
        XCTAssertTrue(app.navigationBars["demo"].exists)
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
