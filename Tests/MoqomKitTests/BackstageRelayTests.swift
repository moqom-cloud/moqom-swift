// Backstage and going live, on `moqom-relay` with tokens verified.
//
// The loopback relay lets anybody publish and read anything, so the rules that
// make backstage a green room — only a backstage grant publishes there, only it
// or the people running the room read there, and a backstage grant may not
// publish on stage — are not exercised by any loopback test. Neither is what a
// relay does when a renewed token moves somebody onto the stage: it withdraws
// what the old grant covered, ends their backstage watch and their tickets, and
// leaves the client to start again under the stage slot. These tests run the
// room, its direct paths and the move against a relay that does all of that.
//
// Skipped unless `MOQOM_RELAY_BIN` names a relay; see `RelayInteropTests`.

#if os(macOS)
    import Foundation
    import MoqomCore
    import MoqomDirectTesting
    @testable import MoqomKit
    import MoqomWire
    import Testing

    @Suite("Backstage on a relay that enforces it", .enabled(if: RelayProcess.isAvailable), .serialized)
    struct BackstageRelayTests {
        static let roomKey = Data(repeating: 0x42, count: 32)
        static let offerSecret = Data(repeating: 0x17, count: 32)

        /// A relay that verifies `DirectTokens` and issues tickets signed by
        /// `DirectTicketDesk.signer`.
        static func enforcingRelay() throws -> RelayProcess {
            let directory = FileManager.default.temporaryDirectory
            // Fixed names, because the keys are fixed: each run rewrites the same
            // two files rather than leaving more behind. Not removed, since the
            // relay reads them after it says it is listening.
            let tokens = directory.appendingPathComponent("moqom-backstage-test-jwks.json")
            let tickets = directory.appendingPathComponent("moqom-backstage-test-tickets.json")
            let tokenKey = DirectTokens.signer.publicKey.rawRepresentation.base64URLEncodedString
            let ticketKey = DirectTicketDesk.signer.publicKey.rawRepresentation.base64URLEncodedString
            let ticketSeed = Data(repeating: 13, count: 32).base64URLEncodedString
            try Data(#"{"keys":[{"kty":"AKP","alg":"ML-DSA-65","kid":"test-key","pub":"\#(tokenKey)"}]}"#.utf8)
                .write(to: tokens, options: .atomic)
            try Data(
                #"{"keys":[{"kty":"AKP","alg":"ML-DSA-65","kid":"\#(DirectTicketDesk.kid)","pub":"\#(ticketKey)","priv":"\#(ticketSeed)"}]}"#
                    .utf8
            ).write(to: tickets, options: .atomic)
            return try RelayProcess.start([
                "MOQOM_RELAY_JWKS": tokens.path,
                "MOQOM_RELAY_ALLOW_ANY_ISSUER": "true",
                "MOQOM_RELAY_TICKET_KEYS": tickets.path,
                "MOQOM_RELAY_STUN_ADDR": "off",
            ])
        }

        /// A token for `device` in `room-42`: on stage, or backstage. Never the
        /// room's owner, who may read backstage whatever the grant says.
        static func token(_ device: DirectDevice, publish: Int = 0x0F, backstage: Bool) -> Data {
            DirectTokens.mint(
                user: device.user, key: device.key, publish: publish,
                extraScope: ["own": false, "bs": backstage]
            )
        }

        struct Person {
            let device: DirectDevice
            let session: MoqomSession
            let room: RoomSession
            var identity: ParticipantIdentity { room.identity }
        }

        static func join(
            _ device: DirectDevice,
            on relay: RelayProcess,
            publish: Int = 0x0F,
            backstage: Bool = false
        ) async throws -> Person {
            let credentials = try device.credentials(token(device, publish: publish, backstage: backstage))
            let session = MoqomSession(
                transport: relay.transport,
                credentials: credentials,
                tenant: "acme",
                directPolicy: .custom(DirectRooms.options(offerSecret: offerSecret))
            )
            do {
                try await session.connect(to: relay.endpoint)
            } catch {
                Issue.record("\(device.user) could not connect: \(error), log:\n\(relay.logContents)")
                throw error
            }
            let room = try await session.join(room: "room-42")
            try await room.useEncryption(.sharedKey(roomKey))
            return Person(device: device, session: session, room: room)
        }

        /// A bare MOQT session, for asking the relay things the SDK never asks.
        static func raw(
            _ device: DirectDevice,
            on relay: RelayProcess,
            publish: Int = 0,
            backstage: Bool = false
        ) async throws -> MoqtSession {
            try await relay.connect(
                alpn: "moqt-22",
                credentials: device.credentials(token(device, publish: publish, backstage: backstage))
            )
        }

        static func backstageSlot(_ who: ParticipantIdentity) throws -> TrackNamespace {
            try MoqomNamespaces.backstageParticipant(tenant: "acme", room: "room-42", identity: who)
        }

        static func stageSlot(_ who: ParticipantIdentity) throws -> TrackNamespace {
            try MoqomNamespaces.participant(tenant: "acme", room: "room-42", identity: who)
        }

        /// Whether `room` reports an event matching `match` within ten seconds.
        static func waitFor(
            _ room: RoomSession,
            _ match: @escaping @Sendable (RoomEvent) -> Bool
        ) -> Task<Bool, Never> {
            let events = room.events
            let reader = Task {
                for await event in events where match(event) { return true }
                return false
            }
            return Task {
                let timeout = Task {
                    try? await Task.sleep(for: .seconds(10))
                    reader.cancel()
                }
                defer { timeout.cancel() }
                return await reader.value
            }
        }

        /// The relay's refusal of `announcement`, if it says so within
        /// `timeout`. An accepted announcement has no answer until it ends.
        static func refusal(
            of announcement: any AnnouncementHandle,
            within timeout: Duration = .seconds(2)
        ) async -> MoqomError? {
            let answer = Collector<MoqomError?>()
            Task { await answer.append(await announcement.refusal) }
            _ = await eventually(timeout: timeout) { await !answer.items.isEmpty }
            return await answer.items.first ?? nil
        }

        static func direct(_ room: RoomSession, to who: ParticipantIdentity) async -> Bool {
            let path = await room.directPaths[who]
            return path?.state == .direct && (path?.objectsOverDirect ?? 0) > 10
        }

        @Test("a cohost backstage is seen by backstage and not by the stage")
        func backstageIsHidden() async throws {
            let relay = try Self.enforcingRelay()
            defer { relay.stop() }
            let alice = try await Self.join(DirectDevice(user: "alice"), on: relay, backstage: true)
            let bob = try await Self.join(DirectDevice(user: "bob"), on: relay, backstage: true)
            let carol = try await Self.join(DirectDevice(user: "carol"), on: relay, publish: 0)
            let cameras = [DirectCamera(), DirectCamera()]
            defer { for camera in cameras { camera.stop() } }
            try await cameras[0].broadcast(on: alice.room, backstage: true)
            // A device watches backstage from the moment it publishes there.
            try await cameras[1].broadcast(on: bob.room, backstage: true)

            let a = alice.identity, b = bob.identity
            #expect(await eventually(timeout: .seconds(10)) {
                await bob.room.roster[a]?.slot.isBackstage == true
            }, "a cohost backstage should see another, log:\n\(relay.logContents)")
            #expect(await bob.room.currentState.backstage.map(\.id).contains(a))
            #expect(await carol.room.roster[a] == nil)
            #expect(await carol.room.roster[b] == nil)

            // What the viewer's SDK does not try, the relay refuses anyway.
            let viewer = DirectDevice(user: "dave")
            let raw = try await Self.raw(viewer, on: relay)
            let video = try FullTrackName(namespace: Self.backstageSlot(a), name: TrackName("video/360p"))
            let offers = try FullTrackName(namespace: Self.backstageSlot(a), name: TrackName(DirectOffers.trackName))
            for track in [video, offers] {
                await #expect(throws: MoqomError.self, "\(track) is backstage") {
                    _ = try await raw.subscribe(SubscribeRequest(track: track))
                }
            }
            let watch = try await raw.announcements(matching: MoqomNamespaces.backstage(tenant: "acme", room: "room-42"))
            var seen: [AnnouncementEvent] = []
            for await event in watch { seen.append(event) }
            #expect(seen.isEmpty, "a viewer's watch of backstage ends with nothing in it")

            await raw.close(code: 0, reason: "done")
            for person in [alice, bob, carol] { await person.session.close() }
        }

        @Test("only a backstage grant publishes backstage, and it does not publish on stage")
        func backstageNeedsTheGrant() async throws {
            let relay = try Self.enforcingRelay()
            defer { relay.stop() }
            let eve = DirectDevice(user: "eve")
            let stage = try await Self.raw(eve, on: relay, publish: 0x0F, backstage: false)
            let eveID = try eve.credentials().identity
            let refused = try await stage.announce(Self.backstageSlot(eveID))
            #expect(await Self.refusal(of: refused, within: .seconds(10)) != nil, "a stage token announced backstage")
            let allowed = try await stage.announce(Self.stageSlot(eveID))
            #expect(await Self.refusal(of: allowed) == nil)

            let frank = DirectDevice(user: "frank")
            let waiting = try await Self.raw(frank, on: relay, publish: 0x0F, backstage: true)
            let frankID = try frank.credentials().identity
            let onStage = try await waiting.announce(Self.stageSlot(frankID))
            #expect(await Self.refusal(of: onStage, within: .seconds(10)) != nil, "a backstage token went live without a new one")
            let backstage = try await waiting.announce(Self.backstageSlot(frankID))
            #expect(await Self.refusal(of: backstage) == nil)

            // Through the SDK: the room says so, and nobody backstage sees it.
            let host = try await Self.join(DirectDevice(user: "gina"), on: relay, backstage: true)
            let guest = try await Self.join(DirectDevice(user: "hal"), on: relay)
            let interrupted = Self.waitFor(guest.room) { if case .broadcastInterrupted = $0 { true } else { false } }
            let camera = DirectCamera()
            defer { camera.stop() }
            try await camera.broadcast(on: guest.room, backstage: true)
            #expect(await interrupted.value, "the room should say the relay refused the backstage slot")
            #expect(await host.room.roster[guest.identity] == nil)

            for session in [stage, waiting] { await session.close(code: 0, reason: "done") }
            for person in [host, guest] { await person.session.close() }
        }

        /// Alice and Bob wait backstage on a direct path to each other while
        /// Carol is on stage. Alice goes live, by renewing on the same
        /// connection or by reconnecting, and her direct path moves with her.
        @Test("going live moves a cohost from the backstage pairing to the stage one", arguments: [false, true])
        func goingLive(reconnects: Bool) async throws {
            let relay = try Self.enforcingRelay()
            defer { relay.stop() }
            let waiting = try await Self.join(DirectDevice(user: "alice"), on: relay, backstage: true)
            let bob = try await Self.join(DirectDevice(user: "bob"), on: relay, backstage: true)
            let carol = try await Self.join(DirectDevice(user: "carol"), on: relay)
            // Alice's second camera is for going live: a stopped publication
            // finishes its source.
            let cameras = [DirectCamera(), DirectCamera(), DirectCamera(), DirectCamera()]
            defer { for camera in cameras { camera.stop() } }
            try await cameras[0].broadcast(on: waiting.room, backstage: true)
            try await cameras[1].broadcast(on: bob.room, backstage: true)
            try await cameras[2].broadcast(on: carol.room)

            let a = waiting.identity, b = bob.identity, c = carol.identity
            #expect(await eventually(timeout: .seconds(10)) {
                let backstage = await waiting.room.roster[b] != nil
                let back = await bob.room.roster[a] != nil
                let stage = await waiting.room.roster[c] != nil
                return backstage && back && stage
            })
            // One layout each: each of these replaces the room's whole layout.
            var drains = [await drainFrames(of: b, on: waiting.room), await drainFrames(of: a, on: bob.room)]
            defer { for drain in drains { drain.cancel() } }

            #expect(await eventually(timeout: .seconds(30)) {
                let there = await Self.direct(waiting.room, to: b)
                let back = await Self.direct(bob.room, to: a)
                return there && back
            }, "backstage cohosts should pair")
            if await !Self.direct(waiting.room, to: b) {
                Issue.record("""
                alice: \(await waiting.room.directPaths), bob: \(await bob.room.directPaths), log:
                \(relay.logContents)
                """)
            }
            // Backstage pairs only with backstage.
            #expect(await waiting.room.directPaths[c] == nil)
            #expect(await carol.room.directPaths[a] == nil)
            #expect(await carol.room.directPaths[b] == nil)

            // Alice goes live.
            let alice: Person
            if reconnects {
                await waiting.session.close()
                alice = try await Self.join(waiting.device, on: relay)
            } else {
                alice = waiting
                let revoked = Self.waitFor(alice.room) { if case .publishingRevoked = $0 { true } else { false } }
                try await alice.session.updateCredential(IssuedToken(
                    token: Self.token(alice.device, backstage: false),
                    expiresAt: Date().addingTimeInterval(600), username: "alice", room: "room-42"
                ))
                // The relay ends what the backstage grant covered.
                #expect(await revoked.value, "the backstage publication should be revoked")
            }
            try await cameras[3].broadcast(on: alice.room)
            drains.append(await drainFrames(of: c, on: alice.room))

            // The stage sees and receives her, under the stage slot.
            #expect(await eventually(timeout: .seconds(10)) {
                await carol.room.roster[a]?.slot.isBackstage == false
            }, "the stage should see alice live, log:\n\(relay.logContents)")
            drains.append(await drainFrames(of: a, on: carol.room))
            #expect(await eventually(timeout: .seconds(15)) {
                (await carol.room.videoStatistics(for: a)?.framesProduced ?? 0) > 10
            }, "the stage should receive alice")
            #expect(await bob.room.roster[a]?.slot.isBackstage == false)

            // She pairs with the stage now, and with nobody backstage.
            #expect(await eventually(timeout: .seconds(30)) {
                let there = await Self.direct(alice.room, to: c)
                let back = await Self.direct(carol.room, to: a)
                return there && back
            }, "alice and carol should pair on stage, log:\n\(relay.logContents)")
            #expect(await eventually(timeout: .seconds(10)) {
                await bob.room.directPaths[a]?.state != .direct
            })
            #expect(await alice.room.directPaths[b] == nil)
            #expect(await carol.room.directPaths[b] == nil)
            // Somewhere she can no longer read is not somewhere she is shown.
            #expect(await alice.room.currentState.backstage.isEmpty)

            for person in [alice, bob, carol] { await person.session.close() }
        }
    }
#endif
