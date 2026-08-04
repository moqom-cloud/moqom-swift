// Which way a captured frame has to be turned, and whether it has to be turned at all.
//
// The camera itself is not testable here — there is no device and no authorisation prompt to
// answer — but this decision is, and it is the part that was wrong. Every sensor format is
// landscape, so a portrait publication is a quarter turn, and the turn is normally applied by
// the capture connection for free. `CameraSource.turn(toReach:having:mirrored:)` is the
// fallback for a connection that accepts the request, reports it back, and goes on delivering
// landscape anyway, which is a thing one of two phones on the same build actually did.
//
// Two ways to be wrong, and neither shows up as an error. Turn when no turn is needed and the
// picture is sideways at the far end. Turn the wrong way and it is upside down. Both were
// found by looking at a phone, which is why the choice now lives somewhere a test can reach.

import Foundation
import Testing

@testable import MoqomCore
@testable import MoqomKit

#if canImport(AVFoundation) && (os(iOS) || os(macOS))

    @Suite("Turning captured frames")
    struct CameraRotationTests {
        private let landscape = PixelSize(width: 1280, height: 720)
        private let portrait = PixelSize(width: 720, height: 1280)

        @Test("a connection that honoured the request needs no help")
        func nothingToDo() {
            // The common case on both counts, and the one that has to cost nothing: this runs
            // on every frame.
            #expect(CameraSource.turn(toReach: 90, having: portrait, mirrored: false) == nil)
            #expect(CameraSource.turn(toReach: 0, having: landscape, mirrored: false) == nil)
            #expect(CameraSource.turn(toReach: 90, having: portrait, mirrored: true) == nil)
        }

        @Test("a connection that would not turn is corrected here")
        func theFallbackTurns() {
            #expect(
                CameraSource.turn(toReach: 90, having: landscape, mirrored: false)
                    == .anticlockwise
            )
            // Mirrored the other way, because the connection flips about an axis the turn
            // carries onto the other one. Turning the same way as the unmirrored case gives a
            // vertically flipped face, which reads as upside down rather than as a mirror.
            #expect(
                CameraSource.turn(toReach: 90, having: landscape, mirrored: true)
                    == .clockwise
            )
        }

        @Test("landscape frames are left alone when landscape is what was asked for")
        func aLandscapeRequestIsNotUndone() {
            // The regression this exists for. The decision used to be made against the format
            // the source was opened with, which is portrait for a phone; asking for landscape
            // later — a host changing layout mid-call — left that unchanged, so every frame was
            // turned back to portrait. The publisher reported the new rotation, the viewer saw
            // no change of shape, and the only cost visible anywhere was a hardware rotation
            // per frame that achieved nothing.
            #expect(CameraSource.turn(toReach: 0, having: landscape, mirrored: false) == nil)
            #expect(CameraSource.turn(toReach: 0, having: landscape, mirrored: true) == nil)
            #expect(CameraSource.turn(toReach: 180, having: landscape, mirrored: false) == nil)
        }

        @Test("a turn nobody asked for is undone the way it came")
        func theInverseTurn() {
            // A connection still applying a rotation that has been switched off. The turn back
            // is the inverse of the turn in, not the same one: taking the same quarter turn
            // both ways arrives half a turn from where it started, which is upside down.
            #expect(
                CameraSource.turn(toReach: 0, having: portrait, mirrored: false)
                    == .clockwise
            )
            #expect(
                CameraSource.turn(toReach: 0, having: portrait, mirrored: true)
                    == .anticlockwise
            )
        }

        @Test("a half turn is not a change of shape")
        func evenQuartersKeepTheShape() {
            // Upside down is still landscape. Counting quarters rather than testing for
            // ninety is what makes this true, and 270 is a real value: it is what a
            // connection is given for a phone held the other way up.
            #expect(CameraSource.turn(toReach: 180, having: landscape, mirrored: false) == nil)
            #expect(
                CameraSource.turn(toReach: 270, having: landscape, mirrored: false)
                    == .anticlockwise
            )
            #expect(CameraSource.turn(toReach: 270, having: portrait, mirrored: false) == nil)
        }

        @Test("a square frame is treated as landscape")
        func squareCounts() {
            // Neither taller nor wider, so nothing is decided by its shape. Landscape is the
            // answer that leaves it alone at rotation zero, and the alternative — turning a
            // square frame to make it a differently oriented square — is work for nothing.
            let square = PixelSize(width: 720, height: 720)
            #expect(CameraSource.turn(toReach: 0, having: square, mirrored: false) == nil)
            #expect(
                CameraSource.turn(toReach: 90, having: square, mirrored: false)
                    == .anticlockwise
            )
        }
    }

#endif
