# =============================================================================
# Cocotb Makefile for cordic_top
# =============================================================================
# This Makefile uses the cordic_top wrapper (cordic + atan_lut) as the
# top-level module, providing a complete integration test.
# =============================================================================

SIM          ?= verilator
TOPLEVEL_LANG = verilog

# Directory containing RTL sources (two levels up from tb/cocotb/)
CORDIC_DIR = $(shell cd ../.. && pwd)

VERILOG_SOURCES  = $(CORDIC_DIR)/src/atan_lut.v
VERILOG_SOURCES += $(CORDIC_DIR)/src/cordic.v
VERILOG_SOURCES += $(CORDIC_DIR)/src/cordic_top.v

TOPLEVEL = cordic_top
MODULE   = test_cordic

# Verilator tracing + suppress harmless width-expansion warnings
EXTRA_ARGS += --trace --trace-fst --trace-structs
EXTRA_ARGS += -Wno-WIDTHEXPAND

include $(shell cocotb-config --makefiles)/Makefile.sim
