# cocotb runs, one top level per invocation (separate sim_build/ and results):
#   make                                                           cordic_top
#   make TOPLEVEL=cordic_sqrt_wrapper MODULE=test_cordic_sqrt_wrapper

SIM          ?= verilator
TOPLEVEL_LANG = verilog

TOPLEVEL ?= cordic_top
MODULE   ?= test_cordic

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
