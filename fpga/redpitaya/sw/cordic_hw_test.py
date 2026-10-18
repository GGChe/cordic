#!/usr/bin/env python3
"""
Hardware test of the CORDIC cores on the Red Pitaya (run on the board as root).

Loads cordic_rp.bit.bin, then drives `cordic_axi_regs` at 0x4000_0000 through
/dev/mem and checks both cores against exact math (testbench tolerances),
plus burst throughput and the FCLK0 frequency. Standard library only.

Never access 0x4000_0000 unless this bitstream is loaded: an unanswered GP0
access freezes the board. Web apps and other notebooks reload the FPGA, so
the script always loads the bitstream first (--no-load skips it).

    python3 cordic_hw_test.py [--n 20000] [--info] [--no-load]

Exit code 0 on success. LED[7:4] show 1010 on success, 1111 on failure.
"""

import argparse
import math
import mmap
import os
import random
import shutil
import subprocess
import sys
import time

BASE = 0x4000_0000
SPAN = 0x1000

# Register offsets (see rtl/cordic_axi_regs.v)
ID, VERSION, SCRATCH, CYCLES = 0x000, 0x004, 0x008, 0x00C
C_CTRL, C_STATUS, C_X_IN, C_Y_IN, C_PHASE_IN = 0x100, 0x104, 0x108, 0x10C, 0x110
C_X_OUT, C_Y_OUT, C_PHASE_OUT, C_CYCLES, C_COUNT, C_BURST_N = 0x114, 0x118, 0x11C, 0x120, 0x124, 0x128
S_CTRL, S_STATUS, S_RAD_IN, S_ROOT_OUT, S_CYCLES, S_COUNT, S_BURST_N = 0x200, 0x204, 0x208, 0x20C, 0x210, 0x214, 0x218

EXPECTED_ID = 0x4352_4443  # "CRDC"

# Circular core configuration (cordic_top defaults)
INOUT_WIDTH, PHASE_WIDTH, N_ITER = 16, 18, 16
PI_FIXED = 1 << (PHASE_WIDTH - 1)
Q_MAX, Q_MIN = (1 << (INOUT_WIDTH - 1)) - 1, -(1 << (INOUT_WIDTH - 1))
K = 1.0
for _i in range(N_ITER):
    K *= math.sqrt(1.0 + 2.0 ** (-2 * _i))
INV_K = round((1 << (INOUT_WIDTH - 1)) / K)

TOL_CIRCULAR = 2      # LSB (Q1.15)
TOL_PHASE = 16        # LSB of the residual phase
TOL_SQRT = 1          # LSB (Q16.16)

# Zynq PSS_IDCODE device codes (UG585)
ZYNQ_DEVICES = {0x02: "7z010", 0x07: "7z020", 0x0C: "7z030", 0x03: "7z007s",
                0x1C: "7z012s", 0x08: "7z014s", 0x1B: "7z015"}


class Regs:
    """32-bit register access through /dev/mem."""

    def __init__(self, base=BASE, span=SPAN):
        self.fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
        self.mm = mmap.mmap(self.fd, span, mmap.MAP_SHARED,
                            mmap.PROT_READ | mmap.PROT_WRITE, offset=base)
        self.words = memoryview(self.mm).cast("I")   # aligned 32-bit accesses

    def rd(self, off):
        return self.words[off >> 2]

    def wr(self, off, value):
        self.words[off >> 2] = value & 0xFFFF_FFFF

    def close(self):
        self.words.release()
        self.mm.close()
        os.close(self.fd)


def signed(v, bits=32):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


def board_info():
    """Zynq device from PSS_IDCODE (SLCR, read-only access)."""
    try:
        fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
        mm = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ, offset=0xF800_0000)
        idcode = memoryview(mm).cast("I")[0x530 >> 2]
        mm.close()
        os.close(fd)
        dev = (idcode >> 12) & 0x1F
        return idcode, ZYNQ_DEVICES.get(dev, f"unknown (0x{dev:02x})")
    except OSError as exc:
        return None, f"unavailable ({exc})"


# ── Reference models ─────────────────────────────────────────────────────────

def deg_to_phase(deg):
    p = round(deg / 180.0 * PI_FIXED)
    return ((p + PI_FIXED) % (2 * PI_FIXED)) - PI_FIXED


def expected_rotation(x, y, phase):
    z = phase * math.pi / PI_FIXED
    xr = K * (x * math.cos(z) - y * math.sin(z))
    yr = K * (y * math.cos(z) + x * math.sin(z))
    sat = lambda v: max(Q_MIN, min(Q_MAX, int(math.floor(v + 0.5))))
    return sat(xr), sat(yr)


