# Architecture

AltraReaderKit is a Swift Package with four layers. Each layer only knows about
the one below it; nothing skips a layer.

```
Sources/
  ReaderTransport/   Byte pipe only. No reader semantics.
  ReaderProtocol/     Framing, checksums, encode/decode. No transport, no UI.
  ReaderSDK/          Public API + application-layer bookkeeping (dedup, export).
  ReaderCLI/           Example console client.
  ReaderManagerApp/   SwiftUI macOS app.
Tests/                 One test target per library target.
Documentation/         This file and friends.
```

## 1. Transport (`ReaderTransport`)

`Transport` is a small protocol: `connect`, `disconnect`, `write`, and an
`AsyncStream<TransportEvent>` for inbound bytes / state changes / errors. Three
conformers:

- **`MockTransport`** — fully in-memory, used by simulation mode and by
  `ReaderProtocolTests`/`ReaderTransportTests`. Supports fault injection
  (timeout, malformed bytes, forced disconnect).
- **`SerialTransport`** — macOS `/dev/cu.*` via POSIX `termios`, non-blocking
  reads via `DispatchSourceRead` (so a device unplug surfaces as an EOF event
  rather than a hang).
- **`TCPTransport`** — `Network.framework`, for the network-port connection mode
  the reference app's manual describes (default `192.168.1.100`).

None of these three know what a "tag" or a "region" is. They move bytes.

## 2. Protocol (`ReaderProtocol`)

`PacketCodec` is the seam between "abstract commands" (`ReaderCommand` — an enum:
`.getReaderInfo`, `.startInventory`, `.readMemory`, etc.) and wire bytes.
`PacketAssembler` is an `actor` that buffers streamed bytes and repeatedly asks
the codec "is there a complete frame at the front yet?" — handling partial
frames, multiple frames in one read, and resynchronization after a malformed
byte (drop one byte, try again, rather than wedging forever).

Two codecs exist today:

- **`ReferenceCodec`** — a fully-specified, documented framing
  (`0xA5 | LEN | CMD | STATUS | PAYLOAD | CRC16`) used **only** for mock mode and
  for exercising the assembler's buffering/malformed-packet logic in tests. It is
  explicitly *not* the real Altra Waves protocol.
- **`AltraWavesCodec`** — the placeholder for the real module's wire protocol.
  Every method throws `ProtocolError.unverifiedProtocol` today. See
  `PROTOCOL.md` for exactly how to unblock this.

## 3. SDK (`ReaderSDK`)

`ReaderClient` is the single public entry point — a Swift `actor`, so every call
is automatically serialized and safe to call from multiple tasks. It:

- Picks the right `Transport` + `PacketCodec` pair from a `TransportDescriptor`
  (`.mock`, `.serial(path:baudRate:)`, `.tcp(host:port:)`).
- Exposes reader operations as `async throws` methods returning strongly-typed
  models (`ReaderInfo`, `TagRead`, `Gen2Configuration`, ...).
- Gates destructive operations (`writeMemory`, `lockTag`, `killTag`) behind
  explicit confirmation value types (`WriteConfirmation`, `LockConfirmation`,
  `KillConfirmation`) that must be constructed with `userAcknowledged: true` (and,
  for lock/kill, `understandsIrreversibility: true`) or the call is rejected
  before touching the transport at all.
- Publishes everything (state changes, tag reads, diagnostic log lines, errors)
  through one `AsyncStream<ReaderEvent>`.

`InventorySession` (also in this target, playing the role the spec called the
"application/service layer") consumes that event stream's tag reads and
maintains the deduplicated table the UI binds to — seen count, first/last seen,
last RSSI — matching the reference app's "unique by bank data" default.
`InventoryExport` turns that table into CSV or JSON.

> **Simplification made for scope:** the spec described "SDK" and
> "application/service layer" as two separate layers. They're combined into one
> `ReaderSDK` target here to keep the package graph simple; `InventorySession`
> and `InventoryExport` are intentionally kept in their own files so splitting
> them into a fifth target later is a low-risk refactor.

## 4. Applications

- **`ReaderCLI`** (`readercli`) — `info` and `inventory` subcommands, works
  against `--mock`, `--serial`, or `--tcp`.
- **`ReaderManagerApp`** — SwiftUI, `NavigationSplitView` sidebar with five
  screens (Connect, Inventory, Tag Access, Configuration, Logs). Fully usable in
  simulation mode; real-hardware screens show the "blocked pending protocol
  verification" state honestly rather than pretending to work.

## Why real hardware commands are blocked, structurally

`ReaderClient` checks `isMock` before doing any protocol work. For a real
transport, every command-issuing method calls `requireVerifiedProtocol(command:)`,
which always throws `ReaderSDKError.protocolLayer(.unverifiedProtocol)` — by
construction, not by omission. `connect()`/`disconnect()` are the only two
operations that touch a real transport today, because they're pure transport
operations with no wire-format dependency. This means:

- The app is honest: it can open a serial port or TCP socket to your reader and
  show that the transport connected, without pretending it can talk to it yet.
- Wiring in `AltraWavesCodec` later is additive — implement `encode`/`decodeFrame`
  for real, delete the `isMock` branches' fallback throws, and everything above
  (`ReaderClient` callers, the app, the CLI) keeps working unchanged.

## Concurrency & error handling

- `ReaderClient`, `PacketAssembler` are actors — no manual locking needed at
  their public boundary.
- `MockTransport`/`SerialTransport`/`TCPTransport` use `NSLock` internally around
  a small amount of mutable state (`@unchecked Sendable`, documented at each
  declaration) because they bridge to callback-based system APIs
  (`DispatchSourceRead`, `NWConnection`) that predate Swift concurrency.
- Every thrown error is a typed enum (`TransportError`, `ProtocolError`,
  `ReaderSDKError`) with a `description` — nothing surfaces as a bare `String`
  or `NSError` from the SDK's public API.
