# Design notes: 10 bits across 860–865 MHz

How the block diagram maps onto the firmware, what each datasheet says that affects it, and what is still unproven. Read this before wiring the RF parts.

---

## 1. The diagram, mapped to the code

| Diagram | Where it lives |
|---|---|
| SDK sends gain, frequency sweep and database to the STM32 | `ChiplessKit` → `SET_TX_POWER`, `SET_PROFILE`, `DB_PUT` |
| STM32 configures R0–R5 over SPI | `firmware/core/adf4351.c`, `plat_adf4351_write()` |
| "Decide gain (−4 to +5 dBm)" | ADF4351 R4 output level, `SET_TX_POWER` |
| "f1, f2, f3 … f10" and "Sweep" | `reader_sweep()` in `firmware/core/reader.c` |
| LPF → PA → directional coupler → TX | Passive, except the PA's SHDN pin, `pa_gate()` |
| "No need for preamp" | Confirmed below: +5 dBm drives the MAX2235 close to saturation |
| Attenuator, "ensure −60 to 0 dBm on AD8302" | `SET_RX_CONFIG` refuses anything above 0 dBm; the Calibration screen shows both inputs against this range |
| "24" written on the attenuator | Read as 24 dB and used as the default (`DEF_REF_ATTEN_HALF_DB`). **Please confirm this reading.** It puts INPA at −14.9 dBm |
| RX → LNA → BPF → INPB | Passive, modelled in `calibration.c` |
| VMAG → ADC1, VPHS → ADC2 | ADC1 + ADC2 in dual simultaneous mode, `ADC_Init()` in `firmware/stm32/Src/main.c` |
| "STM compares the magnitude, phase to detect the bit pattern" | `measure_bit()` and `reader_read_tag()` in `reader.c` |
| "…decoded and compared against database" | `tagdb_match()` in `firmware/core/tagdb.c`; the database lives on the STM32, in flash |
| Single 1, double 10, ten-bit 1010110011 | Tag format presets. `1010110011` is written f1 first and is ID `0x335` |
| The tag–reader "ecosystem": what sweep, frequencies and rate it reads | `TagProfile` / `SET_PROFILE`: one record holding sweep, bit frequencies, read rate and decision settings |

---

## 2. What the datasheets changed

| Part | What the datasheet says | What was in the code | What it is now |
|---|---|---|---|
| **MAX2235** | Output vs input curve at 3.6 V: about 27 dBm at −5 dBm in, 29.2 at 0, 30.2 at +5. Absolute maximum input +13 dBm | Fixed 30 dB gain, clipped at 30.5 dBm | The datasheet curve (`cal_max2235_pout_dbm`). **The 9 dB ADF4351 gain range moves the antenna power by only about 3 dB** (27.1 to 30.0 dBm) |
| **MAX2235** | Off-isolation 48 dB typical with SHDN low | 25 dB | 48 dB |
| **MAX2235** | Auto-ramp: about 600 µs rise with the 0.068 µF capacitor | Measured straight after enable | Waits 1 ms (`PA_RAMP_US`). The PA now runs only during measurements, so the board does not radiate 1 W just by being powered |
| **AD8302** | Input range −60 to 0 dBm, centre −30 dBm; absolute maximum +10 dBm | No check | Range flags on every measurement. Attenuator settings that would exceed 0 dBm are refused: with the PA on, the minimum is **9.5 dB** (at 0 dB, INPA would be about +9 dBm) |
| **AD8302** | At 900 MHz the slopes are 28.7 mV/dB and 10.1 mV/° | Nominal 30 and 10 | 28.7 and 10.1 by default, or the measured value from the attenuator scan. The old figure made every dB reading about 4 % wrong |
| **AD8302** | Phase output is linear over about 145°, and only \|φ\| is available: it cannot tell +90° from −90° | Phase reported, not used to decode | Decode uses the phase *swing* across each bit, which survives the fold at 0° and 180° |
| **PE4312** | MSB first (Table 6: C16 first in), 6-bit shift register, LE high latches | "MSB assumed", with a switch to flip it | Confirmed; the switch is gone |
| **PE4312** | 1.3 dB insertion loss below 1 GHz; +24 dBm max CW input; 800 ns switching | 1.5 dB; no settling time | 1.3 dB; waits 2 µs after a change. The coupled port gives about +10 dBm, well inside the input limit |
| **X3C09F1-20S** | 19.7 ±0.5 dB coupling and 0.05 dB through loss near this band (the nearest table row is 869–894 MHz) | 20 dB and 0.3 dB | 19.7 dB and 0.05 dB |
| **LFCN-1000+** | 0.30 dB at 500 MHz, 0.80 dB at 1000 MHz | TX 1.0 dB | TX 0.65 dB (interpolated) |
| **HFCN-650+** | 0.90 dB at 850 MHz | RX pair 2.0 dB | RX pair 1.55 dB |
| **HMC8410** | 19.5 dB gain, 1.1 dB NF, 21 dBm P1dB at 0.01–3 GHz; RF input absolute maximum +20 dBm | 19.5 dB | Unchanged |
| **ADF4351** | R0 starts VCO band selection: 10 PFD cycles × band-select divider = 80 µs at 125 kHz. Modulus is double-buffered and needs an R0 write | Wrote all six registers at every point | First sweep point programs all six; later points only the changed registers, then R0. Each point still takes about 80 µs of band selection, which the 200 µs settle time covers |
| **ADF4351** | Output levels −4/−1/+2/+5 dBm, ±1 dB; divider ÷4 gives a 3440–3460 MHz VCO for this band; INT ≥ 75 for the 8/9 prescaler (here N ≈ 138) | Correct | Unchanged. All 201 points on the 25 kHz grid come out exact |

