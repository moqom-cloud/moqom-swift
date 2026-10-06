import CryptoKit
import Foundation
import Testing

@testable import MoqomKit

/// The parts of the MLS subset that claim to be exactly RFC 9420, held to the
/// working group's vectors. Anything not tested here is not claimed.
@Suite("MLS conformance (RFC 9420 test vectors, cipher suite 1)")
struct MLSConformanceTests {
    private func vector(_ name: String) -> [String: String] {
        MLSVectors.cryptoBasics[name]!
    }

    @Test("ExpandWithLabel")
    func expandWithLabel() {
        let v = vector("expand_with_label")
        let out = MLSCipherSuite.expandWithLabel(
            hex(v["secret"]!),
            label: v["label"]!,
            context: hex(v["context"]!),
            length: Int(v["length"]!)!
        )
        #expect(out == hex(v["out"]!))
    }

    @Test("DeriveSecret")
    func deriveSecret() {
        let v = vector("derive_secret")
        #expect(MLSCipherSuite.deriveSecret(hex(v["secret"]!), label: v["label"]!) == hex(v["out"]!))
    }

    @Test("DeriveTreeSecret: ExpandWithLabel over a big-endian generation")
    func deriveTreeSecret() {
        // No secret tree is built on this (application data is SFrame), but the
        // vector pins ExpandWithLabel with a non-empty, non-hash context.
        let v = vector("derive_tree_secret")
        var generation = MLSWriter()
        generation.uint32(UInt32(v["generation"]!)!)
        let out = MLSCipherSuite.expandWithLabel(
            hex(v["secret"]!), label: v["label"]!, context: generation.bytes, length: Int(v["length"]!)!
        )
        #expect(out == hex(v["out"]!))
    }

    @Test("RefHash")
    func refHash() {
        let v = vector("ref_hash")
        #expect(MLSCipherSuite.refHash(label: v["label"]!, value: hex(v["value"]!)) == hex(v["out"]!))
    }

