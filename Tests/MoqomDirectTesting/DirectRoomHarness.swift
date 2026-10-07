// Rooms with direct paths on a loopback relay: people holding tokens a direct
// peer accepts, a synthetic camera each, and a stand-in for the relay's ticket
// issuer, which the loopback relay does not have.

import CryptoKit
import Foundation
import MoqomCore
import MoqomKit
import MoqomLoopback

// MARK: - Tickets

/// Issues direct tickets on a loopback relay, as `moqom-relay` does: for every
/// ordered pair of people, a fresh ticket every `period` on the holder's slot,
/// track `.direct/{peer}`.
public actor DirectTicketDesk {
    public static let signer = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 13, count: 32))
    public static let kid = "room-ticket"

    private let relay: LoopbackRelay
    private var people: [DirectDevice] = []
    private var writers: [FullTrackName: any TrackWriter] = [:]
    private var connection: (any TransportSession)?
    private var issuing: Task<Void, Never>?
    private var group: UInt64 = 0
    public private(set) var lifetime: TimeInterval

    public init(relay: LoopbackRelay, lifetime: TimeInterval = 90) {
        self.relay = relay
        self.lifetime = lifetime
    }

    public func admit(_ device: DirectDevice) {
        people.append(device)
    }

    /// Start issuing, every `period`.
    public func open(every period: Duration = .milliseconds(250)) async throws {
        if connection == nil {
            let desk = DirectDevice(user: "relay")
            connection = try await LoopbackTransport(relay: relay).connect(
                to: RelayEndpoint(host: "loopback"), credentials: try desk.credentials()
            )
        }
        issuing?.cancel()
        issuing = Task { [weak self] in
            while !Task.isCancelled {
                await self?.issue()
                try? await Task.sleep(for: period)
            }
        }
    }

    /// Stop issuing, as a relay does for a participant no longer eligible.
    public func close() {
        issuing?.cancel()
        issuing = nil
    }

    private func issue() async {
        guard let connection else { return }
        group += 1
        for holder in people {
            for peer in people where peer.name != holder.name {
                guard let track = Self.track(holder: holder, peer: peer) else { continue }
                if writers[track] == nil {
                    writers[track] = try? await connection.publish(track, priority: 0)
                }
                let issued = Date()
                let payload = Self.object(
                    Self.mint(holder: holder, peer: peer, issued: issued, lifetime: lifetime),
                    expires: issued.addingTimeInterval(lifetime)
                )
                try? await writers[track]?.write(TrackObject(group: group, object: 0, priority: 0, payload: payload))
            }
        }
    }

    public static func track(holder: DirectDevice, peer: DirectDevice) -> FullTrackName? {
        try? FullTrackName(
            namespace: TrackNamespace(["acme", "r", "room-42", holder.user, String(holder.key.thumbprint.prefix(16))]),
            name: TrackName(".direct/\(peer.name)")
        )
    }

    static func mint(holder: DirectDevice, peer: DirectDevice, issued: Date, lifetime: TimeInterval) -> Data {
        DirectTokens.jws(
            ["alg": "EdDSA", "typ": DirectTicketCheck.type, "kid": kid],
            [
                "ten": "acme",
                "room": "room-42",
                "sub": holder.user,
                "dev": String(holder.key.thumbprint.prefix(16)),
                "peer": peer.name,
                "iat": Int(issued.timeIntervalSince1970),
                "exp": Int(issued.addingTimeInterval(lifetime).timeIntervalSince1970),
            ]
        ) { try! signer.signature(for: $0) }
    }

    static func object(_ ticket: Data, expires: Date) -> Data {
        let x = DirectTokens.base64URL(signer.publicKey.rawRepresentation)
        let keys: [[String: Any]] = [["kty": "OKP", "crv": "Ed25519", "kid": kid, "x": x]]
        let object: [String: Any] = [
            "version": 1,
            "ticket": String(decoding: ticket, as: UTF8.self),
            "expires": Int(expires.timeIntervalSince1970),
            "keys": keys,
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }
}

// MARK: - People

/// Somebody in the room: their device, their session, and the room.
public struct DirectRoomPerson: Sendable {
    public let device: DirectDevice
    public let session: MoqomSession
    public let room: RoomSession

