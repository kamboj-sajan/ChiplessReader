import XCTest
@testable import ChiplessKit

final class ChiplessCodecTests: XCTestCase {
    func hex(_ s: String) -> [UInt8] {
        let c = s.replacingOccurrences(of: " ", with: "")
        return stride(from: 0, to: c.count, by: 2).map {
            let a = c.index(c.startIndex, offsetBy: $0)
            return UInt8(c[a..<c.index(a, offsetBy: 2)], radix: 16)!
        }
    }

    func testCRCCheckValue() {
        XCTAssertEqual(ChiplessCodec.crc16(Array("123456789".utf8)), 0x29B1)
    }

    /// Byte vectors from docs/PROTOCOL.md - the firmware produces/accepts exactly these.
    func testEncodeVectors() {
        XCTAssertEqual(ChiplessCodec.encode(command: 0x01), hex("A5 04 00 01 00 3E 2E"))
        XCTAssertEqual(ChiplessCodec.encode(command: 0x02, payload: [0x78, 0x56, 0x34, 0x12]), hex("A5 08 00 02 00 78 56 34 12 AA 55"))
        var w = ByteWriter(); w.u32(865_000)
        XCTAssertEqual(ChiplessCodec.encode(command: 0x20, payload: w.bytes), hex("A5 08 00 20 00 E8 32 0D 00 A8 E7"))
        XCTAssertEqual(ChiplessCodec.encode(command: 0x12, payload: [3, 1]), hex("A5 06 00 12 00 03 01 7D 37"))
        XCTAssertEqual(ChiplessCodec.encode(command: 0x14, payload: [21]), hex("A5 05 00 14 00 15 AB 11"))
        XCTAssertEqual(ChiplessCodec.encode(command: 0xA0, status: 0x04), hex("A5 04 00 A0 04 F5 40"))
    }

    func testParserSplitAndBackToBack() {
        let p = ChiplessFrameParser()
        let a = ChiplessCodec.encode(command: 0x82, payload: [1, 0, 0, 0])
        let b = ChiplessCodec.encode(command: 0x82, payload: [2, 0, 0, 0])
        XCTAssertTrue(p.feed(Array(a[0..<3])).isEmpty)
        XCTAssertTrue(p.feed(Array(a[3..<6])).isEmpty)
        let frames = p.feed(Array(a[6...]) + b)
        XCTAssertEqual(frames.map { $0.payload.first }, [1, 2])
    }

    func testParserResyncAfterGarbageAndBadCRC() {
        let p = ChiplessFrameParser()
        var bad = ChiplessCodec.encode(command: 0xA0, payload: [1, 2, 3, 4])
        bad[bad.count - 1] ^= 0xFF
        let good = ChiplessCodec.encode(command: 0x82, payload: [9, 9, 9, 9])
        let frames = p.feed([0x11, 0xA5, 0x05, 0x00, 0x33] + bad + good)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.command, 0x82)
        XCTAssertEqual(p.crcErrors, 2)   // the garbage (A5 05 00 ...) and the corrupted frame
    }

    func testTagReportParsing() throws {
        var w = ByteWriter()
        w.u32(7); w.u8(1); w.u8(10); w.u32(0x335); w.i16(-226); w.u16(519); w.i16(60)
        w.u16(57); w.u16(201); w.u8(1); w.u16(0); w.u16(0)
        for d: Int16 in [106, 0, 108, 0, 107, 113, 0, 0, 110, 104] { w.i16(d) }
        for s: Int16 in [750, 90, 780, 80, 800, 760, 70, 85, 740, 770] { w.i16(s) }
        w.u8(1); w.u8(0); w.i16(3)
        for b in Array("TEN-A".utf8) + [UInt8](repeating: 0, count: 11) { w.u8(b) }
        let r = try ChiplessReader.parseTagReport(w.bytes)
        XCTAssertEqual(r.hexID, "0x335")
        XCTAssertEqual(r.bitString, "1010110011")
        XCTAssertEqual(r.rssiDBm, -22.6, accuracy: 0.001)
        XCTAssertEqual(r.marginDB, 6.0, accuracy: 0.001)
        XCTAssertEqual(r.notchDepthsDB.count, 10)
        XCTAssertEqual(r.phaseSwingsDegrees[2], 78, accuracy: 0.001)
        XCTAssertTrue(r.matched)
        XCTAssertEqual(r.databaseIndex, 3)
        XCTAssertEqual(r.name, "TEN-A")
    }

    func testBitPatternsAreF1First() {
        XCTAssertEqual(TagPattern.id(fromBits: "1010110011"), 0x335)
        XCTAssertEqual(TagPattern.bits(fromID: 0x335, count: 10), "1010110011")
        XCTAssertEqual(TagPattern.id(fromBits: "10"), 1)
        XCTAssertNil(TagPattern.id(fromBits: "102"))
        XCTAssertNil(TagPattern.id(fromBits: ""))
        XCTAssertEqual(TagDatabaseEntry(name: "x", bitString: "1010110011")?.hexID, "0x335")
    }

    func testStandardProfileIsTenBitsAcrossTheBand() {
        let p = TagProfile.standard(bits: 10)
        XCTAssertEqual(p.bitFrequenciesKHz.first, 860_250)
        XCTAssertEqual(p.bitFrequenciesKHz.last, 864_750)
        XCTAssertEqual(p.minimumBitSpacingKHz, 500)
        XCTAssertEqual(p.sweepPoints, 201)
        XCTAssertEqual(p.requiredResonatorQ, 1250)
        XCTAssertEqual(TagProfile.standard(bits: 1).bitFrequenciesKHz, [862_500])
        XCTAssertEqual(TagProfile.standard(bits: 2).bitFrequenciesKHz, [861_250, 863_750])
    }

    func testProfileRoundTrip() throws {
        var w = ByteWriter()
        for b in Array("Double".utf8) + [UInt8](repeating: 0, count: 10) { w.u8(b) }
        w.u32(860_000); w.u32(865_000); w.u32(25); w.u16(200); w.u8(8); w.u16(60); w.u16(150); w.u16(250); w.u8(1); w.u8(2)
        w.u32(861_250); w.u32(863_750)
        let p = try ChiplessReader.parseProfile(w.bytes)
        XCTAssertEqual(p.name, "Double")
        XCTAssertEqual(p.phaseThresholdDegrees, 15, accuracy: 0.001)
        XCTAssertEqual(p.maxBitErrors, 1)
        XCTAssertEqual(p.bitFrequenciesKHz, [861_250, 863_750])
    }

    func testConditionsDescribeTheirProblems() {
        XCTAssertTrue(RFConditions([]).problems.isEmpty)
        XCTAssertEqual(RFConditions([.echoHigh, .clipped]).problems.count, 2)
    }

    func testTagLibraryMatching() {
        let lib = TagLibrary(tags: [KnownTag(name: "TAG-A", id: 0xA53), KnownTag(name: "TAG-B", id: 0x5AC)])
        XCTAssertEqual(lib.match(0xA53)?.tag.name, "TAG-A")
        XCTAssertNil(lib.match(0xA52))
        XCTAssertEqual(lib.match(0xA52, maxBitErrors: 1)?.bitErrors, 1)
    }
}
