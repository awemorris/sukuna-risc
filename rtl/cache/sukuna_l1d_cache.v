// ============================================================================
// L1 Data Cache (16KB) Stub (Verilog 2005)
// Dedicated per-thread data cache with 2-cycle load/store pipeline
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_l1d_cache #(
  parameter XLEN            = `XLEN,
  parameter PADDR_WIDTH     = `PADDR_WIDTH,
  parameter CACHE_LINE_BITS = `CACHE_LINE_BITS
)(
  input  wire                       clk_i,
  input  wire                       rst_ni,

  // Pipeline AGU/MA Interface
  input  wire                       mem_req_valid_i,
  input  wire                       mem_req_write_i,
  input  wire [2:0]                 mem_req_op_i,
  input  wire [PADDR_WIDTH-1:0]     mem_paddr_i,
  input  wire [XLEN-1:0]            mem_wdata_i,
  output wire                       mem_req_ready_o,
  output wire                       mem_resp_valid_o,
  output wire [XLEN-1:0]            mem_rdata_o,
  output wire                       mem_miss_stall_o,

  // Coherence Snoop Port
  input  wire                       snoop_req_valid_i,
  input  wire [PADDR_WIDTH-1:0]     snoop_paddr_i,
  input  wire                       snoop_invalidate_i,
  output wire                       snoop_hit_o,

  // L2 Refill / Writeback Port
  output wire                       l2_req_valid_o,
  output wire                       l2_req_write_o,
  output wire [PADDR_WIDTH-1:0]     l2_line_paddr_o,
  output wire [CACHE_LINE_BITS-1:0] l2_wline_data_o,
  input  wire                       l2_req_ready_i,
  input  wire                       l2_resp_valid_i,
  input  wire [CACHE_LINE_BITS-1:0] l2_rline_data_i
);

  assign mem_req_ready_o    = 1'b1;
  assign mem_resp_valid_o   = mem_req_valid_i;
  assign mem_rdata_o        = {XLEN{1'b0}};
  assign mem_miss_stall_o   = 1'b0;

  assign snoop_hit_o        = 1'b0;

  assign l2_req_valid_o     = 1'b0;
  assign l2_req_write_o     = 1'b0;
  assign l2_line_paddr_o    = mem_paddr_i;
  assign l2_wline_data_o    = {CACHE_LINE_BITS{1'b0}};

endmodule
