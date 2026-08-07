import Testing

@testable import MoqomKit

/// What decides how much audio waits in front of the speaker.
@Suite("Queue depth")
struct QueueDepthTests {
    /// Packets arriving evenly, one every twenty milliseconds. In whole milliseconds, so the
    /// cadence is exactly the cadence and an assertion about it is not an assertion about
    /// accumulated floating-point error.
    private func evenly(_ depth: inout QueueDepth, seconds: Int, from: Int = 0) {
        for at in stride(from: from * 1000, to: (from + seconds) * 1000, by: 20) {
            depth.fed(at: .milliseconds(at))
        }
    }

    @Test("an even feed asks for nothing beyond the link")
    func anEvenFeedCostsNothing() {
        var depth = QueueDepth()
        depth.aim(at: .milliseconds(40))
        evenly(&depth, seconds: 2)

        // Twenty milliseconds between arrivals is the packet cadence itself, well under the
        // forty the link already asked for, so the feed adds nothing.
        #expect(depth.covering <= .milliseconds(20))
        #expect(depth.target == .milliseconds(40))
    }

    @Test("a bursty feed is covered even when the link looks perfect")
    func coversTheGapsBetweenBursts() {
        // The measured failure: 4.1ms of link jitter, so the aim sat at its 40ms minimum,
        // while arrivals bunched into bursts 120ms apart. A queue sized at 40ms cannot play
        // through a 120ms silence, and it starved five hundred times trying.
        var depth = QueueDepth()
        depth.aim(at: .milliseconds(40))

        for burst in 0 ..< 20 {
            let start = Double(burst) * 0.12
            for packet in 0 ..< 6 {
                depth.fed(at: .seconds(start + Double(packet) * 0.001))
            }
        }

        #expect(depth.covering >= .milliseconds(100))
        #expect(depth.target >= .milliseconds(100))
    }

    @Test("a feed that settles gives the depth back")
    func forgetsABurstOnceItPasses() {
        var depth = QueueDepth()
        depth.aim(at: .milliseconds(40))

        depth.fed(at: .zero)
        depth.fed(at: .milliseconds(150))
        #expect(depth.covering >= .milliseconds(100))

        // Past the window, and the pause it was covering is no longer a fact about this link.
        // Fed evenly throughout rather than jumped over, because a jump is itself a pause and
        // would be covered, correctly, as one.
        evenly(&depth, seconds: 7, from: 1)
        #expect(depth.covering <= .milliseconds(20))
        #expect(depth.target == .milliseconds(40))
    }

    @Test("an even feed and a bunched one are told apart")
    func pacingSeparatesAStallFromABurst() {
        // The same worst pause, arrived at two ways, and the fix for one is no use against the
        // other: a stall wants explaining, while a link that is simply paced in bunches is not
        // malfunctioning at all and no amount of buffering addresses it.
        var stalling = QueueDepth()
        evenly(&stalling, seconds: 2)
        stalling.fed(at: .milliseconds(2100))

        var bunching = QueueDepth()
        for burst in 0 ..< 20 {
            for packet in 0 ..< 5 {
                bunching.fed(at: .milliseconds(burst * 100 + packet))
            }
        }

        #expect(stalling.covering >= .milliseconds(100))
        #expect(bunching.covering >= .milliseconds(90))

        // Which is the whole point: identical worst cases, opposite typical ones.
        #expect(stalling.pacing.typical == .milliseconds(20))
        #expect(bunching.pacing.typical <= .milliseconds(2))
    }

    /// Hold a depth for a stretch of time, at a packet cadence, returning the time reached.
    @discardableResult
    private func hold(
        _ depth: inout QueueDepth,
        _ queued: Duration,
        for span: Duration,
        from start: Duration = .zero,
        every cadence: Duration = .milliseconds(20)
    ) -> Duration {
        var now = start
        let end = start + span
        while now < end {
            depth.holding(queued, at: now)
            now += cadence
        }
        return now
    }

    @Test("what the picture is aligned to follows the depth actually held")
    func settlesOnTheRealDepth() {
        var depth = QueueDepth()
        hold(&depth, .milliseconds(120), for: .seconds(10))

        // The truth, which is what lip sync needs: the aim could read anything at all while the
        // queue really holds this.
        #expect(depth.settled == .milliseconds(120))
    }

