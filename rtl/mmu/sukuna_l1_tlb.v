// ============================================================================
// Micro L1-TLB Stub (8 Entries) (Verilog 2005)
// 1-cycle latency virtual-to-physical address translation per thread
// Word-aligned interface (bits [1:0] omitted)
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_l1_tlb #(
  parameter NUM_ENTRIES = `L1_TLB_ENTRIES,
  parameter VADDR_WIDTH = `VADDR_WIDTH,
  parameter PADDR_WIDTH = `PADDR_WIDTH
)(
  input  wire                   clk_i,
  input  wire                   rst_ni,

  // Pipeline Translation Interface (Word-aligned: bits [1:0] omitted)
  input  wire                   lookup_valid_i,
  input  wire [VADDR_WIDTH-1:2] vaddr_w_i,
  output wire                   hit_o,
  output wire [PADDR_WIDTH-1:2] paddr_w_o,
  output wire                   page_fault_o,

  // L2-TLB Refill Interface (on L1 miss)
  output wire                   refill_req_o,
  output wire [VADDR_WIDTH-1:2] refill_vaddr_w_o,
  input  wire                   refill_resp_valid_i,
  input  wire [PADDR_WIDTH-1:2] refill_paddr_w_i,
  input  wire                   refill_fault_i,

  // Flush Interface (SFENCE.VMA)
  input  wire                   flush_i
);

  // Stub passthrough: 1:1 direct mapping for initial testing
  assign hit_o            = lookup_valid_i;
  assign paddr_w_o        = vaddr_w_i[PADDR_WIDTH-1:2];
  assign page_fault_o     = 1'b0;

  assign refill_req_o     = 1'b0;
  assign refill_vaddr_w_o = vaddr_w_i;

endmodule
