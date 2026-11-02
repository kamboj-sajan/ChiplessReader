# Chipless Reader Protocol v0.3

This is the byte-level contract between the **SDK** (Mac) and the **reader firmware**. The same protocol is used by the STM32F4DISCOVERY and by the virtual reader.

Three implementations follow this document:
- the firmware (`firmware/core/protocol.*`, `commands.c`)
- the Swift SDK (`sdk/AltraReaderKit/Sources/ChiplessKit`)
- the Python bench client (`tools/chipless.py`)

`tools/e2e_test.py` checks all of it end to end.

---

## 1. Frame

```text
┌──────┬──────────┬──────┬────────┬─────────────┬──────────┐
│ 0xA5 │ LEN u16  │ CMD  │ STATUS │ PAYLOAD …   │ CRC u16  │
│ sync │ LE       │ u8   │ u8     │ 0…1019 B    │ LE       │
└──────┴──────────┴──────┴────────┴─────────────┴──────────┘
LEN  = bytes from CMD through CRC inclusive  (= payload + 4), 4 ≤ LEN ≤ 1023
CRC  = CRC-16/CCITT-FALSE over CMD … PAYLOAD  (poly 0x1021, init 0xFFFF, no reflection,
       no final XOR; "123456789" → 0x29B1)
```

- **All multi-byte values** are little-endian.
- **Frequencies** are always in kHz, as `u32`.
- **Fixed-point values:**
  - `_x10` means ×10. For example, `rssi_x10 = -226` means −22.6 dBm.
  - `_x100` means ×100.

### Code ranges

| Range | Meaning |
|---|---|
| `0x01–0x3F` | Host → reader commands |
| `0x81–0xBF` | Reader → host replies: `CMD \| 0x80` |
| `0xBF` | Also the reply to any command byte outside `0x01–0x3F` (status `UNKNOWN_CMD`) |
| `0xC0–0xFF` | Unsolicited reader → host events |

Because the ranges don't overlap, a reply can never be mistaken for an event.

**STATUS** is `0x00` in requests. In replies:

| Code | Name | Meaning |
|---|---|---|
| 0x00 | OK | Command accepted. The payload follows. |
| 0x01 | CRC_ERROR | A frame arrived but its CRC didn't match |
| 0x02 | UNKNOWN_CMD | Command not implemented |
| 0x03 | BAD_LENGTH | Wrong payload length for this command |
| 0x04 | OUT_OF_RANGE | A value is outside its allowed range |
| 0x05 | BUSY | Configuration change refused in AUTO mode (switch to RESPONSE first, as on the chipped reader) |
| 0x06 | PLL_UNLOCKED | Reserved |
| 0x07 | NOT_SUPPORTED | For example, a SIM_* command on the hardware backend |
| 0x08 | NV_ERROR | Writing the flash failed |

Replies with a non-OK status carry no payload.

### Parser behaviour (firmware and SDK)

- The parser resynchronises on the next `0xA5` after a bad length or a bad CRC.
- A partial frame is dropped after 200 ms of silence.
- Split frames and several frames in one USB packet are both handled.

---

## 2. Commands

### Device

| CMD | Name | Request | Reply payload |
|---|---|---|---|
| `0x01` | GET_INFO | none | `fw_major u8, fw_minor u8, hw_rev u8, simulated u8, uid[12], model[16]` (ASCII, NUL-padded) |
| `0x02` | PING | `token u32` | `token u32` |
| `0x03` | GET_STATUS | none | `mode u8, pll_locked u8, bg_valid u8, lo_khz u32, uptime_ms u32, frames_ok u32, frames_err u32, reads u32, tags_found u32, tx_dbm_x10 i16` |
| `0x05` | RESET_CONFIG | none | none (settings and calibration back to defaults in RAM; the tag database is kept) |
| `0x06` | NV_SAVE | none | none (settings, calibration and tag database stored in flash; loaded at boot) |
| `0x08` | SET_MODE | `mode u8` (0 RESPONSE, 1 AUTO), `[interval_ms u16]` (50–60000) | `mode u8, interval_ms u16` |
| `0x0F` | GET_CONFIG | none | `lo_khz u32, sweep_start u32, sweep_stop u32, sweep_step u32, tx_level u8, pa_en u8, ref_atten u8, settle_us u16, averages u8, threshold_x10 u16, n_bits u8, mode u8, interval_ms u16` |

### RF configuration

These correspond to the chipped SDK's Region/Frequency, RF Power, Rx Config and Link Mode settings.

