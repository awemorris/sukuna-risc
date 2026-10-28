// ============================================================================
// L1 Instruction Cache (16KB) Stub (Verilog 2005)
// Dedicated per-thread instruction cache, read-only
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_l1i_cache #(
  parameter PADDR_WIDTH     = `PADDR_WIDTH,
  parameter CACHE_LINE_BITS = `CACHE_LINE_BITS
)(
  input  wire                       clk_i,
  input  wire                       rst_ni,

  // Fetch Pipeline Interface
  input  wire                       fetch_req_valid_i,
  input  wire [PADDR_WIDTH-1:0]     fetch_paddr_i,
  output wire                       fetch_resp_valid_o,
  output wire [31:0]                fetch_inst_o,
  output wire                       fetch_miss_o,

  // L2 Refill Interface
  output wire                       refill_req_valid_o,
  output wire [PADDR_WIDTH-1:0]     refill_line_paddr_o,
  input  wire                       refill_req_ready_i,
  input  wire                       refill_resp_valid_i,
  input  wire [CACHE_LINE_BITS-1:0] refill_line_data_i,

  // Invalidate Interface (e.g. FENCE.I)
  input  wire                       fence_i_flush_i
);

  // Stub direct pass-through/dummy response
  assign fetch_resp_valid_o   = fetch_req_valid_i;
  assign fetch_inst_o         = 32'h00000013; // NOP (addi x0, x0, 0)
  assign fetch_miss_o         = 1'b0;

  assign refill_req_valid_o   = 1'b0;
  assign refill_line_paddr_o  = fetch_paddr_i;

endmodule
