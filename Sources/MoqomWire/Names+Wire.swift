// Wire encoding for the name types, which live in MoqomCore because the room
// model is built out of them.
//
// One divergence from `rs/moqom-proto` is deliberate and worth stating where
// someone debugging an interop failure will find it. The Rust side stores
// namespace fields as raw bytes, because a relay never interprets them. This
// side stores `String` and canonicalises to NFC on construction, because every
// namespace a client builds comes from a username or a room ID and "é" typed on
// iOS arrives decomposed often enough to matter.
//
// The consequence: decoding a namespace whose fields are not already NFC and
// re-encoding it does not reproduce the original bytes, and the protocol
// compares namespaces bytewise. Every namespace MOQOM itself puts on the wire
// is NFC, because it went through these types on the way out, so this is only
// reachable with a third-party publisher that sends decomposed UTF-8 — at which
// point that publisher's namespace and ours were never going to match anyway.
// `namespaceRoundTripsWhenAlreadyCanonical` pins the property that does hold.

import Foundation
import MoqomCore

public extension TrackNamespace {
    /// Field count, then each field as a length-prefixed byte string.
    var encodedLength: Int {
        WireSize.varInt(UInt64(count))
            + fields.reduce(0) { $0 + WireSize.lengthPrefixed($1) }
    }

    func write(to writer: inout WireWriter) {
        writer.varInt(UInt64(count))
        for field in fields {
            writer.lengthPrefixed(field)
        }
    }

    static func read(from reader: inout WireReader) throws(WireError) -> TrackNamespace {
        let count = try reader.varInt()
        guard count <= UInt64(maximumNamespaceFields) else {
            throw WireError.invalid("namespace has more than \(maximumNamespaceFields) fields")
        }

        var fields: [String] = []
        fields.reserveCapacity(Int(count))
        for _ in 0 ..< count {
            fields.append(try reader.lengthPrefixedString())
        }

        do {
            return try TrackNamespace(fields)
        } catch {
            throw WireError.invalid("namespace: \(error)")
        }
    }
}

public extension FullTrackName {
    /// The namespace, then the track name as a length-prefixed byte string.
    var encodedLength: Int {
        namespace.encodedLength + WireSize.lengthPrefixed(name.value)
    }

    func write(to writer: inout WireWriter) {
        namespace.write(to: &writer)
        writer.lengthPrefixed(name.value)
    }

    static func read(from reader: inout WireReader) throws(WireError) -> FullTrackName {
        let namespace = try TrackNamespace.read(from: &reader)
        let name = try reader.lengthPrefixedString()
        do {
            return try FullTrackName(namespace: namespace, name: try TrackName(name))
        } catch {
            throw WireError.invalid("track name: \(error)")
        }
    }
}
