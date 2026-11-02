import Foundation

public enum ChiplessError: Error, CustomStringConvertible, Equatable {
    case notConnected
    case openFailed(String)
    case writeFailed(String)
    case timeout(String)
    case readerStatus(command: String, status: String)
    case malformedReply(String)
    case invalidArgument(String)

    public var description: String {
        switch self {
        case .notConnected: return "Not connected to a reader."
        case .openFailed(let s): return "Could not open the serial port: \(s)"
        case .writeFailed(let s): return "Write to the reader failed: \(s)"
        case .timeout(let c): return "No reply from the reader to \(c) (timeout)."
        case .readerStatus(let c, let s): return "Reader rejected \(c): \(s)"
        case .malformedReply(let s): return "Malformed reply: \(s)"
        case .invalidArgument(let s): return "Invalid argument: \(s)"
        }
    }
}

public enum ReaderMode: UInt8, Sendable, CustomStringConvertible {
    case response = 0
    case auto = 1
    public var description: String { self == .auto ? "AUTO" : "RESPONSE" }
}

/// ADF4351 output power setting (register R4). The MAX2235 PA compresses, so these 9 dB of drive
/// become about 3 dB at the antenna.
public enum TxPowerLevel: UInt8, CaseIterable, Sendable, CustomStringConvertible {
    case minus4dBm = 0, minus1dBm = 1, plus2dBm = 2, plus5dBm = 3

    public var dBm: Int { [-4, -1, 2, 5][Int(rawValue)] }
    public var description: String { String(format: "%+d dBm", dBm) }

    public init?(dBm: Int) {
        switch dBm {
        case -4: self = .minus4dBm
        case -1: self = .minus1dBm
        case 2: self = .plus2dBm
        case 5: self = .plus5dBm
        default: return nil
        }
    }
}

public struct ReaderInfo: Sendable, Equatable {
    public var firmwareVersion: String
    public var hardwareRevision: Int
    public var simulatedFrontEnd: Bool
    public var uid: String
    public var model: String
}

public struct ReaderStatus: Sendable, Equatable {
    public var mode: ReaderMode
    public var pllLocked: Bool
    public var backgroundCaptured: Bool
    public var loKHz: UInt32
    public var uptimeMs: UInt32
    public var framesOK: UInt32
    public var framesWithErrors: UInt32
    public var reads: UInt32
    public var tagsFound: UInt32
    public var txPowerDBm: Double
}

public struct ReaderConfig: Sendable, Equatable {
    public var loKHz: UInt32
    public var sweepStartKHz: UInt32
    public var sweepStopKHz: UInt32
    public var sweepStepKHz: UInt32
    public var txLevel: TxPowerLevel
    public var paEnabled: Bool
    public var refAttenuationDB: Double
    public var settleMicroseconds: UInt16
    public var averages: UInt8
    public var thresholdDB: Double
    public var bitCount: Int
    public var mode: ReaderMode
    public var autoIntervalMs: UInt16

    public var sweepPoints: Int { Int((sweepStopKHz - sweepStartKHz) / max(sweepStepKHz, 1)) + 1 }
}

/// Result of SET_LO: what the STM32 computed and wrote to the ADF4351.
public struct LOResult: Sendable, Equatable {
    public var requestedKHz: UInt32
    public var locked: Bool
    public var actualHz: UInt32
    public var int: UInt16
    public var frac: UInt16
    public var mod: UInt16
    public var rfDivider: UInt8
    public var vcoKHz: UInt32
    /// R0…R5 exactly as clocked into the chip.
    public var registers: [UInt32]
}

/// One AD8302 measurement at the current LO frequency.
public struct RFMeasurement: Sendable, Equatable {
    public var loKHz: UInt32
    public var adcMagnitude: UInt16      // 12-bit counts
    public var adcPhase: UInt16
    public var vmagMillivolts: UInt16
    public var vphsMillivolts: UInt16
    public var gainDB: Double            // P(INPA) - P(INPB)
    public var phaseDegrees: Double      // |phase difference|
    public var referenceDBm: Double      // estimated P(INPA)
    public var receivedDBm: Double       // P(INPB)
    public var rssiDBm: Double           // referred to the RX antenna
    public var clipped: Bool
    public var pllLocked: Bool
    public var conditions: RFConditions
}

