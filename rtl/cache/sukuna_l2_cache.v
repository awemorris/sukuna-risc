// ============================================================================
// Shared L2 Cache (256KB) Stub (Verilog 2005)
// 8-way set associative unified cache with BIU memory refill interface
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_l2_cache #(
  parameter PADDR_WIDTH     = `PADDR_WIDTH,
  parameter CACHE_LINE_BITS = `CACHE_LINE_BITS
)(
  input  wire                       clk_i,
  input  wire                       rst_ni,

  // Interface from L1 Subsystem (L2 Arbiter)
  input  wire                       req_valid_i,
  input  wire                       req_write_i,
  input  wire [3:0]                 req_source_i,
  input  wire [PADDR_WIDTH-1:0]     req_paddr_i,
  input  wire [CACHE_LINE_BITS-1:0] req_wdata_i,
  output wire                       req_ready_o,

  output wire                       resp_valid_o,
  output wire [3:0]                 resp_source_o,
  output wire [CACHE_LINE_BITS-1:0] resp_rdata_o,

  // Memory interface to BIU (AXI4 bridge) on L2 miss/evict
  output wire                       mem_req_valid_o,
  output wire                       mem_req_write_o,
  output wire [PADDR_WIDTH-1:0]     mem_req_paddr_o,
  output wire [CACHE_LINE_BITS-1:0] mem_req_wdata_o,
  input  wire                       mem_req_ready_i,

  input  wire                       mem_resp_valid_i,
  input  wire [CACHE_LINE_BITS-1:0] mem_resp_rdata_i
);

  assign req_ready_o        = 1'b1;
  assign resp_valid_o       = req_valid_i;
  assign resp_source_o      = req_source_i;
  assign resp_rdata_o       = {CACHE_LINE_BITS{1'b0}};

  assign mem_req_valid_o    = 1'b0;
  assign mem_req_write_o    = 1'b0;
  assign mem_req_paddr_o    = req_paddr_i;
  assign mem_req_wdata_o    = req_wdata_i;

endmodule
