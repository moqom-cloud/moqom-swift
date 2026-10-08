// The MLS delivery service, as a client sees it.
//
// MLS needs somebody to put commits in one order and to hold key packages for
// devices that are not online to hand them over. That is all the service does,
// and everything it is given is either public (key packages, which are signed
// public keys) or ciphertext (commits and Welcomes, whose secrets are HPKE
// sealed to members). It is never given anything that derives a key.
//
// A protocol rather than a type so that a deployment running its own backend
// can put one in front of its own store, and so the room's key management can
// be tested without a network. ``HTTPMLSDelivery`` is MOQOM's: the control
// plane's join listener, authenticated by the same token the relay accepts.
//
// Every call takes the token rather than the service holding one, because the
// token is renewed underneath a call that lasts longer than fifteen minutes and
// a service that cached it would start failing at the first renewal.

import Foundation
import MoqomCore
@_exported import MoqomMLS

/// What the delivery service knows about one room's group.
public struct MLSDeliverySnapshot: Sendable, Hashable {
    /// The group's identifier and the epoch the next commit must be made in,
    /// or `nil` when the room has no group yet.
    public var group: Group?

    /// Commits and Welcomes after the cursor that was asked about, in order.
    /// Welcomes are only ever those addressed to the caller.
    public var messages: [Message]

    /// Members the service has heard from recently, the caller included if it
    /// is one, as `username/device`.
    public var members: [String]

    /// Devices present in the room, not in the group, and holding a key
    /// package — the ones a committer should add.
    public var pending: [String]

    /// The sequence number to ask from next time.
    public var cursor: UInt64

    /// Viewers present that are not in the group, and how many of them do not
    /// yet hold the current epoch's key. Reported to members only.
    public var audience: Int
    public var audienceWaiting: Int

    public struct Group: Sendable, Hashable {
        public var id: Data
        public var epoch: UInt64
        /// The identifier of the suite the group was founded in, as the
        /// founder declared it. A raw value, since the service may know of
        /// suites this build does not. A device publishes key packages in this
        /// suite to be added.
        public var cipherSuite: UInt16

        public init(
            id: Data,
            epoch: UInt64,
            cipherSuite: UInt16 = MLSCipherSuite.mls128DHKEMX25519.identifier
        ) {
            self.id = id
            self.epoch = epoch
            self.cipherSuite = cipherSuite
        }
    }

    public struct Message: Sendable, Hashable {
        public enum Kind: String, Sendable, Hashable, Codable {
            case commit
            case welcome
        }

        public var sequence: UInt64
        public var kind: Kind
        public var data: Data

        public init(sequence: UInt64, kind: Kind, data: Data) {
            self.sequence = sequence
            self.kind = kind
            self.data = data
        }
    }

    public init(
        group: Group?,
        messages: [Message],
        members: [String],
        pending: [String],
        cursor: UInt64,
        audience: Int = 0,
        audienceWaiting: Int = 0
    ) {
        self.group = group
        self.messages = messages
        self.members = members
        self.pending = pending
        self.cursor = cursor
        self.audience = audience
        self.audienceWaiting = audienceWaiting
    }
}

/// A commit as it is handed to the delivery service.
///
/// `joiners` and `removed` are bookkeeping for the service — which devices are
/// now members — and carry no authority: every member verifies the commit
/// itself, and a committer that lied here would only confuse the service's
/// idea of who still needs adding.
public struct MLSDeliveryCommit: Sendable, Hashable {
    public var epoch: UInt64
    public var commit: Data
    public var welcome: Data?
    public var joiners: [String]
    public var removed: [String]

    public init(epoch: UInt64, commit: Data, welcome: Data?, joiners: [String], removed: [String]) {
        self.epoch = epoch
        self.commit = commit
        self.welcome = welcome
        self.joiners = joiners
        self.removed = removed
    }
}

/// Whether the service ordered a commit.
public enum MLSCommitReceipt: Sendable, Hashable {
    case accepted(sequence: UInt64)
    /// Another commit for the same epoch was ordered first. Discard this one,
    /// catch up, and decide again.
    case stale
}

