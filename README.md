# CORDIC (COordinate Rotation DIgital Computer)

CORDIC is a highly efficient hardware algorithm for calculating mathematical functions like sine, cosine, magnitude, phase, and square roots. It works by performing a series of simple micro-rotations using only **bit-shifts** and **additions**, completely avoiding the need for expensive hardware multipliers.

## The Principle of Micro-Rotations

The core concept relies on iteratively rotating a vector by pre-defined angles ($\alpha_i$) chosen specifically so that their tangent is a descending power of 2 (i.e., $\tan(\alpha_i) = 2^{-i}$). This mathematical trick simplifies the complex matrix rotation into simple shift arrays.

![Micro-rotations](resources/cordic_micro_rotations.png)

## Operating Modes

The CORDIC algorithm generally operates in two fundamental modes depending on which internal variable it is attempting to drive to zero:

### 1. Rotation Mode
In Rotation Mode, the target angle ($Z$) is constantly driven towards zero. The sequence of micro-rotations is determined by the sign of the remaining angle. This mode is exceptionally useful for calculating trigonometric functions, most notably rotating a vector to compute **Sine** and **Cosine**.

![Rotation Mode](resources/cordic_rotation_mode.png)

### 2. Vectoring Mode
In Vectoring Mode, the vector's y-coordinate ($Y$) is iteratively driven to zero. This effectively rotates the vector until it aligns cleanly with the positive x-axis. The final accumulated angle represents the original phase mapping (used for **Arctangent**), and the accumulated x-coordinate represents the total vector magnitude.

![Vectoring Mode](resources/cordic_vectoring_mode.png)

*(A supplementary overview of micro-rotation execution)*
![Micro-rotation mode](resources/cordic_microrotation_mode.png)

## Repository layout

| Path | Contents |
|---|---|
| `src/` | RTL: circular core, square-root core and wrapper, LUTs, `cordic_top` |
| `tb/verilog/`, `tb/cocotb/` | Self-checking Verilog testbenches and cocotb suites |
| `scripts/` | `cordic.py` (floating-point reference model), `gen_luts.py` (LUT tables) |
| `fpga/redpitaya/` | Red Pitaya integration: AXI4-Lite registers, block design, Vivado build, on-board test and notebook |
| `notebooks/` | Exploration notebook and the interactive iteration explorer |
| `resources/` | Figures and LaTeX notes |

## Package Contents

This repository contains iterative (word-serial, one micro-rotation per clock) Verilog implementations of these CORDIC components:

* **`src/cordic.v`**: Circular CORDIC core (Rotation Mode) for calculating $\sin(\theta)$ and $\cos(\theta)$, or rotating an arbitrary vector.
  * Accepts the full angle range $[-\pi, \pi)$: angles beyond $\pm 90°$ are folded by a $\pi$ pre-rotation, since plain CORDIC only converges up to about $\pm 99.9°$.
  * Carries 2 extra integer bits and `guard_bits` (default 4) extra fractional bits on x/y, plus `phase_guard_bits` (default 4) extra bits on the internal phase accumulator. Outputs are rounded to nearest and saturated, so a result of exactly $+1.0$ clips to `32767` instead of wrapping. With the defaults the error is within 1 LSB.
  * The first micro-rotation is done in the input-handshake cycle, and a new input is accepted in the same cycle in which the previous result is taken, so it sustains one result every 16 cycles.
  * The outputs are computed from the internal registers: the last micro-rotation is a shift by a constant, followed by rounding. This keeps the input path (quadrant fold and capture mux) out of the output path, so the critical path is one micro-rotation and the core closes timing at 125 MHz on a Zynq-7000.
  * The `phase` master channel returns the **residual** angle (≈ 0), useful for verification. Set `phase_output = 0` (`PHASE_OUTPUT` on `cordic_top`) if you do not consume it: the channel then never raises `tvalid` and `m_axis_phase_tready` is ignored. With it enabled, the core waits until the phase beat has been accepted too.
  * Output gain is $K \approx 1.6468$; pre-scale the input by $1/K$ (`19898` in Q1.15) to get $\cos/\sin$ directly.