/// AD8302 input and output conditions, reported with every measurement.
public struct RFConditions: OptionSet, Sendable, Equatable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let referenceHigh = RFConditions(rawValue: 0x01)   // INPA above 0 dBm
    public static let referenceLow = RFConditions(rawValue: 0x02)    // INPA below -60 dBm
    public static let echoHigh = RFConditions(rawValue: 0x04)        // INPB above 0 dBm
    public static let echoLow = RFConditions(rawValue: 0x08)         // INPB below -60 dBm
    public static let clipped = RFConditions(rawValue: 0x10)         // VMAG at a rail, outside +/-30 dB

    public var problems: [String] {
        var out: [String] = []
        if contains(.referenceHigh) { out.append("Reference above the AD8302's 0 dBm input limit. Add attenuation.") }
        if contains(.referenceLow) { out.append("Reference below the AD8302's -60 dBm input limit. Reduce attenuation or turn the PA on.") }
        if contains(.echoHigh) { out.append("Echo above the AD8302's 0 dBm input limit. Improve TX/RX isolation or reduce TX power.") }
        if contains(.echoLow) { out.append("Echo below the AD8302's -60 dBm input limit. Move the tag closer or raise TX power.") }
        if contains(.clipped) { out.append("VMAG is at a rail: the levels are more than 30 dB apart. Run Auto-level.") }
        return out
    }
}

/// What the reader has to know about the tags it reads. A chipless tag cannot announce any of this
/// itself, so the tags and the reader must agree on it: which frequencies to sweep, where each bit
/// sits, how fast to read and how to decide a bit.
public struct TagProfile: Sendable, Equatable, Codable {
    public var name: String
    public var sweepStartKHz: UInt32
    public var sweepStopKHz: UInt32
    public var sweepStepKHz: UInt32
    public var settleMicroseconds: UInt16
    public var averages: UInt8
    public var thresholdDB: Double
    /// Phase swing that confirms a notch. 0 = decide on magnitude alone.
    public var phaseThresholdDegrees: Double
    public var autoIntervalMs: UInt16
    /// Differing bits allowed when matching against the database.
    public var maxBitErrors: UInt8
    /// Resonance frequency of each bit, f1 (bit 0) first.
    public var bitFrequenciesKHz: [UInt32]

    public init(name: String, sweepStartKHz: UInt32, sweepStopKHz: UInt32, sweepStepKHz: UInt32,
                settleMicroseconds: UInt16 = 200, averages: UInt8 = 8, thresholdDB: Double = 6,
                phaseThresholdDegrees: Double = 15, autoIntervalMs: UInt16 = 250, maxBitErrors: UInt8 = 0,
                bitFrequenciesKHz: [UInt32]) {
        self.name = name
        self.sweepStartKHz = sweepStartKHz
        self.sweepStopKHz = sweepStopKHz
        self.sweepStepKHz = sweepStepKHz
        self.settleMicroseconds = settleMicroseconds
        self.averages = averages
        self.thresholdDB = thresholdDB
        self.phaseThresholdDegrees = phaseThresholdDegrees
        self.autoIntervalMs = autoIntervalMs
        self.maxBitErrors = maxBitErrors
        self.bitFrequenciesKHz = bitFrequenciesKHz
    }

    /// One resonator at the centre of each of n equal cells across the band.
    public static func evenlySpaced(bits n: Int, startKHz: UInt32, stopKHz: UInt32) -> [UInt32] {
        let span = stopKHz - startKHz
        return (0..<n).map { startKHz + span * (2 * UInt32($0) + 1) / (2 * UInt32(n)) }
    }

