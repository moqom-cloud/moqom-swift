import MoqomCore
import MoqomWire
import XCTest
@testable import MoqomKit

/// Pins subscribe parameter codes to draft-ietf-moq-transport-19 Table 13. A
/// conformant relay closes the session on an unregistered code, and MOQOM's own
/// relay forwards parameters opaquely, so interop tests alone won't catch drift.
final class SubscribeParameterTests: XCTestCase {
    func testCodesMatchDraft19Registry() {
        XCTAssertEqual(SubscribeParameter.subscriberPriority, 0x20)
        XCTAssertEqual(SubscribeParameter.deliveryTimeout, 0x02)
        XCTAssertEqual(SubscribeParameter.groupOrder, 0x22)
    }

    /// The bytes a SUBSCRIBE carries, so a wrong code fails here rather than as
    /// a relay closing the session. Types are delta-encoded: 0x02, then
    /// 0x20 - 0x02 = 0x1E, then 0x22 - 0x20 = 0x02.
    func testSubscriberPriorityOnTheWire() throws {
        let parameters: Parameters = try [
            .integer(SubscribeParameter.subscriberPriority, 7),
            .integer(SubscribeParameter.deliveryTimeout, 100),
            .integer(SubscribeParameter.groupOrder, 1),
        ]
        var writer = WireWriter()
        parameters.writeCounted(to: &writer)
        XCTAssertEqual(
            [UInt8](writer.bytes),
            [0x03, 0x02, 0x40, 0x64, 0x1E, 0x07, 0x02, 0x01]
        )

        var reader = WireReader(writer.bytes)
        let read = try Parameters.readCounted(from: &reader)
        XCTAssertEqual(read.integer(0x20), 7)
        XCTAssertNil(read.integer(0x0E))
    }
}
