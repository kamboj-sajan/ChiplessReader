import Foundation

/// RF region — names mirror the parameter values seen in the reference app's
/// source (`ModuleTech.Region`, `Reader.Create(address, Region.NA, ...)`).
public enum RFRegion: String, Sendable, Hashable, CaseIterable, Codable {
    case na = "NA"
    case eu = "EU"
    case china = "CN"
    case japan = "JP"
    case korea = "KR"
    case india = "IN"
    case unspecified = "OPEN"
}

public enum MemoryBank: String, Sendable, Hashable, CaseIterable, Codable {
    case reserved   // access/kill passwords
    case epc
    case tid
    case user
}

public enum Gen2Session: Int, Sendable, Hashable, CaseIterable, Codable { case s0 = 0, s1, s2, s3 }
public enum Gen2Target: String, Sendable, Hashable, CaseIterable, Codable { case a = "A", b = "B", autoToggle = "AB" }

public struct Gen2Configuration: Sendable, Equatable, Codable {
    public var session: Gen2Session
    public var target: Gen2Target
    public var qValue: Int? // nil = dynamic Q

    public init(session: Gen2Session = .s0, target: Gen2Target = .a, qValue: Int? = nil) {
        self.session = session
        self.target = target
        self.qValue = qValue
    }
}

/// One tag observation. Field set mirrors what the reference app's inventory
/// table displays (EPC, ANT, RSSI, FREQ, PHASE, protocol) plus SDK-level
/// bookkeeping (seen count, first/last seen) that the reference app computes
/// in its own view layer rather than exposing from the reader.
public struct TagRead: Sendable, Equatable, Codable {
    public var epc: String            // hex string
    public var tid: String?           // hex string, if TID read was requested
    public var antenna: Int
    public var rssi: Int              // dBm
    public var frequencyKHz: Int?
    public var phaseDegrees: Int?
    public var timestamp: Date

    public init(epc: String, tid: String? = nil, antenna: Int, rssi: Int,
                frequencyKHz: Int? = nil, phaseDegrees: Int? = nil, timestamp: Date = Date()) {
        self.epc = epc
        self.tid = tid
        self.antenna = antenna
        self.rssi = rssi
        self.frequencyKHz = frequencyKHz
        self.phaseDegrees = phaseDegrees
        self.timestamp = timestamp
    }
}

public struct ReaderInfo: Sendable, Equatable, Codable {
    public var mainboardType: String
    public var moduleType: String
    public var hardwareVersion: String
    public var softwareVersion: String
    public var antennaCount: Int

    public init(mainboardType: String, moduleType: String, hardwareVersion: String,
                softwareVersion: String, antennaCount: Int) {
        self.mainboardType = mainboardType
        self.moduleType = moduleType
        self.hardwareVersion = hardwareVersion
        self.softwareVersion = softwareVersion
        self.antennaCount = antennaCount
    }
}

public enum FilterRule: String, Sendable, Hashable, CaseIterable, Codable { case match, noMatch }

public struct TagFilter: Sendable, Equatable, Codable {
    public var bank: MemoryBank
    public var startBit: Int
    public var maskHex: String
    public var rule: FilterRule

    public init(bank: MemoryBank, startBit: Int, maskHex: String, rule: FilterRule = .match) {
        self.bank = bank
        self.startBit = startBit
        self.maskHex = maskHex
        self.rule = rule
    }
}

/// Abstract commands the SDK issues. A `PacketCodec` turns these into wire bytes;
/// which commands a given codec actually supports is up to that codec (see
/// `PacketCodec.supports`).
public enum ReaderCommand: Sendable, Equatable {
    case getReaderInfo
    case getParam(String)
    case setParam(String, ParamValue)
    case startInventory(antennas: [Int])
    case stopInventory
    case singleInventory(antennas: [Int])
    case readMemory(bank: MemoryBank, startAddress: Int, wordCount: Int, accessPassword: String?)
    case writeMemory(bank: MemoryBank, startAddress: Int, dataHex: String, accessPassword: String?)
    case lockTag(target: String, type: String, accessPassword: String)
    case killTag(killPassword: String)
    case raw([UInt8]) // diagnostic escape hatch — never used by the public SDK directly
}

public enum ParamValue: Sendable, Equatable {
    case int(Int)
    case string(String)
    case bool(Bool)
    case intArray([Int])
}

/// A decoded response frame. `payload` is codec-specific raw bytes; the SDK layer
/// is responsible for interpreting them once a real codec exists.
public struct ReaderFrame: Sendable, Equatable {
    public var isSuccess: Bool
    public var statusCode: Int
    public var payload: [UInt8]

    public init(isSuccess: Bool, statusCode: Int, payload: [UInt8]) {
        self.isSuccess = isSuccess
        self.statusCode = statusCode
        self.payload = payload
    }
}

public enum ProtocolError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The wire-level protocol for this command/reader has not been verified against
    /// real hardware or an authoritative spec. Thrown instead of guessing.
    case unverifiedProtocol(command: String)
    case malformedPacket(reason: String)
    case checksumMismatch
    case unsupportedCommand(String)
    case decodeIncomplete // not an error condition per se — used internally by the assembler

    public var description: String {
        switch self {
        case .unverifiedProtocol(let command):
            return "No verified wire-protocol encoding exists for '\(command)' yet. See Documentation/PROTOCOL.md."
        case .malformedPacket(let reason):
            return "Malformed packet: \(reason)"
        case .checksumMismatch:
            return "Checksum mismatch."
        case .unsupportedCommand(let name):
            return "Command not supported by this codec: \(name)"
        case .decodeIncomplete:
            return "Incomplete frame (internal)."
        }
    }
}
