# Hardware Validation Checklist

Use this once `AltraWavesCodec` has a real implementation (see `PROTOCOL.md`).
Work top to bottom; each section assumes the previous one passed. Use tags you
don't mind losing for the destructive section.

## 1. Transport

- [ ] Serial: app lists your reader's `/dev/cu.*` device in the picker.
- [ ] Serial: Connect succeeds; disconnect (unplug) is detected and reflected
      in the UI within a few seconds, not silently hung.
- [ ] Serial: reconnect after unplug works without restarting the app.
- [ ] Network: Connect succeeds at the reader's configured IP/port.
- [ ] Network: reader becoming unreachable mid-session is detected.
- [ ] Mac sleep/wake: put the Mac to sleep with a reader connected; verify the
      app recovers (reconnects or clearly shows disconnected) on wake.

## 2. Read-only reader commands

- [ ] `readerInfo()` returns real mainboard/module/firmware strings, not the
      mock's `SIM.*` placeholders.
- [ ] `singleInventory()` returns real tags physically present near the
      antenna.
- [ ] `startInventory()`/`stopInventory()` produce a continuous stream of real
      `TagRead` events, and stop cleanly (no orphaned background reads).
- [ ] RSSI/antenna/frequency values look physically plausible (RSSI more
      negative farther from the antenna, etc.).
- [ ] `readMemory(bank: .epc, ...)` returns the tag's actual EPC bytes,
      matching what's printed/known for a test tag.
- [ ] `readMemory(bank: .tid, ...)` returns the tag's TID.
- [ ] `readMemory(bank: .reserved, ...)` on a locked reserved bank fails
      without the correct access password, and succeeds with it.

## 3. Configuration

- [ ] `setRegion(_:)` — confirm on an RF-legal region for your location;
      verify via `readerInfo()`/`getParam` (once exposed) that it took effect.
- [ ] `setRFPower(dBm:antenna:)` — verify read range changes plausibly with
      power.
- [ ] `setFilter(_:)` — verify only matching tags appear in inventory with a
      filter enabled, and all tags reappear when disabled.
- [ ] `setGen2Configuration(_:)` — verify session/target/Q changes don't crash
      the reader and inventory still functions.

## 4. Destructive operations — use expendable test tags only

- [ ] `writeMemory` on the `user` bank with a disposable tag; read back to
      confirm.
- [ ] `writeMemory` on the `epc` bank; confirm the tag's EPC actually changed.
- [ ] `lockTag(lockType: .temporaryLock)` then verify write fails without the
      access password and succeeds with it.
- [ ] `lockTag(lockType: .permanentLock)` — **only on a tag you're certain you
      want permanently locked.** Confirm the app's confirmation dialog
      correctly describes this as irreversible before proceeding.
- [ ] `killTag` — **only on a tag you're certain you want destroyed.** Confirm
      it no longer responds to inventory afterward.

## 5. Fault handling

- [ ] Send a command with the reader unplugged mid-operation; verify a clean
      `TransportError`/`ReaderSDKError`, not a hang or crash.
- [ ] Verify malformed/corrupted responses (if you can trigger any, e.g. by
      briefly interrupting a serial connection) are reported as
      `ProtocolError.malformedPacket`/`.checksumMismatch` and the assembler
      recovers on the next valid frame, rather than getting stuck.

## 6. Sign-off

- [ ] Update `PROJECT_TODO.md`'s "Real Altra Waves wire-protocol codec" item
      from Blocked to Completed, with a note on which sections above passed.
- [ ] Update `FEATURE_MATRIX.md`'s "Availability on my reader" column from
      "Unknown" to the confirmed answer for each row you tested.
