import CryptoKit
import Foundation
import Testing

@testable import MoqomKit

/// MLS_192_MLKEM768_AES256GCM_SHA384_MLDSA65, the suite every new group uses:
/// HPKE over pure ML-KEM-768 and ML-DSA-65 signatures, held to Go's
/// `crypto/hpke` and `crypto/mldsa` (the control plane's), and the group
/// lifecycle in it end to end. Its key schedule is held to the RFC by
/// `MLSSHA384ConformanceTests`.
@Suite("MLS post-quantum cipher suite (ML-KEM-768, ML-DSA-65)")
struct MLSPostQuantumSuiteTests {
    private let suite = MLSCipherSuite.mls192MLKEM768MLDSA65
    private let room = Data("acme/room-42".utf8)

    @Test("identifiers: the ML-DSA suite is the default, and post-quantum in both halves")
    func identifiers() {
        #expect(MLSCipherSuite.default == suite)
        #expect(MLSCipherSuite.supported.first == suite)
        #expect(MLSCipherSuite(identifier: 0xF0AA) == suite)
        // Private use (RFC 9420 §17.1) until the draft's TBD10 is assigned.
        #expect((0xF000 ... 0xFFFF).contains(suite.identifier))
        #expect(suite.name == "MLS_192_MLKEM768_AES256GCM_SHA384_MLDSA65")
        #expect(suite.hasPostQuantumKEM && suite.hasPostQuantumSignatures)
        #expect(!MLSCipherSuite.mls128MLKEM768X25519.hasPostQuantumSignatures)
        #expect(suite.hashLength == 48 && suite.aeadKeyLength == 32)
        #expect(suite.publicKeyLength == 1184 && suite.encapsulationLength == 1088)
        #expect(suite.signatureKeyLength == 1952)
    }

