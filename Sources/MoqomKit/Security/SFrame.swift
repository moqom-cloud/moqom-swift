// SFrame, RFC 9605.
//
// End-to-end encryption for media, done at the frame rather than the packet.
// The relay forwards ciphertext it cannot read and still schedules it correctly,
// because everything the relay needs — track, group, object, priority, capture
// time, temporal layer — stays outside the encrypted payload and is
// authenticated as additional data. A relay can therefore drop, reorder, and
// prioritise, and cannot alter or forge.
//
// Two notes on what is implemented and what is not.
//
// Only the AES-GCM suites are here (0x0004 and 0x0005). The AES-CTR + HMAC
// suites in the RFC exist for hardware that has AES-CTR and not GCM, and for
// the truncated-tag variants that save bytes on very small audio packets. Every
// platform MOQOM targets has hardware GCM through CryptoKit, and rolling our
// own CTR-then-HMAC composition to save six bytes on an audio packet is a bad
// trade for a security primitive.
//
// The counter must never repeat under a key. That is not a strong
// recommendation, it is the whole security argument for GCM: a repeated nonce
// with a different plaintext leaks the XOR of the plaintexts and, worse, the
// authentication subkey. ``SFrameSender`` owns the counter for exactly this
// reason — there is no API that lets a caller choose one.

import CryptoKit
import Foundation
import MoqomCore

/// The AEAD and hash a context uses.
public enum SFrameCipherSuite: UInt16, Hashable, Sendable, CaseIterable {
    /// AES-128-GCM with SHA-256. 16-byte tag.
    case aes128GcmSha256 = 0x0004

    /// AES-256-GCM with SHA-512. 16-byte tag. The default.
    ///
    /// The larger key costs nothing measurable on hardware AES and removes a
    /// question nobody wants to answer later about multi-user key separation at
    /// 128 bits.
    case aes256GcmSha512 = 0x0005

    /// Key length in bytes.
    var keyLength: Int {
        switch self {
        case .aes128GcmSha256: 16
        case .aes256GcmSha512: 32
        }
    }

    /// Nonce length in bytes. 12 for both, as GCM wants.
    var nonceLength: Int { 12 }

    /// Authentication tag length in bytes.
    var tagLength: Int { 16 }
}

/// What went wrong.
public enum SFrameError: Error, Hashable, Sendable {
    /// The header is malformed or the ciphertext is too short to hold one.
    case malformedHeader

    /// No key is loaded for the KID in the header.
    ///
    /// Recoverable: the RFC allows buffering and retrying once the key
    /// arrives, because key distribution and media are separate channels and
    /// can legitimately race.
    case unknownKey(UInt64)

    /// Authentication failed.
    ///
    /// Never distinguish this from any other failure to a caller who might
    /// report it onward. Which frames fail to authenticate is information an
    /// attacker can use.
    case authenticationFailure

    /// This (KID, CTR) has been seen before, or is too old to accept.
    case replay(counter: UInt64)

    /// The counter space for this key is exhausted.
    ///
    /// Fatal by design. Wrapping the counter would reuse a nonce, and reusing a
    /// GCM nonce is catastrophic rather than merely weak, so the only correct
    /// response is to stop and rekey.
    case counterExhausted
}

/// The KID and CTR that precede an SFrame ciphertext.
public struct SFrameHeader: Hashable, Sendable {
    public let keyID: UInt64
    public let counter: UInt64

    public init(keyID: UInt64, counter: UInt64) {
        self.keyID = keyID
        self.counter = counter
    }

    /// Encoded per RFC 9605 §4.3.
    ///
    /// A value below 8 rides in the config byte itself; anything larger is
    /// appended in the minimum number of bytes. Small KIDs and small counters
    /// therefore cost one byte in total, which matters when the payload is a
    /// 60-byte audio packet.
    public var encoded: Data {
        var config: UInt8 = 0
        var body = Data()

        if keyID < 8 {
            config |= UInt8(keyID) << 4
        } else {
            let bytes = Self.compact(keyID)
            config |= 0x80
            config |= UInt8(bytes.count - 1) << 4
            body.append(bytes)
        }

        if counter < 8 {
            config |= UInt8(counter)
        } else {
            let bytes = Self.compact(counter)
            config |= 0x08
            config |= UInt8(bytes.count - 1)
            body.append(bytes)
        }

        return Data([config]) + body
    }

