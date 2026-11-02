# Build, Test, and Run

**Requires a Mac.** Nothing in this repository was compiled in the environment
that generated it (Linux container, no Swift toolchain, no macOS SDK) — every
command below needs to be run on your machine to actually verify it. If
something doesn't build as-is, that's expected until you've done this first
pass; see the "If it doesn't build" section at the bottom.

## Prerequisites

- macOS 14 (Sonoma) or later.
- Xcode 15+ **or** the standalone Swift toolchain (Xcode Command Line Tools are
  enough: `xcode-select --install`). Full Xcode is only needed if you want the
  Xcode GUI/debugger; `swift build` works from the command line either way.
- For serial hardware: the USB-serial driver for your reader's chipset (FTDI,
  Prolific, or CH340-class — see the manual's driver link,
  `https://www.ftdichip.com/Drivers/D2XX.htm`, if applicable to your module).

## Build everything

```bash
cd AltraReaderKit
swift build
```

## Run the tests

```bash
swift test
```

Expected today: all `ReaderProtocolTests`, `ReaderTransportTests`, and
`ReaderSDKTests` pass using mock/reference-codec paths — nothing requires
hardware. (`ReaderClientMockTests.testRealTransportCommandsAreBlockedUntilProtocolIsVerified`
intentionally verifies the *blocked* behavior for real transports.)

## Run the CLI

```bash
swift run readercli info --mock
swift run readercli inventory --mock --seconds 5
swift run readercli inventory --mock --seconds 5 --csv out.csv --json out.json

# Once you have hardware and a working transport:
swift run readercli inventory --serial /dev/cu.usbserial-XXXX --baud 115200
swift run readercli inventory --tcp 192.168.1.100 --port 4001
```

## Run the macOS app

```bash
swift run ReaderManagerApp
```

This launches a windowed SwiftUI app via `swift run` — no `.xcodeproj` needed
for development. It defaults to Simulation mode; switch to Serial/Network on the
Connect screen once your transport is verified.

### Packaging as a distributable `.app` (later)

`swift run` is great for development but doesn't produce a signed, notarized,
double-clickable `.app` bundle. When you're ready to distribute:
1. Open the package in Xcode (`File > Open` → select the folder — Xcode reads
   `Package.swift` directly) and use `Product > Archive`, **or**
2. Use `swift build -c release` plus a hand-rolled `.app` bundle structure
   (`Info.plist`, `Contents/MacOS/`, icon) and `codesign`/`xcrun notarytool`.

Either path needs an Apple Developer ID for code signing/notarization — out of
scope for this pass since there's nothing to sign until real-hardware support
exists.

## If it doesn't build

This was written without a compiler in the loop, so treat the first
`swift build` as the real first compile. Likely categories of issues, roughly
most-to-least likely:
- **SwiftUI API availability** — `ContentUnavailableView` specifically needs
  macOS 14+, which is why `Package.swift` targets `.v14`. If you lower the
  deployment target, that view (and possibly others) will need `@available`
  guards or simpler fallbacks.
- **Minor type-inference issues** in `SerialTransport`'s `termios` field access
  (`c_cc.16`/`c_cc.17` — correct indices for macOS/BSD `termios`, but the
  Swift-C bridging for that struct is a common source of small compiler
  complaints; if so, isolate that block and fix the specific diagnostic).
- **Actor-isolation warnings** around `MockTransport`/`SerialTransport`/
  `TCPTransport`'s `@unchecked Sendable` + `NSLock` pattern — functionally
  correct but Swift's strict-concurrency checking (if enabled) may want more
  annotations; add `@preconcurrency` or narrow isolation as needed.

None of these are structural — they're the kind of thing a first `swift build`
on real hardware/toolchain routinely surfaces. Fix forward and this doc doesn't
need to change.
