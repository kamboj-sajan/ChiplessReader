# PROJECT_TODO — AltraReaderKit (macOS SDK + App for Altra Waves UHF Reader)

Legend: `[x]` Completed · `[~]` In progress · `[ ]` Pending · `[!]` Blocked

## Phase 1 — Inspection
- [x] Inventory `AWSReaderUI_v2.zip` (WPF/.NET C# reference app, source-available UI, compiled `ModuleAPI.dll`)
- [x] Identify communication transport: Serial (COM/`/dev/cu.*`) and TCP/IP (default `192.168.1.100:...`), selectable per-connection
- [x] Identify SDK lineage: `ModuleAPI.dll` metadata shows `ThingMagic.*` / `ModuleTech.*` namespaces — this is a private-labeled build on top of the **ThingMagic Mercury API** lineage, layered over an **Impinj R2000**-class reader chip (R2000 command classes present in metadata)
- [x] Extract public API surface (parameter names, method shapes) from the **source-visible** WPF code (`ConnectView.xaml.cs`, `InventoryView.xaml.cs`, etc.) — see `Documentation/PROTOCOL.md`
- [!] Byte-level wire protocol (framing, opcodes, checksum) — **not available** from lawful non-destructive inspection. The C# source only shows calls like `Reader.ParamGet("RfPowerMax")`; the actual serial/TCP byte encoding lives inside the compiled `ModuleAPI.dll` and was **not decompiled** (would mean extracting proprietary implementation, not just its interface — out of scope per instructions). Unblock path documented in `Documentation/PROTOCOL.md`.
- [x] Read `ALTRAWAVES_UHF_Reader_Utility_Document_V1_0.pdf` (end-user manual for the Windows "RFID Manager" app — describes UI/workflow, not wire bytes)
- [x] Read handwritten planning note (multi-tag reader, SDK/host boundary, wifi/BLE/wireless, RF sweep params, inventory/data-analysis app) — informed feature priorities, no new protocol facts
- [x] Compare reference reader vs. personal module — **no personal reader documentation was supplied in this conversation**, so the SDK targets the same parameter surface as the reference app behind a transport-agnostic, protocol-pluggable design
- [x] Identify macOS-incompatible pieces: entire WPF/.NET-Framework UI, `Microsoft.Office.Interop.Excel` (Windows COM), `System.Windows.Forms`/WPF, hard-coded `COMx` naming, Windows-only serial driver assumptions
- [x] Finalize macOS stack: Swift 5.9+, Swift Package Manager, SwiftUI, `Network.framework` (TCP), POSIX `termios` over `/dev/cu.*` (serial)

## Phase 2 — Architecture & Scaffolding
- [x] Design layered architecture (Transport / Protocol / SDK / App)
- [x] Create Swift Package project structure
- [x] Feature comparison matrix (`Documentation/FEATURE_MATRIX.md`)

## Phase 3 — Implementation
- [x] Transport protocol/interface (`ReaderTransport`)
- [x] Serial transport (macOS `/dev/cu.*`, termios, async read loop)
- [x] TCP transport (`Network.framework`)
- [x] Mock transport + simulation engine (tag generator, error/timeout/malformed-packet injection, disconnect simulation)
- [x] Protocol layer scaffolding: packet buffering, framing abstraction, checksum abstraction
- [!] Real Altra Waves wire-protocol codec — **blocked**, see `Documentation/PROTOCOL.md` for the exact unblock steps
- [x] Reference/mock codec (clearly labeled non-hardware-verified) so framing, buffering, and malformed-packet logic can be built and tested end-to-end today
- [x] Public SDK surface (`ReaderSDK`): discovery, connect/disconnect, reader/firmware info, region/power/antenna config, start/stop/single inventory, tag memory read, filters, Gen2 params, events, structured errors
- [x] Tag memory **write/lock/kill** gated behind explicit confirmation types (never auto-executed)
- [x] CLI example (`readercli`)
- [x] macOS SwiftUI app (Sidebar, Connect, Inventory dashboard, Config, Tag Access, Logs) — runs fully in simulation mode
- [x] CSV / JSON export
- [x] Diagnostics / raw protocol logging pane

## Phase 4 — Testing
- [x] Packet buffering / partial-packet / multi-packet-in-buffer unit tests (against the reference codec)
- [x] Malformed-packet & checksum-failure tests
- [x] Mock transport tests (timeout, disconnect, error injection)
- [x] SDK API tests against `MockTransport`
- [!] Real-hardware integration tests — blocked (no hardware/protocol access in this environment); manual checklist provided instead

## Phase 5 — Documentation & Handoff
- [x] `Documentation/ARCHITECTURE.md`
- [x] `Documentation/FEATURE_MATRIX.md`
- [x] `Documentation/PROTOCOL.md` (what's verified, what's blocked, exact unblock steps)
- [x] `Documentation/API.md`
- [x] `Documentation/BUILD.md`
- [x] `Documentation/USER_GUIDE.md`
- [x] `Documentation/LIMITATIONS.md`
- [x] `Documentation/HARDWARE_VALIDATION_CHECKLIST.md`
- [x] Final handoff summary (chat response)

## Known blockers (see `Documentation/PROTOCOL.md` for detail)
1. **Wire protocol bytes are unverified.** No packet captures, no `.h`/`.proto`/protocol spec for the *your* reader module were supplied — only a compiled DLL and a UI manual for a *different, Windows-only* demo app.
2. **No dev environment for this run.** This container is Linux with no Swift toolchain and no macOS SDK, so nothing here was compiled or executed as a `.app`; build/test must happen on your Mac (exact commands in `Documentation/BUILD.md`).
