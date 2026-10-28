// ============================================================================
// Writeback & Commit Unit (WB) Stub (Verilog 2005)
// Finalizes instruction execution and routes commit data to Register File
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_writeback #(
  parameter XLEN = `XLEN
)(
  input  wire             clk_i,
  input  wire             rst_ni,

  // Slot 0 (INT) Result Input
  input  wire             int_valid_i,
  input  wire [4:0]       int_rd_i,
  input  wire [XLEN-1:0]  int_result_i,

  // Slot 1 (MA Load) Result Input
  input  wire             ma_valid_i,
  input  wire [4:0]       ma_rd_i,
  input  wire [XLEN-1:0]  ma_result_i,

  // Shared EU Result Input
  input  wire             shared_valid_i,
  input  wire [4:0]       shared_rd_i,
  input  wire [XLEN-1:0]  shared_result_i,

  // Regfile Write Ports
  output wire             rf_wen_p0_o,
  output wire [4:0]       rf_waddr_p0_o,
  output wire [XLEN-1:0]  rf_wdata_p0_o,

  output wire             rf_wen_p1_o,
  output wire [4:0]       rf_waddr_p1_o,
  output wire [XLEN-1:0]  rf_wdata_p1_o,

  output wire             rf_wen_p2_o,
  output wire [4:0]       rf_waddr_p2_o,
  output wire [XLEN-1:0]  rf_wdata_p2_o
);

  assign rf_wen_p0_o   = int_valid_i;
  assign rf_waddr_p0_o = int_rd_i;
  assign rf_wdata_p0_o = int_result_i;

  assign rf_wen_p1_o   = ma_valid_i;
  assign rf_waddr_p1_o = ma_rd_i;
  assign rf_wdata_p1_o = ma_result_i;

  assign rf_wen_p2_o   = shared_valid_i;
  assign rf_waddr_p2_o = shared_rd_i;
  assign rf_wdata_p2_o = shared_result_i;

endmodule
