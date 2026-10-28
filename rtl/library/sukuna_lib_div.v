// ============================================================================
// Divider Primitive Abstraction (Verilog 2005)
// ============================================================================
// Calculates:
//   quotient_o  = dividend_i / divisor_i
//   remainder_o = dividend_i % divisor_i
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_lib_div #(
  parameter WIDTH = 64
)(
  input  wire             clk_i,
  input  wire             rst_ni,

  input  wire             start_i,
  input  wire             signed_mode_i,
  input  wire [WIDTH-1:0] dividend_i,
  input  wire [WIDTH-1:0] divisor_i,

  output reg              ready_o,
  output reg              done_o,
  output reg  [WIDTH-1:0] quotient_o,
  output reg  [WIDTH-1:0] remainder_o,
  output wire             div_by_zero_o
);

  assign div_by_zero_o = (divisor_i == {WIDTH{1'b0}});

  // Behavioral multi-cycle state machine
  reg [5:0]       count_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [WIDTH-1:0] div_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [WIDTH-1:0] rem_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg             busy_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ready_o     <= 1'b1;
      done_o      <= 1'b0;
      quotient_o  <= {WIDTH{1'b0}};
      remainder_o <= {WIDTH{1'b0}};
      count_q     <= 6'd0;
      busy_q      <= 1'b0;
    end else begin
      done_o <= 1'b0;
      if (start_i && ready_o) begin
        ready_o <= 1'b0;
        busy_q  <= 1'b1;
        count_q <= 6'd4; // 4-cycle stub latency
        if (div_by_zero_o) begin
          quotient_o  <= {WIDTH{1'b1}};
          remainder_o <= dividend_i;
        end else begin
          quotient_o  <= dividend_i / divisor_i;
          remainder_o <= dividend_i % divisor_i;
        end
      end else if (busy_q) begin
        if (count_q == 6'd1) begin
          busy_q  <= 1'b0;
          ready_o <= 1'b1;
          done_o  <= 1'b1;
        end
        count_q <= count_q - 6'd1;
      end
    end
  end

endmodule
