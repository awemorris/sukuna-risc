// ============================================================================
// Sukuna-RISC: AXI4 Memory & ROM Model for Testbench (Verilog 2005)
// ============================================================================
// Features:
//   - Responds to AXI4 128-bit bursts (INCR)
//   - Internal memory array initialized via $readmemh or parameter
//   - Supports 64KB - 16MB simulation RAM/ROM
// ============================================================================

`timescale 1ns / 1ps
`include "sukuna_defines.vh"

module sukuna_axi_mem #(
  parameter AXI_ADDR_WIDTH = `AXI_ADDR_WIDTH,
  parameter AXI_DATA_WIDTH = `AXI_DATA_WIDTH, // 128-bit
  parameter AXI_ID_WIDTH   = `AXI_ID_WIDTH,
  parameter MEM_SIZE_BYTES = 65536,           // 64 KB
  parameter BASE_ADDR      = 64'h0000_0000_8000_0000
)(
  input  wire                          clk_i,
  input  wire                          rst_ni,

  // Write Address Channel (AW)
  input  wire                          s_axi_awvalid,
  output reg                           s_axi_awready,
  input  wire [AXI_ADDR_WIDTH-1:0]     s_axi_awaddr,
  input  wire [AXI_ID_WIDTH-1:0]       s_axi_awid,
  input  wire [7:0]                    s_axi_awlen,
  input  wire [2:0]                    s_axi_awsize,
  input  wire [1:0]                    s_axi_awburst,

  // Write Data Channel (W)
  input  wire                          s_axi_wvalid,
  output reg                           s_axi_wready,
  input  wire [AXI_DATA_WIDTH-1:0]     s_axi_wdata,
  input  wire [(AXI_DATA_WIDTH/8)-1:0] s_axi_wstrb,
  input  wire                          s_axi_wlast,

  // Write Response Channel (B)
  output reg                           s_axi_bvalid,
  input  wire                          s_axi_bready,
  output reg  [AXI_ID_WIDTH-1:0]       s_axi_bid,
  output reg  [1:0]                    s_axi_bresp,

  // Read Address Channel (AR)
  input  wire                          s_axi_arvalid,
  output reg                           s_axi_arready,
  input  wire [AXI_ADDR_WIDTH-1:0]     s_axi_araddr,
  input  wire [AXI_ID_WIDTH-1:0]       s_axi_arid,
  input  wire [7:0]                    s_axi_arlen,
  input  wire [2:0]                    s_axi_arsize,
  input  wire [1:0]                    s_axi_arburst,

  // Read Data Channel (R)
  output reg                           s_axi_rvalid,
  input  wire                          s_axi_rready,
  output reg  [AXI_ID_WIDTH-1:0]       s_axi_rid,
  output reg  [AXI_DATA_WIDTH-1:0]     s_axi_rdata,
  output reg  [1:0]                    s_axi_rresp,
  output reg                           s_axi_rlast
);

  localparam NUM_WORDS_128 = MEM_SIZE_BYTES / 16;
  reg [127:0] mem [0:NUM_WORDS_128-1];

  // --------------------------------------------------------------------------
  // Read Channel FSM
  // --------------------------------------------------------------------------
  localparam R_IDLE = 1'b0;
  localparam R_BURST = 1'b1;
  reg        r_state;
  reg [7:0]  r_len_cnt;
  reg [7:0]  r_total_len;
  reg [AXI_ADDR_WIDTH-1:0] r_curr_addr;
  reg [AXI_ID_WIDTH-1:0]   r_id;

  wire [AXI_ADDR_WIDTH-1:0] r_offset = r_curr_addr - BASE_ADDR;
  wire [15:0] r_mem_idx = r_offset[19:4]; // 16-byte index

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      r_state       <= R_IDLE;
      s_axi_arready <= 1'b1;
      s_axi_rvalid  <= 1'b0;
      s_axi_rlast   <= 1'b0;
      s_axi_rdata   <= 128'd0;
      s_axi_rresp   <= 2'b00;
      s_axi_rid     <= {AXI_ID_WIDTH{1'b0}};
      r_len_cnt     <= 8'd0;
      r_total_len   <= 8'd0;
      r_curr_addr   <= {AXI_ADDR_WIDTH{1'b0}};
      r_id          <= {AXI_ID_WIDTH{1'b0}};
    end else begin
      case (r_state)
        R_IDLE: begin
          s_axi_rlast <= 1'b0;
          if (s_axi_arvalid && s_axi_arready) begin
            r_curr_addr   <= s_axi_araddr;
            r_total_len   <= s_axi_arlen;
            r_len_cnt     <= 8'd0;
            r_id          <= s_axi_arid;
            s_axi_arready <= 1'b0;
            r_state       <= R_BURST;
          end else begin
            s_axi_arready <= 1'b1;
          end
        end

        R_BURST: begin
          if (!s_axi_rvalid || s_axi_rready) begin
            s_axi_rvalid <= 1'b1;
            s_axi_rid    <= r_id;
            s_axi_rdata  <= (r_mem_idx < NUM_WORDS_128) ? mem[r_mem_idx] : 128'h00000013_00000013_00000013_00000013; // NOP default
            s_axi_rresp  <= 2'b00;
            s_axi_rlast  <= (r_len_cnt == r_total_len);

            if (r_len_cnt == r_total_len) begin
              r_state       <= R_IDLE;
              s_axi_arready <= 1'b1;
            end else begin
              r_len_cnt   <= r_len_cnt + 1'b1;
              r_curr_addr <= r_curr_addr + 16; // INCR 16 bytes
            end
          end
        end
      endcase
    end
  end

  // --------------------------------------------------------------------------
  // Write Channel FSM
  // --------------------------------------------------------------------------
  localparam W_IDLE = 2'd0;
  localparam W_DATA = 2'd1;
  localparam W_RESP = 2'd2;
  reg [1:0]  w_state;
  reg [AXI_ADDR_WIDTH-1:0] w_curr_addr;
  reg [AXI_ID_WIDTH-1:0]   w_id;

  wire [AXI_ADDR_WIDTH-1:0] w_offset = w_curr_addr - BASE_ADDR;
  wire [15:0] w_mem_idx = w_offset[19:4];

  integer b;
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      w_state       <= W_IDLE;
      s_axi_awready <= 1'b1;
      s_axi_wready  <= 1'b0;
      s_axi_bvalid  <= 1'b0;
      s_axi_bresp   <= 2'b00;
      s_axi_bid     <= {AXI_ID_WIDTH{1'b0}};
      w_curr_addr   <= {AXI_ADDR_WIDTH{1'b0}};
      w_id          <= {AXI_ID_WIDTH{1'b0}};
    end else begin
      case (w_state)
        W_IDLE: begin
          s_axi_bvalid <= 1'b0;
          if (s_axi_awvalid && s_axi_awready) begin
            w_curr_addr   <= s_axi_awaddr;
            w_id          <= s_axi_awid;
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b1;
            w_state       <= W_DATA;
          end else begin
            s_axi_awready <= 1'b1;
          end
        end

        W_DATA: begin
          if (s_axi_wvalid && s_axi_wready) begin
            if (w_mem_idx < NUM_WORDS_128) begin
              for (b = 0; b < 16; b = b + 1) begin
                if (s_axi_wstrb[b]) begin
                  mem[w_mem_idx][b*8 +: 8] <= s_axi_wdata[b*8 +: 8];
                end
              end
            end

            w_curr_addr <= w_curr_addr + 16;

            if (s_axi_wlast) begin
              s_axi_wready <= 1'b0;
              s_axi_bvalid <= 1'b1;
              s_axi_bid    <= w_id;
              s_axi_bresp  <= 2'b00;
              w_state      <= W_RESP;
            end
          end
        end

        W_RESP: begin
          if (s_axi_bready) begin
            s_axi_bvalid  <= 1'b0;
            s_axi_awready <= 1'b1;
            w_state       <= W_IDLE;
          end
        end
      endcase
    end
  end

endmodule
