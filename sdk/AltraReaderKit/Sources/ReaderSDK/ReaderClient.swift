import Foundation
import ReaderTransport
import ReaderProtocol

/// The public SDK surface for talking to an Altra Waves UHF reader (or a
/// simulated one). This is the only type applications should depend on —
/// `ReaderTransport` and `ReaderProtocol` are implementation details.
///
/// Thread-safety: `ReaderClient` is a Swift actor. All operations are safe to call
/// concurrently; they are simply serialized. Long-running operations
/// (`startInventory`) return immediately after arming the reader; tag data arrives
/// via `events`.
///
/// Real hardware today: `connect()`/`disconnect()` work over serial or TCP because
/// they're transport-only operations. Every reader *command* — `readerInfo()`,
/// `startInventory()`, memory read/write, etc. — throws
/// `ReaderSDKError.protocolLayer(.unverifiedProtocol)` for real hardware until a
/// verified `PacketCodec` (`AltraWavesCodec`) replaces the placeholder. See
/// `Documentation/PROTOCOL.md`. Mock mode is fully functional today.
public actor ReaderClient {
    public let descriptor: TransportDescriptor
    private let transport: any Transport
    private let codec: any PacketCodec
    private let assembler: PacketAssembler
    private let simulation: SimulationEngine?

    private var eventContinuation: AsyncStream<ReaderEvent>.Continuation?
    public nonisolated let events: AsyncStream<ReaderEvent>

    private var forwardingTask: Task<Void, Never>?
    private var inventoryActive = false

    public var isMock: Bool {
        if case .mock = descriptor { return true }
        return false
    }

    public init(descriptor: TransportDescriptor, retryPolicy: RetryPolicy = .default) {
        self.descriptor = descriptor

        switch descriptor {
        case .serial(let path, let baud):
            #if os(macOS)
            self.transport = SerialTransport(path: path, baudRate: baud)
            #else
            self.transport = MockTransport()
            #endif
            self.codec = AltraWavesCodec()
            self.simulation = nil
        case .tcp(let host, let port):
            #if canImport(Network)
            self.transport = TCPTransport(host: host, port: port)
            #else
            self.transport = MockTransport()
            #endif
            self.codec = AltraWavesCodec()
            self.simulation = nil
        case .mock:
            self.transport = MockTransport()
            self.codec = ReferenceCodec()
            self.simulation = SimulationEngine()
        }

        self.assembler = PacketAssembler(codec: self.codec)

        var cont: AsyncStream<ReaderEvent>.Continuation!
        self.events = AsyncStream { c in cont = c }
        self.eventContinuation = cont
    }

    // MARK: - Connection

    public func connect(timeout: TimeInterval = 5.0) async throws {
        do {
            try await transport.connect(timeout: timeout)
        } catch let error as TransportError {
            throw ReaderSDKError.transport(error)
        }
        startForwardingTransportEvents()
        eventContinuation?.yield(.diagnosticLog("Connected via \(describe(descriptor))"))
    }

    public func disconnect() async {
        await simulation?.stop()
        inventoryActive = false
        forwardingTask?.cancel()
        await transport.disconnect()
        await assembler.reset()
        eventContinuation?.yield(.diagnosticLog("Disconnected"))
    }

    // MARK: - Reader info / configuration

    public func readerInfo() async throws -> ReaderInfo {
        if isMock {
            return ReaderInfo(mainboardType: "MAINBOARD_SIM", moduleType: "MODULE_SIM3300",
                               hardwareVersion: "SIM.00.00.00", softwareVersion: "SIM.00.00.00",
                               antennaCount: 4)
        }
        try requireVerifiedProtocol(command: "getReaderInfo")
    }

    public func setRegion(_ region: RFRegion) async throws {
        try await sendConfigCommand(.setParam("Region", .string(region.rawValue)))
    }

    public func setRFPower(dBm: Int, antenna: Int?) async throws {
        let key = antenna.map { "AntPower[\($0)]" } ?? "AntPowerAll"
        try await sendConfigCommand(.setParam(key, .int(dBm)))
    }

    public func setGen2Configuration(_ config: Gen2Configuration) async throws {
        try await sendConfigCommand(.setParam("Gen2Session", .int(config.session.rawValue)))
        try await sendConfigCommand(.setParam("Gen2Target", .string(config.target.rawValue)))
        if let q = config.qValue {
            try await sendConfigCommand(.setParam("Gen2Q", .int(q)))
        }
    }

    public func setFilter(_ filter: TagFilter?) async throws {
        guard let filter else {
            try await sendConfigCommand(.setParam("FilterEnabled", .bool(false)))
            return
        }
        try await sendConfigCommand(.setParam("FilterEnabled", .bool(true)))
        try await sendConfigCommand(.setParam("FilterBank", .string(filter.bank.rawValue)))
        try await sendConfigCommand(.setParam("FilterMask", .string(filter.maskHex)))
    }

    // MARK: - Inventory

    public func startInventory(antennas: [Int] = [1]) async throws {
        guard !inventoryActive else { return }
        if isMock {
            inventoryActive = true
            await simulation?.start { [weak self] read in
                guard let self else { return }
                Task { await self.emit(.tagRead(read)) }
            }
            eventContinuation?.yield(.diagnosticLog("Inventory started (simulation, antennas: \(antennas))"))
            return
        }
        try requireVerifiedProtocol(command: "startInventory")
    }

    public func stopInventory() async throws {
        inventoryActive = false
        if isMock {
            await simulation?.stop()
            eventContinuation?.yield(.diagnosticLog("Inventory stopped"))
            return
        }
        try requireVerifiedProtocol(command: "stopInventory")
    }

    public func singleInventory(antennas: [Int] = [1]) async throws -> [TagRead] {
        if isMock {
            return await simulation?.singleScan() ?? []
        }
        try requireVerifiedProtocol(command: "singleInventory")
    }

    // MARK: - Tag memory (read is non-destructive; write/lock/kill require explicit confirmations)

    public func readMemory(epc: String, bank: MemoryBank, startAddress: Int, wordCount: Int,
                            accessPassword: String? = nil) async throws -> String {
        if isMock {
            // Deterministic-looking simulated payload so UI/export code has real
            // hex strings to work with.
            var hasher = Hasher()
            hasher.combine(epc); hasher.combine(bank); hasher.combine(startAddress)
            let seed = UInt32(bitPattern: Int32(truncatingIfNeeded: hasher.finalize()))
            var bytes: [UInt8] = []
            var s = seed
            for _ in 0..<(wordCount * 2) {
                s = s &* 1103515245 &+ 12345
                bytes.append(UInt8((s >> 16) & 0xFF))
            }
            return bytes.map { String(format: "%02X", $0) }.joined()
        }
        try requireVerifiedProtocol(command: "readMemory")
    }

    public func writeMemory(_ confirmation: WriteConfirmation) async throws {
        guard confirmation.userAcknowledged else {
            throw ReaderSDKError.invalidConfirmation("Write was not explicitly acknowledged by the caller/UI.")
        }
        if isMock {
            eventContinuation?.yield(.diagnosticLog("SIMULATED write: \(confirmation.dataHex) -> \(confirmation.bank) @\(confirmation.startAddress) on \(confirmation.targetEPC)"))
            return
        }
        try requireVerifiedProtocol(command: "writeMemory")
    }

    public func lockTag(_ confirmation: LockConfirmation) async throws {
        guard confirmation.userAcknowledged, confirmation.understandsIrreversibility else {
            throw ReaderSDKError.invalidConfirmation("Lock was not explicitly confirmed as irreversible by the caller/UI.")
        }
        if isMock {
            eventContinuation?.yield(.diagnosticLog("SIMULATED lock (\(confirmation.lockType)) on \(confirmation.targetEPC)"))
            return
        }
        try requireVerifiedProtocol(command: "lockTag")
    }

    public func killTag(_ confirmation: KillConfirmation) async throws {
        guard confirmation.userAcknowledged, confirmation.understandsIrreversibility else {
            throw ReaderSDKError.invalidConfirmation("Kill was not explicitly confirmed as irreversible by the caller/UI.")
        }
        if isMock {
            eventContinuation?.yield(.diagnosticLog("SIMULATED kill on \(confirmation.targetEPC)"))
            return
        }
        try requireVerifiedProtocol(command: "killTag")
    }

    // MARK: - Fault injection (mock only, for demos/tests)

    public func simulateMalformedPacket() async {
        guard let mock = transport as? MockTransport else { return }
        mock.simulateInboundBytes([0xA5, 0xFF, 0xFF, 0x00]) // truncated/garbage frame
        eventContinuation?.yield(.diagnosticLog("Injected malformed packet"))
    }

    public func simulateDisconnect() async {
        guard let mock = transport as? MockTransport else { return }
        mock.simulateDeviceRemoved()
    }

    // MARK: - Internals

    private func sendConfigCommand(_ command: ReaderCommand) async throws {
        if isMock {
            let bytes = try codec.encode(command)
            try await transport.write(bytes)
            eventContinuation?.yield(.diagnosticLog("TX \(bytes.count)B: \(command)"))
            return
        }
        try requireVerifiedProtocol(command: String(describing: command))
    }

    private func requireVerifiedProtocol(command: String) throws -> Never {
        let error = ProtocolError.unverifiedProtocol(command: command)
        eventContinuation?.yield(.error(error.description))
        throw ReaderSDKError.protocolLayer(error)
    }

    private func emit(_ event: ReaderEvent) {
        eventContinuation?.yield(event)
    }

    private func startForwardingTransportEvents() {
        forwardingTask?.cancel()
        let stream = transport.events
        forwardingTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .stateChanged(let s):
                    await self.emit(.connectionStateChanged(s))
                case .bytesReceived(let bytes):
                    await self.handleInboundBytes(bytes)
                case .deviceRemoved:
                    await self.emit(.error("Device removed"))
                case .error(let e):
                    await self.emit(.error(e.description))
                }
            }
        }
    }

    private func handleInboundBytes(_ bytes: [UInt8]) async {
        do {
            let frames = try await assembler.feed(bytes)
            for frame in frames {
                eventContinuation?.yield(.diagnosticLog("RX frame status=\(frame.statusCode) payload=\(frame.payload.count)B"))
            }
        } catch {
            eventContinuation?.yield(.error("\(error)"))
        }
    }

    private func describe(_ descriptor: TransportDescriptor) -> String {
        switch descriptor {
        case .serial(let path, let baud): return "serial \(path)@\(baud)"
        case .tcp(let host, let port): return "tcp \(host):\(port)"
        case .mock(let profile): return "mock(\(profile))"
        }
    }
}
