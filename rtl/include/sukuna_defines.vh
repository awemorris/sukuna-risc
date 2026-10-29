// ============================================================================
// Sukuna-RISC Global Header Definitions (Verilog 2005)
// ============================================================================

`ifndef SUKUNA_DEFINES_VH
`define SUKUNA_DEFINES_VH

`timescale 1ns / 1ps

// Architecture Parameters
`define XLEN              64
`define VADDR_WIDTH       64

`ifndef PADDR_WIDTH
`define PADDR_WIDTH       40
`endif

`define NUM_HARTS         3

`define HART_KERNEL       0
`define HART_FG           1
`define HART_BG           2

// Cache Parameters
`define CACHE_LINE_BYTES  64
`define CACHE_LINE_BITS   512

`ifndef L1I_WAYS
`define L1I_WAYS          4
`endif

`ifndef L1D_WAYS
`define L1D_WAYS          4
`endif

`ifndef L2_WAYS
`define L2_WAYS           8
`endif

`ifndef L1I_SIZE_BYTES
`define L1I_SIZE_BYTES    16384
`endif

`ifndef L1D_SIZE_BYTES
`define L1D_SIZE_BYTES    16384
`endif

`ifndef L2_SIZE_BYTES
`define L2_SIZE_BYTES     262144
`endif

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

// ALU Operations (5-bit)
`define ALU_ADD           5'd0
`define ALU_SUB           5'd1
`define ALU_SLL           5'd2
`define ALU_SLT           5'd3
`define ALU_SLTU          5'd4
`define ALU_XOR           5'd5
`define ALU_SRL           5'd6
`define ALU_SRA           5'd7
`define ALU_OR            5'd8
`define ALU_AND           5'd9
`define ALU_MUL           5'd10
`define ALU_MULH          5'd11
`define ALU_MULHSU        5'd12
`define ALU_MULHU         5'd13
`define ALU_DIV           5'd14
`define ALU_DIVU          5'd15
`define ALU_REM           5'd16
`define ALU_REMU          5'd17
`define ALU_FP            5'd18

// Branch Operations
`define BR_NONE           3'b000
`define BR_BEQ            3'b001
`define BR_BNE            3'b010
`define BR_BLT            3'b011
`define BR_BGE            3'b100
`define BR_BLTU           3'b101
`define BR_BGEU           3'b110

// Jump Operations
`define JUMP_NONE         2'b00
`define JUMP_JAL          2'b01
`define JUMP_JALR         2'b10

// Memory Access Operations (4 bits: bit 3 = write, bits [2:0] = funct3)
`define MEM_LB            4'b0000
`define MEM_LH            4'b0001
`define MEM_LW            4'b0010
`define MEM_LD            4'b0011
`define MEM_LBU           4'b0100
`define MEM_LHU           4'b0101
`define MEM_LWU           4'b0110
`define MEM_SB            4'b1000
`define MEM_SH            4'b1001
`define MEM_SW            4'b1010
`define MEM_SD            4'b1011

// Atomic Memory Operation Sub-types (mem_op[7:4])
`define AMO_NONE          4'd0
`define AMO_LR            4'd1
`define AMO_SC            4'd2
`define AMO_SWAP          4'd3
`define AMO_ADD           4'd4
`define AMO_XOR           4'd5
`define AMO_AND           4'd6
`define AMO_OR            4'd7
`define AMO_MIN           4'd8
`define AMO_MAX           4'd9
`define AMO_MINU          4'd10
`define AMO_MAXU          4'd11
`define AMO_FP            4'd12

// System / CSR Operations
`define SYS_NONE          3'b000
`define SYS_CSRRW         3'b001
`define SYS_CSRRS         3'b010
`define SYS_CSRRC         3'b011
`define SYS_PRIV          3'b100

// Privileged Sub-ops (when SYS_PRIV)
`define PRIV_NONE         3'b000
`define PRIV_ECALL        3'b001
`define PRIV_EBREAK       3'b010
`define PRIV_MRET         3'b011
`define PRIV_SRET         3'b100
`define PRIV_WFI          3'b101
`define PRIV_SFENCE_VMA   3'b110
`define PRIV_FENCE_I      3'b111

// Exception Causes
`define EXC_INST_ADDR_MISALIGNED  6'd0
`define EXC_INST_ACCESS_FAULT     6'd1
`define EXC_ILLEGAL_INST          6'd2
`define EXC_BREAKPOINT            6'd3
`define EXC_LOAD_ADDR_MISALIGNED  6'd4
`define EXC_LOAD_ACCESS_FAULT     6'd5
`define EXC_STORE_ADDR_MISALIGNED 6'd6
`define EXC_STORE_ACCESS_FAULT    6'd7
`define EXC_ECALL_U               6'd8
`define EXC_ECALL_S               6'd9
`define EXC_ECALL_M               6'd11
`define EXC_INST_PAGE_FAULT       6'd12
`define EXC_LOAD_PAGE_FAULT       6'd13
`define EXC_STORE_PAGE_FAULT      6'd15

// Interrupt Causes (bit 63 = 1)
`define INT_S_SOFTWARE            6'd1
`define INT_M_SOFTWARE            6'd3
`define INT_S_TIMER               6'd5
`define INT_M_TIMER               6'd7
`define INT_S_EXTERNAL            6'd9
`define INT_M_EXTERNAL            6'd11

// Target Platform Synthesis Directives
// Define SYNTH_KINTEX7 to instantiate Xilinx Kintex-7 DSP48E1 primitives directly
// (Can also be passed via compiler flag -DSYNTH_KINTEX7)
// `define SYNTH_KINTEX7 1

`endif // SUKUNA_DEFINES_VH
