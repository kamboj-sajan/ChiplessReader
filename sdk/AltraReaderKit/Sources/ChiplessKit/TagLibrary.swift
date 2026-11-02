import Foundation

/// A known tag: the name you give a fabricated tag and the ID its resonators encode.
public struct KnownTag: Codable, Sendable, Equatable {
    public var name: String
    public var id: UInt32
    public init(name: String, id: UInt32) { self.name = name; self.id = id }
}

/// Maps decoded IDs to names on the Mac side, from a hand-edited JSON file. The reader's own database
/// (`ChiplessReader.databaseEntries()`) is what identifies a tag during a read; use this to name IDs
/// without a reader attached.
public struct TagLibrary: Codable, Sendable {
    public var tags: [KnownTag]

    public init(tags: [KnownTag] = []) { self.tags = tags }

    /// Exact match first; otherwise the closest tag within `maxBitErrors` differing bits.
    public func match(_ id: UInt32, maxBitErrors: Int = 0) -> (tag: KnownTag, bitErrors: Int)? {
        var best: (KnownTag, Int)?
        for t in tags {
            let d = (t.id ^ id).nonzeroBitCount
            if d <= maxBitErrors, best == nil || d < best!.1 { best = (t, d) }
        }
        return best.map { (tag: $0.0, bitErrors: $0.1) }
    }

    public static func load(from url: URL) throws -> TagLibrary {
        try JSONDecoder().decode(TagLibrary.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url)
    }

    /// The tags built into the simulated front-end.
    public static func from(_ sim: SimulationState) -> TagLibrary {
        TagLibrary(tags: sim.tags.map { KnownTag(name: $0.name, id: $0.code) })
    }
}