* **`src/cordic_sqrt.v`**: Hyperbolic CORDIC core (Vectoring Mode) for fractional square roots, $a \in (0.03, 0.75)$. Output is $K_h \cdot \sqrt{a}$ with $K_h \approx 0.8282$; `z_final` is $\operatorname{atanh}(y_0/x_0)$ in Q2.(phase_width−2) (1.0 = $2^{16}$ by default), so the angle reached at $a = 0.03$ ($\approx -1.06$) does not wrap. The iteration count, datapath width and guard bits are parameters.
* **`src/cordic_sqrt_wrapper.v`**: Normalization wrapper for the square-root core. It takes any 32-bit unsigned integer and returns $\sqrt{x}$ in Q16.16, rounded to nearest (within 1 LSB over the full input range). Internally it uses a 40-bit core so no input bits are dropped during normalization. The post-scaling (× 1/K_h, rounding, exponent shift, saturation) is a 5-stage pipeline ending in the output register, so it closes timing at 125 MHz on a Zynq-7000. `root` and `output_valid` come straight from flip-flops, and the extra stages add latency but leave the throughput unchanged.
* **`src/cordic_top.v`**: Top-level wrapper combining the circular core with its atan LUT into a single block with AXI4-Stream-style ports.
* **`src/atan_lut.v` / `src/atanh_lut.v`**: Combinational ROMs of the elementary angles. The angles are hard-coded once as a 64-bit master table (62 fractional bits); each `PHASE_WIDTH`-bit entry is that value rounded by a constant shift, using integer arithmetic only, with no `$atan` or real math. `scripts/gen_luts.py` produces the tables from exact series and checks that the rounding is exact for every width up to 48 bits (`make luts` regenerates them, `make check-luts` checks them; `make lint` runs the check too). The atan LUT is instantiated at the circular core's internal phase width (`PHASE_WIDTH + PHASE_GUARD_BITS`); the atanh LUT uses the Q2.x scaling of the square-root core.

### Implementation of the circular core

Each clock cycle performs one micro-rotation by θᵢ = atan(2⁻ⁱ), so multiplying by tan θᵢ is a right shift:

```
σᵢ   = +1 if zᵢ ≥ 0, −1 otherwise
xᵢ₊₁ = xᵢ − σᵢ · (yᵢ ≫ i)
yᵢ₊₁ = yᵢ + σᵢ · (xᵢ ≫ i)
zᵢ₊₁ = zᵢ − σᵢ · atan(2⁻ⁱ)                       i = 0 … 15

x₁₆ = K·(x₀ cos z₀ − y₀ sin z₀),  y₁₆ = K·(y₀ cos z₀ + x₀ sin z₀),  K = ∏ √(1 + 2⁻²ⁱ) ≈ 1.6468
```

```
 x0,y0,z0 ─► guard bits + quadrant fold ─► mux ─► micro-rotation ─► registers x,y,z ─┐
 (AXI-Stream)   (|z| ≥ 90°: rotate by π)    ▲      (2 shifters,         │             │
                                            │       3 adders) ◄─ atan_lut(i)          │
                                            └──────────── next iteration ◄────────────┘
                 registers ─► last iteration (constant shift) ─► round + saturate ─► x,y,phase out
```

The FSM (`IDLE` → `ROTATE` → `OUTPUT`) drives the mux and the iteration counter, which also addresses the LUT. Internally x/y are 22 bits (16 + 2 integer + 4 guard) and the phase is 22 bits (π = 2²¹). The square-root core uses the hyperbolic form xⱼ₊₁ = xⱼ + σⱼ(yⱼ ≫ j), yⱼ₊₁ = yⱼ + σⱼ(xⱼ ≫ j), with σⱼ = −sign(yⱼ), driving y to 0 and repeating j = 4 and 13.

### Interfaces and timing

| Module | Input → output format | Latency (cycles) | Throughput |
|---|---|---|---|
| `cordic` / `cordic_top` | Q1.15 x/y, phase with $\pi = 2^{17}$ | 16 | 1 result / 16 cycles |
| `cordic_sqrt` | Q1.15 (x0 = a + ¼, y0 = a − ¼), z in Q2.16 | 1 + 16 | 1 result / 18 cycles |
| `cordic_sqrt_wrapper` | 32-bit unsigned → Q16.16 | 1 + 18 + 5 | 1 result / 20 cycles |

Latency counts the input-handshake cycle up to the clock edge where `tvalid` / `output_valid` rises; throughput is without back-pressure.

The circular core follows the AXI4-Stream handshake rules:
* The three slave channels (`x`, `y`, `phase`) are consumed together. `tready` is only asserted while the core is free **and** all three `tvalid` are high, so a channel is never accepted on its own.
* Each master channel holds `tdata`/`tvalid` stable until its own `tready` is seen. A new input is accepted in the same cycle in which the last pending output beat is accepted, so `s_axis_*_tready` depends combinationally on `m_axis_*_tready` (allowed by AXI4-Stream; just avoid a combinational loop from the outputs back to the inputs).

The square-root core and wrapper use the same valid/ready rules on a single channel.

### Testing

Every module has a self-checking Verilog testbench in `tb/verilog/`. Each one compares against real-valued math, checks the handshake protocol every cycle, and runs its vector set twice: back-to-back, then with random input gaps and random output back-pressure. Every testbench prints the maximum error it measured. Any failure calls `$fatal`, so the commands below exit non-zero.

