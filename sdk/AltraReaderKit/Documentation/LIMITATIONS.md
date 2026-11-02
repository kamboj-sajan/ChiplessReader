# Known Limitations

1. **No real-hardware protocol support yet.** This is the big one — see
   `PROTOCOL.md`. Every reader *command* (info, inventory, config, memory
   read/write, lock, kill) throws `.unverifiedProtocol` for serial/TCP
   transports. Only `connect()`/`disconnect()` are functional against real
   hardware today.
2. **Nothing here has been compiled.** Written without access to a Swift
   toolchain or macOS SDK. Treat the first `swift build` on your Mac as the real
   first compile — see `BUILD.md`'s "If it doesn't build" section for the likely
   small fixes.
3. **TCP port is a guess.** `TCPTransport` defaults to port 4001; the supplied
   manual documents the default IP but not the port. Confirm before relying on
   it.
4. **GPI/GPO peripherals, firmware update, and VSWR/standing-wave tools are not
   implemented.** They're in the feature matrix as "Not started" — the
   reference app supports them, but they were deprioritized behind core
   inventory/tag-access given your handwritten notes' apparent priorities
   (inventory management, data analysis) and the one-run scope. Firmware update
   in particular should not be implemented without your explicit sign-off, given
   how easily a bad firmware push bricks a reader.
5. **Wi-Fi/Bluetooth reader connectivity is unimplemented.** The DLL metadata
   shows `WifiSetting`/`ReaderIPInfo_Ex` types suggesting the reference hardware
   supports Wi-Fi configuration; nothing in the supplied materials showed enough
   to build this safely, and it wasn't a stated requirement beyond the
   handwritten note.
6. **Single-reader only.** `ReaderClient` models one reader per instance. The
   handwritten note mentions "Multiple ... Tags", which likely means many tags
   per reader (already supported) rather than many readers — but if you do need
   a fleet view, it's an additive change (one `ReaderClient` per reader, no
   architecture change needed).
7. **App packaging/signing not done.** `swift run ReaderManagerApp` launches a
   dev build; there's no `.app` bundle, no code signing, no notarization yet
   (not meaningful to do before real functionality exists — see `BUILD.md`).
8. **Mock tag-memory reads are deterministic pseudo-data, not meaningful
   content.** `readMemory` in mock mode returns hash-derived bytes so the UI has
   real-looking hex strings to render/export, not anything resembling actual EPC
   Gen2 memory contents.
9. **No firmware/region-database validation.** `RFRegion` is a fixed enum of
   common regions; the actual set of regions/frequency tables your module
   supports is unverified (see feature matrix).
10. **No integration-test harness against real hardware yet** — by necessity,
    since the protocol isn't verified. `HARDWARE_VALIDATION_CHECKLIST.md`
    describes the manual process for when it is.
