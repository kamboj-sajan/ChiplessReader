# Chipless RFID Reader

A Mac app and STM32 firmware that read chipless tags: **10 bits across 860–865 MHz**. The STM32 sets the gain and the frequency sweep, compares magnitude and phase from the AD8302 at each bit frequency, and looks the pattern up in a tag database it holds itself.

```text
 Chipless Reader.app                                 STM32F407 (firmware/)
┌──────────────────────────┐   frames over USB   ┌──────────────────────────────────────────────┐
│ Read Tags                │  ◀═══════════════▶  │ protocol, commands                           │
│ Reader Setup             │   micro-USB (CN5)   │ reader     sweep, magnitude + phase, bit      │
│ Tag Database             │                     │ tagdb      database, stored in flash          │
│ Calibration              │                     │ adf4351    R0–R5 over SPI                     │
│ Log                      │                     │ rf_hw      LD pin, VMAG on ADC1, VPHS on ADC2 │
└──────────────────────────┘                     │ rf_sim     simulated RF chain and tags        │
                                                 └──────────────────────────────────────────────┘
```

**Read [docs/DESIGN_NOTES.md](docs/DESIGN_NOTES.md) before wiring the RF parts.** It covers what the datasheets require, the antenna isolation needed to protect the AD8302, and the resonator Q that 10 bits in 5 MHz demands.

---

## Using the app

Open **`dist/Chipless Reader.app`**, or open `dist/Chipless-Reader.dmg` and drag the app to Applications. It needs macOS 14 or newer. No Terminal is involved.

The copy is signed for this Mac only. The first time you open it on another Mac, right-click it and choose **Open**.

**With the board:** connect the micro-USB port (CN5). The app finds the reader by itself, including when you plug it in later.

**Without the board:** press **Try Demo Mode**. The same firmware then runs on the Mac with a simulated radio and tags, and Log shows what it would print on the board.

| Screen | What it's for |
|---|---|
| **Read Tags** | Read once or continuously. Shows the name from the database, each bit, its notch depth and phase swing, and the sweep. In Demo Mode you can also choose the tag, distance and resonator Q |
| **Reader Setup** | Tag format (single, double, ten-bit or custom), bit frequencies, frequency sweep, gain, read rate, bit decision |
| **Tag Database** | The tags the STM32 identifies against: add, edit, delete, import, export |
| **Calibration** | PE4312 attenuator, both AD8302 inputs against their −60 to 0 dBm range, Auto-level, attenuator scan, RF chain values, single tone |
| **Log** | What happened, optionally every frame in hex |

Changes take effect in the reader at once. **Save to Reader** stores settings, calibration and the database in the STM32's flash so they survive a power cycle.

A normal first read: **Capture Background** with no tag present, put the tag in place, then **Read Tag**.

---

## The STM32 code

Plain C. The reader itself is in `firmware/core` and runs unchanged on the board and in Demo Mode; `firmware/stm32` is what's specific to this board.

| File | What it does |
|---|---|
| `firmware/core/reader.c` | Sweep, background, notch and phase measurement, bit decision, Auto-level. Start here |
| `firmware/core/tagdb.c` | Tag database lookups |
| `firmware/core/calibration.c` | RF chain levels, including the MAX2235 datasheet curve and the attenuator's safe minimum |
| `firmware/core/adf4351.c` | ADF4351 R0–R5 calculation and programming |
| `firmware/core/commands.c` | One handler per command |
| `firmware/core/nvstore.c` | Stores settings, calibration and the database |
| `firmware/core/protocol.c`, `app.c` | Frames, CRC, main loop |
| `firmware/core/app_config.h` | Defaults and datasheet values, with their sources |
| `firmware/core/rf_hw.c` | Real hardware: lock-detect pin and the two ADCs |
| `firmware/core/rf_sim.c` | Simulated RF chain and tags |
| `firmware/stm32/Src/main.c` | Clocks, SPI2, ADC1 + ADC2 simultaneous mode, USB |
| `firmware/stm32/Src/platform_stm32.c` | SPI words, PE4312, PA pin, ADC read, flash |
| `firmware/stm32/Inc/board.h` | **Pin map and module settings** |

### Flashing

