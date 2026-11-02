import Foundation

/// Errors the mock can be configured to inject, so higher layers can be exercised
/// without physical hardware.
public enum MockFault: Sendable, Equatable {
    case timeout
    case malformedBytes([UInt8])
    case unexpectedDisconnect
    case writeRejected(String)
}

/// A fully in-memory `Transport` that behaves enough like a real reader to drive
/// development, demos, and tests without hardware.
///
/// This never touches a real device. Nothing here should be mistaken for verified
/// wire-protocol bytes — see `ReaderProtocol`'s `ReferenceCodec` for that distinction.
public final class MockTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var _state: TransportState = .disconnected
    private var continuation: AsyncStream<TransportEvent>.Continuation?
    private var simulationTask: Task<Void, Never>?

    public private(set) var state: TransportState {
        get { lock.withLock { _state } }
        set {
            lock.withLock { _state = newValue }
            continuation?.yield(.stateChanged(newValue))
        }
    }

    public let events: AsyncStream<TransportEvent>

    /// Bytes the mock will emit as if they came from a reader, once connected.
    /// The simulation engine in `ReaderSDK` (`MockInventorySource`) drives this;
    /// this class only carries the bytes.
    public var injectedFaults: [MockFault] = []

    public init() {
        var cont: AsyncStream<TransportEvent>.Continuation!
        self.events = AsyncStream { c in cont = c }
        self.continuation = cont
    }

    public func connect(timeout: TimeInterval) async throws {
        guard state == .disconnected || isError else { throw TransportError.alreadyConnected }
        state = .connecting
        // Simulate realistic (short) connection latency.
        try? await Task.sleep(nanoseconds: 150_000_000)
        if injectedFaults.contains(.timeout) {
            state = .error(TransportError.readTimeout.description)
            throw TransportError.connectionFailed("simulated timeout")
        }
        state = .connected
    }

    public func disconnect() async {
        simulationTask?.cancel()
        simulationTask = nil
        state = .disconnected
    }

    public func write(_ bytes: [UInt8]) async throws {
        guard state == .connected else { throw TransportError.notConnected }
        if let fault = injectedFaults.first(where: { if case .writeRejected = $0 { return true } else { return false } }),
           case .writeRejected(let reason) = fault {
            throw TransportError.writeFailed(reason)
        }
        // The mock doesn't need to *do* anything with outbound bytes for simulation
        // purposes — `MockInventorySource` generates inbound tag events independently.
    }

    /// Push raw bytes into the transport as if received from the wire. Used by
    /// tests and by the simulation engine.
    public func simulateInboundBytes(_ bytes: [UInt8]) {
        guard state == .connected else { return }
        continuation?.yield(.bytesReceived(bytes))
    }

    /// Simulate the reader being unplugged mid-session.
    public func simulateDeviceRemoved() {
        state = .error(TransportError.deviceRemoved.description)
        continuation?.yield(.deviceRemoved)
    }

    private var isError: Bool {
        if case .error = state { return true }
        return false
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
