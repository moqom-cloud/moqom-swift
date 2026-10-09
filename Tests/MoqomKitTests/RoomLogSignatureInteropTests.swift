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
    ].joined())!

    @Test("an entry the Go control plane signed verifies here")
    func goSignatureVerifies() {
        #expect(testAuthority.id == "oCQNd7Cb5uY")
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