The figures above were read from these datasheets: ADF4351 Rev. A, AD8302 Rev. B, MAX2235 Rev. 3 (8/21), PE4312 DOC-81482-4.01 (06/2026), HMC8410, LFCN-1000+, HFCN-650+, X3C09F1-20S Rev G. Several were distributor copies because analog.com refused the download.

---

## 3. Power budget at the defaults

ADF4351 +5 dBm, PE4312 at 24 dB, VCC 3.6 V on the PA.

| Point | Level | Limit |
|---|---|---|
| After the LPF, at the PA input | +4.4 dBm | MAX2235 absolute maximum +13 dBm |
| PA output | +30.1 dBm | Coupler rated 25 W |
| TX antenna | +30.0 dBm | See regulatory note |
| Coupled port | +10.4 dBm | PE4312 +24 dBm CW |
| **AD8302 INPA** | **−14.9 dBm** | −60 to 0 dBm |
| AD8302 INPB, per dB of TX-to-RX path loss L | +30.0 − L + 19.5 − 1.55 = **47.95 − L dBm** | −60 to 0 dBm; +10 dBm absolute maximum |

### The risk to check first: antenna isolation

From the last row, the TX and RX antennas need **at least 48 dB of isolation** to keep INPB under 0 dBm, and **at least 38 dB to stay under the AD8302's +10 dBm absolute maximum**. Two antennas side by side can easily be worse than that. The HMC8410's output saturates near 22 dBm, so it will not protect the AD8302.

The AD8302 can't measure this for you with the PA off: both inputs then fall below its −60 dBm range and the reading means nothing. So find the isolation before connecting INPB:

1. **Measure the antennas on a VNA**, or drive the TX antenna from the ADF4351 directly (no PA) and read the RX antenna on a spectrum analyser or SDR. Do this with the antennas mounted as they will be used.
2. **If neither is available, put a 20 dB fixed attenuator in front of INPB** for the first power-up. INPB then stays under +10 dBm for any isolation above 18 dB. Press Measure on the Calibration screen and read INPB; add 20 dB to get the real level.
3. **Remove the pad only if the isolation is at least 48 dB.** Otherwise improve the antenna placement, or keep a fixed attenuator after the LNA.

A fixed attenuator after the LNA is also the only way to set the receive level, because the PE4312 in this design sits on the reference path.

---

## 4. Can 10 bits fit in 5 MHz? Only with sharp resonators

Ten bits in 5 MHz means 500 kHz between neighbouring notches at 865 MHz. A notch's width is f/Q, so a resonator with Q = 250 is 3.5 MHz wide and all ten merge into one dip.

`tools/q_study.py` measured this on the simulated front-end, with a −20 dB notch per resonator, 20 cm range and 0.05 dB noise:

| Resonator Q | Notch width | 1 bit | 2 bits | 10 bits | Mean margin (10 bits) |
|---|---|---|---|---|---|
| 100 | 8.62 MHz | 5/5 | 0/5 | 0/25 | |
| 250 | 3.45 MHz | 5/5 | 5/5 | 0/25 | |
| 500 | 1.73 MHz | 5/5 | 5/5 | 0/25 | |
| 750 | 1.15 MHz | 5/5 | 5/5 | 5/25 | |
| 1000 | 0.86 MHz | 5/5 | 5/5 | 10/25 | |
| **1250** | 0.69 MHz | 5/5 | 5/5 | **25/25** | 1.4 dB |
| 1500 | 0.57 MHz | 5/5 | 5/5 | 25/25 | 2.6 dB |
| **2000** | 0.43 MHz | 5/5 | 5/5 | **25/25** | 4.1 dB |
| 3000 | 0.29 MHz | 5/5 | 5/5 | 25/25 | 5.1 dB |

