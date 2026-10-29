// ============================================================================
// Shared Execution Units Arbiter (Verilog 2005)
// Arbitrates FP and SIMD issue requests among Hart 0, Hart 1, Hart 2
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_shared_arbiter #(
  parameter NUM_HARTS = `NUM_HARTS,
  parameter XLEN      = `XLEN
)(
  input  wire                   clk_i,
  input  wire                   rst_ni,

  // Requests from 3 Harts
  input  wire [NUM_HARTS-1:0]   req_valid_i,
  input  wire [NUM_HARTS*2-1:0] req_type_i,      // 0: FP, 1: FMA, 2: CFP, 3: SIMD
  input  wire [NUM_HARTS*5-1:0] req_rd_i,
  input  wire [NUM_HARTS*XLEN-1:0] req_src1_i,
  input  wire [NUM_HARTS*XLEN-1:0] req_src2_i,
  input  wire [NUM_HARTS*XLEN-1:0] req_src3_i,

  // Stall backpressure to Harts
  output wire [NUM_HARTS-1:0]   stall_thread_o,

  // Dispatched output to Execution Units
  output wire                   fp_valid_o,
  output wire [1:0]             fp_hart_id_o,
  output wire [4:0]             fp_rd_o,
  output wire [XLEN-1:0]        fp_src1_o,
  output wire [XLEN-1:0]        fp_src2_o,
  input  wire                   fp_busy_i,

  output wire                   fma_valid_o,
  output wire [1:0]             fma_hart_id_o,
  output wire [4:0]             fma_rd_o,
  output wire [XLEN-1:0]        fma_src1_o,
  output wire [XLEN-1:0]        fma_src2_o,
  output wire [XLEN-1:0]        fma_src3_o,
  input  wire                   fma_busy_i,

  output wire                   cfp_valid_o,
  output wire [1:0]             cfp_hart_id_o,
  output wire [4:0]             cfp_rd_o,
  output wire [XLEN-1:0]        cfp_src1_o,
  output wire [XLEN-1:0]        cfp_src2_o,
  input  wire                   cfp_busy_i,

  output wire                   simd_valid_o,
  output wire [1:0]             simd_hart_id_o,
  output wire [4:0]             simd_rd_o,
  output wire [XLEN-1:0]        simd_src1_o,
  output wire [XLEN-1:0]        simd_src2_o,
  input  wire                   simd_busy_i
);

  // --------------------------------------------------------------------------
  // Priority Arbitration: Hart 0 > Hart 1 > Hart 2
  // --------------------------------------------------------------------------
  wire [NUM_HARTS-1:0] fp_req   = { (req_valid_i[2] && (req_type_i[5:4] == 2'd0)),
                                    (req_valid_i[1] && (req_type_i[3:2] == 2'd0)),
                                    (req_valid_i[0] && (req_type_i[1:0] == 2'd0)) };
  wire [NUM_HARTS-1:0] fma_req  = { (req_valid_i[2] && (req_type_i[5:4] == 2'd1)),
                                    (req_valid_i[1] && (req_type_i[3:2] == 2'd1)),
                                    (req_valid_i[0] && (req_type_i[1:0] == 2'd1)) };
  wire [NUM_HARTS-1:0] cfp_req  = { (req_valid_i[2] && (req_type_i[5:4] == 2'd2)),
                                    (req_valid_i[1] && (req_type_i[3:2] == 2'd2)),
                                    (req_valid_i[0] && (req_type_i[1:0] == 2'd2)) };
  wire [NUM_HARTS-1:0] simd_req = { (req_valid_i[2] && (req_type_i[5:4] == 2'd3)),
                                    (req_valid_i[1] && (req_type_i[3:2] == 2'd3)),
                                    (req_valid_i[0] && (req_type_i[1:0] == 2'd3)) };

  wire [NUM_HARTS-1:0] fp_gnt;
  assign fp_gnt[0] = fp_req[0] && !fp_busy_i;
  assign fp_gnt[1] = fp_req[1] && !fp_busy_i && !fp_req[0];
  assign fp_gnt[2] = fp_req[2] && !fp_busy_i && !fp_req[0] && !fp_req[1];

  wire [NUM_HARTS-1:0] fma_gnt;
  assign fma_gnt[0] = fma_req[0] && !fma_busy_i;
  assign fma_gnt[1] = fma_req[1] && !fma_busy_i && !fma_req[0];
  assign fma_gnt[2] = fma_req[2] && !fma_busy_i && !fma_req[0] && !fma_req[1];

  wire [NUM_HARTS-1:0] cfp_gnt;
  assign cfp_gnt[0] = cfp_req[0] && !cfp_busy_i;
  assign cfp_gnt[1] = cfp_req[1] && !cfp_busy_i && !cfp_req[0];
  assign cfp_gnt[2] = cfp_req[2] && !cfp_busy_i && !cfp_req[0] && !cfp_req[1];

  wire [NUM_HARTS-1:0] simd_gnt;
  assign simd_gnt[0] = simd_req[0] && !simd_busy_i;
  assign simd_gnt[1] = simd_req[1] && !simd_busy_i && !simd_req[0];
  assign simd_gnt[2] = simd_req[2] && !simd_busy_i && !simd_req[0] && !simd_req[1];

  wire [NUM_HARTS-1:0] any_gnt = fp_gnt | fma_gnt | cfp_gnt | simd_gnt;
  assign stall_thread_o = req_valid_i & ~any_gnt;

  // Multiplexing
  wire [1:0] fp_sel   = fp_gnt[0] ? 2'd0 : fp_gnt[1] ? 2'd1 : 2'd2;
  wire [1:0] fma_sel  = fma_gnt[0] ? 2'd0 : fma_gnt[1] ? 2'd1 : 2'd2;
  wire [1:0] cfp_sel  = cfp_gnt[0] ? 2'd0 : cfp_gnt[1] ? 2'd1 : 2'd2;
  wire [1:0] simd_sel = simd_gnt[0] ? 2'd0 : simd_gnt[1] ? 2'd1 : 2'd2;

  assign fp_valid_o   = |fp_gnt;
  assign fp_hart_id_o = fp_sel;
  assign fp_rd_o      = (fp_sel == 2'd0) ? req_rd_i[4:0] :
                        (fp_sel == 2'd1) ? req_rd_i[9:5] : req_rd_i[14:10];
  assign fp_src1_o    = (fp_sel == 2'd0) ? req_src1_i[XLEN-1:0] :
                        (fp_sel == 2'd1) ? req_src1_i[2*XLEN-1:XLEN] : req_src1_i[3*XLEN-1:2*XLEN];
  assign fp_src2_o    = (fp_sel == 2'd0) ? req_src2_i[XLEN-1:0] :
                        (fp_sel == 2'd1) ? req_src2_i[2*XLEN-1:XLEN] : req_src2_i[3*XLEN-1:2*XLEN];

  assign fma_valid_o   = |fma_gnt;
  assign fma_hart_id_o = fma_sel;
  assign fma_rd_o      = (fma_sel == 2'd0) ? req_rd_i[4:0] :
                         (fma_sel == 2'd1) ? req_rd_i[9:5] : req_rd_i[14:10];
  assign fma_src1_o    = (fma_sel == 2'd0) ? req_src1_i[XLEN-1:0] :
                         (fma_sel == 2'd1) ? req_src1_i[2*XLEN-1:XLEN] : req_src1_i[3*XLEN-1:2*XLEN];
  assign fma_src2_o    = (fma_sel == 2'd0) ? req_src2_i[XLEN-1:0] :
                         (fma_sel == 2'd1) ? req_src2_i[2*XLEN-1:XLEN] : req_src2_i[3*XLEN-1:2*XLEN];
  assign fma_src3_o    = (fma_sel == 2'd0) ? req_src3_i[XLEN-1:0] :
                         (fma_sel == 2'd1) ? req_src3_i[2*XLEN-1:XLEN] : req_src3_i[3*XLEN-1:2*XLEN];

  assign cfp_valid_o   = |cfp_gnt;
  assign cfp_hart_id_o = cfp_sel;
  assign cfp_rd_o      = (cfp_sel == 2'd0) ? req_rd_i[4:0] :
                         (cfp_sel == 2'd1) ? req_rd_i[9:5] : req_rd_i[14:10];
  assign cfp_src1_o    = (cfp_sel == 2'd0) ? req_src1_i[XLEN-1:0] :
                         (cfp_sel == 2'd1) ? req_src1_i[2*XLEN-1:XLEN] : req_src1_i[3*XLEN-1:2*XLEN];
  assign cfp_src2_o    = (cfp_sel == 2'd0) ? req_src2_i[XLEN-1:0] :
                         (cfp_sel == 2'd1) ? req_src2_i[2*XLEN-1:XLEN] : req_src2_i[3*XLEN-1:2*XLEN];

  assign simd_valid_o   = |simd_gnt;
  assign simd_hart_id_o = simd_sel;
  assign simd_rd_o      = (simd_sel == 2'd0) ? req_rd_i[4:0] :
                          (simd_sel == 2'd1) ? req_rd_i[9:5] : req_rd_i[14:10];
  assign simd_src1_o    = (simd_sel == 2'd0) ? req_src1_i[XLEN-1:0] :
                          (simd_sel == 2'd1) ? req_src1_i[2*XLEN-1:XLEN] : req_src1_i[3*XLEN-1:2*XLEN];
  assign simd_src2_o    = (simd_sel == 2'd0) ? req_src2_i[XLEN-1:0] :
                          (simd_sel == 2'd1) ? req_src2_i[2*XLEN-1:XLEN] : req_src2_i[3*XLEN-1:2*XLEN];

endmodule
