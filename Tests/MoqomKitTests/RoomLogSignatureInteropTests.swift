// The room log's signature as the Go control plane writes it.
//
// From `moqom-pq/go/internal/token/testdata/roomlog.json`, which
// `TestRoomLogFixture` regenerates with MOQOM_WRITE_FIXTURES=1. Same seed as
// ``testAuthority``, so this checks that both sides derive the same key ID from
// a seed and sign the same message, not only that each agrees with itself.

import Foundation
import Testing

@testable import MoqomCore
@testable import MoqomKit

@Suite("Room log signature interop")
struct RoomLogSignatureInteropTests {
    private let entry = Data(#"{"sequence":1,"snapshot":{"participants":[]},"version":1}"#.utf8)
    private let property = Data(base64Encoded: [
        "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",
        "AAAABQoSGh4l",
    ].joined())!

    @Test("an entry the Go control plane signed verifies here")
    func goSignatureVerifies() {
        #expect(testAuthority.id == "_uaJ-Ppel-Y")
        #expect(RoomLogSignature.verifies(
            property, entry: entry, tenant: "acme", room: "room-42",
            keys: [testAuthority.verificationKey]
        ))
        #expect(!RoomLogSignature.verifies(
            property, entry: entry, tenant: "acme", room: "room-7",
            keys: [testAuthority.verificationKey]
        ))
    }

    @Test("an entry signed here has the Go control plane's layout")
    func swiftSignatureHasTheSameShape() throws {
        let signed = try testAuthority.sign(entry, tenant: "acme", room: "room-42")
        #expect(signed.prefix(1 + testAuthority.id.utf8.count) == property.prefix(1 + testAuthority.id.utf8.count))
        #expect(signed.count == property.count)
        #expect(RoomLogSignature.verifies(
            signed, entry: entry, tenant: "acme", room: "room-42",
            keys: [testAuthority.verificationKey]
        ))
    }
}
