// Running the sensor faster than the publication, and choosing which frames reach it.
//
// A sixty-frame publication does not need a sixty-frame sensor, and the difference is worth
// about eight milliseconds. A rolling shutter stamps a frame when it begins reading the first
// row and hands it over once it has read the last, so readout costs roughly one frame
// interval: sixteen milliseconds at sixty, eight at a hundred and twenty. Run the sensor at
// twice the publication rate, discard every other frame, and the frames that survive are half
// a readout younger. Nothing downstream is told anything — the encoder is still configured for
// sixty, the catalog still advertises sixty, and the frames are the same shape. Only their age
// changes.
//
// Worth doing because of where that time was going. Sensor-to-callback is charged to no stage
// by any figure the pipeline reports, so it lands inside sensor-to-arrival next to the encoder
// and the radio and reads as transport cost. Measured, it was the largest single term in the
// budget on both phones — thirty-one milliseconds on one and twenty-one on the other, against
// seven for the encoder and fifteen for the network.
//
// It is not free, and the cost is power rather than latency: the sensor reads twice as many
// rows and the image pipeline processes twice as many frames, half of which are thrown away.
// That is the whole trade, and it is why ``CaptureOversampling`` exists rather than this being
// unconditional.

import Foundation

/// Whether to run the sensor faster than the publication rate.
public enum CaptureOversampling: Sendable, Hashable {
    /// Run the sensor at the publication rate, as a camera normally does.
    ///
    /// The choice for a long broadcast from a phone in a pocket of warm air, and the one a
    /// thermal policy should make on its behalf: the latency this gives up is eight
    /// milliseconds, and what it buys back is half the sensor and image-pipeline work.
    case off

    /// Run the sensor at a whole multiple of the publication rate, up to twice, when the
    /// device offers one that costs no extra pixels and the publication is slow enough for it
    /// to be worth anything.
    ///
    /// The first two conditions are about what the device can do. A whole multiple is what
    /// makes the discard cadence exact — at ninety frames into sixty, every third frame is
    /// dropped and the survivors are unevenly spaced, which is worse to watch than the
    /// milliseconds are to wait. The pixel budget is what stops the faster mode being a bigger
    /// one: a device reaching a hundred and twenty only at 4K would spend the entire power
    /// saving of the capture ladder to buy a few milliseconds.
    ///
    /// The third condition is about what there is left to win, and it is the one the
    /// measurement changed. Sensor-to-callback is not the frame interval; on an iPhone 15 Pro
    /// it is a floor of about 15.5ms plus roughly a fifth of the interval, and only that
    /// second part is the sensor's to give back. Doubling the rate is therefore worth a great
    /// deal less than halving the interval suggests:
    ///
    ///     publish 30, sensor  30    19.6ms        publish 60, sensor  60    16.0ms
    ///     publish 30, sensor  60    15.9ms        publish 60, sensor 120    15.6ms
    ///
    /// Four milliseconds at thirty and four tenths at sixty, each the mean of four runs,
    /// alternated and repeated after a cooldown because the whole effect is smaller than the
    /// drift from a warming phone. So this declines above thirty frames a second rather than
    /// spending twice the sensor and image-pipeline power for a result inside the noise —
    /// which on a device already reporting serious thermal pressure is worse than nothing,
    /// since throttling costs frames and frames cost far more than four tenths of a
    /// millisecond.
    ///
    /// > Note: One phone. The floor is a property of a particular image pipeline and the
    /// > threshold follows from it, so a device whose floor is lower has more to gain here
    /// > than this will take.
    case automatic

    /// The largest multiple worth asking for when publishing at this rate.
    ///
    /// A rate rather than a constant because the answer depends on it — see ``automatic``, and
    /// the measurement quoted there for where the threshold comes from.
    func limit(publishing rate: Double) -> Int {
        switch self {
        case .off: 1
        case .automatic: rate <= 30.01 ? 2 : 1
        }
    }
}

/// The sensor rate behind a publication rate, and which captured frames belong to it.
struct CaptureCadence: Sendable {
    /// What the encoder is configured for, and what subscribers were promised.
    let publishRate: Double