    @Test("a transient nobody heard does not become a delay everybody sees")
    func ignoresASinglePause() {
        // The measured failure: one 200ms pause raised the target to 151ms, the video floor
        // followed it within the same second, and the picture kept the delay long after the
        // pause was over.
        var depth = QueueDepth()
        let after = hold(&depth, .milliseconds(60), for: .seconds(10))
        let before = depth.settled

        // A pause arrives, and for the second it lasts the queue really is deeper.
        hold(&depth, .milliseconds(260), for: .seconds(1), from: after)

        // The picture should not have noticed at all. One second of a five second window cannot
        // reach the middle of it, so the excursion is not merely damped, it is invisible — which
        // is the property an average could not give at any tuning.
        #expect(depth.settled == before)

        // And the conservative figure, which exists to react at once, must still have done so.
        depth.fed(at: .zero)
        depth.fed(at: .milliseconds(200))
        #expect(depth.target >= .milliseconds(150))
    }

    @Test("a burst cannot fill the window by arriving quickly")
    func aBurstCannotFloodTheWindow() {
        // The defect this replaced, and the reason the window is timed rather than counted. The
        // window was the last two hundred and fifty samples, called five seconds on the grounds
        // that packets arrive fifty a second — but in a burst they arrive as fast as they can be
        // read, so two hundred and fifty of them spanned a fraction of a second and the burst
        // became the whole window. Measured on a phone, `settled` read 260ms the moment the
        // queue hit 260, the picture's floor followed it for lip sync, and the video buffer
        // swung between 80ms and 250ms with it.
        var depth = QueueDepth()
        let after = hold(&depth, .milliseconds(60), for: .seconds(10))
        let before = depth.settled

        // Three hundred packets inside two hundred milliseconds of wall time. Under a counted
        // window that is more than the window holds; under a timed one it is a fiftieth of it.
        var now = after
        for _ in 0 ..< 300 {
            depth.holding(.milliseconds(260), at: now)
            now += .microseconds(666)
        }

        #expect(depth.settled == before)
    }

    @Test("a link that has genuinely changed is followed")
    func followsALastingChange() {
        var depth = QueueDepth()
        let after = hold(&depth, .milliseconds(60), for: .seconds(10))
        // More than half the window at the new depth, which is where the two requirements meet:
        // any excursion longer than this deserves following, and any shorter one does not.
        hold(&depth, .milliseconds(160), for: .seconds(3), from: after)
        #expect(depth.settled == .milliseconds(160))
    }

    @Test("one pause does not buy an unbounded queue")
    func capsWhatItWillCover() {
        var depth = QueueDepth()
        depth.fed(at: .zero)
        depth.fed(at: .seconds(2))
        #expect(depth.covering == QueueDepth.longestPauseWorthCovering)
    }

    @Test("the two measurements are not paid for twice")
    func takesTheLargerRatherThanTheSum() {
        // Both describe the same packets arriving, seen two ways. A queue holding their sum
        // would be holding the same delay twice over, which is latency for nothing.
        var depth = QueueDepth()
        depth.aim(at: .milliseconds(120))
        depth.fed(at: .zero)
        depth.fed(at: .milliseconds(80))

        #expect(depth.covering == .milliseconds(80))
        #expect(depth.target == .milliseconds(120))
    }

    @Test("a device that runs dry is answered whatever the network says")
    func pressureAnswersTheDeviceAlone() {
        var depth = QueueDepth()
        depth.aim(at: .milliseconds(40))
        evenly(&depth, seconds: 2)
        #expect(depth.target == .milliseconds(40))

        // Priming: the device asks for samples before the room sends any, and that is not a
        // queue that was too shallow.
        depth.answer(starved: 4, whileSpeaking: true)
        #expect(depth.target == .milliseconds(40))

        for starved in 5 ... 8 {
            depth.answer(starved: starved, whileSpeaking: true)
        }
        #expect(depth.target > .milliseconds(40))
    }

    @Test("running dry in a silence is not evidence of anything")
    func silenceDoesNotDeepenTheQueue() {
        // A ring that empties while nobody is talking has cost the listener nothing, and
        // buying insurance against it means a permanently deeper queue for a pause.
        var depth = QueueDepth()
        depth.aim(at: .milliseconds(40))
        depth.answer(starved: 1, whileSpeaking: false)
        for starved in 2 ... 20 {
            depth.answer(starved: starved, whileSpeaking: false)
        }
        #expect(depth.target == .milliseconds(40))
    }
}