| CMD | Name | Request | Reply payload |
|---|---|---|---|
| `0x10` | SET_SWEEP | `start_khz u32, stop_khz u32, step_khz u32` (≤ 512 points, 35 MHz–4.4 GHz) | echo + `points u16` |
| `0x12` | SET_TX_POWER | `level u8` (0 = −4, 1 = −1, 2 = +2, 3 = +5 dBm ADF4351), `pa_en u8` | echo + `tx_dbm_x10 i16` (calibrated, at the TX antenna). `OUT_OF_RANGE` if the current attenuator would then put INPA above 0 dBm |
| `0x13` | SET_CARRIER | `on u8` | `on u8`. Holds the PA on at the LO, for a spectrum analyser. Otherwise the PA runs only during measurements |
| `0x14` | SET_RX_CONFIG | `ref_atten u8`: PE4312 setting in 0.5 dB steps, 0–63 | `ref_atten u8, inpa_dbm_x10 i16, min_atten u8`. `OUT_OF_RANGE` below `min_atten`, the lowest setting that keeps INPA at or below 0 dBm |
| `0x16` | SET_ACQ | `settle_us u16` (10–10000), `averages u8` (1–64) | echo |
| `0x18` | SET_DETECT | `threshold_x10 u16` (1.0–40.0 dB), `n_bits u8` (1–16), `bit_khz u32 × n` | same as GET_DETECT |
| `0x19` | GET_DETECT | none | `threshold_x10 u16, n_bits u8, bit_khz u32 × n` |
| `0x1A` | SET_PROFILE | **tag profile** (below) | the profile as stored |
| `0x1B` | GET_PROFILE | none | **tag profile** |
| `0x1E` | SET_CAL | **calibration** (below) | the calibration as stored |
| `0x1F` | GET_CAL | none | **calibration** |
| `0x20` | SET_LO | `freq_khz u32` | `freq_khz u32, locked u8, actual_hz u32, INT u16, FRAC u16, MOD u16, rf_div u8, vco_khz u32, R0..R5 u32 × 6` |
| `0x21` | MEASURE | none | `lo_khz u32, adc_mag u16, adc_phs u16, vmag_mv u16, vphs_mv u16, gain_x100 i16, phase_x10 u16, p_ref_x10 i16, p_rx_x10 i16, rssi_x10 i16, clipped u8, locked u8, flags u8` (**conditions**, below) |
| `0x22` | ATTEN_SCAN | `step u8` (0.5 dB units) | `count u8`, then per point: `atten u8, vmag_mv u16, gain_x100 i16, inpa_x10 i16, flags u8`. Starts at the safe minimum; restores the setting afterwards |
| `0x23` | AUTO_LEVEL | none | `old_atten u8, new_atten u8, gain_min_x100 i16, gain_max_x100 i16, inpa_x10 i16, clipped u16, flags u8, iterations u8`. Applies the setting that centres the AD8302 on a sweep |

Notes:
- **Background validity:** a change to the sweep (SET_SWEEP or SET_PROFILE) or to SET_TX_POWER invalidates a captured background, because both change what "empty" looks like.
- **ADF4351 registers:** SET_LO returns the exact register words the STM32 clocked into the ADF4351. For 865 MHz with a 25 MHz reference: `R0 00450010 R1 08008029 R2 18004E42 R3 000004B3 R4 00AC803C R5 00580005`.

**Tag profile:** what the reader has to know about the tags, sent as one record. Every bit must fall inside the sweep.

| Field | Type | Range |
|---|---|---|
| `name` | 16 bytes, NUL-padded | |
| `start_khz, stop_khz, step_khz` | u32 × 3 | ≤ 512 points, 35 MHz–4.4 GHz |
| `settle_us` | u16 | 10–10000 |
| `averages` | u8 | 1–64 |
| `threshold_x10` | u16 | 1.0–40.0 dB: notch depth for a 1 |
| `phase_thr_x10` | u16 | 0–180.0°: phase swing that confirms the notch; 0 = ignore phase |
| `interval_ms` | u16 | 50–60000: read rate in AUTO mode |
| `max_bit_errors` | u8 | 0–n_bits: differing bits allowed in a database match |
| `n_bits` | u8 | 1–16 |
| `bit_khz` | u32 × n_bits | f1 first |

**Calibration:** 12 × `i16`, each ×100: TX filter loss, PA trim, coupling, coupler through loss, attenuator insertion loss, LNA gain, RX filter loss (dB); VMAG centre (units of 10 mV), VMAG slope (mV/dB); VPHS centre (units of 10 mV), VPHS slope (mV/°); RSSI trim (dB). The slopes must be at least 5 mV/dB and 1 mV/°.

