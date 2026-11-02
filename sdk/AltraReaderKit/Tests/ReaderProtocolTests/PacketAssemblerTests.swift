import XCTest
@testable import ReaderProtocol

final class PacketAssemblerTests: XCTestCase {
    func testFeedingBytesInChunksYieldsOneFrameOnceComplete() async throws {
        let codec = ReferenceCodec()
        let assembler = PacketAssembler(codec: codec)
        let bytes = try codec.encode(.getReaderInfo)

        // Feed byte-by-byte except the last chunk — should produce no frames yet.
        for b in bytes.dropLast(1) {
            let frames = try await assembler.feed([b])
            XCTAssertTrue(frames.isEmpty)
        }
        let final = try await assembler.feed([bytes.last!])
        XCTAssertEqual(final.count, 1)
    }

    func testFeedingTwoFramesAtOnceYieldsBoth() async throws {
        let codec = ReferenceCodec()
        let assembler = PacketAssembler(codec: codec)
        let combined = try codec.encode(.getReaderInfo) + codec.encode(.stopInventory)
        let frames = try await assembler.feed(combined)
        XCTAssertEqual(frames.count, 2)
    }

    func testMalformedLeadingJunkThrowsAndThenResyncs() async throws {
        let codec = ReferenceCodec()
        let assembler = PacketAssembler(codec: codec)
        let goodFrame = try codec.encode(.getReaderInfo)
        let junk: [UInt8] = [0x00, 0x11, 0x22]

        await XCTAssertThrowsErrorAsync(try await assembler.feed(junk + goodFrame))

        // Each malformed leading byte surfaces one error and drops one byte, by
        // design (see PacketAssembler.feed) — keep resyncing (no new bytes needed;
        // the valid frame is already buffered) until it's found.
        var frames: [ReaderFrame] = []
        for _ in 0..<junk.count {
            do {
                frames = try await assembler.feed([])
                break
            } catch {
                continue
            }
        }
        XCTAssertFalse(frames.isEmpty, "Expected to resynchronize onto the valid frame after dropping the leading junk bytes")
    }

    func testBufferCapIsEnforced() async throws {
        let codec = ReferenceCodec()
        let assembler = PacketAssembler(codec: codec, maxBufferSize: 16)
        let garbage = [UInt8](repeating: 0x00, count: 32)
        await XCTAssertThrowsErrorAsync(try await assembler.feed(garbage))
    }
}

// Small helper since XCTAssertThrowsError doesn't have an async overload pre-Swift 5.9 test infra in all toolchains.
func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error to be thrown", file: file, line: line)
    } catch {
        // expected
    }
}
