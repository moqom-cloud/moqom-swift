// Time, which fails quietly.
//
// A broken clock does not throw. It returns a number that looks exactly like a
// working one, and the damage shows up much later as a recording that will not
// align or an audit log whose order is wrong. So the tests here are mostly not
// "does it produce a timestamp" — they are the specific ways a time client is
// wrong while looking right: a path that is fast one way and slow the other, a
// device that slept through its own sync, a reply somebody else wrote, a field
// read as an integer when it is a fraction, and the two seconds in a decade
// when UTC itself is ambiguous.

import Foundation
import MoqomCore
import Testing

@testable import MoqomKit

@Suite("Trusted time")
struct TrustedTimeTests {
    // MARK: - Reading the wire

    @Test("A request carries a nonce where the clock would go")
    func requestIsNonced() throws {
        let packet = NTPPacket.request(nonce: 0x0123_4567_89AB_CDEF)
        #expect(packet.count == NTPPacket.length)
        // Leap 0, version 4, mode 3.
        #expect(packet[0] == 0b00_100_011)
        #expect([UInt8](packet[40 ..< 48]) == [0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF])

        // Everything a client is nominally allowed to fill in stays zero. The
        // point of the nonce is that the packet reveals nothing about our clock.
        #expect([UInt8](packet[1 ..< 40]).allSatisfy { $0 == 0 })
    }

    @Test("A well formed reply yields the server's two timestamps")
    func readsTimestamps() throws {
        let received = Int64(1_800_000_000_000_000_000)
        let replied = received + 250_000
        let reading = try NTPPacket.read(
            Wire.reply(nonce: 7, receivedAt: received, repliedAt: replied),
            nonce: 7
        )

        // Nanosecond exactness is not available: NTP's fraction is 1/2^32 of a
        // second, so a round trip through it lands within a nanosecond or so.
        #expect(abs(reading.receivedAt - received) <= 1)
        #expect(abs(reading.repliedAt - replied) <= 1)
        #expect(reading.leap == .none)
    }

    @Test("Root distance is half the delay plus the dispersion")
    func rootDistance() throws {
        let reading = try NTPPacket.read(
            Wire.reply(
                nonce: 1,
                receivedAt: 1_800_000_000_000_000_000,
                repliedAt: 1_800_000_000_000_000_000,
                rootDelay: .milliseconds(40),
                rootDispersion: .milliseconds(5)
            ),
            nonce: 1
        )
        // 20ms + 5ms, within the 16.16 fixed point format's resolution.
        #expect(gap(reading.rootDistance, .milliseconds(25)) < .microseconds(50))
    }

    @Test("Timestamps after 2036 are read in the right era")
    func eraRollover() {
        // The last second before NTP's 32-bit second counter wraps, and the
        // first after. Read naively, the second one is 1900.
        let boundary: Int64 = 2_085_978_496
        #expect(NTPPacket.unixNanoseconds(0xFFFF_FFFF_0000_0000) / 1_000_000_000 == boundary - 1)
        #expect(NTPPacket.unixNanoseconds(0x0000_0000_0000_0000) / 1_000_000_000 == boundary)
        #expect(NTPPacket.unixNanoseconds(0x0000_0001_0000_0000) / 1_000_000_000 == boundary + 1)
    }

