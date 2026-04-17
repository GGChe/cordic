# CORDIC — simulation, lint and synthesis. `make help` lists the targets.

SIM ?= verilator

IVERILOG  = iverilog -g2005-sv
VVP       = vvp -n
VERILATOR = verilator --lint-only -Wall
YOSYS     = yosys -q

# Source sets per design
CIRCULAR_SRCS = src/atan_lut.v src/cordic.v
TOP_SRCS      = $(CIRCULAR_SRCS) src/cordic_top.v
SQRT_SRCS     = src/atanh_lut.v src/cordic_sqrt.v
WRAPPER_SRCS  = $(SQRT_SRCS) src/cordic_sqrt_wrapper.v

# Non-default configurations exercised by test-params
#   circular, narrow : Q1.11, pi = 2^13, 12 iterations
#   circular, wide   : Q1.23, pi = 2^25, 24 iterations (through cordic_top)
#   sqrt, wide       : Q1.23, phase Q2.24, 22 iterations, 3 guard bits
P_NARROW = -Ptb_cordic.inout_width=12 -Ptb_cordic.phase_width=14 \
           -Ptb_cordic.cordic_niter=12 -Ptb_cordic.cordic_niter_width=4
P_WIDE   = -Ptb_cordic.inout_width=24 -Ptb_cordic.phase_width=26 \
           -Ptb_cordic.cordic_niter=24 -Ptb_cordic.cordic_niter_width=5 \
           -Ptb_cordic.TOLERANCE=3
P_SQRT_W = -Ptb_cordic_sqrt.data_width=24 -Ptb_cordic_sqrt.phase_width=26 \
           -Ptb_cordic_sqrt.n_iterations=22 -Ptb_cordic_sqrt.iter_width=5 \
           -Ptb_cordic_sqrt.guard_bits=3 -Ptb_cordic_sqrt.TOLERANCE=3 \
           -Ptb_cordic_sqrt.Y_TOLERANCE=8 -Ptb_cordic_sqrt.Z_TOLERANCE=32

.PHONY: help test test-verilog test-verilog-top test-verilog-nophase test-verilog-sqrt \
        test-verilog-wrapper test-params test-all test-cocotb test-cocotb-top \
        test-cocotb-sqrt test-axi redpitaya lint luts check-luts synth view-cocotb view-verilog view-verilog-sqrt \
        view-verilog-top view-verilog-wrapper clean setup setup-all strip-notebook \
        librelane view-openroad

help:  ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

setup:  ## Install core dependencies (simulation / cocotb)
	poetry install

setup-all:  ## Install everything, including notebook and LibreLane groups
	poetry install --with notebook,pnr

# ── Verilog testbenches (Icarus Verilog) ──
# Each testbench calls $fatal on failure, so vvp exits non-zero.
test: test-verilog test-verilog-top test-verilog-nophase test-verilog-sqrt test-verilog-wrapper test-axi  ## Run all Verilog testbenches (default parameters)

test-axi:  ## Run the Red Pitaya AXI4-Lite register interface testbench
	$(MAKE) -C fpga/redpitaya sim

test-all: test test-params test-cocotb  ## Run every testbench: Verilog, parameter sweep and cocotb

test-verilog:  ## Run circular CORDIC core testbench
	$(IVERILOG) -o sim_rtl.out $(CIRCULAR_SRCS) tb/verilog/tb_cordic.v
	$(VVP) sim_rtl.out

test-verilog-top:  ## Run circular CORDIC testbench against the cordic_top wrapper
	$(IVERILOG) -DTB_USE_TOP -o sim_top.out $(TOP_SRCS) tb/verilog/tb_cordic.v
	$(VVP) sim_top.out

test-verilog-nophase:  ## Run circular CORDIC testbench with the phase output disabled
	$(IVERILOG) -DTB_USE_TOP -Ptb_cordic.phase_output=0 -o sim_nophase.out $(TOP_SRCS) tb/verilog/tb_cordic.v
	$(VVP) sim_nophase.out

test-verilog-sqrt:  ## Run hyperbolic sqrt core testbench
	$(IVERILOG) -o sim_sqrt.out $(SQRT_SRCS) tb/verilog/tb_cordic_sqrt.v
	$(VVP) sim_sqrt.out

test-verilog-wrapper:  ## Run sqrt wrapper (32-bit integer → Q16.16) testbench
	$(IVERILOG) -o sim_wrapper.out $(WRAPPER_SRCS) tb/verilog/tb_cordic_sqrt_wrapper.v
	$(VVP) sim_wrapper.out

test-params:  ## Run the testbenches with non-default widths / iteration counts
	$(IVERILOG) $(P_NARROW) -o sim_narrow.out $(CIRCULAR_SRCS) tb/verilog/tb_cordic.v
	$(VVP) sim_narrow.out
	$(IVERILOG) -DTB_USE_TOP $(P_WIDE) -o sim_wide.out $(TOP_SRCS) tb/verilog/tb_cordic.v
	$(VVP) sim_wide.out
	$(IVERILOG) $(P_SQRT_W) -o sim_sqrt_wide.out $(SQRT_SRCS) tb/verilog/tb_cordic_sqrt.v
	$(VVP) sim_sqrt_wide.out

