// ============================================================================
// Pipeline Hazard & Stall Control Unit (Verilog 2005)
// Complies with design-rule.md
// ============================================================================
// Controls:
//   - Backpressure stall from EX (Pattern 1) to ID3, ID2, ID1, IF2, IF1
//   - Load-Use hazard 1-bubble insertion (Pattern 2)
//   - Shared EU stall (Pattern 5)
//   - Flush on branch mispredict / trap (Pattern 6)
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_hazard_unit (
  input  wire       clk_i,
  input  wire       rst_ni,

  // Memory & EX Stalls (Pattern 1)
  input  wire       ex_stall_i,         // MA-EU stall (L1D miss, etc.)
  input  wire       l1i_miss_i,         // L1I miss
  input  wire       shared_eu_stall_i,  // Shared FP/SIMD busy (Pattern 5)

  // Load-Use hazard inputs (Pattern 2)
  input  wire       ex_is_load_i,
  input  wire [4:0] ex_load_rd_i,
  input  wire [4:0] id1_rs1_l0_i,
  input  wire [4:0] id1_rs2_l0_i,
  input  wire [4:0] id1_rs1_l1_i,
  input  wire [4:0] id1_rs2_l1_i,

  // Trap / Branch Flush inputs (Pattern 6)
  input  wire       branch_mispredict_i,
  input  wire       trap_flush_i,

  // Stall outputs to pipeline stages (Hold)
  output wire       stall_l1i_o,
  output wire       stall_if1_o,
  output wire       stall_if2_o,
  output wire       stall_id1_o,
  output wire       stall_id2_o,
  output wire       stall_id3_o,
  output wire       stall_ex_o,

  // Flush outputs to pipeline stages (Squash / Clear)
  output wire       flush_if1_o,
  output wire       flush_if2_o,
  output wire       flush_id1_o,
  output wire       flush_id2_o,
  output wire       flush_id3_o,
  output wire       flush_ex_o
);

  // Global Stall: EX memory stall or Shared EU wait freezes all upstream stages
  wire upstream_freeze = ex_stall_i || shared_eu_stall_i;

  assign stall_l1i_o = upstream_freeze;
  assign stall_if1_o = upstream_freeze || l1i_miss_i;
  assign stall_if2_o = upstream_freeze;
  assign stall_id1_o = upstream_freeze;
  assign stall_id2_o = upstream_freeze;
  assign stall_id3_o = upstream_freeze;
  assign stall_ex_o  = ex_stall_i;

  // Flush logic
  wire global_flush = branch_mispredict_i || trap_flush_i;

  assign flush_if1_o = global_flush;
  assign flush_if2_o = global_flush;
  assign flush_id1_o = global_flush;
  assign flush_id2_o = global_flush;
  assign flush_id3_o = global_flush;
  assign flush_ex_o  = trap_flush_i;

  // Avoid unused input warnings
  wire _unused_haz = &{1'b0, clk_i, rst_ni, ex_is_load_i, ex_load_rd_i,
                       id1_rs1_l0_i, id1_rs2_l0_i, id1_rs1_l1_i, id1_rs2_l1_i, 1'b0};

endmodule