A board still on firmware 0.2 has to be reflashed, and the app will ask for this. Two ready-to-flash builds of 0.3 are in `firmware/stm32/prebuilt/`:

| File | Use it when |
|---|---|
| `chipless_reader.elf` | No RF parts yet: the radio and tags are simulated inside the STM32. **Flash this one first** |
| `hw/chipless_reader.elf` | The RF parts are wired as in the table below |

Flash from STM32CubeIDE:

1. **Run ▸ Debug Configurations ▸ STM32 C/C++ Application ▸ New**, set the application to the `.elf`, and tick **Disable auto build**.
2. On the Debugger tab choose **ST-LINK (ST-LINK GDB server)**, **SWD**.
3. **Debug**, then **Resume (F8)**. The green LED lights.

The firmware stays on the board after you unplug it.

### Building it yourself

In STM32CubeIDE: **File ▸ New ▸ Makefile Project with Existing Code**, choose `firmware/stm32` and the toolchain **MCU ARM GCC**, then **Project ▸ Build Project**. The result is `firmware/stm32/build/chipless_reader.elf`. For the real RF hardware, set the build command to `make BACKEND=HW`, and run `make clean` when switching between the two.

The board has two USB ports. **Mini-USB (CN1)** is the ST-LINK, for flashing and debugging. **Micro-USB (CN5)** is the link to the app. To see the firmware's log in CubeIDE, add `g_console` in **Live Expressions**.

### Wiring the RF parts

| Signal | STM32 pin | Module pin |
|---|---|---|
| SPI2 SCK | PB13 | ADF4351 CLK, PE4312 Clock |
| SPI2 MOSI | PB15 | ADF4351 DATA, PE4312 Data |
| ADF4351 LE | PB12 | LE |
| ADF4351 CE | PE9 | CE |
| ADF4351 LD | PE10 | LD |
| PE4312 LE | PE7 | LE (P/S high for serial mode) |
| PA enable | PE8 | MAX2235 SHDN |
| AD8302 VMAG | PA1 | ADC1_IN1 (VMAG shorted to MSET) |
| AD8302 VPHS | PB1 | ADC2_IN9 (VPHS shorted to PSET) |

---

## Changing and testing the software

These are for development. Nothing here is needed to use the app.

```sh
sh scripts/build_app.sh                       # rebuilds dist/Chipless Reader.app and the .dmg

make -C firmware/host test                    # firmware core: 22 checks, 4,768 synthesizer frequencies
cd firmware/host && make && ./build/chipless-vreader     # start the virtual reader, then in another window:
python3 tools/e2e_test.py                     # 61 end-to-end checks
python3 tools/q_study.py                      # read success against resonator Q
cd sdk/AltraReaderKit
swift test --filter ChiplessKitTests          # Swift SDK: 10 checks
swift run chiplesscli help                    # every command from the terminal, plus a scripted demo
```

### Using the SDK from your own Swift code

```swift
import ChiplessKit

let reader = ChiplessReader(port: ChiplessReader.findReaders().first!.port)
try reader.connect()
try reader.setProfile(.standard(bits: 10))         // 10 bits across 860-865 MHz
try reader.setTxPower(.plus5dBm, paEnabled: true)  // gain
try reader.setReferenceAttenuation(dB: 24)
try reader.putDatabaseEntry(TagDatabaseEntry(name: "Pallet 7", bitString: "1010110011")!)
try reader.saveToFlash()

try reader.captureBackground()                     // with no tag present
let tag = try reader.readTag()
print(tag.name, tag.bitString, tag.rssiDBm, tag.marginDB)
```

Types: `sdk/AltraReaderKit/Documentation/CHIPLESS.md`. Bytes on the wire: `docs/PROTOCOL.md`. The original Altra UHF code in `AltraReaderKit` is untouched.

---

## Status

The simulated-radio firmware runs on a real STM32F407G-DISC1: USB link, 10-bit decode, database lookup and flash storage all work from the Mac app. **Nothing has been tested with real RF parts or tags yet.** See [what has and hasn't been tested](docs/DESIGN_NOTES.md#6-what-has-and-hasnt-been-tested).

Still placeholders: the bit frequencies (replace with your tags' measured values), the RF chain values (datasheet figures until measured), and the simulated channel (isolation, echo level, notch depth).
