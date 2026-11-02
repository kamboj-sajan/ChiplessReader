#!/usr/bin/env python3
"""
chipless.py - minimal Python client for the chipless reader protocol (bench / test tool).

No third-party packages: talks to the serial port with os + termios, so it works with the
STM32's /dev/cu.usbmodem* port and with the virtual reader's /tmp/chipless-reader.

    python3 tools/chipless.py --port /tmp/chipless-reader info
    python3 tools/chipless.py --port /tmp/chipless-reader set-lo 865000
    python3 tools/chipless.py --port /tmp/chipless-reader read
    python3 tools/chipless.py --port /tmp/chipless-reader raw "A5 04 00 01 00 3E 2E"
"""
import argparse, os, select, struct, sys, termios, time, tty

SYNC = 0xA5
STATUS = {0: "OK", 1: "CRC_ERROR", 2: "UNKNOWN_CMD", 3: "BAD_LENGTH", 4: "OUT_OF_RANGE",
          5: "BUSY", 6: "PLL_UNLOCKED", 7: "NOT_SUPPORTED", 8: "NV_ERROR"}


def crc16(data: bytes) -> int:
    c = 0xFFFF
    for b in data:
        c ^= b << 8
        for _ in range(8):
            c = ((c << 1) ^ 0x1021) & 0xFFFF if c & 0x8000 else (c << 1) & 0xFFFF
    return c


def build(cmd: int, payload: bytes = b"", status: int = 0) -> bytes:
    body = bytes([cmd, status]) + payload
    c = crc16(body)
    body += bytes([c & 0xFF, c >> 8])
    return bytes([SYNC, len(body) & 0xFF, len(body) >> 8]) + body


class ReaderError(Exception):
    def __init__(self, cmd, status):
        super().__init__(f"reader replied {STATUS.get(status, status)} to command 0x{cmd:02X}")
        self.status = status


