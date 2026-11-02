import XCTest
@testable import ReaderProtocol

final class ReferenceCodecTests: XCTestCase {
    let codec = ReferenceCodec()

    func testEncodeGetReaderInfoProducesSyncByte() throws {
        let bytes = try codec.encode(.getReaderInfo)
        XCTAssertEqual(bytes.first, 0xA5)
    }

    func testEncodeDecodeRoundTrip() throws {
        let bytes = try codec.encode(.getParam("RfPowerMax"))
        let decoded = try codec.decodeFrame(from: bytes)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.consumed, bytes.count)
        XCTAssertEqual(decoded?.frame.isSuccess, true)
    }

    func testPartialPacketReturnsNilNotError() throws {
        let bytes = try codec.encode(.getReaderInfo)
        let partial = Array(bytes.prefix(bytes.count - 2))
        let decoded = try codec.decodeFrame(from: partial)
        XCTAssertNil(decoded, "A truncated frame must be reported as 'need more bytes', not an error.")
    }

    func testChecksumMismatchThrows() throws {
        var bytes = try codec.encode(.getReaderInfo)
        bytes[bytes.count - 1] ^= 0xFF // corrupt the CRC
        XCTAssertThrowsError(try codec.decodeFrame(from: bytes)) { error in
            XCTAssertEqual(error as? ProtocolError, .checksumMismatch)
        }
    }

    func testMultipleFramesInOneBufferAreEachExtracted() throws {
        let a = try codec.encode(.getReaderInfo)
        let b = try codec.encode(.stopInventory)
        let combined = a + b

        let (first, consumed1) = try XCTUnwrap(codec.decodeFrame(from: combined))
        XCTAssertEqual(consumed1, a.count)
        let remainder = Array(combined.dropFirst(consumed1))
        let (second, consumed2) = try XCTUnwrap(codec.decodeFrame(from: remainder))
        XCTAssertEqual(consumed2, b.count)
        XCTAssertEqual(first.isSuccess, true)
        XCTAssertEqual(second.isSuccess, true)
    }

    func testAltraWavesCodecIsBlockedByDesign() {
        let real = AltraWavesCodec()
        XCTAssertThrowsError(try real.encode(.getReaderInfo)) { error in
            guard case ProtocolError.unverifiedProtocol = error else {
                return XCTFail("Expected .unverifiedProtocol, got \(error)")
            }
        }
    }
}

final class CRC16Tests: XCTestCase {
    func testKnownVector() {
        // "123456789" is the standard CRC-16/CCITT-FALSE test vector -> 0x29B1
        let bytes = Array("123456789".utf8)
        XCTAssertEqual(CRC16.ccitt(bytes), 0x29B1)
    }
}
