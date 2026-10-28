// ============================================================================
// Fused Multiply-Add (FMA) Primitive Abstraction (Verilog 2005)
// ============================================================================
// Calculates:
//   result_o = (a_i * b_i) + (sub_c_i ? -c_i : c_i)
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_lib_fma #(
  parameter A_WIDTH         = 32,
  parameter B_WIDTH         = 32,
  parameter C_WIDTH         = 64,
  parameter OUT_WIDTH       = 64,
  parameter PIPELINE_STAGES = 2
)(
  input  wire                  clk_i,
  input  wire                  rst_ni,

  input  wire                  sub_c_i,
  input  wire [A_WIDTH-1:0]    a_i,
  input  wire [B_WIDTH-1:0]    b_i,
  input  wire [C_WIDTH-1:0]    c_i,

  output wire [OUT_WIDTH-1:0]  result_o
);

  wire [A_WIDTH+B_WIDTH-1:0] mult_res = a_i * b_i;
  wire [OUT_WIDTH-1:0] c_term = sub_c_i ? (-c_i) : c_i;
  wire [OUT_WIDTH-1:0] comb_fma = {{ (OUT_WIDTH-(A_WIDTH+B_WIDTH)){1'b0} }, mult_res} + c_term;

  generate
    if (PIPELINE_STAGES == 0) begin : gen_comb
      assign result_o = comb_fma;
    end else if (PIPELINE_STAGES == 1) begin : gen_pipe1
      reg [OUT_WIDTH-1:0] fma_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) fma_q <= {OUT_WIDTH{1'b0}};
        else         fma_q <= comb_fma;
      end
      assign result_o = fma_q;
    end else begin : gen_pipe2
      reg [OUT_WIDTH-1:0] fma_p1_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      reg [OUT_WIDTH-1:0] fma_p2_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          fma_p1_q <= {OUT_WIDTH{1'b0}};
          fma_p2_q <= {OUT_WIDTH{1'b0}};
        end else begin
          fma_p1_q <= comb_fma;
          fma_p2_q <= fma_p1_q;
        end
      end
      assign result_o = fma_p2_q;
    end
  endgenerate

endmodule
