// ============================================================================
// Pipeline Stage: ID2 (Instruction Decode 2) (Verilog 2005)
// Complies with design-rule.md
// ============================================================================
// Responsibilities:
//   - Parallel dependency checking (RAW / WAW) between Lane 0 and Lane 1
//   - Evaluates dual-issue compatibility ([INT, MA] or [MA, INT])
//   - Generates EX enable bits: int_en_l0/l1, ma_en_l0/l1
//   - Emits Half-width bubble on Lane 1 if single-issue
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_stage_id2 #(
  parameter XLEN = `XLEN
)(
  input  wire             clk_i,
  input  wire             rst_ni,

  // Pipeline flow controls
  input  wire             stall_i,
  input  wire             flush_i,
  input  wire             ma_eu_busy_i,

  // Inputs from ID1 stage
  input  wire             id1_valid0_i,
  input  wire [XLEN-1:0]  id1_pc0_i,
  input  wire [31:0]      id1_inst0_i,
  input  wire [1:0]       id1_type0_i,
  input  wire [4:0]       id1_rd0_i,
  input  wire [4:0]       id1_rs1_0_i,
  input  wire [4:0]       id1_rs2_0_i,
  input  wire [XLEN-1:0]  id1_imm0_i,
  input  wire [3:0]       id1_alu_op0_i,
  input  wire [2:0]       id1_mem_op0_i,

  input  wire             id1_valid1_i,
  input  wire [XLEN-1:0]  id1_pc1_i,
  input  wire [31:0]      id1_inst1_i,
  input  wire [1:0]       id1_type1_i,
  input  wire [4:0]       id1_rd1_i,
  input  wire [4:0]       id1_rs1_1_i,
  input  wire [4:0]       id1_rs2_1_i,
  input  wire [XLEN-1:0]  id1_imm1_i,
  input  wire [3:0]       id1_alu_op1_i,
  input  wire [2:0]       id1_mem_op1_i,

  // Feedback to fetch: how many instructions to advance (1 or 2)
  output wire [1:0]       consume_step_o,

  // Pipeline Registers to ID3 (Lane 0: older, Lane 1: younger)
  output reg              id2_valid0_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]  id2_pc0_o,      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [4:0]       id2_rd0_o,      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [4:0]       id2_rs1_0_o,    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [4:0]       id2_rs2_0_o,    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]  id2_imm0_o,     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [3:0]       id2_alu_op0_o,  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [2:0]       id2_mem_op0_o,  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  output reg              id2_valid1_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]  id2_pc1_o,      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [4:0]       id2_rd1_o,      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [4:0]       id2_rs1_1_o,    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [4:0]       id2_rs2_1_o,    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]  id2_imm1_o,     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [3:0]       id2_alu_op1_o,  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [2:0]       id2_mem_op1_o,  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // EX Unit Enable Bits
  output reg              id2_int_en_l0_o,/* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg              id2_int_en_l1_o,/* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg              id2_ma_en_l0_o, /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg              id2_ma_en_l1_o  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
);

  // Dependency Analysis between Lane 0 and Lane 1
  wire raw_hazard = id1_valid0_i && id1_valid1_i && (id1_rd0_i != 5'd0) &&
                    ((id1_rs1_1_i == id1_rd0_i) || (id1_rs2_1_i == id1_rd0_i));

  wire waw_hazard = id1_valid0_i && id1_valid1_i && (id1_rd0_i != 5'd0) &&
                    (id1_rd1_i == id1_rd0_i);

  // Dual-Issue Combinations
  // Case A: [INT, MA]
  wire can_dual_int_ma = id1_valid0_i && id1_valid1_i &&
                         (id1_type0_i == 2'b01) && (id1_type1_i == 2'b10) &&
                         !raw_hazard && !ma_eu_busy_i;

  // Case B: [MA, INT]
  wire can_dual_ma_int = id1_valid0_i && id1_valid1_i &&
                         (id1_type0_i == 2'b10) && (id1_type1_i == 2'b01) &&
                         !raw_hazard && !waw_hazard && !ma_eu_busy_i;

  wire dual_issue_active = can_dual_int_ma || can_dual_ma_int;

  assign consume_step_o = (!id1_valid0_i) ? 2'd0 :
                          dual_issue_active ? 2'd2 : 2'd1;

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      id2_valid0_o    <= 1'b0;
      id2_pc0_o       <= {XLEN{1'b0}};
      id2_rd0_o       <= 5'd0;
      id2_rs1_0_o     <= 5'd0;
      id2_rs2_0_o     <= 5'd0;
      id2_imm0_o      <= {XLEN{1'b0}};
      id2_alu_op0_o   <= 4'd0;
      id2_mem_op0_o   <= 3'd0;

      id2_valid1_o    <= 1'b0;
      id2_pc1_o       <= {XLEN{1'b0}};
      id2_rd1_o       <= 5'd0;
      id2_rs1_1_o     <= 5'd0;
      id2_rs2_1_o     <= 5'd0;
      id2_imm1_o      <= {XLEN{1'b0}};
      id2_alu_op1_o   <= 4'd0;
      id2_mem_op1_o   <= 3'd0;

      id2_int_en_l0_o <= 1'b0;
      id2_int_en_l1_o <= 1'b0;
      id2_ma_en_l0_o  <= 1'b0;
      id2_ma_en_l1_o  <= 1'b0;
    end else begin
      if (flush_i) begin
        id2_valid0_o    <= 1'b0;
        id2_valid1_o    <= 1'b0;
        id2_int_en_l0_o <= 1'b0;
        id2_int_en_l1_o <= 1'b0;
        id2_ma_en_l0_o  <= 1'b0;
        id2_ma_en_l1_o  <= 1'b0;
      end else if (!stall_i) begin
        // Lane 0 is always preserved
        id2_valid0_o  <= id1_valid0_i;
        id2_pc0_o     <= id1_pc0_i;
        id2_rd0_o     <= id1_rd0_i;
        id2_rs1_0_o   <= id1_rs1_0_i;
        id2_rs2_0_o   <= id1_rs2_0_i;
        id2_imm0_o    <= id1_imm0_i;
        id2_alu_op0_o <= id1_alu_op0_i;
        id2_mem_op0_o <= id1_mem_op0_i;

        // Lane 1 is valid ONLY if dual-issued (otherwise Bubble / valid=0)
        id2_valid1_o  <= dual_issue_active;
        id2_pc1_o     <= id1_pc1_i;
        id2_rd1_o     <= id1_rd1_i;
        id2_rs1_1_o   <= id1_rs1_1_i;
        id2_rs2_1_o   <= id1_rs2_1_i;
        id2_imm1_o    <= id1_imm1_i;
        id2_alu_op1_o <= id1_alu_op1_i;
        id2_mem_op1_o <= id1_mem_op1_i;

        // Set EX Enable bits based on combination
        if (can_dual_int_ma) begin
          id2_int_en_l0_o <= 1'b1;
          id2_ma_en_l1_o  <= 1'b1;
          id2_int_en_l1_o <= 1'b0;
          id2_ma_en_l0_o  <= 1'b0;
        end else if (can_dual_ma_int) begin
          id2_ma_en_l0_o  <= 1'b1;
          id2_int_en_l1_o <= 1'b1;
          id2_int_en_l0_o <= 1'b0;
          id2_ma_en_l1_o  <= 1'b0;
        end else begin
          // Single-issue fallback on Lane 0
          id2_int_en_l0_o <= (id1_type0_i == 2'b01);
          id2_ma_en_l0_o  <= (id1_type0_i == 2'b10);
          id2_int_en_l1_o <= 1'b0;
          id2_ma_en_l1_o  <= 1'b0;
        end
      end
    end
  end

endmodule
