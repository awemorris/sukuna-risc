// ============================================================================
// Pipeline Stage: ID2 (Instruction Decode 2) (Verilog 2005)
// Complies with design-rule.md
// ============================================================================
// Responsibilities:
//   - Parallel dependency checking (RAW / WAW) between Lane 0 and Lane 1
//   - Evaluates dual-issue compatibility ([INT, MA] or [MA, INT])
//   - Generates EX enable bits: int_en_l0/l1, ma_en_l0/l1
//   - Emits Half-width bubble on Lane 1 if single-issue
//   - Passes branch, jump, and word-operation control bits to ID3
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
  input  wire [4:0]       id1_alu_op0_i,
  input  wire [7:0]       id1_mem_op0_i,
  input  wire [2:0]       id1_sys_op0_i,
  input  wire [2:0]       id1_priv_op0_i,
  input  wire [11:0]      id1_csr_addr0_i,
  input  wire             id1_csr_is_imm0_i,
  input  wire [2:0]       id1_br_type0_i,
  input  wire [1:0]       id1_jump_type0_i,
  input  wire             id1_is_word0_i,
  input  wire             id1_use_imm0_i,
  input  wire             id1_use_pc0_i,

  input  wire             id1_valid1_i,
  input  wire [XLEN-1:0]  id1_pc1_i,
  input  wire [31:0]      id1_inst1_i,
  input  wire [1:0]       id1_type1_i,
  input  wire [4:0]       id1_rd1_i,
  input  wire [4:0]       id1_rs1_1_i,
  input  wire [4:0]       id1_rs2_1_i,
  input  wire [XLEN-1:0]  id1_imm1_i,
  input  wire [4:0]       id1_alu_op1_i,
  input  wire [7:0]       id1_mem_op1_i,
  input  wire             id1_is_word1_i,
  input  wire             id1_use_imm1_i,
  input  wire             id1_slot1_older_i,

  // Feedback to fetch and ID1
  output wire             hold_slot0_o,
  output wire             hold_slot1_o,
  output wire [1:0]       consume_step_o,

  // Pipeline Registers to ID3 (Lane 0: older, Lane 1: younger)
  output reg              id2_slot1_older_o,/* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg              id2_valid0_o,     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]  id2_pc0_o,        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [4:0]       id2_rd0_o,        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [4:0]       id2_rs1_0_o,      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [4:0]       id2_rs2_0_o,      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]  id2_imm0_o,       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [4:0]       id2_alu_op0_o,    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [7:0]       id2_mem_op0_o,    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [2:0]       id2_sys_op0_o,    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [2:0]       id2_priv_op0_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [11:0]      id2_csr_addr0_o,  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg              id2_csr_is_imm0_o,/* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [2:0]       id2_br_type0_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [1:0]       id2_jump_type0_o, /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg              id2_is_word0_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg              id2_use_imm0_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg              id2_use_pc0_o,    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  output reg              id2_valid1_o,     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]  id2_pc1_o,        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [4:0]       id2_rd1_o,        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [4:0]       id2_rs1_1_o,      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [4:0]       id2_rs2_1_o,      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]  id2_imm1_o,       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [4:0]       id2_alu_op1_o,    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [7:0]       id2_mem_op1_o,    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg              id2_is_word1_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg              id2_use_imm1_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // EX Unit Enable Bits
  output reg              id2_int_en_l0_o,  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg              id2_int_en_l1_o,  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg              id2_ma_en_l0_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg              id2_ma_en_l1_o    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
);

  // --------------------------------------------------------------------------
  // Dependency & Hazard Analysis between Lane 0 and Lane 1
  // --------------------------------------------------------------------------
  // Normal Mode (slot1_older == 0): Lane 0 is Older, Lane 1 is Younger
  wire raw_hazard = id1_valid0_i && id1_valid1_i && (id1_rd0_i != 5'd0) &&
                    ((id1_rs1_1_i == id1_rd0_i) || (id1_rs2_1_i == id1_rd0_i));

  wire waw_hazard = id1_valid0_i && id1_valid1_i && (id1_rd0_i != 5'd0) &&
                    (id1_rd0_i == id1_rd1_i);

  wire mem_to_int_raw_hazard = id1_valid0_i && id1_valid1_i &&
                               (id1_type0_i == 2'b10) && (id1_type1_i == 2'b01) &&
                               (id1_rd0_i != 5'd0) &&
                               ((id1_rs1_1_i == id1_rd0_i) || (id1_rs2_1_i == id1_rd0_i));

  wire can_dual_int_ma = id1_valid0_i && id1_valid1_i &&
                         (id1_type0_i == 2'b01) && (id1_type1_i == 2'b10) &&
                         (id1_sys_op0_i == `SYS_NONE) &&
                         (id1_br_type0_i == `BR_NONE) &&
                         (id1_jump_type0_i == `JUMP_NONE) &&
                         !raw_hazard && !waw_hazard && !ma_eu_busy_i;

  wire can_dual_ma_int = id1_valid0_i && id1_valid1_i &&
                         (id1_type0_i == 2'b10) && (id1_type1_i == 2'b01) &&
                         (id1_sys_op0_i == `SYS_NONE) &&
                         (id1_br_type0_i == `BR_NONE) &&
                         (id1_jump_type0_i == `JUMP_NONE) &&
                         !raw_hazard && !waw_hazard && !mem_to_int_raw_hazard && !ma_eu_busy_i;

  wire can_dual_normal = id1_valid0_i && id1_valid1_i && !ma_eu_busy_i &&
                         (id1_type0_i == 2'b01 && id1_type1_i == 2'b10) &&
                         (id1_sys_op0_i == `SYS_NONE) &&
                         (id1_br_type0_i == `BR_NONE) &&
                         (id1_jump_type0_i == `JUMP_NONE) &&
                         !raw_hazard && !waw_hazard;

  // Inverted Mode (slot1_older == 1)
  wire raw_hazard_inv = 1'b0;
  wire waw_hazard_inv = 1'b0;
  wire mem_to_int_raw_inv = 1'b0;
  wire can_dual_int_ma_inv = 1'b0;
  wire can_dual_ma_int_inv = 1'b0;
  wire can_dual_inv = 1'b0;

  // Hold & Fetch advance controls
  assign hold_slot1_o = 1'b0;
  assign hold_slot0_o = 1'b0;

  assign consume_step_o = 2'd0;

  wire l0_issue = id1_valid0_i;
  wire l1_issue = can_dual_normal;

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      id2_slot1_older_o <= 1'b0;
      id2_valid0_o      <= 1'b0;
      id2_pc0_o         <= {XLEN{1'b0}};
      id2_rd0_o         <= 5'd0;
      id2_rs1_0_o       <= 5'd0;
      id2_rs2_0_o       <= 5'd0;
      id2_imm0_o        <= {XLEN{1'b0}};
      id2_alu_op0_o     <= 5'd0;
      id2_mem_op0_o     <= 8'd0;
      id2_sys_op0_o     <= `SYS_NONE;
      id2_priv_op0_o    <= `PRIV_NONE;
      id2_csr_addr0_o   <= 12'd0;
      id2_csr_is_imm0_o <= 1'b0;
      id2_br_type0_o    <= `BR_NONE;
      id2_jump_type0_o  <= `JUMP_NONE;
      id2_is_word0_o    <= 1'b0;
      id2_use_imm0_o    <= 1'b0;
      id2_use_pc0_o     <= 1'b0;

      id2_valid1_o      <= 1'b0;
      id2_pc1_o         <= {XLEN{1'b0}};
      id2_rd1_o         <= 5'd0;
      id2_rs1_1_o       <= 5'd0;
      id2_rs2_1_o       <= 5'd0;
      id2_imm1_o        <= {XLEN{1'b0}};
      id2_alu_op1_o     <= 5'd0;
      id2_mem_op1_o     <= 8'd0;
      id2_is_word1_o    <= 1'b0;
      id2_use_imm1_o    <= 1'b0;

      id2_int_en_l0_o   <= 1'b0;
      id2_int_en_l1_o   <= 1'b0;
      id2_ma_en_l0_o    <= 1'b0;
      id2_ma_en_l1_o    <= 1'b0;
    end else begin
      if (flush_i) begin
        id2_slot1_older_o <= 1'b0;
        id2_valid0_o      <= 1'b0;
        id2_valid1_o      <= 1'b0;
        id2_int_en_l0_o   <= 1'b0;
        id2_int_en_l1_o   <= 1'b0;
        id2_ma_en_l0_o    <= 1'b0;
        id2_ma_en_l1_o    <= 1'b0;
      end else if (!stall_i) begin
        // Lane 0: Straight propagation
        id2_valid0_o      <= l0_issue;
        id2_pc0_o         <= id1_pc0_i;
        id2_rd0_o         <= id1_rd0_i;
        id2_rs1_0_o       <= id1_rs1_0_i;
        id2_rs2_0_o       <= id1_rs2_0_i;
        id2_imm0_o        <= id1_imm0_i;
        id2_alu_op0_o     <= id1_alu_op0_i;
        id2_mem_op0_o     <= id1_mem_op0_i;
        id2_sys_op0_o     <= id1_sys_op0_i;
        id2_priv_op0_o    <= id1_priv_op0_i;
        id2_csr_addr0_o   <= id1_csr_addr0_i;
        id2_csr_is_imm0_o <= id1_csr_is_imm0_i;
        id2_br_type0_o    <= id1_br_type0_i;
        id2_jump_type0_o  <= id1_jump_type0_i;
        id2_is_word0_o    <= id1_is_word0_i;
        id2_use_imm0_o    <= id1_use_imm0_i;
        id2_use_pc0_o     <= id1_use_pc0_i;

        // Lane 1: Injected with half-width bubble if single-issue
        id2_valid1_o      <= l1_issue;
        id2_pc1_o         <= id1_pc1_i;
        id2_rd1_o         <= id1_rd1_i;
        id2_rs1_1_o       <= id1_rs1_1_i;
        id2_rs2_1_o       <= id1_rs2_1_i;
        id2_imm1_o        <= id1_imm1_i;
        id2_alu_op1_o     <= id1_alu_op1_i;
        id2_mem_op1_o     <= id1_mem_op1_i;
        id2_is_word1_o    <= id1_is_word1_i;
        id2_use_imm1_o    <= id1_use_imm1_i;

        id2_slot1_older_o <= id1_slot1_older_i;

        // Routing Enable Bits to EX stage
        if (id1_slot1_older_i) begin
          id2_int_en_l0_o <= l0_issue && (id1_type0_i == 2'b01);
          id2_ma_en_l0_o  <= l0_issue && (id1_type0_i == 2'b10);
          id2_int_en_l1_o <= l1_issue && (id1_type1_i == 2'b01);
          id2_ma_en_l1_o  <= l1_issue && (id1_type1_i == 2'b10);
        end else begin
          id2_int_en_l0_o <= l0_issue && (id1_type0_i == 2'b01 || id1_jump_type0_i != `JUMP_NONE);
          id2_ma_en_l0_o  <= l0_issue && (id1_type0_i == 2'b10);
          id2_int_en_l1_o <= l1_issue && (id1_type1_i == 2'b01);
          id2_ma_en_l1_o  <= l1_issue && (id1_type1_i == 2'b10);
        end
      end
    end
  end

  // Avoid unused variable warnings
  wire _unused = &{1'b0, id1_inst0_i, id1_inst1_i, 1'b0};

endmodule