    /// What the device was actually asked to run at.
    let sensorRate: Double

    /// The stamp of the last frame allowed through, on the sensor's own clock.
    private var lastDelivered: Double?

    init(publishing publishRate: Double, sensor sensorRate: Double) {
        self.publishRate = max(1, publishRate)
        self.sensorRate = max(self.publishRate, sensorRate)
    }

    /// How many captured frames there are per published one.
    var multiple: Int { Int((sensorRate / publishRate).rounded()) }

    /// Whether anything is being discarded at all.
    var oversamples: Bool { multiple > 1 }

    /// The shortest gap that counts as a whole publication interval.
    ///
    /// Half a sensor interval of slack, which is the only tolerance that works at every
    /// multiple. Three quarters of the publication interval is the obvious choice and is
    /// wrong above two: at four times the rate the fourth frame lands exactly on it and the
    /// publication comes out at eighty frames a second rather than sixty. Half a sensor
    /// interval sits midway between the frame that must be refused and the one that must be
    /// let through, wherever those two fall.
    private var threshold: Double {
        1 / publishRate - (1 / sensorRate) / 2
    }

    /// Whether the frame stamped at this time is one of the published ones.
    ///
    /// Decided on the stamps rather than by counting, because counting assumes the device
    /// delivered every frame it promised. It does not: a camera under system pressure drops
    /// frames on its own, and a counter that has lost one stays half a frame out of phase for
    /// the rest of the session, publishing at the right rate from the wrong instants. Timing
    /// re-phases on the next frame.
    mutating func delivers(at seconds: Double) -> Bool {
        guard oversamples else { return true }
        guard let last = lastDelivered else {
            lastDelivered = seconds
            return true
        }

        // A stamp that went backwards or jumped a long way is a discontinuity rather than a
        // gap — a session restarted after an interruption begins again on its own clock — and
        // decimating against a reference from before it would discard every frame until the
        // new clock caught up with the old one.
        let elapsed = seconds - last
        guard elapsed > 0, elapsed < 1 else {
            lastDelivered = seconds
            return true
        }

        guard elapsed >= threshold else { return false }
        lastDelivered = seconds
        return true
    }

    /// One of the device's formats, reduced to the two things the rate decision turns on.
    struct Option: Sendable, Equatable {
        let pixels: Int
        let lowestFrameRate: Double
        let highestFrameRate: Double

        init(pixels: Int, lowestFrameRate: Double, highestFrameRate: Double) {
            self.pixels = pixels
            self.lowestFrameRate = lowestFrameRate
            self.highestFrameRate = highestFrameRate
        }

        func supports(_ rate: Double) -> Bool {
            highestFrameRate + 0.01 >= rate && lowestFrameRate - 0.01 <= rate
        }
    }

    /// Which rate to ask the sensor for, given what the device offers.
    ///
    /// - Parameters:
    ///   - rate: The publication rate, which is what the caller asked for and what the
    ///     encoder will be built from.
    ///   - options: The formats already narrowed to those large enough for the request. Size
    ///     is settled first deliberately: judged against every format a device has, the
    ///     fastest is always some small high-speed mode, and the rate decision would quietly
    ///     become a resolution decision.
    ///   - limit: The largest multiple worth asking for. One declines the whole idea.
    /// - Returns: The publication rate, or a whole multiple of it the device can reach
    ///   without spending more pixels than the publication rate alone would have.
    static func sensorRate(publishing rate: Double, from options: [Option], limit: Int) -> Double {
        let rate = max(1, rate)
        guard limit > 1 else { return rate }

        // What the publication costs on its own, which is the budget the faster mode has to
        // fit inside rather than a number anybody reports.
        guard let budget = options.filter({ $0.supports(rate) }).map(\.pixels).min() else {
            return rate
        }

        for multiple in stride(from: limit, through: 2, by: -1) {
            let faster = rate * Double(multiple)
            if options.contains(where: { $0.supports(faster) && $0.pixels <= budget }) {
                return faster
            }
        }
        return rate
    }
}
