import XCTest
@testable import ReaderTransport

final class MockTransportTests: XCTestCase {
    func testConnectTransitionsToConnected() async throws {
        let transport = MockTransport()
        try await transport.connect(timeout: 1)
        XCTAssertEqual(transport.state, .connected)
    }

    func testWriteBeforeConnectThrows() async {
        let transport = MockTransport()
        do {
            try await transport.write([0x01])
            XCTFail("Expected notConnected error")
        } catch let error as TransportError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testInjectedTimeoutFaultFailsConnect() async {
        let transport = MockTransport()
        transport.injectedFaults = [.timeout]
        do {
            try await transport.connect(timeout: 1)
            XCTFail("Expected connection failure")
        } catch {
            // expected
        }
    }

    func testDeviceRemovedEventIsEmitted() async throws {
        let transport = MockTransport()
        try await transport.connect(timeout: 1)

        let expectation = expectation(description: "deviceRemoved event received")
        let listenTask = Task {
            for await event in transport.events {
                if case .deviceRemoved = event {
                    expectation.fulfill()
                    break
                }
            }
        }

        transport.simulateDeviceRemoved()
        await fulfillment(of: [expectation], timeout: 1.0)
        listenTask.cancel()
    }

    func testInboundBytesAreDeliveredOnlyWhenConnected() async throws {
        let transport = MockTransport()
        // Not connected yet — should be a no-op, not a crash.
        transport.simulateInboundBytes([0x01, 0x02])

        try await transport.connect(timeout: 1)

        let expectation = expectation(description: "bytesReceived event received")
        let listenTask = Task {
            for await event in transport.events {
                if case .bytesReceived(let bytes) = event {
                    XCTAssertEqual(bytes, [0xAA])
                    expectation.fulfill()
                    break
                }
            }
        }
        transport.simulateInboundBytes([0xAA])
        await fulfillment(of: [expectation], timeout: 1.0)
        listenTask.cancel()
    }
}
