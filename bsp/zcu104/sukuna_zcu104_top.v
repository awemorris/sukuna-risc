// ============================================================================
// Sukuna-RISC ZCU104 Board Top Wrapper (Verilog 2005)
// Target FPGA: AMD/Xilinx Zynq UltraScale+ (xczu7ev-ffvc1156-2-e)
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_zcu104_top (
  // 125MHz / 300MHz Differential System Clock
  input  wire        CLK_125_P,
  input  wire        CLK_125_N,

  // Active-High Push Button Reset (SW13 / CPU_RESET)
  input  wire        CPU_RESET,

  // USB UART
  input  wire        UART_RX,
  output wire        UART_TX,

  // 4 User LEDs
  output wire [3:0]  GPIO_LED
);

  wire sys_clk;
  wire rst_n = ~CPU_RESET;

`ifdef SYNTHESIS
  // UltraScale+ Differential Input Buffer
  IBUFDS #(
    .DIFF_TERM("FALSE"),
    .IBUF_LOW_PWR("FALSE")
  ) u_ibufds (
    .I (CLK_125_P),
    .IB(CLK_125_N),
    .O (sys_clk)
  );
`else
  assign sys_clk = CLK_125_P;
`endif

  // Heartbeat counter
  reg [25:0] heartbeat_cnt;
  always @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n) begin
      heartbeat_cnt <= 26'd0;
    end else begin
      heartbeat_cnt <= heartbeat_cnt + 26'd1;
    end
  end

  assign GPIO_LED[0]   = heartbeat_cnt[25];
  assign GPIO_LED[3:1] = 3'd0;
  assign UART_TX       = 1'b1;

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
