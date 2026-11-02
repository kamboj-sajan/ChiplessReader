# User Guide

## Simulation mode (works today, no hardware)

1. `swift run ReaderManagerApp`
2. Connect screen → Transport: **Simulation** → Connect.
3. Inventory screen → Start. You'll see a rotating population of ~12 simulated
   tags with jittered RSSI, spread across 4 simulated antennas.
4. Try Export (CSV/JSON), the search field, sorting columns.
5. Logs & Diagnostics screen has two buttons unique to simulation mode:
   "Malformed Packet" and "Simulate Disconnect" — use these to see how the app
   surfaces transport-layer problems.
6. Tag Access screen: pick any EPC (even a made-up one, in simulation mode) and
   try Read / Write / Lock / Destroy. Write/Lock/Destroy all show a confirmation
   sheet — this isn't skippable, even in simulation, so you get an accurate feel
   for the real safety flow.

## Connecting to real hardware

**Read `Documentation/PROTOCOL.md` first.** Short version: you can connect
(open the port/socket) today, but reader *commands* are intentionally blocked
until the wire protocol is verified.

### Serial

1. Install the USB-serial driver for your reader's chipset.
2. Plug in the reader.
3. Connect screen → Transport: **Serial** → pick your device from the dropdown
   (populated from `/dev/cu.*`) → set baud rate (reference app commonly uses
   115200; confirm for your module) → Connect.

### Network

1. Configure your Mac's network interface to be on the same subnet as the
   reader (reference default: reader `192.168.1.100`, mask `255.255.255.0`).
2. Verify reachability: `ping 192.168.1.100`.
3. Connect screen → Transport: **Network (TCP)** → enter host/port → Connect.

## CSV / JSON export

Inventory screen → Export menu. Exports the currently deduplicated table (not
the raw read log) — one row per unique tag with its latest RSSI, total read
count, and first/last-seen timestamps.

## Diagnostics

Every connect/disconnect, command, and error is logged to the Logs &
Diagnostics screen with a timestamp. In mock mode this reflects the
`ReferenceCodec`'s simulated bytes; once `AltraWavesCodec` exists, this becomes
your real protocol log — the same role as the reference app's "Command
Debugging" toggle.
