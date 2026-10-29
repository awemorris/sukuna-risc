// ============================================================================
// Bus Interface Unit (BIU) - AXI4 Master Bridge (Verilog 2005)
// Complies with design-rule.md
// Converts 512-bit cache line refill/eviction into standard 128-bit AXI4 bursts
// Burst length: 4 beats x 128 bits = 512 bits (64-byte cache line)
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_biu_axi4 #(
  parameter AXI_ADDR_WIDTH  = `AXI_ADDR_WIDTH,
  parameter AXI_DATA_WIDTH  = `AXI_DATA_WIDTH,  // 128-bit
  parameter AXI_ID_WIDTH    = `AXI_ID_WIDTH,
  parameter PADDR_WIDTH     = `PADDR_WIDTH,
  parameter CACHE_LINE_BITS = `CACHE_LINE_BITS  // 512-bit
)(
  input  wire                       clk_i,
  input  wire                       rst_ni,

  // L2 / Core Refill & Evict Interface
  input  wire                       mem_req_valid_i,
  input  wire                       mem_req_write_i,
  input  wire [PADDR_WIDTH-1:2]     mem_req_paddr_w_i,
  input  wire [CACHE_LINE_BITS-1:0] mem_req_wdata_i,
  output wire                       mem_req_ready_o,
  output reg                        mem_resp_valid_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output wire [CACHE_LINE_BITS-1:0] mem_resp_rdata_o,

  // --------------------------------------------------------------------------
  // AXI4 Master Interface
  // --------------------------------------------------------------------------
  // Write Address Channel (AW)
  output reg                        m_axi_awvalid,      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  input  wire                       m_axi_awready,
  output reg  [AXI_ADDR_WIDTH-1:0]  m_axi_awaddr,       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output wire [AXI_ID_WIDTH-1:0]    m_axi_awid,
  output wire [7:0]                 m_axi_awlen,
  output wire [2:0]                 m_axi_awsize,
  output wire [1:0]                 m_axi_awburst,
  output wire                       m_axi_awlock,
  output wire [3:0]                 m_axi_awcache,
  output wire [2:0]                 m_axi_awprot,
  output wire [3:0]                 m_axi_awqos,

  // Write Data Channel (W)
  output reg                        m_axi_wvalid,       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  input  wire                       m_axi_wready,
  output reg  [AXI_DATA_WIDTH-1:0]  m_axi_wdata,        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output wire [(AXI_DATA_WIDTH/8)-1:0] m_axi_wstrb,
  output reg                        m_axi_wlast,        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // Write Response Channel (B)
  input  wire                       m_axi_bvalid,
  output wire                       m_axi_bready,
  input  wire [AXI_ID_WIDTH-1:0]    m_axi_bid,
  input  wire [1:0]                 m_axi_bresp,

  // Read Address Channel (AR)
  output reg                        m_axi_arvalid,      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  input  wire                       m_axi_arready,
  output reg  [AXI_ADDR_WIDTH-1:0]  m_axi_araddr,       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output wire [AXI_ID_WIDTH-1:0]    m_axi_arid,
  output wire [7:0]                 m_axi_arlen,
  output wire [2:0]                 m_axi_arsize,
  output wire [1:0]                 m_axi_arburst,
  output wire                       m_axi_arlock,
  output wire [3:0]                 m_axi_arcache,
  output wire [2:0]                 m_axi_arprot,
  output wire [3:0]                 m_axi_arqos,

  // Read Data Channel (R)
  input  wire                       m_axi_rvalid,
  output wire                       m_axi_rready,
  input  wire [AXI_ID_WIDTH-1:0]    m_axi_rid,
  input  wire [AXI_DATA_WIDTH-1:0]  m_axi_rdata,
  input  wire [1:0]                 m_axi_rresp,
  input  wire                       m_axi_rlast
);

  // --------------------------------------------------------------------------
  // Static AXI4 Attributes
  // --------------------------------------------------------------------------
  assign m_axi_awid    = {AXI_ID_WIDTH{1'b0}};
  assign m_axi_awlen   = 8'd3;   // 4 beats
  assign m_axi_awsize  = 3'b100; // 16 bytes = 128 bits
  assign m_axi_awburst = 2'b01;  // INCR
  assign m_axi_awlock  = 1'b0;
  assign m_axi_awcache = 4'b0011;
  assign m_axi_awprot  = 3'b000;
  assign m_axi_awqos   = 4'b0000;

  assign m_axi_wstrb   = {(AXI_DATA_WIDTH/8){1'b1}};
  assign m_axi_bready  = 1'b1;

  assign m_axi_arid    = {AXI_ID_WIDTH{1'b0}};
  assign m_axi_arlen   = 8'd3;   // 4 beats
  assign m_axi_arsize  = 3'b100; // 16 bytes = 128 bits
  assign m_axi_arburst = 2'b01;  // INCR
  assign m_axi_arlock  = 1'b0;
  assign m_axi_arcache = 4'b0011;
  assign m_axi_arprot  = 3'b000;
  assign m_axi_arqos   = 4'b0000;
  assign m_axi_rready  = 1'b1;

  // --------------------------------------------------------------------------
  // State Machine
  // --------------------------------------------------------------------------
  localparam S_IDLE       = 3'd0;
  localparam S_AR_REQ     = 3'd1;
  localparam S_R_BURST    = 3'd2;
  localparam S_AW_REQ     = 3'd3;
  localparam S_W_BURST    = 3'd4;
  localparam S_B_RESP     = 3'd5;

  reg [2:0]                 state_q;        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [1:0]                 beat_cnt_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // Multi-beat read buffer: partitioned into 4 x 128-bit DFF registers (<= 128 bits each)
  reg [127:0]               rdata_buf0_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [127:0]               rdata_buf1_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [127:0]               rdata_buf2_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [127:0]               rdata_buf3_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // 512-bit write data buffer instantiated via sk_ram_ff macro
  wire [CACHE_LINE_BITS-1:0] wdata_buf_q;
  wire wdata_buf_wen = (state_q == S_IDLE) && mem_req_valid_i && mem_req_write_i;

  sk_ram_ff #(
    .DATA_WIDTH (CACHE_LINE_BITS),
    .ADDR_WIDTH (1),
    .DEPTH      (1),
    .ZERO_REG0  (0)
  ) u_wdata_buf_ram (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .wen_i    (wdata_buf_wen),
    .waddr_i  (1'b0),
    .wdata_i  (mem_req_wdata_i),
    .wen1_i   (1'b0), .waddr1_i(1'b0), .wdata1_i({CACHE_LINE_BITS{1'b0}}),
    .wen2_i   (1'b0), .waddr2_i(1'b0), .wdata2_i({CACHE_LINE_BITS{1'b0}}),
    .raddr_a_i(1'b0),
    .rdata_a_o(wdata_buf_q),
    .raddr_b_i(1'b0),
    .rdata_b_o()
  );

  assign mem_resp_rdata_o = (beat_cnt_q == 2'd3) ? {m_axi_rdata, rdata_buf2_q, rdata_buf1_q, rdata_buf0_q} :
                                                   {rdata_buf3_q, rdata_buf2_q, rdata_buf1_q, rdata_buf0_q};

  assign mem_req_ready_o = (state_q == S_IDLE);

  wire [AXI_ADDR_WIDTH-1:0] full_req_addr = {{(AXI_ADDR_WIDTH-PADDR_WIDTH){1'b0}}, mem_req_paddr_w_i, 2'b00};

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q          <= S_IDLE;
      beat_cnt_q       <= 2'd0;
      rdata_buf0_q     <= 128'd0;
      rdata_buf1_q     <= 128'd0;
      rdata_buf2_q     <= 128'd0;
      rdata_buf3_q     <= 128'd0;
      mem_resp_valid_o <= 1'b0;
      m_axi_awvalid    <= 1'b0;
      m_axi_awaddr     <= {AXI_ADDR_WIDTH{1'b0}};
      m_axi_wvalid     <= 1'b0;
      m_axi_wdata      <= {AXI_DATA_WIDTH{1'b0}};
      m_axi_wlast      <= 1'b0;
      m_axi_arvalid    <= 1'b0;
      m_axi_araddr     <= {AXI_ADDR_WIDTH{1'b0}};
    end else begin
      mem_resp_valid_o <= 1'b0;

      case (state_q)
        S_IDLE: begin
          beat_cnt_q <= 2'd0;
          if (mem_req_valid_i) begin
            if (mem_req_write_i) begin
              // Write Burst: Start with AW address channel
              m_axi_awvalid <= 1'b1;
              m_axi_awaddr  <= full_req_addr;
              state_q       <= S_AW_REQ;
            end else begin
              // Read Burst: Start with AR address channel
              m_axi_arvalid <= 1'b1;
              m_axi_araddr  <= full_req_addr;
              state_q       <= S_AR_REQ;
            end
          end
        end

        // --------------------------------------------------------------------
        // Read Channel Operations
        // --------------------------------------------------------------------
        S_AR_REQ: begin
          if (m_axi_arready) begin
            m_axi_arvalid <= 1'b0;
            state_q       <= S_R_BURST;
          end
        end

        S_R_BURST: begin
          if (m_axi_rvalid) begin
            case (beat_cnt_q)
              2'd0: rdata_buf0_q <= m_axi_rdata;
              2'd1: rdata_buf1_q <= m_axi_rdata;
              2'd2: rdata_buf2_q <= m_axi_rdata;
              2'd3: rdata_buf3_q <= m_axi_rdata;
            endcase

            if (m_axi_rlast || (beat_cnt_q == 2'd3)) begin
              mem_resp_valid_o <= 1'b1;
              state_q          <= S_IDLE;
            end else begin
              beat_cnt_q <= beat_cnt_q + 1'b1;
            end
          end
        end

        // --------------------------------------------------------------------
        // Write Channel Operations
        // --------------------------------------------------------------------
        S_AW_REQ: begin
          if (m_axi_awready) begin
            m_axi_awvalid <= 1'b0;
            m_axi_wvalid  <= 1'b1;
            m_axi_wdata   <= wdata_buf_q[127:0];
            m_axi_wlast   <= 1'b0;
            beat_cnt_q    <= 2'd0;
            state_q       <= S_W_BURST;
          end
        end

        S_W_BURST: begin
          if (m_axi_wready) begin
            if (beat_cnt_q == 2'd3) begin
              m_axi_wvalid <= 1'b0;
              m_axi_wlast  <= 1'b0;
              state_q      <= S_B_RESP;
            end else begin
              beat_cnt_q   <= beat_cnt_q + 1'b1;
              m_axi_wlast  <= (beat_cnt_q == 2'd2); // Beat 3 will be last
              case (beat_cnt_q + 1'b1)
                2'd1: m_axi_wdata <= wdata_buf_q[255:128];
                2'd2: m_axi_wdata <= wdata_buf_q[383:256];
                2'd3: m_axi_wdata <= wdata_buf_q[511:384];
                default: m_axi_wdata <= wdata_buf_q[127:0];
              endcase
            end
          end
        end

        S_B_RESP: begin
          if (m_axi_bvalid) begin
            mem_resp_valid_o <= 1'b1;
            state_q          <= S_IDLE;
          end
        end

        default: state_q <= S_IDLE;
      endcase
    end
  end

endmodule
