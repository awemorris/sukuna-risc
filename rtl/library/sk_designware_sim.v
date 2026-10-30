// ============================================================================
// Sukuna-RISC: Synopsys DesignWare Behavioral Stub for Lint / Simulation
// Target: Synopsys DesignWare Building Blocks (DWBB) Compatibility
// Used when SYNTH_DESIGNWARE is active in Verilator / Icarus Verilog / yosys-bigsim
// ============================================================================

`include "sukuna_defines.vh"

`ifdef SYNTH_DESIGNWARE
`ifndef SYNTH_SYNOPSYS_DC

module DW01_add #(
  parameter width = 8
)(
  input  wire [width-1:0] A,
  input  wire [width-1:0] B,
  input  wire             CI,
  output wire [width-1:0] SUM,
  output wire             CO
);
  assign {CO, SUM} = {1'b0, A} + {1'b0, B} + {{width{1'b0}}, CI};
endmodule

module DW01_sub #(
  parameter width = 8
)(
  input  wire [width-1:0] A,
  input  wire [width-1:0] B,
  input  wire             CI,
  output wire [width-1:0] DIFF,
  output wire             CO
);
  assign {CO, DIFF} = {1'b0, A} - {1'b0, B} - {{width{1'b0}}, CI};
endmodule

module DW01_addsub #(
  parameter width = 8
)(
  input  wire [width-1:0] A,
  input  wire [width-1:0] B,
  input  wire             CI,
  input  wire             ADD_SUB,
  output wire [width-1:0] SUM,
  output wire             CO
);
  assign {CO, SUM} = ADD_SUB ? ({1'b0, A} + {1'b0, B} + {{width{1'b0}}, CI}) :
                               ({1'b0, A} - {1'b0, B} - {{width{1'b0}}, CI});
endmodule

module DW02_mult #(
  parameter A_width = 8,
  parameter B_width = 8
)(
  input  wire [A_width-1:0]         A,
  input  wire [B_width-1:0]         B,
  input  wire                       TC,
  output wire [A_width+B_width-1:0] PRODUCT
);
  wire signed [A_width:0] ext_a = TC ? {A[A_width-1], A} : {1'b0, A};
  wire signed [B_width:0] ext_b = TC ? {B[B_width-1], B} : {1'b0, B};
  wire signed [(A_width+1)+(B_width+1)-1:0] prod = ext_a * ext_b;
  assign PRODUCT = prod[A_width+B_width-1:0];
endmodule

module DW02_mult_2p #(
  parameter A_width = 8,
  parameter B_width = 8
)(
  input  wire                       CLK,
  input  wire                       TC,
  input  wire [A_width-1:0]         A,
  input  wire [B_width-1:0]         B,
  output reg  [A_width+B_width-1:0] PRODUCT
);
  wire signed [A_width:0] ext_a = TC ? {A[A_width-1], A} : {1'b0, A};
  wire signed [B_width:0] ext_b = TC ? {B[B_width-1], B} : {1'b0, B};
  wire signed [(A_width+1)+(B_width+1)-1:0] prod = ext_a * ext_b;
  reg [A_width+B_width-1:0] pipe1_q;
  always @(posedge CLK) begin
    pipe1_q <= prod[A_width+B_width-1:0];
    PRODUCT <= pipe1_q;
  end
endmodule

module DW02_mult_3p #(
  parameter A_width = 8,
  parameter B_width = 8
)(
  input  wire                       CLK,
  input  wire                       TC,
  input  wire [A_width-1:0]         A,
  input  wire [B_width-1:0]         B,
  output reg  [A_width+B_width-1:0] PRODUCT
);
  reg [A_width-1:0] a_q;
  reg [B_width-1:0] b_q;
  reg               tc_q;
  wire signed [A_width:0] ext_a = tc_q ? {a_q[A_width-1], a_q} : {1'b0, a_q};
  wire signed [B_width:0] ext_b = tc_q ? {b_q[B_width-1], b_q} : {1'b0, b_q};
  wire signed [(A_width+1)+(B_width+1)-1:0] prod = ext_a * ext_b;
  reg [A_width+B_width-1:0] pipe1_q;
  always @(posedge CLK) begin
    a_q     <= A;
    b_q     <= B;
    tc_q    <= TC;
    pipe1_q <= prod[A_width+B_width-1:0];
    PRODUCT <= pipe1_q;
  end
endmodule

module DW02_mac #(
  parameter A_width = 8,
  parameter B_width = 8
)(
  input  wire [A_width-1:0]         A,
  input  wire [B_width-1:0]         B,
  input  wire [A_width+B_width-1:0] C,
  input  wire                       TC,
  output wire [A_width+B_width-1:0] MAC
);
  wire signed [A_width:0] ext_a = TC ? {A[A_width-1], A} : {1'b0, A};
  wire signed [B_width:0] ext_b = TC ? {B[B_width-1], B} : {1'b0, B};
  wire signed [(A_width+1)+(B_width+1)-1:0] prod = ext_a * ext_b;
  assign MAC = prod[A_width+B_width-1:0] + C;
endmodule

module DW01_bsh #(
  parameter A_width  = 8,
  parameter SH_width = 3
)(
  input  wire [A_width-1:0]  A,
  input  wire [SH_width-1:0] SH,
  output wire [A_width-1:0]  B
);
  assign B = A >> SH;
endmodule

module DW01_prienc #(
  parameter A_width     = 8,
  parameter INDEX_width = 3
)(
  input  wire [A_width-1:0]     A,
  output reg  [INDEX_width-1:0] INDEX,
  output wire                   NONE
);
  assign NONE = ~(|A);
  integer i;
  always @(*) begin
    INDEX = {INDEX_width{1'b0}};
    for (i = 0; i < A_width; i = i + 1) begin
      if (A[i]) begin
        INDEX = i[INDEX_width-1:0];
      end
    end
  end
endmodule

`endif // !SYNTH_SYNOPSYS_DC
`endif // SYNTH_DESIGNWARE
