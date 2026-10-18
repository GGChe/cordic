# =============================================================================
# Cocotb Testbench: test_cordic
# =============================================================================
# Tests the cordic_top module (cordic core + atan LUT) in circular rotation
# mode:
#   1. test_cordic_rotation      — the 8 reference angles of the Verilog tb
#   2. test_cordic_edge_angles   — 0°, ±90°, ±180°, outer quadrants
#   3. test_cordic_random_stream — random vectors streamed back-to-back with
#                                  random tvalid gaps and independent random
#                                  tready per output channel, checked by a
#                                  protocol monitor + scoreboard
#
# Expected values: K · rotate(x0, y0, z0), rounded and saturated to Q1.15,
# with K taken from the Python reference model (scripts/cordic.py).
# The residual phase output (PHASE_OUTPUT = 1, the default) is checked too.
#
# Fixed-Point Convention:
#   INOUT_WIDTH  = 16 → Q1.15 (1.0 = 32768)
#   PHASE_WIDTH  = 18 → pi = 2^17 = 131072
#
# CORDIC Gain K(16 iter) = 1.646760, so 1/K = 0.607253
# 1/K in Q1.15 = round(0.607253 * 32768) = 19898
# =============================================================================

import math
import os
import random
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "scripts"))
from cordic import get_cordic_gain  # noqa: E402  (reference model)

# ── Parameters matching the RTL ──────────────────────────────────────────────
INOUT_WIDTH = 16
PHASE_WIDTH = 18
N_ITER = 16

K = get_cordic_gain(m=1, n_iter=N_ITER)

# 1/K pre-scaled in Q1.15
INV_K = round((1 << (INOUT_WIDTH - 1)) / K)

# Pass/fail tolerance in fixed-point LSBs (same as Verilog tb)
TOLERANCE = 2
PHASE_TOLERANCE = 4

Q_MAX = (1 << (INOUT_WIDTH - 1)) - 1
Q_MIN = -(1 << (INOUT_WIDTH - 1))
PI_FIXED = 1 << (PHASE_WIDTH - 1)


# ── Helpers ──────────────────────────────────────────────────────────────────

def to_unsigned(val, bits):
    """Convert a signed Python int to the unsigned N-bit representation."""
    if val < 0:
        val += (1 << bits)
    return val & ((1 << bits) - 1)


def to_signed(val, bits):
    """Convert an unsigned N-bit value back to a signed Python int."""
    val = int(val) & ((1 << bits) - 1)
    if val >= (1 << (bits - 1)):
        val -= (1 << bits)
    return val


def deg_to_phase(deg):
    """Angle in degrees → fixed-point phase, wrapped into [−π, π)."""
    p = round(deg / 180.0 * PI_FIXED)
    return ((p + PI_FIXED) % (2 * PI_FIXED)) - PI_FIXED


def saturate(v):
    return max(Q_MIN, min(Q_MAX, round(v)))


def expected(x_in, y_in, phase_in):
    """Reference rotation: K · R(z) · (x, y), rounded and saturated."""
    z = phase_in * math.pi / PI_FIXED
    x = K * (x_in * math.cos(z) - y_in * math.sin(z))
    y = K * (y_in * math.cos(z) + x_in * math.sin(z))
    return saturate(x), saturate(y)


async def reset_dut(dut):
    """Apply reset and initialise all inputs."""
    dut.resetn.value = 0
    dut.s_axis_x_tdata.value = 0
    dut.s_axis_y_tdata.value = 0
    dut.s_axis_phase_tdata.value = 0
    dut.s_axis_x_tvalid.value = 0
    dut.s_axis_y_tvalid.value = 0
    dut.s_axis_phase_tvalid.value = 0
    dut.m_axis_x_tready.value = 1
    dut.m_axis_y_tready.value = 1
    dut.m_axis_phase_tready.value = 1

    # Hold reset for a few cycles
    for _ in range(4):
        await RisingEdge(dut.aclk)

    dut.resetn.value = 1
    await RisingEdge(dut.aclk)
    await RisingEdge(dut.aclk)