    @Test("A reply that does not echo the nonce is refused")
    func refusesImpostor() {
        let forged = Wire.reply(nonce: 999, receivedAt: 1, repliedAt: 2)
        #expect(throws: NTPFailure.impostor) {
            try NTPPacket.read(forged, nonce: 7)
        }
    }

    @Test("A broadcast is not an answer to anything we asked")
    func refusesBroadcast() {
        // Mode 5 with the right nonce: an attacker who saw the request cannot
        // get in this way either.
        let broadcast = Wire.reply(nonce: 7, receivedAt: 1, repliedAt: 2, mode: 5)
        #expect(throws: NTPFailure.malformed) {
            try NTPPacket.read(broadcast, nonce: 7)
        }
    }

    @Test("A kiss of death is surfaced with its reason")
    func kissOfDeath() {
        let kiss = Wire.reply(nonce: 7, receivedAt: 1, repliedAt: 2, stratum: 0, reference: "RATE")
        #expect(throws: NTPFailure.kissOfDeath("RATE")) {
            try NTPPacket.read(kiss, nonce: 7)
        }
    }

    @Test("A server that admits it is adrift is not believed")
    func refusesUnsynchronised() {
        let adrift = Wire.reply(nonce: 7, receivedAt: 1, repliedAt: 2, leap: .unsynchronised)
        #expect(throws: NTPFailure.unsynchronised) {
            try NTPPacket.read(adrift, nonce: 7)
        }
    }

    @Test("A truncated packet is refused rather than read past")
    func refusesTruncated() {
        let short = Wire.reply(nonce: 7, receivedAt: 1, repliedAt: 2).prefix(40)
        #expect(throws: NTPFailure.malformed) {
            try NTPPacket.read(short, nonce: 7)
        }
    }

    // MARK: - Talking to the server

    @Test("A lost datagram is retried once")
    func retriesOnce() async throws {
        let socket = FlakySocket(dropping: 1)
        let authority = NTPAuthority(exchange: socket, nonces: { 7 })
        _ = try await authority.read()
        #expect(await socket.attempts == 2)
    }

    @Test("Being told to go away silences the client")
    func honoursKissOfDeath() async throws {
        let socket = RudeSocket()
        let authority = NTPAuthority(exchange: socket, nonces: { 7 })

        await #expect(throws: MoqomError.self) { try await authority.read() }
        #expect(await socket.attempts == 1, "a refusal is not something to retry")

        // And every later attempt is refused locally, without a packet.
        await #expect(throws: MoqomError.self) { try await authority.read() }
        #expect(await socket.attempts == 1)
    }

    // MARK: - Holding the timeline

    @Test("Before the first exchange, nothing claims to be synchronised")
    func startsUntrusted() async {
        let ticker = Ticker()
        let clock = TrustedClock(
            authority: ScriptedAuthority(ticker: ticker, epoch: Wire.epoch),
            continuous: ticker.continuous,
            suspending: ticker.suspending
        )
        let now = await clock.now()
        #expect(!now.isTrusted)
        #expect(now.trust == .fallback)
        // Wide enough that nothing will accidentally be ordered by it.
        #expect(now.uncertainty > .seconds(60))
    }

    @Test("One exchange puts the device on the server's timeline")
    func synchronises() async {
        let ticker = Ticker()
        let authority = ScriptedAuthority(ticker: ticker, epoch: Wire.epoch)
        let clock = TrustedClock(
            authority: authority,
            continuous: ticker.continuous,
            suspending: ticker.suspending
        )
        await authority.expect(out: .milliseconds(20), back: .milliseconds(20))
        #expect(await clock.synchronise())

        let now = await clock.now()
        #expect(now.trust == .synchronised)
        #expect(Duration.nanoseconds(abs(now.nanoseconds - ticker.trueTime())) < .milliseconds(2))
        // Half the round trip, which is the honest bound on a symmetric path.
        #expect(now.uncertainty < .milliseconds(25))
    }

    @Test("A one-sided path does not drag the estimate with it")
    func survivesAsymmetry() async {
        let ticker = Ticker()
        let authority = ScriptedAuthority(ticker: ticker, epoch: Wire.epoch)
        let clock = TrustedClock(
            authority: authority,
            continuous: ticker.continuous,
            suspending: ticker.suspending
        )

        // A badly asymmetric exchange first: 10ms out, 190ms back. Its midpoint
        // estimate is 90ms early and nothing in the sample itself says so.
        await authority.expect(out: .milliseconds(10), back: .milliseconds(190))
        #expect(await clock.synchronise())
        let skewed = await clock.now()
        #expect(Duration.nanoseconds(abs(skewed.nanoseconds - ticker.trueTime())) > .milliseconds(50))
        // But it does not claim to be better than it is: the truth is inside
        // the interval it reports, which is the whole point of carrying one.
        #expect(skewed.uncertainty > .milliseconds(85))

        // Then a clean one. The shorter round trip wins and the error collapses.
        await authority.expect(out: .milliseconds(15), back: .milliseconds(15))
        #expect(await clock.synchronise())
        let settled = await clock.now()
        #expect(Duration.nanoseconds(abs(settled.nanoseconds - ticker.trueTime())) < .milliseconds(2))
    }

    @Test("Sleeping through a sync widens the reading instead of breaking it")
    func survivesSleep() async {
        let ticker = Ticker()
        let authority = ScriptedAuthority(ticker: ticker, epoch: Wire.epoch)
        let clock = TrustedClock(
            authority: authority,
            continuous: ticker.continuous,
            suspending: ticker.suspending
        )
        await authority.expect(out: .milliseconds(10), back: .milliseconds(10))
        #expect(await clock.synchronise())

        // An hour in a pocket. The suspending clock does not advance, which is
        // exactly what would make a naive implementation report an hour ago.
        ticker.sleep(for: .seconds(3600))

        // The estimate survives the nap: a suspending clock would have it an
        // hour in the past, confidently.
        let hour = await clock.now()
        #expect(Duration.nanoseconds(abs(hour.nanoseconds - ticker.trueTime())) < .milliseconds(5))

        // And it is honest about having aged. An hour at 100ppm is 360ms, which
        // is degraded but still inside the ceiling.
        #expect(hour.uncertainty > .milliseconds(300))
        #expect(hour.uncertainty < .milliseconds(400))
        #expect(hour.trust == .synchronised)

        // Long enough and it stops claiming to be synchronised at all, which is
        // the ceiling doing its job rather than an age limit doing it.
        ticker.sleep(for: .seconds(4 * 3600))
        let later = await clock.now()
        #expect(later.uncertainty > TrustedClock.trustCeiling)
        #expect(later.trust == .fallback)
    }

    @Test("Uncertainty grows with the time since the last exchange")
    func uncertaintyGrows() async {
        let ticker = Ticker()
        let authority = ScriptedAuthority(ticker: ticker, epoch: Wire.epoch)
        let clock = TrustedClock(
            authority: authority,
            continuous: ticker.continuous,
            suspending: ticker.suspending
        )
        await authority.expect(out: .milliseconds(5), back: .milliseconds(5))
        #expect(await clock.synchronise())

        let fresh = await clock.now().uncertainty
        ticker.advance(.seconds(60))
        let stale = await clock.now().uncertainty
        #expect(stale > fresh)
        // 60s at 100ppm is 6ms.
        #expect(gap(stale - fresh, .milliseconds(6)) < .milliseconds(1))
    }

    @Test("One forged reply cannot move the timeline")
    func refusesASingleLie() async {
        let ticker = Ticker()
        let authority = ScriptedAuthority(ticker: ticker, epoch: Wire.epoch)
        let clock = TrustedClock(
            authority: authority,
            continuous: ticker.continuous,
            suspending: ticker.suspending
        )
        for _ in 0 ..< 2 {
            await authority.expect(out: .milliseconds(10), back: .milliseconds(10))
            #expect(await clock.synchronise())
        }
        let before = await clock.now()

        // Somebody answers for the server, an hour off.
        await authority.shift(by: .seconds(3600))
        await authority.expect(out: .milliseconds(10), back: .milliseconds(10))
        #expect(await clock.synchronise())

        let after = await clock.now()
        let moved = Duration.nanoseconds(abs(after.nanoseconds - before.nanoseconds))
        #expect(moved < .seconds(1), "a lone disagreeing reply was adopted")
    }

    @Test("Two exchanges that agree are believed, even against the history")
    func acceptsACorroboratedStep() async {
        let ticker = Ticker()
        let authority = ScriptedAuthority(ticker: ticker, epoch: Wire.epoch)
        let clock = TrustedClock(
            authority: authority,
            continuous: ticker.continuous,
            suspending: ticker.suspending
        )
        await authority.expect(out: .milliseconds(10), back: .milliseconds(10))
        #expect(await clock.synchronise())

        // The server really has moved — our own earlier anchor was the wrong
        // one — and it keeps saying so.
        let step = Duration.seconds(3600)
        await authority.shift(by: step)
        for _ in 0 ..< 2 {
            await authority.expect(out: .milliseconds(10), back: .milliseconds(10))
            #expect(await clock.synchronise())
        }

        // The server's timeline is now the ticker plus the step, and that is
        // what the device should be reading.
        let now = await clock.now()
        let truth = ticker.trueTime() &+ step.wholeNanoseconds
        #expect(Duration.nanoseconds(abs(now.nanoseconds - truth)) < .milliseconds(50))
        #expect(now.trust == .synchronised)
    }

    @Test("A pending leap second widens the reading once it lands")
    func widensAcrossALeap() async {
        let ticker = Ticker()
        // Thirty seconds before a UTC midnight, which is where a leap goes.
        let midnight = Wire.epoch / 86_400_000_000_000 * 86_400_000_000_000 + 86_400_000_000_000
        let authority = ScriptedAuthority(ticker: ticker, epoch: midnight - 30_000_000_000)
        let clock = TrustedClock(
            authority: authority,
            continuous: ticker.continuous,
            suspending: ticker.suspending
        )
        await authority.warnOfLeap()
        await authority.expect(out: .milliseconds(5), back: .milliseconds(5))
        #expect(await clock.synchronise())

        // Still before the boundary: the warning alone changes nothing, because
        // the timeline is not yet ambiguous.
        let before = await clock.now()
        #expect(before.trust == .synchronised)
        #expect(before.uncertainty < .milliseconds(50))

        // Past it, and UTC has repeated or skipped a second under us.
        ticker.advance(.seconds(60))
        let after = await clock.now()
        #expect(after.uncertainty > .seconds(1))
        #expect(after.trust == .fallback)
    }

    // MARK: - Saying so

    @Test("Losing trusted time is announced, not just recorded")
    func announcesTheFallback() async {
        // The failure this guards against is silence. `now()` keeps returning a
        // plausible instant when the reference is unreachable, and every
        // consumer that does not inspect `trust` carries on as if nothing
        // happened — so if nobody says it out loud, the first anyone knows is a
        // recording that will not align weeks later.
        let sink = RecordingLogSink()
        let logger = MoqomLogger(sink: sink, minimum: .debug)
        let ticker = Ticker()
        let authority = ScriptedAuthority(ticker: ticker, epoch: Wire.epoch)
        let clock = TrustedClock(
            authority: authority,
            logger: logger,
            continuous: ticker.continuous,
            suspending: ticker.suspending
        )

        await authority.expect(out: .milliseconds(5), back: .milliseconds(5))
        #expect(await clock.synchronise())
        #expect(sink.messages.contains("trusted time established"))
        #expect(!(await clock.isUsingFallback))

        // Long enough that the estimate decays past the ceiling. The device has
        // not failed and the server has not lied; the reading has simply
        // stopped being worth anything.
        sink.clear()
        ticker.sleep(for: .seconds(4 * 3600))

        // A failed exchange, which is what a real device sees when the network
        // is gone. The previous anchor is kept, not discarded.
        #expect(!(await clock.synchronise()))

        #expect(await clock.isUsingFallback)
        #expect(sink.messages.contains("trusted time lost, using the device clock"))
        let warning = sink.records.first { $0.message.hasPrefix("trusted time lost") }
        #expect(warning?.level == .warning, "a silent fallback is the thing being prevented")
    }

    @Test("The announcement is made once, not on every exchange")
    func doesNotRepeatTheAnnouncement() async {
        // A clock that logs its state every poll buries the transition that
        // matters in a stream of identical lines.
        let sink = RecordingLogSink()
        let logger = MoqomLogger(sink: sink, minimum: .debug)
        let ticker = Ticker()
        let authority = ScriptedAuthority(ticker: ticker, epoch: Wire.epoch)
        let clock = TrustedClock(
            authority: authority,
            logger: logger,
            continuous: ticker.continuous,
            suspending: ticker.suspending
        )

        for _ in 0 ..< 4 {
            await authority.expect(out: .milliseconds(5), back: .milliseconds(5))
            #expect(await clock.synchronise())
        }

        let announcements = sink.messages.filter { $0 == "trusted time established" }
        #expect(announcements.count == 1, "said \(announcements.count) times")
    }

    @Test("Coming back is announced too")
    func announcesRecovery() async {
        let sink = RecordingLogSink()
        let logger = MoqomLogger(sink: sink, minimum: .debug)
        let ticker = Ticker()
        let authority = ScriptedAuthority(ticker: ticker, epoch: Wire.epoch)
        let clock = TrustedClock(
            authority: authority,
            logger: logger,
            continuous: ticker.continuous,
            suspending: ticker.suspending
        )

        // No exchange queued, so the first attempt fails and the clock is on
        // fallback time from the start.
        #expect(!(await clock.synchronise()))
        #expect(await clock.isUsingFallback)

        sink.clear()
        await authority.expect(out: .milliseconds(5), back: .milliseconds(5))
        #expect(await clock.synchronise())

        #expect(!(await clock.isUsingFallback))
        #expect(sink.messages.contains("trusted time established"))
    }

    @Test("A fallback timecode is honest about being one")
    func fallbackDescribesItself() {
        let code = Timecode.fallback(Date(timeIntervalSince1970: 1_800_000_000))

        #expect(code.trust == .fallback)
        #expect(!code.isTrusted)
        // A device clock is a user setting and can be wrong by years. A bound
        // that implied otherwise would be the lie the type exists to stop.
        #expect(code.uncertainty > .seconds(3600))
        // And it says so where a human will see it.
        #expect(code.description.contains("fallback"))
    }

    // MARK: - Ordering

    @Test("Two readings that overlap are not ordered")
    func refusesToOrderOverlap() {
        let early = Timecode(nanoseconds: 1_000_000_000, uncertainty: .milliseconds(50), trust: .synchronised)
        let late = Timecode(nanoseconds: 1_020_000_000, uncertainty: .milliseconds(50), trust: .synchronised)

        // 20ms apart with 50ms of slop either side: the second may well have
        // happened first, and saying otherwise is the bug this type exists for.
        #expect(!early.definitelyPrecedes(late))
        #expect(!late.definitelyPrecedes(early))
        #expect(early.mayCoincide(with: late))
    }

    @Test("Two readings that do not overlap are ordered")
    func ordersDisjoint() {
        let early = Timecode(nanoseconds: 1_000_000_000, uncertainty: .milliseconds(5), trust: .synchronised)
        let late = Timecode(nanoseconds: 1_020_000_000, uncertainty: .milliseconds(5), trust: .synchronised)
        #expect(early.definitelyPrecedes(late))
        #expect(!late.definitelyPrecedes(early))
        #expect(!early.mayCoincide(with: late))
    }
}

