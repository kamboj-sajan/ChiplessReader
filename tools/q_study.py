#!/usr/bin/env python3
"""
q_study.py - how sharp do the tag's resonators have to be to read N bits in the 860-865 MHz band?

Runs on the virtual reader (simulated RF chain and tag). Every tag format in the simulator is read
at a range of resonator Q values and the fraction read correctly is printed.

    python3 tools/q_study.py [--port PATH] [--reads N] [--distance CM]
"""
import argparse, os, sys
sys.path.insert(0, os.path.dirname(__file__))
from chipless import Reader, cell_bits  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="/tmp/chipless-reader")
    ap.add_argument("--reads", type=int, default=5)
    ap.add_argument("--distance", type=int, default=20)
    a = ap.parse_args()
    r = Reader(a.port)
    tags = r.sim_get()["tags"]
    qs = [100, 250, 500, 750, 1000, 1250, 1500, 2000, 3000, 5000]
    print(f"Correct reads out of {a.reads * sum(1 for t in tags if t[2] == 10)} for ten-bit tags and {a.reads} for the others, at {a.distance} cm")
    print(f"{'Q':>6} {'bandwidth':>10} {'1 bit':>7} {'2 bits':>7} {'10 bits':>8}  mean margin (10 bits)")
    for q in qs:
        score = {1: 0, 2: 0, 10: 0}
        total = {1: 0, 2: 0, 10: 0}
        margin = 0.0
        for n in (1, 2, 10):
            r.set_profile(f"{n}-bit", 860000, 865000, 25, cell_bits(n))
            r.sim_set(-1, a.distance, 5, q)
            r.capture_bg()
            for i, (name, code, nb) in enumerate(tags):
                if nb != n:
                    continue
                r.sim_set(i, a.distance, 5, q)
                for _ in range(a.reads):
                    rep = r.read_tag()
                    total[n] += 1
                    score[n] += rep["found"] and rep["id"] == code
                    if n == 10:
                        margin += rep["margin_db"]
        print(f"{q:>6} {862.5 / q:>7.2f} MHz {score[1]:>3}/{total[1]:<3} {score[2]:>3}/{total[2]:<3} {score[10]:>3}/{total[10]:<3}  {margin / max(total[10], 1):>6.1f} dB")
    r.sim_set(2, 20, 5, 2000)


if __name__ == "__main__":
    main()
