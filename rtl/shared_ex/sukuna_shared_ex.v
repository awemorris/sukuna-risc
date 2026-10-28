// ============================================================================
// Shared Execution Units Subsystem (Verilog 2005)
// Combines Arbiter, FP-EU1, FMA-EU1, CFP-EU1, and SIMD-EU1
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_shared_ex #(
  parameter NUM_HARTS = `NUM_HARTS,
  parameter XLEN      = `XLEN
)(
  input  wire                         clk_i,
  input  wire                         rst_ni,

  // Request Interface from 3 Harts (Slot 1)
  input  wire [NUM_HARTS-1:0]         req_valid_i,
  input  wire [NUM_HARTS*2-1:0]       req_type_i,
  input  wire [NUM_HARTS*5-1:0]       req_rd_i,
  input  wire [NUM_HARTS*XLEN-1:0]    req_src1_i,
  input  wire [NUM_HARTS*XLEN-1:0]    req_src2_i,
  input  wire [NUM_HARTS*XLEN-1:0]    req_src3_i,

  // Stall notification back to Harts
  output wire [NUM_HARTS-1:0]         stall_thread_o,

  // Result return to Harts' Writeback stages
  output wire                         resp_valid_o,
  output wire [1:0]                   resp_hart_id_o,
  output wire [4:0]                   resp_rd_o,
  output wire [XLEN-1:0]              resp_data_o
);

  // Arbiter to EUs
  wire fp_valid, fma_valid, cfp_valid, simd_valid;
  wire [1:0] fp_hart_id, fma_hart_id, cfp_hart_id, simd_hart_id;
  wire [4:0] fp_rd, fma_rd, cfp_rd, simd_rd;
  wire [XLEN-1:0] fp_src1, fp_src2;
  wire [XLEN-1:0] fma_src1, fma_src2, fma_src3;
  wire [XLEN-1:0] cfp_src1, cfp_src2;
  wire [XLEN-1:0] simd_src1, simd_src2;
  wire fp_busy, fma_busy, cfp_busy, simd_busy;

  // EU outputs
  wire fp_resp_valid, fma_resp_valid, cfp_resp_valid, simd_resp_valid;
  wire [1:0] fp_resp_hart_id, fma_resp_hart_id, cfp_resp_hart_id, simd_resp_hart_id;
  wire [4:0] fp_resp_rd, fma_resp_rd, cfp_resp_rd, simd_resp_rd;
  wire [XLEN-1:0] fp_resp_data, fma_resp_data, cfp_resp_data, simd_resp_data;

  sukuna_shared_arbiter #(
    .NUM_HARTS(NUM_HARTS),
    .XLEN     (XLEN)
  ) u_arbiter (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .req_valid_i    (req_valid_i),
    .req_type_i     (req_type_i),
    .req_rd_i       (req_rd_i),
    .req_src1_i     (req_src1_i),
    .req_src2_i     (req_src2_i),
    .req_src3_i     (req_src3_i),
    .stall_thread_o (stall_thread_o),

    .fp_valid_o     (fp_valid),
    .fp_hart_id_o   (fp_hart_id),
    .fp_rd_o        (fp_rd),
    .fp_src1_o      (fp_src1),
    .fp_src2_o      (fp_src2),
    .fp_busy_i      (fp_busy),

    .fma_valid_o    (fma_valid),
    .fma_hart_id_o  (fma_hart_id),
    .fma_rd_o       (fma_rd),
    .fma_src1_o     (fma_src1),
    .fma_src2_o     (fma_src2),
    .fma_src3_o     (fma_src3),
    .fma_busy_i     (fma_busy),

    .cfp_valid_o    (cfp_valid),
    .cfp_hart_id_o  (cfp_hart_id),
    .cfp_rd_o       (cfp_rd),
    .cfp_src1_o     (cfp_src1),
    .cfp_src2_o     (cfp_src2),
    .cfp_busy_i     (cfp_busy),

    .simd_valid_o   (simd_valid),
    .simd_hart_id_o (simd_hart_id),
    .simd_rd_o      (simd_rd),
    .simd_src1_o    (simd_src1),
    .simd_src2_o    (simd_src2),
    .simd_busy_i    (simd_busy)
  );

  sukuna_fp_eu #(.XLEN(XLEN)) u_fp_eu (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .req_valid_i    (fp_valid),
    .req_hart_id_i  (fp_hart_id),
    .req_rd_i       (fp_rd),
    .req_src1_i     (fp_src1),
    .req_src2_i     (fp_src2),
    .busy_o         (fp_busy),
    .resp_valid_o   (fp_resp_valid),
    .resp_hart_id_o (fp_resp_hart_id),
    .resp_rd_o      (fp_resp_rd),
    .resp_data_o    (fp_resp_data)
  );

  sukuna_fma_eu #(.XLEN(XLEN)) u_fma_eu (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .req_valid_i    (fma_valid),
    .req_hart_id_i  (fma_hart_id),
    .req_rd_i       (fma_rd),
    .req_src1_i     (fma_src1),
    .req_src2_i     (fma_src2),
    .req_src3_i     (fma_src3),
    .busy_o         (fma_busy),
    .resp_valid_o   (fma_resp_valid),
    .resp_hart_id_o (fma_resp_hart_id),
    .resp_rd_o      (fma_resp_rd),
    .resp_data_o    (fma_resp_data)
  );

  sukuna_cfp_eu #(.XLEN(XLEN)) u_cfp_eu (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .req_valid_i    (cfp_valid),
    .req_hart_id_i  (cfp_hart_id),
    .req_rd_i       (cfp_rd),
    .req_src1_i     (cfp_src1),
    .req_src2_i     (cfp_src2),
    .busy_o         (cfp_busy),
    .resp_valid_o   (cfp_resp_valid),
    .resp_hart_id_o (cfp_resp_hart_id),
    .resp_rd_o      (cfp_resp_rd),
    .resp_data_o    (cfp_resp_data)
  );

  sukuna_simd_eu #(.XLEN(XLEN)) u_simd_eu (
    .clk_i                (clk_i),
    .rst_ni               (rst_ni),
    .req_valid_i          (simd_valid),
    .req_hart_id_i        (simd_hart_id),
    .req_rd_i             (simd_rd),
    .req_src1_i           (simd_src1),
    .req_src2_i           (simd_src2),
    .busy_o               (simd_busy),
    .scalar_resp_valid_o  (simd_resp_valid),
    .scalar_resp_hart_id_o(simd_resp_hart_id),
    .scalar_resp_rd_o     (simd_resp_rd),
    .scalar_resp_data_o   (simd_resp_data)
  );

  // Multiplex result back to writeback
  assign resp_valid_o   = fp_resp_valid | fma_resp_valid | cfp_resp_valid | simd_resp_valid;
  assign resp_hart_id_o = fp_resp_valid  ? fp_resp_hart_id  :
                          fma_resp_valid ? fma_resp_hart_id :
                          cfp_resp_valid ? cfp_resp_hart_id : simd_resp_hart_id;
  assign resp_rd_o      = fp_resp_valid  ? fp_resp_rd       :
                          fma_resp_valid ? fma_resp_rd      :
                          cfp_resp_valid ? cfp_resp_rd      : simd_resp_rd;
  assign resp_data_o    = fp_resp_valid  ? fp_resp_data     :
                          fma_resp_valid ? fma_resp_data    :
                          cfp_resp_valid ? cfp_resp_data    : simd_resp_data;

endmodule
