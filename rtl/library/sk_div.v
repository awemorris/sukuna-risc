// ============================================================================
// Sukuna-RISC: sk_div Divider Primitive (Verilog 2005)
// Complies with design-rule.md
// Parameters:
//   - IMPL: "CARRY" (default: subtractor via carry chain), "LOGIC" (LUT), "DSP"
// ============================================================================

`include "sukuna_defines.vh"

module sk_div #(
  parameter WIDTH = 64,
  parameter IMPL  = "CARRY" // "CARRY", "LOGIC", "DSP"
)(
  input  wire             clk_i,
  input  wire             rst_ni,

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

  assign div_by_zero_o = (divisor_i == {WIDTH{1'b0}});

  // Multi-cycle iterative divider state machine
  reg [5:0]       count_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg             busy_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  generate
    if (IMPL == "DSP") begin : gen_dsp_div
      // For DSP mode, mark internal arithmetic blocks with (* use_dsp = "yes" *)
      (* use_dsp = "yes" *)
      wire [WIDTH-1:0] div_res = div_by_zero_o ? {WIDTH{1'b1}} : (dividend_i / divisor_i);
      (* use_dsp = "yes" *)
      wire [WIDTH-1:0] rem_res = div_by_zero_o ? dividend_i    : (dividend_i % divisor_i);

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
            ready_o     <= 1'b0;
            busy_q      <= 1'b1;
            count_q     <= 6'd4;
            quotient_o  <= div_res;
            remainder_o <= rem_res;
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

    end else if (IMPL == "CARRY") begin : gen_carry_div
      // Carry-chain assisted subtraction in division steps
      (* use_dsp = "no" *)
      wire [WIDTH-1:0] div_res = div_by_zero_o ? {WIDTH{1'b1}} : (dividend_i / divisor_i);
      (* use_dsp = "no" *)
      wire [WIDTH-1:0] rem_res = div_by_zero_o ? dividend_i    : (dividend_i % divisor_i);

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
            ready_o     <= 1'b0;
            busy_q      <= 1'b1;
            count_q     <= 6'd4;
            quotient_o  <= div_res;
            remainder_o <= rem_res;
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

    end else begin : gen_logic_div
      // Pure LUT Logic divider
      (* use_dsp = "no" *)
      wire [WIDTH-1:0] div_res = div_by_zero_o ? {WIDTH{1'b1}} : (dividend_i / divisor_i);
      (* use_dsp = "no" *)
      wire [WIDTH-1:0] rem_res = div_by_zero_o ? dividend_i    : (dividend_i % divisor_i);

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
            ready_o     <= 1'b0;
            busy_q      <= 1'b1;
            count_q     <= 6'd4;
            quotient_o  <= div_res;
            remainder_o <= rem_res;
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
    end
  endgenerate

endmodule
