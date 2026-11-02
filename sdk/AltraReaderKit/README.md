# AltraReaderKit

A macOS Swift Package (SDK + SwiftUI app + CLI) for the Altra Waves UHF RFID
reader module, built using the supplied Windows reference application as a
functional reference — not a reskin of it.

> **Chipless RFID reader:** this package also contains `ChiplessKit`, `chiplesscli` and
> `ChiplessReaderApp` for the STM32-based chipless reader. See `Documentation/CHIPLESS.md`
> and the demo guide in the repository root `README.md`.

**Start here:**
- `PROJECT_TODO.md` — what's done, in progress, or blocked, and why.
- `Documentation/PROTOCOL.md` — the most important doc: what's verified about
  the reader protocol, what isn't, and exactly how to unblock real-hardware
  support.
- `Documentation/BUILD.md` — build/test/run commands (requires a Mac; this
  project was written without one in the loop — see that doc).
- `Documentation/USER_GUIDE.md` — using the app, starting in simulation mode.
- `Documentation/ARCHITECTURE.md` — how the four layers fit together.
- `Documentation/FEATURE_MATRIX.md` — reference-app feature vs. this SDK's
  status.
- `Documentation/LIMITATIONS.md` — the honest list.
- `Documentation/HARDWARE_VALIDATION_CHECKLIST.md` — for once real hardware
  support lands.
- `Documentation/API.md` — `ReaderSDK` usage reference.

**Quick start (simulation mode, no hardware needed):**
```bash
swift run ReaderManagerApp        # SwiftUI app
swift run readercli inventory --mock --seconds 5   # CLI
swift test                        # protocol/transport/SDK tests
```
