// ============================================================================
// Sukuna-RISC Global Header Definitions (Verilog 2005)
// ============================================================================

`ifndef SUKUNA_DEFINES_VH
`define SUKUNA_DEFINES_VH

`timescale 1ns / 1ps

// Architecture Parameters
`define XLEN              64
`define VADDR_WIDTH       64
`define PADDR_WIDTH       56
`define NUM_HARTS         3

`define HART_KERNEL       0
`define HART_FG           1
`define HART_BG           2

// Cache Parameters
`define CACHE_LINE_BYTES  64
`define CACHE_LINE_BITS   512
`define L1I_SIZE_BYTES    16384
`define L1D_SIZE_BYTES    16384
`define L2_SIZE_BYTES     262144

// MMU & TLB Parameters
`define L1_TLB_ENTRIES    8
`define L2_TLB_ENTRIES    256

// AXI4 Parameters
`define AXI_ADDR_WIDTH    64
`define AXI_DATA_WIDTH    128
`define AXI_ID_WIDTH      8

// Issue Slot Types
`define SLOT_NONE         2'b00
`define SLOT_INT          2'b01
`define SLOT_MA           2'b10
`define SLOT_FP           2'b11

// ALU Operations
`define ALU_ADD           4'b0000
`define ALU_SUB           4'b0001
`define ALU_SLL           4'b0010
`define ALU_SLT           4'b0011
`define ALU_SLTU          4'b0100
`define ALU_XOR           4'b0101
`define ALU_SRL           4'b0110
`define ALU_SRA           4'b0111
`define ALU_OR            4'b1000
`define ALU_AND           4'b1001
`define ALU_MUL           4'b1010
`define ALU_DIV           4'b1011
`define ALU_REM           4'b1100

// Memory Access Operations
`define MEM_LB            3'b000
`define MEM_LH            3'b001
`define MEM_LW            3'b010
`define MEM_LD            3'b011
`define MEM_SB            3'b100
`define MEM_SH            3'b101
`define MEM_SW            3'b110
`define MEM_SD            3'b111

`endif // SUKUNA_DEFINES_VH