**Conditions** (`flags`): `0x01` INPA above 0 dBm, `0x02` INPA below −60 dBm, `0x04` INPB above 0 dBm, `0x08` INPB below −60 dBm, `0x10` VMAG at a rail.

### Tags

| CMD | Name | Request | Reply payload |
|---|---|---|---|
| `0x30` | READ_TAG | none | **tag report** (below) |
| `0x31` | GET_SWEEP_DATA | `offset u16, count u16` (≤ 160 per call) | `total u16, offset u16, count u16, start_khz u32, step_khz u32, has_bg u8`, then per point: `rx_x100 i16` (dBm at RX antenna), `phase_x10 u16`, `bg_x100 i16` (−32768 = no background) |
| `0x32` | CAPTURE_BG | none (no tag in front of the antennas) | `points u16, sweep_ms u16` |
| `0x33` | CLEAR_BG | none | none |

### Tag database

The list the STM32 identifies tags against, 64 entries. A database command changes the list in RAM; NV_SAVE stores it.

| CMD | Name | Request | Reply payload |
|---|---|---|---|
| `0x24` | DB_INFO | none | `count u16, capacity u16, name_len u8` |
| `0x25` | DB_GET | `index u16` | `index u16, id u32, n_bits u8, name[16]` |
| `0x26` | DB_PUT | `id u32, n_bits u8, name[0..16]` | `index u16, count u16`. Adds it, or renames it if `(id, n_bits)` exists. `OUT_OF_RANGE` if the ID doesn't fit in `n_bits` or the list is full |
| `0x27` | DB_DELETE | `id u32, n_bits u8` | `count u16`. `OUT_OF_RANGE` if not found |
| `0x28` | DB_CLEAR | none | none |

### Simulation

These work on the virtual reader and on the STM32 built with `BACKEND=SIM`. Otherwise they return `NOT_SUPPORTED`.

| CMD | Name | Request | Reply payload |
|---|---|---|---|
| `0x3A` | SIM_SET | `tag i8` (−1 = none), `distance_cm u16` (5–300), `noise_x100 u16` (dB rms), `[q u16]` (20–20000, resonator Q) | same as SIM_GET |
| `0x3B` | SIM_GET | none | `tag i8, distance_cm u16, noise_x100 u16, q u16, n_tags u8`, then per tag: `code u32, name[12], n_bits u8` |

### Events (reader → host)

| Code | Name | When | Payload |
|---|---|---|---|
| `0xC0` | TAG_REPORT | In AUTO mode, every time a tag is found | **tag report** |

---

## 3. Tag report

This is the payload of READ_TAG replies and TAG_REPORT events. It is the chipless equivalent of the chipped reader's inventory frame.

| Field | Type | Meaning |
|---|---|---|
| `seq` | u32 | Read counter |
| `found` | u8 | 1 = at least one resonator detected |
| `n_bits` | u8 | Number of bits in the tag layout |
| `id` | u32 | Decoded ID. Bit k = resonator k present (bit 0 = lowest frequency f1) |
| `rssi_x10` | i16 | Received power at the RX antenna, band average (dBm) |
| `phase_x10` | u16 | \|phase\| at the deepest notch (°) |
| `margin_x10` | i16 | min over bits of \|notch depth − threshold\| (dB): how close the least certain bit came to flipping |
| `sweep_ms` | u16 | Sweep duration |
| `points` | u16 | Points in the sweep |
| `bg_used` | u8 | 1 = background subtracted |
| `clipped` | u16 | Points where the AD8302 was outside its ±30 dB range |
| `unlocked` | u16 | Points where the PLL didn't lock |
| `depth_x10` | i16 × n_bits | Notch depth measured at each bit frequency (dB) |
| `swing_x10` | i16 × n_bits | Phase swing across each bit frequency (°) |
| `matched` | u8 | 1 = the pattern was found in the tag database |
| `bit_errors` | u8 | Differing bits in that match |
| `db_index` | i16 | Database entry, −1 = none |
| `name` | 16 bytes | Name from the database, NUL-padded |

