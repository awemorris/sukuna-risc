// ============================================================================
// MSB / Priority Encoder / Count Leading Zeros Abstraction (Verilog 2005)
// ============================================================================
// Finds the most significant set bit (MSB index) and computes CLZ.
// ============================================================================

`include "sukuna_defines.vh"

module sk_msb #(
  parameter WIDTH     = 64,
  parameter IDX_WIDTH = 6  // 2^6 = 64
)(
  input  wire [WIDTH-1:0]     data_i,

  output reg  [IDX_WIDTH-1:0] msb_idx_o, // Index of highest set bit
  output reg  [IDX_WIDTH:0]   clz_o,     // Count of leading zeros (0..WIDTH)
  output wire                 nonzero_o  // 1 if at least one bit is set
);

`ifdef SYNTH_DESIGNWARE
  wire [IDX_WIDTH-1:0] dw_index;
  wire                 dw_none;

  DW01_prienc #(
    .A_width     (WIDTH),
    .INDEX_width (IDX_WIDTH)
  ) u_dw_prienc (
    .A     (data_i),
    .INDEX (dw_index),
    .NONE  (dw_none)
  );

  assign nonzero_o = ~dw_none;

  always @(*) begin
    if (dw_none) begin
      msb_idx_o = {IDX_WIDTH{1'b0}};
      clz_o     = WIDTH[IDX_WIDTH:0];
    end else begin
      msb_idx_o = dw_index;
      clz_o     = WIDTH[IDX_WIDTH:0] - 1'b1 - {1'b0, dw_index};
    end
  end
`else
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
`endif

endmodule