def expected_root(rad):
    """round(√rad · 2^16) exactly, saturated to 32 bits."""
    n = rad << 32
    r = math.isqrt(n)
    if n - r * r > r:          # (r + ½)² < n  →  round up
        r += 1
    return min(r, 0xFFFF_FFFF)


# ── Operations ───────────────────────────────────────────────────────────────

def wait_done(regs, status, timeout=1.0):
    t0 = time.monotonic()
    while not (regs.rd(status) & 0x2):
        if time.monotonic() - t0 > timeout:
            raise TimeoutError(f"timeout waiting for done (status reg 0x{status:03x})")


def rotate(regs, x, y, phase):
    regs.wr(C_X_IN, x)
    regs.wr(C_Y_IN, y)
    regs.wr(C_PHASE_IN, phase)
    regs.wr(C_CTRL, 0x1)
    wait_done(regs, C_STATUS)
    return signed(regs.rd(C_X_OUT)), signed(regs.rd(C_Y_OUT)), signed(regs.rd(C_PHASE_OUT))


def sqrt_hw(regs, rad):
    regs.wr(S_RAD_IN, rad)
    regs.wr(S_CTRL, 0x1)
    wait_done(regs, S_STATUS)
    return regs.rd(S_ROOT_OUT)


def burst(regs, ctrl, status, burst_n_reg, cycles_reg, count_reg, n):
    c0 = regs.rd(count_reg)
    regs.wr(burst_n_reg, n)
    regs.wr(ctrl, 0x2)
    wait_done(regs, status)
    cycles = regs.rd(cycles_reg)
    produced = (regs.rd(count_reg) - c0) & 0xFFFF_FFFF
    return cycles, produced


# ── Test suites ──────────────────────────────────────────────────────────────

class Result:
    def __init__(self, name):
        self.name, self.n, self.fail, self.max_err = name, 0, 0, 0
        self.examples = []

    def check(self, err, tol, msg):
        self.n += 1
        self.max_err = max(self.max_err, err)
        if err > tol:
            self.fail += 1
            if len(self.examples) < 5:
                self.examples.append(msg)

    def report(self, unit):
        status = "PASS" if self.fail == 0 else "FAIL"
        print(f"  [{status}] {self.name}: {self.n} vectors, max error {self.max_err} {unit}, "
              f"{self.fail} failures")
        for e in self.examples:
            print(f"         {e}")
        return self.fail == 0


def test_circular(regs, rng, n_random):
    res = Result("circular CORDIC")
    vectors = [(INV_K, 0, deg_to_phase(d)) for d in
               (0, 10, 30, 45, 60, 90, -90, -180, 179.9, -179.9, 100, -100, 120, 135, 170, -150)]
    vectors += [(INV_K, 0, deg_to_phase(d)) for d in range(-180, 180)]
    vectors += [(29491, 0, 0), (29491, 0, deg_to_phase(180)), (32767, 32767, deg_to_phase(45)),
                (-32768, 0, 0), (-32768, 0, deg_to_phase(180))]
    vectors += [(rng.randint(-13000, 13000), rng.randint(-13000, 13000),
                 rng.randint(-PI_FIXED, PI_FIXED - 1)) for _ in range(n_random)]
    max_phase = 0
    for x, y, z in vectors:
        xo, yo, zo = rotate(regs, x, y, z)
        xe, ye = expected_rotation(x, y, z)
        err = max(abs(xo - xe), abs(yo - ye))
        res.check(err, TOL_CIRCULAR,
                  f"x0={x} y0={y} z0={z}: got ({xo}, {yo}), expected ({xe}, {ye})")
        max_phase = max(max_phase, abs(zo))
        if abs(zo) > TOL_PHASE:
            res.check(TOL_CIRCULAR + 1, TOL_CIRCULAR, f"x0={x} y0={y} z0={z}: residual phase {zo}")
    ok = res.report("LSB")
    print(f"         max residual phase {max_phase} LSB")
    return ok


def test_sqrt(regs, rng, n_random):
    res = Result("square root (Q16.16)")
    vectors = [0, 1, 2, 3, 4, 9, 16, 25, 100, 10000, 1000000,
               0x7FFF_FFFF, 0xFFFE_0001, 0xFFFF_FFFE, 0xFFFF_FFFF]
    for k in range(1, 32):
        vectors += [(1 << k) - 1, 1 << k, (1 << k) + 1]
    vectors += [rng.getrandbits(32) for _ in range(n_random)]
    for rad in vectors:
        got = sqrt_hw(regs, rad)
        exp = expected_root(rad)
        res.check(abs(got - exp), TOL_SQRT,
                  f"sqrt({rad}): got {got} ({got / 65536:.6f}), expected {exp} ({exp / 65536:.6f})")
    return res.report("LSB")