class Reader:
    def __init__(self, port: str):
        self.fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        tty.setraw(self.fd)
        attrs = termios.tcgetattr(self.fd)
        attrs[4] = attrs[5] = termios.B115200
        termios.tcsetattr(self.fd, termios.TCSANOW, attrs)
        termios.tcflush(self.fd, termios.TCIOFLUSH)
        self.buf = bytearray()
        self.events = []

    def close(self):
        os.close(self.fd)

    def _read_frames(self, timeout):
        end = time.time() + timeout
        frames = []
        while not frames and time.time() < end:
            r, _, _ = select.select([self.fd], [], [], max(0.0, end - time.time()))
            if r:
                try:
                    self.buf += os.read(self.fd, 4096)
                except BlockingIOError:
                    pass
            while True:
                i = self.buf.find(SYNC)
                if i < 0:
                    self.buf.clear(); break
                del self.buf[:i]
                if len(self.buf) < 3: break
                ln = self.buf[1] | (self.buf[2] << 8)
                if ln < 4 or ln > 1023:
                    del self.buf[:1]; continue
                if len(self.buf) < 3 + ln: break
                body = bytes(self.buf[3:3 + ln]); del self.buf[:3 + ln]
                if crc16(body[:-2]) != (body[-2] | body[-1] << 8):
                    continue
                frames.append((body[0], body[1], body[2:-2]))
        return frames

    def request(self, cmd, payload=b"", timeout=3.0):
        os.write(self.fd, build(cmd, payload))
        end = time.time() + timeout
        while time.time() < end:
            for c, st, pl in self._read_frames(end - time.time()):
                if c == ((cmd | 0x80) if 0 < cmd < 0x40 else 0xBF):
                    if st != 0:
                        raise ReaderError(cmd, st)
                    return pl
                if c >= 0xC0:
                    self.events.append((c, pl))
        raise TimeoutError(f"no reply to command 0x{cmd:02X}")

    def wait_event(self, timeout):
        if self.events:
            return self.events.pop(0)
        for c, st, pl in self._read_frames(timeout):
            if c >= 0xC0:
                self.events.append((c, pl))
        return self.events.pop(0) if self.events else None

    # ---- typed commands ----
    def info(self):
        p = self.request(0x01)
        return dict(fw=f"{p[0]}.{p[1]}", hw=p[2], sim=bool(p[3]), uid=p[4:16].hex().upper(),
                    model=p[16:32].split(b"\0")[0].decode())

    def ping(self, token):
        return struct.unpack("<I", self.request(0x02, struct.pack("<I", token)))[0]

    def status(self):
        p = self.request(0x03)
        mode, locked, bg, lo, up, ok, err, reads, found, tx = struct.unpack("<BBBIIIIIIh", p)
        return dict(mode="AUTO" if mode else "RESPONSE", pll_locked=bool(locked), background=bool(bg),
                    lo_khz=lo, uptime_ms=up, frames_ok=ok, frames_err=err, reads=reads, tags_found=found,
                    tx_dbm=tx / 10)

    def config(self):
        p = self.request(0x0F)
        v = struct.unpack("<IIIIBBBHBHBBH", p)
        keys = ["lo_khz", "sweep_start_khz", "sweep_stop_khz", "sweep_step_khz", "tx_level", "pa_en",
                "ref_atten_half_db", "settle_us", "averages", "threshold_x10", "n_bits", "mode", "auto_interval_ms"]
        return dict(zip(keys, v))

    def set_lo(self, khz):
        p = self.request(0x20, struct.pack("<I", khz))
        f, locked, actual, n_int, frac, mod, div, vco = struct.unpack("<IBIHHHBI", p[:20])
        regs = struct.unpack("<6I", p[20:44])
        return dict(khz=f, locked=bool(locked), actual_hz=actual, int=n_int, frac=frac, mod=mod,
                    rf_div=div, vco_khz=vco, regs=[f"0x{r:08X}" for r in regs])

    def set_sweep(self, a, b, s):
        return struct.unpack("<IIIH", self.request(0x10, struct.pack("<III", a, b, s)))

    def set_tx_power(self, level, pa):
        return struct.unpack("<BBh", self.request(0x12, bytes([level, pa])))

    def set_atten(self, half_db):
        return struct.unpack("<BhB", self.request(0x14, bytes([half_db])))

    def set_mode(self, mode, interval_ms=250):
        return self.request(0x08, struct.pack("<BH", mode, interval_ms))

    def measure(self):
        p = self.request(0x21)
        v = struct.unpack("<IHHHHhHhhhBBB", p)
        return dict(lo_khz=v[0], adc_mag=v[1], adc_phs=v[2], vmag_mv=v[3], vphs_mv=v[4], gain_db=v[5] / 100,
                    phase_deg=v[6] / 10, p_ref_dbm=v[7] / 10, p_rx_dbm=v[8] / 10, rssi_dbm=v[9] / 10,
                    clipped=bool(v[10]), locked=bool(v[11]), flags=v[12])

    @staticmethod
    def parse_report(p):
        seq, found, nb, tid, rssi, ph, mg, ms, pts, bg, clip, unl = struct.unpack("<IBBIhHhHHBHH", p[:25])
        depths = [d / 10 for d in struct.unpack(f"<{nb}h", p[25:25 + 2 * nb])]
        swings = [d / 10 for d in struct.unpack(f"<{nb}h", p[25 + 2 * nb:25 + 4 * nb])]
        q = 25 + 4 * nb
        matched, bit_errors, db_index = struct.unpack("<BBh", p[q:q + 4])
        name = p[q + 4:q + 20].split(b"\0")[0].decode()
        return dict(seq=seq, found=bool(found), n_bits=nb, id=tid, swings_deg=swings, matched=bool(matched),
                    bit_errors=bit_errors, db_index=db_index, name=name,
                    bits="".join("1" if tid >> k & 1 else "0" for k in range(nb)),
                    rssi_dbm=rssi / 10, phase_deg=ph / 10, margin_db=mg / 10, sweep_ms=ms, points=pts,
                    bg_used=bool(bg), clipped=clip, unlocked=unl, depths_db=depths)

    def read_tag(self):
        return self.parse_report(self.request(0x30, timeout=10))

    def capture_bg(self):
        return struct.unpack("<HH", self.request(0x32, timeout=10))

    def clear_bg(self):
        self.request(0x33)

    def sweep_data(self):
        out, off = [], 0
        while True:
            p = self.request(0x31, struct.pack("<HH", off, 160))
            total, o, cnt, start, step, has_bg = struct.unpack("<HHHIIB", p[:15])
            for i in range(cnt):
                rx, ph, bg = struct.unpack("<hHh", p[15 + 6 * i:21 + 6 * i])
                out.append(((start + (o + i) * step) / 1000, rx / 100, ph / 10, None if bg == -32768 else bg / 100))
            off += cnt
            if off >= total or cnt == 0:
                return out

    # ---- tag profile: what the reader must know about the tags it reads ----
    def set_profile(self, name, start, stop, step, bits, settle=200, avg=8, threshold_x10=60, phase_thr_x10=150,
                    interval_ms=250, max_bit_errors=0):
        pl = name.encode()[:16].ljust(16, b"\0") + struct.pack("<IIIHBHHHBB", start, stop, step, settle, avg, threshold_x10,
                                                                 phase_thr_x10, interval_ms, max_bit_errors, len(bits))
        pl += b"".join(struct.pack("<I", f) for f in bits)
        return self.parse_profile(self.request(0x1A, pl))

    def get_profile(self):
        return self.parse_profile(self.request(0x1B))

    @staticmethod
    def parse_profile(p):
        v = struct.unpack("<IIIHBHHHBB", p[16:39])
        return dict(name=p[:16].split(b"\0")[0].decode(), start=v[0], stop=v[1], step=v[2], settle=v[3], avg=v[4],
                    threshold_x10=v[5], phase_thr_x10=v[6], interval_ms=v[7], max_bit_errors=v[8],
                    bits=list(struct.unpack(f"<{v[9]}I", p[39:39 + 4 * v[9]])))

    # ---- tag database on the STM32 ----
    def db_info(self):
        return struct.unpack("<HHB", self.request(0x24))

    def db_list(self):
        out = []
        for i in range(self.db_info()[0]):
            p = self.request(0x25, struct.pack("<H", i))
            idx, tid, nb = struct.unpack("<HIB", p[:7])
            out.append(dict(index=idx, id=tid, n_bits=nb, name=p[7:23].split(b"\0")[0].decode()))
        return out

    def db_put(self, tid, n_bits, name):
        return struct.unpack("<HH", self.request(0x26, struct.pack("<IB", tid, n_bits) + name.encode()[:16]))

    def db_delete(self, tid, n_bits):
        return struct.unpack("<H", self.request(0x27, struct.pack("<IB", tid, n_bits)))[0]

    def db_clear(self):
        self.request(0x28)

    def nv_save(self):
        self.request(0x06, timeout=6)

    # ---- calibration ----
    CAL_KEYS = ["tx_filter_il_db", "pa_trim_db", "coupler_db", "coupler_thru_db", "atten_il_db", "lna_gain_db",
                "rx_filter_il_db", "vmag_center_mv", "vmag_slope_mv_db", "vphs_center_mv", "vphs_slope_mv_deg",
                "rssi_trim_db"]

    def _parse_cal(self, p):
        v = [x / 100 for x in struct.unpack("<12h", p)]
        v[7] *= 10; v[9] *= 10
        return dict(zip(self.CAL_KEYS, v))

    def get_cal(self):
        return self._parse_cal(self.request(0x1F))

    def set_cal(self, cal):
        v = [cal[k] for k in self.CAL_KEYS]
        v[7] /= 10; v[9] /= 10
        return self._parse_cal(self.request(0x1E, struct.pack("<12h", *[round(x * 100) for x in v])))

    def atten_scan(self, step_half_db=4):
        p = self.request(0x22, bytes([step_half_db]), timeout=10)
        out = []
        for i in range(p[0]):
            a, mv, g, inpa, fl = struct.unpack("<BHhhB", p[1 + 8 * i:9 + 8 * i])
            out.append(dict(atten_db=a / 2, vmag_mv=mv, gain_db=g / 100, inpa_dbm=inpa / 10, flags=fl))
        return out

    def auto_level(self):
        v = struct.unpack("<BBhhhHBB", self.request(0x23, timeout=10))
        return dict(old_db=v[0] / 2, new_db=v[1] / 2, gain_min_db=v[2] / 100, gain_max_db=v[3] / 100,
                    inpa_dbm=v[4] / 10, clipped=v[5], flags=v[6], iterations=v[7])

    def set_carrier(self, on):
        return self.request(0x13, bytes([1 if on else 0]))[0]

    def sim_set(self, tag, distance_cm=20, noise_x100=5, q=None):
        pl = struct.pack("<bHH", tag, distance_cm, noise_x100)
        if q is not None:
            pl += struct.pack("<H", q)
        return self.request(0x3A, pl)

    def sim_get(self):
        p = self.request(0x3B)
        tag, dist, noise, q_res = struct.unpack("<bHHH", p[:7])
        nt = p[7]; q = 8
        tags = []
        for _ in range(nt):
            code = struct.unpack("<I", p[q:q + 4])[0]; name = p[q + 4:q + 16].split(b"\0")[0].decode(); nb = p[q + 16]; q += 17
            tags.append((name, code, nb))
        return dict(tag=tag, distance_cm=dist, noise_db=noise / 100, q=q_res, tags=tags)