    /// Parse a header, returning it and how many bytes it took.
    public static func read(from data: Data) throws(SFrameError) -> (SFrameHeader, Int) {
        guard let config = data.first else { throw SFrameError.malformedHeader }

        let extendedKeyID = config & 0x80 != 0
        let keyField = Int((config >> 4) & 0x07)
        let extendedCounter = config & 0x08 != 0
        let counterField = Int(config & 0x07)

        var offset = data.startIndex + 1
        let end = data.endIndex

        let keyID: UInt64
        if extendedKeyID {
            let length = keyField + 1
            guard end - offset >= length else { throw SFrameError.malformedHeader }
            keyID = Self.integer(data[offset ..< offset + length])
            offset += length
        } else {
            keyID = UInt64(keyField)
        }

        let counter: UInt64
        if extendedCounter {
            let length = counterField + 1
            guard end - offset >= length else { throw SFrameError.malformedHeader }
            counter = Self.integer(data[offset ..< offset + length])
            offset += length
        } else {
            counter = UInt64(counterField)
        }

        return (SFrameHeader(keyID: keyID, counter: counter), offset - data.startIndex)
    }

    /// Big-endian, minimum length, at least one byte.
    private static func compact(_ value: UInt64) -> Data {
        var bytes = withUnsafeBytes(of: value.bigEndian) { Data($0) }
        while bytes.count > 1, bytes.first == 0 { bytes.removeFirst() }
        return bytes
    }

    private static func integer(_ bytes: some Collection<UInt8>) -> UInt64 {
        bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}

/// A key and salt derived from a base key for one KID.
public struct SFrameKey: Sendable {
    public let keyID: UInt64
    public let suite: SFrameCipherSuite
    let key: SymmetricKey
    let salt: Data

    /// Derive per RFC 9605 §4.4.2.
    ///
    /// The KID and cipher suite are inside the derivation labels rather than
    /// only in the header, which is what stops a ciphertext produced under one
    /// KID or suite from ever authenticating under another.
    public init(keyID: UInt64, baseKey: Data, suite: SFrameCipherSuite = .aes256GcmSha512) {
        self.keyID = keyID
        self.suite = suite

        var suffix = withUnsafeBytes(of: keyID.bigEndian) { Data($0) }
        suffix.append(contentsOf: withUnsafeBytes(of: suite.rawValue.bigEndian) { Data($0) })

        let keyLabel = Data("SFrame 1.0 Secret key ".utf8) + suffix
        let saltLabel = Data("SFrame 1.0 Secret salt ".utf8) + suffix

        switch suite {
        case .aes128GcmSha256:
            let secret = HKDF<SHA256>.extract(
                inputKeyMaterial: SymmetricKey(data: baseKey), salt: Data()
            )
            key = HKDF<SHA256>.expand(
                pseudoRandomKey: secret, info: keyLabel, outputByteCount: suite.keyLength
            )
            salt = HKDF<SHA256>.expand(
                pseudoRandomKey: secret, info: saltLabel, outputByteCount: suite.nonceLength
            ).withUnsafeBytes { Data($0) }
        case .aes256GcmSha512:
            let secret = HKDF<SHA512>.extract(
                inputKeyMaterial: SymmetricKey(data: baseKey), salt: Data()
            )
            key = HKDF<SHA512>.expand(
                pseudoRandomKey: secret, info: keyLabel, outputByteCount: suite.keyLength
            )
            salt = HKDF<SHA512>.expand(
                pseudoRandomKey: secret, info: saltLabel, outputByteCount: suite.nonceLength
            ).withUnsafeBytes { Data($0) }
        }
    }

    /// The salt XORed with the counter, big-endian.
    func nonce(counter: UInt64) -> Data {
        var bytes = Data(repeating: 0, count: suite.nonceLength)
        let counterBytes = withUnsafeBytes(of: counter.bigEndian) { Data($0) }
        // The counter occupies the low-order end; the high-order bytes of the
        // salt pass through unchanged.
        let offset = bytes.count - counterBytes.count
        for index in 0 ..< bytes.count {
            let saltByte = salt[salt.startIndex + index]
            let counterByte = index >= offset
                ? counterBytes[counterBytes.startIndex + index - offset]
                : 0
            bytes[index] = saltByte ^ counterByte
        }
        return bytes
    }

    func seal(_ plaintext: Data, counter: UInt64, aad: Data) throws(SFrameError) -> Data {
        do {
            let sealed = try AES.GCM.seal(
                plaintext,
                using: key,
                nonce: AES.GCM.Nonce(data: nonce(counter: counter)),
                authenticating: aad
            )
            return sealed.ciphertext + sealed.tag
        } catch {
            throw SFrameError.authenticationFailure
        }
    }

