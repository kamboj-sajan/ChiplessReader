import Foundation

/// Command codes understood by the chipless reader firmware (STM32 or virtual reader).
/// Host commands are 0x01…0x3F, replies carry `command | 0x80` (0x81…0xBF), and unsolicited
/// reader → host frames (tag reports) use 0xC0…0xFF - so the three can never be confused.
/// Full byte layouts: `docs/PROTOCOL.md`.
public enum ChiplessCommand: UInt8, CaseIterable, Sendable {
    case getInfo = 0x01
    case ping = 0x02
    case getStatus = 0x03
    case resetConfig = 0x05
    case saveToFlash = 0x06
    case setMode = 0x08
    case getConfig = 0x0F
    case setSweep = 0x10
    case setTxPower = 0x12
    case setCarrier = 0x13
    case setRxConfig = 0x14
    case setAcquisition = 0x16
    case setDetection = 0x18
    case getDetection = 0x19
    case setProfile = 0x1A
    case getProfile = 0x1B
    case setCalibration = 0x1E
    case getCalibration = 0x1F
    case setLO = 0x20
    case measure = 0x21
    case attenuatorScan = 0x22
    case autoLevel = 0x23
    case databaseInfo = 0x24
    case databaseGet = 0x25
    case databasePut = 0x26
    case databaseDelete = 0x27
    case databaseClear = 0x28
    case readTag = 0x30
    case getSweepData = 0x31
    case captureBackground = 0x32
    case clearBackground = 0x33
    case simSet = 0x3A
    case simGet = 0x3B

    public static let responseFlag: UInt8 = 0x80
    /// Reply code used by the reader for any command byte outside 0x01…0x3F.
    public static let invalidCommandReply: UInt8 = 0xBF

    /// The reply code the reader will use for a given command byte.
    public static func replyCode(for command: UInt8) -> UInt8 {
        (1...0x3F).contains(command) ? command | responseFlag : invalidCommandReply
    }
    public static let tagReportEvent: UInt8 = 0xC0

    public var name: String {
        switch self {
        case .getInfo: return "GET_INFO"
        case .ping: return "PING"
        case .getStatus: return "GET_STATUS"
        case .resetConfig: return "RESET_CONFIG"
        case .saveToFlash: return "NV_SAVE"
        case .setMode: return "SET_MODE"
        case .getConfig: return "GET_CONFIG"
        case .setSweep: return "SET_SWEEP"
        case .setTxPower: return "SET_TX_POWER"
        case .setCarrier: return "SET_CARRIER"
        case .setRxConfig: return "SET_RX_CONFIG"
        case .setAcquisition: return "SET_ACQ"
        case .setDetection: return "SET_DETECT"
        case .getDetection: return "GET_DETECT"
        case .setProfile: return "SET_PROFILE"
        case .getProfile: return "GET_PROFILE"
        case .setCalibration: return "SET_CAL"
        case .getCalibration: return "GET_CAL"
        case .setLO: return "SET_LO"
        case .measure: return "MEASURE"
        case .attenuatorScan: return "ATTEN_SCAN"
        case .autoLevel: return "AUTO_LEVEL"
        case .databaseInfo: return "DB_INFO"
        case .databaseGet: return "DB_GET"
        case .databasePut: return "DB_PUT"
        case .databaseDelete: return "DB_DELETE"
        case .databaseClear: return "DB_CLEAR"
        case .readTag: return "READ_TAG"
        case .getSweepData: return "GET_SWEEP_DATA"
        case .captureBackground: return "CAPTURE_BG"
        case .clearBackground: return "CLEAR_BG"
        case .simSet: return "SIM_SET"
        case .simGet: return "SIM_GET"
        }
    }
}

/// Status byte in every reply.
public enum ChiplessStatus: UInt8, Sendable, CustomStringConvertible {
    case ok = 0x00
    case crcError = 0x01
    case unknownCommand = 0x02
    case badLength = 0x03
    case outOfRange = 0x04
    case busy = 0x05
    case pllUnlocked = 0x06
    case notSupported = 0x07
    case flashError = 0x08

    public var description: String {
        switch self {
        case .ok: return "OK"
        case .crcError: return "CRC_ERROR"
        case .unknownCommand: return "UNKNOWN_CMD"
        case .badLength: return "BAD_LENGTH"
        case .outOfRange: return "OUT_OF_RANGE"
        case .busy: return "BUSY (reader is in AUTO mode - switch to RESPONSE mode first)"
        case .pllUnlocked: return "PLL_UNLOCKED"
        case .notSupported: return "NOT_SUPPORTED"
        case .flashError: return "FLASH_ERROR"
        }
    }
}

/// One decoded frame.
public struct ChiplessFrame: Equatable, Sendable {
    public var command: UInt8
    public var status: UInt8
    public var payload: [UInt8]

    public init(command: UInt8, status: UInt8 = 0, payload: [UInt8] = []) {
        self.command = command
        self.status = status
        self.payload = payload
    }

