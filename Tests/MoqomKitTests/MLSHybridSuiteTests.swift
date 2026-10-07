import CryptoKit
import Foundation
import Testing

@testable import MoqomKit

/// The hybrid suite, MLS_128_MLKEM768X25519_AES128GCM_SHA256_Ed25519: its KEM
/// held to the HPKE working group's vector, and the two suites kept apart.
@Suite("MLS hybrid cipher suite (X-Wing)")
struct MLSHybridSuiteTests {
    private let hybrid = MLSCipherSuite.mls128MLKEM768X25519
    private let classical = MLSCipherSuite.mls128DHKEMX25519
    private let room = Data("acme/room-42".utf8)

    @Test("KEM 0x647a: CryptoKit's X-Wing opens draft-ietf-hpke-pq's vector")
    func hpkeVector() throws {
        let v = MLSHybridVectors.self
        let key = try XWingMLKEM768X25519.PrivateKey(seedRepresentation: hex(v.skRm), publicKey: nil)
        #expect(key.publicKey.rawRepresentation == hex(v.pkRm))
        #expect(key.seedRepresentation == hex(v.skRm))

        var recipient = try HPKE.Recipient(
            privateKey: key,
            ciphersuite: HPKE.Ciphersuite(kem: .XWingMLKEM768X25519, kdf: .HKDF_SHA256, aead: .chaChaPoly),
            info: hex(v.info),
            encapsulatedKey: hex(v.enc)
        )
        for (index, encryption) in v.encryptions.enumerated() {
            let opened = try recipient.open(hex(encryption.ct), authenticating: hex(encryption.aad))
            #expect(opened == hex(encryption.pt), "encryption \(index)")
        }
        for export in v.exports {
            let value = try recipient.exportSecret(context: hex(export.context), outputByteCount: export.length)
            #expect(value.withUnsafeBytes { Data($0) } == hex(export.value))
        }
    }

    @Test("identifiers: the hybrid suite is known, and is not what a new group uses")
    func identifiers() {
        #expect(MLSCipherSuite.default != hybrid)
        #expect(hybrid.hasPostQuantumKEM && !classical.hasPostQuantumKEM)
        #expect(MLSCipherSuite(identifier: 0x0001) == classical)
        #expect(MLSCipherSuite(identifier: 0xF0A1) == hybrid)
        // Private use (RFC 9420 §17.1) until the draft's TBD1 is assigned.
        #expect((0xF000 ... 0xFFFF).contains(hybrid.identifier))
        for unknown: UInt16 in [0x0000, 0x0002, 0x0A0A, 0xF000, 0xFFFF] {
            #expect(MLSCipherSuite(identifier: unknown) == nil)
        }
        #expect(hybrid.name == "MLS_128_MLKEM768X25519_AES128GCM_SHA256_Ed25519")
    }

    @Test("KEM keys and encapsulations are the sizes the drafts give", arguments: MLSCipherSuite.supported)
    func sizes(suite: MLSCipherSuite) throws {
        let pair = try suite.generateKeyPair()
        // ML-KEM-768's seed is FIPS 203's d || z; X-Wing's and X25519's are 32 bytes.
        #expect(pair.privateKey.count == (suite == .mls192MLKEM768MLDSA65 ? 64 : 32))
        #expect(pair.publicKey.count == suite.publicKeyLength)
        let sealed = try suite.encryptWithLabel(
            pair.publicKey, label: "UpdatePathNode", context: Data(), plaintext: Data(count: 32)
        )
        #expect(sealed.kemOutput.count == suite.encapsulationLength)
        #expect(sealed.ciphertext.count == 32 + 16)
        if suite == hybrid {
            #expect(suite.publicKeyLength == 1216 && suite.encapsulationLength == 1120)
        }
    }

