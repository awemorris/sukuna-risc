// ============================================================================
// Pipeline Stage: EX (Execution Stage Outer Box) (Verilog 2005)
// Complies with design-rule.md
// ============================================================================
// Responsibilities:
//   - Receives dual-lane buses (Lane 0: older, Lane 1: younger)
//   - Routes to INT-EU and MA-EU based on 1-bit enable bits (int_en_l0/l1, ma_en_l0/l1)
//   - Instantiates dedicated INT-EU (1/multi-cycle with sk_mul) and MA-EU (2-cycle)
//   - Full Branch condition evaluation (BEQ/BNE/BLT/BGE/BLTU/BGEU) and JAL/JALR
//   - Branch mispredict & Jump redirection to IF1 and Hazard Unit
//   - Evaluates CSR and Privileged instructions on Lane 0 (single-issue)
//   - Emits ex_stall_o to Hazard Unit on memory stalls or multicycle ALU execution
//   - Routes results and exception/privileged states to Lane 0 and Lane 1 for WB
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_stage_ex #(
  parameter XLEN        = `XLEN,
  parameter VADDR_WIDTH = `VADDR_WIDTH,
  parameter PADDR_WIDTH = `PADDR_WIDTH,
  parameter MUL_LAT     = 3
)(
  input  wire                   clk_i,
  input  wire                   rst_ni,

  // Pipeline flow controls
  input  wire                   stall_i,
  input  wire                   flush_i,

  // Lane 0 Bus from ID3 (older)
  input  wire                   l0_valid_i,
  input  wire [XLEN-1:0]        l0_pc_i,
  input  wire [4:0]             l0_rd_i,
  input  wire [XLEN-1:0]        l0_src1_i,
  input  wire [XLEN-1:0]        l0_src2_i,
  input  wire [XLEN-1:0]        l0_imm_i,
  input  wire [4:0]             l0_alu_op_i,
  input  wire [7:0]             l0_mem_op_i,
  input  wire [2:0]             l0_sys_op_i,
  input  wire [2:0]             l0_priv_op_i,
  input  wire [11:0]            l0_csr_addr_i,
  input  wire                   l0_csr_is_imm_i,
  input  wire [2:0]             l0_br_type_i,
  input  wire [1:0]             l0_jump_type_i,
  input  wire                   l0_is_word_i,
  input  wire                   l0_use_imm_i,
  input  wire                   l0_use_pc_i,

  // Lane 1 Bus from ID3 (younger)
  input  wire                   l1_valid_i,
  input  wire [XLEN-1:0]        l1_pc_i,
  input  wire [4:0]             l1_rd_i,
  input  wire [XLEN-1:0]        l1_src1_i,
  input  wire [XLEN-1:0]        l1_src2_i,
  input  wire [XLEN-1:0]        l1_imm_i,
  input  wire [4:0]             l1_alu_op_i,
  input  wire [7:0]             l1_mem_op_i,
  input  wire                   l1_is_word_i,
  input  wire                   l1_use_imm_i,

  // Source register numbers for operand forwarding
  input  wire [4:0]             l0_rs1_i,
  input  wire [4:0]             l0_rs2_i,
  input  wire [4:0]             l1_rs1_i,
  input  wire [4:0]             l1_rs2_i,

  // Forwarding from WB stage commit
  input  wire                   wb_l0_wen_i,
  input  wire [4:0]             wb_l0_rd_i,
  input  wire [XLEN-1:0]        wb_l0_data_i,
  input  wire                   wb_l1_wen_i,
  input  wire [4:0]             wb_l1_rd_i,
  input  wire [XLEN-1:0]        wb_l1_data_i,

  // Enable Bits
  input  wire                   int_en_l0_i,
  input  wire                   int_en_l1_i,
  input  wire                   ma_en_l0_i,
  input  wire                   ma_en_l1_i,
  input  wire                   ex_slot1_older_i,

  // Floating-Point Register File Inputs
  input  wire [XLEN-1:0]        fpr_src1_i,
  input  wire [XLEN-1:0]        fpr_src2_i,
  input  wire                   wb_fpr_wen_i,
  input  wire [4:0]             wb_fpr_rd_i,
  input  wire [XLEN-1:0]        wb_fpr_data_i,

  // CSR Unit Read / Legality Interface (Lane 0 EX stage)
  output wire                   csr_req_valid_o,
  output wire [11:0]            csr_raddr_o,
  output wire                   csr_rwen_o,
  input  wire [XLEN-1:0]        csr_rdata_i,
  input  wire                   csr_illegal_i,
  input  wire [1:0]             priv_mode_i,

  // Branch / Mispredict Redirection to IF1 & Hazard Unit
  output wire                   branch_mispredict_o,
  output wire [XLEN-1:0]        branch_target_o,

  // Stall Output to Hazard Unit (MA-EU L1D miss / bus wait, or INT-EU multicycle)
  output wire                   ex_stall_o,

  // DTLB Interface
  output wire                   dtlb_lookup_valid_o,
  output wire [VADDR_WIDTH-1:2] dtlb_vaddr_w_o,
  input  wire                   dtlb_hit_i,
  input  wire [PADDR_WIDTH-1:2] dtlb_paddr_w_i,
  input  wire                   dtlb_fault_i,

  // L1D Cache Interface (Word-aligned address & byte enable)
  output wire                   l1d_req_valid_o,
  output wire                   l1d_req_write_o,
  output wire [3:0]             l1d_req_op_o,
  output wire [7:0]             l1d_req_byte_en_o,
  output wire [PADDR_WIDTH-1:2] l1d_paddr_w_o,
  output wire [XLEN-1:0]        l1d_wdata_o,
  input  wire                   l1d_req_ready_i,
  input  wire                   l1d_resp_valid_i,
  input  wire [XLEN-1:0]        l1d_rdata_i,
  input  wire                   l1d_miss_stall_i,

  // Output to WB Stage: Lane 0
  output wire                   ex_wb_l0_valid_o,
  output wire [XLEN-1:0]        ex_wb_l0_pc_o,
  output wire [4:0]             ex_wb_l0_rd_o,
  output wire [XLEN-1:0]        ex_wb_l0_data_o,
  output wire                   ex_wb_l0_exc_o,
  output wire [5:0]             ex_wb_l0_cause_o,
  output wire [XLEN-1:0]        ex_wb_l0_tval_o,
  output wire                   ex_wb_l0_csr_wen_o,
  output wire [11:0]            ex_wb_l0_csr_addr_o,
  output wire [XLEN-1:0]        ex_wb_l0_csr_wdata_o,
  output wire                   ex_wb_l0_mret_o,
  output wire                   ex_wb_l0_sret_o,
  output wire                   ex_wb_l0_wfi_o,
  output wire                   ex_wb_l0_sfence_o,
  output wire                   ex_wb_l0_fence_i_o,
  output wire                   ex_wb_l0_writes_fpr_o,

  // Output to WB Stage: Lane 1
  output wire                   ex_wb_l1_valid_o,
  output wire [XLEN-1:0]        ex_wb_l1_pc_o,
  output wire [4:0]             ex_wb_l1_rd_o,
  output wire [XLEN-1:0]        ex_wb_l1_data_o,
  output wire                   ex_wb_l1_exc_o,
  output wire [5:0]             ex_wb_l1_cause_o,
  output wire [XLEN-1:0]        ex_wb_l1_tval_o,
  output wire                   ex_wb_slot1_older_o,

  // Combinational bypass outputs from EX stage to ID3
  output wire                   ex_comb_l0_val_o,
  output wire [4:0]             ex_comb_l0_rd_o,
  output wire [XLEN-1:0]        ex_comb_l0_data_o,
  output wire                   ex_comb_l1_val_o,
  output wire [4:0]             ex_comb_l1_rd_o,
  output wire [XLEN-1:0]        ex_comb_l1_data_o
);

  // --------------------------------------------------------------------------
  // Operand Forwarding / Bypass Network
  // Prioritizes: EX/WB (1 cycle ahead) -> WB commit (2 cycles ahead) -> Register file data
  // --------------------------------------------------------------------------
  wire [XLEN-1:0] fwd_l0_src1 = (ex_wb_l0_valid_o && (ex_wb_l0_rd_o != 5'd0) && (ex_wb_l0_rd_o == l0_rs1_i)) ? ex_wb_l0_data_o :
                                (ex_wb_l1_valid_o && (ex_wb_l1_rd_o != 5'd0) && (ex_wb_l1_rd_o == l0_rs1_i)) ? ex_wb_l1_data_o :
                                (wb_l0_wen_i && (wb_l0_rd_i != 5'd0) && (wb_l0_rd_i == l0_rs1_i))             ? wb_l0_data_i   :
                                (wb_l1_wen_i && (wb_l1_rd_i != 5'd0) && (wb_l1_rd_i == l0_rs1_i))             ? wb_l1_data_i   :
                                l0_src1_i;

  wire [XLEN-1:0] fwd_l0_src2 = (ex_wb_l0_valid_o && (ex_wb_l0_rd_o != 5'd0) && (ex_wb_l0_rd_o == l0_rs2_i)) ? ex_wb_l0_data_o :
                                (ex_wb_l1_valid_o && (ex_wb_l1_rd_o != 5'd0) && (ex_wb_l1_rd_o == l0_rs2_i)) ? ex_wb_l1_data_o :
                                (wb_l0_wen_i && (wb_l0_rd_i != 5'd0) && (wb_l0_rd_i == l0_rs2_i))             ? wb_l0_data_i   :
                                (wb_l1_wen_i && (wb_l1_rd_i != 5'd0) && (wb_l1_rd_i == l0_rs2_i))             ? wb_l1_data_i   :
                                l0_src2_i;

  wire [XLEN-1:0] fwd_l1_src1 = (ex_wb_l0_valid_o && (ex_wb_l0_rd_o != 5'd0) && (ex_wb_l0_rd_o == l1_rs1_i)) ? ex_wb_l0_data_o :
                                (ex_wb_l1_valid_o && (ex_wb_l1_rd_o != 5'd0) && (ex_wb_l1_rd_o == l1_rs1_i)) ? ex_wb_l1_data_o :
                                (wb_l0_wen_i && (wb_l0_rd_i != 5'd0) && (wb_l0_rd_i == l1_rs1_i))             ? wb_l0_data_i   :
                                (wb_l1_wen_i && (wb_l1_rd_i != 5'd0) && (wb_l1_rd_i == l1_rs1_i))             ? wb_l1_data_i   :
                                l1_src1_i;

  wire [XLEN-1:0] fwd_l1_src2 = (ex_wb_l0_valid_o && (ex_wb_l0_rd_o != 5'd0) && (ex_wb_l0_rd_o == l1_rs2_i)) ? ex_wb_l0_data_o :
                                (ex_wb_l1_valid_o && (ex_wb_l1_rd_o != 5'd0) && (ex_wb_l1_rd_o == l1_rs2_i)) ? ex_wb_l1_data_o :
                                (wb_l0_wen_i && (wb_l0_rd_i != 5'd0) && (wb_l0_rd_i == l1_rs2_i))             ? wb_l0_data_i   :
                                (wb_l1_wen_i && (wb_l1_rd_i != 5'd0) && (wb_l1_rd_i == l1_rs2_i))             ? wb_l1_data_i   :
                                l1_src2_i;

  // Floating-Point Register File Forwarding
  wire [XLEN-1:0] fwd_fpr_src1 = (ex_wb_l0_writes_fpr_o && (ex_wb_l0_rd_o == l0_rs1_i)) ? ex_wb_l0_data_o :
                                 (wb_fpr_wen_i && (wb_fpr_rd_i == l0_rs1_i))             ? wb_fpr_data_i   :
                                 fpr_src1_i;
  wire [XLEN-1:0] fwd_fpr_src2 = (ex_wb_l0_writes_fpr_o && (ex_wb_l0_rd_o == l0_rs2_i)) ? ex_wb_l0_data_o :
                                 (wb_fpr_wen_i && (wb_fpr_rd_i == l0_rs2_i))             ? wb_fpr_data_i   :
                                 fpr_src2_i;

  // Floating-Point Execution Unit
  wire is_fp_op    = l0_valid_i && (l0_alu_op_i == `ALU_FP);
  wire is_fp_load  = l0_valid_i && (l0_mem_op_i[7:4] == `AMO_FP) && !l0_mem_op_i[3];
  wire is_fp_store = l0_valid_i && (l0_mem_op_i[7:4] == `AMO_FP) && l0_mem_op_i[3];

  wire [XLEN-1:0] fp_unit_res;
  wire            fp_unit_writes_fpr;
  wire            fp_unit_writes_gpr;

  wire fp_busy;

  sukuna_fp_unit #(.XLEN(XLEN)) u_fp_unit (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),
    .funct7_i   (l0_csr_addr_i[11:5]),
    .funct3_i   (l0_mem_op_i[2:0]),
    .rs2_field_i(l0_rs2_i),
    .fpr_src1_i (fwd_fpr_src1),
    .fpr_src2_i (fwd_fpr_src2),
    .gpr_src1_i (fwd_l0_src1),
    .busy_o     (fp_busy),
    .fp_result_o(fp_unit_res),
    .writes_fpr_o(fp_unit_writes_fpr),
    .writes_gpr_o(fp_unit_writes_gpr)
  );

  // --------------------------------------------------------------------------
  // CSR & Privileged Instruction Evaluation (Lane 0 only)
  // --------------------------------------------------------------------------
  wire is_csr_op  = l0_valid_i && (l0_sys_op_i == `SYS_CSRRW || l0_sys_op_i == `SYS_CSRRS || l0_sys_op_i == `SYS_CSRRC);
  wire is_priv_op = l0_valid_i && (l0_sys_op_i == `SYS_PRIV);

  wire csr_w_is_zero = l0_csr_is_imm_i ? (l0_imm_i[4:0] == 5'd0) : (fwd_l0_src1 == {XLEN{1'b0}});
  wire csr_intends_write = (l0_sys_op_i == `SYS_CSRRW) || !csr_w_is_zero;

  assign csr_req_valid_o = is_csr_op && !stall_i && !flush_i;
  assign csr_raddr_o     = l0_csr_addr_i;
  assign csr_rwen_o      = csr_intends_write;

  // CSR Write Data Calculation (RW, RS, RC)
  wire [XLEN-1:0] csr_in_wdata = l0_csr_is_imm_i ? {{(XLEN-5){1'b0}}, l0_imm_i[4:0]} : fwd_l0_src1;
  wire [XLEN-1:0] csr_calc_wdata = (l0_sys_op_i == `SYS_CSRRW) ? csr_in_wdata :
                                   (l0_sys_op_i == `SYS_CSRRS) ? (csr_rdata_i | csr_in_wdata) :
                                   (l0_sys_op_i == `SYS_CSRRC) ? (csr_rdata_i & ~csr_in_wdata) :
                                   csr_in_wdata;

  // Privileged Op Decodes
  wire is_ecall   = is_priv_op && (l0_priv_op_i == `PRIV_ECALL);
  wire is_ebreak  = is_priv_op && (l0_priv_op_i == `PRIV_EBREAK);
  wire is_mret    = is_priv_op && (l0_priv_op_i == `PRIV_MRET);
  wire is_sret    = is_priv_op && (l0_priv_op_i == `PRIV_SRET);
  wire is_wfi     = is_priv_op && (l0_priv_op_i == `PRIV_WFI);
  wire is_sfence  = is_priv_op && (l0_priv_op_i == `PRIV_SFENCE_VMA);
  wire is_fence_i = is_priv_op && (l0_priv_op_i == `PRIV_FENCE_I);

  wire illegal_mret = is_mret && (priv_mode_i < 2'b11);
  wire illegal_sret = is_sret && (priv_mode_i < 2'b01);
  wire illegal_priv = illegal_mret || illegal_sret;
  wire csr_illegal  = is_csr_op && csr_illegal_i;

  wire [5:0] priv_cause = is_ecall ? ((priv_mode_i == 2'b11) ? `EXC_ECALL_M :
                                      (priv_mode_i == 2'b01) ? `EXC_ECALL_S : `EXC_ECALL_U) :
                          is_ebreak ? `EXC_BREAKPOINT :
                          (illegal_priv || csr_illegal) ? `EXC_ILLEGAL_INST : 6'd0;

  wire priv_has_exc = is_ecall || is_ebreak || illegal_priv || csr_illegal;

  // --------------------------------------------------------------------------
  // Control Flow: Branch Condition & Jump Evaluation
  // --------------------------------------------------------------------------
  wire is_branch0 = l0_valid_i && (l0_br_type_i != `BR_NONE);
  wire is_jump0   = l0_valid_i && (l0_jump_type_i != `JUMP_NONE);

  // --------------------------------------------------------------------------
  // INT-EU Operand Routing
  // --------------------------------------------------------------------------
  wire int_freeze = stall_i || ma_busy || (is_fp_op && fp_busy);
  wire int_valid  = !int_freeze && ((int_en_l0_i && l0_valid_i && !is_csr_op && !is_priv_op) ||
                                    (int_en_l1_i && l1_valid_i && !branch_mispredict_o));

  // Operand 1 selection
  wire [XLEN-1:0] int_src1_l0 = (is_jump0 || l0_use_pc_i) ? l0_pc_i : fwd_l0_src1;
  wire [XLEN-1:0] int_src1_l1 = fwd_l1_src1;

  // Operand 2 selection
  wire [XLEN-1:0] int_src2_l0 = (is_jump0)     ? 64'd4 :
                                (l0_use_imm_i) ? l0_imm_i    : fwd_l0_src2;
  wire [XLEN-1:0] int_src2_l1 = l1_use_imm_i ? l1_imm_i    : fwd_l1_src2;

  wire [XLEN-1:0] int_src1    = int_en_l0_i ? int_src1_l0 : int_src1_l1;
  wire [XLEN-1:0] int_src2    = int_en_l0_i ? int_src2_l0 : int_src2_l1;
  wire [4:0]      int_alu_op  = int_en_l0_i ? l0_alu_op_i : l1_alu_op_i;
  wire [4:0]      int_rd      = int_en_l0_i ? l0_rd_i     : l1_rd_i;
  wire            int_is_word = int_en_l0_i ? (is_jump0 ? 1'b0 : l0_is_word_i) : l1_is_word_i;

  wire l0_is_sub = (l0_alu_op_i == `ALU_SUB) || (l0_alu_op_i == `ALU_SLT) || (l0_alu_op_i == `ALU_SLTU);
  wire l1_is_sub = (l1_alu_op_i == `ALU_SUB) || (l1_alu_op_i == `ALU_SLT) || (l1_alu_op_i == `ALU_SLTU);
  wire int_is_sub = int_en_l0_i ? l0_is_sub : l1_is_sub;

  wire int_busy;
  wire int_out_valid;
  wire [4:0] int_out_rd;
  wire [XLEN-1:0] int_out_result;
  wire cmp_eq;
  wire cmp_lt;
  wire cmp_ltu;
  wire ma_busy;

  wire int_comb_valid;
  wire [4:0] int_comb_rd;
  wire [XLEN-1:0] int_comb_result;

  sukuna_int_eu #(
    .XLEN   (XLEN),
    .MUL_LAT(MUL_LAT)
  ) u_int_eu (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .flush_i  (flush_i),
    .stall_i  (int_freeze),
    .valid_i  (int_valid),
    .alu_op_i (int_alu_op),
    .is_sub_i (int_is_sub),
    .is_word_i(int_is_word),
    .src1_i   (int_src1),
    .src2_i   (int_src2),
    .rd_i     (int_rd),
    .busy_o   (int_busy),
    .valid_o  (int_out_valid),
    .rd_o     (int_out_rd),
    .result_o (int_out_result),
    .comb_valid_o (int_comb_valid),
    .comb_rd_o    (int_comb_rd),
    .comb_result_o(int_comb_result),
    .cmp_eq_o (cmp_eq),
    .cmp_lt_o (cmp_lt),
    .cmp_ltu_o(cmp_ltu)
  );

  wire br_sign1 = fwd_l0_src1[XLEN-1];
  wire br_sign2 = fwd_l0_src2[XLEN-1];
  wire br_eq    = (fwd_l0_src1 == fwd_l0_src2);
  wire br_ltu   = (fwd_l0_src1 < fwd_l0_src2);
  wire br_lt    = (br_sign1 != br_sign2) ? br_sign1 : br_ltu;

  // Branch condition evaluation
  reg branch_cond_met;
  always @(*) begin
    case (l0_br_type_i)
      `BR_BEQ:  branch_cond_met = br_eq;
      `BR_BNE:  branch_cond_met = !br_eq;
      `BR_BLT:  branch_cond_met = br_lt;
      `BR_BGE:  branch_cond_met = !br_lt;
      `BR_BLTU: branch_cond_met = br_ltu;
      `BR_BGEU: branch_cond_met = !br_ltu;
      default:  branch_cond_met = 1'b0;
    endcase
  end

  // Branch / Jump Redirection Target Generation (Shared Adder)
  wire [XLEN-1:0] branch_base = (l0_jump_type_i == `JUMP_JALR) ? fwd_l0_src1 : l0_pc_i;
  wire [XLEN-1:0] branch_imm  = l0_imm_i;
  wire [XLEN-1:0] calc_target_pc;

  sk_add #(
    .WIDTH   (XLEN),
    .PIPELINE(0),
    .IMPL    ("CARRY")
  ) u_branch_adder (
    .clk_i   (clk_i),
    .rst_ni  (rst_ni),
    .cin_i   (1'b0),
    .a_i     (branch_base),
    .b_i     (branch_imm),
    .sum_o   (calc_target_pc),
    .cout_o  ()
  );

  wire redirect_active = l0_valid_i && !ex_freeze && (is_jump0 || (is_branch0 && branch_cond_met));
  assign branch_mispredict_o = redirect_active;
  assign branch_target_o     = (l0_jump_type_i == `JUMP_JALR) ? {calc_target_pc[XLEN-1:1], 1'b0} : calc_target_pc;



  // --------------------------------------------------------------------------
  // MA-EU Selection
  // --------------------------------------------------------------------------
  wire ma_valid = (ma_en_l0_i && l0_valid_i) || (ma_en_l1_i && l1_valid_i && !branch_mispredict_o);
  wire [7:0]      ma_op     = ma_en_l0_i ? l0_mem_op_i : l1_mem_op_i;
  wire [4:0]      ma_rd     = ma_en_l0_i ? l0_rd_i     : l1_rd_i;
  wire [XLEN-1:0] ma_base   = ma_en_l0_i ? fwd_l0_src1 : fwd_l1_src1;
  wire [XLEN-1:0] ma_offset = ma_en_l0_i ? l0_imm_i    : l1_imm_i;
  wire [XLEN-1:0] ma_wdata  = ma_en_l0_i ? (is_fp_store ? fwd_fpr_src2 : fwd_l0_src2) : fwd_l1_src2;

  wire ma_req_valid = ma_valid && !stall_i && !flush_i;

  wire ma_out_valid;
  wire [4:0] ma_out_rd;
  wire [XLEN-1:0] ma_out_rdata;

  sukuna_agu_eu #(
    .XLEN       (XLEN),
    .VADDR_WIDTH(VADDR_WIDTH),
    .PADDR_WIDTH(PADDR_WIDTH)
  ) u_agu_eu (
    .clk_i              (clk_i),
    .rst_ni             (rst_ni),
    .req_valid_i        (ma_req_valid),
    .req_op_i           (ma_op),
    .req_rd_i           (ma_rd),
    .req_base_i         (ma_base),
    .req_offset_i       (ma_offset),
    .req_wdata_i        (ma_wdata),
    .busy_o             (ma_busy),
    .snoop_inv_valid_i  (1'b0),
    .snoop_inv_paddr_w_i({(PADDR_WIDTH-2){1'b0}}),
    .dtlb_lookup_valid_o(dtlb_lookup_valid_o),
    .dtlb_vaddr_w_o     (dtlb_vaddr_w_o),
    .dtlb_hit_i         (dtlb_hit_i),
    .dtlb_paddr_w_i     (dtlb_paddr_w_i),
    .dtlb_fault_i       (dtlb_fault_i),
    .l1d_req_valid_o    (l1d_req_valid_o),
    .l1d_req_write_o    (l1d_req_write_o),
    .l1d_req_op_o       (l1d_req_op_o),
    .l1d_req_byte_en_o  (l1d_req_byte_en_o),
    .l1d_paddr_w_o      (l1d_paddr_w_o),
    .l1d_wdata_o        (l1d_wdata_o),
    .l1d_req_ready_i    (l1d_req_ready_i),
    .l1d_resp_valid_i   (l1d_resp_valid_i),
    .l1d_rdata_i        (l1d_rdata_i),
    .l1d_miss_stall_i   (l1d_miss_stall_i),
    .resp_valid_o       (ma_out_valid),
    .resp_rd_o          (ma_out_rd),
    .resp_rdata_o       (ma_out_rdata)
  );

  // Stall backpressure to Hazard Unit (Pattern 1 + Multi-cycle INT)
  assign ex_stall_o = ma_busy || int_busy || (is_fp_op && fp_busy);
  wire   ex_freeze  = stall_i || ex_stall_o;

  // Latch MA-EU response to prevent 1-cycle response pulse from dropping during stalls
  reg [XLEN-1:0] ma_data_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg            ma_valid_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [4:0]      ma_rd_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ma_data_q  <= {XLEN{1'b0}};
      ma_valid_q <= 1'b0;
      ma_rd_q    <= 5'd0;
    end else if (flush_i) begin
      ma_valid_q <= 1'b0;
    end else if (ma_out_valid && stall_i) begin
      ma_data_q  <= ma_out_rdata;
      ma_valid_q <= 1'b1;
      ma_rd_q    <= ma_out_rd;
    end else if (!stall_i) begin
      ma_valid_q <= 1'b0;
    end
  end

  wire            ma_eff_valid = ma_out_valid || ma_valid_q;
  wire [XLEN-1:0] ma_eff_data  = ma_out_valid ? ma_out_rdata : ma_data_q;
  wire [4:0]      ma_eff_rd    = ma_out_valid ? ma_out_rd    : ma_rd_q;

  assign ex_comb_l0_val_o  = !ex_freeze && l0_valid_i && (
                             (int_en_l0_i && !is_csr_op && !is_priv_op && int_comb_valid) ||
                             (is_csr_op && !priv_has_exc) ||
                             (is_fp_op && fp_unit_writes_gpr) ||
                             (ma_en_l0_i && ma_eff_valid)
                             );
  assign ex_comb_l0_rd_o   = ma_en_l0_i ? ma_eff_rd : l0_rd_i;
  assign ex_comb_l0_data_o = ma_en_l0_i ? ma_eff_data :
                             is_csr_op  ? csr_rdata_i  :
                             is_fp_op   ? fp_unit_res  : int_comb_result;

  assign ex_comb_l1_val_o  = !ex_freeze && l1_valid_i && !branch_mispredict_o &&
                             ((int_en_l1_i && int_comb_valid) || (ma_en_l1_i && ma_eff_valid));
  assign ex_comb_l1_rd_o   = ma_en_l1_i ? ma_eff_rd : l1_rd_i;
  assign ex_comb_l1_data_o = ma_en_l1_i ? ma_eff_data : int_comb_result;

  // --------------------------------------------------------------------------
  // Pipeline Registers to WB Stage
  // --------------------------------------------------------------------------
  reg              ex_l0_valid_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg              ex_l1_valid_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg              int_was_l0_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg              ma_was_l0_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg              ma_was_l1_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg              sys_was_l0_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg              sys_valid_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [4:0]        sys_rd_q;        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]   sys_rdata_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg              sys_exc_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [5:0]        sys_cause_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg              sys_csr_wen_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [11:0]       sys_csr_addr_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]   sys_csr_wdata_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg              sys_mret_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg              sys_sret_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg              sys_wfi_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg              sys_sfence_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg              sys_fence_i_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg              is_fp_load_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg              is_fp_op_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg              fp_writes_fpr_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg              is_fp_flw_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [4:0]        fp_rd_q;         /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]   fp_res_q;        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  reg [XLEN-1:0]   l0_pc_q;         /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]   l1_pc_q;         /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]   l0_tval_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]   l1_tval_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg              slot1_older_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]   ex_l0_data_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]   ex_l1_data_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg              dtlb_fault_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]   ma_tval_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      slot1_older_q   <= 1'b0;
      ex_l0_valid_q   <= 1'b0;
      ex_l1_valid_q   <= 1'b0;
      int_was_l0_q    <= 1'b0;
      ma_was_l0_q     <= 1'b0;
      ma_was_l1_q     <= 1'b0;
      sys_was_l0_q    <= 1'b0;
      sys_valid_q     <= 1'b0;
      sys_rd_q        <= 5'd0;
      sys_rdata_q     <= {XLEN{1'b0}};
      sys_exc_q       <= 1'b0;
      sys_cause_q     <= 6'd0;
      sys_csr_wen_q   <= 1'b0;
      sys_csr_addr_q  <= 12'd0;
      sys_csr_wdata_q <= {XLEN{1'b0}};
      sys_mret_q      <= 1'b0;
      sys_sret_q      <= 1'b0;
      sys_wfi_q       <= 1'b0;
      sys_sfence_q    <= 1'b0;
      sys_fence_i_q   <= 1'b0;
      is_fp_load_q    <= 1'b0;
      is_fp_op_q      <= 1'b0;
      fp_writes_fpr_q <= 1'b0;
      is_fp_flw_q     <= 1'b0;
      fp_rd_q         <= 5'd0;
      fp_res_q        <= {XLEN{1'b0}};
      l0_pc_q         <= {XLEN{1'b0}};
      l1_pc_q         <= {XLEN{1'b0}};
      l0_tval_q       <= {XLEN{1'b0}};
      l1_tval_q       <= {XLEN{1'b0}};
      ex_l0_data_q    <= {XLEN{1'b0}};
      ex_l1_data_q    <= {XLEN{1'b0}};
      dtlb_fault_q    <= 1'b0;
      ma_tval_q       <= {XLEN{1'b0}};
    end else begin
      if (flush_i) begin
        slot1_older_q   <= 1'b0;
        ex_l0_valid_q   <= 1'b0;
        ex_l1_valid_q   <= 1'b0;
        int_was_l0_q    <= 1'b0;
        ma_was_l0_q     <= 1'b0;
        ma_was_l1_q     <= 1'b0;
        sys_was_l0_q    <= 1'b0;
        sys_valid_q     <= 1'b0;
        sys_exc_q       <= 1'b0;
        sys_csr_wen_q   <= 1'b0;
        sys_mret_q      <= 1'b0;
        sys_sret_q      <= 1'b0;
        sys_wfi_q       <= 1'b0;
        sys_sfence_q    <= 1'b0;
        sys_fence_i_q   <= 1'b0;
        is_fp_load_q    <= 1'b0;
        is_fp_op_q      <= 1'b0;
        fp_writes_fpr_q <= 1'b0;
        is_fp_flw_q     <= 1'b0;
        fp_rd_q         <= 5'd0;
        fp_res_q        <= {XLEN{1'b0}};
        ex_l0_data_q    <= {XLEN{1'b0}};
        ex_l1_data_q    <= {XLEN{1'b0}};
        dtlb_fault_q    <= 1'b0;
        ma_tval_q       <= {XLEN{1'b0}};
      end else if (!ex_freeze) begin
        slot1_older_q   <= ex_slot1_older_i;
        ex_l0_valid_q   <= l0_valid_i;
        ex_l1_valid_q   <= l1_valid_i && !branch_mispredict_o;
        int_was_l0_q    <= int_en_l0_i && !is_csr_op && !is_priv_op;
        ma_was_l0_q     <= ma_en_l0_i;
        ma_was_l1_q     <= ma_en_l1_i;
        sys_was_l0_q    <= is_csr_op || is_priv_op;
        sys_valid_q     <= l0_valid_i && (is_csr_op || is_priv_op);
        sys_rd_q        <= l0_rd_i;
        sys_rdata_q     <= csr_rdata_i;
        sys_exc_q       <= priv_has_exc;
        sys_cause_q     <= priv_cause;
        sys_csr_wen_q   <= is_csr_op && csr_intends_write && !priv_has_exc;
        sys_csr_addr_q  <= l0_csr_addr_i;
        sys_csr_wdata_q <= csr_calc_wdata;
        sys_mret_q      <= is_mret && !illegal_mret;
        sys_sret_q      <= is_sret && !illegal_sret;
        sys_wfi_q       <= is_wfi;
        sys_sfence_q    <= is_sfence;
        sys_fence_i_q   <= is_fence_i;
        is_fp_load_q    <= is_fp_load;
        is_fp_op_q      <= is_fp_op;
        fp_writes_fpr_q <= fp_unit_writes_fpr;
        if (is_fp_op) begin
          fp_rd_q  <= l0_rd_i;
          fp_res_q <= fp_unit_res;
        end
        is_fp_flw_q     <= is_fp_load && (l0_mem_op_i[2:0] == 3'b010);
        l0_pc_q         <= l0_pc_i;
        l1_pc_q         <= l1_pc_i;
        l0_tval_q       <= l0_pc_i;
        l1_tval_q       <= l1_pc_i;
        dtlb_fault_q    <= dtlb_fault_i;
        ma_tval_q       <= ma_base;
      end
    end
  end

  // --------------------------------------------------------------------------
  // Output Routing to WB Stage
  // --------------------------------------------------------------------------
  assign ex_wb_l0_valid_o     = !stall_i && ex_l0_valid_q && (sys_was_l0_q ? sys_valid_q :
                                is_fp_op_q   ? 1'b1 :
                                int_was_l0_q ? int_out_valid : ma_eff_valid);
  assign ex_wb_l0_pc_o        = l0_pc_q;
  assign ex_wb_l0_rd_o        = sys_was_l0_q ? sys_rd_q :
                                is_fp_op_q   ? fp_rd_q :
                                int_was_l0_q ? int_out_rd : ma_eff_rd;
  assign ex_wb_l0_data_o      = sys_was_l0_q ? sys_rdata_q :
                                is_fp_op_q   ? fp_res_q :
                                int_was_l0_q ? int_out_result :
                                is_fp_flw_q  ? {32'hFFFFFFFF, ma_eff_data[31:0]} :
                                ma_eff_data;
  assign ex_wb_l0_exc_o       = sys_was_l0_q ? sys_exc_q :
                                (!int_was_l0_q && dtlb_fault_q);
  assign ex_wb_l0_cause_o     = sys_was_l0_q ? sys_cause_q : `EXC_LOAD_PAGE_FAULT;
  assign ex_wb_l0_tval_o      = sys_was_l0_q ? l0_tval_q : ma_tval_q;

  assign ex_wb_l0_csr_wen_o   = sys_was_l0_q && sys_csr_wen_q;
  assign ex_wb_l0_csr_addr_o  = sys_csr_addr_q;
  assign ex_wb_l0_csr_wdata_o = sys_csr_wdata_q;
  assign ex_wb_l0_mret_o      = sys_was_l0_q && sys_mret_q;
  assign ex_wb_l0_sret_o      = sys_was_l0_q && sys_sret_q;
  assign ex_wb_l0_wfi_o       = sys_was_l0_q && sys_wfi_q;
  assign ex_wb_l0_sfence_o    = sys_was_l0_q && sys_sfence_q;
  assign ex_wb_l0_fence_i_o   = sys_was_l0_q && sys_fence_i_q;
  assign ex_wb_l0_writes_fpr_o= is_fp_load_q || (is_fp_op_q && fp_writes_fpr_q);

  assign ex_wb_l1_valid_o     = !stall_i && ex_l1_valid_q && (ma_was_l1_q ? ma_eff_valid : int_out_valid);
  assign ex_wb_l1_pc_o        = l1_pc_q;
  assign ex_wb_l1_rd_o        = ma_was_l1_q ? ma_eff_rd : int_out_rd;
  assign ex_wb_l1_data_o      = ma_was_l1_q ? ma_eff_data : int_out_result;
  assign ex_wb_l1_exc_o       = (int_was_l0_q && dtlb_fault_q);
  assign ex_wb_l1_cause_o     = `EXC_LOAD_PAGE_FAULT;
  assign ex_wb_l1_tval_o      = l1_tval_q;
  assign ex_wb_slot1_older_o  = slot1_older_q;

  // Avoid unused variable warnings
  wire _unused = ma_was_l0_q;

endmodule
