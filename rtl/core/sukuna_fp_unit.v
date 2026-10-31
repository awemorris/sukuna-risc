`timescale 1ns / 1ps
`default_nettype none

// ============================================================================
// Sukuna-RISC: Pipelined Floating-Point Execution Unit (Verilog 2005)
// Complies with style.md and IEEE-754
// ============================================================================
// Features:
//   - Unified SP (.S) and DP (.D) internal datapath
//   - Variable-cycle pipelined execution per operation class:
//     * 1-cycle: FMV.X.W/D, FMV.W/D.X, FSGNJ/N/X.S/D, FCLASS.S/D
//     * 2-cycle: FEQ/FLT/FLE.S/D, FMIN/FMAX.S/D, FCVT.S.D, FCVT.D.S
//                (64-bit comparisons split into 32-bit halves across 2 stages)
//     * 3-cycle: FCVT.W/WU/L/LU.S/D, FCVT.S/D.W/WU/L/LU
//                (64-bit 2's complement negations split into 32-bit halves)
//     * 4-cycle: FADD.S/D, FSUB.S/D
//                (56-bit mantissa add/sub split into 28-bit halves across stages)
//     * (MUL_LAT+1)-cycle: FMUL.S/D using configurable-latency sk_mul
//     * Multi-cycle: FDIV.S/D (26 cycles SP / 55 cycles DP iterative restoring)
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_fp_unit #(
  parameter XLEN    = `XLEN,
  parameter MUL_LAT = `FP_MUL_LAT
)(
  input  wire            clk_i,
  input  wire            rst_ni,
  input  wire            flush_i,
  input  wire            stall_i,
  input  wire            valid_i,
  input  wire [6:0]      funct7_i,
  input  wire [2:0]      funct3_i,
  input  wire [4:0]      rs2_field_i,
  input  wire [4:0]      rd_i,
  input  wire [XLEN-1:0] fpr_src1_i,
  input  wire [XLEN-1:0] fpr_src2_i,
  input  wire [XLEN-1:0] gpr_src1_i,

  output wire            busy_o,
  output reg             valid_o,      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [4:0]      rd_o,         /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0] fp_result_o,  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg             writes_fpr_o, /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg             writes_gpr_o  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
);

  // --------------------------------------------------------------------------
  // Operation Decode
  // --------------------------------------------------------------------------
  wire [4:0] op5   = funct7_i[6:2];
  wire       is_sp = (funct7_i[1:0] == 2'b00); // 00: .S, 01: .D

  wire is_fmv_fclass = (op5 == 5'b11100);
  wire is_fmv_w_x    = (op5 == 5'b11110);
  wire is_fsgnj      = (op5 == 5'b00100);
  wire is_1cyc_op    = is_fmv_fclass || is_fmv_w_x || is_fsgnj;

  wire is_fcmp       = (op5 == 5'b10100);
  wire is_fminmax    = (op5 == 5'b00101);
  wire is_fcvt_fp_fp = (op5 == 5'b01000);
  wire is_2cyc_op    = is_fcmp || is_fminmax || is_fcvt_fp_fp;

  wire is_fcvt_f2i   = (op5 == 5'b11000);
  wire is_fcvt_i2f   = (op5 == 5'b11010);
  wire is_3cyc_op    = is_fcvt_f2i || is_fcvt_i2f;

  wire is_fadd       = (op5 == 5'b00000);
  wire is_fsub       = (op5 == 5'b00001);
  wire is_addsub_op  = is_fadd || is_fsub;

  wire is_fmul       = (op5 == 5'b00010);
  wire is_fdiv       = (op5 == 5'b00011);

  wire is_multicyc_op = !is_1cyc_op;

  wire writes_gpr_comb = is_fmv_fclass || is_fcmp || is_fcvt_f2i;
  wire writes_fpr_comb = !writes_gpr_comb;

  // --------------------------------------------------------------------------
  // State & Cycle Counter Control
  // --------------------------------------------------------------------------
  localparam S_IDLE = 1'b0;
  localparam S_BUSY = 1'b1;

  reg       state_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [5:0] cnt_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [2:0] step_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  reg [4:0] op5_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg       is_sp_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [2:0] rm_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [4:0] rd_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg       wfpr_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg       wgpr_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  wire [5:0] mul_Wait_cycles = MUL_LAT[5:0]; // Total FMUL cycles = MUL_LAT + 1

  wire [5:0] init_cnt = is_2cyc_op   ? 6'd1 :
                        is_3cyc_op   ? 6'd2 :
                        is_addsub_op ? 6'd3 :
                        is_fmul      ? mul_Wait_cycles :
                        (is_sp ? 6'd25 : 6'd54);

  assign busy_o = (state_q == S_IDLE) ? (valid_i && is_multicyc_op) : (cnt_q != 6'd1);

  wire start_multicyc = (state_q == S_IDLE) && valid_i && is_multicyc_op && !stall_i;
  wire finish_multicyc = (state_q == S_BUSY) && (cnt_q == 6'd1) && !stall_i;

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= S_IDLE;
      cnt_q   <= 6'd0;
      step_q  <= 3'd0;
      op5_q   <= 5'd0;
      is_sp_q <= 1'b0;
      rm_q    <= 3'd0;
      rd_q    <= 5'd0;
      wfpr_q  <= 1'b0;
      wgpr_q  <= 1'b0;
    end else if (flush_i) begin
      state_q <= S_IDLE;
      cnt_q   <= 6'd0;
      step_q  <= 3'd0;
    end else if (!stall_i) begin
      if (state_q == S_IDLE) begin
        if (valid_i && is_multicyc_op) begin
          state_q <= S_BUSY;
          cnt_q   <= init_cnt;
          step_q  <= 3'd1;
          op5_q   <= op5;
          is_sp_q <= is_sp;
          rm_q    <= funct3_i;
          rd_q    <= rd_i;
          wfpr_q  <= writes_fpr_comb;
          wgpr_q  <= writes_gpr_comb;
        end
      end else begin
        if (cnt_q == 6'd1) begin
          state_q <= S_IDLE;
          cnt_q   <= 6'd0;
          step_q  <= 3'd0;
        end else begin
          cnt_q  <= cnt_q - 6'd1;
          step_q <= (step_q == 3'd7) ? 3'd7 : (step_q + 3'd1);
        end
      end
    end
  end

  // --------------------------------------------------------------------------
  // Common Input Unpacking (SP & DP unified to 53-bit MSB-aligned mantissa)
  // --------------------------------------------------------------------------
  wire [63:0] op_a_dp = fpr_src1_i;
  wire [63:0] op_b_dp = fpr_src2_i;
  wire [31:0] op_a_sp = fpr_src1_i[31:0];
  wire [31:0] op_b_sp = fpr_src2_i[31:0];

  wire        sign_a  = is_sp ? op_a_sp[31] : op_a_dp[63];
  wire        sign_b  = is_sp ? op_b_sp[31] : op_b_dp[63];
  wire [7:0]  exp_a_s = op_a_sp[30:23];
  wire [7:0]  exp_b_s = op_b_sp[30:23];
  wire [10:0] exp_a_d = op_a_dp[62:52];
  wire [10:0] exp_b_d = op_b_dp[62:52];

  wire [10:0] exp_a_u  = is_sp ? {3'b000, exp_a_s} : exp_a_d;
  wire [10:0] exp_b_u  = is_sp ? {3'b000, exp_b_s} : exp_b_d;
  wire [52:0] mant_a_u = is_sp ? {(|exp_a_s), op_a_sp[22:0], 29'd0} : {(|exp_a_d), op_a_dp[51:0]};
  wire [52:0] mant_b_u = is_sp ? {(|exp_b_s), op_b_sp[22:0], 29'd0} : {(|exp_b_d), op_b_dp[51:0]};

  // 32-bit split zero & NaN detection (<= 3 LUT6 levels)
  wire a_hi_zero = (op_a_dp[62:32] == 31'd0);
  wire a_lo_zero = (op_a_dp[31:0]  == 32'd0);
  wire b_hi_zero = (op_b_dp[62:32] == 31'd0);
  wire b_lo_zero = (op_b_dp[31:0]  == 32'd0);
  wire a_sp_zero = (op_a_sp[30:0]  == 31'd0);
  wire b_sp_zero = (op_b_sp[30:0]  == 31'd0);

  wire src_is_sp   = is_fcvt_fp_fp ? !is_sp : is_sp;
  wire a_zero_comb = src_is_sp ? a_sp_zero : (a_hi_zero && a_lo_zero);
  wire b_zero_comb = src_is_sp ? b_sp_zero : (b_hi_zero && b_lo_zero);

  wire a_nan_dp = (&exp_a_d) && ((|op_a_dp[51:32]) || (!a_lo_zero));
  wire b_nan_dp = (&exp_b_d) && ((|op_b_dp[51:32]) || (!b_lo_zero));
  wire a_nan_sp = (&exp_a_s) && (|op_a_sp[22:0]);
  wire b_nan_sp = (&exp_b_s) && (|op_b_sp[22:0]);
  wire a_nan_comb = src_is_sp ? a_nan_sp : a_nan_dp;
  wire b_nan_comb = src_is_sp ? b_nan_sp : b_nan_dp;

  // ==========================================================================
  // 1. 1-Cycle Operations: FMV, FSGNJ, FCLASS
  // ==========================================================================
  wire is_inf_s  = (&exp_a_s) && (op_a_sp[22:0] == 23'd0);
  wire is_snan_s = a_nan_sp && !op_a_sp[22];
  wire is_qnan_s = a_nan_sp && op_a_sp[22];
  wire is_subn_s = (exp_a_s == 8'd0) && (op_a_sp[22:0] != 23'd0);
  wire is_norm_s = (!(&exp_a_s)) && (exp_a_s != 8'd0);
  wire [9:0] fclass_sp = {is_qnan_s, is_snan_s, !op_a_sp[31] && is_inf_s, !op_a_sp[31] && is_norm_s,
                          !op_a_sp[31] && is_subn_s, !op_a_sp[31] && a_sp_zero, op_a_sp[31] && a_sp_zero,
                          op_a_sp[31] && is_subn_s, op_a_sp[31] && is_norm_s, op_a_sp[31] && is_inf_s};

  wire frac_d_zero = (op_a_dp[51:32] == 20'd0) && a_lo_zero;
  wire is_inf_d    = (&exp_a_d) && frac_d_zero;
  wire is_snan_d   = a_nan_dp && !op_a_dp[51];
  wire is_qnan_d   = a_nan_dp && op_a_dp[51];
  wire is_subn_d   = (exp_a_d == 11'd0) && !frac_d_zero;
  wire is_norm_d   = (!(&exp_a_d)) && (exp_a_d != 11'd0);
  wire [9:0] fclass_dp = {is_qnan_d, is_snan_d, !op_a_dp[63] && is_inf_d, !op_a_dp[63] && is_norm_d,
                          !op_a_dp[63] && is_subn_d, !op_a_dp[63] && (a_hi_zero && a_lo_zero),
                          op_a_dp[63] && (a_hi_zero && a_lo_zero),
                          op_a_dp[63] && is_subn_d, op_a_dp[63] && is_norm_d, op_a_dp[63] && is_inf_d};

  reg [63:0] res_1cyc;
  always @(*) begin
    case (op5)
      5'b11100: begin // FMV.X.W/D, FCLASS.S/D
        if (funct3_i == 3'b001) begin
          res_1cyc = is_sp ? {54'd0, fclass_sp} : {54'd0, fclass_dp};
        end else if (is_sp) begin
          res_1cyc = {{32{op_a_sp[31]}}, op_a_sp};
        end else begin
          res_1cyc = op_a_dp;
        end
      end
      5'b11110: begin // FMV.W.X, FMV.D.X
        res_1cyc = is_sp ? {32'hFFFFFFFF, gpr_src1_i[31:0]} : gpr_src1_i;
      end
      default: begin // 5'b00100: FSGNJ, FSGNJN, FSGNJX
        case (funct3_i)
          3'b000:  res_1cyc = is_sp ? {32'hFFFFFFFF, op_b_sp[31], op_a_sp[30:0]} : {op_b_dp[63], op_a_dp[62:0]};
          3'b001:  res_1cyc = is_sp ? {32'hFFFFFFFF, ~op_b_sp[31], op_a_sp[30:0]} : {~op_b_dp[63], op_a_dp[62:0]};
          3'b010:  res_1cyc = is_sp ? {32'hFFFFFFFF, op_a_sp[31] ^ op_b_sp[31], op_a_sp[30:0]} : {op_a_dp[63] ^ op_b_dp[63], op_a_dp[62:0]};
          default: res_1cyc = is_sp ? {32'hFFFFFFFF, op_a_sp} : op_a_dp;
        endcase
      end
    endcase
  end

  // ==========================================================================
  // 2. 2-Cycle Operations: FEQ/FLT/FLE, FMIN/FMAX, FCVT.S.D, FCVT.D.S
  //    Stage 1: Split 32-bit comparisons & exponent adjustments
  //    Stage 2: Combine flags & select 64-bit result
  // ==========================================================================
  reg [63:0] s1_op_a_q;        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [63:0] s1_op_b_q;        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg        s1_cmp_hi_eq_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg        s1_cmp_hi_lt_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg        s1_cmp_lo_eq_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg        s1_cmp_lo_lt_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg        s1_cmp_sp_eq_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg        s1_cmp_sp_lt_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg        s1_a_zero_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg        s1_b_zero_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg        s1_a_nan_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg        s1_b_nan_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [10:0] s1_sd_exp_adj_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg        s1_sd_ovf_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg        s1_sd_udf_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [10:0] s1_ds_exp_adj_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s1_op_a_q       <= 64'd0;
      s1_op_b_q       <= 64'd0;
      s1_cmp_hi_eq_q  <= 1'b0;
      s1_cmp_hi_lt_q  <= 1'b0;
      s1_cmp_lo_eq_q  <= 1'b0;
      s1_cmp_lo_lt_q  <= 1'b0;
      s1_cmp_sp_eq_q  <= 1'b0;
      s1_cmp_sp_lt_q  <= 1'b0;
      s1_a_zero_q     <= 1'b0;
      s1_b_zero_q     <= 1'b0;
      s1_a_nan_q      <= 1'b0;
      s1_b_nan_q      <= 1'b0;
      s1_sd_exp_adj_q <= 11'd0;
      s1_sd_ovf_q     <= 1'b0;
      s1_sd_udf_q     <= 1'b0;
      s1_ds_exp_adj_q <= 11'd0;
    end else if (start_multicyc && is_2cyc_op) begin
      s1_op_a_q       <= op_a_dp;
      s1_op_b_q       <= op_b_dp;
      s1_cmp_hi_eq_q  <= (op_a_dp[62:32] == op_b_dp[62:32]);
      s1_cmp_hi_lt_q  <= (op_a_dp[62:32] <  op_b_dp[62:32]);
      s1_cmp_lo_eq_q  <= (op_a_dp[31:0]  == op_b_dp[31:0]);
      s1_cmp_lo_lt_q  <= (op_a_dp[31:0]  <  op_b_dp[31:0]);
      s1_cmp_sp_eq_q  <= (op_a_sp[30:0]  == op_b_sp[30:0]);
      s1_cmp_sp_lt_q  <= (op_a_sp[30:0]  <  op_b_sp[30:0]);
      s1_a_zero_q     <= a_zero_comb;
      s1_b_zero_q     <= b_zero_comb;
      s1_a_nan_q      <= a_nan_comb;
      s1_b_nan_q      <= b_nan_comb;
      s1_sd_exp_adj_q <= exp_a_d - 11'd896;
      s1_sd_ovf_q     <= (exp_a_d > 11'd1150);
      s1_sd_udf_q     <= (exp_a_d < 11'd897);
      s1_ds_exp_adj_q <= {3'b000, exp_a_s} + 11'd896;
    end
  end

  // Stage 2 evaluation
  wire s2_sign_a    = is_sp_q ? s1_op_a_q[31] : s1_op_a_q[63];
  wire s2_sign_b    = is_sp_q ? s1_op_b_q[31] : s1_op_b_q[63];
  wire s2_both_zero = s1_a_zero_q && s1_b_zero_q;
  wire s2_any_nan   = s1_a_nan_q  || s1_b_nan_q;
  wire s2_mag_eq    = is_sp_q ? s1_cmp_sp_eq_q : (s1_cmp_hi_eq_q && s1_cmp_lo_eq_q);
  wire s2_mag_lt    = is_sp_q ? s1_cmp_sp_lt_q : (s1_cmp_hi_eq_q ? s1_cmp_lo_lt_q : s1_cmp_hi_lt_q);
  wire s2_mag_gt    = !s2_mag_eq && !s2_mag_lt;

  wire s2_fp_eq = !s2_any_nan && (s2_both_zero || ((s2_sign_a == s2_sign_b) && s2_mag_eq));
  wire s2_fp_lt = !s2_any_nan && !s2_both_zero &&
                  ((s2_sign_a != s2_sign_b) ? s2_sign_a : (s2_sign_a ? s2_mag_gt : s2_mag_lt));
  wire s2_fp_le = s2_fp_lt || s2_fp_eq;

  wire s2_sel_a_min = s1_b_nan_q ? 1'b1 : s1_a_nan_q ? 1'b0 : s2_fp_lt;
  wire s2_sel_a_max = s1_b_nan_q ? 1'b1 : s1_a_nan_q ? 1'b0 : !s2_fp_lt;

  reg [31:0] s2_fcvt_s_d_res;
  always @(*) begin
    if (s1_a_nan_q) begin
      s2_fcvt_s_d_res = {s1_op_a_q[63], 8'hFF, 1'b1, s1_op_a_q[50:29]};
    end else if (s1_a_zero_q) begin
      s2_fcvt_s_d_res = {s1_op_a_q[63], 31'd0};
    end else if (s1_sd_ovf_q) begin
      s2_fcvt_s_d_res = {s1_op_a_q[63], 8'hFF, 23'd0};
    end else if (s1_sd_udf_q) begin
      s2_fcvt_s_d_res = {s1_op_a_q[63], 31'd0};
    end else begin
      s2_fcvt_s_d_res = {s1_op_a_q[63], s1_sd_exp_adj_q[7:0], s1_op_a_q[51:29]};
    end
  end

  reg [63:0] s2_fcvt_d_s_res;
  always @(*) begin
    if (s1_a_nan_q) begin
      s2_fcvt_d_s_res = {s1_op_a_q[31], 11'h7FF, 1'b1, s1_op_a_q[21:0], 29'd0};
    end else if (s1_a_zero_q) begin
      s2_fcvt_d_s_res = {s1_op_a_q[31], 63'd0};
    end else begin
      s2_fcvt_d_s_res = {s1_op_a_q[31], s1_ds_exp_adj_q, s1_op_a_q[22:0], 29'd0};
    end
  end

  reg [63:0] res_2cyc;
  always @(*) begin
    case (op5_q)
      5'b10100: begin // FEQ, FLT, FLE
        case (rm_q)
          3'b010:  res_2cyc = {63'd0, s2_fp_eq};
          3'b001:  res_2cyc = {63'd0, s2_fp_lt};
          3'b000:  res_2cyc = {63'd0, s2_fp_le};
          default: res_2cyc = 64'd0;
        endcase
      end
      5'b00101: begin // FMIN, FMAX
        if (rm_q == 3'b000) begin
          res_2cyc = s2_sel_a_min ? (is_sp_q ? {32'hFFFFFFFF, s1_op_a_q[31:0]} : s1_op_a_q) :
                                    (is_sp_q ? {32'hFFFFFFFF, s1_op_b_q[31:0]} : s1_op_b_q);
        end else begin
          res_2cyc = s2_sel_a_max ? (is_sp_q ? {32'hFFFFFFFF, s1_op_a_q[31:0]} : s1_op_a_q) :
                                    (is_sp_q ? {32'hFFFFFFFF, s1_op_b_q[31:0]} : s1_op_b_q);
        end
      end
      default: begin // 5'b01000: FCVT.S.D, FCVT.D.S
        res_2cyc = is_sp_q ? {32'hFFFFFFFF, s2_fcvt_s_d_res} : s2_fcvt_d_s_res;
      end
    endcase
  end

  // ==========================================================================
  // 3. 3-Cycle Operations: FCVT Float <-> Int (32-bit split negations)
  // ==========================================================================
  // 3a. Float -> Int
  wire [7:0]  exp_s_diff  = exp_a_s - 8'd127;
  wire [5:0]  shift_amt_s = 6'd63 - exp_s_diff[5:0];
  wire [10:0] exp_d_diff  = exp_a_d - 11'd1023;
  wire [5:0]  shift_amt_d = 6'd63 - exp_d_diff[5:0];

  wire [5:0]  f2i_shamt   = is_sp ? shift_amt_s : shift_amt_d;
  wire [63:0] f2i_sig_in  = {mant_a_u, 11'd0};
  wire [63:0] f2i_shifted = f2i_sig_in >> f2i_shamt;

  reg [63:0] f2i_s1_raw_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg        f2i_s1_too_small_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg        f2i_s1_too_large_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg        f2i_s1_sign_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [1:0]  f2i_s1_rs2_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  reg [31:0] f2i_s2_pos_lo_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [31:0] f2i_s2_pos_hi_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [31:0] f2i_s2_neg_lo_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg        f2i_s2_lo_zero_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      f2i_s1_raw_q       <= 64'd0;
      f2i_s1_too_small_q <= 1'b0;
      f2i_s1_too_large_q <= 1'b0;
      f2i_s1_sign_q      <= 1'b0;
      f2i_s1_rs2_q       <= 2'd0;
      f2i_s2_pos_lo_q    <= 32'd0;
      f2i_s2_pos_hi_q    <= 32'd0;
      f2i_s2_neg_lo_q    <= 32'd0;
      f2i_s2_lo_zero_q   <= 1'b0;
    end else if (!stall_i) begin
      if (start_multicyc && is_fcvt_f2i) begin
        f2i_s1_raw_q       <= f2i_shifted;
        f2i_s1_too_small_q <= is_sp ? (exp_a_s < 8'd127)    : (exp_a_d < 11'd1023);
        f2i_s1_too_large_q <= is_sp ? (exp_s_diff >= 8'd63) : (exp_d_diff >= 11'd63);
        f2i_s1_sign_q      <= sign_a;
        f2i_s1_rs2_q       <= rs2_field_i[1:0];
      end else if (state_q == S_BUSY && step_q == 3'd1 && op5_q == 5'b11000) begin
        f2i_s2_pos_lo_q  <= f2i_s1_raw_q[31:0];
        f2i_s2_pos_hi_q  <= f2i_s1_raw_q[63:32];
        f2i_s2_neg_lo_q  <= ~f2i_s1_raw_q[31:0] + 32'd1;
        f2i_s2_lo_zero_q <= (f2i_s1_raw_q[31:0] == 32'd0);
      end
    end
  end

  wire [31:0] f2i_s3_neg_hi = ~f2i_s2_pos_hi_q + {31'd0, f2i_s2_lo_zero_q};
  wire [63:0] f2i_s3_pos    = f2i_s1_too_small_q ? 64'd0 : f2i_s1_too_large_q ? 64'h7FFFFFFFFFFFFFFF : {f2i_s2_pos_hi_q, f2i_s2_pos_lo_q};
  wire [63:0] f2i_s3_neg    = f2i_s1_too_small_q ? 64'd0 : f2i_s1_too_large_q ? 64'h8000000000000000 : {f2i_s3_neg_hi, f2i_s2_neg_lo_q};
  wire [63:0] f2i_s3_raw    = f2i_s1_sign_q ? f2i_s3_neg : f2i_s3_pos;
  wire [63:0] f2i_s3_res    = (f2i_s1_rs2_q[1] == 1'b0) ? {{32{f2i_s3_raw[31]}}, f2i_s3_raw[31:0]} : f2i_s3_raw;

  // 3b. Int -> Float
  wire is_unsigned_int = rs2_field_i[0];
  wire is_word_int     = !rs2_field_i[1];
  wire sign_int_comb   = !is_unsigned_int && (is_word_int ? gpr_src1_i[31] : gpr_src1_i[63]);
  wire [63:0] int_in_ext = is_word_int ? {{32{sign_int_comb}}, gpr_src1_i[31:0]} : gpr_src1_i;
  wire [31:0] i2f_lo_xor = int_in_ext[31:0] ^ {32{sign_int_comb}};
  wire [31:0] i2f_hi_xor = int_in_ext[63:32] ^ {32{sign_int_comb}};

  reg [31:0] i2f_s1_abs_lo_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [31:0] i2f_s1_hi_xor_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg        i2f_s1_carry_lo_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg        i2f_s1_sign_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg        i2f_s1_zero_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg        i2f_s1_word_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  reg [63:0] i2f_s2_val64_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [4:0]  i2f_s2_clz_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg        i2f_s2_hi_nz_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  function [4:0] clz32;
    input [31:0] v;
    reg [4:0] c;
    begin
      if      (v[31]) c = 5'd0;
      else if (v[30]) c = 5'd1;
      else if (v[29]) c = 5'd2;
      else if (v[28]) c = 5'd3;
      else if (v[27]) c = 5'd4;
      else if (v[26]) c = 5'd5;
      else if (v[25]) c = 5'd6;
      else if (v[24]) c = 5'd7;
      else if (v[23]) c = 5'd8;
      else if (v[22]) c = 5'd9;
      else if (v[21]) c = 5'd10;
      else if (v[20]) c = 5'd11;
      else if (v[19]) c = 5'd12;
      else if (v[18]) c = 5'd13;
      else if (v[17]) c = 5'd14;
      else if (v[16]) c = 5'd15;
      else if (v[15]) c = 5'd16;
      else if (v[14]) c = 5'd17;
      else if (v[13]) c = 5'd18;
      else if (v[12]) c = 5'd19;
      else if (v[11]) c = 5'd20;
      else if (v[10]) c = 5'd21;
      else if (v[9])  c = 5'd22;
      else if (v[8])  c = 5'd23;
      else if (v[7])  c = 5'd24;
      else if (v[6])  c = 5'd25;
      else if (v[5])  c = 5'd26;
      else if (v[4])  c = 5'd27;
      else if (v[3])  c = 5'd28;
      else if (v[2])  c = 5'd29;
      else if (v[1])  c = 5'd30;
      else            c = 5'd31;
      clz32 = c;
    end
  endfunction

  wire [31:0] i2f_s2_abs_hi = i2f_s1_hi_xor_q + {31'd0, i2f_s1_carry_lo_q};
  wire        i2f_s2_hi_nz  = !i2f_s1_word_q && (i2f_s2_abs_hi != 32'd0);
  wire [31:0] i2f_s2_val32  = i2f_s2_hi_nz ? i2f_s2_abs_hi : i2f_s1_abs_lo_q;
  wire [63:0] i2f_s2_val64  = i2f_s2_hi_nz ? {i2f_s2_abs_hi, i2f_s1_abs_lo_q} : {i2f_s1_abs_lo_q, 32'd0};

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      i2f_s1_abs_lo_q   <= 32'd0;
      i2f_s1_hi_xor_q   <= 32'd0;
      i2f_s1_carry_lo_q <= 1'b0;
      i2f_s1_sign_q     <= 1'b0;
      i2f_s1_zero_q     <= 1'b0;
      i2f_s1_word_q     <= 1'b0;
      i2f_s2_val64_q    <= 64'd0;
      i2f_s2_clz_q      <= 5'd0;
      i2f_s2_hi_nz_q    <= 1'b0;
    end else if (!stall_i) begin
      if (start_multicyc && is_fcvt_i2f) begin
        i2f_s1_abs_lo_q   <= i2f_lo_xor + {31'd0, sign_int_comb};
        i2f_s1_hi_xor_q   <= i2f_hi_xor;
        i2f_s1_carry_lo_q <= sign_int_comb && (gpr_src1_i[31:0] == 32'd0);
        i2f_s1_sign_q     <= sign_int_comb;
        i2f_s1_zero_q     <= is_word_int ? (gpr_src1_i[31:0] == 32'd0) :
                             ((gpr_src1_i[63:32] == 32'd0) && (gpr_src1_i[31:0] == 32'd0));
        i2f_s1_word_q     <= is_word_int;
      end else if (state_q == S_BUSY && step_q == 3'd1 && op5_q == 5'b11010) begin
        i2f_s2_val64_q <= i2f_s2_val64;
        i2f_s2_clz_q   <= clz32(i2f_s2_val32);
        i2f_s2_hi_nz_q <= i2f_s2_hi_nz;
      end
    end
  end

  wire [5:0]  i2f_s3_lzc    = i2f_s2_hi_nz_q ? {1'b0, i2f_s2_clz_q} : {1'b1, i2f_s2_clz_q};
  wire [63:0] i2f_s3_norm   = i2f_s2_val64_q << i2f_s2_clz_q;
  wire [10:0] i2f_s3_exp_dp = i2f_s1_zero_q ? 11'd0 : (11'd1086 - {5'd0, i2f_s3_lzc});
  wire [7:0]  i2f_s3_exp_sp = i2f_s1_zero_q ? 8'd0  : (8'd190  - {2'd0, i2f_s3_lzc});
  wire [63:0] i2f_s3_res_dp = i2f_s1_zero_q ? 64'd0 : {i2f_s1_sign_q, i2f_s3_exp_dp, i2f_s3_norm[62:11]};
  wire [31:0] i2f_s3_res_sp = i2f_s1_zero_q ? 32'd0 : {i2f_s1_sign_q, i2f_s3_exp_sp, i2f_s3_norm[62:40]};
  wire [63:0] i2f_s3_res    = is_sp_q ? {32'hFFFFFFFF, i2f_s3_res_sp} : i2f_s3_res_dp;

  wire [63:0] res_3cyc = (op5_q == 5'b11000) ? f2i_s3_res : i2f_s3_res;

  // ==========================================================================
  // 4. 4-Cycle Operations: FADD.S/D, FSUB.S/D (28-bit split mantissa add/sub)
  // ==========================================================================
  wire add_is_sub  = is_fsub;
  wire add_eff_sub = add_is_sub ? (sign_a == sign_b) : (sign_a != sign_b);

  wire add_exp_gt     = (exp_a_u > exp_b_u);
  wire add_exp_eq     = (exp_a_u == exp_b_u);
  wire add_mant_hi_gt = (mant_a_u[52:29] > mant_b_u[52:29]);
  wire add_mant_hi_eq = (mant_a_u[52:29] == mant_b_u[52:29]);
  wire add_mant_lo_ge = (mant_a_u[28:0] >= mant_b_u[28:0]);
  wire add_a_ge_b     = add_exp_gt || (add_exp_eq && (add_mant_hi_gt || (add_mant_hi_eq && add_mant_lo_ge)));

  wire [10:0] add_large_exp  = add_a_ge_b ? exp_a_u  : exp_b_u;
  wire [10:0] add_small_exp  = add_a_ge_b ? exp_b_u  : exp_a_u;
  wire [52:0] add_large_mant = add_a_ge_b ? mant_a_u : mant_b_u;
  wire [52:0] add_small_mant = add_a_ge_b ? mant_b_u : mant_a_u;
  wire        add_res_sign   = add_a_ge_b ? sign_a   : (add_is_sub ? !sign_b : sign_b);

  reg [10:0] add_s1_large_exp_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [10:0] add_s1_exp_diff_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [52:0] add_s1_large_mant_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [52:0] add_s1_small_mant_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg        add_s1_res_sign_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg        add_s1_eff_sub_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg        add_s1_is_sub_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg        add_s1_a_zero_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg        add_s1_b_zero_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [63:0] add_s1_op_a_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [63:0] add_s1_op_b_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // Stage 2: Alignment shift & lower 28-bit mantissa addition
  wire [55:0] add_s2_small_ext     = {add_s1_small_mant_q, 3'b000};
  wire [55:0] add_s2_small_shifted = (add_s1_exp_diff_q > 11'd55) ? 56'd0 :
                                     (add_s2_small_ext >> add_s1_exp_diff_q[5:0]);
  wire [55:0] add_s2_large_ext     = {add_s1_large_mant_q, 3'b000};
  wire [27:0] add_s2_small_lo_op   = add_s1_eff_sub_q ? ~add_s2_small_shifted[27:0]  : add_s2_small_shifted[27:0];
  wire [27:0] add_s2_small_hi_op   = add_s1_eff_sub_q ? ~add_s2_small_shifted[55:28] : add_s2_small_shifted[55:28];
  wire [28:0] add_s2_sum_lo        = {1'b0, add_s2_large_ext[27:0]} + {1'b0, add_s2_small_lo_op} + {28'd0, add_s1_eff_sub_q};

  reg [27:0] add_s2_sum_lo_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg        add_s2_carry_lo_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [27:0] add_s2_large_hi_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [27:0] add_s2_small_hi_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // Stage 3: Upper 28-bit mantissa addition & LZC
  wire [28:0] add_s3_sum_hi   = {1'b0, add_s2_large_hi_q} + {1'b0, add_s2_small_hi_q} + {28'd0, add_s2_carry_lo_q};
  wire [28:0] add_s3_sum_hi_m = add_s1_eff_sub_q ? {1'b0, add_s3_sum_hi[27:0]} : add_s3_sum_hi;
  wire [56:0] add_s3_mant_sum = {add_s3_sum_hi_m, add_s2_sum_lo_q};

  // LZC on add_s3_mant_sum[55:3] (53 bits, padded to 64 bits with bit 55 at MSB 63)
  wire [31:0] add_s3_lzc_hi32 = {add_s3_mant_sum[55:24]};
  wire [31:0] add_s3_lzc_lo32 = {add_s3_mant_sum[23:3], 11'd0};
  wire        add_s3_hi_nz    = (add_s3_lzc_hi32 != 32'd0);
  wire [4:0]  add_s3_clz32    = clz32(add_s3_hi_nz ? add_s3_lzc_hi32 : add_s3_lzc_lo32);
  wire [5:0]  add_s3_lzc      = add_s3_hi_nz ? {1'b0, add_s3_clz32} : {1'b1, add_s3_clz32};

  reg [56:0] add_s3_mant_sum_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [5:0]  add_s3_lzc_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg        add_s3_sum_zero_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      add_s1_large_exp_q  <= 11'd0;
      add_s1_exp_diff_q   <= 11'd0;
      add_s1_large_mant_q <= 53'd0;
      add_s1_small_mant_q <= 53'd0;
      add_s1_res_sign_q   <= 1'b0;
      add_s1_eff_sub_q    <= 1'b0;
      add_s1_is_sub_q     <= 1'b0;
      add_s1_a_zero_q     <= 1'b0;
      add_s1_b_zero_q     <= 1'b0;
      add_s1_op_a_q       <= 64'd0;
      add_s1_op_b_q       <= 64'd0;
      add_s2_sum_lo_q     <= 28'd0;
      add_s2_carry_lo_q   <= 1'b0;
      add_s2_large_hi_q   <= 28'd0;
      add_s2_small_hi_q   <= 28'd0;
      add_s3_mant_sum_q   <= 57'd0;
      add_s3_lzc_q        <= 6'd0;
      add_s3_sum_zero_q   <= 1'b0;
    end else if (!stall_i) begin
      if (start_multicyc && is_addsub_op) begin
        add_s1_large_exp_q  <= add_large_exp;
        add_s1_exp_diff_q   <= add_large_exp - add_small_exp;
        add_s1_large_mant_q <= add_large_mant;
        add_s1_small_mant_q <= add_small_mant;
        add_s1_res_sign_q   <= add_res_sign;
        add_s1_eff_sub_q    <= add_eff_sub;
        add_s1_is_sub_q     <= add_is_sub;
        add_s1_a_zero_q     <= a_zero_comb;
        add_s1_b_zero_q     <= b_zero_comb;
        add_s1_op_a_q       <= op_a_dp;
        add_s1_op_b_q       <= op_b_dp;
      end else if (state_q == S_BUSY && (op5_q == 5'b00000 || op5_q == 5'b00001)) begin
        if (step_q == 3'd1) begin
          add_s2_sum_lo_q   <= add_s2_sum_lo[27:0];
          add_s2_carry_lo_q <= add_s2_sum_lo[28];
          add_s2_large_hi_q <= add_s2_large_ext[55:28];
          add_s2_small_hi_q <= add_s2_small_hi_op;
        end else if (step_q == 3'd2) begin
          add_s3_mant_sum_q <= add_s3_mant_sum;
          add_s3_lzc_q      <= add_s3_lzc;
          add_s3_sum_zero_q <= (!add_s3_hi_nz) && (add_s3_mant_sum[23:3] == 21'd0) && (!add_s3_mant_sum[56]);
        end
      end
    end
  end

  // Stage 4: Normalization shift & packing
  wire [52:0] add_s4_norm_mant = add_s3_mant_sum_q[55:3] << add_s3_lzc_q;
  wire [10:0] add_s4_norm_exp  = (add_s1_large_exp_q > {5'd0, add_s3_lzc_q}) ?
                                 (add_s1_large_exp_q - {5'd0, add_s3_lzc_q}) : 11'd0;
  wire [10:0] add_s4_ovf_exp   = add_s1_large_exp_q + 11'd1;

  reg [63:0] res_addsub;
  always @(*) begin
    if (add_s1_a_zero_q && add_s1_b_zero_q) begin
      res_addsub = is_sp_q ? {32'hFFFFFFFF, 32'd0} : 64'd0;
    end else if (add_s1_a_zero_q) begin
      res_addsub = is_sp_q ? {32'hFFFFFFFF, add_s1_is_sub_q ? ~add_s1_op_b_q[31] : add_s1_op_b_q[31], add_s1_op_b_q[30:0]} :
                             {add_s1_is_sub_q ? ~add_s1_op_b_q[63] : add_s1_op_b_q[63], add_s1_op_b_q[62:0]};
    end else if (add_s1_b_zero_q) begin
      res_addsub = is_sp_q ? {32'hFFFFFFFF, add_s1_op_a_q[31:0]} : add_s1_op_a_q;
    end else if (add_s3_sum_zero_q) begin
      res_addsub = is_sp_q ? {32'hFFFFFFFF, 32'd0} : 64'd0;
    end else if (add_s3_mant_sum_q[56]) begin
      res_addsub = is_sp_q ? {32'hFFFFFFFF, add_s1_res_sign_q, add_s4_ovf_exp[7:0], add_s3_mant_sum_q[55:33]} :
                             {add_s1_res_sign_q, add_s4_ovf_exp, add_s3_mant_sum_q[55:4]};
    end else begin
      res_addsub = is_sp_q ? {32'hFFFFFFFF, add_s1_res_sign_q, add_s4_norm_exp[7:0], add_s4_norm_mant[51:29]} :
                             {add_s1_res_sign_q, add_s4_norm_exp, add_s4_norm_mant[51:0]};
    end
  end

  // ==========================================================================
  // 5. Configurable-Latency Multiplication: FMUL.S/D (sk_mul, LAT = MUL_LAT)
  // ==========================================================================
  wire [105:0] mul_mant_prod;
  sk_mul #(
    .AW    (53),
    .BW    (53),
    .SIGNED(0),
    .LAT   (MUL_LAT),
    .IMPL  ("DSP")
  ) u_fp_mul (
    .clk(clk_i),
    .en (!stall_i),
    .a  (mant_a_u),
    .b  (mant_b_u),
    .p  (mul_mant_prod)
  );

  reg        mul_sign_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg        mul_zero_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [11:0] mul_exp_base_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [11:0] mul_exp_p1_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  wire [11:0] mul_exp_sum = {1'b0, exp_a_u} + {1'b0, exp_b_u};
  wire [11:0] mul_bias    = is_sp ? 12'd127 : 12'd1023;
  wire [11:0] mul_bias_m1 = is_sp ? 12'd126 : 12'd1022;

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mul_sign_q     <= 1'b0;
      mul_zero_q     <= 1'b0;
      mul_exp_base_q <= 12'd0;
      mul_exp_p1_q   <= 12'd0;
    end else if (start_multicyc && is_fmul) begin
      mul_sign_q     <= sign_a ^ sign_b;
      mul_zero_q     <= a_zero_comb || b_zero_comb;
      mul_exp_base_q <= (mul_exp_sum >= mul_bias)    ? (mul_exp_sum - mul_bias)    : 12'd0;
      mul_exp_p1_q   <= (mul_exp_sum >= mul_bias_m1) ? (mul_exp_sum - mul_bias_m1) : 12'd0;
    end
  end

  wire [10:0] mul_final_exp = mul_mant_prod[105] ? mul_exp_p1_q[10:0] : mul_exp_base_q[10:0];
  wire [51:0] mul_final_dp  = mul_mant_prod[105] ? mul_mant_prod[104:53] : mul_mant_prod[103:52];
  wire [22:0] mul_final_sp  = mul_mant_prod[105] ? mul_mant_prod[104:82] : mul_mant_prod[103:81];

  wire [63:0] res_fmul = mul_zero_q ? (is_sp_q ? {32'hFFFFFFFF, mul_sign_q, 31'd0} : {mul_sign_q, 63'd0}) :
                         is_sp_q    ? {32'hFFFFFFFF, mul_sign_q, mul_final_exp[7:0], mul_final_sp} :
                                      {mul_sign_q, mul_final_exp, mul_final_dp};

  // ==========================================================================
  // 6. Multi-Cycle Restoring Division: FDIV.S/D
  // ==========================================================================
  reg        div_sign_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg        div_zero_a_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg        div_zero_b_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [10:0] div_exp_norm_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [10:0] div_exp_m1_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [53:0] div_rem_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [53:0] div_den_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [53:0] div_quo_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  wire [54:0] div_sub = {1'b0, div_rem_q} - {1'b0, div_den_q};
  wire        div_ge  = !div_sub[54];

  wire [10:0] div_bias_norm = is_sp ? 11'd127 : 11'd1023;
  wire [10:0] div_bias_m1   = is_sp ? 11'd126 : 11'd1022;

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      div_sign_q     <= 1'b0;
      div_zero_a_q   <= 1'b0;
      div_zero_b_q   <= 1'b0;
      div_exp_norm_q <= 11'd0;
      div_exp_m1_q   <= 11'd0;
      div_rem_q      <= 54'd0;
      div_den_q      <= 54'd0;
      div_quo_q      <= 54'd0;
    end else if (!stall_i) begin
      if (start_multicyc && is_fdiv) begin
        div_sign_q     <= sign_a ^ sign_b;
        div_zero_a_q   <= a_zero_comb;
        div_zero_b_q   <= b_zero_comb;
        div_exp_norm_q <= exp_a_u - exp_b_u + div_bias_norm;
        div_exp_m1_q   <= exp_a_u - exp_b_u + div_bias_m1;
        div_rem_q      <= {1'b0, mant_a_u};
        div_den_q      <= {1'b0, mant_b_u};
        div_quo_q      <= 54'd0;
      end else if (state_q == S_BUSY && op5_q == 5'b00011) begin
        div_rem_q <= div_ge ? {div_sub[52:0], 1'b0} : {div_rem_q[52:0], 1'b0};
        div_quo_q <= {div_quo_q[52:0], div_ge};
      end
    end
  end

  wire [53:0] div_quo_final = {div_quo_q[52:0], div_ge};

  reg [63:0] res_fdiv;
  always @(*) begin
    if (div_zero_b_q) begin
      res_fdiv = is_sp_q ? {32'hFFFFFFFF, div_sign_q, 8'hFF, 23'd0} : {div_sign_q, 11'h7FF, 52'd0};
    end else if (div_zero_a_q) begin
      res_fdiv = is_sp_q ? {32'hFFFFFFFF, div_sign_q, 31'd0} : {div_sign_q, 63'd0};
    end else if (is_sp_q) begin
      if (div_quo_final[24]) begin
        res_fdiv = {32'hFFFFFFFF, div_sign_q, div_exp_norm_q[7:0], div_quo_final[23:1]};
      end else begin
        res_fdiv = {32'hFFFFFFFF, div_sign_q, div_exp_m1_q[7:0], div_quo_final[22:0]};
      end
    end else begin
      if (div_quo_final[53]) begin
        res_fdiv = {div_sign_q, div_exp_norm_q, div_quo_final[52:1]};
      end else begin
        res_fdiv = {div_sign_q, div_exp_m1_q, div_quo_final[51:0]};
      end
    end
  end

  // ==========================================================================
  // 7. Final Output Multiplexer & Pipeline Register
  // ==========================================================================
  reg [63:0] multicyc_res;
  always @(*) begin
    case (op5_q)
      5'b10100, 5'b00101, 5'b01000: multicyc_res = res_2cyc;
      5'b11000, 5'b11010:           multicyc_res = res_3cyc;
      5'b00000, 5'b00001:           multicyc_res = res_addsub;
      5'b00010:                     multicyc_res = res_fmul;
      default:                      multicyc_res = res_fdiv;
    endcase
  end

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid_o      <= 1'b0;
      rd_o         <= 5'd0;
      fp_result_o  <= {XLEN{1'b0}};
      writes_fpr_o <= 1'b0;
      writes_gpr_o <= 1'b0;
    end else if (flush_i) begin
      valid_o      <= 1'b0;
      writes_fpr_o <= 1'b0;
      writes_gpr_o <= 1'b0;
    end else if (!stall_i) begin
      if (finish_multicyc) begin
        valid_o      <= 1'b1;
        rd_o         <= rd_q;
        fp_result_o  <= multicyc_res;
        writes_fpr_o <= wfpr_q;
        writes_gpr_o <= wgpr_q;
      end else if (state_q == S_IDLE && valid_i && is_1cyc_op) begin
        valid_o      <= 1'b1;
        rd_o         <= rd_i;
        fp_result_o  <= res_1cyc;
        writes_fpr_o <= writes_fpr_comb;
        writes_gpr_o <= writes_gpr_comb;
      end else begin
        valid_o <= 1'b0;
      end
    end else begin
      valid_o <= 1'b0;
    end
  end

  wire _unused = &{1'b0, rs2_field_i[4:2], add_s3_sum_hi[28], div_quo_q[53], 1'b0};

endmodule

`default_nettype wire
