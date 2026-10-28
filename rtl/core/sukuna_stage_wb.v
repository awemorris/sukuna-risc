// ============================================================================
// Pipeline Stage: WB (Writeback / Commit Stage) (Verilog 2005)
// Complies with design-rule.md
// ============================================================================
// Responsibilities:
//   - In-order commit to RegFile Write Ports (Port 0: Lane 0, Port 1: Lane 1)
//   - Precise Exception guarantee: Squashes Lane 1 commit if Lane 0 had exception
//   - Drives CSR Commit Interface and Privileged Ret/Trap commands to CSR Unit
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
  input  wire [XLEN-1:0]  l0_pc_i,
  input  wire [4:0]       l0_rd_i,
  input  wire [XLEN-1:0]  l0_data_i,
  input  wire             l0_exc_i,
  input  wire [5:0]       l0_cause_i,
  input  wire [XLEN-1:0]  l0_tval_i,

  // Lane 0 Privileged & CSR commit from EX
  input  wire             l0_csr_wen_i,
  input  wire [11:0]      l0_csr_addr_i,
  input  wire [XLEN-1:0]  l0_csr_wdata_i,
  input  wire             l0_mret_i,
  input  wire             l0_sret_i,
  input  wire             l0_wfi_i,
  input  wire             l0_sfence_i,

  // Lane 1 Result from EX (younger)
  input  wire             l1_valid_i,
  input  wire [XLEN-1:0]  l1_pc_i,
  input  wire [4:0]       l1_rd_i,
  input  wire [XLEN-1:0]  l1_data_i,
  input  wire             l1_exc_i,
  input  wire [5:0]       l1_cause_i,
  input  wire [XLEN-1:0]  l1_tval_i,

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

  // CSR Unit Commit Interface
  output wire             csr_commit_wen_o,
  output wire [11:0]      csr_commit_addr_o,
  output wire [XLEN-1:0]  csr_commit_wdata_o,

  // Precise Exception Trap output to CSR Unit
  output wire             trap_valid_o,
  output wire [5:0]       trap_cause_o,
  output wire [XLEN-1:0]  trap_pc_o,
  output wire [XLEN-1:0]  trap_tval_o,

  // Privileged return / execution commands to CSR Unit
  output wire             mret_valid_o,
  output wire             sret_valid_o,
  output wire             wfi_valid_o,
  output wire             sfence_valid_o
);

  wire _unused = &{1'b0, clk_i, rst_ni, 1'b0};

  // If Lane 0 incurs an exception, Lane 1 MUST NOT commit!
  wire lane0_has_trap = l0_valid_i && l0_exc_i;
  wire lane1_has_trap = l1_valid_i && l1_exc_i;

  // Port 0: Lane 0 Commit
  assign rf_wen_p0_o   = l0_valid_i && !l0_exc_i && (l0_rd_i != 5'd0);
  assign rf_waddr_p0_o = l0_rd_i;
  assign rf_wdata_p0_o = l0_data_i;

  // Port 1: Lane 1 Commit (Squashed if Lane 0 trapped)
  assign rf_wen_p1_o   = l1_valid_i && !lane0_has_trap && !l1_exc_i && (l1_rd_i != 5'd0);
  assign rf_waddr_p1_o = l1_rd_i;
  assign rf_wdata_p1_o = l1_data_i;

  // Port 2: Shared EU Commit
  assign rf_wen_p2_o   = shared_valid_i && !lane0_has_trap && (shared_rd_i != 5'd0);
  assign rf_waddr_p2_o = shared_rd_i;
  assign rf_wdata_p2_o = shared_data_i;

  // CSR Write: Commits at WB stage if Lane 0 had no exception
  assign csr_commit_wen_o   = l0_valid_i && !l0_exc_i && l0_csr_wen_i;
  assign csr_commit_addr_o  = l0_csr_addr_i;
  assign csr_commit_wdata_o = l0_csr_wdata_i;

  // Privileged commands: Commit at WB stage
  assign mret_valid_o   = l0_valid_i && !l0_exc_i && l0_mret_i;
  assign sret_valid_o   = l0_valid_i && !l0_exc_i && l0_sret_i;
  assign wfi_valid_o    = l0_valid_i && !l0_exc_i && l0_wfi_i;
  assign sfence_valid_o = l0_valid_i && !l0_exc_i && l0_sfence_i;

  // Trap generation
  assign trap_valid_o  = lane0_has_trap || lane1_has_trap;
  assign trap_cause_o  = lane0_has_trap ? l0_cause_i : l1_cause_i;
  assign trap_pc_o     = lane0_has_trap ? l0_pc_i    : l1_pc_i;
  assign trap_tval_o   = lane0_has_trap ? l0_tval_i  : l1_tval_i;

endmodule
