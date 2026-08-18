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

    /// Join, brought into view first.
    ///
    /// A SwiftUI `Form` is a collection view that instantiates only the cells
    /// near the viewport, so a button below the fold does not exist to be
    /// queried at all -- it is not merely present and unhittable, which is why
    /// `waitForExistence` on it burns its whole timeout and then fails. The join
    /// screen grew past one screen when the relay and token-service sections
    /// arrived, and every test in this file had been failing to find a button it
    /// used to find ever since.
    ///
    /// Nothing said so, which is the part worth fixing once rather than eight
    /// times: the workflow asked for a scheme xcodegen does not generate, so
    /// this bundle never ran, and then the organisation's Actions minutes ran
    /// out and no job started anywhere for three weeks.
    private func joinButton(in app: XCUIApplication) -> XCUIElement {
        let join = app.buttons["Join"]
        var swipes = 0
        while !join.exists, swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        return join
    }

    private func tapJoin(in app: XCUIApplication) {
        let join = joinButton(in: app)
        XCTAssertTrue(join.waitForExistence(timeout: 5), "Join never came into view")
        join.tap()
    }

    /// The username field, brought back into view.
    ///
    /// The counterpart to ``joinButton(in:)`` and needed for the same reason:
    /// once the form has been scrolled far enough down to reach Join, the field
    /// at the top of it has been recycled and no longer exists to type into.
    private func usernameField(in app: XCUIApplication) -> XCUIElement {
        let username = app.textFields["Username"]
        var swipes = 0
        while !username.exists, swipes < 8 {
            app.swipeDown()
            swipes += 1
        }
        return username
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
        tapJoin(in: app)

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
        tapJoin(in: app)
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
        //
        // "End audio" rather than "Mute": ending the publication and muting it
        // are two different buttons here because they are two different things
        // on the wire, and asserting on the wrong one would pass while the
        // publication never started.
        app.buttons["Audio"].tap()
        XCTAssertTrue(app.buttons["End audio"].waitForExistence(timeout: 10))

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

    func testMutingTheMicrophoneAndCameraWithoutEndingEither() {
        let app = launch()

        let username = app.textFields["Username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))
        username.tap()
        username.typeText("elliott")
        tapJoin(in: app)
        XCTAssertTrue(app.navigationBars["demo"].waitForExistence(timeout: 15))

        // Muting is only meaningful against a running publication, and the
        // buttons say so by being disabled until there is one. That is worth
        // asserting: a mute control that is live before anything is publishing
        // is a control that silently does nothing.
        XCTAssertFalse(app.buttons["Camera off"].isEnabled)
        XCTAssertFalse(app.buttons["Mute"].isEnabled)

        app.buttons["Go live"].tap()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 10))
        app.buttons["Audio"].tap()
        XCTAssertTrue(app.buttons["End audio"].waitForExistence(timeout: 10))

        app.buttons["Mute"].tap()
        XCTAssertTrue(app.buttons["Unmute"].waitForExistence(timeout: 5))

        app.buttons["Camera off"].tap()
        XCTAssertTrue(app.buttons["Camera on"].waitForExistence(timeout: 5))

        // The whole point of the feature: muted, but still broadcasting and
        // still on stage. A mute implemented as stop-and-restart would have
        // flipped these back and emptied the grid.
        XCTAssertTrue(app.buttons["Stop"].exists, "muting the camera ended the broadcast")
        XCTAssertTrue(app.buttons["End audio"].exists, "muting the mic ended the publication")
        XCTAssertFalse(app.staticTexts["Nobody on stage"].exists, "muting took us off stage")

        XCTAssertFalse(
            app.alerts.firstMatch.waitForExistence(timeout: 3),
            "muting raised: \(app.alerts.firstMatch.staticTexts.allElementsBoundByIndex.map(\.label))"
        )

        app.buttons["Unmute"].tap()
        XCTAssertTrue(app.buttons["Mute"].waitForExistence(timeout: 5))
        app.buttons["Camera on"].tap()
        XCTAssertTrue(app.buttons["Camera off"].waitForExistence(timeout: 5))
    }

    func testFlippingIsOfferedOnlyForARealCamera() {
        let app = launch()

        let username = app.textFields["Username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))
        username.tap()
        username.typeText("elliott")
        tapJoin(in: app)
        XCTAssertTrue(app.navigationBars["demo"].waitForExistence(timeout: 15))

        app.buttons["Go live"].tap()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 10))

        // The sample broadcasts a test pattern by default so it runs in a
        // simulator, and a test pattern has no front and back. Asserting the
        // control is disabled rather than absent, because a flip button that
        // does nothing is worse than one that says it cannot.
        XCTAssertTrue(app.buttons["Flip"].exists)
        XCTAssertFalse(app.buttons["Flip"].isEnabled)

        // The picker that would change that is locked while live, for the same
        // reason: swapping the source under a running publication means tearing
        // down the capture the encoder is reading from.
        app.buttons["Input"].tap()
        let video = app.buttons["Camera"]
        XCTAssertTrue(video.waitForExistence(timeout: 5), "no video input picker in the menu")
    }

    func testSwitchingToTheAudioRoomLayout() {
        let app = launch()

        let username = app.textFields["Username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))
        username.tap()
        username.typeText("elliott")
        tapJoin(in: app)
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

    func testChoosingWhoStaysInTheSmallWindow() {
        let app = launch()

        let username = app.textFields["Username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))
        username.tap()
        username.typeText("elliott")
        tapJoin(in: app)
        XCTAssertTrue(app.navigationBars["demo"].waitForExistence(timeout: 15))

        // Picture in Picture itself cannot be driven from a UI test — the
        // window belongs to the system and the simulator will not background
        // the app on demand — so what is worth testing is the part that can
        // break silently: choosing a cast reaches `RoomSession` and the room
        // recomputes occupancy without throwing. A cast that referenced a
        // participant who is not there surfaces here as an alert.
        app.buttons["Room"].tap()
        let cast = app.buttons["Cohosts and guests"]
        XCTAssertTrue(cast.waitForExistence(timeout: 5), "the cast picker is not in the menu")
        cast.tap()

        XCTAssertFalse(
            app.alerts.firstMatch.waitForExistence(timeout: 3),
            "choosing a cast raised: \(app.alerts.firstMatch.staticTexts.allElementsBoundByIndex.map(\.label))"
        )
        XCTAssertTrue(app.navigationBars["demo"].exists)
    }

    func testJoinIsRefusedUntilThereIsAName() {
        let app = launch()

        XCTAssertTrue(
            app.textFields["Username"].waitForExistence(timeout: 10),
            "join screen never appeared"
        )
        XCTAssertTrue(joinButton(in: app).exists, "Join never came into view")
        XCTAssertFalse(joinButton(in: app).isEnabled, "Join was enabled with no username")

        // `canJoin` trims before checking, so whitespace has to stay disabled
        // too. This is the assertion that would catch someone "simplifying"
        // that to isEmpty.
        //
        // Each check re-fetches the button rather than holding one across a
        // scroll, because the form recycles it: an element captured before
        // scrolling up to type is stale by the time the assertion reads it.
        let username = usernameField(in: app)
        username.tap()
        username.typeText("   ")
        XCTAssertFalse(joinButton(in: app).isEnabled, "Join was enabled with only whitespace")

        usernameField(in: app).typeText("elliott")
        XCTAssertTrue(joinButton(in: app).isEnabled)
    }

    func testLeavingReturnsToTheJoinScreen() {
        let app = launch()

        let username = app.textFields["Username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))
        username.tap()
        username.typeText("elliott")
        tapJoin(in: app)

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