// MARK: - Doubles

/// Absolute difference, since `Duration` is not `SignedNumeric`.
private func gap(_ left: Duration, _ right: Duration) -> Duration {
    left > right ? left - right : right - left
}

/// Builds the bytes a server would send.
private enum Wire {
    /// An arbitrary but realistic instant, used as the server's clock.
    static let epoch: Int64 = 1_800_000_000_000_000_000

    static func reply(
        nonce: UInt64,
        receivedAt: Int64,
        repliedAt: Int64,
        leap: NTPLeap = .none,
        stratum: UInt8 = 3,
        rootDelay: Duration = .milliseconds(10),
        rootDispersion: Duration = .milliseconds(5),
        mode: UInt8 = 4,
        version: UInt8 = 4,
        reference: String = "GPS "
    ) -> Data {
        var packet = Data(count: NTPPacket.length)
        packet[0] = leap.rawValue << 6 | version << 3 | mode
        packet[1] = stratum
        write(short(rootDelay), to: &packet, at: 4)
        write(short(rootDispersion), to: &packet, at: 8)
        packet.replaceSubrange(12 ..< 16, with: Array(reference.utf8.prefix(4)))
        write64(nonce, to: &packet, at: 24)
        write64(timestamp(receivedAt), to: &packet, at: 32)
        write64(timestamp(repliedAt), to: &packet, at: 40)
        return packet
    }

