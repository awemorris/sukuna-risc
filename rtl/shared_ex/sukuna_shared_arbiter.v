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

  // Stub round-robin / priority dispatch logic
  assign stall_thread_o = {NUM_HARTS{1'b0}};

  assign fp_valid_o    = 1'b0;
  assign fp_hart_id_o  = 2'b00;
  assign fp_rd_o       = 5'd0;
  assign fp_src1_o     = {XLEN{1'b0}};
  assign fp_src2_o     = {XLEN{1'b0}};

  assign fma_valid_o   = 1'b0;
  assign fma_hart_id_o = 2'b00;
  assign fma_rd_o      = 5'd0;
  assign fma_src1_o    = {XLEN{1'b0}};
  assign fma_src2_o    = {XLEN{1'b0}};
  assign fma_src3_o    = {XLEN{1'b0}};

  assign cfp_valid_o   = 1'b0;
  assign cfp_hart_id_o = 2'b00;
  assign cfp_rd_o      = 5'd0;
  assign cfp_src1_o    = {XLEN{1'b0}};
  assign cfp_src2_o    = {XLEN{1'b0}};

  assign simd_valid_o   = 1'b0;
  assign simd_hart_id_o = 2'b00;
  assign simd_rd_o      = 5'd0;
  assign simd_src1_o    = {XLEN{1'b0}};
  assign simd_src2_o    = {XLEN{1'b0}};

endmodule