```bash
make setup       # poetry install (cocotb); `make setup-all` adds the notebook and LibreLane groups
make test        # all Verilog testbenches with default parameters (Icarus Verilog), incl. the Red Pitaya AXI block
make test-params # the testbenches again with non-default widths / iteration counts
make test-cocotb # cocotb suites on cordic_top and cordic_sqrt_wrapper (Verilator by default)
make test-all    # all of the above
make lint        # Verilator -Wall on both top levels (and cordic_top with PHASE_OUTPUT=0) and the AXI block
make synth       # quick generic Yosys synthesis with cell counts
make help        # list every target
```

| Testbench | DUT | Vectors | Tolerance |
|---|---|---|---|
| `tb_cordic.v` | `cordic`; `cordic_top` with `-DTB_USE_TOP`; also with `phase_output = 0` | 349 (incl. 0°, ±90°, ±180°, outer quadrants, saturation, random); also checks 1 result / 16 cycles | 2 LSB, residual phase 4 LSB |
| `tb_cordic_sqrt.v` | `cordic_sqrt` | 117 (a ∈ [0.03, 0.74]); checks x, y and `z_final` | x 3 LSB, y 2 LSB, z 32 LSB (Q2.16) |
| `tb_cordic_sqrt_wrapper.v` | `cordic_sqrt_wrapper` | 408 (every $2^k \pm 1$, `0xFFFFFFFF`, random) | 1 LSB (Q16.16) |
| `tb/cocotb/test_cordic.py` | `cordic_top` | reference angles, edge angles, 272-vector random stream | 2 LSB |
| `tb/cocotb/test_cordic_sqrt_wrapper.py` | `cordic_sqrt_wrapper` | directed $2^k \pm 1$ set, 332-value random stream with back-pressure | 1 LSB (Q16.16) |
| `fpga/redpitaya/tb/tb_cordic_axi_regs.v` | `cordic_axi_regs` (Red Pitaya register block) | AXI4-Lite accesses with random AW/W ordering: ID, scratch, unmapped addresses, single operations and bursts of both cores | circular 2 LSB, sqrt 1 LSB |

`make test-params` runs `tb_cordic.v` in Q1.11 (12 iterations) and in Q1.23 (24 iterations, through `cordic_top`), and `tb_cordic_sqrt.v` in Q1.23 (22 iterations).

### Notebook

`notebooks/cordic_exploration.ipynb` needs the optional `notebook` group (`make setup-all`). Run `make strip-notebook` before committing to drop its outputs and keep the repository small.

`notebooks/cordic_iteration_explorer.html` is a standalone page (open it in a browser). It steps through the 16 micro-rotations using the same fixed-point model as the RTL, showing σ, the remaining angle, the x/y values and the vector converging on the unit circle.

## Running on hardware (Red Pitaya)

`fpga/redpitaya/` builds a bitstream that puts both cores on a **Red Pitaya STEMlab 125-14**. It also has a test that runs on the board, and a Jupyter notebook that plots the hardware results. The full flow, register map and notes are in [fpga/redpitaya/README.md](fpga/redpitaya/README.md).

```
 Zynq PS (Linux) ── M_AXI_GP0 ── AXI Interconnect ── cordic_axi_regs ──┬── cordic_top
   /dev/mem @ 0x4000_0000        (AXI3 → AXI4-Lite)   (registers)      └── cordic_sqrt_wrapper
                                                    FCLK_CLK0 125 MHz
```

Linux on the board writes inputs through AXI4-Lite registers, starts operations (single or in bursts), and reads the results and the on-chip cycle counters. `fpgautil` loads the bitstream at runtime in about 60 ms, so nothing needs to be flashed to the SD card.

```bash
cd fpga/redpitaya
make build      # Vivado 2025.1 batch build → out/cordic_rp.bit.bin (fails if timing is not met)
make hw         # copy to the board over SSH, load it with fpgautil, run the hardware test
make plots      # run the notebook on the board and fetch the plots into out/plots/
```

These targets need SSH key access to the board, set up once with `ssh-copy-id root@<board>`. The default address is `RP_HOST=192.168.1.145`.

**Interactive notebook.** `make notebook` copies `fpga/redpitaya/sw/cordic_explorer.ipynb` to the board's JupyterLab, available at `http://<board>:8888/jlab/lab/tree/cordic/cordic_explorer.ipynb`. Red Pitaya serves JupyterLab under `/jlab`. The notebook reloads the bitstream before touching the bus, redraws these plots live, and has sliders that rotate a vector on the FPGA.

**Before loading the bitstream, close the Red Pitaya web interface in your browser.** The web server reads the FPGA registers continuously, and a read that lands during reprogramming hangs the board. A GP0 access with no design loaded hangs it too. Details are in [fpga/redpitaya/README.md](fpga/redpitaya/README.md#notes).
