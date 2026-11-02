import Foundation

/// How a reader is reached. Kept intentionally small — new cases (Bluetooth, HID)
/// slot in without touching the protocol or SDK layers.
public enum TransportDescriptor: Sendable, Equatable {
    /// macOS serial device, e.g. "/dev/cu.usbserial-1410", at a given baud rate.
    case serial(path: String, baudRate: Int)
    /// Network reader, e.g. host "192.168.1.100" port 4001 (the reference app's default).
    case tcp(host: String, port: UInt16)
    /// In-memory simulated reader — no physical device required.
    case mock(profile: String = "default")
}

public enum TransportState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case disconnecting
    case error(String)
}

public enum TransportError: Error, Sendable, Equatable, CustomStringConvertible {
    case alreadyConnected
    case notConnected
    case connectionFailed(String)
    case writeFailed(String)
    case readTimeout
    case deviceRemoved
    case cancelled

    public var description: String {
        switch self {
        case .alreadyConnected: return "Transport is already connected."
        case .notConnected: return "Transport is not connected."
        case .connectionFailed(let reason): return "Connection failed: \(reason)"
        case .writeFailed(let reason): return "Write failed: \(reason)"
        case .readTimeout: return "Read timed out."
        case .deviceRemoved: return "The device was removed or disconnected unexpectedly."
        case .cancelled: return "The operation was cancelled."
        }
    }
}

/// Transport-level events, surfaced to the protocol/SDK layers for logging and
/// connection-recovery decisions.
public enum TransportEvent: Sendable {
    case stateChanged(TransportState)
    case bytesReceived([UInt8])
    case deviceRemoved
    case error(TransportError)
}

/// The seam between "how we talk to a reader" and "what we say to it".
///
/// Both `SerialTransport`/`TCPTransport` (real hardware) and `MockTransport`
/// (simulation) implement this so the protocol and SDK layers are transport-agnostic.
/// Conformers must be safe to use from a single actor context — call sites in this
/// project always own a transport from one `ReaderSession` actor.
public protocol Transport: AnyObject, Sendable {
    var state: TransportState { get }

    /// A stream of transport events (state changes, inbound bytes, errors).
    /// Consumers should treat this as the single source of truth; do not poll `state`
    /// in a loop.
    var events: AsyncStream<TransportEvent> { get }

    func connect(timeout: TimeInterval) async throws
    func disconnect() async

    /// Write raw bytes. Framing/checksums are the protocol layer's job, not the transport's.
    func write(_ bytes: [UInt8]) async throws
}

/// Common retry/timeout policy used by transports and the protocol layer.
public struct RetryPolicy: Sendable, Equatable {
    public var maxAttempts: Int
    public var timeout: TimeInterval
    public var backoff: TimeInterval

    public init(maxAttempts: Int = 3, timeout: TimeInterval = 2.0, backoff: TimeInterval = 0.25) {
        self.maxAttempts = maxAttempts
        self.timeout = timeout
        self.backoff = backoff
    }

    public static let `default` = RetryPolicy()
}
