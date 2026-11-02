import XCTest
import ReaderTransport
import ReaderProtocol
@testable import ReaderSDK

final class ReaderClientMockTests: XCTestCase {
    func testConnectAndDisconnectMock() async throws {
        let client = ReaderClient(descriptor: .mock())
        try await client.connect()
        await client.disconnect()
    }

    func testReaderInfoInMockModeReturnsSimulatedInfo() async throws {
        let client = ReaderClient(descriptor: .mock())
        try await client.connect()
        let info = try await client.readerInfo()
        XCTAssertEqual(info.antennaCount, 4)
        await client.disconnect()
    }

    func testRealTransportCommandsAreBlockedUntilProtocolIsVerified() async throws {
        // Reader *commands* (not connect/disconnect) must be refused for any
        // non-mock transport until a verified codec exists — this is checked before
        // any network/serial I/O happens, so no reachable hardware is needed here.
        let client = ReaderClient(descriptor: .tcp(host: "192.168.1.100", port: 4001))
        do {
            _ = try await client.readerInfo()
            XCTFail("Expected .protocolLayer(.unverifiedProtocol) since no real codec exists yet")
        } catch ReaderSDKError.protocolLayer(.unverifiedProtocol(let command)) {
            XCTAssertEqual(command, "getReaderInfo")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStartInventoryDeliversSimulatedTagReadEvents() async throws {
        let client = ReaderClient(descriptor: .mock())
        try await client.connect()

        let expectation = expectation(description: "received at least one tag read")
        let listener = Task {
            for await event in client.events {
                if case .tagRead = event {
                    expectation.fulfill()
                    break
                }
            }
        }

        try await client.startInventory()
        await fulfillment(of: [expectation], timeout: 3.0)
        try await client.stopInventory()
        listener.cancel()
        await client.disconnect()
    }

    func testSingleInventoryReturnsNonEmptySnapshot() async throws {
        let client = ReaderClient(descriptor: .mock())
        try await client.connect()
        let reads = try await client.singleInventory()
        XCTAssertFalse(reads.isEmpty)
        await client.disconnect()
    }

    func testWriteWithoutAcknowledgementIsRejected() async throws {
        let client = ReaderClient(descriptor: .mock())
        try await client.connect()
        let confirmation = WriteConfirmation(targetEPC: "E280", bank: .user, startAddress: 0,
                                              dataHex: "1234", userAcknowledged: false)
        do {
            try await client.writeMemory(confirmation)
            XCTFail("Expected invalidConfirmation error")
        } catch ReaderSDKError.invalidConfirmation {
            // expected
        }
        await client.disconnect()
    }

    func testWriteWithAcknowledgementSucceedsInMockMode() async throws {
        let client = ReaderClient(descriptor: .mock())
        try await client.connect()
        let confirmation = WriteConfirmation(targetEPC: "E280", bank: .user, startAddress: 0,
                                              dataHex: "1234", userAcknowledged: true)
        try await client.writeMemory(confirmation)
        await client.disconnect()
    }

    func testKillWithoutIrreversibilityAcknowledgementIsRejected() async throws {
        let client = ReaderClient(descriptor: .mock())
        try await client.connect()
        let confirmation = KillConfirmation(targetEPC: "E280", killPassword: "00000000",
                                             userAcknowledged: true, understandsIrreversibility: false)
        do {
            try await client.killTag(confirmation)
            XCTFail("Expected invalidConfirmation error")
        } catch ReaderSDKError.invalidConfirmation {
            // expected
        }
        await client.disconnect()
    }
}

final class InventorySessionTests: XCTestCase {
    @MainActor
    func testDuplicateReadsAreDeduplicatedAndCounted() {
        let session = InventorySession()
        let read1 = TagRead(epc: "E280AAAA", antenna: 1, rssi: -40)
        let read2 = TagRead(epc: "E280AAAA", antenna: 1, rssi: -38)
        session.ingest(read1)
        session.ingest(read2)
        XCTAssertEqual(session.rows.count, 1)
        XCTAssertEqual(session.rows[0].readCount, 2)
        XCTAssertEqual(session.rows[0].lastRSSI, -38)
        XCTAssertEqual(session.totalReads, 2)
    }

    @MainActor
    func testDifferentEPCsProduceSeparateRows() {
        let session = InventorySession()
        session.ingest(TagRead(epc: "AAAA", antenna: 1, rssi: -40))
        session.ingest(TagRead(epc: "BBBB", antenna: 1, rssi: -40))
        XCTAssertEqual(session.rows.count, 2)
    }

    @MainActor
    func testClearResetsState() {
        let session = InventorySession()
        session.ingest(TagRead(epc: "AAAA", antenna: 1, rssi: -40))
        session.clear()
        XCTAssertTrue(session.rows.isEmpty)
        XCTAssertEqual(session.totalReads, 0)
    }
}

final class InventoryExportTests: XCTestCase {
    @MainActor
    func testCSVExportContainsHeaderAndRow() {
        let session = InventorySession()
        session.ingest(TagRead(epc: "E280AAAA", antenna: 2, rssi: -41))
        let csv = InventoryExport.csv(session.rows)
        XCTAssertTrue(csv.hasPrefix("epc,tid,antenna,last_rssi,read_count,first_seen,last_seen"))
        XCTAssertTrue(csv.contains("E280AAAA"))
    }

    @MainActor
    func testJSONExportRoundTrips() throws {
        let session = InventorySession()
        session.ingest(TagRead(epc: "E280AAAA", antenna: 2, rssi: -41))
        let data = try InventoryExport.json(session.rows)
        let decoded = try JSONDecoder().decode([InventoryRow].self, from: data)
        XCTAssertEqual(decoded.first?.epc, "E280AAAA")
    }
}