The software can do its part, but **10 bits at 500 kHz spacing needs Q of about 1250 to read at all, and about 2000 to read with margin.** A printed copper resonator is usually in the low hundreds, limited by the board material. At Q of a few hundred, in this band, 1 or 2 bits work and 10 do not.

Manufacturing tolerance is a second problem. A printed resonator's frequency commonly shifts by a fraction of a percent between boards, and 0.5 % at 865 MHz is more than 4 MHz, nearly the whole band.

**What to do about it:**

1. **Measure a real tag on a VNA** before anything else: resonance frequency, notch depth and Q.
2. If Q is low, keep 10 bits but widen the band (10 bits need about 20 MHz at Q ≈ 300), or use fewer bits in 5 MHz. The format, band and bit frequencies are all settings in the app, so this needs no firmware change.
3. Enter each tag's measured frequencies under Bit frequencies on Reader Setup, instead of the evenly spaced defaults.

These numbers come from a model. The −20 dB notch and the tag echo level are estimates until real tags are measured.

---

## 5. Other things to know

- **Regulatory.** India's licence-exempt RFID band starts at 865 MHz (865–867 MHz, recently 865–868 MHz), so most of 860–865 MHz needs authorisation to radiate, and the default is about 1 W. Check this with your institution, or test in a shielded enclosure or with cabled connections.
- **A tag with no resonators cannot be read.** `0000000000` looks the same as no tag at all, so don't assign it to a tag. The app warns about this.
- **One tag at a time.** Two tags in front of the antennas mix their notches, as before.
- **862.5 MHz is an integer-N point.** VCO 3450 MHz is an exact multiple of the 25 MHz PFD, so settings next to it have a fractional spur very close to the carrier. It is worth looking at this point on an analyser. If it disturbs the f5 and f6 bits, change `ADF_REF_KHZ` and `ADF_R_COUNTER`.
- **The module crystal.** 25 MHz is still assumed; check your module. Its tolerance (±20–50 ppm is common) shifts the band by 17–43 kHz, which is small against the ±100 kHz search window around each bit.
- **ADF4351 loop filter.** The 200 µs settle time assumes a typical module. If the sweep shows steps or the unlocked count is not zero, raise it on Reader Setup.
- **MAX2235 match.** The datasheet circuit is matched at 836 MHz. Check the output inductor on your board for 860–865 MHz.
- **Output power control.** The MAX2235's GC pin has a 37 dB range, which is real gain control, unlike the ADF4351 level. It is left unconnected, per the datasheet circuit. If you want to control TX power properly, this is the pin to use, driven from the STM32 DAC (PA4 or PA5, both shared with on-board parts on this board, so it needs checking).

---

## 6. What has and hasn't been tested

| Tested | How |
|---|---|
| Firmware core: CRC, parser, register maths over 4,768 frequencies, RF levels, database | `make -C firmware/host test`, 22/22 |
| Every command, 10-bit decode, formats, database, calibration, AUTO mode | `tools/e2e_test.py` on the virtual reader, 61/61 |
| Swift SDK | `swift test --filter ChiplessKitTests`, 10/10 |
| The Mac app, driven on screen in Demo Mode: read, setup, database, calibration, old-firmware and unplug cases | Manual and scripted runs |
| The STM32 firmware builds and links, simulated and hardware versions, with the memory layout as designed | GCC 14.2 and CubeIDE 1.19's GCC 13.3: about 7 % of flash and 24 % of RAM, 0 errors, 0 warnings |
| The simulated-radio firmware on a real STM32F407G-DISC1: flashing, startup, USB link to the app, 10-bit sweep and decode (201 points in 100 ms on the chip), database lookup | Run from the Mac app |
| Flash storage on the real chip: a tag added and saved was still there after unplugging the board | Run from the Mac app |
| Every command on the real chip: bad frames, 10-bit decode, formats, database, calibration, AUTO mode | `tools/e2e_test.py --port` on the board, 61/61 |

| **Not** tested | Why |
|---|---|
| The hardware firmware (`prebuilt/hw`) on the board | Needs the RF parts |
| Real SPI traffic into the ADF4351 and PE4312, and lock detect | Not wired yet; the simulated build does drive the pins, but nothing has checked them |
| Real AD8302 readings through ADC1 + ADC2 simultaneous sampling | The ADCs start up on the board, but the simulated build doesn't read them |
| Any real RF part or real tag | Not wired yet |
