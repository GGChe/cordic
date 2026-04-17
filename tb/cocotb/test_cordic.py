# =============================================================================
# Cocotb Testbench: test_cordic
# =============================================================================
# Tests the cordic_top module (cordic core + atan LUT) in circular rotation
# mode with 8 angle test cases — matching the Verilog testbench.
#
# Fixed-Point Convention:
#   INOUT_WIDTH  = 16 → Q1.15 (1.0 = 32768)
#   PHASE_WIDTH  = 18 → pi = 2^17 = 131072
#
# CORDIC Gain K(16 iter) = 1.646760, so 1/K = 0.607253
# 1/K in Q1.15 = round(0.607253 * 32768) = 19898
# =============================================================================

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

# ── Parameters matching the RTL ──────────────────────────────────────────────
INOUT_WIDTH = 16
PHASE_WIDTH = 18

# 1/K pre-scaled in Q1.15
INV_K = 19898

# Pass/fail tolerance in fixed-point LSBs (same as Verilog tb: 50)
TOLERANCE = 50


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

    # ── Wait for slave handshake (data accepted) ──
    await RisingEdge(dut.aclk)
    timeout = 100
    while not (int(dut.s_axis_x_tready.value) and int(dut.s_axis_x_tvalid.value)):
        await RisingEdge(dut.aclk)
        timeout -= 1
        assert timeout > 0, f"{name}: Timed out waiting for slave handshake"
    await RisingEdge(dut.aclk)

    # ── Deassert valid ──
    dut.s_axis_x_tvalid.value     = 0
    dut.s_axis_y_tvalid.value     = 0
    dut.s_axis_phase_tvalid.value = 0

    # ── Wait for output valid ──
    timeout = 100
    while not int(dut.m_axis_x_tvalid.value):
        await RisingEdge(dut.aclk)
        timeout -= 1
        assert timeout > 0, f"{name}: Timed out waiting for output valid"
    await RisingEdge(dut.aclk)

    # ── Read & convert outputs ──
    x_out = to_signed(dut.m_axis_x_tdata.value, INOUT_WIDTH)
    y_out = to_signed(dut.m_axis_y_tdata.value, INOUT_WIDTH)

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

    dut._log.info(f"  Result: PASS")

    # Let the master handshake complete (DUT returns to IDLE)
    await RisingEdge(dut.aclk)
    await RisingEdge(dut.aclk)


# ── Main test ────────────────────────────────────────────────────────────────

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
    dut._log.info(f"  Fixed-point: 1.0 = 2^15 = 32768, pi = 2^17 = 131072")
    dut._log.info(f"  1/K = {INV_K} (pre-scaled input)")
    dut._log.info("=" * 60)

    # ── Test cases ───────────────────────────────────────────────
    # Each tuple: (phase_in, x_expected, y_expected, test_name)
    # Phase = round(angle_deg / 180 * 2^17)
    #
    # These values exactly match the Verilog testbench (tb_cordic.v).
    # ─────────────────────────────────────────────────────────────
    test_cases = [
        # (phase,   x_exp,  y_exp,  name)
        (  7282,    32270,   5690,   "Rotate 10 deg"),
        ( 10923,    31651,   8481,   "Rotate 15 deg"),
        ( 21845,    28378,  16384,   "Rotate 30 deg"),
        ( 32768,    23170,  23170,   "Rotate 45 deg"),
        ( 43691,    16384,  28378,   "Rotate 60 deg"),
        ( 54613,     8481,  31651,   "Rotate 75 deg"),
        (-32768,    23170, -23170,   "Rotate -45 deg"),
        (-43691,    16384, -28378,   "Rotate -60 deg"),
    ]

    pass_count = 0
    for phase_in, x_exp, y_exp, name in test_cases:
        await run_test(dut, INV_K, 0, phase_in, x_exp, y_exp, name)
        pass_count += 1

    dut._log.info("=" * 60)
    dut._log.info(f"  SUMMARY: {pass_count} / {len(test_cases)} tests passed")
    dut._log.info("  ALL TESTS PASSED")
    dut._log.info("=" * 60)
