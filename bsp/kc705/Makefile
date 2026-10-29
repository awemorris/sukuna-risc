# ============================================================================
# Makefile for KC705 Synthesis with Vivado
# ============================================================================

SHELL := /bin/bash

VIVADO_DIR        ?= $(firstword $(wildcard /home/awe/opt/amd/*/Vivado /home/awe/opt/Xilinx/Vivado/* /opt/Xilinx/Vivado/*))
VIVADO_SETTINGS   ?= $(VIVADO_DIR)/settings64.sh
VIVADO_UBUNTU_LIB ?= $(firstword $(wildcard $(VIVADO_DIR)/lib/lnx64.o/Ubuntu/24 $(VIVADO_DIR)/lib/lnx64.o/Ubuntu/22))
VIVADO_CMD        ?= $(if $(VIVADO_SETTINGS),source $(VIVADO_SETTINGS) && LD_LIBRARY_PATH=$(VIVADO_UBUNTU_LIB):$$LD_LIBRARY_PATH vivado,vivado)

BUILD_DIR         ?= build_kc705

.PHONY: all synth clean

all: synth

synth:
	@echo "==> Synthesizing with Vivado ($(VIVADO_SETTINGS))..."
	mkdir -p $(BUILD_DIR)
	$(VIVADO_CMD) -mode batch -source kc705_synth.tcl -log $(BUILD_DIR)/vivado.log -jou $(BUILD_DIR)/vivado.jou
	@echo "==> Synthesis finished. Summary reports:"
	@grep -A 15 "1. Slice Logic" $(BUILD_DIR)/synth_utilization.rpt || true
	@grep -A 20 "Design Timing Summary" $(BUILD_DIR)/synth_timing.rpt || true

gui:
	$(VIVADO_CMD) -mode gui &

clean:
	rm -rf $(BUILD_DIR) *.log *.jou *.dcp *.rpt .Xil
