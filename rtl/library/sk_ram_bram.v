// ============================================================================
// Block RAM (BRAM) Macro Abstraction (Verilog 2005)
// ============================================================================
// Characteristics:
//   - Synchronous write, Synchronous pipelined read (1 or 2 cycles).
//   - Cannot be read asynchronously.
//   - Supports optional byte-wide write enables.
//   - Target: FPGA Block RAM / UltraRAM, or ASIC compiled SRAM macro.
// ============================================================================

`include "sukuna_defines.vh"

module sk_ram_bram #(
  parameter DATA_WIDTH      = 64,
  parameter ADDR_WIDTH      = 10,
  parameter DEPTH           = (1 << ADDR_WIDTH),
  parameter PIPELINE_STAGES = 1,                 // 1: single register, 2: two output registers
  parameter BYTE_WRITE_EN   = 1,
  parameter WE_WIDTH        = BYTE_WRITE_EN ? (DATA_WIDTH / 8) : 1
)(
  input  wire                  clk_i,
  input  wire                  rst_ni,

  // Write Port
  input  wire                  wen_i,
  input  wire [WE_WIDTH-1:0]   wstrb_i,
  input  wire [ADDR_WIDTH-1:0] waddr_i,
  input  wire [DATA_WIDTH-1:0] wdata_i,

  // Read Port (Synchronous only)
  input  wire                  ren_i,
  input  wire [ADDR_WIDTH-1:0] raddr_i,
  output wire [DATA_WIDTH-1:0] rdata_o
);

  // Behavioral memory array for simulation & FPGA BRAM inference
  reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

  // Pipeline output registers
  reg [DATA_WIDTH-1:0] rdata_pipe_q;
  reg [DATA_WIDTH-1:0] rdata_out_q;

  integer i;
  integer init_i;

  initial begin
    for (init_i = 0; init_i < DEPTH; init_i = init_i + 1) begin
      mem[init_i] = {DATA_WIDTH{1'b0}};
    end
    rdata_pipe_q = {DATA_WIDTH{1'b0}};
    rdata_out_q  = {DATA_WIDTH{1'b0}};
  end

  // Synchronous Write
  reg [DATA_WIDTH-1:0] mem_next;
  always @(posedge clk_i) begin
    if (wen_i) begin
      if (BYTE_WRITE_EN) begin
        mem_next = mem[waddr_i];
        for (i = 0; i < WE_WIDTH; i = i + 1) begin
          if (wstrb_i[i]) begin
            mem_next[i*8 +: 8] = wdata_i[i*8 +: 8];
          end
        end
        mem[waddr_i] <= mem_next;
      end else begin
        mem[waddr_i] <= wdata_i;
      end
    end
  end

  // Synchronous Read (Stage 1) - WRITE_FIRST forwarding
  always @(posedge clk_i) begin
    if (ren_i) begin
      if (wen_i && (waddr_i == raddr_i)) begin
        rdata_pipe_q <= wdata_i;
      end else begin
        rdata_pipe_q <= mem[raddr_i];
      end
    end
  end

  // Optional Pipeline Stage 2
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rdata_out_q <= {DATA_WIDTH{1'b0}};
    end else begin
      rdata_out_q <= rdata_pipe_q;
    end
  end

  assign rdata_o = (PIPELINE_STAGES >= 2) ? rdata_out_q : rdata_pipe_q;

endmodule
