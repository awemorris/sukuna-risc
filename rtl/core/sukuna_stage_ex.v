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
  parameter MUL_LAT     = `MUL_LAT,
  parameter FP_MUL_LAT  = `FP_MUL_LAT
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
  input  wire                   l1d_sbuf_empty_i,
  input  wire                   snoop_inv_valid_i,
  input  wire [PADDR_WIDTH-1:2] snoop_inv_paddr_w_i,

  // Dedicated Uncached / MMIO Port
  output wire                   uncached_req_valid_o,
  output wire                   uncached_req_write_o,
  output wire [3:0]             uncached_req_op_o,
  output wire [7:0]             uncached_req_byte_en_o,
  output wire [PADDR_WIDTH-1:2] uncached_req_paddr_w_o,
  output wire [XLEN-1:0]        uncached_req_wdata_o,
  input  wire                   uncached_req_ready_i,
  input  wire                   uncached_resp_valid_i,
  input  wire [XLEN-1:0]        uncached_resp_rdata_i,

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

  // Pre-decoded Forwarding Select Inputs from ID3
  input  wire [1:0]             fwd_sel_l0_rs1_i,
  input  wire [1:0]             fwd_sel_l0_rs2_i,
  input  wire [1:0]             fwd_sel_l1_rs1_i,
  input  wire [1:0]             fwd_sel_l1_rs2_i,
  input  wire [1:0]             fwd_sel_fpr_rs1_i,
  input  wire [1:0]             fwd_sel_fpr_rs2_i,

  // In-flight MA1 / MA2 destination specifiers to ID3
  output wire                   ma_s1_valid_o,
  output wire [4:0]             ma_s1_rd_o,
  output wire                   ma_s2_valid_o,
  output wire [4:0]             ma_s2_rd_o
);

  // --------------------------------------------------------------------------
  // Operand Forwarding / Bypass Network
  // Driven directly by registered selection bits from ID3:
  //   - FWD_INT_WB (2'd1): 1-cycle INT / CSR / FP WB register
  //   - FWD_MA_WB  (2'd2): 3-cycle MA-EU WB register
  // --------------------------------------------------------------------------
  localparam FWD_NONE   = 2'd0;
  localparam FWD_INT_WB = 2'd1;
  localparam FWD_MA_WB  = 2'd2;

  wire [XLEN-1:0] int_wb_data;
  wire [XLEN-1:0] ma_wb_data;

  wire [XLEN-1:0] fwd_l0_src1 = (fwd_sel_l0_rs1_i == FWD_INT_WB) ? int_wb_data :
                                (fwd_sel_l0_rs1_i == FWD_MA_WB)  ? ma_wb_data  :
                                l0_src1_i;

  wire [XLEN-1:0] fwd_l0_src2 = (fwd_sel_l0_rs2_i == FWD_INT_WB) ? int_wb_data :
                                (fwd_sel_l0_rs2_i == FWD_MA_WB)  ? ma_wb_data  :
                                l0_src2_i;

  wire [XLEN-1:0] fwd_l1_src1 = (fwd_sel_l1_rs1_i == FWD_INT_WB) ? int_wb_data :
                                (fwd_sel_l1_rs1_i == FWD_MA_WB)  ? ma_wb_data  :
                                l1_src1_i;

  wire [XLEN-1:0] fwd_l1_src2 = (fwd_sel_l1_rs2_i == FWD_INT_WB) ? int_wb_data :
                                (fwd_sel_l1_rs2_i == FWD_MA_WB)  ? ma_wb_data  :
                                l1_src2_i;

  // Floating-Point Execution Unit & Pre-decoded Operand Forwarding
  wire is_fp_op    = l0_valid_i && (l0_alu_op_i == `ALU_FP);
  wire is_fp_store = (l0_mem_op_i[7:4] == `AMO_FP) && l0_mem_op_i[3];

  wire            fp_busy;
  wire            fp_out_valid;
  wire [4:0]      fp_out_rd;
  wire [XLEN-1:0] fp_unit_res;
  wire            fp_unit_writes_fpr;
  wire            fp_unit_writes_gpr;
  wire            fp_freeze;

  wire [XLEN-1:0] fwd_fpr_src1 = (fwd_sel_fpr_rs1_i == FWD_INT_WB) ? fp_unit_res :
                                 (fwd_sel_fpr_rs1_i == FWD_MA_WB)  ? ma_wb_data  :
                                 fpr_src1_i;
  wire [XLEN-1:0] fwd_fpr_src2 = (fwd_sel_fpr_rs2_i == FWD_INT_WB) ? fp_unit_res :
                                 (fwd_sel_fpr_rs2_i == FWD_MA_WB)  ? ma_wb_data  :
                                 fpr_src2_i;

  sukuna_fp_unit #(
    .XLEN   (XLEN),
    .MUL_LAT(FP_MUL_LAT)
  ) u_fp_unit (
    .clk_i       (clk_i),
    .rst_ni      (rst_ni),
    .flush_i     (flush_i),
    .stall_i     (fp_freeze),
    .valid_i     (is_fp_op),
    .rd_i        (l0_rd_i),
    .funct7_i    (l0_csr_addr_i[11:5]),
    .funct3_i    (l0_mem_op_i[2:0]),
    .rs2_field_i (l0_rs2_i),
    .fpr_src1_i  (fwd_fpr_src1),
    .fpr_src2_i  (fwd_fpr_src2),
    .gpr_src1_i  (fwd_l0_src1),
    .busy_o      (fp_busy),
    .valid_o     (fp_out_valid),
    .rd_o        (fp_out_rd),
    .fp_result_o (fp_unit_res),
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

  wire ex_freeze;
  wire int_freeze;

  assign csr_req_valid_o = is_csr_op && !ex_freeze && !flush_i;
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

  // Pure Lane 0 redirect condition (decoupled from ex_freeze to break stall->redirect->int_valid loop)
  wire l0_redirect_taken = l0_valid_i && (is_jump0 || (is_branch0 && branch_cond_met));

  // --------------------------------------------------------------------------
  // INT-EU Operand Routing
  // --------------------------------------------------------------------------
  wire l0_op_is_fp  = (l0_alu_op_i == `ALU_FP);
  wire l0_op_is_sys = (l0_sys_op_i == `SYS_CSRRW) || (l0_sys_op_i == `SYS_CSRRS) ||
                      (l0_sys_op_i == `SYS_CSRRC) || (l0_sys_op_i == `SYS_PRIV);
  wire l0_int_req   = l0_valid_i && int_en_l0_i && !l0_op_is_fp && !l0_op_is_sys;
  // Note: ID1 never pairs a branch/jump on Lane 0 with Lane 1 (l1_valid_i == 0 when branch/jump),
  // so int_valid and ma_valid do not depend on l0_redirect_taken!
  wire int_valid    = !int_freeze && (l0_int_req || (int_en_l1_i && l1_valid_i));

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
    .comb_valid_o (),
    .comb_rd_o    (),
    .comb_result_o(),
    .cmp_eq_o (cmp_eq),
    .cmp_lt_o (cmp_lt),
    .cmp_ltu_o(cmp_ltu)
  );

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

  wire redirect_active = l0_redirect_taken && !ex_freeze;
  assign branch_mispredict_o = redirect_active;
  assign branch_target_o     = (l0_jump_type_i == `JUMP_JALR) ? {calc_target_pc[XLEN-1:1], 1'b0} : calc_target_pc;



  // --------------------------------------------------------------------------
  // MA-EU Selection & Pipelined Load-Hazard Stall Logic
  // --------------------------------------------------------------------------
  wire ma_valid = (ma_en_l0_i && l0_valid_i) || (ma_en_l1_i && l1_valid_i);
  wire [XLEN-1:0] ma_pc     = ma_en_l0_i ? l0_pc_i     : l1_pc_i;
  wire [7:0]      ma_op     = ma_en_l0_i ? l0_mem_op_i : l1_mem_op_i;
  wire [4:0]      ma_rd     = ma_en_l0_i ? l0_rd_i     : l1_rd_i;
  wire [XLEN-1:0] ma_base   = ma_en_l0_i ? fwd_l0_src1 : fwd_l1_src1;
  wire [XLEN-1:0] ma_offset = ma_en_l0_i ? l0_imm_i    : l1_imm_i;
  wire [XLEN-1:0] ma_wdata  = ma_en_l0_i ? (is_fp_store ? fwd_fpr_src2 : fwd_l0_src2) : fwd_l1_src2;

  wire ma_req_valid = ma_valid && !ex_freeze && !flush_i;

  wire            ma_s1_valid;
  wire [4:0]      ma_s1_rd;
  wire            ma_s1_is_fp;
  wire            ma_s2_valid;
  wire [4:0]      ma_s2_rd;
  wire            ma_s2_is_fp;
  wire            ma_miss_or_amo_stall;

  wire            ma_out_valid;
  wire [XLEN-1:0] ma_out_pc;
  wire [4:0]      ma_out_rd;
  wire [XLEN-1:0] ma_out_rdata;
  wire            ma_out_writes_fpr;

  sukuna_agu_eu #(
    .XLEN       (XLEN),
    .VADDR_WIDTH(VADDR_WIDTH),
    .PADDR_WIDTH(PADDR_WIDTH)
  ) u_agu_eu (
    .clk_i              (clk_i),
    .rst_ni             (rst_ni),
    .req_valid_i        (ma_req_valid),
    .req_pc_i           (ma_pc),
    .req_op_i           (ma_op),
    .req_rd_i           (ma_rd),
    .req_base_i         (ma_base),
    .req_offset_i       (ma_offset),
    .req_wdata_i        (ma_wdata),
    .busy_o             (ma_busy),
    .s1_valid_o         (ma_s1_valid),
    .s1_rd_o            (ma_s1_rd),
    .s1_is_fp_o         (ma_s1_is_fp),
    .s2_valid_o         (ma_s2_valid),
    .s2_rd_o            (ma_s2_rd),
    .s2_is_fp_o         (ma_s2_is_fp),
    .miss_or_amo_stall_o(ma_miss_or_amo_stall),
    .snoop_inv_valid_i  (snoop_inv_valid_i),
    .snoop_inv_paddr_w_i(snoop_inv_paddr_w_i),
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
    .uncached_req_valid_o  (uncached_req_valid_o),
    .uncached_req_write_o  (uncached_req_write_o),
    .uncached_req_op_o     (uncached_req_op_o),
    .uncached_req_byte_en_o(uncached_req_byte_en_o),
    .uncached_req_paddr_w_o(uncached_req_paddr_w_o),
    .uncached_req_wdata_o  (uncached_req_wdata_o),
    .uncached_req_ready_i  (uncached_req_ready_i),
    .uncached_resp_valid_i (uncached_resp_valid_i),
    .uncached_resp_rdata_i (uncached_resp_rdata_i),
    .resp_valid_o       (ma_out_valid),
    .resp_pc_o          (ma_out_pc),
    .resp_rd_o          (ma_out_rd),
    .resp_rdata_o       (ma_out_rdata),
    .resp_writes_fpr_o  (ma_out_writes_fpr)
  );

  assign ma_s1_valid_o = ma_s1_valid && !ma_s1_is_fp;
  assign ma_s1_rd_o    = ma_s1_rd;
  assign ma_s2_valid_o = ma_s2_valid && !ma_s2_is_fp;
  assign ma_s2_rd_o    = ma_s2_rd;
  assign ma_wb_data    = ma_out_rdata;

  // Load-Use (RAW) and WAW Hazard Detection against in-flight MA1 (s1) and MA2 (s2)
  wire s1_has_gpr_rd     = ma_s1_valid && !ma_s1_is_fp && (ma_s1_rd != 5'd0);
  wire s2_has_gpr_rd     = ma_s2_valid && !ma_s2_is_fp && (ma_s2_rd != 5'd0);
  wire l0_op_is_fp_mem   = (l0_mem_op_i[7:4] == `AMO_FP);
  wire l0_op_is_fp_load  = l0_op_is_fp_mem && !l0_mem_op_i[3];
  wire l0_op_is_fp_store = l0_op_is_fp_mem && l0_mem_op_i[3];
  wire l0_fp_writes_gpr  = (l0_csr_addr_i[11:7] == 5'b11100) ||
                           (l0_csr_addr_i[11:7] == 5'b10100) ||
                           (l0_csr_addr_i[11:7] == 5'b11000);
  wire l0_uses_gpr_rs2   = !l0_op_is_fp && !l0_op_is_fp_store;
  wire l0_writes_gpr     = !l0_op_is_fp_load && (!l0_op_is_fp || l0_fp_writes_gpr) && (l0_rd_i != 5'd0);

  // Pre-evaluate 5-bit register index matches directly from pipeline registers (independent of l0_valid_i)
  wire l0_match_s1 = (l0_rs1_i == ma_s1_rd) ||
                     (l0_uses_gpr_rs2 && (l0_rs2_i == ma_s1_rd)) ||
                     (l0_writes_gpr   && (l0_rd_i  == ma_s1_rd));
  wire l1_match_s1 = (l1_rs1_i == ma_s1_rd) ||
                     (l1_rs2_i == ma_s1_rd) ||
                     (l1_rd_i  == ma_s1_rd);

  wire l0_match_s2 = (l0_rs1_i == ma_s2_rd) ||
                     (l0_uses_gpr_rs2 && (l0_rs2_i == ma_s2_rd)) ||
                     (l0_writes_gpr   && (l0_rd_i  == ma_s2_rd));
  wire l1_match_s2 = (l1_rs1_i == ma_s2_rd) ||
                     (l1_rs2_i == ma_s2_rd) ||
                     (l1_rd_i  == ma_s2_rd);

  wire hazard_s1 = s1_has_gpr_rd && ((l0_valid_i && l0_match_s1) || (l1_valid_i && l1_match_s1));
  wire hazard_s2 = s2_has_gpr_rd && ((l0_valid_i && l0_match_s2) || (l1_valid_i && l1_match_s2));

  wire load_hazard_stall = hazard_s1 || hazard_s2;
  wire ma_struct_stall   = ((ma_en_l0_i && l0_valid_i) || (ma_en_l1_i && l1_valid_i)) && ma_busy;
  wire sys_ma_stall      = l0_valid_i && l0_op_is_sys && (ma_busy || ma_out_valid || !l1d_sbuf_empty_i);
  wire non_eu_stall      = ma_miss_or_amo_stall || ma_struct_stall || sys_ma_stall || load_hazard_stall;
  wire other_ex_stall    = (is_fp_op && fp_busy) || non_eu_stall;

  // Stall backpressure to Hazard Unit
  assign ex_stall_o = int_busy || other_ex_stall;
  assign int_freeze = !int_busy && other_ex_stall;
  assign fp_freeze  = int_busy || non_eu_stall;
  assign ex_freeze  = int_busy || other_ex_stall;

  // --------------------------------------------------------------------------
  // Pipeline Registers to WB Stage (Lane 0: INT/CSR/FP, Lane 1: 3-cycle MA)
  // --------------------------------------------------------------------------
  reg              int_was_l0_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* max_fanout = 4 *) reg sys_was_l0_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
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
  (* max_fanout = 4 *) reg is_fp_op_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]   int_pc_q;        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]   l0_tval_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      int_was_l0_q    <= 1'b0;
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
      is_fp_op_q      <= 1'b0;
      int_pc_q        <= {XLEN{1'b0}};
      l0_tval_q       <= {XLEN{1'b0}};
    end else begin
      if (flush_i) begin
        int_was_l0_q    <= 1'b0;
        sys_was_l0_q    <= 1'b0;
        sys_valid_q     <= 1'b0;
        sys_exc_q       <= 1'b0;
        sys_csr_wen_q   <= 1'b0;
        sys_mret_q      <= 1'b0;
        sys_sret_q      <= 1'b0;
        sys_wfi_q       <= 1'b0;
        sys_sfence_q    <= 1'b0;
        sys_fence_i_q   <= 1'b0;
        is_fp_op_q      <= 1'b0;
      end else if (!ex_freeze) begin
        int_was_l0_q    <= int_en_l0_i && !is_csr_op && !is_priv_op && !is_fp_op;
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
        is_fp_op_q      <= is_fp_op;
        int_pc_q        <= (int_en_l0_i || is_csr_op || is_priv_op || is_fp_op) ? l0_pc_i : l1_pc_i;
        l0_tval_q       <= l0_pc_i;
      end else begin
        // Clear 1-cycle commit pulses while holding result data for EX forwarding
        sys_valid_q   <= 1'b0;
        sys_exc_q     <= 1'b0;
        sys_csr_wen_q <= 1'b0;
        sys_mret_q    <= 1'b0;
        sys_sret_q    <= 1'b0;
        sys_wfi_q     <= 1'b0;
        sys_sfence_q  <= 1'b0;
        sys_fence_i_q <= 1'b0;
      end
    end
  end

  assign int_wb_data = sys_was_l0_q ? sys_rdata_q :
                       is_fp_op_q   ? fp_unit_res :
                       int_out_result;

  // --------------------------------------------------------------------------
  // Output Routing to WB Stage
  // - Lane 0: INT / CSR / FP result (or FP Load flw/fld)
  // - Lane 1: 3-cycle MA GPR Load / Store / AMO result
  // --------------------------------------------------------------------------
  wire int_wb_valid = sys_was_l0_q ? sys_valid_q  :
                      is_fp_op_q   ? fp_out_valid :
                      int_out_valid;

  assign ex_wb_l0_valid_o      = ma_out_writes_fpr ? ma_out_valid : int_wb_valid;
  assign ex_wb_l0_pc_o         = ma_out_writes_fpr ? ma_out_pc    : int_pc_q;
  assign ex_wb_l0_rd_o         = ma_out_writes_fpr ? ma_out_rd    :
                                 sys_was_l0_q      ? sys_rd_q     :
                                 is_fp_op_q        ? fp_out_rd    :
                                 int_out_rd;
  assign ex_wb_l0_data_o       = ma_out_writes_fpr ? ma_out_rdata : int_wb_data;
  assign ex_wb_l0_exc_o        = !ma_out_writes_fpr && sys_was_l0_q && sys_exc_q;
  assign ex_wb_l0_cause_o      = sys_cause_q;
  assign ex_wb_l0_tval_o       = l0_tval_q;

  assign ex_wb_l0_csr_wen_o    = !ma_out_writes_fpr && sys_was_l0_q && sys_csr_wen_q;
  assign ex_wb_l0_csr_addr_o   = sys_csr_addr_q;
  assign ex_wb_l0_csr_wdata_o  = sys_csr_wdata_q;
  assign ex_wb_l0_mret_o       = !ma_out_writes_fpr && sys_was_l0_q && sys_mret_q;
  assign ex_wb_l0_sret_o       = !ma_out_writes_fpr && sys_was_l0_q && sys_sret_q;
  assign ex_wb_l0_wfi_o        = !ma_out_writes_fpr && sys_was_l0_q && sys_wfi_q;
  assign ex_wb_l0_sfence_o     = !ma_out_writes_fpr && sys_was_l0_q && sys_sfence_q;
  assign ex_wb_l0_fence_i_o    = !ma_out_writes_fpr && sys_was_l0_q && sys_fence_i_q;
  assign ex_wb_l0_writes_fpr_o = ma_out_writes_fpr || (is_fp_op_q && fp_unit_writes_fpr);

  assign ex_wb_l1_valid_o      = ma_out_valid && !ma_out_writes_fpr;
  assign ex_wb_l1_pc_o         = ma_out_pc;
  assign ex_wb_l1_rd_o         = ma_out_rd;
  assign ex_wb_l1_data_o       = ma_out_rdata;
  assign ex_wb_l1_exc_o        = 1'b0;
  assign ex_wb_l1_cause_o      = `EXC_LOAD_PAGE_FAULT;
  assign ex_wb_l1_tval_o       = {XLEN{1'b0}};
  assign ex_wb_slot1_older_o   = ex_wb_l1_valid_o;

  // Avoid unused variable warnings
  wire _unused = &{1'b0, stall_i, ex_slot1_older_i, wb_l0_wen_i, wb_l0_rd_i, wb_l0_data_i,
                   wb_l1_wen_i, wb_l1_rd_i, wb_l1_data_i, int_was_l0_q, fp_unit_writes_gpr, 1'b0};

endmodule