    /// The 860-865 MHz band with n bits and a 25 kHz sweep step.
    public static func standard(bits n: Int) -> TagProfile {
        TagProfile(name: n == 1 ? "Single" : n == 2 ? "Double" : "\(n)-bit 860-865",
                   sweepStartKHz: 860_000, sweepStopKHz: 865_000, sweepStepKHz: 25,
                   bitFrequenciesKHz: evenlySpaced(bits: n, startKHz: 860_000, stopKHz: 865_000))
    }

    public var sweepPoints: Int { Int((sweepStopKHz - sweepStartKHz) / max(sweepStepKHz, 1)) + 1 }

    /// Closest distance between two bits; with one bit, the whole sweep.
    public var minimumBitSpacingKHz: UInt32 {
        let sorted = bitFrequenciesKHz.sorted()
        guard sorted.count > 1 else { return sweepStopKHz - sweepStartKHz }
        return zip(sorted, sorted.dropFirst()).map { $1 - $0 }.min() ?? 0
    }

    /// Roughly the resonator Q the tags need for their notches to stay apart at this spacing. From
    /// tools/q_study.py on the simulated front-end: 10 bits at 500 kHz spacing need Q ~ 1250.
    public var requiredResonatorQ: Int {
        guard bitFrequenciesKHz.count > 1 else { return 50 }
        return Int((625_000 / Double(max(minimumBitSpacingKHz, 1))).rounded())
    }
}

/// One tag known to the STM32's database.
public struct TagDatabaseEntry: Sendable, Equatable, Codable, Identifiable, Hashable {
    public var name: String
    public var tagID: UInt32
    public var bitCount: Int

    public init(name: String, tagID: UInt32, bitCount: Int) {
        self.name = name
        self.tagID = tagID
        self.bitCount = bitCount
    }

    /// From a pattern written f1 first, e.g. "1010110011". Nil if it isn't 1...16 ones and zeros.
    public init?(name: String, bitString: String) {
        guard let id = TagPattern.id(fromBits: bitString) else { return nil }
        self.init(name: name, tagID: id, bitCount: bitString.count)
    }

    public var id: String { "\(bitCount):\(tagID)" }
    public var bitString: String { TagPattern.bits(fromID: tagID, count: bitCount) }
    public var hexID: String { TagPattern.hex(tagID, count: bitCount) }
}

/// Bit patterns are written f1 (the lowest frequency) first; in an ID, bit k is resonator k.
public enum TagPattern {
    public static func bits(fromID id: UInt32, count: Int) -> String {
        (0..<count).map { (id >> UInt32($0)) & 1 == 1 ? "1" : "0" }.joined()
    }
    public static func id(fromBits s: String) -> UInt32? {
        guard (1...16).contains(s.count) else { return nil }
        var v: UInt32 = 0
        for (k, c) in s.enumerated() {
            switch c {
            case "1": v |= 1 << UInt32(k)
            case "0": break
            default: return nil
            }
        }
        return v
    }
    public static func hex(_ id: UInt32, count: Int) -> String {
        String(format: "0x%0\(max(1, (count + 3) / 4))X", id)
    }
}

/// The RF chain numbers the reader uses to turn AD8302 voltages into dBm. They start as datasheet
/// values; replace them with what you measure.
public struct RFCalibration: Sendable, Equatable, Codable {
    public var txFilterLossDB: Double
    public var paTrimDB: Double
    public var couplerDB: Double
    public var couplerThroughLossDB: Double
    public var attenuatorInsertionLossDB: Double
    public var lnaGainDB: Double
    public var rxFilterLossDB: Double
    public var vmagCenterMillivolts: Double
    public var vmagSlopeMillivoltsPerDB: Double
    public var vphsCenterMillivolts: Double
    public var vphsSlopeMillivoltsPerDegree: Double
    public var rssiTrimDB: Double