/// Somewhere that orders a room's MLS handshake messages.
public protocol MLSDeliveryService: Sendable {
    /// Replace this device's key packages for the token's room.
    ///
    /// Each of `packages` is handed out at most once. `lastResort` is handed
    /// out when they have run out, and is never consumed, so a device that has
    /// been added more often than it uploaded can still be added.
    func publishKeyPackages(_ packages: [Data], lastResort: Data, token: Data) async throws

    /// Take one key package belonging to `identity`, to add it.
    func claimKeyPackage(for identity: String, token: Data) async throws -> Data

    /// Everything after `cursor`, waiting up to `wait` for there to be something.
    func sync(after cursor: UInt64, wait: Duration, token: Data) async throws -> MLSDeliverySnapshot

    /// Found the room's group in `cipherSuite`. `false` when somebody else
    /// founded it first.
    ///
    /// The service records the suite and reports it in every snapshot's
    /// ``MLSDeliverySnapshot/Group/cipherSuite``, which is how a device that
    /// is not yet a member knows which suite to publish key packages in. It
    /// should refuse to hand out a key package in any other suite.
    func createGroup(_ id: Data, cipherSuite: MLSCipherSuite, token: Data) async throws -> Bool

    func submitCommit(_ commit: MLSDeliveryCommit, token: Data) async throws -> MLSCommitReceipt

    /// Ask to be added again: this device has lost or cannot follow its state.
    func rejoin(token: Data) async throws

    /// Leave, so the next commit removes this device without waiting for it to
    /// go quiet.
    func leave(token: Data) async throws

    // MARK: Audience

    /// Post this device's audience key and wait up to `wait` for an epoch key
    /// sealed to it other than `have`. Also its heartbeat as a viewer.
    func joinAudience(publicKey: Data, have: MLSEpochRef?, wait: Duration, token: Data) async throws -> MLSAudienceEnvelope?

    /// Stop being a viewer.
    func leaveAudience(token: Data) async throws

    /// The current epoch, and the viewers that do not hold it. Members only.
    func audienceWork(token: Data) async throws -> MLSAudienceWork

    /// Store sealed epoch keys by device. `false` when the group has moved past
    /// `epoch`.
    func sealAudience(_ envelopes: [String: Data], for epoch: MLSEpochRef, token: Data) async throws -> Bool
}

extension MLSDeliveryService {
    public func joinAudience(publicKey: Data, have: MLSEpochRef?, wait: Duration, token: Data) async throws -> MLSAudienceEnvelope? {
        throw MLSDeliveryError.refused(status: 501, reason: "this delivery service has no audience")
    }

    public func leaveAudience(token: Data) async throws {}

    public func audienceWork(token: Data) async throws -> MLSAudienceWork {
        throw MLSDeliveryError.refused(status: 501, reason: "this delivery service has no audience")
    }

    public func sealAudience(_ envelopes: [String: Data], for epoch: MLSEpochRef, token: Data) async throws -> Bool {
        throw MLSDeliveryError.refused(status: 501, reason: "this delivery service has no audience")
    }
}

/// One epoch of one group.
public struct MLSEpochRef: Sendable, Hashable {
    public var groupID: Data
    public var epoch: UInt64

    public init(groupID: Data, epoch: UInt64) {
        self.groupID = groupID
        self.epoch = epoch
    }
}

/// An epoch's SFrame base key sealed to one viewer.
public struct MLSAudienceEnvelope: Sendable, Hashable {
    public var epoch: MLSEpochRef
    public var data: Data

    public init(epoch: MLSEpochRef, data: Data) {
        self.epoch = epoch
        self.data = data
    }
}

/// What a member seals next.
public struct MLSAudienceWork: Sendable, Hashable {
    public struct Seat: Sendable, Hashable {
        public var device: String
        public var publicKey: Data

        public init(device: String, publicKey: Data) {
            self.device = device
            self.publicKey = publicKey
        }
    }

    public var epoch: MLSEpochRef
    public var seats: [Seat]

    public init(epoch: MLSEpochRef, seats: [Seat]) {
        self.epoch = epoch
        self.seats = seats
    }
}

/// Why the delivery service could not be used.
public enum MLSDeliveryError: Error, Sendable, Hashable {
    case unreachable(String)
    case refused(status: Int, reason: String)
    case malformed(String)
}

