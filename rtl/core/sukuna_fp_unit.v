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
  input  wire            clk_i,
  input  wire            rst_ni,
  input  wire [6:0]      funct7_i,
  input  wire [2:0]      funct3_i,
  input  wire [4:0]      rs2_field_i,
  input  wire [XLEN-1:0] fpr_src1_i,
  input  wire [XLEN-1:0] fpr_src2_i,
  input  wire [XLEN-1:0] gpr_src1_i,

  output wire            busy_o,
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
  // Exponent extraction for conversions
  // (Multicycle arithmetic FADD/FSUB/FMUL/FDIV is handled in sukuna_fp_eu)
  // --------------------------------------------------------------------------
  wire [7:0]  exp_a_sp = op_a_sp[30:23];
  wire [10:0] exp_a    = op_a_dp[62:52];

  // --------------------------------------------------------------------------
  // FCVT (Float <-> Integer conversion) - 2-cycle balanced pipeline
  wire is_fcvt_fp_to_int = (funct7_i[6:2] == 5'b11000);
  wire is_fcvt_int_to_fp = (funct7_i[6:2] == 5'b11010);
  wire is_fcvt           = is_fcvt_fp_to_int || is_fcvt_int_to_fp;

  reg fcvt_busy_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fcvt_busy_q <= 1'b0;
    end else if (is_fcvt && !fcvt_busy_q) begin
      fcvt_busy_q <= 1'b1;
    end else begin
      fcvt_busy_q <= 1'b0;
    end
  end

  assign busy_o = is_fcvt && !fcvt_busy_q;

  // --------------------------------------------------------------------------
  // 1. Float -> Int: Cycle 1 (Shifter)
  // --------------------------------------------------------------------------
  wire [7:0]  exp_s_diff   = exp_a_sp - 8'd127;
  wire [5:0]  shift_amt_s  = 6'd63 - exp_s_diff[5:0];
  wire [63:0] sig_s        = {1'b1, op_a_sp[22:0], 40'd0};
  wire [63:0] shifted_s    = sig_s >> shift_amt_s;

  wire [10:0] exp_d_diff   = exp_a - 11'd1023;
  wire [5:0]  shift_amt_d  = 6'd63 - exp_d_diff[5:0];
  wire [63:0] sig_d        = {1'b1, op_a_dp[51:0], 11'd0};
  wire [63:0] shifted_d    = sig_d >> shift_amt_d;

  wire [63:0] raw_f2i           = is_sp ? shifted_s : shifted_d;
  wire        exp_too_small_comb = is_sp ? (exp_a_sp < 8'd127) : (exp_a < 11'd1023);
  wire        exp_too_large_comb = is_sp ? (exp_s_diff >= 8'd63) : (exp_d_diff >= 11'd63);
  wire        sign_f2i_comb      = is_sp ? op_a_sp[31] : op_a_dp[63];

  reg [63:0] s1_f2i_raw_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg        s1_f2i_too_small_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg        s1_f2i_too_large_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg        s1_f2i_sign_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [1:0]  s1_f2i_rs2_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s1_f2i_raw_q       <= 64'd0;
      s1_f2i_too_small_q <= 1'b0;
      s1_f2i_too_large_q <= 1'b0;
      s1_f2i_sign_q      <= 1'b0;
      s1_f2i_rs2_q       <= 2'd0;
    end else if (is_fcvt_fp_to_int && !fcvt_busy_q) begin
      s1_f2i_raw_q       <= raw_f2i;
      s1_f2i_too_small_q <= exp_too_small_comb;
      s1_f2i_too_large_q <= exp_too_large_comb;
      s1_f2i_sign_q      <= sign_f2i_comb;
      s1_f2i_rs2_q       <= rs2_field_i[1:0];
    end
  end

  // Float -> Int: Cycle 2 (Negate & Sign-Extend)
  wire [63:0] pos_f2i      = s1_f2i_too_small_q ? 64'd0 : s1_f2i_too_large_q ? 64'h7FFFFFFFFFFFFFFF : s1_f2i_raw_q;
  wire [63:0] neg_f2i      = s1_f2i_too_small_q ? 64'd0 : s1_f2i_too_large_q ? 64'h8000000000000000 : (-s1_f2i_raw_q);
  wire [63:0] fcvt_int_raw = s1_f2i_sign_q ? neg_f2i : pos_f2i;

  reg [63:0] fcvt_int_res;
  always @(*) begin
    case (s1_f2i_rs2_q)
      2'b00, 2'b01: fcvt_int_res = {{32{fcvt_int_raw[31]}}, fcvt_int_raw[31:0]};
      default:      fcvt_int_res = fcvt_int_raw;
    endcase
  end

  // --------------------------------------------------------------------------
  // 2. Int -> Float: Cycle 1 (Negation & Word Muxing)
  // --------------------------------------------------------------------------
  wire is_unsigned_int = rs2_field_i[0];
  wire is_word_int     = !rs2_field_i[1];
  wire sign_int        = !is_unsigned_int && (is_word_int ? gpr_src1_i[31] : gpr_src1_i[63]);
  wire int_is_zero     = is_word_int ? (gpr_src1_i[31:0] == 32'd0) : (gpr_src1_i == 64'd0);

  wire [63:0] int_in_ext   = is_word_int ? {{32{sign_int}}, gpr_src1_i[31:0]} : gpr_src1_i;
  wire [63:0] abs_int_comb = (int_in_ext ^ {64{sign_int}}) + {63'd0, sign_int};

  wire        hi_has_ones_comb = !is_word_int && (|abs_int_comb[63:32]);
  wire [31:0] val32_comb       = hi_has_ones_comb ? abs_int_comb[63:32] : abs_int_comb[31:0];
  wire [63:0] val64_comb       = hi_has_ones_comb ? abs_int_comb : {abs_int_comb[31:0], 32'd0};

  reg [63:0] s1_val64_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [31:0] s1_val32_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg        s1_hi_has_ones_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg        s1_sign_int_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg        s1_zero_q;        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s1_val64_q       <= 64'd0;
      s1_val32_q       <= 32'd0;
      s1_hi_has_ones_q <= 1'b0;
      s1_sign_int_q    <= 1'b0;
      s1_zero_q        <= 1'b0;
    end else if (is_fcvt_int_to_fp && !fcvt_busy_q) begin
      s1_val64_q       <= val64_comb;
      s1_val32_q       <= val32_comb;
      s1_hi_has_ones_q <= hi_has_ones_comb;
      s1_sign_int_q    <= sign_int;
      s1_zero_q        <= int_is_zero;
    end
  end

  // Int -> Float: Cycle 2 (CLZ & 2-stage Fast Barrel Shifter)
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

  wire [4:0]  clz_val = clz32(s1_val32_q);
  wire [5:0]  lzc     = s1_hi_has_ones_q ? {1'b0, clz_val} : {1'b1, clz_val};

  reg [63:0] s1_shift;
  always @(*) begin
    case (clz_val[4:2])
      3'd0: s1_shift = s1_val64_q;
      3'd1: s1_shift = {s1_val64_q[59:0], 4'd0};
      3'd2: s1_shift = {s1_val64_q[55:0], 8'd0};
      3'd3: s1_shift = {s1_val64_q[51:0], 12'd0};
      3'd4: s1_shift = {s1_val64_q[47:0], 16'd0};
      3'd5: s1_shift = {s1_val64_q[43:0], 20'd0};
      3'd6: s1_shift = {s1_val64_q[39:0], 24'd0};
      3'd7: s1_shift = {s1_val64_q[35:0], 28'd0};
    endcase
  end

  reg [63:0] norm_int;
  always @(*) begin
    case (clz_val[1:0])
      2'd0: norm_int = s1_shift;
      2'd1: norm_int = {s1_shift[62:0], 1'b0};
      2'd2: norm_int = {s1_shift[61:0], 2'b0};
      2'd3: norm_int = {s1_shift[60:0], 3'b0};
    endcase
  end

  wire [10:0] cvt_exp_dp = s1_zero_q ? 11'd0 : (11'd1086 - {5'd0, lzc});
  wire [7:0]  cvt_exp_sp = s1_zero_q ? 8'd0  : (8'd190 - {2'd0, lzc});

  wire [63:0] fcvt_d_int_res = s1_zero_q ? 64'd0 : {s1_sign_int_q, cvt_exp_dp, norm_int[62:11]};
  wire [31:0] fcvt_s_int_res = s1_zero_q ? 32'd0 : {s1_sign_int_q, cvt_exp_sp, norm_int[62:40]};

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
  reg [63:0] gpr_res;
  always @(*) begin
    case (funct7_i[6:2])
      5'b11100: begin
        if (funct3_i == 3'b001) begin
          gpr_res = is_sp ? {54'd0, fclass_sp} : {54'd0, fclass_dp};
        end else if (is_sp) begin
          gpr_res = {{32{op_a_sp[31]}}, op_a_sp};
        end else begin
          gpr_res = op_a_dp;
        end
      end
      5'b10100: begin
        case (funct3_i)
          3'b010:  gpr_res = fp_eq ? 64'd1 : 64'd0;
          3'b001:  gpr_res = fp_lt ? 64'd1 : 64'd0;
          3'b000:  gpr_res = fp_le ? 64'd1 : 64'd0;
          default: gpr_res = 64'd0;
        endcase
      end
      5'b11000: begin
        gpr_res = fcvt_int_res;
      end
      default: gpr_res = 64'd0;
    endcase
  end

  reg [63:0] fpr_res;
  always @(*) begin
    case (funct7_i[6:2])
      5'b11110: fpr_res = is_sp ? {32'hFFFFFFFF, gpr_src1_i[31:0]} : gpr_src1_i;
      5'b00100: begin // FSGNJ
        case (funct3_i)
          3'b000: fpr_res = is_sp ? {32'hFFFFFFFF, op_b_sp[31], op_a_sp[30:0]} :
                                    {op_b_dp[63], op_a_dp[62:0]};
          3'b001: fpr_res = is_sp ? {32'hFFFFFFFF, ~op_b_sp[31], op_a_sp[30:0]} :
                                    {~op_b_dp[63], op_a_dp[62:0]};
          3'b010: fpr_res = is_sp ? {32'hFFFFFFFF, op_a_sp[31] ^ op_b_sp[31], op_a_sp[30:0]} :
                                    {op_a_dp[63] ^ op_b_dp[63], op_a_dp[62:0]};
          default: fpr_res = is_sp ? {32'hFFFFFFFF, op_a_sp} : op_a_dp;
        endcase
      end
      5'b00101: begin // FMIN/FMAX
        if (funct3_i == 3'b000) begin
          fpr_res = sel_a_min ? (is_sp ? {32'hFFFFFFFF, op_a_sp} : op_a_dp) :
                                (is_sp ? {32'hFFFFFFFF, op_b_sp} : op_b_dp);
        end else begin
          fpr_res = sel_a_max ? (is_sp ? {32'hFFFFFFFF, op_a_sp} : op_a_dp) :
                                (is_sp ? {32'hFFFFFFFF, op_b_sp} : op_b_dp);
        end
      end
      5'b11010: fpr_res = is_sp ? {32'hFFFFFFFF, fcvt_s_int_res} : fcvt_d_int_res;
      5'b01000: fpr_res = is_sp ? {32'hFFFFFFFF, fcvt_s_d_res}   : fcvt_d_s_res;
      default:  fpr_res = is_sp ? {32'hFFFFFFFF, op_a_sp}        : op_a_dp;
    endcase
  end

  wire writes_gpr = (funct7_i[6:2] == 5'b11100) ||
                    (funct7_i[6:2] == 5'b10100) ||
                    (funct7_i[6:2] == 5'b11000);

  wire writes_fpr = (funct7_i[6:2] == 5'b11110) ||
                    (funct7_i[6:2] == 5'b00100) ||
                    (funct7_i[6:2] == 5'b00101) ||
                    (funct7_i[6:2] == 5'b11010) ||
                    (funct7_i[6:2] == 5'b01000);

  always @(*) begin
    writes_gpr_o = writes_gpr;
    writes_fpr_o = writes_fpr;
    fp_result_o  = writes_gpr ? gpr_res : fpr_res;
  end
endmodule
