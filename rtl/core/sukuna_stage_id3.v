// ============================================================================
// Pipeline Stage: ID3 (Instruction Decode 3) (Verilog 2005)
// Complies with design-rule.md
// ============================================================================
// Responsibilities:
//   - Operand Forwarding / Bypass injection from EX & WB stages
//   - Direct, straight output of Lane 0 & Lane 1 buses to EX (Zero-Mux datapath)
//   - Passes EX Enable bits: int_en_l0/l1, ma_en_l0/l1
//   - Passes branch, jump, and word-operation control bits to EX
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_stage_id3 #(
  parameter XLEN = `XLEN
)(
  input  wire             clk_i,
  input  wire             rst_ni,

  // Pipeline flow controls
  input  wire             stall_i,
  input  wire             flush_i,

  // Inputs from ID2
  input  wire             id2_valid0_i,
  input  wire [XLEN-1:0]  id2_pc0_i,
  input  wire [4:0]       id2_rd0_i,
  input  wire [4:0]       id2_rs1_0_i,
  input  wire [4:0]       id2_rs2_0_i,
  input  wire [XLEN-1:0]  id2_imm0_i,
  input  wire [4:0]       id2_alu_op0_i,
  input  wire [7:0]       id2_mem_op0_i,
  input  wire [2:0]       id2_sys_op0_i,
  input  wire [2:0]       id2_priv_op0_i,
  input  wire [11:0]      id2_csr_addr0_i,
  input  wire             id2_csr_is_imm0_i,
  input  wire [2:0]       id2_br_type0_i,
  input  wire [1:0]       id2_jump_type0_i,
  input  wire             id2_is_word0_i,
  input  wire             id2_use_imm0_i,
  input  wire             id2_use_pc0_i,

  input  wire             id2_valid1_i,
  input  wire [XLEN-1:0]  id2_pc1_i,
  input  wire [4:0]       id2_rd1_i,
  input  wire [4:0]       id2_rs1_1_i,
  input  wire [4:0]       id2_rs2_1_i,
  input  wire [XLEN-1:0]  id2_imm1_i,
  input  wire [4:0]       id2_alu_op1_i,
  input  wire [7:0]       id2_mem_op1_i,
  input  wire             id2_is_word1_i,
  input  wire             id2_use_imm1_i,

  input  wire             id2_int_en_l0_i,
  input  wire             id2_int_en_l1_i,
  input  wire             id2_ma_en_l0_i,
  input  wire             id2_ma_en_l1_i,
  input  wire             id2_slot1_older_i,

  // RegFile Read Data Outputs
  input  wire [XLEN-1:0]  rf_rdata_l0_rs1_i,
  input  wire [XLEN-1:0]  rf_rdata_l0_rs2_i,
  input  wire [XLEN-1:0]  rf_rdata_l1_rs1_i,
  input  wire [XLEN-1:0]  rf_rdata_l1_rs2_i,

  // Floating-Point Register File Read Data & Forwarding
  input  wire [XLEN-1:0]  fpr_rdata_l0_rs1_i,
  input  wire [XLEN-1:0]  fpr_rdata_l0_rs2_i,
  input  wire             fwd_ex_fpr_val_i,
  input  wire [4:0]       fwd_ex_fpr_rd_i,
  input  wire [XLEN-1:0]  fwd_ex_fpr_data_i,
  input  wire             fwd_wb_fpr_val_i,
  input  wire [4:0]       fwd_wb_fpr_rd_i,
  input  wire [XLEN-1:0]  fwd_wb_fpr_data_i,

  // Bypass / Forwarding inputs from EX & WB
  input  wire             fwd_ex_val_i,
  input  wire [4:0]       fwd_ex_rd_i,
  input  wire [XLEN-1:0]  fwd_ex_data_i,
  input  wire             fwd_ex_l1_val_i,
  input  wire [4:0]       fwd_ex_l1_rd_i,
  input  wire [XLEN-1:0]  fwd_ex_l1_data_i,

  input  wire             fwd_wb_l0_val_i,
  input  wire [4:0]       fwd_wb_l0_rd_i,
  input  wire [XLEN-1:0]  fwd_wb_l0_data_i,
  input  wire             fwd_wb_l1_val_i,
  input  wire [4:0]       fwd_wb_l1_rd_i,
  input  wire [XLEN-1:0]  fwd_wb_l1_data_i,

  // --------------------------------------------------------------------------
  // Direct Outputs to EX Stage (Lane 0: older, Lane 1: younger)
  // --------------------------------------------------------------------------
  output reg              ex_l0_valid_o,      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]  ex_l0_pc_o,         /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [4:0]       ex_l0_rd_o,         /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]  ex_l0_src1_o,       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]  ex_l0_src2_o,       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]  ex_l0_imm_o,        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [4:0]       ex_l0_alu_op_o,     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [7:0]       ex_l0_mem_op_o,     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [2:0]       ex_l0_sys_op_o,     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [2:0]       ex_l0_priv_op_o,    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [11:0]      ex_l0_csr_addr_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg              ex_l0_csr_is_imm_o, /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [2:0]       ex_l0_br_type_o,    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [1:0]       ex_l0_jump_type_o,  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg              ex_l0_is_word_o,    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg              ex_l0_use_imm_o,    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg              ex_l0_use_pc_o,     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]  ex_l0_fpr_src1_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]  ex_l0_fpr_src2_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  output reg              ex_l1_valid_o,      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]  ex_l1_pc_o,         /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [4:0]       ex_l1_rd_o,         /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]  ex_l1_src1_o,       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]  ex_l1_src2_o,       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]  ex_l1_imm_o,        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [4:0]       ex_l1_alu_op_o,     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [7:0]       ex_l1_mem_op_o,     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg              ex_l1_is_word_o,    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg              ex_l1_use_imm_o,    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // Control Enable Bits to EX
  output reg              ex_int_en_l0_o,     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg              ex_int_en_l1_o,     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg              ex_ma_en_l0_o,      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg              ex_ma_en_l1_o,      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // Source Register Specifiers for EX Hazard/Forwarding
  output reg  [4:0]       ex_l0_rs1_o,        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [4:0]       ex_l0_rs2_o,        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [4:0]       ex_l1_rs1_o,        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [4:0]       ex_l1_rs2_o,        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg              ex_slot1_older_o    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
);

  // Bypass selection for Lane 0
  wire [XLEN-1:0] l0_src1_mux = (fwd_ex_val_i && (fwd_ex_rd_i != 5'd0) && (fwd_ex_rd_i == id2_rs1_0_i))       ? fwd_ex_data_i :
                                (fwd_ex_l1_val_i && (fwd_ex_l1_rd_i != 5'd0) && (fwd_ex_l1_rd_i == id2_rs1_0_i)) ? fwd_ex_l1_data_i :
                                (fwd_wb_l0_val_i && (fwd_wb_l0_rd_i != 5'd0) && (fwd_wb_l0_rd_i == id2_rs1_0_i)) ? fwd_wb_l0_data_i :
                                (fwd_wb_l1_val_i && (fwd_wb_l1_rd_i != 5'd0) && (fwd_wb_l1_rd_i == id2_rs1_0_i)) ? fwd_wb_l1_data_i :
                                rf_rdata_l0_rs1_i;

  wire [XLEN-1:0] l0_src2_mux = (fwd_ex_val_i && (fwd_ex_rd_i != 5'd0) && (fwd_ex_rd_i == id2_rs2_0_i))       ? fwd_ex_data_i :
                                (fwd_ex_l1_val_i && (fwd_ex_l1_rd_i != 5'd0) && (fwd_ex_l1_rd_i == id2_rs2_0_i)) ? fwd_ex_l1_data_i :
                                (fwd_wb_l0_val_i && (fwd_wb_l0_rd_i != 5'd0) && (fwd_wb_l0_rd_i == id2_rs2_0_i)) ? fwd_wb_l0_data_i :
                                (fwd_wb_l1_val_i && (fwd_wb_l1_rd_i != 5'd0) && (fwd_wb_l1_rd_i == id2_rs2_0_i)) ? fwd_wb_l1_data_i :
                                rf_rdata_l0_rs2_i;

  // Bypass selection for Lane 1
  wire [XLEN-1:0] l1_src1_mux = (fwd_ex_val_i && (fwd_ex_rd_i != 5'd0) && (fwd_ex_rd_i == id2_rs1_1_i))       ? fwd_ex_data_i :
                                (fwd_ex_l1_val_i && (fwd_ex_l1_rd_i != 5'd0) && (fwd_ex_l1_rd_i == id2_rs1_1_i)) ? fwd_ex_l1_data_i :
                                (fwd_wb_l0_val_i && (fwd_wb_l0_rd_i != 5'd0) && (fwd_wb_l0_rd_i == id2_rs1_1_i)) ? fwd_wb_l0_data_i :
                                (fwd_wb_l1_val_i && (fwd_wb_l1_rd_i != 5'd0) && (fwd_wb_l1_rd_i == id2_rs1_1_i)) ? fwd_wb_l1_data_i :
                                rf_rdata_l1_rs1_i;

  wire [XLEN-1:0] l1_src2_mux = (fwd_ex_val_i && (fwd_ex_rd_i != 5'd0) && (fwd_ex_rd_i == id2_rs2_1_i))       ? fwd_ex_data_i :
                                (fwd_ex_l1_val_i && (fwd_ex_l1_rd_i != 5'd0) && (fwd_ex_l1_rd_i == id2_rs2_1_i)) ? fwd_ex_l1_data_i :
                                (fwd_wb_l0_val_i && (fwd_wb_l0_rd_i != 5'd0) && (fwd_wb_l0_rd_i == id2_rs2_1_i)) ? fwd_wb_l0_data_i :
                                (fwd_wb_l1_val_i && (fwd_wb_l1_rd_i != 5'd0) && (fwd_wb_l1_rd_i == id2_rs2_1_i)) ? fwd_wb_l1_data_i :
                                rf_rdata_l1_rs2_i;

  // Bypass selection for FPR
  wire [XLEN-1:0] l0_fpr_src1_mux = (fwd_ex_fpr_val_i && (fwd_ex_fpr_rd_i == id2_rs1_0_i)) ? fwd_ex_fpr_data_i :
                                    (fwd_wb_fpr_val_i && (fwd_wb_fpr_rd_i == id2_rs1_0_i)) ? fwd_wb_fpr_data_i :
                                    fpr_rdata_l0_rs1_i;

  wire [XLEN-1:0] l0_fpr_src2_mux = (fwd_ex_fpr_val_i && (fwd_ex_fpr_rd_i == id2_rs2_0_i)) ? fwd_ex_fpr_data_i :
                                    (fwd_wb_fpr_val_i && (fwd_wb_fpr_rd_i == id2_rs2_0_i)) ? fwd_wb_fpr_data_i :
                                    fpr_rdata_l0_rs2_i;

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ex_l0_valid_o      <= 1'b0;
      ex_l0_pc_o         <= {XLEN{1'b0}};
      ex_l0_rd_o         <= 5'd0;
      ex_l0_src1_o       <= {XLEN{1'b0}};
      ex_l0_src2_o       <= {XLEN{1'b0}};
      ex_l0_imm_o        <= {XLEN{1'b0}};
      ex_l0_alu_op_o     <= 5'd0;
      ex_l0_mem_op_o     <= 8'd0;
      ex_l0_sys_op_o     <= `SYS_NONE;
      ex_l0_priv_op_o    <= `PRIV_NONE;
      ex_l0_csr_addr_o   <= 12'd0;
      ex_l0_csr_is_imm_o <= 1'b0;
      ex_l0_br_type_o    <= `BR_NONE;
      ex_l0_jump_type_o  <= `JUMP_NONE;
      ex_l0_is_word_o    <= 1'b0;
      ex_l0_use_imm_o    <= 1'b0;
      ex_l0_use_pc_o     <= 1'b0;
      ex_l0_fpr_src1_o   <= {XLEN{1'b0}};
      ex_l0_fpr_src2_o   <= {XLEN{1'b0}};

      ex_l1_valid_o      <= 1'b0;
      ex_l1_pc_o         <= {XLEN{1'b0}};
      ex_l1_rd_o         <= 5'd0;
      ex_l1_src1_o       <= {XLEN{1'b0}};
      ex_l1_src2_o       <= {XLEN{1'b0}};
      ex_l1_imm_o        <= {XLEN{1'b0}};
      ex_l1_alu_op_o     <= 5'd0;
      ex_l1_mem_op_o     <= 8'd0;
      ex_l1_is_word_o    <= 1'b0;
      ex_l1_use_imm_o    <= 1'b0;

      ex_int_en_l0_o     <= 1'b0;
      ex_int_en_l1_o     <= 1'b0;
      ex_ma_en_l0_o      <= 1'b0;
      ex_ma_en_l1_o      <= 1'b0;
      ex_l0_rs1_o        <= 5'd0;
      ex_l0_rs2_o        <= 5'd0;
      ex_l1_rs1_o        <= 5'd0;
      ex_l1_rs2_o        <= 5'd0;
      ex_slot1_older_o   <= 1'b0;
    end else begin
      if (flush_i) begin
        ex_l0_valid_o  <= 1'b0;
        ex_l1_valid_o  <= 1'b0;
        ex_int_en_l0_o <= 1'b0;
        ex_int_en_l1_o <= 1'b0;
        ex_ma_en_l0_o  <= 1'b0;
        ex_ma_en_l1_o  <= 1'b0;
        ex_l0_rs1_o    <= 5'd0;
        ex_l0_rs2_o    <= 5'd0;
        ex_l1_rs1_o    <= 5'd0;
        ex_l1_rs2_o    <= 5'd0;
        ex_slot1_older_o <= 1'b0;
        ex_l0_fpr_src1_o <= {XLEN{1'b0}};
        ex_l0_fpr_src2_o <= {XLEN{1'b0}};
      end else if (!stall_i) begin
        ex_slot1_older_o   <= id2_slot1_older_i;
        // Straight assignment of Lane 0
        ex_l0_valid_o      <= id2_valid0_i;
        ex_l0_pc_o         <= id2_pc0_i;
        ex_l0_rd_o         <= id2_rd0_i;
        ex_l0_rs1_o        <= id2_rs1_0_i;
        ex_l0_rs2_o        <= id2_rs2_0_i;
        ex_l0_src1_o       <= l0_src1_mux;
        ex_l0_src2_o       <= l0_src2_mux;
        ex_l0_fpr_src1_o   <= l0_fpr_src1_mux;
        ex_l0_fpr_src2_o   <= l0_fpr_src2_mux;
        ex_l0_imm_o        <= id2_imm0_i;
        ex_l0_alu_op_o     <= id2_alu_op0_i;
        ex_l0_mem_op_o     <= id2_mem_op0_i;
        ex_l0_sys_op_o     <= id2_sys_op0_i;
        ex_l0_priv_op_o    <= id2_priv_op0_i;
        ex_l0_csr_addr_o   <= id2_csr_addr0_i;
        ex_l0_csr_is_imm_o <= id2_csr_is_imm0_i;
        ex_l0_br_type_o    <= id2_br_type0_i;
        ex_l0_jump_type_o  <= id2_jump_type0_i;
        ex_l0_is_word_o    <= id2_is_word0_i;
        ex_l0_use_imm_o    <= id2_use_imm0_i;
        ex_l0_use_pc_o     <= id2_use_pc0_i;

        // Straight assignment of Lane 1
        ex_l1_valid_o      <= id2_valid1_i;
        ex_l1_pc_o         <= id2_pc1_i;
        ex_l1_rd_o         <= id2_rd1_i;
        ex_l1_rs1_o        <= id2_rs1_1_i;
        ex_l1_rs2_o        <= id2_rs2_1_i;
        ex_l1_src1_o       <= l1_src1_mux;
        ex_l1_src2_o       <= l1_src2_mux;
        ex_l1_imm_o        <= id2_imm1_i;
        ex_l1_alu_op_o     <= id2_alu_op1_i;
        ex_l1_mem_op_o     <= id2_mem_op1_i;
        ex_l1_is_word_o    <= id2_is_word1_i;
        ex_l1_use_imm_o    <= id2_use_imm1_i;

        // Passes EX Enable Bits
        ex_int_en_l0_o     <= id2_int_en_l0_i;
        ex_int_en_l1_o     <= id2_int_en_l1_i;
        ex_ma_en_l0_o      <= id2_ma_en_l0_i;
        ex_ma_en_l1_o      <= id2_ma_en_l1_i;
      end
    end
  end

endmodule
