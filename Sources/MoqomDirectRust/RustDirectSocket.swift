// A direct socket from moqom-direct-ffi: one UDP socket that does STUN, sends
// NAT probes, and carries QUIC, so probing goes on for the whole establishment
// on both sides, as in the Rust SDK, and nothing has to be released before a
// dial.

#if canImport(MoqomDirectFFI)
    import Foundation
    import MoqomDirectFFI
    import MoqomKit

    /// The library behind ``DirectBackend/rust``.
    public enum RustDirectBackend {
        /// The interface version this module was compiled against.
        public static let expectedABIVersion = UInt32(MOQOM_DIRECT_ABI_VERSION)

        /// The interface version of the library linked in.
        public static var libraryABIVersion: UInt32 { moqom_direct_abi_version() }

        /// Whether the linked library speaks the interface this module does.
        /// When it does not, every bind fails with
        /// ``DirectEndpointError/bind(_:)`` and the caller stays on the relay.
        public static var isCompatible: Bool { libraryABIVersion == expectedABIVersion }

        /// The provider, for ``DirectBackend/custom(_:)``.
        public static var provider: any DirectSocketProvider { RustDirectSocketProvider() }
    }

    public extension DirectBackend {
        /// Direct paths on moqom-direct-ffi. iOS and macOS only.
        static var rust: DirectBackend { .custom(RustDirectBackend.provider) }
    }

    struct RustDirectSocketProvider: DirectSocketProvider {
        func bind(_ options: DirectSocketOptions) async throws(DirectEndpointError) -> any DirectSocket {
            guard RustDirectBackend.isCompatible else {
                throw .bind(
                    "moqom-direct-ffi speaks ABI \(RustDirectBackend.libraryABIVersion), "
                        + "this module \(RustDirectBackend.expectedABIVersion)"
                )
            }
            let result = await awaitHandle { context in
                options.alpn.withCString { alpn in
                    withOptionalCString(options.stun?.host) { stunHost in
                        var config = MoqomDirectEndpointConfig()
                        config.port = options.port
                        config.alpn = alpn
                        config.idle_timeout_ms = options.idleTimeout.clampedMilliseconds
                        config.datagrams = 1
                        config.stun_host = stunHost
                        config.stun_port = options.stun?.port ?? 0
                        config.stun_timeout_ms = options.stunTimeout.clampedMilliseconds
                        moqom_direct_endpoint_bind(&config, context, endpointTrampoline)
                    }
                }
            }
            switch result {
            case let .success(endpoint):
                do throws(RustStatus) {
                    return try RustDirectSocket(endpoint)
                } catch {
                    throw .identity(error.description)
                }
            case let .failure(status) where status.code == MOQOM_DIRECT_TLS:
                throw .identity(status.description)
            case let .failure(status):
                throw .bind(status.description)
            }
        }
    }

    /// One moqom-direct-ffi endpoint.
    final class RustDirectSocket: DirectSocket, @unchecked Sendable {
        let port: UInt16
        let certificateDER: Data
        let reflexive: DirectCandidate?
        let probesWhileDialling = true

        private let endpoint: RawHandle

        init(_ endpoint: RawHandle) throws(RustStatus) {
            self.endpoint = endpoint
            port = moqom_direct_endpoint_port(endpoint.pointer)
            var der: UnsafePointer<UInt8>?
            var length = 0
            let status = moqom_direct_endpoint_certificate(endpoint.pointer, &der, &length)
            guard status == MOQOM_DIRECT_OK, let der, length > 0 else {
                moqom_direct_endpoint_free(endpoint.pointer)
                throw RustStatus(status == MOQOM_DIRECT_OK ? MOQOM_DIRECT_NULL : status)
            }
            certificateDER = Data(bytes: der, count: length)
            var address = MoqomDirectAddress()
            reflexive = moqom_direct_endpoint_reflexive(endpoint.pointer, &address) == MOQOM_DIRECT_OK
                ? address.candidate
                : nil
        }

        deinit {
            moqom_direct_endpoint_free(endpoint.pointer)
        }

        func close() {
            moqom_direct_endpoint_close(endpoint.pointer)
        }

        func startPunching(_ candidates: [DirectCandidate], interval: Duration) {
            let addresses = candidates.map(MoqomDirectAddress.init)
            _ = addresses.withUnsafeBufferPointer { buffer in
                moqom_direct_endpoint_punch_start(
                    endpoint.pointer,
                    buffer.baseAddress,
                    buffer.count,
                    max(1, interval.clampedMilliseconds)
                )
            }
        }

        func stopPunching() {
            moqom_direct_endpoint_punch_stop(endpoint.pointer)
        }

        func dial(
            _ candidates: [DirectCandidate],
            pinning fingerprint: Data,
            timeout: Duration
        ) async throws(MoqomError) -> any QUICCarrier {
            guard fingerprint.count == 32, !candidates.isEmpty else { throw MoqomError.transport(.unreachable) }
            let addresses = candidates.map(MoqomDirectAddress.init)
            let pin = [UInt8](fingerprint)
            let endpoint = endpoint
            let result = await cancellable {
                await awaitHandle { context in
                    addresses.withUnsafeBufferPointer { buffer in
                        moqom_direct_endpoint_dial(
                            endpoint.pointer,
                            buffer.baseAddress,
                            buffer.count,
                            pin,
                            timeout.clampedMilliseconds,
                            context,
                            connectionTrampoline
                        )
                    }
                }
            }
            return try Self.carrier(result)
        }

        func accept(pinning fingerprint: Data, timeout: Duration) async throws(MoqomError) -> any QUICCarrier {
            guard fingerprint.count == 32 else { throw MoqomError.transport(.unreachable) }
            let pin = [UInt8](fingerprint)
            let endpoint = endpoint
            let result = await cancellable {
                await awaitHandle { context in
                    moqom_direct_endpoint_accept(
                        endpoint.pointer,
                        pin,
                        timeout.clampedMilliseconds,
                        context,
                        connectionTrampoline
                    )
                }
            }
            return try Self.carrier(result)
        }

        /// Run a dial or an accept, ending it early if the task is cancelled.
        ///
        /// The library cannot cancel one operation, only everything on the
        /// endpoint, so cancelling closes it. An endpoint establishes once, and
        /// a cancelled establishment is a finished one.
        private func cancellable(
            _ body: () async -> Result<RawHandle, RustStatus>
        ) async -> Result<RawHandle, RustStatus> {
            await withTaskCancellationHandler {
                await body()
            } onCancel: {
                self.close()
            }
        }

        private static func carrier(_ result: Result<RawHandle, RustStatus>) throws(MoqomError) -> RustQUICCarrier {
            switch result {
            case let .success(connection):
                return RustQUICCarrier(connection)
            case let .failure(status) where status.code == MOQOM_DIRECT_TLS:
                throw MoqomError.transport(.untrustedPeer)
            case .failure:
                throw MoqomError.transport(.unreachable)
            }
        }
    }

    private func withOptionalCString<T>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
        guard let string else { return body(nil) }
        return string.withCString { body($0) }
    }
#endif
