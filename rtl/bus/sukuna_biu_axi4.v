// ============================================================================
// Bus Interface Unit (BIU) - AXI4 Master Bridge Stub (Verilog 2005)
// Converts cache line refill/eviction and MMIO transactions to standard AXI4
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_biu_axi4 #(
  parameter AXI_ADDR_WIDTH  = `AXI_ADDR_WIDTH,
  parameter AXI_DATA_WIDTH  = `AXI_DATA_WIDTH,
  parameter AXI_ID_WIDTH    = `AXI_ID_WIDTH,
  parameter PADDR_WIDTH     = `PADDR_WIDTH,
  parameter CACHE_LINE_BITS = `CACHE_LINE_BITS
)(
  input  wire                       clk_i,
  input  wire                       rst_ni,

  // L2 / Core Refill & Evict Interface
  input  wire                       mem_req_valid_i,
  input  wire                       mem_req_write_i,
  input  wire [PADDR_WIDTH-1:2]     mem_req_paddr_w_i,
  input  wire [CACHE_LINE_BITS-1:0] mem_req_wdata_i,
  output wire                       mem_req_ready_o,
  output wire                       mem_resp_valid_o,
  output wire [CACHE_LINE_BITS-1:0] mem_resp_rdata_o,

  // --------------------------------------------------------------------------
  // AXI4 Master Interface
  // --------------------------------------------------------------------------
  // Write Address Channel (AW)
  output wire                       m_axi_awvalid,
  input  wire                       m_axi_awready,
  output wire [AXI_ADDR_WIDTH-1:0]  m_axi_awaddr,
  output wire [AXI_ID_WIDTH-1:0]    m_axi_awid,
  output wire [7:0]                 m_axi_awlen,
  output wire [2:0]                 m_axi_awsize,
  output wire [1:0]                 m_axi_awburst,
  output wire                       m_axi_awlock,
  output wire [3:0]                 m_axi_awcache,
  output wire [2:0]                 m_axi_awprot,
  output wire [3:0]                 m_axi_awqos,

  // Write Data Channel (W)
  output wire                       m_axi_wvalid,
  input  wire                       m_axi_wready,
  output wire [AXI_DATA_WIDTH-1:0]  m_axi_wdata,
  output wire [(AXI_DATA_WIDTH/8)-1:0] m_axi_wstrb,
  output wire                       m_axi_wlast,

  // Write Response Channel (B)
  input  wire                       m_axi_bvalid,
  output wire                       m_axi_bready,
  input  wire [AXI_ID_WIDTH-1:0]    m_axi_bid,
  input  wire [1:0]                 m_axi_bresp,

  // Read Address Channel (AR)
  output wire                       m_axi_arvalid,
  input  wire                       m_axi_arready,
  output wire [AXI_ADDR_WIDTH-1:0]  m_axi_araddr,
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

  // Internal interface stubs
  assign mem_req_ready_o  = 1'b1;
  assign mem_resp_valid_o = 1'b0;
  assign mem_resp_rdata_o = {CACHE_LINE_BITS{1'b0}};

  // AXI4 write channels stub
  assign m_axi_awvalid  = 1'b0;
  assign m_axi_awaddr   = {AXI_ADDR_WIDTH{1'b0}};
  assign m_axi_awid     = {AXI_ID_WIDTH{1'b0}};
  assign m_axi_awlen    = 8'd0;
  assign m_axi_awsize   = 3'b100; // 16 bytes (128 bits)
  assign m_axi_awburst  = 2'b01;  // INCR
  assign m_axi_awlock   = 1'b0;
  assign m_axi_awcache  = 4'b0011;
  assign m_axi_awprot   = 3'b000;
  assign m_axi_awqos    = 4'b0000;

  assign m_axi_wvalid   = 1'b0;
  assign m_axi_wdata    = {AXI_DATA_WIDTH{1'b0}};
  assign m_axi_wstrb    = {(AXI_DATA_WIDTH/8){1'b0}};
  assign m_axi_wlast    = 1'b0;
  assign m_axi_bready   = 1'b1;

  // AXI4 read channels stub
  assign m_axi_arvalid  = 1'b0;
  assign m_axi_araddr   = {AXI_ADDR_WIDTH{1'b0}};
  assign m_axi_arid     = {AXI_ID_WIDTH{1'b0}};
  assign m_axi_arlen    = 8'd3;   // 4 beats of 128-bit = 512-bit (64B cache line)
  assign m_axi_arsize   = 3'b100; // 16 bytes
  assign m_axi_arburst  = 2'b01;  // INCR
  assign m_axi_arlock   = 1'b0;
  assign m_axi_arcache  = 4'b0011;
  assign m_axi_arprot   = 3'b000;
  assign m_axi_arqos    = 4'b0000;
  assign m_axi_rready   = 1'b1;

endmodule
