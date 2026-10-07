// Turning moqom-direct-ffi's callbacks into awaits.
//
// Every asynchronous call takes a C function pointer and an opaque context, and
// calls back exactly once on one of the library's threads, possibly before the
// call has returned, and possibly after the handle it was made on was freed.
// So each await retains a small box holding its continuation, passes the box
// as the context, and the trampoline takes the retain back: the box lives
// exactly as long as the operation, whoever outlives whom.
//
// Handles cross threads in `RawHandle` because a C pointer is not `Sendable`,
// and these are: the library says every function may be called from any thread.

#if canImport(MoqomDirectFFI)
    import Foundation
    import MoqomDirectFFI
    import MoqomKit

    /// A library handle, moved between threads.
    struct RawHandle: @unchecked Sendable {
        let pointer: OpaquePointer
    }

    /// A status the library returned, with its message.
    struct RustStatus: Error, Sendable, CustomStringConvertible {
        let code: Int32
        let message: String

        init(_ code: Int32, message: String? = nil) {
            self.code = code
            self.message = message ?? String(cString: moqom_direct_status_message(code))
        }

        var description: String { "\(message) (\(code))" }
    }

    // MARK: - Boxes

    final class HandleCallback: @unchecked Sendable {
        let body: @Sendable (Int32, RawHandle?, String?) -> Void
        init(_ body: @escaping @Sendable (Int32, RawHandle?, String?) -> Void) { self.body = body }
    }

    final class PairCallback: @unchecked Sendable {
        let body: @Sendable (Int32, RawHandle?, RawHandle?) -> Void
        init(_ body: @escaping @Sendable (Int32, RawHandle?, RawHandle?) -> Void) { self.body = body }
    }

    final class BytesCallback: @unchecked Sendable {
        let body: @Sendable (Int32, Data?, UInt64) -> Void
        init(_ body: @escaping @Sendable (Int32, Data?, UInt64) -> Void) { self.body = body }
    }

    final class StatusCallback: @unchecked Sendable {
        let body: @Sendable (Int32, UInt64) -> Void
        init(_ body: @escaping @Sendable (Int32, UInt64) -> Void) { self.body = body }
    }

    final class ClosedCallback: @unchecked Sendable {
        let body: @Sendable (Int32, UInt64, String) -> Void
        init(_ body: @escaping @Sendable (Int32, UInt64, String) -> Void) { self.body = body }
    }

    /// The context for one operation: retained here, released by the
    /// trampoline.
    func retained(_ box: AnyObject) -> UnsafeMutableRawPointer {
        Unmanaged.passRetained(box).toOpaque()
    }

    func take<Box: AnyObject>(_ context: UnsafeMutableRawPointer?, as _: Box.Type) -> Box {
        Unmanaged<Box>.fromOpaque(context!).takeRetainedValue()
    }

    func handle(_ pointer: OpaquePointer?) -> RawHandle? {
        pointer.map(RawHandle.init(pointer:))
    }

    // MARK: - Awaiting

    /// The result of an operation that produces one handle.
    func awaitHandle(
        _ start: (UnsafeMutableRawPointer) -> Void
    ) async -> Result<RawHandle, RustStatus> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<RawHandle, RustStatus>, Never>) in
            let box = HandleCallback { status, handle, message in
                if status == MOQOM_DIRECT_OK, let handle {
                    continuation.resume(returning: .success(handle))
                } else {
                    let status = status == MOQOM_DIRECT_OK ? MOQOM_DIRECT_NULL : status
                    continuation.resume(returning: .failure(RustStatus(status, message: message)))
                }
            }
            start(retained(box))
        }
    }

    /// The result of an operation that produces a send and a receive half, or
    /// either alone.
    func awaitPair(
        _ start: (UnsafeMutableRawPointer) -> Void
    ) async -> (status: Int32, first: RawHandle?, second: RawHandle?) {
        await withCheckedContinuation {
            (continuation: CheckedContinuation<(status: Int32, first: RawHandle?, second: RawHandle?), Never>) in
            let box = PairCallback { status, first, second in
                continuation.resume(returning: (status, first, second))
            }
            start(retained(box))
        }
    }

    func awaitBytes(
        _ start: (UnsafeMutableRawPointer) -> Void
    ) async -> (status: Int32, data: Data?, code: UInt64) {
        await withCheckedContinuation { (continuation: CheckedContinuation<(status: Int32, data: Data?, code: UInt64), Never>) in
            let box = BytesCallback { status, data, code in
                continuation.resume(returning: (status, data, code))
            }
            start(retained(box))
        }
    }

    func awaitStatus(
        _ start: (UnsafeMutableRawPointer) -> Void
    ) async -> (status: Int32, code: UInt64) {
        await withCheckedContinuation { (continuation: CheckedContinuation<(status: Int32, code: UInt64), Never>) in
            let box = StatusCallback { status, code in
                continuation.resume(returning: (status, code))
            }
            start(retained(box))
        }
    }

    // MARK: - Trampolines

    // Closures that capture nothing, so they convert to the C function
    // pointers the library takes.

    let endpointTrampoline: moqom_direct_endpoint_callback = { context, status, endpoint, message in
        take(context, as: HandleCallback.self).body(status, handle(endpoint), message.map { String(cString: $0) })
    }

    let connectionTrampoline: moqom_direct_connection_callback = { context, status, connection, message in
        take(context, as: HandleCallback.self).body(status, handle(connection), message.map { String(cString: $0) })
    }

    let biTrampoline: moqom_direct_bi_callback = { context, status, send, recv in
        take(context, as: PairCallback.self).body(status, handle(send), handle(recv))
    }

    let uniSendTrampoline: moqom_direct_uni_send_callback = { context, status, send in
        take(context, as: PairCallback.self).body(status, handle(send), nil)
    }

    let uniRecvTrampoline: moqom_direct_uni_recv_callback = { context, status, recv in
        take(context, as: PairCallback.self).body(status, nil, handle(recv))
    }

    let bytesTrampoline: moqom_direct_bytes_callback = { context, status, data, length, code in
        // Valid only for the duration of this call, so copied.
        let bytes = data.map { Data(bytes: $0, count: length) }
        take(context, as: BytesCallback.self).body(status, bytes, code)
    }

    let statusTrampoline: moqom_direct_status_callback = { context, status, code in
        take(context, as: StatusCallback.self).body(status, code)
    }

    let closedTrampoline: moqom_direct_closed_callback = { context, status, code, reason in
        take(context, as: ClosedCallback.self).body(status, code, reason.map { String(cString: $0) } ?? "")
    }

    // MARK: - Addresses

    extension MoqomDirectAddress {
        init(_ candidate: DirectCandidate) {
            self.init()
            family = candidate.isIPv6 ? 6 : 4
            port = candidate.port
            withUnsafeMutableBytes(of: &address) { raw in
                for (index, byte) in candidate.address.enumerated() { raw[index] = byte }
            }
        }

        var candidate: DirectCandidate? {
            let count = family == 6 ? 16 : family == 4 ? 4 : 0
            guard count > 0 else { return nil }
            let bytes = withUnsafeBytes(of: address) { Array($0.prefix(count)) }
            return DirectCandidate(address: bytes, port: port)
        }
    }

    extension Duration {
        /// Whole milliseconds, clamped to what the library takes.
        var clampedMilliseconds: UInt32 {
            let (seconds, attoseconds) = components
            let total = seconds * 1000 + attoseconds / 1_000_000_000_000_000
            return UInt32(clamping: max(0, total))
        }
    }

    extension Data {
        var base64URL: String {
            base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
    }
#endif
