#if canImport(Network)
import Foundation
import Network

/// A `Transport` over TCP/IP using `Network.framework`, for readers reached by
/// network port (the reference app's default is `192.168.1.100`, per its manual —
/// see `Documentation/PROTOCOL.md`). The exact port is not documented anywhere
/// supplied to this project; it must be confirmed against your module (commonly
/// 4001 or 6000 for this class of device — verify before shipping).
public final class TCPTransport: Transport, @unchecked Sendable {
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.altrareaderkit.tcp")
    private let lock = NSLock()
    private var _state: TransportState = .disconnected
    private var continuation: AsyncStream<TransportEvent>.Continuation?

    public private(set) var state: TransportState {
        get { lock.withLock { _state } }
        set {
            lock.withLock { _state = newValue }
            continuation?.yield(.stateChanged(newValue))
        }
    }

    public let events: AsyncStream<TransportEvent>

    public init(host: String, port: UInt16) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port) ?? 4001
        var cont: AsyncStream<TransportEvent>.Continuation!
        self.events = AsyncStream { c in cont = c }
        self.continuation = cont
    }

    public func connect(timeout: TimeInterval) async throws {
        guard connection == nil else { throw TransportError.alreadyConnected }
        state = .connecting

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let conn = NWConnection(host: host, port: port, using: .tcp)
            self.connection = conn
            let resumeGuard = ResumeOnce()

            conn.stateUpdateHandler = { [weak self] newState in
                guard let self else { return }
                switch newState {
                case .ready:
                    self.state = .connected
                    self.startReceiveLoop()
                    resumeGuard.run { cont.resume() }
                case .failed(let error):
                    self.state = .error(error.localizedDescription)
                    resumeGuard.run { cont.resume(throwing: TransportError.connectionFailed(error.localizedDescription)) }
                case .cancelled:
                    self.state = .disconnected
                case .waiting(let error):
                    // Keep waiting up to the caller's timeout; surface as an event for diagnostics.
                    self.continuation?.yield(.error(.connectionFailed(error.localizedDescription)))
                default:
                    break
                }
            }
            conn.start(queue: self.queue)

            self.queue.asyncAfter(deadline: .now() + timeout) {
                resumeGuard.run {
                    conn.cancel()
                    cont.resume(throwing: TransportError.connectionFailed("timed out after \(timeout)s"))
                }
            }
        }
    }

    public func disconnect() async {
        connection?.cancel()
        connection = nil
        state = .disconnected
    }

    public func write(_ bytes: [UInt8]) async throws {
        guard let connection else { throw TransportError.notConnected }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: TransportError.writeFailed(error.localizedDescription))
                } else {
                    cont.resume()
                }
            })
        }
    }

    private func startReceiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.continuation?.yield(.bytesReceived(Array(data)))
            }
            if let error {
                self.continuation?.yield(.error(.readTimeout))
                self.state = .error(error.localizedDescription)
                return
            }
            if isComplete {
                self.continuation?.yield(.deviceRemoved)
                self.state = .error(TransportError.deviceRemoved.description)
                return
            }
            self.startReceiveLoop()
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}

/// Guards a `CheckedContinuation` against being resumed twice. `connect(timeout:)`
/// has two independent closures racing to resume the same continuation — the
/// connection's state-update handler and the timeout fallback — both running on
/// `queue`. A bare captured `var resumed = false` mutated from both is exactly
/// the kind of shared mutable state Swift 6's strict concurrency checking flags
/// (correctly: two closures capturing and mutating the same non-isolated `var`
/// is a real, if narrow, race). A tiny lock-backed "first caller wins" type is
/// the standard fix — simpler than restructuring this into an actor for what's
/// fundamentally a one-shot flag.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var hasRun = false

    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !hasRun else { return }
        hasRun = true
        body()
    }
}
#endif
