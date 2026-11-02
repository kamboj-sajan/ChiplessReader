import Foundation

/// The contract between "abstract reader commands" and "bytes on the wire".
///
/// A real implementation for your Altra Waves module (`AltraWavesCodec`, not yet
/// written — see `Documentation/PROTOCOL.md`) belongs here once the wire format is
/// verified. Nothing in `ReaderSDK` or the app should ever encode/decode bytes
/// directly; it must go through a `PacketCodec`.
public protocol PacketCodec: Sendable {
    /// Human-readable name shown in diagnostics/logs.
    var name: String { get }

    func encode(_ command: ReaderCommand) throws -> [UInt8]

    /// Try to decode one complete frame from the front of `buffer`.
    /// - Returns: `nil` if `buffer` doesn't yet contain a complete frame (caller
    ///   should wait for more bytes).
    /// - Throws: `ProtocolError.malformedPacket`/`.checksumMismatch` if the leading
    ///   bytes are clearly not a valid frame — the assembler will drop one byte and
    ///   retry to resynchronize, rather than getting stuck forever.
    func decodeFrame(from buffer: [UInt8]) throws -> (frame: ReaderFrame, consumed: Int)?
}

/// Accumulates streamed bytes from a `Transport` and hands complete frames to a
/// `PacketCodec`. Handles: partial packets, multiple packets arriving in one
/// read, and resynchronization after a malformed packet.
public actor PacketAssembler {
    private var buffer: [UInt8] = []
    private let codec: PacketCodec
    private let maxBufferSize: Int

    public init(codec: PacketCodec, maxBufferSize: Int = 64 * 1024) {
        self.codec = codec
        self.maxBufferSize = maxBufferSize
    }

    /// Feed newly-received bytes. Returns every complete frame that could be
    /// extracted (zero, one, or many — e.g. if the transport handed back several
    /// frames' worth of bytes in a single read).
    @discardableResult
    public func feed(_ bytes: [UInt8]) throws -> [ReaderFrame] {
        buffer.append(contentsOf: bytes)
        if buffer.count > maxBufferSize {
            // Runaway buffer (e.g. persistent malformed stream): drop it rather than
            // growing unbounded, and surface that as a malformed-packet error.
            buffer.removeAll()
            throw ProtocolError.malformedPacket(reason: "buffer exceeded \(maxBufferSize) bytes without a valid frame; discarded")
        }

        var frames: [ReaderFrame] = []
        while true {
            do {
                guard let (frame, consumed) = try codec.decodeFrame(from: buffer), consumed > 0 else {
                    break // need more bytes
                }
                buffer.removeFirst(consumed)
                frames.append(frame)
            } catch {
                // Resynchronize: drop one byte and keep scanning, rather than wedging
                // the assembler on a single bad byte forever.
                if !buffer.isEmpty {
                    buffer.removeFirst()
                }
                throw error
            }
        }
        return frames
    }

    public func reset() {
        buffer.removeAll()
    }

    public var pendingByteCount: Int { buffer.count }
}
