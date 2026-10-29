// ============================================================================
// Pipeline Stage: IF1 (Instruction Fetch 1) (Verilog 2005)
// Complies with design-rule.md
// ============================================================================
// Responsibilities:
//   - Receives block fetch request from IF2 fetch buffer
//   - L1-ITLB virtual address translation request
//   - L1I instruction cache read request with word-aligned address [PADDR_WIDTH-1:2]
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_stage_if1 #(
  parameter HART_ID     = 0,
  parameter XLEN        = `XLEN,
  parameter VADDR_WIDTH = `VADDR_WIDTH,
  parameter PADDR_WIDTH = `PADDR_WIDTH,
  parameter RESET_PC    = 64'h0000_0000_8000_0000
)(
  input  wire                   clk_i,
  input  wire                   rst_ni,

  // Pipeline flow controls
  input  wire                   flush_i,
  input  wire                   fetch_req_valid_i,
  input  wire [XLEN-1:0]        fetch_req_pc_i,

  // L1-ITLB Translation Interface (Word-aligned: bits [1:0] omitted)
  output wire                   itlb_req_valid_o,
  output wire [VADDR_WIDTH-1:2] itlb_vaddr_w_o,
  input  wire                   itlb_hit_i,
  input  wire [PADDR_WIDTH-1:2] itlb_paddr_w_i,
  input  wire                   itlb_fault_i,

  // L1I Cache Request Interface (Word-aligned: lower 2 bits omitted)
  output wire                   l1i_req_valid_o,
  output wire [PADDR_WIDTH-1:2] l1i_paddr_w_o
);

  wire [31:0] _unused_hart = HART_ID;
  wire _unused = &{1'b0, clk_i, rst_ni, itlb_fault_i, 1'b0};

  // Request virtual address to ITLB (word-aligned)
  assign itlb_req_valid_o = fetch_req_valid_i && !flush_i;
  assign itlb_vaddr_w_o   = fetch_req_pc_i[VADDR_WIDTH-1:2];

  // Physical address request to L1I (Word-aligned)
  assign l1i_req_valid_o  = itlb_hit_i && fetch_req_valid_i && !flush_i;
  assign l1i_paddr_w_o    = itlb_paddr_w_i;

endmodule