    @Test("HPKE (0x0041, 0x0002, 0x0002): opens what Go's crypto/hpke sealed")
    func hpkeAgainstGo() throws {
        let seed = hex("101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f")
        let key = try MLKEM768.PrivateKey(seedRepresentation: seed, publicKey: nil)
        #expect(key.publicKey.rawRepresentation == hex(Self.goKEMPublicKey))
        #expect(key.seedRepresentation == seed)
        let opened = try MLKEMHPKE.open(
            HPKECiphertext(kemOutput: hex(Self.goEnc), ciphertext: hex("9a49f8cac9e5bdecc8f4fb390119f97cbd5bb5e332ec4e2bcbca1bd4aa59319f4bc6693db4")),
            seed: seed,
            info: hex("4d4f514f4d2063726f73732d636865636b20696e666f")
        )
        #expect(opened == hex("6a6f696e6572207365637265742066726f6d20476f"))
        #expect(throws: (any Error).self) {
            _ = try MLKEMHPKE.open(
                HPKECiphertext(kemOutput: hex(Self.goEnc), ciphertext: hex("9a49f8cac9e5bdecc8f4fb390119f97cbd5bb5e332ec4e2bcbca1bd4aa59319f4bc6693db4")),
                seed: seed,
                info: Data("other info".utf8)
            )
        }
    }

    @Test("ML-DSA-65: the same key from the same seed as Go, and Go's signature verifies")
    func mlDSAAgainstGo() throws {
        let key = try MLDSA65.PrivateKey(seedRepresentation: hex("404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f"), publicKey: nil)
        #expect(key.publicKey.rawRepresentation == hex(Self.goSignatureKey))
        let message = hex("4d4f514f4d2063726f73732d636865636b206d657373616765")
        #expect(key.publicKey.isValidSignature(hex(Self.goSignature), for: message))
        #expect(!key.publicKey.isValidSignature(hex(Self.goSignature), for: message + Data([0])))
    }

    @Test("SignWithLabel and EncryptWithLabel round-trip, bound to their labels")
    func labelled() throws {
        let signing = try suite.generateSignatureKeyPair()
        #expect(signing.privateKey.count == 32 && signing.publicKey.count == 1952)
        let signature = try suite.signWithLabel(signing.privateKey, label: "GroupInfoTBS", content: room)
        #expect(signature.count == 3309)
        #expect(suite.verifyWithLabel(signing.publicKey, label: "GroupInfoTBS", content: room, signature: signature))
        #expect(!suite.verifyWithLabel(signing.publicKey, label: "Other", content: room, signature: signature))
        // An Ed25519 key is the wrong size for this suite and is refused outright.
        let ed25519 = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        #expect(!suite.verifyWithLabel(ed25519, label: "GroupInfoTBS", content: room, signature: signature))

        let pair = try suite.generateKeyPair()
        let secret = suite.randomSecret()
        #expect(secret.count == 48)
        let sealed = try suite.encryptWithLabel(pair.publicKey, label: "Welcome", context: room, plaintext: secret)
        #expect(sealed.kemOutput.count == 1088)
        #expect(try suite.decryptWithLabel(pair.privateKey, label: "Welcome", context: room, ciphertext: sealed) == secret)
        #expect(throws: MLSError.decryptionFailed) {
            _ = try suite.decryptWithLabel(pair.privateKey, label: "UpdatePathNode", context: room, ciphertext: sealed)
        }
        let other = try suite.generateKeyPair()
        #expect(throws: MLSError.decryptionFailed) {
            _ = try suite.decryptWithLabel(other.privateKey, label: "Welcome", context: room, ciphertext: sealed)
        }
    }

    @Test("a key package is ML-DSA signed, with ML-KEM keys, and is refused relabelled")
    func keyPackage() throws {
        let package = try MLSKeyPackageBundle.generate(identity: "bob/b").keyPackage
        #expect(package.cipherSuite == suite)
        #expect(package.signatureKey.count == 1952)
        #expect(package.initKey.count == 1184 && package.encryptionKey.count == 1184)
        #expect(package.signature.count == 3309)
        #expect(package.isValid)
        let encoded = package.encoded
        #expect(encoded[2 ..< 4] == Data([0xF0, 0xAA]))
        #expect(try MLSKeyPackage.decode(encoded) == package)

        var relabelled = encoded
        relabelled[3] = 0xA1
        #expect(!(try MLSKeyPackage.decode(relabelled)).isValid)
    }

    @Test("found, add, rotate, remove and rejoin: every member agrees on every epoch")
    func lifecycle() throws {
        let alice = try MLSGroup.create(groupID: room, bundle: .generate(identity: "alice/a"))
        #expect(alice.cipherSuite == suite)
        let bob = try MLSKeyPackageBundle.generate(identity: "bob/b")
        let carol = try MLSKeyPackageBundle.generate(identity: "carol/c")
        let add = try alice.commit(adding: [bob.keyPackage, carol.keyPackage])
        let welcome = try #require(add.welcome)
        let bobGroup = try MLSGroup.join(welcome, bundle: bob)
        let carolGroup = try MLSGroup.join(welcome, bundle: carol)
        #expect(bobGroup.epochAuthenticator == add.next.epochAuthenticator)
        #expect(carolGroup.epochAuthenticator == add.next.epochAuthenticator)
        #expect(bobGroup.cipherSuite == suite)

        // Bob rotates; Alice and Carol follow.
        let rotate = try bobGroup.commit()
        guard case .advanced(let aliceNext) = try add.next.process(rotate.message),
              case .advanced(let carolNext) = try carolGroup.process(rotate.message)
        else { Issue.record("rotation not followed"); return }
        #expect(aliceNext.epochAuthenticator == rotate.next.epochAuthenticator)
        #expect(carolNext.epochAuthenticator == rotate.next.epochAuthenticator)

        // SFrame keys from the epoch agree too.
        #expect(aliceNext.sframeKeys(suite: .aes256GcmSha512).map(\.keyID)
            == carolNext.sframeKeys(suite: .aes256GcmSha512).map(\.keyID))
        #expect(aliceNext.export(label: "x", length: 32) == carolNext.export(label: "x", length: 32))

        // Alice removes Carol; Carol is told, Bob follows.
        let carolLeaf = try #require(aliceNext.leaf(of: "carol/c"))
        let remove = try aliceNext.commit(removing: [carolLeaf])
        guard case .removed = try carolNext.process(remove.message) else {
            Issue.record("Carol was not told she was removed"); return
        }
        guard case .advanced(let bobAfter) = try rotate.next.process(remove.message) else {
            Issue.record("removal not followed"); return
        }
        #expect(bobAfter.epochAuthenticator == remove.next.epochAuthenticator)
        #expect(bobAfter.memberCount == 2)

        // A commit with its ML-DSA signature broken is refused.
        let forged = try remove.next.commit()
        var signature = forged.message.signature
        signature[signature.startIndex] ^= 1
        let tampered = MLSCommitMessage(
            groupID: forged.message.groupID, epoch: forged.message.epoch, sender: forged.message.sender,
            commit: forged.message.commit, signature: signature, confirmationTag: forged.message.confirmationTag
        )
        #expect(throws: MLSError.badSignature) { _ = try bobAfter.process(tampered) }
    }

    @Test("sizes on the wire: what one member costs a commit and a Welcome")
    func wireSizes() throws {
        var group = try MLSGroup.create(groupID: room, bundle: .generate(identity: "alice/a"))
        var commits: [Int] = []
        var welcomes: [Int] = []
        var packages: [Int] = []
        for index in 0 ..< 4 {
            let joiner = try MLSKeyPackageBundle.generate(identity: "member/\(index)")
            packages.append(joiner.keyPackage.encoded.count)
            let add = try group.commit(adding: [joiner.keyPackage])
            commits.append(add.message.encoded.count)
            welcomes.append(try #require(add.welcome).encoded.count)
            group = add.next
        }
        let commitPerMember = Set(zip(commits.dropFirst(), commits).map { $0 - $1 })
        let welcomePerMember = Set(zip(welcomes.dropFirst(), welcomes).map { $0 - $1 })
        // Two ML-KEM keys, an ML-DSA key and an ML-DSA signature.
        #expect(packages.allSatisfy { (7_600 ... 7_700).contains($0) })
        // One HPKE ciphertext (1,088 + 64 bytes) and its framing per member.
        #expect(commitPerMember.allSatisfy { (1_152 ... 1_164).contains($0) })
        // One leaf (identity, 1,952-byte ML-DSA key, 1,184-byte leaf key) per member.
        #expect(welcomePerMember.allSatisfy { (3_140 ... 3_170).contains($0) })
        print("pq-suite sizes: key package \(packages), commit +\(commitPerMember), welcome +\(welcomePerMember)")
        // The control plane's maxCommitBytes is 1 MiB: a room of 300 fits in
        // a Welcome, 800 in a rotation commit.
        let limit = 1 << 20
        #expect(800 * (commitPerMember.max() ?? 0) < limit)
        #expect(300 * (welcomePerMember.max() ?? 0) < limit)
    }

    private static let goKEMPublicKey = "961a4b40f61169ac045b3b780d28bf24111fedb0aaeffcc07798405c79a4b5037ca154a803e37c5babac02b36c40575b65eb95f157191d2314f1f63bfa060094b847cbf2b0f4a72c47e5baa7dccfdaf8bf85b07c471996fdb32692c4c472f42d0739616bb974c19151959278ddb763a1735248b7673be621069abf47616fb6e2ae4fa49e1fa8b2649507f619639a313228fb5ef2b407997898c95476d7354f66ea263a859f308c3cbac3a6ed1c4acd0bbf6e825cd23b0fcc989161cc144e393f7bd68c30a858c9b91584ba92b5cb030a425deea828eb8c4837d09bd5cc3e85e23065d280bfa391719abf25040c2ff3b5f30a07a3482d96271b5cbcb321a4cf0e026d66281aa43cc153c15fe88604d424526480c1516c51b5c97cd60a7fb7b63230345f051026c01c1827114751018ad5b496524c25afdb69913923503b1d45d274428c00c8904f4f068ed2a93bf46414da21608d552cb50c7b97913b0daa8718e15a09b071f9902753051e0d748cd0137cb4e800b5d5413a5149ae92b6a5b923ba48c593e8ca39318dd3864076c9081d02050a21875eb22cae70618ccbb4543282d3dcc8d4bb1acaba3d6db63aed6bcd14a4c4bde508e2cb1dba931a425789c264a4ccc88e48818fa9c6b62ada56a52241d264b5868b07eef171db9bbc7f9411bde75dfca5a6c43014c5d82943dc3710571e5ea4c3f634a151aa919925b94f83297319112146ba551491669c09e6ca7ba6c60e1c59410fc73fd1b40df8e3bd24438f96b77f9cc1a446e6b14b6c73c61539e7a90bbfe862a6ecb609fcb73dda07db0307bbf3aebada85eff5a4a5dc98f6560c2e6ba446b81f4465a9f4e69b0eb176b2fb461bea342a963b4de18f1659aa92077ec4628763438e32a27515d85221d905039b13c9d036fa30492544b745265585827748988cdf3381f64303402c45f1675b57405df5460e1b0ba269c57ae86a41134a7ebdc73ce776321d9935d2faa7a177a26b8833bd4c87de2b5b00fa2c61040439d6808cdc9fba33aa2d35c3c2377a0ea3b4bf362ef841309fd95fa128a19efb2080500ecfd59acf1c455c80060e801a20769929786955eb82a3d5335c7053c09cabf593ab66a22dc4a18cb28c042fb52d68d5a2ae21c6ad878854001b4c9694524217cebc5b1f329f7ac1026dc4b3157a8555935086a0530ea193846970b96c975f19213e1b75bb71b3d5283cad778adeb5ce06c77d106a49d2c23c86900ccb2c814f13c0067a088859952ad9af3ed1c83edac1572c9af24b7994c12b3dc52a921764eb2440cdec5dbaf73a37a1b634f8958a20977462cae90b0b7201282a87aa10797cbe246843a72b11d3cea8e78090c126adc2364d2335b9b90d5ec52a86f944169aa404b74324458ec6ca13bf9a6e6beca977eb1b3ef9803a720b1d0721674abc72414868092f70d4aa2eaca424e024ca924b690c463b70308f8033e80b13d106a376838404900febab633cfcc39b28630c71abbff24fc9f7c5cc57818c689251d96d90f7b83a42a96e38aaa3097c08eb8ab5a8084f7562b1029c93d153d0e1ca847375f7164b2c6384f2714d863b10efc1237c40bb241a10b2dc9f586535dba08d8baa312903064041a4781b18b7055f02a6ba88d220e6f9a12f0f470f5802d4a28ba7f1a2d2534f2bef"
    private static let goEnc = "686e9b1b2ad8b50426b0c1783d226af09602778df0b6679e5ba8f5e718a05fb6e400a70c42fc0d3eed71519110966d8ce2d176fef8769311d19cb2be9b040221941e7405feeaf03e257f2efaa073f0f2ca18adf805b447059bc8237b487480cb015eacc65d35454ec24334900be42318bcab95daf5a45ac08b1e7d17238e87caf72d5903b65602f876b02ad5d02eb4306e19eedd0edb20b5e6334b815cacefb96a12d68f12157a61294943569eedd8410b81054b6175ec996072e39c416dd684acb6ff7ea0699d0811d06566c1dfef3297765ae090c3bad25d93b176e62ea44f14edbf45627cceb60a994665c83d749968cdd20c8470ca57d1ecd78e5b3bc823970ca9ed7f65436e596342ece531084e1e2dcf5b5fd68d7d8a2d8699fb9724e5783a2c1af1cf43b42ac89016c2e06ef50f26909a9e9fca3bf6d5b6d7a3bfd0cea9043f6014d8c2dd5bafc8d2ed30dcab960214a24df49e47e412531f9130251ed74d7f6ececc053696da571d0f63421b064de89d5fde6cf26b101990c9e43b75bca82796718836205fe4cfea32de11e25bec90f9691d4b43a54a9ac9ea740b7f896555f29e427951869db99e0a16568337dd814cff7432a4ad54820cf2b083b21ecf7c1d01d4d7d7aefd71bdbfcdec23f77189dbb44af74f2f8a30651cc784975f07d44de1b6cabc9637fc11786b22c5c12343012857fb998a8e3006d7543efe4e0fbe32e73e5ea3ec051ec7f136140970519e4fcc9fcc5bfc9b2155fe9aeea4123a0c5ce7b913f3ff97f24fa7dc87ac6ee911f6488f238e8c9b4fbe0a0d6be515274509aa70aed89cb114f502a21f4a57e8ad11c206bf8e8db157d4c8adb408d06a9db4f48bab02700959437ca737ccc60f9bfbc4d7ad8201f8a6f5e176bcb427dbe127b1cc3338cf54a03adce7b7d2c0af4229f74644b609e1b9819ead58ca21a62529783e7602f17f0df8d08d4033019a0d1a717d8e40a5f8014d47810a33afc7aa3f30842f2bf93caa74c5f26f2f4a8b49c33ae5107b30bda85663178f9578492d050135ff1d76fd0c7edea8575e73ac5ce1756109c2e340c4562fe20829a7d43097c0c8314a05b549ac20f040741df888dfe0b4a7b6e750f7c12cbc8a2d21512583fc53a3b906153e9783b3f1018ac7470086a1b6c1c249cd0c3923154edc47a55e6837b8ff2d7385e0ada784b7b49ff3d9f048d2e1bc96fb5514c3861b85f64c1275e74b364320bbe9bfd45d0641daaeb3e9cb265d94eac00810561e06d0f3618f181a109b6cd57f7ad6afa903305ba348615f56c0a67bb5c7c7fc3df8b2ce3ce9dffe4f7d8e9405c26b8e7a3b93c132b8c5c17acfb6d468e4b8d988c03412f61befe78d0debda1985d603f96c751eab6363b51bf2b83eb854d26933d7313bac9416dbd2f7b39beab8cac4afe3e4c8c099e80ae30d73179b235f234df87671d3b9e435bf8f61a164f972199090b740c0c6f6f84c382781407d6d5d3fff0ee6d8cb606f6cf6616e9e8e3be04894bffd8f01bbcdb7196437677f063e6f3d"
    private static let goSignatureKey = "c0f4848649b3b8e661deb1d0f53ac876f32bd50eb812aab82021fda65f3f15fa4215c4ad08b829fa60bf60a59338b0f853ce593f86147f42c03608516456980428c785af9c003880c41fe3b47f800eff3033a8b6333d41bd6c1b9679e56c501c9d3abd49573ac4e20327fd182a0317fbb9f55dac2b03c6ebc364263d8ee24d3c32de5258d0e397f400ee70224a171f312e35be261cc18d14ff69bdaf1137bd936c0609a816ff1be4ddea9c3ad5d7940e45d1ab7a060248b2c4590afc982d0d11a840ee50fe32b3177b81bac9812f1cf423d16b7404ff6cb1a1b77f212db91495b757f6ecb360359f704f69f873d0e6031d2e7973bd72dc67f831535198fa8016a0ce50f65cc59dd39b7772902cf56c530657e1d3bbbc3e06d5837264a4ac1d43c1d7ed6cad5c83abc74ce6ce379d4e9d36ccfdddd5f1770d7dea73d62dce68b62196d1b175bd93a483b7274c294b2bd42c75cc05d60956c97d9f1164b4c115157a585ad231334e5afd99fae456eba19e57c167f33948dd951fa600cf7c80f5d49550d971c693e7a81fdf1dd42f1c9f383cede50b8654699385acabfaabbde232eaca05e5861895190f37d60f6053f01bc24ad10e4ab8e2eb767b2abbe6c73509d67a7bfa6c1366465e5d3ed2d8da88369fd01ce0e0a1cead01d93b9deab7a5b52f8e8517291c39397fdd69530a7d875ce3964b21bf6c3a24ccf5c52c215a010dd2112d2c58d7cd78ce3fff90eb32ef6749018f7071709a52510470b87aa444053cbc1762e62fb418043516c0232c150936a8cc6f25643dea5b1962be7701d2ddfd0811c099dd3b311443fd1c22decd8c77eb0c869abb96ae9b76ebdd3e044f53fccc8328ba4fd73857c52ce42faaabab925b7dc2da5bbd2e8bcbef2ea535c26f53d9a686ccc4cce6287981dcf41eab403cb18d224c5f24e56417496f0a1556bb35bf622193edbc11b0f33b8b4db8218cbb3cd75693a8ab4984d890e2aa04adcda099cae07f241d706cf8b8fb16b893c9d0011fe8b219339c8fe1a6d6305d866bc09137fcdc3138c9f784555835f22aa23824bfa517bd0bfb2427482f3bb29716a2fa88534c56fc45e683d322708944476b09c6acfd1fdffca5f7da8ac4e34d3cc07a5af236e30b1cacf6e716e5fe65267fea0b750e24ae09fa84cacf654378a2e72d3762d4b67ecf8220a6978f4b9ed99edacde45d61c3495cdc13823d1b13e95952a95e2ff0de9932f9c760feb4fb27c599a0e746b228cb85db5b824693f93589a5a2be01aa9e4ccb25e9a1a61ef41fde32743f013c2a7a5b5f3a4f01ad7c411e29a96c9692f2c1bbce8d0b72368cf75aa53df0aa4b26daac48afb35e64be1d35755b49354b08a3b2b806a2f99ffc8eca6944b146c5264562593a74cedbcfb467348d890442f62e6202ed8a428ed33e2075d5917e193a202c0de9f25ede01d341c8ce722f4e60891610634b0314e9363a5a4f0be83d386cfd04207ef5e84944c189be4a6ced826c5bead50fd3c6ae4892b1d2cc7684d2cc3dbe3104f1865901d02362e34ff2e7649ed36cdef071015bcc62b504b6587bccd2ab37b2fd2bf60026c910fcadaa8b51d16c0ece655279473a64ba5a990b0b69f851083db9a40f633a94540a90dd8521ad0a58b791d399699b4329d2c183fe6e60b9df44c24805c484740e07629251579124c00837ac370407f39fe3fcaf06c86fa8248f30a308b8e4cb3483f147c4d3e677bf5425bc5e4ab38973b8755c9210681416f00b93a4c5de62b2323acf6c4e173e0fc2402246b578ecae6f05fe48549a6d4bf11f37a413213e35df5448f05fe3aac10f0a74249dcef33ee9ccc47ee89a3bedef7d17d3b6940f7b76a5a0b9fc663e3653b67d639a386f0d177cfddb62338c914c95fd01e83921bfe0698b20adec0da8ddec3f2ce138199c5763043b02e33bc9176592222933789a41819535b2a695cb0fa5a1d6e131a68e3762c87035a99a7ed973b6de9351af100c4844e48848c628bfd974b83b0e468ad7a48b033ad491dd73601772dd1467ec1a289e81515efa1709bd23bf4200fc9eca985a19ef664455070cfda13489ed06bc9c255c1b5dae2f560b5effa43539a3f2df3de01acfdffbd112ed4c49c15c3dbc6321f692747da85f33e129bd655c698b78fb608fcc026cee865476011f8f77e149ec9a3d8782a6d2340c0db6922004af59d3db4ac7fd881ef647c8f8877439a50336c70209b93734b14d4ff28945471b31fc32b030f22240d2ca2714a482c39ca36d46467c484dfb966bb83548a45710bdaacee03b4d3532b541d16f48222b9cc91d473811f301e91383fb579578c30503ee91262caeec2f74afd293112d0f82f05f2bb85b1f2e510bad101e21b005a6ea1cdaedf541e030fcabcb3152223a28576785a1c49cbc9cb2c8db4ce7ab828fa7690de905d1c38dfe68a44d8061ce4a9376335cd0001d8b8a5d1f819e919f2bc52e5f3b25a24fa862cd94a2052eba9ed41614d4b07b38165b76846d84282f3df920d0ce19af8b1ff18890e9717fd9e25568185a663ccacb8462f16c471efc99f3b4892bae85ee71434e59e24bda03055fb03ec057c770079a5ddcfe2dd54186202d203ae4bb4335543cb05ec6c2ca82e6234889fa44c0a18b59c659a7e30eaebc9a8395ae406a707d15654d1428d9647a4e03c8aa98f4bc49e0d2240d7788dc072c86930ec5a31033305655d706ddeee2577e9a5d335bfb6014b205512e7da4327cce92d99e13dbcd80f32c"
    private static let goSignature = "598767feed3b76dfea25654fa50ba910a6690723a64ae90366bad326f8fbab27266ec643f581ae22ca4ad9b5ff795db0f258938f809d7772da74222ddc2eebcd3c77e0f67dabd44b2e5286108390e575b03863c7a6a069b4da9aca3bf98106be021e40a4116b094ee2c0eaf23e22ac27b64651c148bbcda32e9983bc2751cea3eeed0aed3c0d6f6b3652eff11495622a492c711f086a265b474bf6c869f56855dc169f01b2a9a7791a19c08d0a998f2d48033941edf81738921869a65fe606da98c4cc879f6d8c2db78f3fd8d3a9124c28a0a4da316005d47f182fad528e75f8b4895038289be814bba4f3b722c5dfe89e59001f111b81da730db2c535e6f601e9e07da90d4175e59e92b65a9b9c24b3d80c3ac7414e576720962bd5c1d2a9fa81ca42b92556e63946b44116eab1527d29cfdecd2bbbb1a7f28bc2feff8be189273ae5e6a7bf46d29e0993b1c5858d46bd1d3c79b6adf88b23de433b59f4cd05c8b1ce04e5c817ce8a454e81870e2e20c0b4fb8b907e8fa8609285719197d6103b8106e679e009f68457657c3b412b01d3a596be067ac2941a361a75f3e1ae62c97d02e3e59e020a61b1888ff62c60380f977750db6bb791106cb5f3d66b03c06f6cbe7f0e7b5516c0d370fb871ca366d7dd5752b8578b52a1e7d17602620156ba782ffbf2b15d2f1699e4056a5c24c83781dacbe4f60c7a8ea94872807cb20a6e8c4ddcc9477d4c709a6cb8f308f62f8ddf65f7fc2f44b7d0448dac88f8a3e6ed6803bb47d2e524b0a8ab78308e68e1a96efe78afdb77d46551dac55f8be60eb758ce83acd10bddecc0bb0304fcd3de70ceed37f23f2f87d81203f73e54cecdbb46889cc7444111e4835f9277a65e59de58cc609f0c0a17ce15183b7d123c0645dee7a1f3a63a027047b14fe613c8f55ed4c90b2e7accf1f7a96d930e5bdec53c54af8c9a82d67f34e3916f1cdf1776f48ed207dc07c54b49863825abd779e075112efa77eaea2b0f1603d12ae97c418bb2facf080bff8a57fbde0e175813b0e4e8b0a86342a364fbc210004514720eb45c2c40b2d54d56cfca34b8e25eccf538336dd780bb1ad4d74ddb51aa5e150345b73e0d9c11d21fcd3e56c430a1ac8658b9ffbe4b01809554beeb141e68b9b63867372eb3cf4bfe19e65036628853a723e9a4b24f066302efcae57c2bfc2bfa7c6f8c5687b011558658b721f96dd6d137178ea79257252726c1616a6e27e997511954ae72301b1a577bd092030429e1b4c695b30f95f8b500a48d864e8620a85c6c0ad6ad8bf93b7e49211c121519b38c80ce5214e041c5c94cabcebfff97a024c988f396476fca6e3ce20f18823f6654dbab2517950765010016b122e60462890345afae2bc75aa6563634754bd9e05b188a1bb4fa1ea90f2bebfbcf46ea86e97f1576ab800508157ca14479df31a6afa6f32d3976e25b019825ba1b1e63f798c3c51f5c6479b1e32bcc707fb85e1a6b3958c53b4e76fbca9462d249d513ee3e6082fe0b7899c322f79031d74c0de8d9ef8872119787a8857ada299d15b2f72bfce9ecef11cf9d822ac94d3368af9a479ae0a3dd75acd098120ebfd581eac12c44c33ed9fcd70be67a848b65d9b25b015ea79e91b7d6a603449417fc18e877ff5e162c1982ee237909ca030cb1ad28def976e37ba09a92ec6abd539289219d3a105e52ea09f6cef4cd17543d9068f5a704c4b17e407da582b91362ffead837c89537de71f08884622ea29151f61651823622308d3384a620a97905065844ec8fe76c00d2bdb2b0eedeb260b6ccc510fd0f518c43649828b7044f76d34d88e23f71f69d16d3c993e455aed06eae007b3c502d96a1d25ddf27ebf10ac53328d1528ea88073a56069e21f2a8fd7675c47fb15ccddf94c45f1192ae01ca6f5ac239d86d9713fc92cb5bf3e76256c557160efd824461147a24eae10bc5c729325964ec6a15a200490d3ddb115a79fbe3cfd3d35d1a5203c8ea809cfe815364dc2bf644333c2ad59a2b669c392c9b8aa393ded52694851f3173986a5efe6a332439a389749c6442c0828d8397d34b7350ff6fadd1a4520d1b7e981b505f448fd542363b62aefb8ccb19079b644dcbf2f976b053b07487ad3fc3794ebe407b96b898213e23aff057c42e875232ed4894f3f2277126ae360850e4a46bdcf0ab698bbfafdaa1b7c7ee2732a42f9167f6f810916aab9f723032e79d3fba7ffd99ee15af01fdae309acc0a0531b543abcdf91a830c694148ba746800aa251fec9fbfda0edcae7ac3420da9684a4072883163700db3a32be691610896c325e46fb4bad6d7c49a24e28315a683aa0d53eb3851a701df62027ffd827f8024a630a7b202e7f369c904ea6217cf4f6652dc311baf1264f5fa3292db9896d8ff8e0cad210631507a769785d1a402a153d42200f67fc86bddea57dbbe144022806c28f2cb31d8674080628e3e337166bf5a10a39687736f58762cd046486d50bc384aa70ee304bb5f2381e13fe34dc8c009ac93301631af718e457b6b057d87b6a9dcf9da5433d0be26231e02f545ca172a220e5b8fcf6a8d9aeeb892f7692ff194e9dbefb276ce5aa32d739827d5887302b9416e5d513897ac85c94ad22b707efa5e02c6c5c281976f76ff7bf31306624f6bcb67b3fdb94138ab6f94948ef933839c48a9bae134d35cfe7586290aaaf71d2511a02d7cec9807f4591c56865619a1294f8ec5af95b1f42a234b330f99995859569e8209cb55a9415ed85a3653b58d157bf155a3f62810b119805d5d214c94d657f14fb0945cfc1c122b8263e3bef23be8d6bb23ef2641ec96233e6711e553241f31eb140cb99587e4c59e1f7489429f61ecbe64e76fb0ceb7034c0dcb89e118fd9d24d188c50c9a413460064ff00d97c1bb6964456ed05fa03af37594ef433b8c4e24f88319291ad97bbccc20ef87634528d1f34cd408a0afa0366d56a75cf702c02677757bbe58d7dbee23ba3c901a3c5b25f70b0752a7c8d2e708fbe1c336fe5e91569b4ab006bdf471627ff4f42815f24d369962d72f50c87e08363f149edd30aa7d5edd91f154227a548d3a16dd4444a41cd724284398375b7a4d77d634a99d3d3dc783e0632435be499ccc3727ed0e8a95224ed6bcdca73aea59cdf8ba656895d8359c2442f83efed08fed6c29fbda716fe7c23b0bdf6b4d831fcc9c30661e037fb94ea6c34c3dbf26c73942049c6cf376b81c8beaad6e2c7e515ad01485185a7a11e6c984273035f017f85b5ef34b064c98fd812f5d65bddb4f3db009c63d91c1061984895e5d7794405a9d23eb20b6d363ff173305b6837ddbee9c472dd66d69360a90ac61f15fedc8f957c3a6e89a68ea55e4cfd0bd3a706081084767072f2f28d6ee7cd0c6c90e0c9e658689c5c9ec7eb0a5b69b215afe79cdac0894461fba66fb54875000c078c014184f03da26e29715d4f392573b32e59aa2fbc631f5c3213b6eac62f4c2c3d8162f2e062a77b87b53c2d566690603576ebcc9cf1e189a96806afd1e020ff2e26ef1763bf2231a7bd7042240b2d1b70e8e6cac10e73b8fab41ca2390c33f6ab2cd148b343d4aeb2e96f5bb03838347082aa954666bf8c33622eec6331f130ff7a112dfe5a512e4974e18efb922a0b32d71b4ff82539ea3cc3c72317f02f251bd983005308d4c23c2043be007277b246c24c8830d9d93b22fc1c4f6f5cb7efba8b22274a2ace8722a1ad46d2343aa367aa825f8e59d278301f64e3ecf5b30819bde50642af7500d1867ca65eeae21b1d0b6a1b794a478f7b4ba19613fd4d9f27aef6765d34942456a37aecf5ee86009f0b120baa6b4fe1589d3246ba8c5675fae5210f9593660fa47f1671ee37766a6a9f6e74885205d00101ef7cb4340b9a9335e25be32d076dc6d890c2021597b9af5614c6d8243d64632debcb2b415e3c5ad696abbbc182b922214ccf31b7dc2dff883df37b1a18c80ff44f4d2b9bcdd48f07fca06829246a0451c1b4c64d7f8ae7ff2b975381ba349da36f10588e31da833a710fa82bd6e9e90ce9ef2b9655e1059bbcd850e9ede225987aa5ab5978d4896b92df738c146a54f047f5ddebfab2ad4f5bfe2c62e5f5dfea72f291753603bd1cb36bb9131fc2ed20a4cff49afb8a15dc009b084f14b4e6910f15c6510556fed661b6978412d1807572b91fbd9ad041152a4c0c5ca185f8f7c4e47937806cc9657ca6a89bb125dc5935046df0f48d0dec48570e648b37cf8dbc84fd6f2ea2ef1b7aef3c6751095602a33494faa8ce967615c751c1fd4983b11b5bc869a53ee8a8a5fa2d150ddeba7793eb1bdf9d92706531ae004761387d1f72cf26f811de93a3263489f79e5af4aa422e7e9852d2c47505af50d6f4d8e9d3cecbbaafe78cca36b4bca311080a0aaed1eef683ac73729cb15fd6024d9c26a1ff5c33ec081a184ad4c3dade4723b2047cdb1309f23f5cf58d25b5bb1f630c3aece52c85f8fbf520cf86a655cc78b1e162af36827ac943b241b9751ab46e417d34965a786910d91b743b2e4315a61537b71df9c30a29249c4c17c5e813f55129b26f7338f5d1d35ac9145f2bcd71422a1b385f6886f1f213234c5e6788fa238ca4c8343c8999b3c6f01518313a50c0cf21368caccdea0000000000000000000000000000000000070e12192026"
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