    @Test("SignWithLabel: the published signature verifies, and ours does too")
    func signWithLabel() throws {
        // Ed25519 in CryptoKit is randomised, so our own signature cannot be
        // compared byte for byte; verifying both directions is the check.
        let v = vector("sign_with_label")
        let content = hex(v["content"]!)
        #expect(MLSCipherSuite.verifyWithLabel(
            hex(v["pub"]!), label: v["label"]!, content: content, signature: hex(v["signature"]!)
        ))
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: hex(v["priv"]!))
        #expect(key.publicKey.rawRepresentation == hex(v["pub"]!))
        let ours = try MLSCipherSuite.signWithLabel(key, label: v["label"]!, content: content)
        #expect(MLSCipherSuite.verifyWithLabel(
            hex(v["pub"]!), label: v["label"]!, content: content, signature: ours
        ))
        #expect(!MLSCipherSuite.verifyWithLabel(
            hex(v["pub"]!), label: "Other", content: content, signature: ours
        ))
    }

    @Test("EncryptWithLabel: the published ciphertext decrypts, and ours round-trips")
    func encryptWithLabel() throws {
        let v = vector("encrypt_with_label")
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex(v["priv"]!))
        #expect(key.publicKey.rawRepresentation == hex(v["pub"]!))
        let opened = try MLSCipherSuite.decryptWithLabel(
            key,
            label: v["label"]!,
            context: hex(v["context"]!),
            ciphertext: HPKECiphertext(
                kemOutput: hex(v["kem_output"]!), ciphertext: hex(v["ciphertext"]!)
            )
        )
        #expect(opened == hex(v["plaintext"]!))

        let sealed = try MLSCipherSuite.encryptWithLabel(
            hex(v["pub"]!), label: v["label"]!, context: hex(v["context"]!), plaintext: Data("x".utf8)
        )
        let back = try MLSCipherSuite.decryptWithLabel(
            key, label: v["label"]!, context: hex(v["context"]!), ciphertext: sealed
        )
        #expect(back == Data("x".utf8))
    }

    @Test("key schedule: five epochs, every derived secret, GroupContext and exporter")
    func keySchedule() {
        var initSecret = hex(MLSVectors.initialInitSecret)
        for (index, v) in MLSVectors.epochs.enumerated() {
            let context = MLSGroupContext(
                groupID: hex(MLSVectors.groupID),
                epoch: UInt64(index),
                treeHash: hex(v["tree_hash"]!),
                confirmedTranscriptHash: hex(v["confirmed_transcript_hash"]!)
            )
            #expect(context.encoded == hex(v["group_context"]!), "group context, epoch \(index)")

            let secrets = MLSEpochSecrets.derive(
                initSecret: initSecret,
                commitSecret: hex(v["commit_secret"]!),
                pskSecret: hex(v["psk_secret"]!),
                context: context
            )
            #expect(secrets.joinerSecret == hex(v["joiner_secret"]!), "joiner, epoch \(index)")
            #expect(secrets.welcomeSecret == hex(v["welcome_secret"]!), "welcome, epoch \(index)")
            #expect(secrets.senderDataSecret == hex(v["sender_data_secret"]!))
            #expect(secrets.encryptionSecret == hex(v["encryption_secret"]!))
            #expect(secrets.exporterSecret == hex(v["exporter_secret"]!))
            #expect(secrets.externalSecret == hex(v["external_secret"]!))
            #expect(secrets.confirmationKey == hex(v["confirmation_key"]!))
            #expect(secrets.membershipKey == hex(v["membership_key"]!))
            #expect(secrets.resumptionPSK == hex(v["resumption_psk"]!))
            #expect(secrets.epochAuthenticator == hex(v["epoch_authenticator"]!))
            #expect(secrets.initSecret == hex(v["init_secret"]!), "init, epoch \(index)")
            #expect(
                MLSEpochSecrets.welcomeSecret(
                    joinerSecret: secrets.joinerSecret, pskSecret: hex(v["psk_secret"]!)
                ) == hex(v["welcome_secret"]!)
            )

            // The vector's label is a string that happens to look like hex,
            // and is used as its UTF-8 bytes rather than decoded.
            let exported = secrets.export(
                label: v["exporter_label"]!,
                context: hex(v["exporter_context"]!),
                length: Int(v["exporter_length"]!)!
            )
            #expect(exported == hex(v["exporter_out"]!), "exporter, epoch \(index)")

            initSecret = secrets.initSecret
        }
    }

    @Test("GroupContext round-trips through its encoding")
    func groupContextRoundTrip() throws {
        let context = MLSGroupContext(
            groupID: Data("room".utf8), epoch: 7, treeHash: Data(repeating: 1, count: 32),
            confirmedTranscriptHash: Data(repeating: 2, count: 32)
        )
        var reader = MLSReader(context.encoded)
        #expect(try MLSGroupContext.read(from: &reader) == context)
    }

    @Test("vector lengths use the RFC's minimum-length encoding")
    func variableLengths() throws {
        for count in [0, 63, 64, 16383, 16384] {
            var writer = MLSWriter()
            writer.vector(Data(count: count))
            var reader = MLSReader(writer.bytes)
            #expect(try reader.vector().count == count)
            #expect(reader.isAtEnd)
        }
        // 0x40 0x05 is five encoded in two bytes, which the RFC forbids.
        var reader = MLSReader(Data([0x40, 0x05, 1, 2, 3, 4, 5]))
        #expect(throws: MLSError.self) { _ = try reader.vector() }
    }

    @Test("deserialization.json: every published vlbytes header, both directions")
    func deserializationVectors() throws {
        for (header, length) in MLSVectors.vlbytesHeaders {
            var writer = MLSWriter()
            writer.length(length)
            #expect(writer.bytes == hex(header), "encode \(length)")
            var reader = MLSReader(hex(header))
            #expect(try reader.length() == length, "decode \(header)")
            #expect(reader.isAtEnd)
        }
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
