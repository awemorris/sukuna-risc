// ============================================================================
// Subtractor Primitive Abstraction (Verilog 2005)
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_lib_sub #(
  parameter WIDTH    = 64,
  parameter PIPELINE = 0
)(
  input  wire             clk_i,
  input  wire             rst_ni,

  input  wire             bin_i,
  input  wire [WIDTH-1:0] a_i,
  input  wire [WIDTH-1:0] b_i,

  output wire [WIDTH-1:0] diff_o,
  output wire             bout_o
);

  wire [WIDTH:0] comb_diff = {1'b0, a_i} - {1'b0, b_i} - {{WIDTH{1'b0}}, bin_i};

  generate
    if (PIPELINE) begin : gen_pipe
      reg [WIDTH-1:0] diff_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      reg             bout_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

      always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          diff_q <= {WIDTH{1'b0}};
          bout_q <= 1'b0;
        end else begin
          diff_q <= comb_diff[WIDTH-1:0];
          bout_q <= comb_diff[WIDTH];
        end
      end

      assign diff_o = diff_q;
      assign bout_o = bout_q;
    end else begin : gen_comb
      assign diff_o = comb_diff[WIDTH-1:0];
      assign bout_o = comb_diff[WIDTH];
    end
  endgenerate

endmodule