    /// The values in firmware/core/app_config.h.
    public static let datasheet = RFCalibration(
        txFilterLossDB: 0.65, paTrimDB: 0, couplerDB: 19.7, couplerThroughLossDB: 0.05,
        attenuatorInsertionLossDB: 1.3, lnaGainDB: 19.5, rxFilterLossDB: 1.55, vmagCenterMillivolts: 900,
        vmagSlopeMillivoltsPerDB: 28.7, vphsCenterMillivolts: 900, vphsSlopeMillivoltsPerDegree: 10.1, rssiTrimDB: 0)
}

/// One point of an attenuator scan.
public struct AttenuatorScanPoint: Sendable, Equatable, Identifiable {
    public var attenuationDB: Double
    public var vmagMillivolts: UInt16
    public var gainDB: Double
    public var inpaDBm: Double
    public var conditions: RFConditions
    public var id: Double { attenuationDB }
}

/// Result of Auto-level: the PE4312 setting that centres the AD8302 on the last sweep.
public struct AutoLevelResult: Sendable, Equatable {
    public var oldAttenuationDB: Double
    public var newAttenuationDB: Double
    public var gainMinDB: Double
    public var gainMaxDB: Double
    public var inpaDBm: Double
    public var clippedPoints: Int
    public var conditions: RFConditions
    public var iterations: Int
}

public struct DetectionSettings: Sendable, Equatable {
    public var thresholdDB: Double
    /// Resonance frequency of each tag bit, lowest (bit 0) first.
    public var bitFrequenciesKHz: [UInt32]
    public init(thresholdDB: Double, bitFrequenciesKHz: [UInt32]) {
        self.thresholdDB = thresholdDB
        self.bitFrequenciesKHz = bitFrequenciesKHz
    }
}

/// A tag read - the chipless equivalent of the chipped reader's inventory record (EPC/TID/RSSI).
public struct TagReport: Sendable, Equatable {
    public var sequence: UInt32
    public var found: Bool
    public var bitCount: Int
    /// Decoded ID: bit k = resonator k present (bit 0 = lowest frequency).
    public var id: UInt32
    public var rssiDBm: Double
    public var phaseDegrees: Double
    /// Distance of the least-certain bit from the threshold (dB). Higher = more robust read.
    public var marginDB: Double
    public var sweepMilliseconds: Int
    public var points: Int
    public var backgroundSubtracted: Bool
    public var clippedPoints: Int
    public var unlockedPoints: Int
    /// Notch depth measured at each bit frequency (dB).
    public var notchDepthsDB: [Double]
    /// Phase swing across each bit frequency (degrees).
    public var phaseSwingsDegrees: [Double]
    /// The decoded pattern was found in the reader's database.
    public var matched: Bool
    public var bitErrors: Int
    public var databaseIndex: Int?
    /// Name from the reader's database ("" when not matched).
    public var name: String
    public var timestamp: Date

    /// Bits in frequency order f1…fN (bit 0 first) - how they appear along the sweep.
    public var bitString: String { TagPattern.bits(fromID: id, count: bitCount) }
    public var hexID: String { TagPattern.hex(id, count: bitCount) }
}

public struct SweepPoint: Sendable, Equatable {
    public var frequencyMHz: Double
    public var receivedDBm: Double       // at the RX antenna
    public var phaseDegrees: Double
    public var backgroundDBm: Double?    // nil if no background captured
    /// Tag response: received minus background (or raw if no background).
    public var responseDB: Double { receivedDBm - (backgroundDBm ?? 0) }
}

public struct SimulatedTag: Sendable, Equatable {
    public var index: Int
    public var name: String
    public var code: UInt32
    public var bitCount: Int
    public var bitString: String { TagPattern.bits(fromID: code, count: bitCount) }
}

public struct SimulationState: Sendable, Equatable {
    public var tagIndex: Int?            // nil = no tag in front of the antennas
    public var distanceCm: Int
    public var noiseDB: Double
    public var resonatorQ: Int
    public var tags: [SimulatedTag]
}
