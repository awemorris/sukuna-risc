// ============================================================================
// Shared L2-TLB Stub (256 Entries) (Verilog 2005)
// Multi-cycle shared TLB servicing misses from all threads' L1-TLBs
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_l2_tlb #(
  parameter NUM_ENTRIES = `L2_TLB_ENTRIES,
  parameter VADDR_WIDTH = `VADDR_WIDTH,
  parameter PADDR_WIDTH = `PADDR_WIDTH
)(
  input  wire                   clk_i,
  input  wire                   rst_ni,

  // Request Interface from L1-TLB Arbiter
  input  wire                   req_valid_i,
  input  wire [1:0]             req_hart_id_i,
  input  wire [VADDR_WIDTH-1:0] req_vaddr_i,
  output wire                   req_ready_o,

  // Response Interface to L1-TLBs
  output wire                   resp_valid_o,
  output wire [1:0]             resp_hart_id_o,
  output wire [PADDR_WIDTH-1:0] resp_paddr_o,
  output wire                   resp_fault_o,

  // Interface to Hardware Page Table Walker (on L2-TLB miss)
  output wire                   ptw_req_valid_o,
  output wire [1:0]             ptw_req_hart_id_o,
  output wire [VADDR_WIDTH-1:0] ptw_req_vaddr_o,
  input  wire                   ptw_req_ready_i,
  input  wire                   ptw_resp_valid_i,
  input  wire [PADDR_WIDTH-1:0] ptw_resp_paddr_i,
  input  wire                   ptw_resp_fault_i,

  // Flush Interface
  input  wire                   flush_i
);

  assign req_ready_o        = 1'b1;
  assign resp_valid_o       = req_valid_i;
  assign resp_hart_id_o     = req_hart_id_i;
  assign resp_paddr_o       = req_vaddr_i[PADDR_WIDTH-1:0];
  assign resp_fault_o       = 1'b0;

  assign ptw_req_valid_o    = 1'b0;
  assign ptw_req_hart_id_o  = req_hart_id_i;
  assign ptw_req_vaddr_o    = req_vaddr_i;

endmodule
