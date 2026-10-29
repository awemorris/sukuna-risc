// ============================================================================
// Sukuna-RISC: sk_div Multi-cycle Restoring Divider (Verilog 2005)
// Complies with design-rule.md
// Performs 64-bit integer division iteratively in 64 clock cycles.
// Features 1-cycle early termination for division by zero and overflow.
// ============================================================================

`include "sukuna_defines.vh"

module sk_div #(
  parameter WIDTH = 64,
  parameter IMPL  = "CARRY" // "CARRY", "LOGIC", "DSP"
)(
  input  wire             clk_i,
  input  wire             rst_ni,
  input  wire             flush_i,

  input  wire             start_i,
  input  wire             signed_mode_i,
  input  wire [WIDTH-1:0] dividend_i,
  input  wire [WIDTH-1:0] divisor_i,

  output reg              ready_o,        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg              done_o,         /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [WIDTH-1:0] quotient_o,     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [WIDTH-1:0] remainder_o,    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output wire             div_by_zero_o
);

  localparam S_IDLE = 2'b00;
  localparam S_CALC = 2'b01;
  localparam S_DONE = 2'b10;

  reg [1:0] state_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  assign div_by_zero_o = (divisor_i == {WIDTH{1'b0}});

  wire is_overflow = signed_mode_i && (dividend_i == {1'b1, {(WIDTH-1){1'b0}}}) && (divisor_i == {WIDTH{1'b1}});

  // Internal registers for multi-cycle iteration
  reg [WIDTH-1:0]   acc_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [WIDTH-1:0]   quo_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [WIDTH-1:0]   div_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [5:0]         cnt_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg               neg_quo_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg               neg_rem_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // Next-step trial subtraction (single 64-bit adder, ~0.8 ns)
  wire [WIDTH:0] next_acc_trial = {acc_q[WIDTH-2:0], quo_q[WIDTH-1]};
  wire [WIDTH:0] sub_res = next_acc_trial - {1'b0, div_q};
  wire           sub_ok  = ~sub_res[WIDTH];

  wire [WIDTH-1:0] abs_dividend = (signed_mode_i && dividend_i[WIDTH-1]) ? -dividend_i : dividend_i;
  wire [WIDTH-1:0] abs_divisor  = (signed_mode_i && divisor_i[WIDTH-1])  ? -divisor_i  : divisor_i;

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q     <= S_IDLE;
      ready_o     <= 1'b1;
      done_o      <= 1'b0;
      quotient_o  <= {WIDTH{1'b0}};
      remainder_o <= {WIDTH{1'b0}};
      acc_q       <= {WIDTH{1'b0}};
      quo_q       <= {WIDTH{1'b0}};
      div_q       <= {WIDTH{1'b0}};
      cnt_q       <= 6'd0;
      neg_quo_q   <= 1'b0;
      neg_rem_q   <= 1'b0;
    end else if (flush_i) begin
      state_q     <= S_IDLE;
      ready_o     <= 1'b1;
      done_o      <= 1'b0;
    end else begin
      done_o <= 1'b0;

      case (state_q)
        S_IDLE: begin
          ready_o <= 1'b1;
          if (start_i && ready_o) begin
            ready_o <= 1'b0;
            if (div_by_zero_o) begin
              quotient_o  <= {WIDTH{1'b1}};
              remainder_o <= dividend_i;
              done_o      <= 1'b1;
              state_q     <= S_IDLE;
            end else if (is_overflow) begin
              quotient_o  <= dividend_i;
              remainder_o <= {WIDTH{1'b0}};
              done_o      <= 1'b1;
              state_q     <= S_IDLE;
            end else begin
              neg_quo_q <= signed_mode_i && (dividend_i[WIDTH-1] ^ divisor_i[WIDTH-1]);
              neg_rem_q <= signed_mode_i && dividend_i[WIDTH-1];
              acc_q     <= {WIDTH{1'b0}};
              quo_q     <= abs_dividend;
              div_q     <= abs_divisor;
              cnt_q     <= 6'd63;
              state_q   <= S_CALC;
            end
          end
        end

        S_CALC: begin
          if (sub_ok) begin
            acc_q <= sub_res[WIDTH-1:0];
            quo_q <= {quo_q[WIDTH-2:0], 1'b1};
          end else begin
            acc_q <= next_acc_trial[WIDTH-1:0];
            quo_q <= {quo_q[WIDTH-2:0], 1'b0};
          end

          if (cnt_q == 6'd0) begin
            state_q <= S_DONE;
          end else begin
            cnt_q <= cnt_q - 6'd1;
          end
        end

        S_DONE: begin
          quotient_o  <= neg_quo_q ? -quo_q : quo_q;
          remainder_o <= neg_rem_q ? -acc_q : acc_q;
          done_o      <= 1'b1;
          ready_o     <= 1'b1;
          state_q     <= S_IDLE;
        end

        default: state_q <= S_IDLE;
      endcase
    end
  end

endmodule
