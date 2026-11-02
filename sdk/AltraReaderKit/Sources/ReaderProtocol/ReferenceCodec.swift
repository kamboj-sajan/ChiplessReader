import Foundation

/// A simple, fully-specified framing used for **mock mode and protocol-layer
/// tests only**.
///
/// Frame layout: `[0xA5][LEN:u16 LE][CMD:u8][STATUS:u8][PAYLOAD...][CRC16:u16 LE]`
/// `LEN` counts everything from `CMD` through `CRC16` inclusive.
///
/// This is **not** the Altra Waves reader's real wire protocol — that has not been
/// verified (see `Documentation/PROTOCOL.md`). It exists so the buffering,
/// resynchronization, and malformed-packet-handling logic in `PacketAssembler` has
/// something concrete to run against today, and so `MockTransport`-backed sessions
/// can round-trip realistic-looking bytes end to end. Do not point this codec at
/// real hardware — replace it with a verified `AltraWavesCodec` once the real
/// framing is captured (steps in `Documentation/PROTOCOL.md`).
public struct ReferenceCodec: PacketCodec {
    public let name = "ReferenceCodec (mock/testing only — not hardware-verified)"

    public init() {}

    private enum Op: UInt8 {
        case getReaderInfo = 0x01
        case getParam = 0x02
        case setParam = 0x03
        case startInventory = 0x10
        case stopInventory = 0x11
        case singleInventory = 0x12
        case readMemory = 0x20
        case writeMemory = 0x21
        case lockTag = 0x22
        case killTag = 0x23
        case tagReport = 0x30 // async notification, reader -> host
    }

    public func encode(_ command: ReaderCommand) throws -> [UInt8] {
        switch command {
        case .getReaderInfo:
            return frame(op: .getReaderInfo, payload: [])
        case .getParam(let name):
            return frame(op: .getParam, payload: Array(name.utf8))
        case .setParam(let name, let value):
            var payload = Array(name.utf8)
            payload.append(0x00) // NUL-separated name/value for this reference format
            payload.append(contentsOf: Array(describe(value).utf8))
            return frame(op: .setParam, payload: payload)
        case .startInventory(let antennas):
            return frame(op: .startInventory, payload: antennas.map { UInt8(clamping: $0) })
        case .stopInventory:
            return frame(op: .stopInventory, payload: [])
        case .singleInventory(let antennas):
            return frame(op: .singleInventory, payload: antennas.map { UInt8(clamping: $0) })
        case .readMemory(let bank, let start, let count, _):
            return frame(op: .readMemory, payload: [bankCode(bank), UInt8(clamping: start), UInt8(clamping: count)])
        case .writeMemory(let bank, let start, let dataHex, _):
            var payload: [UInt8] = [bankCode(bank), UInt8(clamping: start)]
            payload.append(contentsOf: hexToBytes(dataHex))
            return frame(op: .writeMemory, payload: payload)
        case .lockTag, .killTag:
            throw ProtocolError.unsupportedCommand("lock/kill are intentionally not encodable by the reference codec — destructive ops require a verified real codec")
        case .raw:
            throw ProtocolError.unsupportedCommand("raw")
        }
    }

    public func decodeFrame(from buffer: [UInt8]) throws -> (frame: ReaderFrame, consumed: Int)? {
        guard let start = buffer.firstIndex(of: 0xA5) else { return nil }
        if start > 0 {
            // Junk before the sync byte — treat as malformed so the assembler resyncs.
            throw ProtocolError.malformedPacket(reason: "unexpected bytes before sync marker")
        }
        guard buffer.count >= 4 else { return nil } // need sync + len(2) + at least cmd
        let len = Int(buffer[1]) | (Int(buffer[2]) << 8)
        let total = 3 + len // sync(1) + len(2) + len bytes (cmd+status+payload+crc)
        guard buffer.count >= total else { return nil }

        let body = Array(buffer[3..<(3 + len)])
        guard body.count >= 4 else { // cmd(1) + status(1) + crc(2) minimum
            throw ProtocolError.malformedPacket(reason: "frame shorter than minimum size")
        }
        let crcBytes = body.suffix(2)
        let payloadAndHeader = body.dropLast(2)
        let expectedCRC = UInt16(crcBytes.first!) | (UInt16(crcBytes.last!) << 8)
        let actualCRC = CRC16.ccitt(Array(payloadAndHeader))
        guard expectedCRC == actualCRC else {
            throw ProtocolError.checksumMismatch
        }

        let status = payloadAndHeader[payloadAndHeader.startIndex + 1]
        let payload = Array(payloadAndHeader.dropFirst(2))
        let frame = ReaderFrame(isSuccess: status == 0, statusCode: Int(status), payload: payload)
        return (frame, total)
    }

    // MARK: - Helpers

    private func frame(op: Op, payload: [UInt8]) -> [UInt8] {
        var body: [UInt8] = [op.rawValue, 0x00] // cmd, status(unused on outbound)
        body.append(contentsOf: payload)
        let crc = CRC16.ccitt(body)
        body.append(UInt8(crc & 0xFF))
        body.append(UInt8((crc >> 8) & 0xFF))
        let len = body.count
        var out: [UInt8] = [0xA5, UInt8(len & 0xFF), UInt8((len >> 8) & 0xFF)]
        out.append(contentsOf: body)
        return out
    }

    private func bankCode(_ bank: MemoryBank) -> UInt8 {
        switch bank {
        case .reserved: return 0
        case .epc: return 1
        case .tid: return 2
        case .user: return 3
        }
    }

    private func describe(_ value: ParamValue) -> String {
        switch value {
        case .int(let i): return String(i)
        case .string(let s): return s
        case .bool(let b): return b ? "1" : "0"
        case .intArray(let arr): return arr.map(String.init).joined(separator: ",")
        }
    }

    private func hexToBytes(_ hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var chars = Array(hex)
        if chars.count % 2 != 0 { chars.insert("0", at: 0) }
        var i = 0
        while i < chars.count {
            if let b = UInt8(String(chars[i...i+1]), radix: 16) { bytes.append(b) }
            i += 2
        }
        return bytes
    }
}

/// Placeholder for the verified Altra Waves wire protocol. Intentionally throws on
/// every call: encoding or decoding without a verified spec risks sending an
/// unknown/unsafe command to real hardware, which the project's safety
/// requirements rule out. Replace the bodies once the real framing is captured —
/// see `Documentation/PROTOCOL.md` for exactly how.
public struct AltraWavesCodec: PacketCodec {
    public let name = "AltraWavesCodec (BLOCKED — wire protocol not yet verified)"

    public init() {}

    public func encode(_ command: ReaderCommand) throws -> [UInt8] {
        throw ProtocolError.unverifiedProtocol(command: String(describing: command))
    }

    public func decodeFrame(from buffer: [UInt8]) throws -> (frame: ReaderFrame, consumed: Int)? {
        throw ProtocolError.unverifiedProtocol(command: "decode")
    }
}
