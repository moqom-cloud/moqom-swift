// The one STUN exchange a direct endpoint needs: a Binding request, and the
// address the response reports (RFC 8489). A port of
// `moqom_client::direct::stun`, kept byte-compatible so either SDK can use the
// same server, and a test server in one can answer the other.

import Foundation

enum DirectSTUN {
    static let magicCookie: UInt32 = 0x2112_A442
    private static let bindingRequest: UInt16 = 0x0001
    private static let bindingSuccess: UInt16 = 0x0101
    private static let mappedAddress: UInt16 = 0x0001
    private static let xorMappedAddress: UInt16 = 0x0020

    /// A Binding request with no attributes.
    static func request(transaction: [UInt8]) -> Data {
        precondition(transaction.count == 12)
        var out = Data()
        out.append(contentsOf: bigEndian(bindingRequest))
        out.append(contentsOf: [0, 0])
        out.append(contentsOf: bigEndian(magicCookie))
        out.append(contentsOf: transaction)
        return out
    }

    /// A Binding success response telling the requester it came from `from`,
    /// for a test server.
    static func response(transaction: [UInt8], from: DirectCandidate) -> Data {
        var value: [UInt8] = [0, from.isIPv6 ? 0x02 : 0x01]
        value.append(contentsOf: bigEndian(from.port ^ UInt16(magicCookie >> 16)))
        let mask = bigEndian(magicCookie) + transaction
        value.append(contentsOf: zip(from.address, mask).map { $0 ^ $1 })

        var out = Data()
        out.append(contentsOf: bigEndian(bindingSuccess))
        out.append(contentsOf: bigEndian(UInt16(4 + value.count)))
        out.append(contentsOf: bigEndian(magicCookie))
        out.append(contentsOf: transaction)
        out.append(contentsOf: bigEndian(xorMappedAddress))
        out.append(contentsOf: bigEndian(UInt16(value.count)))
        out.append(contentsOf: value)
        return out
    }

    /// The address a Binding success response for `transaction` reports, if
    /// `datagram` is one. XOR-MAPPED-ADDRESS wins over MAPPED-ADDRESS, as in
    /// the Rust codec.
    static func parse(_ datagram: Data, transaction: [UInt8]) -> DirectCandidate? {
        let bytes = [UInt8](datagram)
        guard bytes.count >= 20,
              word16(bytes, 0) == bindingSuccess,
              word32(bytes, 4) == magicCookie,
              Array(bytes[8 ..< 20]) == transaction
        else { return nil }
        let length = Int(word16(bytes, 2))
        guard bytes.count >= 20 + length else { return nil }
        var attributes = Array(bytes[20 ..< 20 + length])

        var plain: DirectCandidate?
        while attributes.count >= 4 {
            let kind = word16(attributes, 0)
            let count = Int(word16(attributes, 2))
            guard attributes.count >= 4 + count else { return nil }
            let value = Array(attributes[4 ..< 4 + count])
            switch kind {
            case xorMappedAddress: return address(value, transaction: transaction)
            case mappedAddress: plain = address(value, transaction: nil)
            default: break
            }
            let padded = (count + 3) & ~3
            attributes = attributes.count > 4 + padded ? Array(attributes[(4 + padded)...]) : []
        }
        return plain
    }

    private static func address(_ value: [UInt8], transaction: [UInt8]?) -> DirectCandidate? {
        guard value.count >= 4 else { return nil }
        var port = word16(value, 2)
        var mask = [UInt8](repeating: 0, count: 16)
        if let transaction {
            port ^= UInt16(magicCookie >> 16)
            mask = bigEndian(magicCookie) + transaction
        }
        let width: Int
        switch value[1] {
        case 0x01: width = 4
        case 0x02: width = 16
        default: return nil
        }
        guard value.count >= 4 + width else { return nil }
        let raw = value[4 ..< 4 + width]
        return DirectCandidate(address: zip(raw, mask).map { $0 ^ $1 }, port: port)
    }

    private static func bigEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian) { Array($0) }
    }

    private static func word16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1])
    }

    private static func word32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(word16(bytes, at)) << 16 | UInt32(word16(bytes, at + 2))
    }
}
