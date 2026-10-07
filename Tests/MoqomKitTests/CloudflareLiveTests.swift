// `Draft16Session` against Cloudflare's public draft-16 relay, over real QUIC.
//
// The unit tests drive a scripted relay, which proves the bytes match what this
// package believes draft-16 says. Only a real relay proves that belief matches
// Cloudflare's. Skipped unless asked for, because it needs the network and a
// token Cloudflare issues for its demo stream:
//
//     MOQOM_CF_DEMO_TOKEN=<jwt> swift test --filter CloudflareLiveTests
//
// or, to read the token from Cloudflare's demo-streams page at test time:
//
//     MOQOM_CF_DEMO_TOKEN=fetch swift test --filter CloudflareLiveTests
//
// The token is never printed and never written down; keep it out of the
// repository either way.

#if canImport(Network)
    import Foundation
    import Testing

    @testable import MoqomCore
    @testable import MoqomKit

    @Suite(
        "Cloudflare's draft-16 relay, live",
        .serialized,
        .enabled(
            if: ProcessInfo.processInfo.environment["MOQOM_CF_DEMO_TOKEN"] != nil,
            "set MOQOM_CF_DEMO_TOKEN to a token, or to `fetch`, to run these"
        )
    )
    struct CloudflareLiveTests {
        static let demoPage = URL(string: "https://developers.cloudflare.com/moq/demo-streams/index.md")!

        /// The token from the environment, or from the demo page's moq-sub
        /// command, which carries it in the relay URL's path.
        private static func token() async throws -> String {
            let configured = try #require(ProcessInfo.processInfo.environment["MOQOM_CF_DEMO_TOKEN"])
            guard configured == "fetch" else { return configured }
            let (data, _) = try await URLSession.shared.data(from: demoPage)
            let page = String(decoding: data, as: UTF8.self)
            let pattern = /draft-16\.cloudflare\.mediaoverquic\.com\/(eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+)/
            let match = try #require(page.firstMatch(of: pattern), "no draft-16 token on the demo page")
            return String(match.output.1)
        }

        /// The first object a subscription delivers, or `nil` after `limit`.
        private static func firstObject(
            of subscription: any SubscriptionHandle,
            within limit: Duration
        ) async -> TrackObject? {
            await withTaskGroup(of: TrackObject?.self) { group in
                group.addTask {
                    for await object in subscription.objects { return object }
                    return nil
                }
                group.addTask {
                    try? await Task.sleep(for: limit)
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
        }

        @Test("SETUP, then a subscription under bbb delivers an object")
        func subscribe() async throws {
            let endpoint = RelayEndpoint.cloudflare(token: try await Self.token())
            let transport = MoqtTransport.network()
            let session = try await transport.connect(
                to: endpoint,
                credentials: DeviceCredentials(
                    identity: identity("demo", device: "live-test"),
                    token: Data(),
                    deviceKey: nil
                )
            )
            #expect(session is Draft16Session)
            #expect(await session.negotiated.alpn == "moqt-16")

            // The init segment is published once, so it is asked for
            // unfiltered — what the relay has cached — the way moq-sub asks.
            let namespace = try TrackNamespace(["bbb"])
            let initSegment = try await session.subscribe(
                SubscribeRequest(track: FullTrackName(namespace: namespace, name: TrackName("0.mp4")), start: .latestGroup)
            )
            let object = await Self.firstObject(of: initSegment, within: .seconds(15))
            let received = try #require(object, "no object on bbb/0.mp4 within 15 s")
            print("cloudflare live: bbb/0.mp4 group \(received.group) object \(received.object), \(received.payload.count) bytes")
            #expect(received.payload.count > 8)
            #expect(received.payload.dropFirst(4).prefix(4) == Data("ftyp".utf8))

            // A media track, from the next group: proves live delivery rather
            // than a cached object.
            let media = try await session.subscribe(
                SubscribeRequest(track: FullTrackName(namespace: namespace, name: TrackName("1.m4s")))
            )
            if let live = await Self.firstObject(of: media, within: .seconds(15)) {
                print("cloudflare live: bbb/1.m4s group \(live.group) object \(live.object), \(live.payload.count) bytes")
            } else {
                Issue.record("no object on bbb/1.m4s within 15 s")
            }

            await media.cancel()
            await initSegment.cancel()
            await session.close(code: 0, reason: "done")
        }
    }
#endif
