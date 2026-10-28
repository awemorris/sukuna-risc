// ============================================================================
// Sukuna-RISC KC705 Board Top Wrapper (Verilog 2005)
// Target FPGA: AMD/Xilinx Kintex-7 (xc7k325tffg900-2)
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_kc705_top (
  // 200MHz Differential System Clock
  input  wire        SYSCLK_P,
  input  wire        SYSCLK_N,

  // Active-High Push Button Reset (SW5 / CPU_RESET)
  input  wire        CPU_RESET,

  // UART USB-RS232
  input  wire        USB_UART_RX,
  output wire        USB_UART_TX,

  // 8 User LEDs
  output wire [7:0]  GPIO_LED
);

  // Clock generation (behavioral or IBUFGDS for synthesis)
  wire sys_clk;
  wire rst_n = ~CPU_RESET;

`ifdef SYNTHESIS
  // Xilinx 7-Series Differential Clock Buffer
  IBUFGDS #(
    .DIFF_TERM    ("TRUE"),
    .IBUF_LOW_PWR ("FALSE"),
    .IOSTANDARD   ("LVDS_25")
  ) u_ibufgds (
    .I  (SYSCLK_P),
    .IB (SYSCLK_N),
    .O  (sys_clk)
  );
`else
  assign sys_clk = SYSCLK_P;
`endif

  // Heartbeat LED counter
  reg [26:0] heartbeat_cnt;
  always @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n) begin
      heartbeat_cnt <= 27'd0;
    end else begin
      heartbeat_cnt <= heartbeat_cnt + 27'd1;
    end
  end

  assign GPIO_LED[0]   = heartbeat_cnt[26];
  assign GPIO_LED[7:1] = 7'd0;
  assign USB_UART_TX   = 1'b1; // Idle high

  // Sukuna CPU Top Instance
  sukuna_top #(
    .NUM_SOURCES    (32),
    .NUM_HARTS      (`NUM_HARTS),
    .XLEN           (`XLEN),
    .VADDR_WIDTH    (`VADDR_WIDTH),
    .PADDR_WIDTH    (`PADDR_WIDTH),
    .CACHE_LINE_BITS(`CACHE_LINE_BITS),
    .AXI_ADDR_WIDTH (`AXI_ADDR_WIDTH),
    .AXI_DATA_WIDTH (`AXI_DATA_WIDTH),
    .AXI_ID_WIDTH   (`AXI_ID_WIDTH)
  ) u_cpu (
    .clk_i        (sys_clk),
    .rst_ni       (rst_n),
    .enable_i     (1'b1),
    .ext_irq_i    (32'd0),

    // AXI4 Loopback / Termination stubs for BSP testing
    .m_axi_awvalid(),
    .m_axi_awready(1'b1),
    .m_axi_awaddr (),
    .m_axi_awid   (),
    .m_axi_awlen  (),
    .m_axi_awsize (),
    .m_axi_awburst(),
    .m_axi_awlock (),
    .m_axi_awcache(),
    .m_axi_awprot (),
    .m_axi_awqos  (),
    .m_axi_wvalid (),
    .m_axi_wready (1'b1),
    .m_axi_wdata  (),
    .m_axi_wstrb  (),
    .m_axi_wlast  (),
    .m_axi_bvalid (1'b0),
    .m_axi_bready (),
    .m_axi_bid    (8'd0),
    .m_axi_bresp  (2'b00),
    .m_axi_arvalid(),
    .m_axi_arready(1'b1),
    .m_axi_araddr (),
    .m_axi_arid   (),
    .m_axi_arlen  (),
    .m_axi_arsize (),
    .m_axi_arburst(),
    .m_axi_arlock (),
    .m_axi_arcache(),
    .m_axi_arprot (),
    .m_axi_arqos  (),
    .m_axi_rvalid (1'b0),
    .m_axi_rready (),
    .m_axi_rid    (8'd0),
    .m_axi_rdata  ({`AXI_DATA_WIDTH{1'b0}}),
    .m_axi_rresp  (2'b00),
    .m_axi_rlast  (1'b0)
  );

endmodule
