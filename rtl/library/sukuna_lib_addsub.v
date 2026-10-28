// ============================================================================
// Adder/Subtractor Primitive Abstraction (Verilog 2005)
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_lib_addsub #(
  parameter WIDTH    = 64,
  parameter PIPELINE = 0
)(
  input  wire             clk_i,
  input  wire             rst_ni,

  input  wire             sub_i,      // 0: Add, 1: Sub
  input  wire [WIDTH-1:0] a_i,
  input  wire [WIDTH-1:0] b_i,

  output wire [WIDTH-1:0] result_o,
  output wire             carry_borrow_o
);

  wire [WIDTH-1:0] b_effective = sub_i ? ~b_i : b_i;
  wire [WIDTH:0]   comb_res    = a_i + b_effective + {{WIDTH{1'b0}}, sub_i};

  generate
    if (PIPELINE) begin : gen_pipe
      reg [WIDTH-1:0] res_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      reg             cb_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

      always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          res_q <= {WIDTH{1'b0}};
          cb_q  <= 1'b0;
        end else begin
          res_q <= comb_res[WIDTH-1:0];
          cb_q  <= comb_res[WIDTH];
        end
      end

      assign result_o       = res_q;
      assign carry_borrow_o = cb_q;
    end else begin : gen_comb
      assign result_o       = comb_res[WIDTH-1:0];
      assign carry_borrow_o = comb_res[WIDTH];
    end
  endgenerate

endmodule
