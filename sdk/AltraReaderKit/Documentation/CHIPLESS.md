# ChiplessKit: the chipless reader SDK

`ChiplessKit` is a separate library in this package. It talks to the chipless RFID reader: the STM32F4DISCOVERY firmware, or the virtual reader built from the same firmware. It depends only on Foundation, so it builds on macOS and Linux.

| Target | What it is | Run |
|---|---|---|
| `ChiplessKit` | The SDK library | `import ChiplessKit` |
| `chiplesscli` | Command line tool + scripted demo | `swift run chiplesscli help` |
| `ChiplessReaderApp` | SwiftUI app: read tags, reader setup, tag database, calibration, log | `scripts/build_app.sh` makes `dist/Chipless Reader.app` |
| `ChiplessKitTests` | Protocol byte vectors, parser, report and profile decoding | `swift test --filter ChiplessKitTests` |

The protocol is specified in `../../../docs/PROTOCOL.md`, relative to this file. The project guide is `../../../README.md`.

## Main types

| Type | Purpose |
|---|---|
| `ChiplessReader` | Connection and every reader command. Synchronous and thread-safe; call it off the main thread in UI code. |
| `TagReport` | One read: `name`, `matched`, `hexID`, `bitString`, `rssiDBm`, `marginDB`, `notchDepthsDB`, `phaseSwingsDegrees`, … |
| `TagProfile` | What the reader knows about the tags: sweep, bit frequencies, read rate, decision settings. `TagProfile.standard(bits: 10)` is 10 bits across 860–865 MHz |
| `TagDatabaseEntry` | One tag in the reader's database. `databaseEntries()`, `putDatabaseEntry(_:)`, `deleteDatabaseEntry(_:)`, `clearDatabase()` |
| `RFCalibration` | The RF chain numbers. `getCalibration()`, `setCalibration(_:)` |
| `AutoLevelResult`, `AttenuatorScanPoint` | `autoLevel()` and `attenuatorScan(stepDB:)`, for attenuator calibration |
| `LOResult` | What SET_LO programmed: lock state, INT/FRAC/MOD, RF divider, and the R0…R5 register words |
| `RFMeasurement` | One AD8302 reading: ADC counts, VMAG/VPHS, gain, phase, RSSI, and `conditions` against the AD8302's limits |
| `ReaderConfig`, `ReaderStatus`, `ReaderInfo` | Get commands |
| `SweepPoint` | Raw sweep data for plotting and export |
| `TagLibrary` | Maps decoded IDs to tag names on the Mac (JSON), without a reader attached |
| `SerialPort` | POSIX serial port used underneath; `SerialPort.candidatePorts()` lists readers |

## Mapping to the chipped reader SDK

| Chipped SDK screen | ChiplessKit |
|---|---|
| Communication Setup / Connect | `ChiplessReader(port:)`, `connect()` |
| Device Information | `getInfo()` |
| Device Operating Mode (Response / Auto) | `setMode(.response / .auto)`, `onTagReport` |
| RF Configuration: Region, Min/Max frequency | `setProfile(_:)`, `setSweep(...)`, `setLO(kHz:)` |
| RF Configuration: RF Power | `setTxPower(_:paEnabled:)` |
| Rx config | `setReferenceAttenuation(dB:)`, `autoLevel()`, `attenuatorScan(stepDB:)` |
| Link Mode | `setAcquisition(settleMicroseconds:averages:)` |
| Inventory + tag list (EPC/TID/RSSI, count) | `readTag()` → `TagReport`; the app aggregates reads by ID with a count |
| RF Diagnosis graph | `measure()`, `sweepData()`, `captureBackground()` |
| Tag memory read/write/kill | Not applicable to chipless tags. The reader's tag database names IDs instead. |

The existing Altra UHF targets (`ReaderTransport`, `ReaderProtocol`, `ReaderSDK`, `readercli`, `ReaderManagerApp`) are unchanged.
