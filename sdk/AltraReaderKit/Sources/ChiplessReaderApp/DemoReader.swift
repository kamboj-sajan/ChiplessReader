import Foundation

/// Demo Mode: starts the reader firmware compiled for the Mac (`chipless-vreader`, carried inside the
/// app) and hands back the serial port it creates. Everything above that port behaves as it does with
/// the board: same frames, same firmware, only the RF signal is simulated.
final class DemoReader {
    private var process: Process?
    private var output: Pipe?

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Chipless Reader", isDirectory: true)
    }

    /// Inside the .app next to the main program; for `swift run`, the Makefile's build folder.
    private static func helperURL() -> URL? {
        if let u = Bundle.main.url(forAuxiliaryExecutable: "chipless-vreader") { return u }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("firmware/host/build/chipless-vreader")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    /// Returns the path of the serial port once it exists. `onOutput` receives the firmware's console.
    func start(onOutput: @escaping @Sendable (String) -> Void) throws -> String {
        guard let helper = DemoReader.helperURL() else {
            throw NSError(domain: "ChiplessReader", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "The demo reader is missing from this copy of the app."])
        }
        let dir = DemoReader.supportDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let port = dir.appendingPathComponent("demo-port").path
        try? FileManager.default.removeItem(atPath: port)

        let p = Process()
        p.executableURL = helper
        p.arguments = ["--link", port, "--nv", dir.appendingPathComponent("demo-reader.nv").path, "--exit-with-parent", "-v", "0"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            for line in s.split(whereSeparator: \.isNewline) { onOutput(String(line)) }
        }
        try p.run()
        process = p
        output = pipe

        for _ in 0..<100 {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: port)) != nil { return port }
            usleep(20_000)
        }
        stop()
        throw NSError(domain: "ChiplessReader", code: 2, userInfo: [NSLocalizedDescriptionKey: "The demo reader did not start."])
    }

    func stop() {
        output?.fileHandleForReading.readabilityHandler = nil
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        output = nil
    }
}
