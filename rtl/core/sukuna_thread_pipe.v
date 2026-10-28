// ============================================================================
// Single Thread Pipeline (Hart) Wrapper (Verilog 2005)
// Complies with design-rule.md
// ============================================================================
// Stages:
//   IF1 -> IF2 -> ID1 -> ID2 -> ID3 -> EX -> WB
// Features:
//   - In-order Dual-Lane architecture (Lane 0: older, Lane 1: younger)
//   - EX enable bits control (no wide datapath swap mux)
//   - Full EX-stall backpressure to upstream stages (Pattern 1)
//   - Precise exception handling (Lane 0 squashes Lane 1 on trap)
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_thread_pipe #(
  parameter HART_ID     = 0,
  parameter XLEN        = `XLEN,
  parameter VADDR_WIDTH = `VADDR_WIDTH,
  parameter PADDR_WIDTH = `PADDR_WIDTH
)(
  input  wire                       clk_i,
  input  wire                       rst_ni,

  // --------------------------------------------------------------------------
  // Interrupt & CSR Inputs
  // --------------------------------------------------------------------------
  input  wire                       meip_i,
  input  wire                       seip_i,
  input  wire                       mtip_i,
  input  wire                       msip_i,
  output wire [XLEN-1:0]            satp_o,
  output wire                       sfence_flush_o,

  // --------------------------------------------------------------------------
  // L1-ITLB Interface
  // --------------------------------------------------------------------------
  output wire                       itlb_req_valid_o,
  output wire [VADDR_WIDTH-1:0]     itlb_vaddr_o,
  input  wire                       itlb_hit_i,
  input  wire [PADDR_WIDTH-1:0]     itlb_paddr_i,
  input  wire                       itlb_fault_i,

  // --------------------------------------------------------------------------
  // L1I Cache Interface
  // --------------------------------------------------------------------------
  output wire                       l1i_req_valid_o,
  output wire [PADDR_WIDTH-1:0]     l1i_paddr_o,
  input  wire                       l1i_resp_valid_i,
  input  wire [31:0]                l1i_inst_i,
  input  wire                       l1i_miss_i,
  output wire                       fence_i_flush_o,

  // --------------------------------------------------------------------------
  // L1-DTLB Interface
  // --------------------------------------------------------------------------
  output wire                       dtlb_lookup_valid_o,
  output wire [VADDR_WIDTH-1:0]     dtlb_vaddr_o,
  input  wire                       dtlb_hit_i,
  input  wire [PADDR_WIDTH-1:0]     dtlb_paddr_i,
  input  wire                       dtlb_fault_i,

  // --------------------------------------------------------------------------
  // L1D Cache Interface
  // --------------------------------------------------------------------------
  output wire                       l1d_req_valid_o,
  output wire                       l1d_req_write_o,
  output wire [2:0]                 l1d_req_op_o,
  output wire [PADDR_WIDTH-1:0]     l1d_paddr_o,
  output wire [XLEN-1:0]            l1d_wdata_o,
  input  wire                       l1d_req_ready_i,
  input  wire                       l1d_resp_valid_i,
  input  wire [XLEN-1:0]            l1d_rdata_i,
  input  wire                       l1d_miss_stall_i,

  // --------------------------------------------------------------------------
  // Shared Execution Unit Request & Response Interface
  // --------------------------------------------------------------------------
  output wire                       shared_req_valid_o,
  output wire [1:0]                 shared_req_type_o,
  output wire [4:0]                 shared_req_rd_o,
  output wire [XLEN-1:0]            shared_req_src1_o,
  output wire [XLEN-1:0]            shared_req_src2_o,
  output wire [XLEN-1:0]            shared_req_src3_o,
  input  wire                       shared_stall_i,

  input  wire                       shared_resp_valid_i,
  input  wire [4:0]                 shared_resp_rd_i,
  input  wire [XLEN-1:0]            shared_resp_data_i
);

  assign fence_i_flush_o = 1'b0;
  assign sfence_flush_o  = 1'b0;

  // --------------------------------------------------------------------------
  // Hazard & Stall Wires
  // --------------------------------------------------------------------------
  wire stall_if1, stall_if2, stall_id1, stall_id2, stall_id3, stall_ex;
  wire flush_if1, flush_if2, flush_id1, flush_id2, flush_id3, flush_ex;
  wire ex_stall;
  wire [1:0] fetch_step;

  // Trap and redirection wires
  wire trap_valid;
  wire [5:0] trap_cause;
  wire [XLEN-1:0] trap_target_pc;
  wire trap_flush;

  // --------------------------------------------------------------------------
  // Stage Interconnects
  // --------------------------------------------------------------------------
  // IF1 -> IF2
  wire            if1_valid;
  wire [XLEN-1:0] if1_pc;

  // IF2 -> ID1
  wire            if2_valid0, if2_valid1;
  wire [XLEN-1:0] if2_pc0, if2_pc1;
  wire [31:0]     if2_inst0, if2_inst1;

  // ID1 -> RegFile (Zero-Mux unconditioned read ports)
  wire [4:0]      rf_raddr_l0_rs1, rf_raddr_l0_rs2;
  wire [4:0]      rf_raddr_l1_rs1, rf_raddr_l1_rs2;

  // RegFile -> ID3
  wire [XLEN-1:0] rf_rdata_l0_rs1, rf_rdata_l0_rs2;
  wire [XLEN-1:0] rf_rdata_l1_rs1, rf_rdata_l1_rs2;

  // ID1 -> ID2
  wire            id1_valid0, id1_valid1;
  wire [XLEN-1:0] id1_pc0, id1_pc1;
  wire [31:0]     id1_inst0, id1_inst1;
  wire [1:0]      id1_type0, id1_type1;
  wire [4:0]      id1_rd0, id1_rd1;
  wire [4:0]      id1_rs1_0, id1_rs1_1;
  wire [4:0]      id1_rs2_0, id1_rs2_1;
  wire [XLEN-1:0] id1_imm0, id1_imm1;
  wire [3:0]      id1_alu_op0, id1_alu_op1;
  wire [2:0]      id1_mem_op0, id1_mem_op1;

  // ID2 -> ID3
  wire            id2_valid0, id2_valid1;
  wire [XLEN-1:0] id2_pc0, id2_pc1;
  wire [4:0]      id2_rd0, id2_rd1;
  wire [4:0]      id2_rs1_0, id2_rs1_1;
  wire [4:0]      id2_rs2_0, id2_rs2_1;
  wire [XLEN-1:0] id2_imm0, id2_imm1;
  wire [3:0]      id2_alu_op0, id2_alu_op1;
  wire [2:0]      id2_mem_op0, id2_mem_op1;
  wire            id2_int_en_l0, id2_int_en_l1;
  wire            id2_ma_en_l0, id2_ma_en_l1;

  // ID3 -> EX
  wire            ex_l0_valid, ex_l1_valid;
  wire [XLEN-1:0] ex_l0_pc, ex_l1_pc;
  wire [4:0]      ex_l0_rd, ex_l1_rd;
  wire [XLEN-1:0] ex_l0_src1, ex_l1_src1;
  wire [XLEN-1:0] ex_l0_src2, ex_l1_src2;
  wire [XLEN-1:0] ex_l0_imm, ex_l1_imm;
  wire [3:0]      ex_l0_alu_op, ex_l1_alu_op;
  wire [2:0]      ex_l0_mem_op, ex_l1_mem_op;
  wire            ex_int_en_l0, ex_int_en_l1;
  wire            ex_ma_en_l0, ex_ma_en_l1;

  // EX -> WB
  wire            ex_wb_l0_valid, ex_wb_l1_valid;
  wire [4:0]      ex_wb_l0_rd, ex_wb_l1_rd;
  wire [XLEN-1:0] ex_wb_l0_data, ex_wb_l1_data;
  wire            ex_wb_l0_exc, ex_wb_l1_exc;

  // WB -> RegFile Commit
  wire            rf_wen_p0, rf_wen_p1, rf_wen_p2;
  wire [4:0]      rf_waddr_p0, rf_waddr_p1, rf_waddr_p2;
  wire [XLEN-1:0] rf_wdata_p0, rf_wdata_p1, rf_wdata_p2;

  // --------------------------------------------------------------------------
  // Stage 1: IF1
  // --------------------------------------------------------------------------
  sukuna_stage_if1 #(
    .HART_ID    (HART_ID),
    .XLEN       (XLEN),
    .VADDR_WIDTH(VADDR_WIDTH),
    .PADDR_WIDTH(PADDR_WIDTH)
  ) u_if1 (
    .clk_i            (clk_i),
    .rst_ni           (rst_ni),
    .stall_i          (stall_if1),
    .flush_i          (flush_if1),
    .redirect_pc_i    (trap_target_pc),
    .fetch_step_i     (fetch_step),
    .itlb_req_valid_o (itlb_req_valid_o),
    .itlb_vaddr_o     (itlb_vaddr_o),
    .itlb_hit_i       (itlb_hit_i),
    .itlb_paddr_i     (itlb_paddr_i),
    .itlb_fault_i     (itlb_fault_i),
    .l1i_req_valid_o  (l1i_req_valid_o),
    .l1i_paddr_o      (l1i_paddr_o),
    .if1_valid_o      (if1_valid),
    .if1_pc_o         (if1_pc)
  );

  // --------------------------------------------------------------------------
  // Stage 2: IF2
  // --------------------------------------------------------------------------
  sukuna_stage_if2 #(
    .XLEN(XLEN)
  ) u_if2 (
    .clk_i            (clk_i),
    .rst_ni           (rst_ni),
    .stall_i          (stall_if2),
    .flush_i          (flush_if2),
    .if1_valid_i      (if1_valid),
    .if1_pc_i         (if1_pc),
    .l1i_resp_valid_i (l1i_resp_valid_i),
    .l1i_inst_i       (l1i_inst_i),
    .l1i_miss_i       (l1i_miss_i),
    .if2_valid0_o     (if2_valid0),
    .if2_pc0_o        (if2_pc0),
    .if2_inst0_o      (if2_inst0),
    .if2_valid1_o     (if2_valid1),
    .if2_pc1_o        (if2_pc1),
    .if2_inst1_o      (if2_inst1)
  );

  // --------------------------------------------------------------------------
  // Stage 3: ID1
  // --------------------------------------------------------------------------
  sukuna_stage_id1 #(
    .XLEN(XLEN)
  ) u_id1 (
    .clk_i            (clk_i),
    .rst_ni           (rst_ni),
    .stall_i          (stall_id1),
    .flush_i          (flush_id1),
    .if2_valid0_i     (if2_valid0),
    .if2_pc0_i        (if2_pc0),
    .if2_inst0_i      (if2_inst0),
    .if2_valid1_i     (if2_valid1),
    .if2_pc1_i        (if2_pc1),
    .if2_inst1_i      (if2_inst1),
    .rf_raddr_l0_rs1_o(rf_raddr_l0_rs1),
    .rf_raddr_l0_rs2_o(rf_raddr_l0_rs2),
    .rf_raddr_l1_rs1_o(rf_raddr_l1_rs1),
    .rf_raddr_l1_rs2_o(rf_raddr_l1_rs2),
    .id1_valid0_o     (id1_valid0),
    .id1_pc0_o        (id1_pc0),
    .id1_inst0_o      (id1_inst0),
    .id1_type0_o      (id1_type0),
    .id1_rd0_o        (id1_rd0),
    .id1_rs1_0_o      (id1_rs1_0),
    .id1_rs2_0_o      (id1_rs2_0),
    .id1_imm0_o       (id1_imm0),
    .id1_alu_op0_o    (id1_alu_op0),
    .id1_mem_op0_o    (id1_mem_op0),
    .id1_valid1_o     (id1_valid1),
    .id1_pc1_o        (id1_pc1),
    .id1_inst1_o      (id1_inst1),
    .id1_type1_o      (id1_type1),
    .id1_rd1_o        (id1_rd1),
    .id1_rs1_1_o      (id1_rs1_1),
    .id1_rs2_1_o      (id1_rs2_1),
    .id1_imm1_o       (id1_imm1),
    .id1_alu_op1_o    (id1_alu_op1),
    .id1_mem_op1_o    (id1_mem_op1)
  );

  // --------------------------------------------------------------------------
  // Register File (GPR) - Multi-Port RAM
  // --------------------------------------------------------------------------
  sukuna_regfile #(
    .XLEN(XLEN)
  ) u_regfile (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .raddr_s0_rs1_i (rf_raddr_l0_rs1),
    .rdata_s0_rs1_o (rf_rdata_l0_rs1),
    .raddr_s0_rs2_i (rf_raddr_l0_rs2),
    .rdata_s0_rs2_o (rf_rdata_l0_rs2),
    .raddr_s1_rs1_i (rf_raddr_l1_rs1),
    .rdata_s1_rs1_o (rf_rdata_l1_rs1),
    .raddr_s1_rs2_i (rf_raddr_l1_rs2),
    .rdata_s1_rs2_o (rf_rdata_l1_rs2),
    .wen_p0_i       (rf_wen_p0),
    .waddr_p0_i     (rf_waddr_p0),
    .wdata_p0_i     (rf_wdata_p0),
    .wen_p1_i       (rf_wen_p1),
    .waddr_p1_i     (rf_waddr_p1),
    .wdata_p1_i     (rf_wdata_p1),
    .wen_p2_i       (rf_wen_p2),
    .waddr_p2_i     (rf_waddr_p2),
    .wdata_p2_i     (rf_wdata_p2)
  );

  // --------------------------------------------------------------------------
  // Stage 4: ID2
  // --------------------------------------------------------------------------
  sukuna_stage_id2 #(
    .XLEN(XLEN)
  ) u_id2 (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .stall_i        (stall_id2),
    .flush_i        (flush_id2),
    .ma_eu_busy_i   (ex_stall),
    .id1_valid0_i   (id1_valid0),
    .id1_pc0_i      (id1_pc0),
    .id1_inst0_i    (id1_inst0),
    .id1_type0_i    (id1_type0),
    .id1_rd0_i      (id1_rd0),
    .id1_rs1_0_i    (id1_rs1_0),
    .id1_rs2_0_i    (id1_rs2_0),
    .id1_imm0_i     (id1_imm0),
    .id1_alu_op0_i  (id1_alu_op0),
    .id1_mem_op0_i  (id1_mem_op0),
    .id1_valid1_i   (id1_valid1),
    .id1_pc1_i      (id1_pc1),
    .id1_inst1_i    (id1_inst1),
    .id1_type1_i    (id1_type1),
    .id1_rd1_i      (id1_rd1),
    .id1_rs1_1_i    (id1_rs1_1),
    .id1_rs2_1_i    (id1_rs2_1),
    .id1_imm1_i     (id1_imm1),
    .id1_alu_op1_i  (id1_alu_op1),
    .id1_mem_op1_i  (id1_mem_op1),
    .consume_step_o (fetch_step),
    .id2_valid0_o   (id2_valid0),
    .id2_pc0_o      (id2_pc0),
    .id2_rd0_o      (id2_rd0),
    .id2_rs1_0_o    (id2_rs1_0),
    .id2_rs2_0_o    (id2_rs2_0),
    .id2_imm0_o     (id2_imm0),
    .id2_alu_op0_o  (id2_alu_op0),
    .id2_mem_op0_o  (id2_mem_op0),
    .id2_valid1_o   (id2_valid1),
    .id2_pc1_o      (id2_pc1),
    .id2_rd1_o      (id2_rd1),
    .id2_rs1_1_o    (id2_rs1_1),
    .id2_rs2_1_o    (id2_rs2_1),
    .id2_imm1_o     (id2_imm1),
    .id2_alu_op1_o  (id2_alu_op1),
    .id2_mem_op1_o  (id2_mem_op1),
    .id2_int_en_l0_o(id2_int_en_l0),
    .id2_int_en_l1_o(id2_int_en_l1),
    .id2_ma_en_l0_o (id2_ma_en_l0),
    .id2_ma_en_l1_o (id2_ma_en_l1)
  );

  // --------------------------------------------------------------------------
  // Stage 5: ID3
  // --------------------------------------------------------------------------
  sukuna_stage_id3 #(
    .XLEN(XLEN)
  ) u_id3 (
    .clk_i            (clk_i),
    .rst_ni           (rst_ni),
    .stall_i          (stall_id3),
    .flush_i          (flush_id3),
    .id2_valid0_i     (id2_valid0),
    .id2_pc0_i        (id2_pc0),
    .id2_rd0_i        (id2_rd0),
    .id2_rs1_0_i      (id2_rs1_0),
    .id2_rs2_0_i      (id2_rs2_0),
    .id2_imm0_i       (id2_imm0),
    .id2_alu_op0_i    (id2_alu_op0),
    .id2_mem_op0_i    (id2_mem_op0),
    .id2_valid1_i     (id2_valid1),
    .id2_pc1_i        (id2_pc1),
    .id2_rd1_i        (id2_rd1),
    .id2_rs1_1_i      (id2_rs1_1),
    .id2_rs2_1_i      (id2_rs2_1),
    .id2_imm1_i       (id2_imm1),
    .id2_alu_op1_i    (id2_alu_op1),
    .id2_mem_op1_i    (id2_mem_op1),
    .id2_int_en_l0_i  (id2_int_en_l0),
    .id2_int_en_l1_i  (id2_int_en_l1),
    .id2_ma_en_l0_i   (id2_ma_en_l0),
    .id2_ma_en_l1_i   (id2_ma_en_l1),
    .rf_rdata_l0_rs1_i(rf_rdata_l0_rs1),
    .rf_rdata_l0_rs2_i(rf_rdata_l0_rs2),
    .rf_rdata_l1_rs1_i(rf_rdata_l1_rs1),
    .rf_rdata_l1_rs2_i(rf_rdata_l1_rs2),
    .fwd_ex_val_i     (ex_wb_l0_valid),
    .fwd_ex_rd_i      (ex_wb_l0_rd),
    .fwd_ex_data_i    (ex_wb_l0_data),
    .fwd_wb_l0_val_i  (rf_wen_p0),
    .fwd_wb_l0_rd_i   (rf_waddr_p0),
    .fwd_wb_l0_data_i (rf_wdata_p0),
    .ex_l0_valid_o    (ex_l0_valid),
    .ex_l0_pc_o       (ex_l0_pc),
    .ex_l0_rd_o       (ex_l0_rd),
    .ex_l0_src1_o     (ex_l0_src1),
    .ex_l0_src2_o     (ex_l0_src2),
    .ex_l0_imm_o      (ex_l0_imm),
    .ex_l0_alu_op_o   (ex_l0_alu_op),
    .ex_l0_mem_op_o   (ex_l0_mem_op),
    .ex_l1_valid_o    (ex_l1_valid),
    .ex_l1_pc_o       (ex_l1_pc),
    .ex_l1_rd_o       (ex_l1_rd),
    .ex_l1_src1_o     (ex_l1_src1),
    .ex_l1_src2_o     (ex_l1_src2),
    .ex_l1_imm_o      (ex_l1_imm),
    .ex_l1_alu_op_o   (ex_l1_alu_op),
    .ex_l1_mem_op_o   (ex_l1_mem_op),
    .ex_int_en_l0_o   (ex_int_en_l0),
    .ex_int_en_l1_o   (ex_int_en_l1),
    .ex_ma_en_l0_o    (ex_ma_en_l0),
    .ex_ma_en_l1_o    (ex_ma_en_l1)
  );

  // --------------------------------------------------------------------------
  // Stage 6: EX (Execution Stage Outer Box)
  // --------------------------------------------------------------------------
  sukuna_stage_ex #(
    .XLEN       (XLEN),
    .VADDR_WIDTH(VADDR_WIDTH),
    .PADDR_WIDTH(PADDR_WIDTH)
  ) u_stage_ex (
    .clk_i              (clk_i),
    .rst_ni             (rst_ni),
    .stall_i            (stall_ex),
    .flush_i            (flush_ex),
    .l0_valid_i         (ex_l0_valid),
    .l0_pc_i            (ex_l0_pc),
    .l0_rd_i            (ex_l0_rd),
    .l0_src1_i          (ex_l0_src1),
    .l0_src2_i          (ex_l0_src2),
    .l0_imm_i           (ex_l0_imm),
    .l0_alu_op_i        (ex_l0_alu_op),
    .l0_mem_op_i        (ex_l0_mem_op),
    .l1_valid_i         (ex_l1_valid),
    .l1_pc_i            (ex_l1_pc),
    .l1_rd_i            (ex_l1_rd),
    .l1_src1_i          (ex_l1_src1),
    .l1_src2_i          (ex_l1_src2),
    .l1_imm_i           (ex_l1_imm),
    .l1_alu_op_i        (ex_l1_alu_op),
    .l1_mem_op_i        (ex_l1_mem_op),
    .int_en_l0_i        (ex_int_en_l0),
    .int_en_l1_i        (ex_int_en_l1),
    .ma_en_l0_i         (ex_ma_en_l0),
    .ma_en_l1_i         (ex_ma_en_l1),
    .ex_stall_o         (ex_stall),
    .dtlb_lookup_valid_o(dtlb_lookup_valid_o),
    .dtlb_vaddr_o       (dtlb_vaddr_o),
    .dtlb_hit_i         (dtlb_hit_i),
    .dtlb_paddr_i       (dtlb_paddr_i),
    .dtlb_fault_i       (dtlb_fault_i),
    .l1d_req_valid_o    (l1d_req_valid_o),
    .l1d_req_write_o    (l1d_req_write_o),
    .l1d_req_op_o       (l1d_req_op_o),
    .l1d_paddr_o        (l1d_paddr_o),
    .l1d_wdata_o        (l1d_wdata_o),
    .l1d_req_ready_i    (l1d_req_ready_i),
    .l1d_resp_valid_i   (l1d_resp_valid_i),
    .l1d_rdata_i        (l1d_rdata_i),
    .l1d_miss_stall_i   (l1d_miss_stall_i),
    .ex_wb_l0_valid_o   (ex_wb_l0_valid),
    .ex_wb_l0_rd_o      (ex_wb_l0_rd),
    .ex_wb_l0_data_o    (ex_wb_l0_data),
    .ex_wb_l0_exc_o     (ex_wb_l0_exc),
    .ex_wb_l1_valid_o   (ex_wb_l1_valid),
    .ex_wb_l1_rd_o      (ex_wb_l1_rd),
    .ex_wb_l1_data_o    (ex_wb_l1_data),
    .ex_wb_l1_exc_o     (ex_wb_l1_exc)
  );

  // Shared EU Requests
  assign shared_req_valid_o = 1'b0;
  assign shared_req_type_o  = 2'b00;
  assign shared_req_rd_o    = 5'd0;
  assign shared_req_src1_o  = {XLEN{1'b0}};
  assign shared_req_src2_o  = {XLEN{1'b0}};
  assign shared_req_src3_o  = {XLEN{1'b0}};

  // --------------------------------------------------------------------------
  // Stage 7: WB (Writeback / Commit Stage)
  // --------------------------------------------------------------------------
  sukuna_stage_wb #(
    .XLEN(XLEN)
  ) u_wb (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .l0_valid_i     (ex_wb_l0_valid),
    .l0_rd_i        (ex_wb_l0_rd),
    .l0_data_i      (ex_wb_l0_data),
    .l0_exc_i       (ex_wb_l0_exc),
    .l1_valid_i     (ex_wb_l1_valid),
    .l1_rd_i        (ex_wb_l1_rd),
    .l1_data_i      (ex_wb_l1_data),
    .l1_exc_i       (ex_wb_l1_exc),
    .shared_valid_i (shared_resp_valid_i),
    .shared_rd_i    (shared_resp_rd_i),
    .shared_data_i  (shared_resp_data_i),
    .rf_wen_p0_o    (rf_wen_p0),
    .rf_waddr_p0_o  (rf_waddr_p0),
    .rf_wdata_p0_o  (rf_wdata_p0),
    .rf_wen_p1_o    (rf_wen_p1),
    .rf_waddr_p1_o  (rf_waddr_p1),
    .rf_wdata_p1_o  (rf_wdata_p1),
    .rf_wen_p2_o    (rf_wen_p2),
    .rf_waddr_p2_o  (rf_waddr_p2),
    .rf_wdata_p2_o  (rf_wdata_p2),
    .trap_valid_o   (trap_valid),
    .trap_cause_o   (trap_cause)
  );

  // --------------------------------------------------------------------------
  // Pipeline Hazard Unit
  // --------------------------------------------------------------------------
  sukuna_hazard_unit u_hazard (
    .clk_i              (clk_i),
    .rst_ni             (rst_ni),
    .ex_stall_i         (ex_stall),
    .l1i_miss_i         (l1i_miss_i),
    .shared_eu_stall_i  (shared_stall_i),
    .ex_is_load_i       (ex_ma_en_l0 || ex_ma_en_l1),
    .ex_load_rd_i       (ex_ma_en_l0 ? ex_l0_rd : ex_l1_rd),
    .id1_rs1_l0_i       (id1_rs1_0),
    .id1_rs2_l0_i       (id1_rs2_0),
    .id1_rs1_l1_i       (id1_rs1_1),
    .id1_rs2_l1_i       (id1_rs2_1),
    .branch_mispredict_i(1'b0),
    .trap_flush_i       (trap_flush),
    .stall_if1_o        (stall_if1),
    .stall_if2_o        (stall_if2),
    .stall_id1_o        (stall_id1),
    .stall_id2_o        (stall_id2),
    .stall_id3_o        (stall_id3),
    .stall_ex_o         (stall_ex),
    .flush_if1_o        (flush_if1),
    .flush_if2_o        (flush_if2),
    .flush_id1_o        (flush_id1),
    .flush_id2_o        (flush_id2),
    .flush_id3_o        (flush_id3),
    .flush_ex_o         (flush_ex)
  );

  // --------------------------------------------------------------------------
  // CSR & Trap Unit
  // --------------------------------------------------------------------------
  sukuna_csr_unit #(
    .HART_ID(HART_ID),
    .XLEN   (XLEN)
  ) u_csr (
    .clk_i            (clk_i),
    .rst_ni           (rst_ni),
    .csr_req_valid_i  (1'b0),
    .csr_addr_i       (12'd0),
    .csr_op_i         (2'b00),
    .csr_wdata_i      ({XLEN{1'b0}}),
    .csr_rdata_o      (),
    .meip_i           (meip_i),
    .seip_i           (seip_i),
    .mtip_i           (mtip_i),
    .msip_i           (msip_i),
    .exception_valid_i(trap_valid),
    .exception_cause_i(trap_cause),
    .exception_pc_i   (ex_l0_pc),
    .mret_valid_i     (1'b0),
    .sret_valid_i     (1'b0),
    .trap_flush_o     (trap_flush),
    .trap_target_pc_o (trap_target_pc),
    .satp_o           (satp_o),
    .priv_mode_o      ()
  );

endmodule
