// ============================================================================
// L2 Cache Arbiter / Crossbar (Verilog 2005)
// Multiplexes requests from 3x L1I, 3x L1D, and PTW to Shared L2 cache
// Word-aligned address interface (bits [1:0] omitted)
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_l2_arbiter #(
  parameter NUM_HARTS       = `NUM_HARTS,
  parameter PADDR_WIDTH     = `PADDR_WIDTH,
  parameter CACHE_LINE_BITS = `CACHE_LINE_BITS
)(
  input  wire                               clk_i,
  input  wire                               rst_ni,

  // 3x L1I Refill Requests (Word-aligned: bits [1:0] omitted)
  input  wire [NUM_HARTS-1:0]               l1i_req_valid_i,
  input  wire [NUM_HARTS*(PADDR_WIDTH-2)-1:0] l1i_line_paddr_w_i,
  output wire [NUM_HARTS-1:0]               l1i_req_ready_o,
  output wire [NUM_HARTS-1:0]               l1i_resp_valid_o,
  output wire [NUM_HARTS*CACHE_LINE_BITS-1:0] l1i_line_data_o,

  // 3x L1D Miss/Evict Requests (Word-aligned: bits [1:0] omitted)
  input  wire [NUM_HARTS-1:0]               l1d_req_valid_i,
  input  wire [NUM_HARTS-1:0]               l1d_req_write_i,
  input  wire [NUM_HARTS*(PADDR_WIDTH-2)-1:0] l1d_line_paddr_w_i,
  input  wire [NUM_HARTS*CACHE_LINE_BITS-1:0] l1d_wline_data_i,
  output wire [NUM_HARTS-1:0]               l1d_req_ready_o,
  output wire [NUM_HARTS-1:0]               l1d_resp_valid_o,
  output wire [NUM_HARTS*CACHE_LINE_BITS-1:0] l1d_rline_data_o,

  // 1x PTW Request
  input  wire                               ptw_req_valid_i,
  input  wire [PADDR_WIDTH-1:2]             ptw_paddr_w_i,
  output wire                               ptw_req_ready_o,
  output wire                               ptw_resp_valid_o,
  output wire [`XLEN-1:0]                   ptw_data_o,

  // Unified Request to Shared L2 Cache (Word-aligned: bits [1:0] omitted)
  output reg                                l2_req_valid_o,
  output reg                                l2_req_write_o,
  output reg  [3:0]                         l2_req_source_o,
  output reg  [PADDR_WIDTH-1:2]             l2_req_paddr_w_o,
  output reg  [CACHE_LINE_BITS-1:0]         l2_req_wdata_o,
  input  wire                               l2_req_ready_i,

  input  wire                               l2_resp_valid_i,
  input  wire [3:0]                         l2_resp_source_i,
  input  wire [CACHE_LINE_BITS-1:0]         l2_resp_rdata_i
);

  assign l1i_req_ready_o    = {NUM_HARTS{l2_req_ready_i}};
  assign l1i_resp_valid_o   = {NUM_HARTS{l2_resp_valid_i && (l2_resp_source_i < 3)}};
  assign l1i_line_data_o    = {NUM_HARTS{l2_resp_rdata_i}};

  assign l1d_req_ready_o    = {NUM_HARTS{l2_req_ready_i}};
  assign l1d_resp_valid_o   = {NUM_HARTS{l2_resp_valid_i && (l2_resp_source_i >= 3 && l2_resp_source_i < 6)}};
  assign l1d_rline_data_o   = {NUM_HARTS{l2_resp_rdata_i}};

  assign ptw_req_ready_o    = l2_req_ready_i;
  assign ptw_resp_valid_o   = l2_resp_valid_i && (l2_resp_source_i == 4'd6);
  assign ptw_data_o         = l2_resp_rdata_i[`XLEN-1:0];

  always @(*) begin
    l2_req_valid_o   = 1'b0;
    l2_req_write_o   = 1'b0;
    l2_req_source_o  = 4'd0;
    l2_req_paddr_w_o = {(PADDR_WIDTH-2){1'b0}};
    l2_req_wdata_o   = {CACHE_LINE_BITS{1'b0}};

    if (ptw_req_valid_i) begin
      l2_req_valid_o   = 1'b1;
      l2_req_source_o  = 4'd6;
      l2_req_paddr_w_o = ptw_paddr_w_i;
    end else if (|l1d_req_valid_i) begin
      l2_req_valid_o   = 1'b1;
      l2_req_write_o   = l1d_req_write_i[0];
      l2_req_source_o  = 4'd3;
      l2_req_paddr_w_o = l1d_line_paddr_w_i[PADDR_WIDTH-3:0];
      l2_req_wdata_o   = l1d_wline_data_i[CACHE_LINE_BITS-1:0];
    end else if (|l1i_req_valid_i) begin
      l2_req_valid_o   = 1'b1;
      l2_req_source_o  = 4'd0;
      l2_req_paddr_w_o = l1i_line_paddr_w_i[PADDR_WIDTH-3:0];
    end
  end

endmodule
