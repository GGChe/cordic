# CORDIC hardware test on the Red Pitaya. `make help` lists the targets.
# Board access is over SSH with a key (once: ssh-copy-id root@<board>).

RP_HOST ?= 192.168.1.145
RP_USER ?= root
RP_DIR  ?= /root/cordic
PART    ?= xc7z020clg400-1
JOBS    ?= 8
NB_DIR  ?= /home/jupyter/cordic
N       ?= 2000

VIVADO_SETTINGS ?= /tools/Xilinx/2025.1/Vivado/settings64.sh

REPO    = ../..
RTL     = $(REPO)/src/atan_lut.v $(REPO)/src/cordic.v $(REPO)/src/cordic_top.v \
          $(REPO)/src/atanh_lut.v $(REPO)/src/cordic_sqrt.v $(REPO)/src/cordic_sqrt_wrapper.v \
          rtl/cordic_axi_regs.v

SSH     = ssh -o BatchMode=yes -o ConnectTimeout=5 $(RP_USER)@$(RP_HOST)
# Red Pitaya tools (fpgautil) live in /opt/redpitaya/bin, which is not in the
# PATH of non-interactive SSH sessions
RP_PATH = PATH=$$PATH:/opt/redpitaya/bin
SCP     = scp -o BatchMode=yes -o ConnectTimeout=5

BITBIN  = out/cordic_rp.bit.bin
BIT     = out/cordic_rp.bit

.PHONY: help sim lint build info deploy test hw notebook plots clean

help:  ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-10s\033[0m %s\n", $$1, $$2}'

sim:  ## Run the AXI4-Lite register interface testbench
	iverilog -g2005-sv -o sim_axi.out $(RTL) tb/tb_cordic_axi_regs.v
	cd $(REPO) && vvp -n fpga/redpitaya/sim_axi.out

lint:  ## Verilator -Wall on the register interface (with the cores)
	verilator --lint-only -Wall --top-module cordic_axi_regs $(RTL)

build: $(BITBIN)  ## Build the bitstream with Vivado (PART=..., JOBS=...)

$(BITBIN): $(RTL) rtl/red_pitaya_cordic_top.v bd/system.tcl bd/ps7_config.tcl sdc/red_pitaya_cordic.xdc build.tcl
	bash -c 'source $(VIVADO_SETTINGS) && vivado -mode batch -nojournal -log out/vivado.log -source build.tcl -tclargs $(PART) $(JOBS)'
	@grep -E "INFO: WNS" out/vivado.log

info:  ## Show the board's Zynq device and OS version
	$(SCP) sw/cordic_hw_test.py $(RP_USER)@$(RP_HOST):/tmp/cordic_hw_test.py
	$(SSH) '$(RP_PATH); grep -h "^# Version" /etc/motd /opt/redpitaya/version.txt 2>/dev/null | head -1; \
	        echo "fpgautil: $$(command -v fpgautil || echo not found)"; \
	        python3 /tmp/cordic_hw_test.py --info'

deploy: $(BITBIN)  ## Copy bitstream + test script to the board and load the FPGA
	$(SSH) 'mkdir -p $(RP_DIR)'
	$(SCP) $(BITBIN) $(BIT) sw/cordic_hw_test.py $(RP_USER)@$(RP_HOST):$(RP_DIR)/
	@# Flush to the SD card and verify the copies (a copy made right after a
	@# power cut once arrived with zeroed blocks)
	(cd out && md5sum cordic_rp.bit.bin cordic_rp.bit; cd ../sw && md5sum cordic_hw_test.py) | \
	  $(SSH) 'cd $(RP_DIR) && sync && md5sum -c --quiet -'
	$(SSH) '$(RP_PATH); cd $(RP_DIR) && \
	  if command -v fpgautil >/dev/null 2>&1; then fpgautil -b cordic_rp.bit.bin; \
	  elif [ -e /dev/xdevcfg ]; then cat cordic_rp.bit > /dev/xdevcfg; \
	  else echo "no fpgautil or /dev/xdevcfg on the board" >&2; exit 1; fi'
	@echo "FPGA loaded on $(RP_HOST)"

test:  ## Run the hardware test on the board (N=random vectors per core)
	$(SSH) 'python3 $(RP_DIR)/cordic_hw_test.py --n $(N)'

hw: deploy test  ## Deploy and run the hardware test

notebook: $(BITBIN)  ## Copy the graphical explorer to JupyterLab on the board
	$(SSH) 'mkdir -p $(NB_DIR)'
	$(SCP) sw/cordic_explorer.ipynb sw/cordic_hw_test.py $(BITBIN) $(RP_USER)@$(RP_HOST):$(NB_DIR)/
	(cd out && md5sum cordic_rp.bit.bin; cd ../sw && md5sum cordic_explorer.ipynb cordic_hw_test.py) | \
	  $(SSH) 'cd $(NB_DIR) && sync && md5sum -c --quiet -'
	@echo "Open http://$(RP_HOST):8888/jlab/lab/tree/cordic/cordic_explorer.ipynb (Red Pitaya JupyterLab)"

plots: notebook  ## Execute the explorer on the board and fetch the plots into out/plots
	$(SSH) 'cd $(NB_DIR) && /usr/local/bin/jupyter nbconvert --to notebook --execute \
	        --ExecutePreprocessor.timeout=600 --output cordic_explorer_run.ipynb cordic_explorer.ipynb'
	mkdir -p out/plots
	$(SCP) '$(RP_USER)@$(RP_HOST):$(NB_DIR)/plots/*.png' out/plots/
	@ls out/plots

clean:  ## Remove Vivado build products
	rm -rf build out .Xil sim_axi.out tb/*.vcd *.jou *.log
