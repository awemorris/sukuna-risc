// ============================================================================
// Multiplier Primitive Abstraction (Verilog 2005)
// ============================================================================
// Characteristics:
//   - Configurable input widths (A_WIDTH, B_WIDTH).
//   - Full product width (A_WIDTH + B_WIDTH).
//   - Supports signed and unsigned multiplication.
//   - Configurable pipeline stages (0 for combinational, 1 or 2 for DSP retiming).
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_lib_mul #(
  parameter A_WIDTH         = 64,
  parameter B_WIDTH         = 64,
  parameter PROD_WIDTH      = A_WIDTH + B_WIDTH,
  parameter PIPELINE_STAGES = 1
)(
  input  wire                  clk_i,
  input  wire                  rst_ni,

  input  wire                  signed_a_i,
  input  wire                  signed_b_i,
  input  wire [A_WIDTH-1:0]    a_i,
  input  wire [B_WIDTH-1:0]    b_i,

  output wire [PROD_WIDTH-1:0] prod_o
);

  wire signed [A_WIDTH:0] ext_a = signed_a_i ? {a_i[A_WIDTH-1], a_i} : {1'b0, a_i};
  wire signed [B_WIDTH:0] ext_b = signed_b_i ? {b_i[B_WIDTH-1], b_i} : {1'b0, b_i};

  wire signed [(A_WIDTH+1)+(B_WIDTH+1)-1:0] full_prod = ext_a * ext_b;

  generate
    if (PIPELINE_STAGES == 0) begin : gen_comb
      assign prod_o = full_prod[PROD_WIDTH-1:0];
    end else if (PIPELINE_STAGES == 1) begin : gen_pipe1
      reg [PROD_WIDTH-1:0] prod_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          prod_q <= {PROD_WIDTH{1'b0}};
        end else begin
          prod_q <= full_prod[PROD_WIDTH-1:0];
        end
      end
      assign prod_o = prod_q;
    end else begin : gen_pipe2
      reg [PROD_WIDTH-1:0] prod_p1_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      reg [PROD_WIDTH-1:0] prod_p2_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          prod_p1_q <= {PROD_WIDTH{1'b0}};
          prod_p2_q <= {PROD_WIDTH{1'b0}};
        end else begin
          prod_p1_q <= full_prod[PROD_WIDTH-1:0];
          prod_p2_q <= prod_p1_q;
        end
      end
      assign prod_o = prod_p2_q;
    end
  endgenerate

endmodule
