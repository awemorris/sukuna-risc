// ============================================================================
// Barrel Shifter Primitive Abstraction (Verilog 2005)
// ============================================================================
// Supports:
//   op_i = 2'b00: SLL (Shift Left Logical)
//   op_i = 2'b01: SRL (Shift Right Logical)
//   op_i = 2'b10: SRA (Shift Right Arithmetic)
// ============================================================================

`include "sukuna_defines.vh"

module sk_shift #(
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

`ifdef SYNTH_DESIGNWARE
  wire [WIDTH-1:0] data_rev;
  genvar gi;
  generate
    for (gi = 0; gi < WIDTH; gi = gi + 1) begin : gen_rev_in
      assign data_rev[gi] = data_i[WIDTH - 1 - gi];
    end
  endgenerate

  wire [WIDTH-1:0] bsh_in = (op_i == 2'b00) ? data_rev : data_i;
  wire [WIDTH-1:0] bsh_out;

  DW01_bsh #(
    .A_width  (WIDTH),
    .SH_width (SHIFT_BITS)
  ) u_dw_bsh (
    .A  (bsh_in),
    .SH (shamt_i),
    .B  (bsh_out)
  );

  wire [WIDTH-1:0] bsh_out_rev;
  generate
    for (gi = 0; gi < WIDTH; gi = gi + 1) begin : gen_rev_out
      assign bsh_out_rev[gi] = bsh_out[WIDTH - 1 - gi];
    end
  endgenerate

  wire [WIDTH-1:0] sra_mask = (shamt_i == {SHIFT_BITS{1'b0}}) ? {WIDTH{1'b0}} :
                              ~({WIDTH{1'b1}} >> shamt_i);

  reg [WIDTH-1:0] comb_res;
  always @(*) begin
    case (op_i)
      2'b00:   comb_res = bsh_out_rev;
      2'b01:   comb_res = bsh_out;
      2'b10:   comb_res = data_i[WIDTH-1] ? (bsh_out | sra_mask) : bsh_out;
      default: comb_res = data_i;
    endcase
  end
`else
  reg [WIDTH-1:0] comb_res;

  always @(*) begin
    case (op_i)
      2'b00:   comb_res = data_i << shamt_i;
      2'b01:   comb_res = data_i >> shamt_i;
      2'b10:   comb_res = $signed(data_i) >>> shamt_i;
      default: comb_res = data_i;
    endcase
  end
`endif

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
