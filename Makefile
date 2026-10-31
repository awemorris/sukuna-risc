# ============================================================================
# Sukuna-RISC Master Makefile
# ============================================================================

SHELL := /bin/bash

# Configuration Parameters
-include config.mk

PADDR_WIDTH    ?= 40
L1I_WAYS       ?= 4
L1D_WAYS       ?= 4
L2_WAYS        ?= 8
L1I_SIZE_BYTES ?= 16384
L1D_SIZE_BYTES ?= 16384
L2_SIZE_BYTES  ?= 262144
MUL_LAT        ?= 3
FP_MUL_LAT     ?= 3

CONFIG_DEFINES := -DPADDR_WIDTH=$(PADDR_WIDTH) -DL1I_WAYS=$(L1I_WAYS) \
                  -DL1D_WAYS=$(L1D_WAYS) -DL2_WAYS=$(L2_WAYS) \
                  -DL1I_SIZE_BYTES=$(L1I_SIZE_BYTES) \
                  -DL1D_SIZE_BYTES=$(L1D_SIZE_BYTES) \
                  -DL2_SIZE_BYTES=$(L2_SIZE_BYTES) \
                  -DMUL_LAT=$(MUL_LAT) \
                  -DFP_MUL_LAT=$(FP_MUL_LAT)

# Project & Board Parameters
TOP_MODULE     ?= sukuna_top
KC705_TOP      ?= sukuna_kc705_top
ZCU104_TOP     ?= sukuna_zcu104_top

PART_KC705     ?= xc7k325tffg900-2
PART_ZCU104    ?= xczu7ev-ffvc1156-2-e

# Directory Paths
BUILD_DIR      := build
RTL_DIR        := rtl
BSP_DIR        := bsp
SCRIPTS_DIR    := scripts

# Toolchain Definitions
VERILATOR      ?= verilator
IVERILOG       ?= iverilog
YOSYS          ?= yosys
NEXTPNR_XILINX ?= nextpnr-xilinx
FASM2FRAMES    ?= fasm2frames
XC7FRAMES2BIT  ?= xc7frames2bit

