// Reading the time off an NTP server, as bytes.
//
// Deliberately separate from the socket that carries them. The parsing is where
// the mistakes live — an era boundary in 2036, a fixed-point field read as an
// integer, a response accepted because nobody checked it was a response — and
// none of those need a network to reproduce. What is left in ``NTPAuthority``
// once this is lifted out is a send and a receive.
//
// # What is trusted here, and what is not
//
// Plain NTP is unauthenticated. A packet claiming to be from the server is
// accepted on the strength of arriving, which means anyone able to *see* the
// request can forge a reply and move a client's timeline wherever they like.
// For an audit log that is exactly the attack that matters.
//
// Two things narrow it. The transmit timestamp is a random nonce rather than a
// clock reading, and a reply whose origin field does not echo it is discarded —
// which closes off every attacker who cannot see the request, and that is most
// of them. And ``TrustedClock`` will not let one reply move an established
// estimate: a sample that disagrees wildly with the ones around it is refused
// rather than adopted.
//
// What remains open is an attacker sitting on the path. The fix for that is
// Network Time Security (RFC 8915), which Cloudflare serves on the same
// hostname — a TLS key exchange on port 4460, then the same NTP packets with
// authenticated extension fields. It is a real piece of work and it is not
// here yet, which is a gap worth stating plainly rather than implying that
// "uses NTP over the internet" and "trusted" are the same claim.

import Foundation
import MoqomCore

/// What the server says about leap seconds and its own health.
public enum NTPLeap: UInt8, Hashable, Sendable {
    case none = 0

    /// A leap second is being inserted at the end of the current UTC day.
    case addSecond = 1

    /// A leap second is being removed at the end of the current UTC day.
    case deleteSecond = 2

    /// The server's own clock is not synchronised. Its timestamps mean nothing.
    case unsynchronised = 3

    /// Whether a leap is pending, which makes UTC ambiguous by a second.
    ///
    /// Cloudflare does not smear leap seconds — it passes this flag through and
    /// expects the kernel to step — so a client reading it has to widen rather
    /// than pretend the timeline is continuous across the boundary.
    public var isPending: Bool { self == .addSecond || self == .deleteSecond }
}

/// Why a reply could not be used.
public enum NTPFailure: Error, Hashable, Sendable {
    /// Too short, or a version and mode that are not a server's reply.
    case malformed

    /// The origin timestamp did not echo the nonce that was sent.
    ///
    /// Either a stale reply to an earlier request, or somebody guessing.
    case impostor

    /// The server is telling us to go away, with a four-letter reason.
    ///
    /// `RATE` means we polled too fast, `DENY` and `RSTR` mean we are not
    /// welcome. A client that ignores this is abusing a free public service,
    /// so it is surfaced as a distinct failure rather than folded into the rest.
    case kissOfDeath(String)

    /// The server admits its own clock is adrift.
    case unsynchronised
}

/// One usable reply.
public struct NTPReading: Hashable, Sendable {
    /// Server time when the request arrived, nanoseconds since the Unix epoch.
    public let receivedAt: Int64

    /// Server time when the reply left.
    public let repliedAt: Int64

    /// How far this server is from a real reference clock, as an error bound.
    ///
    /// RFC 5905 calls it the root distance: half the round-trip delay to the
    /// primary reference plus the accumulated dispersion. It is the server
    /// stating its own uncertainty, and passing it on is what stops the client
    /// treating a stratum-4 box on a congested link as if it were a caesium
    /// standard in the same rack.
    public let rootDistance: Duration

    public let leap: NTPLeap

    /// Distance from a reference clock in hops. 1 is directly attached.
    public let stratum: UInt8
}

/// The 48 bytes an SNTP exchange is made of.
public enum NTPPacket {
    /// Seconds between the NTP epoch (1900) and the Unix epoch (1970).
    static let epochOffset: Int64 = 2_208_988_800

    /// Unix seconds at which NTP's 32-bit second counter wraps, in 2036.
    ///
    /// The counter is not going to be widened before then, so a reading with
    /// the high bit clear is not 1900, it is the era after the wrap. Handling
    /// it costs three lines now and is unfixable in the field later.
    static let eraTwoOffset: Int64 = 2_085_978_496