def cell_bits(n, start=860000, stop=865000):
    """Bit frequencies for n equal cells across a band: one resonator at each cell centre (kHz)."""
    return [start + (stop - start) * (2 * k + 1) // (2 * n) for k in range(n)]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", default="/tmp/chipless-reader")
    ap.add_argument("cmd")
    ap.add_argument("args", nargs="*")
    a = ap.parse_args()
    r = Reader(a.port)
    try:
        if a.cmd == "info": print(r.info())
        elif a.cmd == "status": print(r.status())
        elif a.cmd == "config": print(r.config())
        elif a.cmd == "set-lo": print(r.set_lo(int(a.args[0])))
        elif a.cmd == "measure": print(r.measure())
        elif a.cmd == "read": print(r.read_tag())
        elif a.cmd == "bg": print(r.capture_bg())
        elif a.cmd == "sim": print(r.sim_set(int(a.args[0]), *(int(x) for x in a.args[1:])) and r.sim_get())
        elif a.cmd == "raw":
            os.write(r.fd, bytes.fromhex(a.args[0].replace(" ", "")))
            for c, st, pl in r._read_frames(2.0):
                print(f"cmd=0x{c:02X} status={STATUS.get(st, st)} payload={pl.hex(' ').upper()}")
        else: sys.exit(f"unknown command {a.cmd}")
    finally:
        r.close()


if __name__ == "__main__":
    main()
