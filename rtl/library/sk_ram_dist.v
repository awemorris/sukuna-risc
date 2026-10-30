// ============================================================================
// Distributed RAM (LUT RAM) Macro Abstraction (Verilog 2005)
// ============================================================================
// Characteristics:
//   - Synchronous write, Synchronous read (1-cycle read latency).
//   - Cannot be read asynchronously.
//   - Suitable for small-to-medium arrays (e.g. TLB, branch buffers, small queues).
//   - Target: FPGA Distributed LUT RAM, or ASIC latch/register arrays.
// ============================================================================

`include "sukuna_defines.vh"

module sk_ram_dist #(
  parameter DATA_WIDTH = 64,
  parameter ADDR_WIDTH = 6,
  parameter DEPTH      = (1 << ADDR_WIDTH)
)(
  input  wire                  clk_i,
  input  wire                  rst_ni,

  // Write Port
  input  wire                  wen_i,
  input  wire [ADDR_WIDTH-1:0] waddr_i,
  input  wire [DATA_WIDTH-1:0] wdata_i,

  // Read Port (Synchronous registered read)
  input  wire                  ren_i,
  input  wire [ADDR_WIDTH-1:0] raddr_i,
  output reg  [DATA_WIDTH-1:0] rdata_o
);

  (* ram_style = "distributed" *) reg [DATA_WIDTH-1:0] mem [0:DEPTH-1]; /* synthesis syn_ramstyle = "select_ram" */

  integer init_i;
  initial begin
    for (init_i = 0; init_i < DEPTH; init_i = init_i + 1) begin
      mem[init_i] = {DATA_WIDTH{1'b0}};
    end
  end

  // Synchronous Write
  always @(posedge clk_i) begin
    if (wen_i) begin
      mem[waddr_i] <= wdata_i;
    end
  end

  // Synchronous Read (1 cycle latency with write forwarding)
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rdata_o <= {DATA_WIDTH{1'b0}};
    end else if (ren_i) begin
      rdata_o <= (wen_i && (waddr_i == raddr_i)) ? wdata_i : mem[raddr_i];
    end
  end

endmodule