def test_bursts(regs, fclk_hz):
    ok = True
    for name, regset in (
        ("circular", (C_CTRL, C_STATUS, C_BURST_N, C_CYCLES, C_COUNT)),
        ("sqrt",     (S_CTRL, S_STATUS, S_BURST_N, S_CYCLES, S_COUNT)),
    ):
        n = 10000
        cycles, produced = burst(regs, *regset, n)
        per = cycles / max(produced, 1)
        rate = fclk_hz / per / 1e6 if fclk_hz else 0.0
        good = produced == n
        ok &= good
        print(f"  [{'PASS' if good else 'FAIL'}] {name} burst: {produced}/{n} results in {cycles} cycles "
              f"→ {per:.2f} cycles/result ≈ {rate:.2f} Mresults/s")
    return ok


def measure_fclk(regs, seconds=0.5):
    c0, t0 = regs.rd(CYCLES), time.monotonic()
    time.sleep(seconds)
    c1, t1 = regs.rd(CYCLES), time.monotonic()
    return ((c1 - c0) & 0xFFFF_FFFF) / (t1 - t0)


DEFAULT_BITSTREAM = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cordic_rp.bit.bin")


def load_bitstream(path=DEFAULT_BITSTREAM):
    """Program the PL with fpgautil. Must run before any access to 0x4000_0000."""
    tool = shutil.which("fpgautil") or "/opt/redpitaya/bin/fpgautil"
    if not os.path.exists(path):
        raise FileNotFoundError(f"bitstream not found: {path}")
    out = subprocess.run([tool, "-b", path], capture_output=True, text=True)
    if out.returncode != 0 or "successfully" not in out.stdout:
        raise RuntimeError(f"fpgautil failed:\n{out.stdout}{out.stderr}")


def main():
    ap = argparse.ArgumentParser(description="CORDIC hardware test on the Red Pitaya")
    ap.add_argument("--n", type=int, default=2000, help="random vectors per core (default 2000)")
    ap.add_argument("--seed", type=int, default=0xC0D1C, help="random seed")
    ap.add_argument("--info", action="store_true", help="print board info only")
    ap.add_argument("--bitstream", default=DEFAULT_BITSTREAM, help="bitstream to load (.bit.bin)")
    ap.add_argument("--no-load", action="store_true",
                    help="do not load the bitstream (UNSAFE unless it is already loaded)")
    args = ap.parse_args()

    if os.geteuid() != 0:
        print("This script needs root (it maps /dev/mem).", file=sys.stderr)
        return 1

    idcode, device = board_info()
    print("=" * 72)
    print("  CORDIC hardware test — Red Pitaya")
    print(f"  Zynq device: {device}" + (f" (PSS_IDCODE 0x{idcode:08x})" if idcode is not None else ""))
    if args.info:
        return 0

    if not args.no_load:
        load_bitstream(args.bitstream)
        print(f"  Loaded {os.path.basename(args.bitstream)} with fpgautil")
    regs = Regs()
    try:
        ident = regs.rd(ID)
        if ident != EXPECTED_ID:
            print(f"  ID register reads 0x{ident:08x}, expected 0x{EXPECTED_ID:08x}.")
            print("  Is cordic_rp.bit.bin loaded? (fpgautil -b cordic_rp.bit.bin)")
            return 1
        ver = regs.rd(VERSION)
        fclk = measure_fclk(regs)
        print(f"  Bitstream ID OK, version {ver >> 16}.{ver & 0xFFFF}, FCLK0 ≈ {fclk / 1e6:.2f} MHz")
        print(f"  Random vectors per core: {args.n}, seed 0x{args.seed:x}")
        print("=" * 72)

        regs.wr(SCRATCH, 0x0)
        rng = random.Random(args.seed)
        t0 = time.monotonic()
        ok = test_circular(regs, rng, args.n)
        ok &= test_sqrt(regs, rng, args.n)
        ok &= test_bursts(regs, fclk)
        elapsed = time.monotonic() - t0

        print("=" * 72)
        print(f"  {'ALL TESTS PASSED' if ok else 'SOME TESTS FAILED'} ({elapsed:.1f} s)")
        print("=" * 72)
        regs.wr(SCRATCH, 0xA if ok else 0xF)   # LED[7:4]
        return 0 if ok else 1
    finally:
        regs.close()


if __name__ == "__main__":
    sys.exit(main())
