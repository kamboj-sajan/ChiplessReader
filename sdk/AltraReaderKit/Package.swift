// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AltraReaderKit",
    platforms: [
        .macOS(.v14) // Sonoma+. ContentUnavailableView, NavigationSplitView, and Table all need macOS 14.
    ],
    products: [
        .library(name: "ReaderTransport", targets: ["ReaderTransport"]),
        .library(name: "ReaderProtocol", targets: ["ReaderProtocol"]),
        .library(name: "ReaderSDK", targets: ["ReaderSDK"]),
        .executable(name: "readercli", targets: ["ReaderCLI"]),
        .executable(name: "ReaderManagerApp", targets: ["ReaderManagerApp"]),

        // Chipless RFID reader (STM32 / virtual reader) - see Documentation/CHIPLESS.md
        .library(name: "ChiplessKit", targets: ["ChiplessKit"]),
        .executable(name: "chiplesscli", targets: ["ChiplessCLI"]),
        .executable(name: "ChiplessReaderApp", targets: ["ChiplessReaderApp"])
    ],
    dependencies: [],
    targets: [
        // MARK: Transport layer — moves bytes only, knows nothing about reader semantics.
        .target(
            name: "ReaderTransport",
            dependencies: []
        ),
        .testTarget(
            name: "ReaderTransportTests",
            dependencies: ["ReaderTransport"]
        ),

        // MARK: Protocol layer — framing, checksums, encode/decode. No transport, no UI.
        .target(
            name: "ReaderProtocol",
            dependencies: ["ReaderTransport"]
        ),
        .testTarget(
            name: "ReaderProtocolTests",
            dependencies: ["ReaderProtocol"]
        ),

        // MARK: Public SDK — the only layer apps should depend on.
        .target(
            name: "ReaderSDK",
            dependencies: ["ReaderTransport", "ReaderProtocol"]
        ),
        .testTarget(
            name: "ReaderSDKTests",
            dependencies: ["ReaderSDK", "ReaderTransport", "ReaderProtocol"]
        ),

        // MARK: CLI example
        .executableTarget(
            name: "ReaderCLI",
            dependencies: ["ReaderSDK", "ReaderTransport"]
        ),

        // MARK: macOS SwiftUI application
        .executableTarget(
            name: "ReaderManagerApp",
            dependencies: ["ReaderSDK", "ReaderTransport", "ReaderProtocol"]
        ),

        // MARK: Chipless reader SDK - self-contained (Foundation only), talks to the STM32
        // firmware or the virtual reader over a serial port.
        .target(
            name: "ChiplessKit",
            dependencies: []
        ),
        .testTarget(
            name: "ChiplessKitTests",
            dependencies: ["ChiplessKit"]
        ),
        .executableTarget(
            name: "ChiplessCLI",
            dependencies: ["ChiplessKit"]
        ),
        .executableTarget(
            name: "ChiplessReaderApp",
            dependencies: ["ChiplessKit"]
        )
    ]
)
