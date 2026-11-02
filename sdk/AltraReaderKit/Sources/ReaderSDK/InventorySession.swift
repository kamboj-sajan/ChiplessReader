import Foundation
import Combine
import ReaderProtocol

/// One row of the deduplicated inventory table (what the app's tag grid binds to).
public struct InventoryRow: Sendable, Identifiable, Equatable, Codable {
    public var id: String { epc }
    public var epc: String
    public var tid: String?
    public var antenna: Int
    public var lastRSSI: Int
    public var readCount: Int
    public var firstSeen: Date
    public var lastSeen: Date
}

/// Application-layer session state: consumes raw `TagRead` events from a
/// `ReaderClient` and maintains the deduplicated table the UI displays, matching
/// the reference app's "unique by bank data" behavior (its default; "unique by
/// antenna" is the alternative it also offers).
///
/// This is deliberately a plain (non-actor) value-ish class so SwiftUI can hold it
/// as an `@Observable`/`ObservableObject` without extra hops; it's expected to be
/// driven from the main actor.
@MainActor
public final class InventorySession: ObservableObject {
    public enum UniqueBy { case epc, epcAndAntenna }

    @Published public private(set) var rows: [InventoryRow] = []
    @Published public private(set) var totalReads: Int = 0

    private var index: [String: Int] = [:] // key -> rows index
    private let uniqueBy: UniqueBy

    public init(uniqueBy: UniqueBy = .epc) {
        self.uniqueBy = uniqueBy
    }

    public func ingest(_ read: TagRead) {
        totalReads += 1
        let key = uniqueBy == .epc ? read.epc : "\(read.epc)#\(read.antenna)"
        if let idx = index[key] {
            rows[idx].lastRSSI = read.rssi
            rows[idx].readCount += 1
            rows[idx].lastSeen = read.timestamp
            if let tid = read.tid { rows[idx].tid = tid }
        } else {
            let row = InventoryRow(epc: read.epc, tid: read.tid, antenna: read.antenna,
                                    lastRSSI: read.rssi, readCount: 1,
                                    firstSeen: read.timestamp, lastSeen: read.timestamp)
            index[key] = rows.count
            rows.append(row)
        }
    }

    public func clear() {
        rows.removeAll()
        index.removeAll()
        totalReads = 0
    }
}