    public static let length = 48

    /// A client request carrying a nonce where the timestamp would go.
    ///
    /// The transmit field is specified as the client's own clock, and every
    /// implementation that puts one there hands an off-path attacker the value
    /// it must echo to be believed. A random one costs nothing and is what the
    /// hardening advice for unauthenticated NTP has said for years.
    public static func request(nonce: UInt64) -> Data {
        var packet = Data(count: length)
        // Leap 0, version 4, mode 3 (client).
        packet[0] = 0b00_100_011
        withUnsafeBytes(of: nonce.bigEndian) { bytes in
            packet.replaceSubrange(40 ..< 48, with: bytes)
        }
        return packet
    }

    /// Read a reply, refusing anything that is not one.
    public static func read(_ data: Data, nonce: UInt64) throws(NTPFailure) -> NTPReading {
        guard data.count >= length else { throw NTPFailure.malformed }
        let bytes = [UInt8](data)

        let leap = NTPLeap(rawValue: (bytes[0] & 0b1100_0000) >> 6) ?? .unsynchronised
        let version = (bytes[0] & 0b0011_1000) >> 3
        let mode = bytes[0] & 0b0000_0111

        // Mode 4 is a server's reply to a client. Mode 5 is a broadcast, which
        // is unsolicited by definition and must never be treated as an answer
        // to anything we asked.
        guard mode == 4, version == 3 || version == 4 else { throw NTPFailure.malformed }

        let stratum = bytes[1]
        if stratum == 0 {
            // The reference ID carries four ASCII characters instead of an
            // address when the stratum is zero.
            let code = String(decoding: bytes[12 ..< 16], as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            throw NTPFailure.kissOfDeath(code)
        }
        guard leap != .unsynchronised, stratum <= 15 else { throw NTPFailure.unsynchronised }

        // Checked before the timestamps are believed, not after.
        let origin = integer(bytes, at: 24)
        guard origin == nonce else { throw NTPFailure.impostor }

        return NTPReading(
            receivedAt: unixNanoseconds(integer(bytes, at: 32)),
            repliedAt: unixNanoseconds(integer(bytes, at: 40)),
            rootDistance: short(bytes, at: 4) / 2 + short(bytes, at: 8),
            leap: leap,
            stratum: stratum
        )
    }

    /// Convert NTP's 64-bit timestamp to nanoseconds since the Unix epoch.
    ///
    /// The top 32 bits are seconds since 1900 and the bottom 32 a binary
    /// fraction of a second.
    static func unixNanoseconds(_ timestamp: UInt64) -> Int64 {
        let seconds = Int64(timestamp >> 32)
        let fraction = timestamp & 0xFFFF_FFFF

        // Bit 0 of the seconds field distinguishes the eras (RFC 4330 §3): set
        // means 1968–2036 counted from 1900, clear means 2036 onwards.
        let unixSeconds = seconds & 0x8000_0000 != 0
            ? seconds - epochOffset
            : seconds + eraTwoOffset

        // The fraction is a binary fraction, so scaling is a multiply and a
        // shift rather than a divide by a decimal power.
        let nanoseconds = Int64((fraction &* 1_000_000_000) >> 32)
        return unixSeconds &* 1_000_000_000 &+ nanoseconds
    }

    /// Read one of NTP's 16.16 fixed-point "short format" fields.
    private static func short(_ bytes: [UInt8], at offset: Int) -> Duration {
        var raw: UInt32 = 0
        for index in 0 ..< 4 { raw = raw << 8 | UInt32(bytes[offset + index]) }
        // 16 bits of seconds and 16 of fraction, so a billion nanoseconds is
        // one unit of 65536.
        return .nanoseconds(Int64(raw) * 1_000_000_000 / 65536)
    }

    private static func integer(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        var raw: UInt64 = 0
        for index in 0 ..< 8 { raw = raw << 8 | UInt64(bytes[offset + index]) }
        return raw
    }
}
