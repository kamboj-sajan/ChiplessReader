# API Reference — `ReaderSDK`

Import `ReaderSDK` (which re-exports the types you need day to day; `import
ReaderTransport` / `import ReaderProtocol` directly only if you need
lower-level types like `TransportDescriptor`).

## Connecting

```swift
import ReaderSDK
import ReaderTransport

let client = ReaderClient(descriptor: .mock())               // simulation
// let client = ReaderClient(descriptor: .serial(path: "/dev/cu.usbserial-1410", baudRate: 115_200))
// let client = ReaderClient(descriptor: .tcp(host: "192.168.1.100", port: 4001))

try await client.connect()          // throws ReaderSDKError.transport(...) on failure
defer { Task { await client.disconnect() } }
```

## Listening for events

```swift
Task {
    for await event in client.events {
        switch event {
        case .tagRead(let read):
            print(read.epc, read.rssi)
        case .connectionStateChanged(let state):
            print("state:", state)
        case .diagnosticLog(let line):
            print("[log]", line)
        case .error(let message):
            print("[error]", message)
        }
    }
}
```

## Inventory

```swift
try await client.startInventory(antennas: [1, 2])   // tags arrive via `events`
try await client.stopInventory()

let snapshot = try await client.singleInventory(antennas: [1])
```

## Configuration

```swift
try await client.setRegion(.na)
try await client.setRFPower(dBm: 30, antenna: nil)   // nil = all antennas
try await client.setGen2Configuration(Gen2Configuration(session: .s0, target: .a, qValue: nil))
try await client.setFilter(TagFilter(bank: .epc, startBit: 32, maskHex: "E280"))
try await client.setFilter(nil)                       // disable
```

## Tag memory — read (non-destructive)

```swift
let hex = try await client.readMemory(epc: "E280...", bank: .user,
                                        startAddress: 0, wordCount: 4,
                                        accessPassword: nil)
```

## Tag memory — write / lock / kill (destructive, gated)

These **require** an explicit confirmation value with `userAcknowledged: true`
(and `understandsIrreversibility: true` for lock/kill). There is no shortcut —
this is deliberate; see `Documentation/LIMITATIONS.md` for why.

```swift
try await client.writeMemory(WriteConfirmation(
    targetEPC: "E280...", bank: .user, startAddress: 0, dataHex: "DEADBEEF",
    userAcknowledged: true))

try await client.lockTag(LockConfirmation(
    targetEPC: "E280...", bank: .epc, lockType: .temporaryLock,
    accessPassword: "00000000", userAcknowledged: true, understandsIrreversibility: true))

try await client.killTag(KillConfirmation(
    targetEPC: "E280...", killPassword: "00000000",
    userAcknowledged: true, understandsIrreversibility: true))
```

## Reader info

```swift
let info = try await client.readerInfo()
// info.mainboardType, .moduleType, .hardwareVersion, .softwareVersion, .antennaCount
```

## Errors

All throwing methods throw `ReaderSDKError`:

| Case | Meaning |
|---|---|
| `.transport(TransportError)` | Connection/write/timeout failure at the byte-pipe level |
| `.protocolLayer(ProtocolError)` | Framing/checksum problem, or `.unverifiedProtocol` for real hardware today |
| `.notConnected` | Called before `connect()` |
| `.invalidConfirmation(String)` | A write/lock/kill confirmation wasn't fully acknowledged |
| `.unsupported(String)` | Operation not supported by the current codec |

## Real hardware today

`connect()`/`disconnect()` work over serial/TCP. Every other method throws
`.protocolLayer(.unverifiedProtocol(command:))` for non-mock transports until
`AltraWavesCodec` is implemented — see `Documentation/PROTOCOL.md`.

## Thread safety

`ReaderClient` is a Swift `actor`. Call it from any task/thread; calls are
serialized automatically. `InventorySession` is `@MainActor` (it backs SwiftUI
`@Published` state) — ingest tag reads on the main actor, as the app and CLI
examples both do.

## Semantic versioning

This package has not been tagged yet. Once real-hardware support lands, tag
`1.0.0`; treat the pre-1.0 API as subject to change without notice, per SemVer
convention for `0.x` releases.