    @Test("EncryptWithLabel round-trips under X-Wing and is bound to its label and context")
    func encryptWithLabel() throws {
        let pair = try hybrid.generateKeyPair()
        let secret = MLSCipherSuite.randomSecret(32)
        let sealed = try hybrid.encryptWithLabel(
            pair.publicKey, label: "Welcome", context: Data("ctx".utf8), plaintext: secret
        )
        #expect(try hybrid.decryptWithLabel(
            pair.privateKey, label: "Welcome", context: Data("ctx".utf8), ciphertext: sealed
        ) == secret)
        #expect(throws: MLSError.decryptionFailed) {
            _ = try hybrid.decryptWithLabel(pair.privateKey, label: "Other", context: Data("ctx".utf8), ciphertext: sealed)
        }
        #expect(throws: MLSError.decryptionFailed) {
            _ = try hybrid.decryptWithLabel(pair.privateKey, label: "Welcome", context: Data(), ciphertext: sealed)
        }
        // Another suite's key, or another suite's ciphertext, is refused before HPKE runs.
        #expect(throws: MLSError.malformed) {
            _ = try hybrid.encryptWithLabel(
                try classical.generateKeyPair().publicKey, label: "Welcome", context: Data(), plaintext: secret
            )
        }
        #expect(throws: MLSError.decryptionFailed) {
            _ = try classical.decryptWithLabel(pair.privateKey, label: "Welcome", context: Data("ctx".utf8), ciphertext: sealed)
        }
    }

    @Test("a key package names its suite, and one in a suite not implemented does not decode")
    func keyPackageSuite() throws {
        let package = try MLSKeyPackageBundle.generate(identity: "bob/b", cipherSuite: hybrid).keyPackage
        #expect(package.cipherSuite == hybrid)
        #expect(package.initKey.count == 1216 && package.encryptionKey.count == 1216)
        #expect(package.isValid)
        let encoded = package.encoded
        #expect(encoded[2 ..< 4] == Data([0xF0, 0xA1]))
        #expect(try MLSKeyPackage.decode(encoded) == package)

        var unknown = encoded
        unknown[3] = 0x02
        #expect(throws: MLSError.unsupported) { _ = try MLSKeyPackage.decode(unknown) }

        // Relabelled as the classical suite: the signature covers the suite,
        // and the keys are the wrong size for it.
        var relabelled = encoded
        relabelled[2] = 0x00
        relabelled[3] = 0x01
        let decoded = try MLSKeyPackage.decode(relabelled)
        #expect(decoded.cipherSuite == classical)
        #expect(!decoded.isValid)
    }

    @Test("a group never mixes suites: a commit refuses a key package in the other one")
    func mixedSuitesRefused() throws {
        let hybridGroup = try MLSGroup.create(
            groupID: room, bundle: .generate(identity: "alice/a", cipherSuite: hybrid)
        )
        #expect(hybridGroup.cipherSuite == hybrid)
        let classicalBob = try MLSKeyPackageBundle.generate(identity: "bob/b", cipherSuite: classical)
        #expect(throws: MLSError.cipherSuiteMismatch(group: 0xF0A1, other: 0x0001)) {
            _ = try hybridGroup.commit(adding: [classicalBob.keyPackage])
        }

        let classicalGroup = try MLSGroup.create(
            groupID: room, bundle: .generate(identity: "alice/a", cipherSuite: classical)
        )
        #expect(classicalGroup.cipherSuite == classical)
        let hybridBob = try MLSKeyPackageBundle.generate(identity: "bob/b", cipherSuite: hybrid)
        #expect(throws: MLSError.cipherSuiteMismatch(group: 0x0001, other: 0xF0A1)) {
            _ = try classicalGroup.commit(adding: [hybridBob.keyPackage])
        }

        // A Welcome made for the right suite does not open for a bundle in the other.
        let add = try classicalGroup.commit(adding: [classicalBob.keyPackage])
        let welcome = try #require(add.welcome)
        #expect(throws: MLSError.notAddressed) { _ = try MLSGroup.join(welcome, bundle: hybridBob) }
        let joined = try MLSGroup.join(welcome, bundle: classicalBob)
        #expect(joined.cipherSuite == classical)
        #expect(joined.epochAuthenticator == add.next.epochAuthenticator)
    }

    @Test("the two suites give different epochs from the same inputs")
    func suiteBindsKeySchedule() {
        func secrets(_ suite: MLSCipherSuite) -> MLSEpochSecrets {
            MLSEpochSecrets.derive(
                initSecret: Data(count: 32),
                commitSecret: Data(count: 32),
                context: MLSGroupContext(
                    cipherSuite: suite, groupID: room, epoch: 1,
                    treeHash: Data(count: 32), confirmedTranscriptHash: Data(count: 32)
                )
            )
        }
        #expect(secrets(hybrid).exporterSecret != secrets(classical).exporterSecret)
    }

    @Test("sizes on the wire: what one member costs a commit and a Welcome under X-Wing")
    func wireSizes() throws {
        // Members two to five, added one at a time, so each commit seals one
        // more secret than the last and each Welcome carries one more leaf.
        var group = try MLSGroup.create(groupID: room, bundle: .generate(identity: "alice/a", cipherSuite: hybrid))
        var commits: [Int] = []
        var welcomes: [Int] = []
        for index in 0 ..< 4 {
            let joiner = try MLSKeyPackageBundle.generate(identity: "member/\(index)", cipherSuite: hybrid)
            #expect(joiner.keyPackage.encoded.count < 2_700)
            let add = try group.commit(adding: [joiner.keyPackage])
            commits.append(add.message.encoded.count)
            welcomes.append(try #require(add.welcome).encoded.count)
            group = add.next
        }
        let commitPerMember = Set(zip(commits.dropFirst(), commits).map { $0 - $1 })
        let welcomePerMember = Set(zip(welcomes.dropFirst(), welcomes).map { $0 - $1 })
        // One HPKE ciphertext (1,120 + 48 bytes) and its framing per member.
        #expect(commitPerMember.allSatisfy { (1_168 ... 1_180).contains($0) })
        // One leaf (identity, Ed25519 key, 1,216-byte leaf key) per member.
        #expect(welcomePerMember.allSatisfy { (1_250 ... 1_270).contains($0) })
        // The control plane's maxCommitBytes is 1 MiB: a room of 800 fits in
        // both a rotation commit and a Welcome.
        let limit = 1 << 20
        #expect(800 * (commitPerMember.max() ?? 0) < limit)
        #expect(800 * (welcomePerMember.max() ?? 0) < limit)
    }
}

private func hex(_ string: String) -> Data {
    var data = Data(capacity: string.count / 2)
    var index = string.startIndex
    while index < string.endIndex {
        let next = string.index(index, offsetBy: 2)
        data.append(UInt8(string[index ..< next], radix: 16)!)
        index = next
    }
    return data
}
