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
  parameter WE_WIDTH        = BYTE_WRITE_EN ? (DATA_WIDTH / 8) : 1,
  parameter RAM_STYLE       = "block"
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

  // Behavioral memory array for simulation & FPGA BRAM/LUTRAM inference
  (* ram_style = RAM_STYLE *) reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

  // Pipeline output registers
  reg [DATA_WIDTH-1:0] rdata_pipe_q;
  reg [DATA_WIDTH-1:0] rdata_out_q;

  integer init_i;

  initial begin
    for (init_i = 0; init_i < DEPTH; init_i = init_i + 1) begin
      mem[init_i] = {DATA_WIDTH{1'b0}};
    end
    rdata_pipe_q = {DATA_WIDTH{1'b0}};
    rdata_out_q  = {DATA_WIDTH{1'b0}};
  end

  // Synchronous Write (Xilinx standard BRAM inference template)
  genvar i;
  generate
    if (BYTE_WRITE_EN) begin : gen_byte_wr
      for (i = 0; i < WE_WIDTH; i = i + 1) begin : gen_byte
        always @(posedge clk_i) begin
          if (wen_i && wstrb_i[i]) begin
            mem[waddr_i][i*8 +: 8] <= wdata_i[i*8 +: 8];
          end
        end
      end
    end else begin : gen_word_wr
      always @(posedge clk_i) begin
        if (wen_i) begin
          mem[waddr_i] <= wdata_i;
        end
      end
    end
  endgenerate

  // Synchronous Read (Stage 1 with WRITE_FIRST forwarding)
  integer bi;
  always @(posedge clk_i) begin
    if (ren_i) begin
      if (wen_i && (waddr_i == raddr_i)) begin
        if (BYTE_WRITE_EN) begin
          for (bi = 0; bi < WE_WIDTH; bi = bi + 1) begin
            rdata_pipe_q[bi*8 +: 8] <= wstrb_i[bi] ? wdata_i[bi*8 +: 8] : mem[raddr_i][bi*8 +: 8];
          end
        end else begin
          rdata_pipe_q <= wdata_i;
        end
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
