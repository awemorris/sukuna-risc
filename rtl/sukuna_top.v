// ============================================================================
// Sukuna-RISC CPU Top-Level (Verilog 2005)
// ============================================================================
// Top-level module connecting:
//   - Sukuna 3-SMT Core (sukuna_core)
//   - Interrupt Subsystem (sukuna_interrupt_subsys: PLIC & CLINT)
//   - Shared 256KB L2 Cache (sukuna_l2_cache)
//   - AXI4 Master Bus Interface Unit (sukuna_biu_axi4)
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_top #(
  parameter NUM_SOURCES     = 32,
  parameter NUM_HARTS       = `NUM_HARTS,
  parameter XLEN            = `XLEN,
  parameter VADDR_WIDTH     = `VADDR_WIDTH,
  parameter PADDR_WIDTH     = `PADDR_WIDTH,
  parameter CACHE_LINE_BITS = `CACHE_LINE_BITS,
  parameter AXI_ADDR_WIDTH  = `AXI_ADDR_WIDTH,
  parameter AXI_DATA_WIDTH  = `AXI_DATA_WIDTH,
  parameter AXI_ID_WIDTH    = `AXI_ID_WIDTH,
  parameter RESET_PC        = 64'h0000_0000_8000_0000
)(
  // Clock and Active-Low Synchronous/Asynchronous Reset
  input  wire                           clk_i,
  input  wire                           rst_ni,

  // Global CPU Enable
  input  wire                           enable_i,

  // External Interrupt Lines to PLIC
  input  wire [NUM_SOURCES-1:0]         ext_irq_i,

  // --------------------------------------------------------------------------
  // AXI4 Master Interface (to SoC Interconnect / External DDR)
  // --------------------------------------------------------------------------
  // Write Address Channel (AW)
  output wire                           m_axi_awvalid,
  input  wire                           m_axi_awready,
  output wire [AXI_ADDR_WIDTH-1:0]      m_axi_awaddr,
  output wire [AXI_ID_WIDTH-1:0]        m_axi_awid,
  output wire [7:0]                     m_axi_awlen,
  output wire [2:0]                     m_axi_awsize,
  output wire [1:0]                     m_axi_awburst,
  output wire                           m_axi_awlock,
  output wire [3:0]                     m_axi_awcache,
  output wire [2:0]                     m_axi_awprot,
  output wire [3:0]                     m_axi_awqos,

  // Write Data Channel (W)
  output wire                           m_axi_wvalid,
  input  wire                           m_axi_wready,
  output wire [AXI_DATA_WIDTH-1:0]      m_axi_wdata,
  output wire [(AXI_DATA_WIDTH/8)-1:0]  m_axi_wstrb,
  output wire                           m_axi_wlast,

  // Write Response Channel (B)
  input  wire                           m_axi_bvalid,
  output wire                           m_axi_bready,
  input  wire [AXI_ID_WIDTH-1:0]        m_axi_bid,
  input  wire [1:0]                     m_axi_bresp,

  // Read Address Channel (AR)
  output wire                           m_axi_arvalid,
  input  wire                           m_axi_arready,
  output wire [AXI_ADDR_WIDTH-1:0]      m_axi_araddr,
  output wire [AXI_ID_WIDTH-1:0]        m_axi_arid,
  output wire [7:0]                     m_axi_arlen,
  output wire [2:0]                     m_axi_arsize,
  output wire [1:0]                     m_axi_arburst,
  output wire                           m_axi_arlock,
  output wire [3:0]                     m_axi_arcache,
  output wire [2:0]                     m_axi_arprot,
  output wire [3:0]                     m_axi_arqos,

  // Read Data Channel (R)
  input  wire                           m_axi_rvalid,
  output wire                           m_axi_rready,
  input  wire [AXI_ID_WIDTH-1:0]        m_axi_rid,
  input  wire [AXI_DATA_WIDTH-1:0]      m_axi_rdata,
  input  wire [1:0]                     m_axi_rresp,
  input  wire                           m_axi_rlast
);

  // --------------------------------------------------------------------------
  // Reset Synchronizer (Asynchronous Assert, Synchronous Deassert)
  // --------------------------------------------------------------------------
  wire sync_rst_n;
  sk_rst_sync u_rst_sync (
    .clk_i        (clk_i),
    .async_rst_ni (rst_ni),
    .sync_rst_no  (sync_rst_n)
  );

  // Gated synchronized reset with enable
  wire core_rst_n = sync_rst_n & enable_i;

  // Interrupt routing wires
  wire [NUM_HARTS-1:0] meip;
  wire [NUM_HARTS-1:0] seip;
  wire [NUM_HARTS-1:0] mtip;
  wire [NUM_HARTS-1:0] msip;

  // Core <-> Shared L2 Cache wires
  wire                       l2_req_valid;
  wire                       l2_req_write;
  wire [3:0]                 l2_req_source;
  wire [PADDR_WIDTH-1:2]     l2_req_paddr_w;
  wire [CACHE_LINE_BITS-1:0] l2_req_wdata;
  wire                       l2_req_ready;
  wire                       l2_resp_valid;
  wire [3:0]                 l2_resp_source;
  wire [CACHE_LINE_BITS-1:0] l2_resp_rdata;

  // L2 Cache <-> BIU wires
  wire                       mem_req_valid;
  wire                       mem_req_write;
  wire [PADDR_WIDTH-1:2]     mem_req_paddr_w;
  wire [CACHE_LINE_BITS-1:0] mem_req_wdata;
  wire                       mem_req_ready;
  wire                       mem_resp_valid;
  wire [CACHE_LINE_BITS-1:0] mem_resp_rdata;

  // --------------------------------------------------------------------------
  // Core Memory Request Router: MMIO (PLIC & CLINT) vs Shared L2 Cache
  // --------------------------------------------------------------------------
  wire is_mmio = (l2_req_paddr_w[PADDR_WIDTH-1:28] == {(PADDR_WIDTH-28){1'b0}});

  wire mmio_req_valid  = l2_req_valid && is_mmio;
  wire cache_req_valid = l2_req_valid && !is_mmio;

  wire mmio_req_ready, mmio_resp_valid;
  wire [XLEN-1:0] mmio_resp_rdata;

  reg [3:0] mmio_src_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  always @(posedge clk_i or negedge core_rst_n) begin
    if (!core_rst_n) begin
      mmio_src_q <= 4'd0;
    end else if (mmio_req_valid && mmio_req_ready) begin
      mmio_src_q <= l2_req_source;
    end
  end

  wire                       l2_cache_req_ready;
  wire                       l2_cache_resp_valid;
  wire [3:0]                 l2_cache_resp_source;
  wire [CACHE_LINE_BITS-1:0] l2_cache_resp_rdata;

  assign l2_req_ready    = is_mmio ? mmio_req_ready : l2_cache_req_ready;
  assign l2_resp_valid   = l2_cache_resp_valid | mmio_resp_valid;
  assign l2_resp_source  = mmio_resp_valid ? mmio_src_q : l2_cache_resp_source;
  assign l2_resp_rdata   = mmio_resp_valid ? {8{mmio_resp_rdata}} : l2_cache_resp_rdata;

  // --------------------------------------------------------------------------
  // Interrupt Subsystem (PLIC & CLINT)
  // --------------------------------------------------------------------------
  sukuna_interrupt_subsys #(
    .NUM_SOURCES(NUM_SOURCES),
    .NUM_HARTS  (NUM_HARTS),
    .XLEN       (XLEN)
  ) u_interrupt_subsys (
    .clk_i            (clk_i),
    .rst_ni           (core_rst_n),
    .ext_irq_i        (ext_irq_i),
    .mmio_req_valid_i (mmio_req_valid),
    .mmio_req_write_i (l2_req_write),
    .mmio_req_addr_i  ({{(XLEN-PADDR_WIDTH){1'b0}}, l2_req_paddr_w, 2'b00}),
    .mmio_req_wdata_i (l2_req_wdata[XLEN-1:0]),
    .mmio_req_wstrb_i ({(XLEN/8){1'b1}}),
    .mmio_req_ready_o (mmio_req_ready),
    .mmio_resp_valid_o(mmio_resp_valid),
    .mmio_resp_rdata_o(mmio_resp_rdata),
    .meip_o           (meip),
    .seip_o           (seip),
    .mtip_o           (mtip),
    .msip_o           (msip)
  );

  // --------------------------------------------------------------------------
  // Sukuna 3-SMT Core
  // --------------------------------------------------------------------------
  sukuna_core #(
    .NUM_HARTS      (NUM_HARTS),
    .XLEN           (XLEN),
    .VADDR_WIDTH    (VADDR_WIDTH),
    .PADDR_WIDTH    (PADDR_WIDTH),
    .CACHE_LINE_BITS(CACHE_LINE_BITS),
    .RESET_PC       (RESET_PC)
  ) u_core (
    .clk_i           (clk_i),
    .rst_ni          (core_rst_n),
    .meip_i          (meip),
    .seip_i          (seip),
    .mtip_i          (mtip),
    .msip_i          (msip),
    .l2_req_valid_o  (l2_req_valid),
    .l2_req_write_o  (l2_req_write),
    .l2_req_source_o (l2_req_source),
    .l2_req_paddr_w_o(l2_req_paddr_w),
    .l2_req_wdata_o  (l2_req_wdata),
    .l2_req_ready_i  (l2_req_ready),
    .l2_resp_valid_i (l2_resp_valid),
    .l2_resp_source_i(l2_resp_source),
    .l2_resp_rdata_i (l2_resp_rdata)
  );

  // --------------------------------------------------------------------------
  // Shared 256KB L2 Cache
  // --------------------------------------------------------------------------
  sukuna_l2_cache #(
    .PADDR_WIDTH    (PADDR_WIDTH),
    .CACHE_LINE_BITS(CACHE_LINE_BITS)
  ) u_l2_cache (
    .clk_i           (clk_i),
    .rst_ni          (core_rst_n),
    .req_valid_i     (cache_req_valid),
    .req_write_i     (l2_req_write),
    .req_source_i    (l2_req_source),
    .req_paddr_w_i   (l2_req_paddr_w),
    .req_wdata_i     (l2_req_wdata),
    .req_ready_o     (l2_cache_req_ready),
    .resp_valid_o    (l2_cache_resp_valid),
    .resp_source_o   (l2_cache_resp_source),
    .resp_rdata_o    (l2_cache_resp_rdata),
    .mem_req_valid_o (mem_req_valid),
    .mem_req_write_o (mem_req_write),
    .mem_req_paddr_w_o(mem_req_paddr_w),
    .mem_req_wdata_o (mem_req_wdata),
    .mem_req_ready_i (mem_req_ready),
    .mem_resp_valid_i(mem_resp_valid),
    .mem_resp_rdata_i(mem_resp_rdata)
  );

  // --------------------------------------------------------------------------
  // Bus Interface Unit (BIU) - AXI4 Master
  // --------------------------------------------------------------------------
  sukuna_biu_axi4 #(
    .AXI_ADDR_WIDTH (AXI_ADDR_WIDTH),
    .AXI_DATA_WIDTH (AXI_DATA_WIDTH),
    .AXI_ID_WIDTH   (AXI_ID_WIDTH),
    .PADDR_WIDTH    (PADDR_WIDTH),
    .CACHE_LINE_BITS(CACHE_LINE_BITS)
  ) u_biu_axi4 (
    .clk_i           (clk_i),
    .rst_ni          (core_rst_n),
    .mem_req_valid_i (mem_req_valid),
    .mem_req_write_i (mem_req_write),
    .mem_req_paddr_w_i(mem_req_paddr_w),
    .mem_req_wdata_i (mem_req_wdata),
    .mem_req_ready_o (mem_req_ready),
    .mem_resp_valid_o(mem_resp_valid),
    .mem_resp_rdata_o(mem_resp_rdata),
    .m_axi_awvalid   (m_axi_awvalid),
    .m_axi_awready   (m_axi_awready),
    .m_axi_awaddr    (m_axi_awaddr),
    .m_axi_awid      (m_axi_awid),
    .m_axi_awlen     (m_axi_awlen),
    .m_axi_awsize    (m_axi_awsize),
    .m_axi_awburst   (m_axi_awburst),
    .m_axi_awlock    (m_axi_awlock),
    .m_axi_awcache   (m_axi_awcache),
    .m_axi_awprot    (m_axi_awprot),
    .m_axi_awqos     (m_axi_awqos),
    .m_axi_wvalid    (m_axi_wvalid),
    .m_axi_wready    (m_axi_wready),
    .m_axi_wdata     (m_axi_wdata),
    .m_axi_wstrb     (m_axi_wstrb),
    .m_axi_wlast     (m_axi_wlast),
    .m_axi_bvalid    (m_axi_bvalid),
    .m_axi_bready    (m_axi_bready),
    .m_axi_bid       (m_axi_bid),
    .m_axi_bresp     (m_axi_bresp),
    .m_axi_arvalid   (m_axi_arvalid),
    .m_axi_arready   (m_axi_arready),
    .m_axi_araddr    (m_axi_araddr),
    .m_axi_arid      (m_axi_arid),
    .m_axi_arlen     (m_axi_arlen),
    .m_axi_arsize    (m_axi_arsize),
    .m_axi_arburst   (m_axi_arburst),
    .m_axi_arlock    (m_axi_arlock),
    .m_axi_arcache   (m_axi_arcache),
    .m_axi_arprot    (m_axi_arprot),
    .m_axi_arqos     (m_axi_arqos),
    .m_axi_rvalid    (m_axi_rvalid),
    .m_axi_rready    (m_axi_rready),
    .m_axi_rid       (m_axi_rid),
    .m_axi_rdata     (m_axi_rdata),
    .m_axi_rresp     (m_axi_rresp),
    .m_axi_rlast     (m_axi_rlast)
  );

endmodule