    public var isResponse: Bool { command & 0xC0 == 0x80 }
    public var isEvent: Bool { command >= 0xC0 }
}

/// Frame encoding: `A5 | LEN u16 LE | CMD | STATUS | PAYLOAD | CRC16 u16 LE`,
/// LEN = CMD…CRC inclusive, CRC-16/CCITT-FALSE over CMD…PAYLOAD.
public enum ChiplessCodec {
    public static let sync: UInt8 = 0xA5
    public static let maxLength = 1023

    /// CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF). "123456789" → 0x29B1.
    public static func crc16<C: Collection>(_ bytes: C) -> UInt16 where C.Element == UInt8 {
        var crc: UInt16 = 0xFFFF
        for b in bytes {
            crc ^= UInt16(b) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }

    public static func encode(command: UInt8, status: UInt8 = 0, payload: [UInt8] = []) -> [UInt8] {
        var body: [UInt8] = [command, status]
        body.append(contentsOf: payload)
        let crc = crc16(body)
        body.append(UInt8(crc & 0xFF))
        body.append(UInt8(crc >> 8))
        let len = body.count
        return [sync, UInt8(len & 0xFF), UInt8(len >> 8)] + body
    }

    public static func encode(_ frame: ChiplessFrame) -> [UInt8] {
        encode(command: frame.command, status: frame.status, payload: frame.payload)
    }
}

/// Incremental frame parser: tolerates partial frames, several frames per read, and garbage
/// between frames (it resynchronises on the next 0xA5 after a bad length or CRC).
public final class ChiplessFrameParser {
    private var buffer: [UInt8] = []
    public private(set) var crcErrors = 0
    public private(set) var discardedBytes = 0

    public init() {}

    public func reset() { buffer.removeAll() }

    public func feed(_ bytes: [UInt8]) -> [ChiplessFrame] {
        buffer.append(contentsOf: bytes)
        var frames: [ChiplessFrame] = []
        while true {
            guard let start = buffer.firstIndex(of: ChiplessCodec.sync) else {
                discardedBytes += buffer.count
                buffer.removeAll()
                break
            }
            if start > 0 {
                discardedBytes += start
                buffer.removeFirst(start)
            }
            guard buffer.count >= 3 else { break }
            let len = Int(buffer[1]) | (Int(buffer[2]) << 8)
            if len < 4 || len > ChiplessCodec.maxLength {
                buffer.removeFirst()           // not a real frame start
                discardedBytes += 1
                continue
            }
            guard buffer.count >= 3 + len else { break }
            let body = Array(buffer[3..<(3 + len)])
            let got = UInt16(body[len - 2]) | (UInt16(body[len - 1]) << 8)
            if ChiplessCodec.crc16(body[0..<(len - 2)]) != got {
                crcErrors += 1
                buffer.removeFirst()           // resynchronise on the next 0xA5
                discardedBytes += 1
                continue
            }
            buffer.removeFirst(3 + len)
            frames.append(ChiplessFrame(command: body[0], status: body[1], payload: Array(body[2..<(len - 2)])))
        }
        return frames
    }
}

// MARK: - Little-endian helpers

public struct ByteWriter {
    public private(set) var bytes: [UInt8] = []
    public init() {}
    public mutating func u8(_ v: UInt8) { bytes.append(v) }
    public mutating func i8(_ v: Int8) { bytes.append(UInt8(bitPattern: v)) }
    public mutating func u16(_ v: UInt16) { bytes.append(UInt8(v & 0xFF)); bytes.append(UInt8(v >> 8)) }
    public mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    public mutating func u32(_ v: UInt32) {
        for s in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8((v >> UInt32(s)) & 0xFF)) }
    }
}

public struct ByteReader {
    private let data: [UInt8]
    public private(set) var offset = 0
    public init(_ data: [UInt8]) { self.data = data }

    public var remaining: Int { data.count - offset }

    private mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard offset + n <= data.count else { throw ChiplessError.malformedReply("payload too short (\(data.count) bytes)") }
        defer { offset += n }
        return data[offset..<(offset + n)]
    }
    public mutating func u8() throws -> UInt8 { try take(1).first! }
    public mutating func i8() throws -> Int8 { Int8(bitPattern: try u8()) }
    public mutating func u16() throws -> UInt16 {
        let s = try take(2); return UInt16(s[s.startIndex]) | (UInt16(s[s.startIndex + 1]) << 8)
    }
    public mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }
    public mutating func u32() throws -> UInt32 {
        let s = try take(4)
        var v: UInt32 = 0
        for (i, b) in s.enumerated() { v |= UInt32(b) << UInt32(8 * i) }
        return v
    }
    public mutating func bytes(_ n: Int) throws -> [UInt8] { Array(try take(n)) }
    public mutating func string(_ n: Int) throws -> String {
        let raw = try bytes(n)
        let trimmed = raw.prefix { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self)
    }
}

public func hexString(_ bytes: [UInt8], separator: String = " ") -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: separator)
}