/// The control plane's delivery service, on its join listener.
///
/// A class holding one URL session, rather than a value making one per call
/// as ``TokenService`` does: this is asked every few seconds for as long as a
/// call lasts, and a pinned session retains its delegate until invalidated.
public final class HTTPMLSDelivery: MLSDeliveryService {
    public let endpoint: RelayEndpoint
    public let certificateHashes: [String]
    private let session: URLSession

    public init(endpoint: RelayEndpoint, certificateHashes: [String] = []) {
        self.endpoint = endpoint
        self.certificateHashes = certificateHashes
        session = TokenService.session(pinning: certificateHashes).session
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    public func publishKeyPackages(_ packages: [Data], lastResort: Data, token: Data) async throws {
        _ = try await call(
            "PUT", "/mls/v1/keypackages",
            body: KeyPackagesBody(keyPackages: packages, lastResort: lastResort), token: token
        )
    }

    public func claimKeyPackage(for identity: String, token: Data) async throws -> Data {
        let data = try await call(
            "POST", "/mls/v1/keypackages/claim", body: ClaimBody(device: identity), token: token
        )
        return try decode(ClaimResponse.self, data).keyPackage
    }

    public func sync(after cursor: UInt64, wait: Duration, token: Data) async throws -> MLSDeliverySnapshot {
        let seconds = max(0, Int(wait.components.seconds))
        let data = try await call(
            "GET", "/mls/v1/sync",
            query: [URLQueryItem(name: "after", value: "\(cursor)"), URLQueryItem(name: "wait", value: "\(seconds)")],
            body: Optional<Empty>.none, token: token, timeout: TimeInterval(seconds) + 10
        )
        let body = try decode(SyncResponse.self, data)
        return MLSDeliverySnapshot(
            group: body.group.map {
                // A service that does not report a suite predates suites, and
                // every group it holds is in 0x0001.
                MLSDeliverySnapshot.Group(
                    id: $0.id, epoch: $0.epoch,
                    cipherSuite: $0.cipherSuite ?? MLSCipherSuite.mls128DHKEMX25519.identifier
                )
            },
            messages: (body.messages ?? []).map {
                MLSDeliverySnapshot.Message(sequence: $0.seq, kind: $0.kind, data: $0.data)
            },
            members: body.members ?? [],
            pending: body.pending ?? [],
            cursor: body.cursor,
            audience: body.audience ?? 0,
            audienceWaiting: body.audienceWaiting ?? 0
        )
    }

    public func createGroup(_ id: Data, cipherSuite: MLSCipherSuite, token: Data) async throws -> Bool {
        do {
            _ = try await call(
                "POST", "/mls/v1/group",
                body: GroupBody(groupId: id, cipherSuite: cipherSuite.identifier), token: token
            )
            return true
        } catch MLSDeliveryError.refused(status: 409, _) {
            return false
        }
    }

    public func submitCommit(_ commit: MLSDeliveryCommit, token: Data) async throws -> MLSCommitReceipt {
        do {
            let data = try await call(
                "POST", "/mls/v1/commits",
                body: CommitBody(
                    epoch: commit.epoch, commit: commit.commit, welcome: commit.welcome,
                    joiners: commit.joiners, removed: commit.removed
                ),
                token: token
            )
            return .accepted(sequence: try decode(CommitResponse.self, data).seq)
        } catch MLSDeliveryError.refused(status: 409, _) {
            return .stale
        }
    }

    public func rejoin(token: Data) async throws {
        _ = try await call("POST", "/mls/v1/rejoin", body: Optional<Empty>.none, token: token)
    }

    public func leave(token: Data) async throws {
        _ = try await call("DELETE", "/mls/v1/presence", body: Optional<Empty>.none, token: token)
    }

    public func joinAudience(publicKey: Data, have: MLSEpochRef?, wait: Duration, token: Data) async throws -> MLSAudienceEnvelope? {
        let seconds = max(0, Int(wait.components.seconds))
        let data = try await call(
            "POST", "/mls/v1/audience",
            body: AudienceBody(publicKey: publicKey, haveGroupId: have?.groupID, haveEpoch: have?.epoch, wait: seconds),
            token: token, timeout: TimeInterval(seconds) + 10
        )
        // 204: nothing newer than `have` was sealed in time.
        guard !data.isEmpty else { return nil }
        let body = try decode(EnvelopeResponse.self, data)
        return MLSAudienceEnvelope(epoch: MLSEpochRef(groupID: body.groupId, epoch: body.epoch), data: body.data)
    }

    public func leaveAudience(token: Data) async throws {
        _ = try await call("DELETE", "/mls/v1/audience", body: Optional<Empty>.none, token: token)
    }

    public func audienceWork(token: Data) async throws -> MLSAudienceWork {
        let data = try await call("GET", "/mls/v1/audience/work", body: Optional<Empty>.none, token: token)
        let body = try decode(WorkResponse.self, data)
        return MLSAudienceWork(
            epoch: MLSEpochRef(groupID: body.groupId, epoch: body.epoch),
            seats: body.seats.map { MLSAudienceWork.Seat(device: $0.device, publicKey: $0.publicKey) }
        )
    }

    public func sealAudience(_ envelopes: [String: Data], for epoch: MLSEpochRef, token: Data) async throws -> Bool {
        do {
            _ = try await call(
                "POST", "/mls/v1/audience/envelopes",
                body: SealBody(groupId: epoch.groupID, epoch: epoch.epoch, envelopes: envelopes), token: token
            )
            return true
        } catch MLSDeliveryError.refused(status: 409, _) {
            return false
        }
    }

    // MARK: - Wire

    private struct Empty: Encodable {}

    private struct AudienceBody: Encodable {
        var publicKey: Data
        var haveGroupId: Data?
        var haveEpoch: UInt64?
        var wait: Int
    }

    private struct EnvelopeResponse: Decodable {
        var groupId: Data
        var epoch: UInt64
        var data: Data
    }

    private struct WorkResponse: Decodable {
        struct Seat: Decodable {
            var device: String
            var publicKey: Data
        }

        var groupId: Data
        var epoch: UInt64
        var seats: [Seat]
    }

    private struct SealBody: Encodable {
        var groupId: Data
        var epoch: UInt64
        var envelopes: [String: Data]
    }

    private struct KeyPackagesBody: Encodable {
        var keyPackages: [Data]
        var lastResort: Data
    }

    private struct ClaimBody: Encodable { var device: String }
    private struct ClaimResponse: Decodable { var keyPackage: Data }
    private struct GroupBody: Encodable {
        var groupId: Data
        var cipherSuite: UInt16
    }

    private struct CommitBody: Encodable {
        var epoch: UInt64
        var commit: Data
        var welcome: Data?
        var joiners: [String]
        var removed: [String]
    }

    private struct CommitResponse: Decodable { var seq: UInt64 }

    private struct SyncResponse: Decodable {
        struct Group: Decodable {
            var id: Data
            var epoch: UInt64
            var cipherSuite: UInt16?
        }

        struct Message: Decodable {
            var seq: UInt64
            var kind: MLSDeliverySnapshot.Message.Kind
            var data: Data
        }

        var group: Group?
        var messages: [Message]?
        var members: [String]?
        var pending: [String]?
        var cursor: UInt64
        var audience: Int?
        var audienceWaiting: Int?
    }

    private func decode<T: Decodable>(_: T.Type, _ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw MLSDeliveryError.malformed("\(error)")
        }
    }

    private func call(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: (some Encodable)?,
        token: Data,
        timeout: TimeInterval = 10
    ) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = endpoint.host
        components.port = Int(endpoint.port)
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw MLSDeliveryError.unreachable("not an address") }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(String(decoding: token, as: UTF8.self))", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        request.timeoutInterval = timeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MLSDeliveryError.unreachable("\(error.localizedDescription)")
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw MLSDeliveryError.malformed("not an HTTP response")
        }
        guard (200 ..< 300).contains(status) else {
            let reason = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw MLSDeliveryError.refused(status: status, reason: reason)
        }
        return data
    }
}

extension TokenService {
    /// The delivery service on the same listener this asks for tokens, pinned
    /// the same way.
    public var keyDelivery: HTTPMLSDelivery {
        HTTPMLSDelivery(endpoint: endpoint, certificateHashes: certificateHashes)
    }
}
