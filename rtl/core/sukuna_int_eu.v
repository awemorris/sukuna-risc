// ============================================================================
// Sukuna-RISC: Dedicated Integer Execution Unit (INT-EU) (Verilog 2005)
// Complies with design-rule.md
// ============================================================================
// Features:
//   - Resource sharing:
//     * Single sk_addsub for ADD, SUB, SLT, SLTU, Branch Compares
//     * Single sk_shift for SLL, SRL, SRA (both 64-bit and 32-bit Word shifts)
//     * Single sk_mul (parameterizable LAT) for all MUL instructions
//     * Single sk_div for DIV, REM
//   - 32-bit Word operations (RV64I OP-32/OP-IMM-32): 64-bit sign-extension
//   - Multi-cycle busy generation for Hazard Unit backpressure (stall_o)
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_int_eu #(
  parameter XLEN    = `XLEN,
  parameter MUL_LAT = 2
)(
  input  wire            clk_i,
  input  wire            rst_ni,

  input  wire            valid_i,
  input  wire [3:0]      alu_op_i,
  input  wire            is_word_i,
  input  wire [XLEN-1:0] src1_i,
  input  wire [XLEN-1:0] src2_i,
  input  wire [4:0]      rd_i,

  // Multi-cycle stall request to EX stage / Hazard Unit
  output wire            busy_o,

  // Result outputs
  output reg             valid_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [4:0]      rd_o,      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0] result_o,  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // Comparison flags for branch resolution
  output wire            cmp_eq_o,
  output wire            cmp_lt_o,
  output wire            cmp_ltu_o
);

  // --------------------------------------------------------------------------
  // 1. Unified Shared Adder/Subtractor (ADD, SUB, SLT, SLTU, Branch Compares)
  // --------------------------------------------------------------------------
  wire is_sub = (alu_op_i == `ALU_SUB) ||
                (alu_op_i == `ALU_SLT) ||
                (alu_op_i == `ALU_SLTU);

  wire [XLEN-1:0] addsub_res;
  wire            addsub_cb;

  sk_addsub #(
    .WIDTH   (XLEN),
    .PIPELINE(0),
    .IMPL    ("CARRY")
  ) u_shared_addsub (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .sub_i         (is_sub),
    .a_i           (src1_i),
    .b_i           (src2_i),
    .result_o      (addsub_res),
    .carry_borrow_o(addsub_cb)
  );

  // Signed & unsigned comparison evaluation using addsub result
  wire sign1 = src1_i[XLEN-1];
  wire sign2 = src2_i[XLEN-1];
  wire sign_diff = addsub_res[XLEN-1];
  wire overflow = (sign1 != sign2) && (sign_diff != sign1);
  wire slt_val  = sign_diff ^ overflow;
  wire sltu_val = ~addsub_cb; // No carry = borrow in subtraction

  assign cmp_eq_o  = (addsub_res == {XLEN{1'b0}});
  assign cmp_lt_o  = slt_val;
  assign cmp_ltu_o = sltu_val;

  // --------------------------------------------------------------------------
  // 2. Unified Shared Barrel Shifter (SLL, SRL, SRA)
  // --------------------------------------------------------------------------
  wire [1:0] shift_mode = (alu_op_i == `ALU_SLL) ? 2'b00 :
                          (alu_op_i == `ALU_SRL) ? 2'b01 : 2'b10;

  wire [5:0] effective_shamt = is_word_i ? {1'b0, src2_i[4:0]} : src2_i[5:0];
  wire [XLEN-1:0] shift_operand = is_word_i ? {{32{src1_i[31]}}, src1_i[31:0]} : src1_i;
  wire [XLEN-1:0] shift_res;

  sk_shift #(
    .WIDTH     (XLEN),
    .SHIFT_BITS(6),
    .PIPELINE  (0)
  ) u_shared_shifter (
    .clk_i   (clk_i),
    .rst_ni  (rst_ni),
    .op_i    (shift_mode),
    .data_i  (shift_operand),
    .shamt_i (effective_shamt),
    .result_o(shift_res)
  );

  // --------------------------------------------------------------------------
  // 3. Unified Shared Multiplier (sk_mul, Parameterizable LAT, DSP Target)
  // --------------------------------------------------------------------------
  wire is_mul = (alu_op_i == `ALU_MUL);
  wire [129:0] mul_full_prod;

  // Sign extension to 65 bits for signed multiplication
  wire [64:0] mul_a = is_word_i ? {{33{src1_i[31]}}, src1_i[31:0]} : {src1_i[XLEN-1], src1_i};
  wire [64:0] mul_b = is_word_i ? {{33{src2_i[31]}}, src2_i[31:0]} : {src2_i[XLEN-1], src2_i};

  sk_mul #(
    .AW    (65),
    .BW    (65),
    .SIGNED(1),
    .LAT   (MUL_LAT),
    .IMPL  ("DSP")
  ) u_shared_mul (
    .clk(clk_i),
    .en (1'b1),
    .a  (mul_a),
    .b  (mul_b),
    .p  (mul_full_prod)
  );

  // Multiplier pipeline tracking registers
  reg [MUL_LAT:0] mul_pipe_vld_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [4:0]       mul_rd_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg             mul_busy_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg             mul_word_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mul_pipe_vld_q <= {(MUL_LAT+1){1'b0}};
      mul_rd_q       <= 5'd0;
      mul_busy_q     <= 1'b0;
      mul_word_q     <= 1'b0;
    end else begin
      mul_pipe_vld_q <= {mul_pipe_vld_q[MUL_LAT-1:0], (valid_i && is_mul)};
      if (valid_i && is_mul) begin
        mul_word_q <= is_word_i;
        if (MUL_LAT > 1) begin
          mul_rd_q   <= rd_i;
          mul_busy_q <= 1'b1;
        end
      end else if (mul_pipe_vld_q[MUL_LAT-1]) begin
        mul_busy_q <= 1'b0;
      end
    end
  end

  // --------------------------------------------------------------------------
  // 4. Unified Shared Divider (DIV, REM)
  // --------------------------------------------------------------------------
  wire is_div_op = (alu_op_i == `ALU_DIV) || (alu_op_i == `ALU_REM);
  wire div_start = valid_i && is_div_op && !div_busy_q;
  wire div_ready;
  wire div_done;
  wire [XLEN-1:0] div_quotient;
  wire [XLEN-1:0] div_remainder;
  reg  div_busy_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg  div_is_rem_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg  div_word_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [4:0] div_rd_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  wire [XLEN-1:0] div_src1 = is_word_i ? {{32{src1_i[31]}}, src1_i[31:0]} : src1_i;
  wire [XLEN-1:0] div_src2 = is_word_i ? {{32{src2_i[31]}}, src2_i[31:0]} : src2_i;

  sk_div #(
    .WIDTH(XLEN),
    .IMPL ("CARRY")
  ) u_shared_div (
    .clk_i        (clk_i),
    .rst_ni       (rst_ni),
    .start_i      (div_start),
    .signed_mode_i(1'b1),
    .dividend_i   (div_src1),
    .divisor_i    (div_src2),
    .ready_o      (div_ready),
    .done_o       (div_done),
    .quotient_o   (div_quotient),
    .remainder_o  (div_remainder),
    .div_by_zero_o()
  );

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      div_busy_q   <= 1'b0;
      div_is_rem_q <= 1'b0;
      div_word_q   <= 1'b0;
      div_rd_q     <= 5'd0;
    end else begin
      if (div_start) begin
        div_busy_q   <= 1'b1;
        div_is_rem_q <= (alu_op_i == `ALU_REM);
        div_word_q   <= is_word_i;
        div_rd_q     <= rd_i;
      end else if (div_done) begin
        div_busy_q   <= 1'b0;
      end
    end
  end

  // Stall output to EX outer box
  assign busy_o = mul_busy_q || div_busy_q;

  // --------------------------------------------------------------------------
  // 5. Result Selection & Output Latching
  // --------------------------------------------------------------------------
  wire [XLEN-1:0] logic_and = src1_i & src2_i;
  wire [XLEN-1:0] logic_or  = src1_i | src2_i;
  wire [XLEN-1:0] logic_xor = src1_i ^ src2_i;

  reg [XLEN-1:0] alu_raw_res;
  always @(*) begin
    case (alu_op_i)
      `ALU_ADD:  alu_raw_res = addsub_res;
      `ALU_SUB:  alu_raw_res = addsub_res;
      `ALU_SLL:  alu_raw_res = shift_res;
      `ALU_SLT:  alu_raw_res = {{(XLEN-1){1'b0}}, slt_val};
      `ALU_SLTU: alu_raw_res = {{(XLEN-1){1'b0}}, sltu_val};
      `ALU_XOR:  alu_raw_res = logic_xor;
      `ALU_SRL:  alu_raw_res = shift_res;
      `ALU_SRA:  alu_raw_res = shift_res;
      `ALU_OR:   alu_raw_res = logic_or;
      `ALU_AND:  alu_raw_res = logic_and;
      default:   alu_raw_res = addsub_res;
    endcase
  end

  wire [XLEN-1:0] final_alu_res = is_word_i ? {{32{alu_raw_res[31]}}, alu_raw_res[31:0]} : alu_raw_res;
  wire [XLEN-1:0] div_res_raw   = div_is_rem_q ? div_remainder : div_quotient;
  wire [XLEN-1:0] div_final_res = div_word_q ? {{32{div_res_raw[31]}}, div_res_raw[31:0]} : div_res_raw;
  wire [XLEN-1:0] mul_final_res = mul_word_q ? {{32{mul_full_prod[31]}}, mul_full_prod[31:0]} : mul_full_prod[XLEN-1:0];

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid_o  <= 1'b0;
      rd_o     <= 5'd0;
      result_o <= {XLEN{1'b0}};
    end else if (div_done) begin
      valid_o  <= 1'b1;
      rd_o     <= div_rd_q;
      result_o <= div_final_res;
    end else if (MUL_LAT > 0 && mul_pipe_vld_q[MUL_LAT-1]) begin
      valid_o  <= 1'b1;
      rd_o     <= (MUL_LAT > 1) ? mul_rd_q : rd_i;
      result_o <= mul_final_res;
    end else if (valid_i && !is_mul && !is_div_op) begin
      valid_o  <= 1'b1;
      rd_o     <= rd_i;
      result_o <= final_alu_res;
    end else if (!busy_o) begin
      valid_o <= 1'b0;
    end
  end

  // Avoid unused variable warnings
  wire _unused = &{1'b0, div_ready, 1'b0};

endmodule
