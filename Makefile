# ============================================================
# Cocotb configuration
# ============================================================

export CXX = g++
export CC = gcc
export COCOTB_WAVES        = 1
export COCOTB_WAVE_FORMAT = fst

SIM ?= verilator
TOPLEVEL_LANG ?= verilog
VERILOG_SOURCES = $(PWD)/src/cordic.v
TOPLEVEL = cordic
MODULE = test_cordic

# Enable FST tracing for Verilator
EXTRA_ARGS += --trace --trace-fst --trace-structs

export PYTHONPATH := $(PWD)/tb/cocotb:$(PYTHONPATH)
export PLUSARGS += +trace

.PHONY: help test-cocotb test-verilog view-cocotb view-verilog clean setup librelane view-openroad

# Help target: lists all targets with descriptions (marked with #)
help:  ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

# Run Cocotb testbench
test-cocotb:  ## Run Cocotb testbench
	cd tb/cocotb && poetry run $(MAKE) SIM=$(SIM)

# Install dependencies
setup:  ## Install dependencies
	poetry install

# Run full LibreLane flow
librelane:  ## Run full LibreLane flow
	cd librelane && python3 run_librelane.py

# Run Verilog testbench (Icarus Verilog)
test-verilog:  ## Run Verilog testbench (Icarus Verilog)
	iverilog -g2005-sv -o sim_rtl.out $(VERILOG_SOURCES) $(PWD)/tb/verilog/tb_cordic.v
	vvp sim_rtl.out

# View Cocotb waveforms
view-cocotb:  ## View Cocotb waveforms
	gtkwave --script tcl_scripts/signals.tcl tb/cocotb/dump.fst

# View Verilog testbench waveforms
view-verilog: test-verilog  ## View Verilog testbench waveforms
	gtkwave -f tb/wave.gtkw

# View synthesized/routed model in OpenROAD
view-openroad:  ## View synthesized/routed model in OpenROAD
	@echo "Finding latest run..."
	@LATEST_RUN=$$(ls -td librelane/runs/RUN_* | head -n 1); \
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

clean::
	rm -rf sim_build __pycache__ .pytest_cache
	rm -f results.xml *.csv *.html *.vcd *.fst *.wlf transcript sim_rtl.out
	cd tb/cocotb && rm -rf sim_build __pycache__ results.xml *.csv *.html *.fst