async def run_test(dut, x_in, y_in, phase_in, x_expected, y_expected, name):
    """
    Drive one CORDIC rotation and check the output.

    Parameters match the Verilog ``run_test`` task:
      x_in        – initial x (typically 1/K = 19898)
      y_in        – initial y (typically 0)
      phase_in    – target angle  (signed, PHASE_WIDTH bits)
      x_expected  – expected cos(angle) * 2^15
      y_expected  – expected sin(angle) * 2^15
      name        – descriptive label
    """

    # ── Drive inputs ──
    await RisingEdge(dut.aclk)
    dut.s_axis_x_tdata.value     = to_unsigned(x_in, INOUT_WIDTH)
    dut.s_axis_y_tdata.value     = to_unsigned(y_in, INOUT_WIDTH)
    dut.s_axis_phase_tdata.value = to_unsigned(phase_in, PHASE_WIDTH)
    dut.s_axis_x_tvalid.value     = 1
    dut.s_axis_y_tvalid.value     = 1
    dut.s_axis_phase_tvalid.value = 1

    # ── Wait for slave handshake (data accepted at the next edge) ──
    timeout = 100
    while True:
        await ReadOnly()
        accepted = int(dut.s_axis_x_tready.value)
        await RisingEdge(dut.aclk)
        if accepted:
            break
        timeout -= 1
        assert timeout > 0, f"{name}: Timed out waiting for slave handshake"

    # ── Deassert valid ──
    dut.s_axis_x_tvalid.value     = 0
    dut.s_axis_y_tvalid.value     = 0
    dut.s_axis_phase_tvalid.value = 0

    # ── Wait for output valid ──
    timeout = 100
    while True:
        await ReadOnly()
        if int(dut.m_axis_x_tvalid.value):
            break
        await RisingEdge(dut.aclk)
        timeout -= 1
        assert timeout > 0, f"{name}: Timed out waiting for output valid"

    # ── Read & convert outputs ──
    x_out = to_signed(dut.m_axis_x_tdata.value, INOUT_WIDTH)
    y_out = to_signed(dut.m_axis_y_tdata.value, INOUT_WIDTH)
    z_res = to_signed(dut.m_axis_phase_tdata.value, PHASE_WIDTH)

    # ── Error calculation ──
    x_err = abs(x_out - x_expected)
    y_err = abs(y_out - y_expected)

    # ── Report ──
    dut._log.info("-" * 60)
    dut._log.info(f"  Test: {name}")
    dut._log.info(f"  Input : x={x_in:6d}, y={y_in:6d}, phase={phase_in:7d}")
    dut._log.info(f"  Output: x={x_out:6d}, y={y_out:6d}")
    dut._log.info(f"  Expect: x={x_expected:6d}, y={y_expected:6d}")
    dut._log.info(f"  Error : x={x_err:6d}, y={y_err:6d} (tolerance={TOLERANCE})")

    # ── Assert ──
    assert x_err <= TOLERANCE, \
        f"{name}: x error {x_err} exceeds tolerance {TOLERANCE}"
    assert y_err <= TOLERANCE, \
        f"{name}: y error {y_err} exceeds tolerance {TOLERANCE}"
    assert abs(z_res) <= PHASE_TOLERANCE, \
        f"{name}: residual phase {z_res} exceeds tolerance {PHASE_TOLERANCE}"

    dut._log.info("  Result: PASS")

    # Let the master handshake complete (DUT returns to IDLE)
    await RisingEdge(dut.aclk)
    await RisingEdge(dut.aclk)


# ── Tests ────────────────────────────────────────────────────────────────────

@cocotb.test()
async def test_cordic_rotation(dut):
    """Test CORDIC circular rotation mode with 8 angle test cases."""

    # Start clock — 100 MHz (10 ns period)
    cocotb.start_soon(Clock(dut.aclk, 10, units="ns").start())

    # Reset
    await reset_dut(dut)

    dut._log.info("=" * 60)
    dut._log.info("  CORDIC Circular Rotation Mode — Cocotb Testbench")
    dut._log.info(f"  INOUT_WIDTH={INOUT_WIDTH}, PHASE_WIDTH={PHASE_WIDTH}")
    dut._log.info("  Fixed-point: 1.0 = 2^15 = 32768, pi = 2^17 = 131072")
    dut._log.info(f"  1/K = {INV_K} (pre-scaled input)")
    dut._log.info("=" * 60)

    # ── Test cases ───────────────────────────────────────────────
    # The 8 reference angles of the Verilog testbench (tb_cordic.v).
    # Phase = round(angle_deg / 180 * 2^17). Expected values include the
    # 1/K quantisation of the pre-scaled input (K · 19898 ≈ 32767.2).
    # ─────────────────────────────────────────────────────────────
    test_angles = [10, 15, 30, 45, 60, 75, -45, -60]

    pass_count = 0
    for deg in test_angles:
        phase_in = deg_to_phase(deg)
        x_exp, y_exp = expected(INV_K, 0, phase_in)
        await run_test(dut, INV_K, 0, phase_in, x_exp, y_exp, f"Rotate {deg} deg")
        pass_count += 1

    dut._log.info("=" * 60)
    dut._log.info(f"  SUMMARY: {pass_count} / {len(test_angles)} tests passed")
    dut._log.info("  ALL TESTS PASSED")
    dut._log.info("=" * 60)


@cocotb.test()
async def test_cordic_edge_angles(dut):
    """±1.0 results (overflow) and outer-quadrant angles (|z| > 99.9°)."""

    cocotb.start_soon(Clock(dut.aclk, 10, units="ns").start())
    await reset_dut(dut)

    for deg in (0, 90, -90, -180, 179.9, -179.9, 100, -100, 120, 135, 170, -150):
        phase = deg_to_phase(deg)
        x_exp, y_exp = expected(INV_K, 0, phase)
        await run_test(dut, INV_K, 0, phase, x_exp, y_exp, f"Rotate {deg} deg")


