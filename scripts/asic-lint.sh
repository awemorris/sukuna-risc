#!/bin/bash
# ============================================================================
# asic-lint.sh: Run the ASIC 5nm 1.5 GHz High-Frequency Architecture Linter
# for Sukuna-RISC
# ============================================================================
set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: scripts/asic-lint.sh <module_name> [clock_period_ns] [extra_verilog_defines]"
    echo "Example: scripts/asic-lint.sh sukuna_int_eu 4.000"
    exit 1
fi

mod=$1
period=${2:-4.000}
defines=${3:-}

root=$(cd "$(dirname -- "$0")/.." && pwd)

# Locate Vivado settings and libraries
VIVADO_DIR=""
for d in /home/awe/opt/amd/*/Vivado /home/awe/opt/Xilinx/Vivado/* /opt/Xilinx/Vivado/*; do
    if [ -d "$d" ]; then
        VIVADO_DIR="$d"
        break
    fi
done

VIVADO_SETTINGS="${VIVADO_DIR}/settings64.sh"
VIVADO_UBUNTU_LIB=""
if [ -d "${VIVADO_DIR}/lib/lnx64.o/Ubuntu/24" ]; then
    VIVADO_UBUNTU_LIB="${VIVADO_DIR}/lib/lnx64.o/Ubuntu/24"
elif [ -d "${VIVADO_DIR}/lib/lnx64.o/Ubuntu/22" ]; then
    VIVADO_UBUNTU_LIB="${VIVADO_DIR}/lib/lnx64.o/Ubuntu/22"
fi

export VIVADO_THREADS=2
export VIVADO_MAX_THREADS=2

if [ -f "$VIVADO_SETTINGS" ]; then
    # Source Vivado environment silently
    set +u
    source "$VIVADO_SETTINGS" > /dev/null 2>&1
    set -u
    if [ -n "$VIVADO_UBUNTU_LIB" ]; then
        export LD_LIBRARY_PATH="${VIVADO_UBUNTU_LIB}:${LD_LIBRARY_PATH:-}"
    fi
fi

exec vivado -mode batch -source "${root}/scripts/asic-lint.tcl" -tclargs "$mod" "$period" "$defines"
