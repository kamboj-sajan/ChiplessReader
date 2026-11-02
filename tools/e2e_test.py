#!/usr/bin/env python3
"""
e2e_test.py - end-to-end acceptance test for the chipless reader protocol.

Runs against the virtual reader (default /tmp/chipless-reader) or the STM32 built with the
simulated RF backend (--port /dev/cu.usbmodemXXXX). Prints PASS/FAIL per check.

    python3 tools/e2e_test.py [--port PATH]
"""
import argparse, os, struct, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from chipless import Reader, ReaderError, build, cell_bits, crc16  # noqa: E402

results = []


def check(name, cond, detail=""):
    results.append(bool(cond))
    print(f"  {'PASS' if cond else 'FAIL'}  {name}" + (f"  ({detail})" if detail else ""))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="/tmp/chipless-reader")
    a = ap.parse_args()
    r = Reader(a.port)

    def raw(b, wait=0.6):
        os.write(r.fd, b)
        return r._read_frames(wait)

    print("Protocol")
    check("CRC-16/CCITT-FALSE check value", crc16(b"123456789") == 0x29B1)
    check("GET_INFO byte vector", build(0x01) == bytes.fromhex("A5040001003E2E"))
    info = r.info()
    check("GET_INFO", info["model"] == "CHIPLESS-R1", f"{info['model']} fw {info['fw']} sim={info['sim']}")
    check("PING x50", all(r.ping(i * 7919) == i * 7919 for i in range(50)))
    f = raw(bytes.fromhex("A508002000E8320D00A818"))
    check("corrupted CRC -> CRC_ERROR", f and f[0][1] == 1)
    f = raw(build(0x2F))
    check("unknown command -> UNKNOWN_CMD", f and f[0][:2] == (0xAF, 2))
    f = raw(build(0x45))
    check("command >= 0x40 -> reply 0xBF", f and f[0][:2] == (0xBF, 2))
    f = raw(build(0x20, b"\x01\x02"))
    check("bad payload length -> BAD_LENGTH", f and f[0][1] == 3)
    fr = build(0x02, struct.pack("<I", 0xCAFEBABE))
    os.write(r.fd, fr[:3]); time.sleep(0.05); os.write(r.fd, fr[3:8]); time.sleep(0.05)
    f = raw(fr[8:])
    check("frame split across 3 writes", f and f[0][2] == struct.pack("<I", 0xCAFEBABE))
    f = raw(build(0x02, b"\x01\0\0\0") + build(0x02, b"\x02\0\0\0")) + r._read_frames(0.3)
    check("two frames in one write", [x[2][0] for x in f] == [1, 2])
    # over real USB the CRC_ERROR reply and the PING reply arrive separately, so read twice
    f = raw(bytes([0x11, 0xA5, 0x05, 0x00, 0x33]) + build(0x02, b"\x09\x09\x09\x09")) + r._read_frames(0.3)
    check("garbage then valid frame (resync)", any(c == 0x82 for c, s, p in f))

    print("RF configuration")
    lo = r.set_lo(865000)
    check("SET_LO 865 MHz locks", lo["locked"] and lo["actual_hz"] == 865_000_000)
    check("ADF4351 registers", lo["regs"] == ["0x00450010", "0x08008029", "0x18004E42", "0x000004B3", "0x00AC803C", "0x00580005"],
          " ".join(lo["regs"]))
    lo2 = r.set_lo(433920)
    check("SET_LO 433.92 MHz (RF divider 8)", lo2["locked"] and lo2["rf_div"] == 8 and lo2["actual_hz"] == 433_920_000)
    try:
        r.set_lo(5_000_000); check("SET_LO 5 GHz rejected", False)
    except ReaderError as e:
        check("SET_LO 5 GHz rejected", e.status == 4)
    r.set_lo(862500)
    check("SET_TX_POWER +5 dBm: MAX2235 curve gives ~30 dBm", r.set_tx_power(3, 1)[2] == 300, f"{r.set_tx_power(3, 1)[2] / 10} dBm")
    low = r.set_tx_power(0, 1)[2]
    check("PA compresses: 9 dB of drive moves the output ~3 dB", 20 < 300 - low < 40, f"-4 dBm drive gives {low / 10} dBm")
    r.set_tx_power(3, 1)
    a48 = r.set_atten(48)
    check("SET_RX_CONFIG 24 dB puts INPA inside the AD8302 range", a48[1] == -149, f"{a48[1] / 10} dBm, minimum setting {a48[2] / 2} dB")
    try:
        r.set_atten(0); check("attenuator refused below the AD8302 0 dBm limit", False)
    except ReaderError as e:
        check("attenuator refused below the AD8302 0 dBm limit", e.status == 4)
    m = r.measure()
    check("MEASURE (12-bit ADC -> AD8302 -> dBm)", 0 < m["adc_mag"] < 4096 and not m["clipped"], f"ADC {m['adc_mag']}, RSSI {m['rssi_dbm']} dBm")
    try:
        r.set_sweep(860000, 865000, 5); check("SET_SWEEP > 512 points rejected", False)
    except ReaderError as e:
        check("SET_SWEEP > 512 points rejected", e.status == 4)

    print("Tag profile: 10 bits across 860-865 MHz")
    pr = r.get_profile()
    check("default profile is 860-865 MHz, 25 kHz steps", (pr["start"], pr["stop"], pr["step"]) == (860000, 865000, 25), pr["name"])
    check("default has 10 bit frequencies, 500 kHz apart", pr["bits"] == cell_bits(10) and pr["bits"][0] == 860250 and pr["bits"][9] == 864750)
    check("SET_SWEEP 860-865 MHz / 25 kHz = 201 points", r.set_sweep(860000, 865000, 25)[3] == 201)
    try:
        r.set_profile("bad", 860000, 865000, 25, [870000]); check("bit outside the sweep rejected", False)
    except ReaderError as e:
        check("bit outside the sweep rejected", e.status == 4)
    pr2 = r.set_profile("rate test", 860000, 865000, 25, cell_bits(10), settle=300, avg=4, interval_ms=500)
    check("profile carries sweep, frequencies and read rate", (pr2["name"], pr2["settle"], pr2["avg"], pr2["interval_ms"]) == ("rate test", 300, 4, 500))
    r.set_profile("10-bit 860-865", 860000, 865000, 25, cell_bits(10))

    print("Tag reading (simulated front-end)")
    sim = r.sim_get()
    r.sim_set(-1, 20, 5, 2000)
    check("no tag -> not found", not r.read_tag()["found"])
    check("background capture", r.capture_bg()[0] == 201)
    for i, (name, code, nb) in enumerate(sim["tags"]):
        if nb != 10:
            continue
        r.sim_set(i, 20, 5, 2000)
        rep = r.read_tag()
        check(f"{name} decodes as {rep['bits']}", rep["found"] and rep["id"] == code and rep["name"] == name, f"database says {rep['name'] or 'unknown'}, margin {rep['margin_db']} dB")
    ten_a = next(i for i, t in enumerate(sim["tags"]) if t[0] == "TEN-A")
    r.sim_set(ten_a, 20, 5, 2000)
    rep = r.read_tag()
    check("the pattern from the notes reads 1010110011", rep["bits"] == "1010110011" and rep["id"] == 0x335)
    ones = [k for k in range(10) if rep["bits"][k] == "1"]
    zeros = [k for k in range(10) if rep["bits"][k] == "0"]
    check("phase swings wider at the notches than at the gaps", min(rep["swings_deg"][k] for k in ones) > max(rep["swings_deg"][k] for k in zeros),
          f"notch {min(rep['swings_deg'][k] for k in ones)} deg, gap {max(rep['swings_deg'][k] for k in zeros)} deg")
    pts = r.sweep_data()
    check("GET_SWEEP_DATA (2 chunks)", len(pts) == 201 and pts[0][3] is not None)
    r.sim_set(ten_a, 90, 5, 2000)
    check("90 cm: beyond read range", r.read_tag()["id"] != 0x335)

    print("Single, double and ten-bit formats")
    for n, tname, want in [(1, "SINGLE-1", "1"), (2, "DOUBLE-10", "10")]:
        r.set_profile(f"{n}-bit", 860000, 865000, 25, cell_bits(n))
        i = next(j for j, t in enumerate(sim["tags"]) if t[0] == tname)
        r.sim_set(-1, 20, 5, 2000); r.capture_bg()
        r.sim_set(i, 20, 5, 2000)
        rep = r.read_tag()
        check(f"{tname} reads {want}", rep["bits"] == want and rep["name"] == tname, f"margin {rep['margin_db']} dB")
    r.set_profile("10-bit 860-865", 860000, 865000, 25, cell_bits(10))
    r.sim_set(-1, 20, 5, 2000); r.capture_bg()

    print("Tag database on the reader")
    before = r.db_list()
    check("simulator tags seeded", any(e["id"] == 0x335 and e["name"] == "TEN-A" for e in before), f"{len(before)} entries, capacity {r.db_info()[1]}")
    r.db_put(0x2AA, 10, "MY TAG")
    check("DB_PUT adds an entry", any(e["id"] == 0x2AA and e["name"] == "MY TAG" for e in r.db_list()))
    r.db_put(0x2AA, 10, "RENAMED")
    check("DB_PUT again renames it", sum(e["id"] == 0x2AA and e["n_bits"] == 10 for e in r.db_list()) == 1 and any(e["name"] == "RENAMED" for e in r.db_list()))
    r.db_delete(0x2AA, 10)
    check("DB_DELETE removes it", not any(e["id"] == 0x2AA for e in r.db_list()))
    try:
        r.db_put(0x400, 10, "too wide"); check("ID wider than its format rejected", False)
    except ReaderError as e:
        check("ID wider than its format rejected", e.status == 4)
    r.db_delete(0x335, 10)
    r.sim_set(ten_a, 20, 5, 2000)
    rep = r.read_tag()
    check("decoded tag not in database is reported as unknown", rep["found"] and not rep["matched"] and rep["db_index"] == -1 and rep["bits"] == "1010110011")
    r.db_put(0x335, 10, "TEN-A")
    r.set_profile("10-bit 860-865", 860000, 865000, 25, cell_bits(10), max_bit_errors=1)
    r.db_delete(0x335, 10)
    r.db_put(0x337, 10, "CLOSE")
    rep = r.read_tag()
    check("match within 1 bit when the profile allows it", rep["matched"] and rep["name"] == "CLOSE" and rep["bit_errors"] == 1)
    r.db_delete(0x337, 10)
    r.db_put(0x335, 10, "TEN-A")
    r.set_profile("10-bit 860-865", 860000, 865000, 25, cell_bits(10))

    print("Attenuation calibration")
    scan = r.atten_scan(4)
    check("attenuator scan starts at the safe minimum", scan[0]["inpa_dbm"] <= 0 and len(scan) > 5, f"{scan[0]['atten_db']} to {scan[-1]['atten_db']} dB, {len(scan)} points")
    slope = (scan[0]["vmag_mv"] - scan[-1]["vmag_mv"]) / (scan[-1]["atten_db"] - scan[0]["atten_db"])
    check("VMAG follows the attenuator at the AD8302 slope", 26 < slope < 31, f"{slope:.1f} mV/dB")
    check("scan restores the setting", r.config()["ref_atten_half_db"] == 48)
    level = r.auto_level()
    centre = (level["gain_min_db"] + level["gain_max_db"]) / 2
    check("auto-level centres the AD8302", abs(centre) < 1.0 and level["clipped"] == 0, f"{level['old_db']} -> {level['new_db']} dB, gain {level['gain_min_db']:+.1f}..{level['gain_max_db']:+.1f} dB")
    check("auto-level keeps INPA inside the AD8302 range", -60 <= level["inpa_dbm"] <= 0, f"{level['inpa_dbm']} dBm")
    rep = r.read_tag()
    check("still reads the tag after auto-level", rep["id"] == 0x335, f"margin {rep['margin_db']} dB")
    r.set_atten(48)
    cal = r.get_cal()
    check("calibration starts from the datasheet values", cal["coupler_db"] == 19.7 and cal["lna_gain_db"] == 19.5 and cal["vmag_slope_mv_db"] == 28.7)
    before_rssi = r.measure()["rssi_dbm"]
    trimmed = dict(cal, rssi_trim_db=-2.0)
    r.set_cal(trimmed)
    after_rssi = r.measure()["rssi_dbm"]
    check("SET_CAL changes the reported level", abs((before_rssi - after_rssi) - 2.0) < 0.5, f"{before_rssi} -> {after_rssi} dBm")
    r.set_cal(cal)
    try:
        r.set_cal(dict(cal, vmag_slope_mv_db=0)); check("zero slope rejected", False)
    except ReaderError as e:
        check("zero slope rejected", e.status == 4)
    check("carrier on and off", r.set_carrier(True) == 1 and r.set_carrier(False) == 0)

    print("AUTO mode")
    b_index = next(i for i, t in enumerate(sim["tags"]) if t[0] == "TEN-B")
    r.sim_set(b_index, 20, 5, 2000)
    r.set_mode(1, 200)
    try:
        r.set_lo(866000); check("config refused in AUTO", False)
    except ReaderError as e:
        check("config refused in AUTO (BUSY)", e.status == 5)
    try:
        r.db_clear(); check("database edit refused in AUTO", False)
    except ReaderError as e:
        check("database edit refused in AUTO (BUSY)", e.status == 5)
    got = []
    t0 = time.time()
    while time.time() - t0 < 1.5:
        e = r.wait_event(0.4)
        if e: got.append(Reader.parse_report(e[1]))
    r.set_mode(0)
    check("TAG_REPORT events pushed", len(got) >= 4 and all(x["name"] == "TEN-B" for x in got), f"{len(got)} reports")
    st = r.status()
    check("GET_STATUS back in RESPONSE", st["mode"] == "RESPONSE")
    r.sim_set(ten_a, 20, 5, 2000)
    r.nv_save()
    check("NV_SAVE accepted", True)

    n, p = len(results), sum(results)
    print(f"\n{p}/{n} checks passed")
    sys.exit(0 if p == n else 1)


if __name__ == "__main__":
    main()