@cocotb.test()
async def test_cordic_random_stream(dut):
    """Random vectors with random tvalid gaps and per-channel back-pressure."""

    rng = random.Random(0xC0D1C)
    cocotb.start_soon(Clock(dut.aclk, 10, units="ns").start())
    await reset_dut(dut)

    # Vectors: full-circle sweep with 1/K input + random (x, y, z)
    vectors = [(INV_K, 0, deg_to_phase(d)) for d in range(-180, 180, 5)]
    for _ in range(200):
        vectors.append((rng.randint(-13000, 13000),
                        rng.randint(-13000, 13000),
                        rng.randint(-PI_FIXED, PI_FIXED - 1)))
    exp = [expected(*v) for v in vectors]

    channels = {
        "x":     (dut.m_axis_x_tvalid,     dut.m_axis_x_tready,     dut.m_axis_x_tdata,     INOUT_WIDTH),
        "y":     (dut.m_axis_y_tvalid,     dut.m_axis_y_tready,     dut.m_axis_y_tdata,     INOUT_WIDTH),
        "phase": (dut.m_axis_phase_tvalid, dut.m_axis_phase_tready, dut.m_axis_phase_tdata, PHASE_WIDTH),
    }
    received = {name: [] for name in channels}
    errors = []

    async def ready_driver():
        while True:
            await RisingEdge(dut.aclk)
            for _, ready, _, _ in channels.values():
                ready.value = 1 if rng.random() < 0.7 else 0

    async def monitor():
        stalled = {name: None for name in channels}
        while True:
            await RisingEdge(dut.aclk)
            await ReadOnly()
            # Slave side: never accept a lone channel
            readies = [int(dut.s_axis_x_tready.value), int(dut.s_axis_y_tready.value),
                       int(dut.s_axis_phase_tready.value)]
            valids = [int(dut.s_axis_x_tvalid.value), int(dut.s_axis_y_tvalid.value),
                      int(dut.s_axis_phase_tvalid.value)]
            if any(readies) and not (all(readies) and all(valids)):
                errors.append(f"slave tready without all channels valid: {valids} {readies}")
            # Master side
            for name, (valid, ready, data, width) in channels.items():
                v, r, d = int(valid.value), int(ready.value), to_signed(data.value, width)
                if stalled[name] is not None and (not v or d != stalled[name]):
                    errors.append(f"{name} changed while stalled")
                if v and r:
                    received[name].append(d)
                stalled[name] = d if (v and not r) else None

    cocotb.start_soon(ready_driver())
    cocotb.start_soon(monitor())

    # Driver
    for x_in, y_in, phase_in in vectors:
        while rng.random() < 0.25:
            await RisingEdge(dut.aclk)
        dut.s_axis_x_tdata.value     = to_unsigned(x_in, INOUT_WIDTH)
        dut.s_axis_y_tdata.value     = to_unsigned(y_in, INOUT_WIDTH)
        dut.s_axis_phase_tdata.value = to_unsigned(phase_in, PHASE_WIDTH)
        dut.s_axis_x_tvalid.value     = 1
        dut.s_axis_y_tvalid.value     = 1
        dut.s_axis_phase_tvalid.value = 1
        while True:
            await ReadOnly()
            accepted = int(dut.s_axis_x_tready.value)
            await RisingEdge(dut.aclk)
            if accepted:
                break
        dut.s_axis_x_tvalid.value     = 0
        dut.s_axis_y_tvalid.value     = 0
        dut.s_axis_phase_tvalid.value = 0

    # Drain
    for _ in range(2000):
        if all(len(received[n]) >= len(vectors) for n in channels):
            break
        await RisingEdge(dut.aclk)
    for _ in range(N_ITER + 8):
        await RisingEdge(dut.aclk)

    assert not errors, f"Protocol errors: {errors[:5]} (total {len(errors)})"
    for name in channels:
        assert len(received[name]) == len(vectors), \
            f"{name}: received {len(received[name])} beats, expected {len(vectors)}"

    max_err = 0
    for i, ((x_e, y_e), x_o, y_o) in enumerate(zip(exp, received["x"], received["y"])):
        err = max(abs(x_o - x_e), abs(y_o - y_e))
        max_err = max(max_err, err)
        assert err <= TOLERANCE, \
            f"vector {i} {vectors[i]}: got ({x_o}, {y_o}), expected ({x_e}, {y_e})"

    max_res = max(abs(z) for z in received["phase"])
    assert max_res <= PHASE_TOLERANCE, f"residual phase {max_res} exceeds {PHASE_TOLERANCE}"

    dut._log.info(f"  {len(vectors)} vectors OK, max error {max_err} LSB, "
                  f"max residual phase {max_res} LSB")
