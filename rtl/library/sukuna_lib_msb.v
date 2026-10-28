// ============================================================================
// MSB / Priority Encoder / Count Leading Zeros Abstraction (Verilog 2005)
// ============================================================================
// Finds the most significant set bit (MSB index) and computes CLZ.
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_lib_msb #(
  parameter WIDTH     = 64,
  parameter IDX_WIDTH = 6  // 2^6 = 64
)(
  input  wire [WIDTH-1:0]     data_i,

  output reg  [IDX_WIDTH-1:0] msb_idx_o, // Index of highest set bit
  output reg  [IDX_WIDTH:0]   clz_o,     // Count of leading zeros (0..WIDTH)
  output wire                 nonzero_o  // 1 if at least one bit is set
);

  assign nonzero_o = |data_i;

  integer i;
  always @(*) begin
    msb_idx_o = {IDX_WIDTH{1'b0}};
    clz_o     = WIDTH[IDX_WIDTH:0];
    for (i = 0; i < WIDTH; i = i + 1) begin
      if (data_i[i]) begin
        msb_idx_o = i[IDX_WIDTH-1:0];
        clz_o     = WIDTH[IDX_WIDTH:0] - 1'b1 - i[IDX_WIDTH:0];
      end
    end
  end

endmodule