    /// Unix nanoseconds to NTP's 64-bit fixed point, era zero.
    static func timestamp(_ nanoseconds: Int64) -> UInt64 {
        let seconds = nanoseconds / 1_000_000_000
        let remainder = nanoseconds % 1_000_000_000
        let ntpSeconds = UInt64(seconds + NTPPacket.epochOffset)
        let fraction = UInt64(remainder) << 32 / 1_000_000_000
        return ntpSeconds << 32 | fraction
    }

    static func short(_ duration: Duration) -> UInt32 {
        UInt32(duration.wholeNanoseconds * 65536 / 1_000_000_000)
    }

    static func write(_ value: UInt32, to data: inout Data, at offset: Int) {
        withUnsafeBytes(of: value.bigEndian) { data.replaceSubrange(offset ..< offset + 4, with: $0) }
    }

    static func write64(_ value: UInt64, to data: inout Data, at offset: Int) {
        withUnsafeBytes(of: value.bigEndian) { data.replaceSubrange(offset ..< offset + 8, with: $0) }
    }
}

/// A clock the test drives by hand.
///
/// Two readings rather than one, because the difference between them *is* the
/// sleep detector under test.
private final class Ticker: @unchecked Sendable {
    private let lock = NSLock()
    private var running: Duration = .zero
    private var awake: Duration = .zero
    private var base: Int64 = 0

