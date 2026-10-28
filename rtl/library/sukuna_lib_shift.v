// ============================================================================
// Barrel Shifter Primitive Abstraction (Verilog 2005)
// ============================================================================
// Supports:
//   op_i = 2'b00: SLL (Shift Left Logical)
//   op_i = 2'b01: SRL (Shift Right Logical)
//   op_i = 2'b10: SRA (Shift Right Arithmetic)
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_lib_shift #(
  parameter WIDTH      = 64,
  parameter SHIFT_BITS = 6, // 2^6 = 64
  parameter PIPELINE   = 0
)(
  input  wire                  clk_i,
  input  wire                  rst_ni,

  input  wire [1:0]            op_i,     // 00: SLL, 01: SRL, 10: SRA
  input  wire [WIDTH-1:0]      data_i,
  input  wire [SHIFT_BITS-1:0] shamt_i,

  output wire [WIDTH-1:0]      result_o
);

  reg [WIDTH-1:0] comb_res;

  always @(*) begin
    case (op_i)
      2'b00:   comb_res = data_i << shamt_i;
      2'b01:   comb_res = data_i >> shamt_i;
      2'b10:   comb_res = $signed(data_i) >>> shamt_i;
      default: comb_res = data_i;
    endcase
  end

  generate
    if (PIPELINE) begin : gen_pipe
      reg [WIDTH-1:0] res_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) res_q <= {WIDTH{1'b0}};
        else         res_q <= comb_res;
      end
      assign result_o = res_q;
    end else begin : gen_comb
      assign result_o = comb_res;
    end
  endgenerate

endmodule
