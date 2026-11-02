import Foundation

public enum InventoryExport {
    public static func csv(_ rows: [InventoryRow]) -> String {
        let formatter = ISO8601DateFormatter()
        var lines = ["epc,tid,antenna,last_rssi,read_count,first_seen,last_seen"]
        for row in rows {
            let fields = [
                row.epc,
                row.tid ?? "",
                String(row.antenna),
                String(row.lastRSSI),
                String(row.readCount),
                formatter.string(from: row.firstSeen),
                formatter.string(from: row.lastSeen)
            ]
            lines.append(fields.map(csvEscape).joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    public static func json(_ rows: [InventoryRow]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(rows)
    }

    private static func csvEscape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