# Vivado Configuration (Auto-detect ~/opt/amd or ~/opt/Xilinx)
VIVADO_DIR        ?= $(firstword $(wildcard /home/awe/opt/amd/*/Vivado /home/awe/opt/Xilinx/Vivado/* /opt/Xilinx/Vivado/*))
VIVADO_SETTINGS   ?= $(VIVADO_DIR)/settings64.sh
VIVADO_UBUNTU_LIB ?= $(firstword $(wildcard $(VIVADO_DIR)/lib/lnx64.o/Ubuntu/24 $(VIVADO_DIR)/lib/lnx64.o/Ubuntu/22))
VIVADO_CMD        ?= $(if $(VIVADO_SETTINGS),source $(VIVADO_SETTINGS) && LD_LIBRARY_PATH=$(VIVADO_UBUNTU_LIB):$$LD_LIBRARY_PATH vivado,vivado)
VIVADO            ?= $(VIVADO_CMD)

# OpenXC7 / Project X-Ray Configuration
XRAY_DIR       ?= /opt/openxc7/prjxray
XRAY_DATABASE  ?= kintex7
CHIPDB_DIR     ?= /opt/openxc7/nextpnr-xilinx/xilinx/chipdb
CHIPDB         ?= $(CHIPDB_DIR)/chipdb-$(PART_KC705).bin

# Source File Groups
INCLUDES       := -I$(RTL_DIR)/include -I$(RTL_DIR)/library -I$(RTL_DIR)/core \
                  -I$(RTL_DIR)/shared_ex -I$(RTL_DIR)/mmu -I$(RTL_DIR)/cache \
                  -I$(RTL_DIR)/interrupt -I$(RTL_DIR)/bus

SRC_LIB        := $(wildcard $(RTL_DIR)/library/*.v)
SRC_INT        := $(wildcard $(RTL_DIR)/interrupt/*.v)
SRC_MMU        := $(wildcard $(RTL_DIR)/mmu/*.v)
SRC_SHARED     := $(wildcard $(RTL_DIR)/shared_ex/*.v)
SRC_CACHE      := $(wildcard $(RTL_DIR)/cache/*.v)
SRC_CORE       := $(wildcard $(RTL_DIR)/core/*.v)
SRC_BUS        := $(wildcard $(RTL_DIR)/bus/*.v)
SRC_TOP        := $(RTL_DIR)/sukuna_top.v

ALL_RTL_SRCS   := $(SRC_TOP) $(SRC_LIB) $(SRC_INT) $(SRC_MMU) $(SRC_SHARED) \
                  $(SRC_CACHE) $(SRC_CORE) $(SRC_BUS)

# Default Target
.PHONY: all help
all: help

help:
	@echo "Sukuna-RISC Build System"
	@echo "========================"
	@echo "Available targets:"
	@echo "  make lint            : Run Verilator and Icarus Verilog lint checks"
	@echo "  make openxc7         : Run openxc7 flow (Synthesis -> PnR -> Bitstream for KC705)"
	@echo "  make openxc7-synth   : Run openxc7 Yosys synthesis only"
	@echo "  make openxc7-pnr     : Run openxc7 nextpnr-xilinx place & route"
	@echo "  make openxc7-bit     : Generate FPGA bitstream via Project X-Ray"
	@echo "  make vivado-kc705    : Run Vivado batch synthesis for KC705"
	@echo "  make vivado-zcu104   : Run Vivado batch synthesis for ZCU104"
	@echo "  make clean           : Remove build artifacts"

# ----------------------------------------------------------------------------
# Simulation Targets
# ----------------------------------------------------------------------------
.PHONY: sim sim-build

SRC_TB := tb/sukuna_tb_top.v tb/sukuna_axi_mem.v

sim: sim-build
	@echo "==> Running simulation with vvp..."
	vvp $(BUILD_DIR)/sukuna_tb $(EXTRA_SIM_ARGS)

sim-build: $(ALL_RTL_SRCS) $(SRC_TB) | $(BUILD_DIR)
	@echo "==> Compiling testbench with Icarus Verilog..."
	$(IVERILOG) -g2005 -Wall -Wno-timescale $(CONFIG_DEFINES) $(INCLUDES) -Itb -o $(BUILD_DIR)/sukuna_tb $(ALL_RTL_SRCS) $(SRC_TB)

# ----------------------------------------------------------------------------
# Lint & Syntax Validation Targets
# ----------------------------------------------------------------------------
.PHONY: lint lint-verilator lint-iverilog
lint: lint-verilator lint-iverilog
	@echo "[SUCCESS] All RTL lint checks passed."

lint-verilator:
	@echo "==> Running Verilator lint..."
	$(VERILATOR) --lint-only --top-module $(TOP_MODULE) $(CONFIG_DEFINES) $(INCLUDES) $(ALL_RTL_SRCS)

lint-iverilog:
	@echo "==> Running Icarus Verilog syntax check..."
	$(IVERILOG) -g2005 -Wall -Wno-timescale $(CONFIG_DEFINES) $(INCLUDES) -o /dev/null $(ALL_RTL_SRCS)

# ----------------------------------------------------------------------------
# OpenXC7 Flow Targets (Kintex-7 / KC705)
# ----------------------------------------------------------------------------
.PHONY: openxc7 openxc7-synth openxc7-pnr openxc7-bit

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

openxc7: openxc7-bit
	@echo "[SUCCESS] OpenXC7 bitstream generation completed."

openxc7-synth: $(BUILD_DIR)/sukuna_kc705.json

$(BUILD_DIR)/sukuna_kc705.json: $(ALL_RTL_SRCS) $(BSP_DIR)/kc705/sukuna_kc705_top.v | $(BUILD_DIR)
	@echo "==> Running OpenXC7 Yosys synthesis..."
	$(YOSYS) -v 3 -l $(BUILD_DIR)/yosys.log -s $(SCRIPTS_DIR)/openxc7_synth.ys

openxc7-pnr: $(BUILD_DIR)/sukuna_kc705.fasm

$(BUILD_DIR)/sukuna_kc705.fasm: $(BUILD_DIR)/sukuna_kc705.json $(BSP_DIR)/kc705/kc705.xdc
	@echo "==> Running OpenXC7 nextpnr-xilinx PnR..."
	$(NEXTPNR_XILINX) \
		--chipdb $(CHIPDB) \
		--xdc $(BSP_DIR)/kc705/kc705.xdc \
		--json $(BUILD_DIR)/sukuna_kc705.json \
		--fasm $(BUILD_DIR)/sukuna_kc705.fasm \
		--log $(BUILD_DIR)/nextpnr.log

openxc7-bit: $(BUILD_DIR)/sukuna_kc705.bit

$(BUILD_DIR)/sukuna_kc705.bit: $(BUILD_DIR)/sukuna_kc705.fasm
	@echo "==> Generating Bitstream via Project X-Ray..."
	$(FASM2FRAMES) --part $(PART_KC705) --db-root $(XRAY_DIR)/$(XRAY_DATABASE) \
		$(BUILD_DIR)/sukuna_kc705.fasm $(BUILD_DIR)/sukuna_kc705.frames
	$(XC7FRAMES2BIT) --part-name $(PART_KC705) --part-file $(XRAY_DIR)/$(XRAY_DATABASE)/$(PART_KC705).yaml \
		$(BUILD_DIR)/sukuna_kc705.frames $(BUILD_DIR)/sukuna_kc705.bit

# ----------------------------------------------------------------------------
# Vendor Vivado Targets
# ----------------------------------------------------------------------------
.PHONY: vivado-kc705 vivado-zcu104

vivado-kc705:
	@echo "==> Running Vivado batch synthesis for KC705..."
	$(MAKE) -C $(BSP_DIR)/kc705 synth

vivado-zcu104:
	@echo "==> Running Vivado batch synthesis for ZCU104..."
	cd $(BSP_DIR)/zcu104 && $(VIVADO) -mode batch -source zcu104_synth.tcl

# ----------------------------------------------------------------------------
# Clean
# ----------------------------------------------------------------------------
.PHONY: clean
clean:
	rm -rf $(BUILD_DIR)
	rm -rf $(BSP_DIR)/kc705/build_kc705 $(BSP_DIR)/kc705/*.log $(BSP_DIR)/kc705/*.jou $(BSP_DIR)/kc705/*.dcp $(BSP_DIR)/kc705/*.rpt $(BSP_DIR)/kc705/.Xil
	rm -rf $(BSP_DIR)/zcu104/build_zcu104 $(BSP_DIR)/zcu104/*.log $(BSP_DIR)/zcu104/*.jou $(BSP_DIR)/zcu104/*.dcp $(BSP_DIR)/zcu104/*.rpt $(BSP_DIR)/zcu104/.Xil