    public var identity: ParticipantIdentity { room.identity }
}

public enum DirectRooms {
    public static let rung = VideoLayer(
        id: "video/360p", size: PixelSize(width: 640, height: 360), frameRate: 30, bitrate: 600_000
    )

    /// Options as a test wants them: quick to settle, quick to retry, offered
    /// on loopback.
    public static func options(
        offerSecret: Data? = nil,
        tickets: DirectTicketSettings = DirectTicketSettings(grace: .seconds(10), represent: .seconds(1), skew: .seconds(30))
    ) -> DirectRoomOptions {
        var options = DirectRoomOptions(
            exposure: .peersWillLearnMyIPAddresses(),
            tokenKeys: DirectTokens.keys,
            offerSecret: offerSecret,
            patience: .seconds(4),
            path: DirectPathSettings(settle: .milliseconds(200)),
            tickets: tickets,
            retry: .milliseconds(200)
        )
        options.advertisedHost = "127.0.0.1"
        return options
    }

    /// Join `room-42` on `relay` as `user`.
    ///
    /// - Parameters:
    ///   - publish: the token's publish mask; `0` is a viewer.
    ///   - sharedKey: an application key for the room, instead of managed MLS.
    ///   - keyDelivery: an MLS delivery service for this person, for a room
    ///     that keys itself.
    public static func join(
        _ user: String,
        relay: LoopbackRelay,
        publish: Int = 0x0F,
        sharedKey: Data? = nil,
        keyDelivery: (@Sendable (ParticipantIdentity) async -> any MLSDeliveryService)? = nil,
        backend: DirectBackend = .networkFramework
    ) async throws -> DirectRoomPerson {
        let device = DirectDevice(user: user)
        let base = try device.credentials(DirectTokens.mint(user: user, key: device.key, publish: publish))
        let credentials = DeviceCredentials(
            identity: base.identity,
            token: base.token,
            deviceKey: device.key,
            keyDelivery: await keyDelivery?(base.identity)
        )
        let session = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials,
            tenant: "acme",
            directBackend: backend
        )
        try await session.connect(to: RelayEndpoint(host: "loopback"))
        let room = try await session.join(room: "room-42")
        if let sharedKey { await room.useEncryption(.sharedKey(sharedKey, keyID: 1)) }
        return DirectRoomPerson(device: device, session: session, room: room)
    }
}

// MARK: - Cameras

/// A synthetic camera publishing at about 30 frames a second until stopped.
public final class DirectCamera: Sendable {
    public let source = FrameRelay(format: CaptureFormat(size: DirectRooms.rung.size, frameRate: 30), depth: 16)
    private let feeding: Task<Void, Never>

    public init() {
        let source = source
        feeding = Task {
            var index: UInt64 = 0
            while !Task.isCancelled {
                source.submit(VideoFrame(
                    timestamp: FrameTimestamp(nanoseconds: index * 33_000_000),
                    size: DirectRooms.rung.size,
                    surface: .synthetic(byteCount: 512),
                    forcesKeyFrame: index % 30 == 0
                ))
                index += 1
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    /// Go live with this camera on `room`'s stage.
    @discardableResult
    public func broadcast(on room: RoomSession) async throws -> Broadcast {
        try await room.startBroadcast(
            from: source,
            configuration: BroadcastConfiguration(
                ladder: LayerLadder(rungs: [DirectRooms.rung]),
                encoderFactory: { SyntheticEncoder(configuration: $0) }
            )
        )
    }

    public func stop() {
        feeding.cancel()
        source.stop()
    }
}

/// Subscribe to `who`'s video on `room` and keep reading it, so its pump has a
/// consumer.
public func drainFrames(of who: ParticipantIdentity, on room: RoomSession) async -> Task<Void, Never> {
    _ = await room.updateLayout([who: RenderBox(width: 640, height: 360, scale: 1)], linkBitrate: 5_000_000)
    return Task {
        while !Task.isCancelled {
            if let frames = await room.frames(from: who) {
                for await _ in frames {}
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// Poll until `condition` holds, or `timeout` passes.
public func directEventually(
    timeout: Duration = .seconds(15),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}
