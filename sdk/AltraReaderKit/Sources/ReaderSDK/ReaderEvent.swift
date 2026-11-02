import Foundation
import ReaderTransport
import ReaderProtocol

public enum ReaderEvent: Sendable {
    case connectionStateChanged(TransportState)
    case tagRead(TagRead)
    case diagnosticLog(String)
    case error(String)
}

/// Structured, typed SDK errors — never a bare `String` at the call site.
public enum ReaderSDKError: Error, Sendable, CustomStringConvertible, Equatable {
    case transport(TransportError)
    case protocolLayer(ProtocolError)
    case notConnected
    case invalidConfirmation(String)
    case unsupported(String)

    public var description: String {
        switch self {
        case .transport(let e): return e.description
        case .protocolLayer(let e): return e.description
        case .notConnected: return "Not connected to a reader."
        case .invalidConfirmation(let reason): return "Operation blocked: \(reason)"
        case .unsupported(let what): return "Not supported: \(what)"
        }
    }
}