    func open(_ ciphertext: Data, counter: UInt64, aad: Data) throws(SFrameError) -> Data {
        guard ciphertext.count >= suite.tagLength else {
            throw SFrameError.authenticationFailure
        }
        let split = ciphertext.index(ciphertext.endIndex, offsetBy: -suite.tagLength)
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonce(counter: counter)),
                ciphertext: ciphertext[..<split],
                tag: ciphertext[split...]
            )
            return try AES.GCM.open(box, using: key, authenticating: aad)
        } catch {
            throw SFrameError.authenticationFailure
        }
    }
}

/// Encrypts, owning the counter.
///
/// One sender per (key, media stream). Sharing one across two streams is safe
/// and sharing a *key* across two senders is not, because two independent
/// counters under one key will collide.
public final class SFrameSender: @unchecked Sendable {
    public let key: SFrameKey

    private let lock = NSLock()
    private var counter: UInt64 = 0

    public init(key: SFrameKey) {
        self.key = key
    }

    /// Counters issued so far. For deciding when to rekey.
    public var issuedCounters: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return counter
    }

    /// Encrypt one frame.
    ///
    /// - Parameter metadata: Authenticated but not encrypted. Whatever the
    ///   relay is allowed to read and must not be able to change.
    public func protect(_ plaintext: Data, metadata: Data = Data()) throws(SFrameError) -> Data {
        lock.lock()
        let current = counter
        guard current < UInt64.max else {
            lock.unlock()
            throw SFrameError.counterExhausted
        }
        counter = current + 1
        lock.unlock()

        let header = SFrameHeader(keyID: key.keyID, counter: current).encoded
        let ciphertext = try key.seal(plaintext, counter: current, aad: header + metadata)
        return header + ciphertext
    }
}

/// Decrypts, holding keys for one or more KIDs and rejecting replays.
public final class SFrameReceiver: @unchecked Sendable {
    /// How far back a counter may be and still be accepted.
    ///
    /// Reordering is normal on a network, so a strict "must increase" rule
    /// would discard perfectly good frames. The window bounds how much
    /// out-of-order delivery is tolerated before a frame is assumed to be a
    /// replay; 1024 is far more than any real path reorders and still small
    /// enough that the bitmap is two words per key.
    public let replayWindow: UInt64

    private let lock = NSLock()
    private var keys: [UInt64: SFrameKey] = [:]
    private var seen: [UInt64: ReplayWindow] = [:]

    public init(replayWindow: UInt64 = 1024) {
        self.replayWindow = replayWindow
    }

    public func add(_ key: SFrameKey) {
        lock.lock()
        defer { lock.unlock() }
        keys[key.keyID] = key
        seen[key.keyID] = ReplayWindow(size: replayWindow)
    }

    /// Forget a key.
    ///
    /// Anything still in flight under it stops decrypting, which is the point:
    /// this is what removing a participant from a group means.
    public func remove(keyID: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        keys[keyID] = nil
        seen[keyID] = nil
    }

    /// Decrypt one frame.
    public func unprotect(_ data: Data, metadata: Data = Data()) throws(SFrameError) -> Data {
        let (header, length) = try SFrameHeader.read(from: data)

        lock.lock()
        guard let key = keys[header.keyID] else {
            lock.unlock()
            throw SFrameError.unknownKey(header.keyID)
        }
        var window = seen[header.keyID] ?? ReplayWindow(size: replayWindow)
        guard window.accepts(header.counter) else {
            lock.unlock()
            throw SFrameError.replay(counter: header.counter)
        }
        lock.unlock()

        let aad = data.prefix(length) + metadata
        let plaintext = try key.open(data.dropFirst(length), counter: header.counter, aad: aad)

        // Recorded only after authentication. Marking a counter used on a frame
        // that failed to authenticate would let anyone with a forged frame
        // knock out the real one behind it.
        lock.lock()
        window.record(header.counter)
        seen[header.keyID] = window
        lock.unlock()

        return plaintext
    }
}

/// A sliding window of counters already seen.
struct ReplayWindow: Sendable {
    private let size: UInt64
    private var highest: UInt64?
    private var bitmap: UInt64 = 0

    init(size: UInt64) {
        self.size = min(size, 64)
    }

    /// Whether a counter is new enough and has not been seen.
    func accepts(_ counter: UInt64) -> Bool {
        guard let highest else { return true }
        if counter > highest { return true }
        let age = highest - counter
        guard age < size else { return false }
        return bitmap & (1 << age) == 0
    }

    mutating func record(_ counter: UInt64) {
        guard let current = highest else {
            highest = counter
            bitmap = 1
            return
        }
        if counter > current {
            let shift = counter - current
            bitmap = shift >= 64 ? 0 : bitmap << shift
            bitmap |= 1
            highest = counter
        } else {
            let age = current - counter
            if age < 64 { bitmap |= (1 << age) }
        }
    }
}