# ── Cocotb testbenches (Verilator by default) ──
test-cocotb: test-cocotb-top test-cocotb-sqrt  ## Run all cocotb testbenches

test-cocotb-top:  ## Run cocotb testbench on cordic_top
	cd tb/cocotb && poetry run $(MAKE) SIM=$(SIM) TOPLEVEL=cordic_top MODULE=test_cordic

test-cocotb-sqrt:  ## Run cocotb testbench on cordic_sqrt_wrapper
	cd tb/cocotb && poetry run $(MAKE) SIM=$(SIM) TOPLEVEL=cordic_sqrt_wrapper MODULE=test_cordic_sqrt_wrapper

# ── Static checks ──
lint: check-luts  ## Lint all RTL with Verilator -Wall (and check the LUT tables)
	$(VERILATOR) --top-module cordic_top $(TOP_SRCS)
	$(VERILATOR) --top-module cordic_top -GPHASE_OUTPUT=0 $(TOP_SRCS)
	$(VERILATOR) --top-module cordic_sqrt_wrapper $(WRAPPER_SRCS)
	$(MAKE) -C fpga/redpitaya lint

redpitaya:  ## Build the Red Pitaya bitstream (see fpga/redpitaya/README.md)
	$(MAKE) -C fpga/redpitaya build

luts:  ## Regenerate the hard-coded LUT master tables (scripts/gen_luts.py)
	python3 scripts/gen_luts.py --write

check-luts:  ## Verify the LUT master tables are current and round exactly
	python3 scripts/gen_luts.py --check

synth:  ## Quick generic Yosys synthesis of both tops (cell count report)
	$(YOSYS) -p "read_verilog -sv $(TOP_SRCS); hierarchy -check -top cordic_top; synth -flatten -top cordic_top; tee -o /dev/stdout stat"
	$(YOSYS) -p "read_verilog -sv $(WRAPPER_SRCS); hierarchy -check -top cordic_sqrt_wrapper; synth -flatten -top cordic_sqrt_wrapper; tee -o /dev/stdout stat"

# ── Waveforms ──
view-cocotb:  ## View Cocotb waveforms (last cocotb run)
	gtkwave tb/cocotb/dump.fst

view-verilog: test-verilog  ## View Verilog testbench waveforms
	gtkwave tb/dump.vcd

view-verilog-sqrt: test-verilog-sqrt  ## View Verilog sqrt testbench waveforms
	gtkwave tb/dump_sqrt.vcd

view-verilog-top: test-verilog-top  ## View Verilog top-level wrapper testbench waveforms
	gtkwave tb/dump.vcd

view-verilog-wrapper: test-verilog-wrapper  ## View Verilog sqrt wrapper testbench waveforms
	gtkwave tb/dump_wrapper.vcd

# ── Notebook hygiene ──
strip-notebook:  ## Remove outputs from the notebook before committing (needs: make setup-all)
	poetry run nbstripout notebooks/*.ipynb

# ── Physical design (LibreLane) — requires a librelane/ configuration ──
librelane:  ## Run full LibreLane flow (needs librelane/run_librelane.py)
	@if [ ! -f librelane/run_librelane.py ]; then \
		echo "librelane/run_librelane.py not found — add a LibreLane configuration first."; \
		exit 1; \
	fi
	cd librelane && python3 run_librelane.py

# View synthesized/routed model in OpenROAD
view-openroad:  ## View synthesized/routed model in OpenROAD
	@echo "Finding latest run..."
	@LATEST_RUN=$$(ls -td librelane/runs/RUN_* 2>/dev/null | head -n 1); \
	if [ -z "$$LATEST_RUN" ]; then \
		echo "No runs found in librelane/runs/"; \
		exit 1; \
	fi; \
	echo "Using run: $$LATEST_RUN"; \
	LATEST_ODB=$$(find $$LATEST_RUN -name "*.odb" | sort | tail -n 1); \
	if [ -z "$$LATEST_ODB" ]; then \
		echo "No .odb files found in $$LATEST_RUN"; \
		exit 1; \
	fi; \
	echo "Opening $$LATEST_ODB in OpenROAD..."; \
	echo "read_db $$LATEST_ODB" > view.tcl; \
	openroad -gui view.tcl; \
	rm view.tcl

clean:  ## Remove simulation build products and waveforms
	rm -rf sim_build __pycache__ .pytest_cache
	rm -f results.xml *.csv *.html *.vcd *.fst *.wlf transcript sim_*.out
	rm -f tb/*.vcd tb/*.fst
	cd tb/cocotb && rm -rf sim_build __pycache__ results*.xml *.csv *.html *.fst *.vcd
