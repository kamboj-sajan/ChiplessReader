import Foundation
import ReaderProtocol

/// Drives simulated tag traffic for `ReaderClient` when constructed with
/// `TransportDescriptor.mock`. Generates a small fixed population of tags so
/// "duplicate sightings" and seen-count behavior are exercised realistically,
/// with configurable noise (RSSI jitter) and rate.
public actor SimulationEngine {
    public struct Configuration: Sendable {
        public var tagCount: Int
        public var antennaCount: Int
        public var readsPerSecond: Double
        public var rssiRange: ClosedRange<Int>

        public init(tagCount: Int = 12, antennaCount: Int = 4, readsPerSecond: Double = 8, rssiRange: ClosedRange<Int> = -70...(-30)) {
            self.tagCount = tagCount
            self.antennaCount = antennaCount
            self.readsPerSecond = readsPerSecond
            self.rssiRange = rssiRange
        }
    }

    private var task: Task<Void, Never>?
    private let config: Configuration
    private var population: [String] = []

    public init(configuration: Configuration = Configuration()) {
        self.config = configuration
        self.population = (0..<configuration.tagCount).map { i in
            String(format: "E280%08X%08X", UInt32.random(in: 0...UInt32.max), UInt32(i))
        }
    }

    /// Starts emitting simulated reads to `onRead` until `stop()` is called.
    public func start(onRead: @escaping @Sendable (TagRead) -> Void) {
        stopInternal()
        let interval = 1.0 / max(config.readsPerSecond, 0.1)
        let population = self.population
        let antennaCount = self.config.antennaCount
        let rssiRange = self.config.rssiRange
        task = Task {
            while !Task.isCancelled {
                let epc = population.randomElement() ?? population[0]
                let read = TagRead(
                    epc: epc,
                    tid: nil,
                    antenna: Int.random(in: 1...max(antennaCount, 1)),
                    rssi: Int.random(in: rssiRange),
                    frequencyKHz: [902_750, 915_250, 920_625].randomElement(),
                    phaseDegrees: Int.random(in: 0...359)
                )
                onRead(read)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    public func stop() {
        stopInternal()
    }

    /// One-shot inventory: return a snapshot of currently "visible" tags rather
    /// than starting the continuous stream.
    public func singleScan() -> [TagRead] {
        population.map { epc in
            TagRead(epc: epc, antenna: Int.random(in: 1...max(config.antennaCount, 1)),
                     rssi: Int.random(in: config.rssiRange))
        }
    }

    private func stopInternal() {
        task?.cancel()
        task = nil
    }
}
