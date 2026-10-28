# ============================================================================
# Sukuna-RISC Configuration Parameters (config.mk)
# ============================================================================

# Physical Address Width (choose from 32 to 40 bits)
# 40: RISC-V SV39/SV48 physical address (1 TB addressable space)
# 36: Typical 64 GB embedded/FPGA physical address
# 32: 4 GB physical address
PADDR_WIDTH    ?= 40

# Cache Set-Associativity Parameters (N >= 2, N <= 32)
L1I_WAYS       ?= 4
L1D_WAYS       ?= 4
L2_WAYS        ?= 8

# Cache Capacities (Bytes)
L1I_SIZE_BYTES ?= 16384
L1D_SIZE_BYTES ?= 16384
L2_SIZE_BYTES  ?= 262144
