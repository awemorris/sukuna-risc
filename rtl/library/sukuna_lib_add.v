// ============================================================================
// Adder Primitive Abstraction (Verilog 2005)
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_lib_add #(
  parameter WIDTH    = 64,
  parameter PIPELINE = 0
)(
  input  wire             clk_i,
  input  wire             rst_ni,

  input  wire             cin_i,
  input  wire [WIDTH-1:0] a_i,
  input  wire [WIDTH-1:0] b_i,

  output wire [WIDTH-1:0] sum_o,
  output wire             cout_o
);

  wire [WIDTH:0] comb_sum = a_i + b_i + {{WIDTH{1'b0}}, cin_i};

  generate
    if (PIPELINE) begin : gen_pipe
      reg [WIDTH-1:0] sum_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      reg             cout_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

      always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          sum_q  <= {WIDTH{1'b0}};
          cout_q <= 1'b0;
        end else begin
          sum_q  <= comb_sum[WIDTH-1:0];
          cout_q <= comb_sum[WIDTH];
        end
      end

      assign sum_o  = sum_q;
      assign cout_o = cout_q;
    end else begin : gen_comb
      assign sum_o  = comb_sum[WIDTH-1:0];
      assign cout_o = comb_sum[WIDTH];
    end
  endgenerate

endmodule
