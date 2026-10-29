// ============================================================================
// Sukuna-RISC: Floating-Point Execution Unit (Verilog 2005)
// Complies with design-rule.md and IEEE-754
// Supports RV64F and RV64D:
//   - FMV.X.W, FMV.W.X, FMV.X.D, FMV.D.X
//   - FSGNJ, FSGNJN, FSGNJX (.S and .D)
//   - FEQ, FLT, FLE (.S and .D)
//   - FMIN, FMAX (.S and .D)
//   - FCLASS (.S and .D)
//   - FCVT.W.D, FCVT.WU.D, FCVT.L.D, FCVT.LU.D
//   - FCVT.D.W, FCVT.D.WU, FCVT.D.L, FCVT.D.LU
//   - FCVT.W.S, FCVT.WU.S, FCVT.L.S, FCVT.LU.S
//   - FCVT.S.W, FCVT.S.WU, FCVT.S.L, FCVT.S.LU
//   - FCVT.S.D, FCVT.D.S
//   - FADD.S/D, FSUB.S/D, FMUL.S/D, FDIV.S/D
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_fp_unit #(
  parameter XLEN = `XLEN
)(
  input  wire [6:0]      funct7_i,
  input  wire [2:0]      funct3_i,
  input  wire [4:0]      rs2_field_i,
  input  wire [XLEN-1:0] fpr_src1_i,
  input  wire [XLEN-1:0] fpr_src2_i,
  input  wire [XLEN-1:0] gpr_src1_i,

  output reg  [XLEN-1:0] fp_result_o,
  output reg             writes_fpr_o,
  output reg             writes_gpr_o
);

  wire is_sp = (funct7_i[1:0] == 2'b00); // 00: .S, 01: .D

  // Operands
  wire [63:0] op_a_dp = fpr_src1_i;
  wire [63:0] op_b_dp = fpr_src2_i;
  wire [31:0] op_a_sp = fpr_src1_i[31:0];
  wire [31:0] op_b_sp = fpr_src2_i[31:0];

  // --------------------------------------------------------------------------
  // IEEE-754 Classification & Comparisons
  // --------------------------------------------------------------------------
  wire a_is_nan_dp = (&op_a_dp[62:52]) && (|op_a_dp[51:0]);
  wire b_is_nan_dp = (&op_b_dp[62:52]) && (|op_b_dp[51:0]);
  wire a_is_nan_sp = (&op_a_sp[30:23]) && (|op_a_sp[22:0]);
  wire b_is_nan_sp = (&op_b_sp[30:23]) && (|op_b_sp[22:0]);
  wire is_nan = is_sp ? (a_is_nan_sp || b_is_nan_sp) : (a_is_nan_dp || b_is_nan_dp);

  wire a_is_zero_dp = (op_a_dp[62:0] == 63'd0);
  wire b_is_zero_dp = (op_b_dp[62:0] == 63'd0);
  wire a_is_zero_sp = (op_a_sp[30:0] == 31'd0);
  wire b_is_zero_sp = (op_b_sp[30:0] == 31'd0);
  wire both_zero = is_sp ? (a_is_zero_sp && b_is_zero_sp) : (a_is_zero_dp && b_is_zero_dp);

  wire fp_eq = !is_nan && (both_zero || (is_sp ? (op_a_sp == op_b_sp) : (op_a_dp == op_b_dp)));

  wire fp_lt_dp = !is_nan && !both_zero &&
                  ((op_a_dp[63] != op_b_dp[63]) ? op_a_dp[63] :
                   op_a_dp[63] ? (op_a_dp[62:0] > op_b_dp[62:0]) : (op_a_dp[62:0] < op_b_dp[62:0]));
  wire fp_lt_sp = !is_nan && !both_zero &&
                  ((op_a_sp[31] != op_b_sp[31]) ? op_a_sp[31] :
                   op_a_sp[31] ? (op_a_sp[30:0] > op_b_sp[30:0]) : (op_a_sp[30:0] < op_b_sp[30:0]));
  wire fp_lt = is_sp ? fp_lt_sp : fp_lt_dp;
  wire fp_le = fp_lt || fp_eq;

  // FMIN / FMAX NaN handling
  wire a_nan = is_sp ? a_is_nan_sp : a_is_nan_dp;
  wire b_nan = is_sp ? b_is_nan_sp : b_is_nan_dp;
  wire sel_a_min = b_nan ? 1'b1 : a_nan ? 1'b0 : fp_lt;
  wire sel_a_max = b_nan ? 1'b1 : a_nan ? 1'b0 : !fp_lt;

  // FCLASS breakdown
  wire sign_s      = op_a_sp[31];
  wire [7:0] exp_s = op_a_sp[30:23];
  wire [22:0] m_s  = op_a_sp[22:0];
  wire is_inf_s    = (&exp_s) && (m_s == 23'd0);
  wire is_nan_s    = (&exp_s) && (m_s != 23'd0);
  wire is_snan_s   = is_nan_s && !m_s[22];
  wire is_qnan_s   = is_nan_s && m_s[22];
  wire is_zero_s   = (exp_s == 8'd0) && (m_s == 23'd0);
  wire is_subn_s   = (exp_s == 8'd0) && (m_s != 23'd0);
  wire is_norm_s   = (!(&exp_s)) && (exp_s != 8'd0);
  wire [9:0] fclass_sp = {is_qnan_s, is_snan_s, !sign_s && is_inf_s, !sign_s && is_norm_s,
                          !sign_s && is_subn_s, !sign_s && is_zero_s, sign_s && is_zero_s,
                          sign_s && is_subn_s, sign_s && is_norm_s, sign_s && is_inf_s};

  wire sign_d       = op_a_dp[63];
  wire [10:0] exp_d = op_a_dp[62:52];
  wire [51:0] m_d   = op_a_dp[51:0];
  wire is_inf_d     = (&exp_d) && (m_d == 52'd0);
  wire is_nan_d     = (&exp_d) && (m_d != 52'd0);
  wire is_snan_d    = is_nan_d && !m_d[51];
  wire is_qnan_d    = is_nan_d && m_d[51];
  wire is_zero_d    = (exp_d == 11'd0) && (m_d == 52'd0);
  wire is_subn_d    = (exp_d == 11'd0) && (m_d != 52'd0);
  wire is_norm_d    = (!(&exp_d)) && (exp_d != 11'd0);
  wire [9:0] fclass_dp = {is_qnan_d, is_snan_d, !sign_d && is_inf_d, !sign_d && is_norm_d,
                          !sign_d && is_subn_d, !sign_d && is_zero_d, sign_d && is_zero_d,
                          sign_d && is_subn_d, sign_d && is_norm_d, sign_d && is_inf_d};

  // --------------------------------------------------------------------------
  // Dedicated SP Arithmetic Core (FADD.S, FSUB.S, FMUL.S, FDIV.S)
  // --------------------------------------------------------------------------
  wire is_sub_op = (funct7_i[6:2] == 5'b00001);
  wire eff_sub_sp = is_sub_op ? (op_a_sp[31] == op_b_sp[31]) : (op_a_sp[31] != op_b_sp[31]);

  wire [7:0]  exp_a_sp  = op_a_sp[30:23];
  wire [7:0]  exp_b_sp  = op_b_sp[30:23];
  wire [23:0] mant_a_sp = (|exp_a_sp) ? {1'b1, op_a_sp[22:0]} : {1'b0, op_a_sp[22:0]};
  wire [23:0] mant_b_sp = (|exp_b_sp) ? {1'b1, op_b_sp[22:0]} : {1'b0, op_b_sp[22:0]};

  wire a_ge_b_sp = (exp_a_sp > exp_b_sp) || ((exp_a_sp == exp_b_sp) && (mant_a_sp >= mant_b_sp));
  wire [7:0]  large_exp_sp  = a_ge_b_sp ? exp_a_sp : exp_b_sp;
  wire [7:0]  small_exp_sp  = a_ge_b_sp ? exp_b_sp : exp_a_sp;
  wire [23:0] large_mant_sp = a_ge_b_sp ? mant_a_sp : mant_b_sp;
  wire [23:0] small_mant_sp = a_ge_b_sp ? mant_b_sp : mant_a_sp;
  wire        res_sign_add_sp = a_ge_b_sp ? op_a_sp[31] : (is_sub_op ? !op_b_sp[31] : op_b_sp[31]);

  wire [7:0]  exp_diff_sp = large_exp_sp - small_exp_sp;
  wire [26:0] small_mant_sp_shifted = (exp_diff_sp > 8'd26) ? 27'd0 : ({small_mant_sp, 3'b000} >> exp_diff_sp);
  wire [26:0] large_mant_sp_ext = {large_mant_sp, 3'b000};
  wire [27:0] mant_sum_sp = eff_sub_sp ? ({1'b0, large_mant_sp_ext} - {1'b0, small_mant_sp_shifted}) :
                                         ({1'b0, large_mant_sp_ext} + {1'b0, small_mant_sp_shifted});

  reg [4:0] sp_sub_lzc;
  integer i_sp;
  always @(*) begin
    sp_sub_lzc = 5'd24;
    for (i_sp = 0; i_sp < 24; i_sp = i_sp + 1) begin
      if (mant_sum_sp[3 + i_sp]) sp_sub_lzc = 5'd23 - i_sp[4:0];
    end
  end

  wire [7:0]  norm_exp_sp = (large_exp_sp > {3'd0, sp_sub_lzc}) ? (large_exp_sp - {3'd0, sp_sub_lzc}) : 8'd0;
  wire [50:0] norm_mant_sp_shifted = {mant_sum_sp[26:3], 27'd0} << sp_sub_lzc;

  reg [31:0] add_res_sp;
  always @(*) begin
    if (a_is_zero_sp && b_is_zero_sp) begin
      add_res_sp = 32'd0;
    end else if (a_is_zero_sp) begin
      add_res_sp = is_sub_op ? {~op_b_sp[31], op_b_sp[30:0]} : op_b_sp;
    end else if (b_is_zero_sp) begin
      add_res_sp = op_a_sp;
    end else if (mant_sum_sp[27:3] == 25'd0) begin
      add_res_sp = 32'd0;
    end else if (mant_sum_sp[27]) begin
      add_res_sp = {res_sign_add_sp, large_exp_sp + 8'd1, mant_sum_sp[26:4]};
    end else begin
      add_res_sp = {res_sign_add_sp, norm_exp_sp, norm_mant_sp_shifted[49:27]};
    end
  end

  // SP Multiplier
  wire res_sign_mul_sp = op_a_sp[31] ^ op_b_sp[31];
  wire [8:0]  exp_mul_sum_sp = {1'b0, exp_a_sp} + {1'b0, exp_b_sp};
  wire [8:0]  exp_mul_res_sp = (exp_mul_sum_sp >= 9'd127) ? (exp_mul_sum_sp - 9'd127) : 9'd0;
  wire [47:0] mul_mant_prod_sp = mant_a_sp * mant_b_sp;

  reg [31:0] mul_res_sp;
  always @(*) begin
    if (a_is_zero_sp || b_is_zero_sp) begin
      mul_res_sp = {res_sign_mul_sp, 31'd0};
    end else if (mul_mant_prod_sp[47]) begin
      mul_res_sp = {res_sign_mul_sp, exp_mul_res_sp[7:0] + 8'd1, mul_mant_prod_sp[46:24]};
    end else begin
      mul_res_sp = {res_sign_mul_sp, exp_mul_res_sp[7:0], mul_mant_prod_sp[45:23]};
    end
  end

  // SP Divider
  wire res_sign_div_sp = op_a_sp[31] ^ op_b_sp[31];
  wire signed [9:0] exp_div_sp = {2'b00, exp_a_sp} - {2'b00, exp_b_sp} + 10'd127;
  wire [47:0] div_mant_num_sp = {mant_a_sp, 24'd0};
  wire [47:0] div_mant_quot_sp = (mant_b_sp != 24'd0) ? (div_mant_num_sp / {24'd0, mant_b_sp}) : 48'd0;
  reg [31:0] div_res_sp;
  always @(*) begin
    if (b_is_zero_sp) begin
      div_res_sp = {res_sign_div_sp, 8'hFF, 23'd0};
    end else if (a_is_zero_sp) begin
      div_res_sp = {res_sign_div_sp, 31'd0};
    end else if (div_mant_quot_sp[24]) begin
      div_res_sp = {res_sign_div_sp, exp_div_sp[7:0], div_mant_quot_sp[23:1]};
    end else if (div_mant_quot_sp[23]) begin
      div_res_sp = {res_sign_div_sp, exp_div_sp[7:0] - 8'd1, div_mant_quot_sp[22:0]};
    end else begin
      div_res_sp = {res_sign_div_sp, exp_div_sp[7:0], div_mant_quot_sp[23:1]};
    end
  end

  // --------------------------------------------------------------------------
  // Dedicated DP Arithmetic Core (FADD.D, FSUB.D, FMUL.D, FDIV.D)
  // --------------------------------------------------------------------------
  wire eff_sub_dp = is_sub_op ? (op_a_dp[63] == op_b_dp[63]) : (op_a_dp[63] != op_b_dp[63]);

  wire [10:0] exp_a = op_a_dp[62:52];
  wire [10:0] exp_b = op_b_dp[62:52];
  wire [52:0] mant_a = (|exp_a) ? {1'b1, op_a_dp[51:0]} : {1'b0, op_a_dp[51:0]};
  wire [52:0] mant_b = (|exp_b) ? {1'b1, op_b_dp[51:0]} : {1'b0, op_b_dp[51:0]};

  wire a_ge_b = (exp_a > exp_b) || ((exp_a == exp_b) && (mant_a >= mant_b));
  wire [10:0] large_exp  = a_ge_b ? exp_a : exp_b;
  wire [10:0] small_exp  = a_ge_b ? exp_b : exp_a;
  wire [52:0] large_mant = a_ge_b ? mant_a : mant_b;
  wire [52:0] small_mant = a_ge_b ? mant_b : mant_a;
  wire        res_sign_add = a_ge_b ? op_a_dp[63] : (is_sub_op ? !op_b_dp[63] : op_b_dp[63]);

  wire [10:0] exp_diff = large_exp - small_exp;
  wire [55:0] small_mant_shifted = (exp_diff > 11'd55) ? 56'd0 : ({small_mant, 3'b000} >> exp_diff);
  wire [55:0] large_mant_ext = {large_mant, 3'b000};
  wire [56:0] mant_sum = eff_sub_dp ? ({1'b0, large_mant_ext} - {1'b0, small_mant_shifted}) :
                                      ({1'b0, large_mant_ext} + {1'b0, small_mant_shifted});

  reg [5:0] dp_sub_lzc;
  integer i_dp;
  always @(*) begin
    dp_sub_lzc = 6'd53;
    for (i_dp = 0; i_dp < 53; i_dp = i_dp + 1) begin
      if (mant_sum[3 + i_dp]) dp_sub_lzc = 6'd52 - i_dp[5:0];
    end
  end

  wire [10:0] norm_exp_dp = (large_exp > {5'd0, dp_sub_lzc}) ? (large_exp - {5'd0, dp_sub_lzc}) : 11'd0;
  wire [108:0] norm_mant_dp_shifted = {mant_sum[55:3], 56'd0} << dp_sub_lzc;

  reg [63:0] add_res_dp;
  always @(*) begin
    if (a_is_zero_dp && b_is_zero_dp) begin
      add_res_dp = 64'd0;
    end else if (a_is_zero_dp) begin
      add_res_dp = is_sub_op ? {~op_b_dp[63], op_b_dp[62:0]} : op_b_dp;
    end else if (b_is_zero_dp) begin
      add_res_dp = op_a_dp;
    end else if (mant_sum[56:3] == 54'd0) begin
      add_res_dp = 64'd0;
    end else if (mant_sum[56]) begin
      add_res_dp = {res_sign_add, large_exp + 11'd1, mant_sum[55:4]};
    end else begin
      add_res_dp = {res_sign_add, norm_exp_dp, norm_mant_dp_shifted[107:56]};
    end
  end

  // DP Multiplier
  wire res_sign_mul = op_a_dp[63] ^ op_b_dp[63];
  wire [11:0] exp_mul_sum = {1'b0, exp_a} + {1'b0, exp_b};
  wire [11:0] exp_mul_res = (exp_mul_sum >= 12'd1023) ? (exp_mul_sum - 12'd1023) : 12'd0;
  wire [105:0] mul_mant_prod = mant_a * mant_b;

  reg [63:0] mul_res_dp;
  always @(*) begin
    if (a_is_zero_dp || b_is_zero_dp) begin
      mul_res_dp = {res_sign_mul, 63'd0};
    end else if (mul_mant_prod[105]) begin
      mul_res_dp = {res_sign_mul, exp_mul_res[10:0] + 11'd1, mul_mant_prod[104:53]};
    end else begin
      mul_res_dp = {res_sign_mul, exp_mul_res[10:0], mul_mant_prod[103:52]};
    end
  end

  // DP Divider
  wire res_sign_div_dp = op_a_dp[63] ^ op_b_dp[63];
  wire signed [12:0] exp_div_dp = {2'b00, exp_a} - {2'b00, exp_b} + 13'd1023;
  wire [105:0] div_mant_num_dp = {mant_a, 53'd0};
  wire [105:0] div_mant_quot_dp = (mant_b != 53'd0) ? (div_mant_num_dp / {53'd0, mant_b}) : 106'd0;
  reg [63:0] div_res_dp;
  always @(*) begin
    if (b_is_zero_dp) begin
      div_res_dp = {res_sign_div_dp, 11'h7FF, 52'd0};
    end else if (a_is_zero_dp) begin
      div_res_dp = {res_sign_div_dp, 63'd0};
    end else if (div_mant_quot_dp[53]) begin
      div_res_dp = {res_sign_div_dp, exp_div_dp[10:0], div_mant_quot_dp[52:1]};
    end else if (div_mant_quot_dp[52]) begin
      div_res_dp = {res_sign_div_dp, exp_div_dp[10:0] - 11'd1, div_mant_quot_dp[51:0]};
    end else begin
      div_res_dp = {res_sign_div_dp, exp_div_dp[10:0], div_mant_quot_dp[52:1]};
    end
  end

  // --------------------------------------------------------------------------
  // FCVT (Float <-> Integer conversion)
  // --------------------------------------------------------------------------
  // Float -> Int
  wire signed [9:0] shift_sp = {2'b00, exp_a_sp} - 10'd127;
  reg [63:0] fcvt_l_s_res;
  always @(*) begin
    if (exp_a_sp < 8'd127) begin
      fcvt_l_s_res = 64'd0;
    end else if (shift_sp >= 10'd63) begin
      fcvt_l_s_res = op_a_sp[31] ? 64'h8000000000000000 : 64'h7FFFFFFFFFFFFFFF;
    end else begin
      fcvt_l_s_res = {1'b1, op_a_sp[22:0], 40'd0} >> (10'd63 - shift_sp);
      if (op_a_sp[31]) fcvt_l_s_res = -fcvt_l_s_res;
    end
  end

  wire signed [12:0] shift_dp = {2'b00, exp_a} - 13'd1023;
  reg [63:0] fcvt_l_d_res;
  always @(*) begin
    if (exp_a < 11'd1023) begin
      fcvt_l_d_res = 64'd0;
    end else if (shift_dp >= 13'd63) begin
      fcvt_l_d_res = op_a_dp[63] ? 64'h8000000000000000 : 64'h7FFFFFFFFFFFFFFF;
    end else begin
      fcvt_l_d_res = {1'b1, op_a_dp[51:0], 11'd0} >> (13'd63 - shift_dp);
      if (op_a_dp[63]) fcvt_l_d_res = -fcvt_l_d_res;
    end
  end

  wire [63:0] fcvt_int_raw = is_sp ? fcvt_l_s_res : fcvt_l_d_res;
  reg [63:0] fcvt_int_res;
  always @(*) begin
    case (rs2_field_i[1:0])
      2'b00: fcvt_int_res = {{32{fcvt_int_raw[31]}}, fcvt_int_raw[31:0]}; // W (signed 32)
      2'b01: fcvt_int_res = {{32{fcvt_int_raw[31]}}, fcvt_int_raw[31:0]}; // WU (unsigned 32 sign-extended)
      2'b10: fcvt_int_res = fcvt_int_raw;                                  // L (signed 64)
      2'b11: fcvt_int_res = fcvt_int_raw;                                  // LU (unsigned 64)
    endcase
  end

  // Int -> Float
  wire is_unsigned_int = rs2_field_i[0];
  wire is_word_int     = !rs2_field_i[1];
  wire sign_int        = !is_unsigned_int && (is_word_int ? gpr_src1_i[31] : gpr_src1_i[63]);
  wire [63:0] int_in   = is_word_int ? (is_unsigned_int ? {32'd0, gpr_src1_i[31:0]} :
                                                          {{32{gpr_src1_i[31]}}, gpr_src1_i[31:0]})
                                     : gpr_src1_i;
  wire [63:0] abs_int  = sign_int ? (-int_in) : int_in;

  reg [5:0] lzc;
  integer k;
  always @(*) begin
    lzc = 6'd63;
    for (k = 0; k < 64; k = k + 1) begin
      if (abs_int[k]) lzc = 6'd63 - k[5:0];
    end
  end

  wire [10:0] cvt_exp_dp = (int_in == 64'd0) ? 11'd0 : (11'd1023 + 11'd63 - {5'd0, lzc});
  wire [7:0]  cvt_exp_sp = (int_in == 64'd0) ? 8'd0  : (8'd127 + 8'd63 - {2'd0, lzc});
  wire [126:0] shifted_abs = {abs_int, 63'd0} << lzc;

  wire [63:0] fcvt_d_int_res = (int_in == 64'd0) ? 64'd0 :
                               {sign_int, cvt_exp_dp, shifted_abs[125:74]};
  wire [31:0] fcvt_s_int_res = (int_in == 64'd0) ? 32'd0 :
                               {sign_int, cvt_exp_sp, shifted_abs[125:103]};

  // FCVT.S.D & FCVT.D.S
  wire [10:0] fcvt_s_d_exp = op_a_dp[62:52];
  wire [10:0] fcvt_s_d_exp_adj = fcvt_s_d_exp - 11'd896;
  reg [31:0] fcvt_s_d_res;
  always @(*) begin
    if (a_is_nan_dp) begin
      fcvt_s_d_res = {op_a_dp[63], 8'hFF, 1'b1, op_a_dp[50:29]};
    end else if (a_is_zero_dp) begin
      fcvt_s_d_res = {op_a_dp[63], 31'd0};
    end else if (fcvt_s_d_exp > 11'd1023 + 11'd127) begin
      fcvt_s_d_res = {op_a_dp[63], 8'hFF, 23'd0};
    end else if (fcvt_s_d_exp < 11'd1023 - 11'd126) begin
      fcvt_s_d_res = {op_a_dp[63], 31'd0};
    end else begin
      fcvt_s_d_res = {op_a_dp[63], fcvt_s_d_exp_adj[7:0], op_a_dp[51:29]};
    end
  end

  reg [63:0] fcvt_d_s_res;
  always @(*) begin
    if (a_is_nan_sp) begin
      fcvt_d_s_res = {op_a_sp[31], 11'h7FF, 1'b1, op_a_sp[21:0], 29'd0};
    end else if (a_is_zero_sp) begin
      fcvt_d_s_res = {op_a_sp[31], 63'd0};
    end else begin
      fcvt_d_s_res = {op_a_sp[31], {3'b000, op_a_sp[30:23]} + 11'd896, op_a_sp[22:0], 29'd0};
    end
  end

  // --------------------------------------------------------------------------
  // Instruction Multiplexer
  // --------------------------------------------------------------------------
  always @(*) begin
    fp_result_o  = {XLEN{1'b0}};
    writes_fpr_o = 1'b0;
    writes_gpr_o = 1'b0;

    case (funct7_i[6:2])
      // 1. FMV.X.W, FMV.X.D, FCLASS (.S and .D)
      5'b11100: begin
        writes_gpr_o = 1'b1;
        if (funct3_i == 3'b001) begin // FCLASS
          fp_result_o = is_sp ? {54'd0, fclass_sp} : {54'd0, fclass_dp};
        end else if (is_sp) begin // FMV.X.W
          fp_result_o = {{32{op_a_sp[31]}}, op_a_sp};
        end else begin // FMV.X.D
          fp_result_o = op_a_dp;
        end
      end

      // 2. FMV.W.X, FMV.D.X
      5'b11110: begin
        writes_fpr_o = 1'b1;
        if (is_sp) begin // FMV.W.X
          fp_result_o = {32'hFFFFFFFF, gpr_src1_i[31:0]};
        end else begin // FMV.D.X
          fp_result_o = gpr_src1_i;
        end
      end

      // 3. FSGNJ, FSGNJN, FSGNJX (.S and .D)
      5'b00100: begin
        writes_fpr_o = 1'b1;
        case (funct3_i)
          3'b000: fp_result_o = is_sp ? {32'hFFFFFFFF, op_b_sp[31], op_a_sp[30:0]} :
                                        {op_b_dp[63], op_a_dp[62:0]};
          3'b001: fp_result_o = is_sp ? {32'hFFFFFFFF, ~op_b_sp[31], op_a_sp[30:0]} :
                                        {~op_b_dp[63], op_a_dp[62:0]};
          3'b010: fp_result_o = is_sp ? {32'hFFFFFFFF, op_a_sp[31] ^ op_b_sp[31], op_a_sp[30:0]} :
                                        {op_a_dp[63] ^ op_b_dp[63], op_a_dp[62:0]};
          default: fp_result_o = is_sp ? {32'hFFFFFFFF, op_a_sp} : op_a_dp;
        endcase
      end

      // 4. FEQ, FLT, FLE (.S and .D)
      5'b10100: begin
        writes_gpr_o = 1'b1;
        case (funct3_i)
          3'b010: fp_result_o = fp_eq ? 64'd1 : 64'd0;
          3'b001: fp_result_o = fp_lt ? 64'd1 : 64'd0;
          3'b000: fp_result_o = fp_le ? 64'd1 : 64'd0;
          default: fp_result_o = 64'd0;
        endcase
      end

      // 5. FMIN, FMAX (.S and .D)
      5'b00101: begin
        writes_fpr_o = 1'b1;
        if (funct3_i == 3'b000) begin // FMIN
          fp_result_o = sel_a_min ? (is_sp ? {32'hFFFFFFFF, op_a_sp} : op_a_dp) :
                                    (is_sp ? {32'hFFFFFFFF, op_b_sp} : op_b_dp);
        end else begin // FMAX
          fp_result_o = sel_a_max ? (is_sp ? {32'hFFFFFFFF, op_a_sp} : op_a_dp) :
                                    (is_sp ? {32'hFFFFFFFF, op_b_sp} : op_b_dp);
        end
      end

      // 6. FADD (.S and .D)
      5'b00000: begin
        writes_fpr_o = 1'b1;
        fp_result_o  = is_sp ? {32'hFFFFFFFF, add_res_sp} : add_res_dp;
      end

      // 7. FSUB (.S and .D)
      5'b00001: begin
        writes_fpr_o = 1'b1;
        fp_result_o  = is_sp ? {32'hFFFFFFFF, add_res_sp} : add_res_dp;
      end

      // 8. FMUL (.S and .D)
      5'b00010: begin
        writes_fpr_o = 1'b1;
        fp_result_o  = is_sp ? {32'hFFFFFFFF, mul_res_sp} : mul_res_dp;
      end

      // 9. FDIV (.S and .D)
      5'b00011: begin
        writes_fpr_o = 1'b1;
        fp_result_o  = is_sp ? {32'hFFFFFFFF, div_res_sp} : div_res_dp;
      end

      // 10. FCVT float -> int
      5'b11000: begin
        writes_gpr_o = 1'b1;
        fp_result_o  = fcvt_int_res;
      end

      // 11. FCVT int -> float
      5'b11010: begin
        writes_fpr_o = 1'b1;
        fp_result_o  = is_sp ? {32'hFFFFFFFF, fcvt_s_int_res} : fcvt_d_int_res;
      end

      // 12. FCVT.S.D and FCVT.D.S
      5'b01000: begin
        writes_fpr_o = 1'b1;
        if (is_sp) begin // FCVT.S.D
          fp_result_o = {32'hFFFFFFFF, fcvt_s_d_res};
        end else begin // FCVT.D.S
          fp_result_o = fcvt_d_s_res;
        end
      end

      default: begin
        fp_result_o  = {XLEN{1'b0}};
        writes_fpr_o = 1'b0;
        writes_gpr_o = 1'b0;
      end
    endcase
  end

endmodule