**How a read works on the reader:**
1. For each frequency in the sweep, program the ADF4351 and wait for lock (LD pin).
2. Wait `settle_us`, then average `averages` 12-bit ADC samples of VMAG and VPHS.
3. Convert the readings to received power at the RX antenna.
4. For each bit frequency, find the lowest level within ±20 % of the bit spacing, and the highest level from there out to the midpoint with each neighbouring bit (the "shoulders"). Notch depth is the lower of the two shoulders minus the lowest level, so a 0 next to a 1 doesn't borrow that notch's slope.
5. The phase swing is the range of |φ| across the same ±20 % window.
6. A bit is **1** when the depth reaches the threshold and the swing reaches the phase threshold. A depth above twice the threshold doesn't need the phase.
7. The pattern is looked up in the tag database.

**AD8302 conversions** (datasheet slopes):
- VMAG = 0.9 V + 28.7 mV/dB × (P_INPA − P_INPB)  (the datasheet's 900 MHz slope, adjustable with SET_CAL)
- VPHS = 0.9 V − 10.1 mV/° × (|φ| − 90°)
- P_INPB = P_INPA(estimated from TX power, the −20 dB coupler and the attenuator) − gain
- RSSI = P_INPB − LNA gain + RX filter loss

---

## 4. Byte examples

These are exact vectors, used in the unit tests on both sides.

| Frame | Bytes |
|---|---|
| GET_INFO | `A5 04 00 01 00 3E 2E` |
| PING 0x12345678 | `A5 08 00 02 00 78 56 34 12 AA 55` |
| PING reply | `A5 08 00 82 00 78 56 34 12 8A 81` |
| GET_STATUS | `A5 04 00 03 00 5C 48` |
| GET_CONFIG | `A5 04 00 0F 00 31 0D` |
| SET_SWEEP 860–865 MHz, 25 kHz | `A5 10 00 10 00 60 1F 0D 00 E8 32 0D 00 19 00 00 00 56 7B` |
| SET_CARRIER on | `A5 05 00 13 00 01 8E C6` |
| SET_RX_CONFIG 24 dB (48) | `A5 05 00 14 00 30 6C 65` |
| GET_PROFILE | `A5 04 00 1B 00 86 C2` |
| ATTEN_SCAN 1 dB steps | `A5 05 00 22 00 02 78 04` |
| AUTO_LEVEL | `A5 04 00 23 00 BA 4E` |
| DB_INFO | `A5 04 00 24 00 2D D7` |
| DB_PUT 1010110011 "TEN-A" | `A5 0E 00 26 00 35 03 00 00 0A 54 45 4E 2D 41 D4 45` |
| NV_SAVE | `A5 04 00 06 00 A9 B7` |
| SET_TX_POWER +5 dBm, PA on | `A5 06 00 12 00 03 01 7D 37` |
| SET_LO 865 000 kHz | `A5 08 00 20 00 E8 32 0D 00 A8 E7` |
| MEASURE | `A5 04 00 21 00 D8 28` |
| READ_TAG | `A5 04 00 30 00 9A 18` |
| CAPTURE_BG | `A5 04 00 32 00 F8 7E` |
| SIM_SET TAG-A (0), 20 cm, 0.05 dB | `A5 09 00 3A 00 00 14 00 05 00 AE 75` |
| SET_MODE AUTO, 250 ms | `A5 07 00 08 00 01 FA 00 1B D8` |
| Reply OUT_OF_RANGE to SET_LO | `A5 04 00 A0 04 F5 40` |
| Reply BUSY to SET_LO | `A5 04 00 A0 05 D4 50` |
| Reply to a command ≥ 0x40 | `A5 04 00 BF 02 7E 33` |

---

## 5. Mapping to the chipped reader SDK (RRUHFR03)

| Chipped SDK | This protocol |
|---|---|
| Get Device Information | GET_INFO |
| Set/Get Mode of Operation (Response / Auto) | SET_MODE, GET_STATUS |
| Region + Min/Max frequency (min = max to disable hopping) | SET_SWEEP (start = stop to hold one frequency) and SET_LO |
| Set/Get Power | SET_TX_POWER |
| Set Rx Config (PGA/mixer gains) | SET_RX_CONFIG (PE4312 reference level) |
| Link Mode (speed vs range) | SET_ACQ (settle time, averaging) |
| Q / Session / Target | Not applicable: chipless tags can't take turns. SET_DETECT sets the bit layout and threshold instead. |
| Inventory (EPC / TID / RSSI) | READ_TAG → ID, bits, name from the database, RSSI, margin, phase |
| Auto-inventory tag data frame | TAG_REPORT event (0xC0) |
| RF Diagnosis (noise graph) | MEASURE, GET_SWEEP_DATA, CAPTURE_BG |
| Read/Write/Kill/Protect tag memory | Not possible: a chipless tag's ID is fixed copper. The tag database on the reader maps IDs to names instead. |
