# =============================================================================
# Cocotb Testbench: test_cordic_sqrt_wrapper
# =============================================================================
# Tests the cordic_sqrt_wrapper module (32-bit unsigned integer → Q16.16
# square root, hyperbolic CORDIC core + normalisation + output register):
#   1. test_sqrt_directed      — small integers, perfect squares, every
#                                2^k − 1 / 2^k / 2^k + 1, top of the range
#   2. test_sqrt_random_stream — random 32-bit values streamed with random
#                                input gaps and random output back-pressure,
#                                checked by a protocol monitor + scoreboard
#
# Expected value: round(√rad · 2^16), computed exactly with integer math and
# saturated to 0xFFFF_FFFF (√(2^32 − 1) rounds to 2^32).
# =============================================================================

import math
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge

# Pass/fail tolerance in Q16.16 LSBs (same as tb_cordic_sqrt_wrapper.v)
TOLERANCE = 1

MAX_U32 = (1 << 32) - 1


def expected_root(rad):
    """round(√rad · 2^16) with exact integer arithmetic, saturated to 32 bits."""
    v = rad << 32                 # (√rad · 2^16)^2
    q = math.isqrt(v)             # floor
    if v - q * q > q:             # v > (q + 0.5)^2 − 0.25  ⇔  round up
        q += 1
    return min(q, MAX_U32)


async def reset_dut(dut):
    """Apply reset and initialise all inputs."""
    dut.resetn.value = 0
    dut.rad.value = 0
    dut.input_valid.value = 0
    dut.output_ready.value = 1
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.resetn.value = 1
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)


async def run_stream(dut, values, rng, gaps, backpressure):
    """Stream `values` through the DUT and return (results, protocol_errors)."""
    results = []
    errors = []

    async def ready_driver():
        while True:
            await RisingEdge(dut.clk)
            dut.output_ready.value = 1 if (not backpressure or rng.random() < 0.7) else 0

    async def monitor():
        stalled = None
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            v, r = int(dut.output_valid.value), int(dut.output_ready.value)
            d = int(dut.root.value)
            if stalled is not None and (not v or d != stalled):
                errors.append("root changed while stalled")
            if v and r:
                results.append(d)
            stalled = d if (v and not r) else None

    ready_task = cocotb.start_soon(ready_driver())
    monitor_task = cocotb.start_soon(monitor())

    for rad in values:
        while gaps and rng.random() < 0.25:
            await RisingEdge(dut.clk)
        dut.rad.value = rad
        dut.input_valid.value = 1
        while True:
            await ReadOnly()
            accepted = int(dut.input_ready.value)
            await RisingEdge(dut.clk)
            if accepted:
                break
        dut.input_valid.value = 0

    for _ in range(100 * len(values) + 100):
        if len(results) >= len(values):
            break
        await RisingEdge(dut.clk)
    for _ in range(30):
        await RisingEdge(dut.clk)

    ready_task.kill()
    monitor_task.kill()
    dut.output_ready.value = 1
    return results, errors


def check(dut, values, results, errors):
    assert not errors, f"Protocol errors: {errors[:5]} (total {len(errors)})"
    assert len(results) == len(values), \
        f"received {len(results)} results, expected {len(values)}"
    max_err = 0
    for rad, got in zip(values, results):
        exp = expected_root(rad)
        err = abs(got - exp)
        max_err = max(max_err, err)
        assert err <= TOLERANCE, \
            f"sqrt({rad}): got {got} ({got / 65536:.6f}), expected {exp} ({exp / 65536:.6f})"
    dut._log.info(f"  {len(values)} values OK, max error {max_err} LSB (Q16.16)")


@cocotb.test()
async def test_sqrt_directed(dut):
    """Directed values covering every normalisation shift and the range ends."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)

    values = [0, 1, 2, 3, 4, 9, 16, 25, 100, 10000, 1000000]
    for k in range(1, 32):
        values += [(1 << k) - 1, 1 << k, (1 << k) + 1]
    values += [0x7FFF_FFFF, 0xFFFE_0001, 0xFFFF_FFFE, 0xFFFF_FFFF]

    results, errors = await run_stream(dut, values, random.Random(1), gaps=False, backpressure=False)
    check(dut, values, results, errors)


@cocotb.test()
async def test_sqrt_random_stream(dut):
    """Random 32-bit values with random input gaps and output back-pressure."""
    rng = random.Random(0x5A5A)
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)

    values = [rng.getrandbits(32) for _ in range(300)]
    # also exercise every MSB position with random low bits
    values += [(1 << m) | rng.getrandbits(m) for m in range(32)]

    results, errors = await run_stream(dut, values, rng, gaps=True, backpressure=True)
    check(dut, values, results, errors)
