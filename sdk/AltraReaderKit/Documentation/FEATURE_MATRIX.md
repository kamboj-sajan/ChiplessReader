# Feature Matrix

Source of truth for "required feature" = the reference app's manual
(`ALTRAWAVES_UHF_Reader_Utility_Document_V1_0.pdf`) plus the handwritten planning
note. "Reference implementation" = what `AWSReaderUI_v2.zip`'s source shows.
"Availability on my reader" is honestly **Unknown** everywhere — no documentation
or protocol capture for your specific module was supplied in this conversation
(see `PROTOCOL.md`).

| Required feature | Reference implementation | Required reader command/API (as seen in reference source) | Availability on my reader | macOS implementation | Status |
|---|---|---|---|---|---|
| Serial connection | `ConnectView` — COM port + antenna count picker | `Reader.Create(comPort, region, antCount)` | Unknown | `SerialTransport` (`/dev/cu.*`, termios) | Transport implemented; commands blocked |
| Network connection | `ConnectView` — IP `192.168.1.100` default | `Reader.Create(ip, region, antCount)` | Unknown | `TCPTransport` (`Network.framework`) | Transport implemented; commands blocked |
| Reader/firmware info | Connect screen "Hardware Information" panel | `ParamGet("HardwareVersion" / "SoftwareVersion")` | Unknown | `ReaderClient.readerInfo()` | **Mock: done.** Real: blocked |
| Antenna count / config | `ParamAntsView`, Settings → Antennas tab | `ParamGet/Set("ConnectedAntennas")`, per-antenna read/write power | Unknown | Planned in `ReaderClient` config surface | Blocked (real); not yet modeled (mock) |
| RF region | Settings → Advance → Frequency Control Rules | `Reader.Create(..., Region.NA, ...)` | Unknown | `ReaderClient.setRegion(_:)` | **Mock: done.** Real: blocked |
| RF power (per-antenna / all) | Settings → Antennas, read/write power fields | `ParamGet/Set("RfPowerMax/Min")`, per-ant power array | Unknown | `ReaderClient.setRFPower(dBm:antenna:)` | **Mock: done.** Real: blocked |
| Antenna selection | Settings → Antennas "in Use" checkboxes | `ParamGet("ConnectedAntennas")` | Unknown | `antennas:` params on inventory calls | **Mock: done.** Real: blocked |
| Continuous inventory | Inventory screen ▶/■ buttons | reader "Start/Stop Count" | Unknown | `ReaderClient.startInventory/stopInventory` | **Mock: done** (simulated tag stream). Real: blocked |
| Single inventory | N/A explicit in reference UI (continuous only) | — | Unknown | `ReaderClient.singleInventory()` | **Mock: done.** Real: blocked |
| EPC/TID/RSSI/ANT display | Inventory table columns | inventory response fields | Unknown | `TagRead` model + `InventoryView` table | **Done (mock data shape matches reference columns)** |
| Seen count / first/last seen | Computed in reference app's own view layer | n/a (app-side, not reader-side) | N/A | `InventorySession` | **Done** |
| EPC filtering | "Tag Filter" flyout (bank/rule/mask) | `ParamSet("FilterBank/Rule/Mask")`-style | Unknown | `ReaderClient.setFilter(_:)`, `TagFilter` | **Mock: done.** Real: blocked |
| Gen2 session/target/Q | Settings → Inventory "Common Parameters" | `ParamSet("Gen2Session/Target/Q")` | Unknown | `ReaderClient.setGen2Configuration(_:)` | **Mock: done.** Real: blocked |
| Tag memory read | Tag Access → Read Bank | `ParamGet`-style read op, per bank | Unknown | `ReaderClient.readMemory(...)` | **Mock: done** (deterministic simulated bytes). Real: blocked |
| Tag memory write | Tag Access → Write Bank | write op, per bank (TID not writable) | Unknown | `ReaderClient.writeMemory(_:)`, gated by `WriteConfirmation` | **Mock: done.** Real: blocked |
| Tag lock (unlock/temp/permanent) | Tag Access → Lock Tag | lock op with access password | Unknown | `ReaderClient.lockTag(_:)`, gated by `LockConfirmation` | **Mock: done.** Real: blocked |
| Tag kill/destroy | Tag Access → Destroy Tag | kill op with kill password | Unknown | `ReaderClient.killTag(_:)`, gated by `KillConfirmation` | **Mock: done.** Real: blocked |
| CSV export | Inventory "Export List" | app-side, exports its own grid | N/A | `InventoryExport.csv(_:)` | **Done** |
| JSON export | Not present in reference app | — | N/A | `InventoryExport.json(_:)` | **Done** (new capability, not a reference parity item) |
| Command/protocol debug logging | "Enable Communication Protocol Debug" toggle | prints raw comms | N/A | `LogsView` + `ReaderEvent.diagnosticLog` | **Done (mock).** Real: will show real bytes once `AltraWavesCodec` exists |
| GPI/GPO peripherals | Peripherals screen | `ParamGet`(GPI)/`ParamSet`(GPO) | Unknown | Not yet implemented | **Not started** — lower priority than core inventory/tag-access per your handwritten notes |
| Firmware update | Tools → Firmware | module vs. mainboard firmware, serial vs. network | Unknown | Not implemented | **Not started** — explicitly high-risk/irreversible; needs a verified protocol and your explicit sign-off before any implementation begins |
| VSWR / standing-wave check | Tools → Vswr Check | antenna diagnostic sweep | Unknown | Not implemented | **Not started** |
| Wi-Fi / Bluetooth wireless config | Handwritten note ("wifi", "Blue tooth") | `ReaderIPInfo_Ex` + `WifiSetting` types seen in DLL metadata | Unknown | Not implemented | **Not started** — noted as a future transport, no current reader exposes it in the supplied materials |
| Multi-reader / multi-tag fleet view | Handwritten note ("Multiple", "Tags") | — | N/A | `ReaderClient` is single-reader; app is single-session | **Not started** — architecturally straightforward (one `ReaderClient` per reader) but out of scope for this pass |

**Reading this table:** "Mock: done" means the behavior is fully implemented and
exercised by tests today. "Real: blocked" means the *interface* exists in
`ReaderSDK` and will work unchanged once `AltraWavesCodec` is written — nothing
about the public API needs to change to unblock it.
