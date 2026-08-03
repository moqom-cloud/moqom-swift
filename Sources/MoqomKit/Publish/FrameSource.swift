// Where frames come from.
//
// Camera capture is one implementation of this protocol, not the shape of the
// API. A rendered RealityKit scene is the case that matters most for MOQOM and
// it does not resemble a camera at all: frames arrive on the render thread,
// inside a callback that must not block, at whatever rate the scene is being
// drawn. An API built around `AVCaptureSession` and extended later to cover
// that ends up with the scene path as an adapter over a camera abstraction,
// which is backwards.
//
// So the protocol is a stream of frames and nothing more, and the push-driven
// case — someone else owns the render loop and hands us frames — is the
// primitive rather than the special case.

import Foundation
import MoqomCore

/// What a source produces.
public struct CaptureFormat: Hashable, Sendable {
    public let size: PixelSize

    /// Nominal frames per second. A hint for the encoder's rate control; the
    /// actual rate follows submission.
    public let frameRate: Double

    public init(size: PixelSize, frameRate: Double) {
        self.size = size
        self.frameRate = frameRate
    }
}

/// A stream of frames for the SDK to encode and publish.
public protocol FrameSource: Sendable {
    /// What the source intends to produce. May be revised by the source
    /// stopping and a new one starting; it is not renegotiated mid-stream.
    var captureFormat: CaptureFormat { get }

    /// The frames.
    ///
    /// A source supports one consumer. Two publications of the same scene want
    /// two taps, not two iterations of one stream, because the second consumer
    /// would otherwise silently receive half the frames.
    func frames() -> AsyncStream<VideoFrame>

    /// Stop producing. Idempotent.
    func stop()

    /// Let go of the capture hardware without ending the stream.
    ///
    /// The difference from ``stop()`` is what can follow it. Stopping is final
    /// — the stream finishes and the publication above it has to be rebuilt —
    /// whereas this leaves everything standing and produces no frames, so
    /// ``resume()`` is a camera warming up rather than a rejoin.
    ///
    /// What it is for is the indicator. A force-muted participant is entitled
    /// to see the light go out, and no amount of dropping frames further down
    /// achieves that: the light reports the device being open, which is a
    /// claim only the source can make.
    func suspend()

    /// Open the hardware again. Idempotent, and does nothing after ``stop()``.
    ///
    /// > Important: There is deliberately no default implementation of these
    /// > two, although most sources have no hardware and want an empty one.
    /// > A default is inherited by a source that wraps another — a decorator
    /// > that measures frames, say — and a wrapper which forwards everything
    /// > else while silently swallowing this one leaves the camera open under
    /// > a moderator's mute, with every counter above it reporting the mute as
    /// > applied. That happened, on a phone, with the light on: the relay had
    /// > stopped carrying the video and the sensor was still running.
    func resume()
}

/// A source someone else pushes into.
///
/// This is what a render callback talks to. ``submit(_:)`` is non-blocking and
/// callable from any thread or actor, which is not a convenience — RealityKit's
/// post-process callback runs every frame on the render thread and Apple's own
/// guidance is that nothing in it may do CPU work. A submit that could block,
/// allocate unboundedly, or hop actors would stall the display.
///
/// The buffer drops the *oldest* frame when full. That is the correct policy
/// for live media and the wrong one for a file: if the encoder has fallen
/// behind, the frames worth keeping are the recent ones, and a frame delivered
/// after its deadline is not late but worthless.
public final class FrameRelay: FrameSource, Sendable {
    public let captureFormat: CaptureFormat

    private let stream: AsyncStream<VideoFrame>
    private let continuation: AsyncStream<VideoFrame>.Continuation

    /// - Parameter depth: How many frames may queue before the oldest is
    ///   dropped. Three is about one display refresh of slack at 60fps; more
    ///   than that trades latency for smoothness in the wrong direction.
    public init(format: CaptureFormat, depth: Int = 3) {
        captureFormat = format
        (stream, continuation) = AsyncStream.makeStream(
            of: VideoFrame.self,
            bufferingPolicy: .bufferingNewest(max(1, depth))
        )
    }

    /// Hand a frame to the SDK. Safe from a render callback.
    public func submit(_ frame: VideoFrame) {
        continuation.yield(frame)
    }

    public func frames() -> AsyncStream<VideoFrame> { stream }

    public func stop() {
        continuation.finish()
    }

    /// Nothing to release: whoever is pushing owns whatever is producing.
    ///
    /// A renderer that keeps drawing keeps submitting, and those frames are
    /// dropped above rather than here — the publication is what knows it is
    /// muted. If the thing behind the renderer is a camera, pausing it is the
    /// app's to do, and only the app can.
    public func suspend() {}
    public func resume() {}
}

/// A source that produces nothing, for a publication that is authorised but not
/// yet live.
///
/// Promotion is an offer, never an act: a publish scope permits publishing and
/// does not start it. This is what a promoted guest holds until they choose to
/// go live.
public struct IdleFrameSource: FrameSource {
    public let captureFormat: CaptureFormat

    public init(format: CaptureFormat) {
        captureFormat = format
    }

    public func frames() -> AsyncStream<VideoFrame> {
        AsyncStream { $0.finish() }
    }

    public func stop() {}

    /// Produces nothing already, so there is nothing to hold or hand back.
    public func suspend() {}
    public func resume() {}
}
