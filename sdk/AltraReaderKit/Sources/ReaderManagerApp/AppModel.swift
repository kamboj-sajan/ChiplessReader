import Foundation
import Combine
import ReaderTransport
import ReaderProtocol
import ReaderSDK

enum ConnectionKind: String, CaseIterable, Identifiable, Hashable {
    case mock = "Simulation"
    case serial = "Serial"
    case tcp = "Network (TCP)"
    var id: String { rawValue }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var connectionKind: ConnectionKind = .mock
    @Published var serialPath: String = SerialDeviceDiscovery.candidateDevices().first ?? ""
    @Published var baudRate: String = "115200"
    @Published var tcpHost: String = "192.168.1.100"
    @Published var tcpPort: String = "4001"

    @Published private(set) var transportState: TransportState = .disconnected
    @Published private(set) var isConnected = false
    @Published private(set) var readerInfo: ReaderInfo?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var logLines: [String] = []
    @Published var isInventoryRunning = false

    let inventory = InventorySession()

    private var client: ReaderClient?
    private var eventTask: Task<Void, Never>?

    var availableSerialDevices: [String] { SerialDeviceDiscovery.candidateDevices() }

    func connect() async {
        let descriptor = buildDescriptor()
        let client = ReaderClient(descriptor: descriptor)
        self.client = client
        subscribeToEvents(of: client)
        do {
            try await client.connect()
            isConnected = true
            lastErrorMessage = nil
            if let info = try? await client.readerInfo() {
                readerInfo = info
            }
        } catch {
            lastErrorMessage = "\(error)"
            isConnected = false
        }
    }

    func disconnect() async {
        isInventoryRunning = false
        await client?.disconnect()
        eventTask?.cancel()
        isConnected = false
        readerInfo = nil
    }

    func toggleInventory() async {
        guard let client else { return }
        do {
            if isInventoryRunning {
                try await client.stopInventory()
                isInventoryRunning = false
            } else {
                inventory.clear()
                try await client.startInventory()
                isInventoryRunning = true
            }
        } catch {
            lastErrorMessage = "\(error)"
        }
    }

    func performSingleScan() async {
        guard let client else { return }
        do {
            let reads = try await client.singleInventory()
            for read in reads { inventory.ingest(read) }
        } catch {
            lastErrorMessage = "\(error)"
        }
    }

    func clearError() { lastErrorMessage = nil }

    func injectMalformedPacket() async { await client?.simulateMalformedPacket() }
    func injectDisconnect() async { await client?.simulateDisconnect() }

    func applyRegion(_ region: RFRegion) async throws {
        guard let client else { throw ReaderSDKError.notConnected }
        try await client.setRegion(region)
    }

    func applyPower(_ dBm: Int) async throws {
        guard let client else { throw ReaderSDKError.notConnected }
        try await client.setRFPower(dBm: dBm, antenna: nil)
    }

    func applyGen2(_ config: Gen2Configuration) async throws {
        guard let client else { throw ReaderSDKError.notConnected }
        try await client.setGen2Configuration(config)
    }

    func applyFilter(_ filter: TagFilter?) async throws {
        guard let client else { throw ReaderSDKError.notConnected }
        try await client.setFilter(filter)
    }

    func readTagMemory(epc: String, bank: MemoryBank, startAddress: Int, wordCount: Int, accessPassword: String?) async throws -> String {
        guard let client else { throw ReaderSDKError.notConnected }
        return try await client.readMemory(epc: epc, bank: bank, startAddress: startAddress,
                                             wordCount: wordCount, accessPassword: accessPassword)
    }

    // MARK: - Destructive ops (require explicit confirmations from the caller/UI)

    func performWrite(_ confirmation: WriteConfirmation) async {
        guard let client else { return }
        do { try await client.writeMemory(confirmation) }
        catch { lastErrorMessage = "\(error)" }
    }

    func performLock(_ confirmation: LockConfirmation) async {
        guard let client else { return }
        do { try await client.lockTag(confirmation) }
        catch { lastErrorMessage = "\(error)" }
    }

    func performKill(_ confirmation: KillConfirmation) async {
        guard let client else { return }
        do { try await client.killTag(confirmation) }
        catch { lastErrorMessage = "\(error)" }
    }

    // MARK: - Internals

    private func buildDescriptor() -> TransportDescriptor {
        switch connectionKind {
        case .mock:
            return .mock()
        case .serial:
            return .serial(path: serialPath, baudRate: Int(baudRate) ?? 115_200)
        case .tcp:
            return .tcp(host: tcpHost, port: UInt16(tcpPort) ?? 4001)
        }
    }

    private func subscribeToEvents(of client: ReaderClient) {
        eventTask?.cancel()
        eventTask = Task {
            for await event in client.events {
                switch event {
                case .connectionStateChanged(let state):
                    self.transportState = state
                case .tagRead(let read):
                    self.inventory.ingest(read)
                case .diagnosticLog(let msg):
                    self.appendLog(msg)
                case .error(let msg):
                    self.lastErrorMessage = msg
                    self.appendLog("ERROR: \(msg)")
                }
            }
        }
    }

    private func appendLog(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        logLines.append("\(stamp)  \(line)")
        if logLines.count > 500 { logLines.removeFirst(logLines.count - 500) }
    }
}
