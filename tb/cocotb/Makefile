# =============================================================================
# Cocotb Makefile
# =============================================================================
# Two top levels can be tested (one per invocation):
#
#   make                                   cordic_top (cordic + atan_lut), default
#   make TOPLEVEL=cordic_sqrt_wrapper \
#        MODULE=test_cordic_sqrt_wrapper   sqrt wrapper (atanh_lut + cordic_sqrt)
#
# Each top level builds in its own sim_build/<toplevel> directory and writes
# its own results_<toplevel>.xml, so the two runs never clash.
# =============================================================================

SIM          ?= verilator
TOPLEVEL_LANG = verilog

TOPLEVEL ?= cordic_top
MODULE   ?= test_cordic

# Directory containing RTL sources (two levels up from tb/cocotb/)
CORDIC_DIR = $(shell cd ../.. && pwd)

ifeq ($(TOPLEVEL),cordic_top)
  VERILOG_SOURCES  = $(CORDIC_DIR)/src/atan_lut.v
  VERILOG_SOURCES += $(CORDIC_DIR)/src/cordic.v
  VERILOG_SOURCES += $(CORDIC_DIR)/src/cordic_top.v
else ifeq ($(TOPLEVEL),cordic_sqrt_wrapper)
  VERILOG_SOURCES  = $(CORDIC_DIR)/src/atanh_lut.v
  VERILOG_SOURCES += $(CORDIC_DIR)/src/cordic_sqrt.v
  VERILOG_SOURCES += $(CORDIC_DIR)/src/cordic_sqrt_wrapper.v
else
  $(error Unknown TOPLEVEL '$(TOPLEVEL)' (use cordic_top or cordic_sqrt_wrapper))
endif

SIM_BUILD = sim_build/$(TOPLEVEL)
export COCOTB_RESULTS_FILE := results_$(TOPLEVEL).xml

# Verilator tracing
EXTRA_ARGS += --trace --trace-fst --trace-structs

include $(shell cocotb-config --makefiles)/Makefile.sim
