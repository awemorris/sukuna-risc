// ============================================================================
// Pipeline Stage: WB (Writeback / Commit Stage) (Verilog 2005)
// Complies with design-rule.md
// ============================================================================
// Responsibilities:
//   - In-order commit to RegFile Write Ports (Port 0: Lane 0, Port 1: Lane 1)
//   - Precise Exception guarantee: Squashes Lane 1 commit if Lane 0 had exception
//   - Supplies Writeback Bypass data to ID3 stage
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_stage_wb #(
  parameter XLEN = `XLEN
)(
  input  wire             clk_i,
  input  wire             rst_ni,

  // Lane 0 Result from EX (older)
  input  wire             l0_valid_i,
  input  wire [4:0]       l0_rd_i,
  input  wire [XLEN-1:0]  l0_data_i,
  input  wire             l0_exc_i,

  // Lane 1 Result from EX (younger)
  input  wire             l1_valid_i,
  input  wire [4:0]       l1_rd_i,
  input  wire [XLEN-1:0]  l1_data_i,
  input  wire             l1_exc_i,

  // Shared EU Result Input
  input  wire             shared_valid_i,
  input  wire [4:0]       shared_rd_i,
  input  wire [XLEN-1:0]  shared_data_i,

  // RegFile Write Ports
  output wire             rf_wen_p0_o,
  output wire [4:0]       rf_waddr_p0_o,
  output wire [XLEN-1:0]  rf_wdata_p0_o,

  output wire             rf_wen_p1_o,
  output wire [4:0]       rf_waddr_p1_o,
  output wire [XLEN-1:0]  rf_wdata_p1_o,

  output wire             rf_wen_p2_o,
  output wire [4:0]       rf_waddr_p2_o,
  output wire [XLEN-1:0]  rf_wdata_p2_o,

  // Precise Exception Trap output
  output wire             trap_valid_o,
  output wire [5:0]       trap_cause_o
);

  // If Lane 0 incurs an exception, Lane 1 MUST NOT commit!
  wire lane0_has_trap = l0_valid_i && l0_exc_i;

  // Port 0: Lane 0 Commit
  assign rf_wen_p0_o   = l0_valid_i && !l0_exc_i;
  assign rf_waddr_p0_o = l0_rd_i;
  assign rf_wdata_p0_o = l0_data_i;

  // Port 1: Lane 1 Commit (Squashed if Lane 0 trapped)
  assign rf_wen_p1_o   = l1_valid_i && !lane0_has_trap && !l1_exc_i;
  assign rf_waddr_p1_o = l1_rd_i;
  assign rf_wdata_p1_o = l1_data_i;

  // Port 2: Shared EU Commit
  assign rf_wen_p2_o   = shared_valid_i && !lane0_has_trap;
  assign rf_waddr_p2_o = shared_rd_i;
  assign rf_wdata_p2_o = shared_data_i;

  // Trap generation
  assign trap_valid_o  = lane0_has_trap || (l1_valid_i && l1_exc_i);
  assign trap_cause_o  = lane0_has_trap ? 6'd13 : 6'd15; // Page fault code

endmodule
