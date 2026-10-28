// ============================================================================
// Pipeline Stage: EX (Execution Stage Outer Box) (Verilog 2005)
// Complies with design-rule.md
// ============================================================================
// Responsibilities:
//   - Receives dual-lane buses (Lane 0: older, Lane 1: younger)
//   - Routes to INT-EU and MA-EU based on 1-bit enable bits (int_en_l0/l1, ma_en_l0/l1)
//   - Instantiates dedicated INT-EU (1/multi-cycle with sk_mul) and MA-EU (2-cycle)
//   - Generates unified branch condition evaluation and target address calculation
//   - Emits ex_stall_o to Hazard Unit on memory stalls or multicycle ALU execution
//   - Routes results to Lane 0 and Lane 1 for WB stage
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_stage_ex #(
  parameter XLEN        = `XLEN,
  parameter VADDR_WIDTH = `VADDR_WIDTH,
  parameter PADDR_WIDTH = `PADDR_WIDTH,
  parameter MUL_LAT     = 2
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
  input  wire [3:0]             l0_alu_op_i,
  input  wire [2:0]             l0_mem_op_i,

  // Lane 1 Bus from ID3 (younger)
  input  wire                   l1_valid_i,
  input  wire [XLEN-1:0]        l1_pc_i,
  input  wire [4:0]             l1_rd_i,
  input  wire [XLEN-1:0]        l1_src1_i,
  input  wire [XLEN-1:0]        l1_src2_i,
  input  wire [XLEN-1:0]        l1_imm_i,
  input  wire [3:0]             l1_alu_op_i,
  input  wire [2:0]             l1_mem_op_i,

  // Enable Bits
  input  wire                   int_en_l0_i,
  input  wire                   int_en_l1_i,
  input  wire                   ma_en_l0_i,
  input  wire                   ma_en_l1_i,

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
  output wire [2:0]             l1d_req_op_o,
  output wire [7:0]             l1d_req_byte_en_o,
  output wire [PADDR_WIDTH-1:2] l1d_paddr_w_o,
  output wire [XLEN-1:0]        l1d_wdata_o,
  input  wire                   l1d_req_ready_i,
  input  wire                   l1d_resp_valid_i,
  input  wire [XLEN-1:0]        l1d_rdata_i,
  input  wire                   l1d_miss_stall_i,

  // Output to WB Stage
  output wire                   ex_wb_l0_valid_o,
  output wire [4:0]             ex_wb_l0_rd_o,
  output wire [XLEN-1:0]        ex_wb_l0_data_o,
  output wire                   ex_wb_l0_exc_o,

  output wire                   ex_wb_l1_valid_o,
  output wire [4:0]             ex_wb_l1_rd_o,
  output wire [XLEN-1:0]        ex_wb_l1_data_o,
  output wire                   ex_wb_l1_exc_o
);

  // --------------------------------------------------------------------------
  // INT-EU Selection
  // --------------------------------------------------------------------------
  wire int_valid = (int_en_l0_i && l0_valid_i) || (int_en_l1_i && l1_valid_i);
  wire [3:0]      int_alu_op = int_en_l0_i ? l0_alu_op_i : l1_alu_op_i;
  wire [XLEN-1:0] int_src1   = int_en_l0_i ? l0_src1_i   : l1_src1_i;
  wire [XLEN-1:0] int_src2   = int_en_l0_i ? l0_src2_i   : l1_src2_i;
  wire [4:0]      int_rd     = int_en_l0_i ? l0_rd_i     : l1_rd_i;

  wire int_busy;
  wire int_out_valid;
  wire [4:0] int_out_rd;
  wire [XLEN-1:0] int_out_result;
  wire cmp_eq;
  wire cmp_lt;
  wire cmp_ltu;

  sukuna_int_eu #(
    .XLEN   (XLEN),
    .MUL_LAT(MUL_LAT)
  ) u_int_eu (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .valid_i  (int_valid && !stall_i),
    .alu_op_i (int_alu_op),
    .src1_i   (int_src1),
    .src2_i   (int_src2),
    .rd_i     (int_rd),
    .busy_o   (int_busy),
    .valid_o  (int_out_valid),
    .rd_o     (int_out_rd),
    .result_o (int_out_result),
    .cmp_eq_o (cmp_eq),
    .cmp_lt_o (cmp_lt),
    .cmp_ltu_o(cmp_ltu)
  );

  // --------------------------------------------------------------------------
  // Branch Calculation & Target Generation (Shared Adder)
  // --------------------------------------------------------------------------
  wire [XLEN-1:0] branch_base_pc = int_en_l0_i ? l0_pc_i : l1_pc_i;
  wire [XLEN-1:0] branch_imm     = int_en_l0_i ? l0_imm_i : l1_imm_i;
  wire [XLEN-1:0] calc_target_pc;

  sk_add #(
    .WIDTH   (XLEN),
    .PIPELINE(0),
    .IMPL    ("CARRY")
  ) u_branch_adder (
    .clk_i   (clk_i),
    .rst_ni  (rst_ni),
    .cin_i   (1'b0),
    .a_i     (branch_base_pc),
    .b_i     (branch_imm),
    .sum_o   (calc_target_pc),
    .cout_o  ()
  );

  assign branch_target_o     = calc_target_pc;
  assign branch_mispredict_o = 1'b0; // Default off until branch prediction integration

  // --------------------------------------------------------------------------
  // MA-EU Selection
  // --------------------------------------------------------------------------
  wire ma_valid = (ma_en_l0_i && l0_valid_i) || (ma_en_l1_i && l1_valid_i);
  wire [2:0]      ma_op     = ma_en_l0_i ? l0_mem_op_i : l1_mem_op_i;
  wire [4:0]      ma_rd     = ma_en_l0_i ? l0_rd_i     : l1_rd_i;
  wire [XLEN-1:0] ma_base   = ma_en_l0_i ? l0_src1_i   : l1_src1_i;
  wire [XLEN-1:0] ma_offset = ma_en_l0_i ? l0_imm_i    : l1_imm_i;
  wire [XLEN-1:0] ma_wdata  = ma_en_l0_i ? l0_src2_i   : l1_src2_i;

  wire ma_busy;
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
    .req_valid_i        (ma_valid && !stall_i),
    .req_op_i           (ma_op),
    .req_rd_i           (ma_rd),
    .req_base_i         (ma_base),
    .req_offset_i       (ma_offset),
    .req_wdata_i        (ma_wdata),
    .busy_o             (ma_busy),
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
  assign ex_stall_o = ma_busy || int_busy;

  // Track which EU served which Lane
  reg int_was_l0_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg ma_was_l0_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      int_was_l0_q <= 1'b0;
      ma_was_l0_q  <= 1'b0;
    end else if (!stall_i) begin
      int_was_l0_q <= int_en_l0_i;
      ma_was_l0_q  <= ma_en_l0_i;
    end
  end

  // Route results back to Lane 0 and Lane 1
  assign ex_wb_l0_valid_o = int_was_l0_q ? int_out_valid : ma_out_valid;
  assign ex_wb_l0_rd_o    = int_was_l0_q ? int_out_rd    : ma_out_rd;
  assign ex_wb_l0_data_o  = int_was_l0_q ? int_out_result: ma_out_rdata;
  assign ex_wb_l0_exc_o   = (!int_was_l0_q && dtlb_fault_i); // Page Fault on Lane 0 MA

  assign ex_wb_l1_valid_o = (!int_was_l0_q) ? int_out_valid : ma_out_valid;
  assign ex_wb_l1_rd_o    = (!int_was_l0_q) ? int_out_rd    : ma_out_rd;
  assign ex_wb_l1_data_o  = (!int_was_l0_q) ? int_out_result: ma_out_rdata;
  assign ex_wb_l1_exc_o   = (int_was_l0_q && dtlb_fault_i);

endmodule
