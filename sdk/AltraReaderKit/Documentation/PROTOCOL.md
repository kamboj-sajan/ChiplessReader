# Protocol — What's Verified, What's Blocked, and How to Unblock It

## What was supplied

1. `ALTRAWAVES_UHF_Reader_Utility_Document_V1_0.pdf` — an **end-user manual** for
   a Windows demo app called "RFID Manager". It documents UI workflows (connect,
   inventory, filter, settings, tag access, tools) and two operationally useful
   facts:
   - Default network address `192.168.1.100`, gateway `192.168.1.254`, mask
     `255.255.255.0`.
   - Firmware upgrade note: *"Upgrade module firmware through serial port and
     communication board firmware through network port."*
   It does **not** contain wire-level bytes: no packet layout, opcodes, checksum
   algorithm, or timing.
2. `AWSReaderUI_v2.zip` — the Windows WPF **reference application**, source
   available for the UI (`.xaml`/`.cs`), plus a compiled `ModuleAPI.dll` that the
   UI calls into.
3. A handwritten planning note — product/feature priorities (multi-tag reading,
   security/inventory/data-analysis use cases, wifi/BLE, RF sweep parameters). No
   protocol content.

## What inspection of `ModuleAPI.dll` found

`ModuleAPI.dll` is a **managed .NET assembly** (confirmed via `file`: "Mono/.Net
assembly"). Two things were inspected, deliberately stopping at the interface
boundary rather than the implementation:

- **The reference app's own source code** (plaintext `.cs` files) shows *how* the
  UI calls the DLL: `Reader.Create(address, Region.NA, antennaPortNumber)`, then
  `ParamGet("...")` / `ParamSet("...", value)` for everything else — antenna
  power, region, connected antennas, IP settings, fast-mode params, etc. This is
  reading source the way you'd read a header file; it tells you the *shape* of
  the public API (which parameters exist, what they're called) but not a single
  byte of the wire format, because the wire format lives inside `ParamGet`/
  `ParamSet`'s implementation, which is compiled.
- **The DLL's .NET metadata** (type/namespace names only, via a pure-Python
  metadata reader — no IL disassembly, no decompilation of method bodies) shows
  namespaces `ThingMagic.*` and `ModuleTech.*` with classes like `M5eReader`,
  `M6eReader`, `SerialReader`, `Gen2`, and an `R2000cmd`/`R902CmdCodeE` command
  enumeration. This is a strong signal (not a certainty) that this reader is
  built on the **ThingMagic Mercury API** lineage over an **Impinj R2000-class**
  reader chip, private-labeled as "ModuleAPI".

**What was deliberately *not* done:** disassembling the DLL's method bodies (IL
decompilation) to reconstruct the actual byte-level command encoding. That would
mean extracting proprietary implementation, not just reading its interface — out
of scope per this project's own instructions, and not necessary given the path
below.

## Why this still leaves the wire protocol unverified

Knowing "this is probably Mercury-API-over-R2000" is a strong hint, not a
verified spec for *your specific module*. Private-labeled builds like this one
commonly:
- Use a subset of the real Mercury/R2000 command set.
- Add or rename vendor-specific commands (the metadata already shows
  `ModuleTech`-prefixed types that aren't standard ThingMagic names).
- Run a different framing/checksum than either upstream project by default.

Shipping a codec that *guesses* at Mercury API or R2000 framing and sends it to
your hardware would violate this project's safety requirements ("Never invent
undocumented reader commands"). So `AltraWavesCodec` stays a documented stub
(`ProtocolError.unverifiedProtocol`) until one of the paths below produces real
bytes.

## Exact unblock steps (fastest to slowest)

1. **Use the reference app's own debug logger.** The manual documents a
   "Command Debugging" toggle (§ II.4, "Enable Communication Protocol Debug")
   that prints the raw bytes the app sends/receives. Run the Windows reference
   app against your actual reader with that enabled, exercise Connect → Inventory
   → a couple of Tag Access operations, and save the printed log. This is the
   single fastest way to get verified, real bytes — no reverse engineering
   required, since the vendor's own tool is doing the logging.
2. **USB/serial or network packet capture** as a fallback if (1) is unavailable:
   `Wireshark` (with a USB capture backend, e.g. `usbmon` on Linux or `Wireshark`
   + a serial-to-pipe tool) or a simple serial sniffer between the reference app
   and the reader while performing the same operations.
3. **Vendor documentation request.** Ask Altra Waves Solutions directly for the
   "Module API" command reference — companies that license a Mercury-API-derived
   SDK commonly have one, even if it wasn't included in this ZIP.
4. **If confirmed to be genuine ThingMagic Mercury API**, its serial protocol
   (message ID, length, opcode, payload, CRC) is publicly documented by
   ThingMagic/JADAK; that documentation could seed `AltraWavesCodec`, but must
   still be **validated against a real capture from your module** before use,
   since the metadata findings above are a lineage hint, not a guarantee this
   build didn't diverge from the standard framing.

## Once you have real bytes

Drop them into `AltraWavesCodec.encode`/`decodeFrame` in
`Sources/ReaderProtocol/ReferenceCodec.swift` (rename the file/type as you like).
Everything above that layer — `ReaderClient`, the CLI, the app — is already
written against the `PacketCodec` protocol and needs **no changes**. Suggested
order:
1. Implement `decodeFrame` first against captured *response* bytes (read-only,
   zero risk to hardware) and write fixture-based tests in
   `Tests/ReaderProtocolTests` using the captured bytes verbatim.
2. Implement `encode` for read-only commands (`getReaderInfo`, `getParam`,
   single inventory) and test against a real reader with `readMemory`/inventory
   only.
3. Only after (1) and (2) are solid, wire up `writeMemory`/`lockTag`/`killTag` —
   and test those against tags you don't mind losing, per
   `HARDWARE_VALIDATION_CHECKLIST.md`.

## Network port specifics still to confirm

The manual gives the default IP but not the **TCP port** the reader listens on
for the "network port connection" mode. `TCPTransport` defaults to `4001`
(a common choice for this class of device) — confirm and update
`Sources/ReaderTransport/TCPTransport.swift` once known.
