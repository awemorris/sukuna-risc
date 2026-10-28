// ============================================================================
// Flip-Flop RAM (FF RAM) Macro Abstraction (Verilog 2005)
// ============================================================================
// Characteristics:
//   - Synchronous write, Asynchronous (combinational) read (0-cycle read latency).
//   - Data is available immediately in the same cycle when raddr is presented.
//   - Supports 2 concurrent read ports (ideal for dual-operand RegFile).
//   - Target: FPGA DFF registers, or ASIC Standard Cell DFF array.
// ============================================================================

`include "sukuna_defines.vh"

module sk_ram_ff #(
  parameter DATA_WIDTH = 64,
  parameter ADDR_WIDTH = 5,
  parameter DEPTH      = (1 << ADDR_WIDTH),
  parameter ZERO_REG0  = 1                  // If 1, address 0 always returns 0
)(
  input  wire                  clk_i,
  input  wire                  rst_ni,

  // Write Port (Synchronous)
  input  wire                  wen_i,
  input  wire [ADDR_WIDTH-1:0] waddr_i,
  input  wire [DATA_WIDTH-1:0] wdata_i,

  // Read Port A (Asynchronous / Combinational)
  input  wire [ADDR_WIDTH-1:0] raddr_a_i,
  output wire [DATA_WIDTH-1:0] rdata_a_o,

  // Read Port B (Asynchronous / Combinational)
  input  wire [ADDR_WIDTH-1:0] raddr_b_i,
  output wire [DATA_WIDTH-1:0] rdata_b_o
);

  reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
  integer i;

  // Synchronous Write with Reset
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (i = 0; i < DEPTH; i = i + 1) begin
        mem[i] <= {DATA_WIDTH{1'b0}};
      end
    end else if (wen_i) begin
      if (!(ZERO_REG0 && (waddr_i == {ADDR_WIDTH{1'b0}}))) begin
        mem[waddr_i] <= wdata_i;
      end
    end
  end

  // Asynchronous / Combinational Read Ports
  assign rdata_a_o = (ZERO_REG0 && (raddr_a_i == {ADDR_WIDTH{1'b0}})) ? {DATA_WIDTH{1'b0}} : mem[raddr_a_i];
  assign rdata_b_o = (ZERO_REG0 && (raddr_b_i == {ADDR_WIDTH{1'b0}})) ? {DATA_WIDTH{1'b0}} : mem[raddr_b_i];

endmodule
