import Foundation
import ReaderTransport
import ReaderSDK

// Minimal hand-rolled arg parsing to avoid an extra dependency for the example.
// Usage:
//   readercli inventory --mock [--seconds 5]
//   readercli inventory --serial /dev/cu.usbserial-XXXX --baud 115200
//   readercli inventory --tcp 192.168.1.100 --port 4001
//   readercli info --mock

func printUsage() {
    print("""
    readercli — Altra Waves reader SDK example

    Subcommands:
      info      Print reader info
      inventory Run inventory and print tags as they're seen

    Connection (choose one):
      --mock                       Use the built-in simulated reader (default)
      --serial <path> [--baud N]   Connect over a macOS serial device
      --tcp <host> [--port N]      Connect over TCP/IP

    Options:
      --seconds N   Stop inventory after N seconds (default: run until Ctrl-C)
      --csv <path>  Export the deduplicated table to CSV on exit
      --json <path> Export the deduplicated table to JSON on exit
    """)
}

func parseDescriptor(_ args: [String]) -> TransportDescriptor {
    if let i = args.firstIndex(of: "--serial"), i + 1 < args.count {
        let path = args[i + 1]
        var baud = 115_200
        if let b = args.firstIndex(of: "--baud"), b + 1 < args.count, let v = Int(args[b + 1]) { baud = v }
        return .serial(path: path, baudRate: baud)
    }
    if let i = args.firstIndex(of: "--tcp"), i + 1 < args.count {
        let host = args[i + 1]
        var port: UInt16 = 4001
        if let p = args.firstIndex(of: "--port"), p + 1 < args.count, let v = UInt16(args[p + 1]) { port = v }
        return .tcp(host: host, port: port)
    }
    return .mock()
}

let args = Array(CommandLine.arguments.dropFirst())
guard let subcommand = args.first else {
    printUsage()
    exit(64)
}

let descriptor = parseDescriptor(Array(args.dropFirst()))

func runInfo() async {
    let client = ReaderClient(descriptor: descriptor)
    do {
        try await client.connect()
        let info = try await client.readerInfo()
        print("Mainboard: \(info.mainboardType)")
        print("Module:    \(info.moduleType)")
        print("HW:        \(info.hardwareVersion)")
        print("SW:        \(info.softwareVersion)")
        print("Antennas:  \(info.antennaCount)")
        await client.disconnect()
    } catch {
        FileHandle.standardError.write("Error: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

func runInventory() async {
    let client = ReaderClient(descriptor: descriptor)
    let session = await MainActor.run { InventorySession() }

    var seconds: Double?
    if let i = args.firstIndex(of: "--seconds"), i + 1 < args.count, let v = Double(args[i + 1]) {
        seconds = v
    }
    var csvPath: String?
    if let i = args.firstIndex(of: "--csv"), i + 1 < args.count { csvPath = args[i + 1] }
    var jsonPath: String?
    if let i = args.firstIndex(of: "--json"), i + 1 < args.count { jsonPath = args[i + 1] }

    do {
        try await client.connect()

        let listenTask = Task {
            for await event in client.events {
                switch event {
                case .tagRead(let read):
                    await MainActor.run { session.ingest(read) }
                    print("EPC=\(read.epc) ANT=\(read.antenna) RSSI=\(read.rssi)")
                case .connectionStateChanged(let s):
                    print("[state] \(s)")
                case .error(let e):
                    print("[error] \(e)")
                case .diagnosticLog(let msg):
                    print("[log] \(msg)")
                }
            }
        }

        try await client.startInventory()

        if let seconds {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        } else {
            print("Press Ctrl-C to stop.")
            try await Task.sleep(nanoseconds: 3_600 * 1_000_000_000)
        }

        try await client.stopInventory()
        listenTask.cancel()
        await client.disconnect()

        let rows = await MainActor.run { session.rows }
        print("\n--- \(rows.count) unique tags, \(await MainActor.run { session.totalReads }) total reads ---")
        for row in rows.sorted(by: { $0.readCount > $1.readCount }) {
            print("\(row.epc)  reads=\(row.readCount)  rssi=\(row.lastRSSI)  ant=\(row.antenna)")
        }

        if let csvPath {
            try InventoryExport.csv(rows).write(toFile: csvPath, atomically: true, encoding: .utf8)
            print("Wrote \(csvPath)")
        }
        if let jsonPath {
            let data = try InventoryExport.json(rows)
            try data.write(to: URL(fileURLWithPath: jsonPath))
            print("Wrote \(jsonPath)")
        }
    } catch {
        FileHandle.standardError.write("Error: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

switch subcommand {
case "info":
    await runInfo()
case "inventory":
    await runInventory()
default:
    printUsage()
    exit(64)
}