    var continuous: @Sendable () -> Duration {
        { [self] in lock.withLock { running } }
    }

    var suspending: @Sendable () -> Duration {
        { [self] in lock.withLock { awake } }
    }

    func advance(_ interval: Duration) {
        lock.withLock {
            running += interval
            awake += interval
        }
    }

    /// Time passing while the device is suspended: only one clock notices.
    func sleep(for interval: Duration) {
        lock.withLock { running += interval }
    }

    func anchor(_ epoch: Int64) {
        lock.withLock { base = epoch }
    }

    /// What the server's clock genuinely reads right now.
    func trueTime() -> Int64 {
        lock.withLock { base &+ running.wholeNanoseconds }
    }
}

/// An authority whose network delays and honesty the test chooses.
private actor ScriptedAuthority: TimeAuthority {
    private let ticker: Ticker
    private var legs: [(out: Duration, back: Duration)] = []
    private var shift: Duration = .zero
    private var leap = false

    init(ticker: Ticker, epoch: Int64) {
        self.ticker = ticker
        ticker.anchor(epoch)
    }

    /// Queue the next exchange's one-way delays.
    func expect(out: Duration, back: Duration) {
        legs.append((out, back))
    }

    /// Start answering with a clock this far from the truth.
    func shift(by interval: Duration) {
        shift = interval
    }

    func warnOfLeap() {
        leap = true
    }

    func read() async throws(MoqomError) -> AuthorityReading {
        guard !legs.isEmpty else { throw MoqomError.transport(.unreachable) }
        let leg = legs.removeFirst()

        ticker.advance(leg.out)
        let arrived = ticker.trueTime() &+ shift.wholeNanoseconds
        ticker.advance(leg.back)

        return AuthorityReading(
            receivedAt: arrived,
            repliedAt: arrived,
            uncertainty: .zero,
            isDisciplined: true,
            leapSecondPending: leap
        )
    }
}

/// A socket that loses the first few datagrams.
private actor FlakySocket: DatagramExchange {
    private(set) var attempts = 0
    private var remaining: Int

    init(dropping: Int) {
        remaining = dropping
    }

    func exchange(_ request: Data, timeout _: Duration) async throws(MoqomError) -> Data {
        attempts += 1
        if remaining > 0 {
            remaining -= 1
            throw MoqomError.transport(.idleTimeout)
        }
        let nonce = request.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 40, as: UInt64.self) }
        return Wire.reply(
            nonce: UInt64(bigEndian: nonce),
            receivedAt: Wire.epoch,
            repliedAt: Wire.epoch
        )
    }
}

/// A socket whose server has had enough of us.
private actor RudeSocket: DatagramExchange {
    private(set) var attempts = 0

    func exchange(_ request: Data, timeout _: Duration) async throws(MoqomError) -> Data {
        attempts += 1
        let nonce = request.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 40, as: UInt64.self) }
        return Wire.reply(
            nonce: UInt64(bigEndian: nonce),
            receivedAt: Wire.epoch,
            repliedAt: Wire.epoch,
            stratum: 0,
            reference: "RATE"
        )
    }
}
