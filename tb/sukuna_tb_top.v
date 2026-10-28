// ============================================================================
// Sukuna-RISC: Master Testbench (Verilog 2005)
// ============================================================================
// Features:
//   - Drives clock and asynchronous reset
//   - Connects sukuna_top to sukuna_axi_mem model
//   - Loads hex program into AXI memory via +HEX=<file.hex>
//   - Monitors instruction commit in Thread 0
//   - Detects test completion / pass / fail
// ============================================================================

`timescale 1ns / 1ps
`include "sukuna_defines.vh"

module sukuna_tb_top;

  localparam CLK_PERIOD = 10; // 100 MHz

  reg clk;
  reg rst_n;
  reg enable;
  reg [31:0] ext_irq;

  // Clock generation
  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  // AXI4 Interconnect Wires
  wire        m_axi_awvalid;
  wire        m_axi_awready;
  wire [63:0] m_axi_awaddr;
  wire [7:0]  m_axi_awid;
  wire [7:0]  m_axi_awlen;
  wire [2:0]  m_axi_awsize;
  wire [1:0]  m_axi_awburst;
  wire        m_axi_awlock;
  wire [3:0]  m_axi_awcache;
  wire [2:0]  m_axi_awprot;
  wire [3:0]  m_axi_awqos;

  wire        m_axi_wvalid;
  wire        m_axi_wready;
  wire [127:0] m_axi_wdata;
  wire [15:0]  m_axi_wstrb;
  wire        m_axi_wlast;

  wire        m_axi_bvalid;
  wire        m_axi_bready;
  wire [7:0]  m_axi_bid;
  wire [1:0]  m_axi_bresp;

  wire        m_axi_arvalid;
  wire        m_axi_arready;
  wire [63:0] m_axi_araddr;
  wire [7:0]  m_axi_arid;
  wire [7:0]  m_axi_arlen;
  wire [2:0]  m_axi_arsize;
  wire [1:0]  m_axi_arburst;
  wire        m_axi_arlock;
  wire [3:0]  m_axi_arcache;
  wire [2:0]  m_axi_arprot;
  wire [3:0]  m_axi_arqos;

  wire        m_axi_rvalid;
  wire        m_axi_rready;
  wire [7:0]  m_axi_rid;
  wire [127:0] m_axi_rdata;
  wire [1:0]  m_axi_rresp;
  wire        m_axi_rlast;

  // --------------------------------------------------------------------------
  // CPU Top Instantiation
  // --------------------------------------------------------------------------
  sukuna_top #(
    .RESET_PC(64'h0000_0000_8000_0000)
  ) dut (
    .clk_i        (clk),
    .rst_ni       (rst_n),
    .enable_i     (enable),
    .ext_irq_i    (ext_irq),
    .m_axi_awvalid(m_axi_awvalid),
    .m_axi_awready(m_axi_awready),
    .m_axi_awaddr (m_axi_awaddr),
    .m_axi_awid   (m_axi_awid),
    .m_axi_awlen  (m_axi_awlen),
    .m_axi_awsize (m_axi_awsize),
    .m_axi_awburst(m_axi_awburst),
    .m_axi_awlock (m_axi_awlock),
    .m_axi_awcache(m_axi_awcache),
    .m_axi_awprot (m_axi_awprot),
    .m_axi_awqos  (m_axi_awqos),
    .m_axi_wvalid (m_axi_wvalid),
    .m_axi_wready (m_axi_wready),
    .m_axi_wdata  (m_axi_wdata),
    .m_axi_wstrb  (m_axi_wstrb),
    .m_axi_wlast  (m_axi_wlast),
    .m_axi_bvalid (m_axi_bvalid),
    .m_axi_bready (m_axi_bready),
    .m_axi_bid    (m_axi_bid),
    .m_axi_bresp  (m_axi_bresp),
    .m_axi_arvalid(m_axi_arvalid),
    .m_axi_arready(m_axi_arready),
    .m_axi_araddr (m_axi_araddr),
    .m_axi_arid   (m_axi_arid),
    .m_axi_arlen  (m_axi_arlen),
    .m_axi_arsize (m_axi_arsize),
    .m_axi_arburst(m_axi_arburst),
    .m_axi_arlock (m_axi_arlock),
    .m_axi_arcache(m_axi_arcache),
    .m_axi_arprot (m_axi_arprot),
    .m_axi_arqos  (m_axi_arqos),
    .m_axi_rvalid (m_axi_rvalid),
    .m_axi_rready (m_axi_rready),
    .m_axi_rid    (m_axi_rid),
    .m_axi_rdata  (m_axi_rdata),
    .m_axi_rresp  (m_axi_rresp),
    .m_axi_rlast  (m_axi_rlast)
  );

  // --------------------------------------------------------------------------
  // AXI4 Simulation Memory Instantiation
  // --------------------------------------------------------------------------
  sukuna_axi_mem #(
    .MEM_SIZE_BYTES(65536),
    .BASE_ADDR     (64'h0000_0000_8000_0000)
  ) u_mem (
    .clk_i        (clk),
    .rst_ni       (rst_n),
    .s_axi_awvalid(m_axi_awvalid),
    .s_axi_awready(m_axi_awready),
    .s_axi_awaddr (m_axi_awaddr),
    .s_axi_awid   (m_axi_awid),
    .s_axi_awlen  (m_axi_awlen),
    .s_axi_awsize (m_axi_awsize),
    .s_axi_awburst(m_axi_awburst),
    .s_axi_wvalid (m_axi_wvalid),
    .s_axi_wready (m_axi_wready),
    .s_axi_wdata  (m_axi_wdata),
    .s_axi_wstrb  (m_axi_wstrb),
    .s_axi_wlast  (m_axi_wlast),
    .s_axi_bvalid (m_axi_bvalid),
    .s_axi_bready (m_axi_bready),
    .s_axi_bid    (m_axi_bid),
    .s_axi_bresp  (m_axi_bresp),
    .s_axi_arvalid(m_axi_arvalid),
    .s_axi_arready(m_axi_arready),
    .s_axi_araddr (m_axi_araddr),
    .s_axi_arid   (m_axi_arid),
    .s_axi_arlen  (m_axi_arlen),
    .s_axi_arsize (m_axi_arsize),
    .s_axi_arburst(m_axi_arburst),
    .s_axi_rvalid (m_axi_rvalid),
    .s_axi_rready (m_axi_rready),
    .s_axi_rid    (m_axi_rid),
    .s_axi_rdata  (m_axi_rdata),
    .s_axi_rresp  (m_axi_rresp),
    .s_axi_rlast  (m_axi_rlast)
  );

  // --------------------------------------------------------------------------
  // Test Sequence & Hex Loading
  // --------------------------------------------------------------------------
  reg [1023:0] hex_file;
  integer cycle_count;

  initial begin
    rst_n   = 1'b0;
    enable  = 1'b0;
    ext_irq = 32'd0;
    cycle_count = 0;

    // Load program from +HEX=<file>
    if ($value$plusargs("HEX=%s", hex_file)) begin
      $display("[TB] Loading HEX program: %0s", hex_file);
      $readmemh(hex_file, u_mem.mem);
    end else begin
      $display("[TB] No +HEX specified. Using default test program in memory.");
      // Initialize with simple test instructions:
      // Word 0: 4 instructions (128-bit)
      // PC 0x80000000: addi x1, x0, 10   (0x00a00093)
      // PC 0x80000004: addi x2, x0, 20   (0x01400113)
      // PC 0x80000008: add  x3, x1, x2   (0x002081b3) (x3 = 30)
      // PC 0x8000000C: slli x4, x3, 2    (0x00219213) (x4 = 120)
      u_mem.mem[0] = {32'h00219213, 32'h002081b3, 32'h01400113, 32'h00a00093};
      // Word 1:
      // PC 0x80000010: addi x5, x0, 120  (0x07800293)
      // PC 0x80000014: sub  x6, x4, x5   (0x40520333) (x6 = 0)
      // PC 0x80000018: beq  x6, x0, 8    (0x00030463) -> jump to 0x80000020
      // PC 0x8000001C: addi x10, x0, 1   (0x00100513) (Fail)
      u_mem.mem[1] = {32'h00100513, 32'h00030463, 32'h40520333, 32'h07800293};
      // Word 2:
      // PC 0x80000020: addi x10, x0, 0   (0x00000513) (Success)
      // PC 0x80000024: ecall             (0x00000073)
      // PC 0x80000028: j .               (0x0000006f)
      u_mem.mem[2] = {32'h0000006f, 32'h0000006f, 32'h00000073, 32'h00000513};
    end

    // Reset sequence
    repeat (10) @(posedge clk);
    rst_n  = 1'b1;
    enable = 1'b1;
    $display("[TB] Reset released, CPU core started at PC=0x8000_0000");

    // Timeout watchdog (max 2000 cycles for basic test)
    while (cycle_count < 50) begin
      @(posedge clk);
      cycle_count = cycle_count + 1;
      if (cycle_count < 25) begin
        $display("[CYCLE %0d] PC=0x%08h stall_if1=%b l1i_miss=%b l1i_refill_req=%b l2_req_val=%b l2_req_rdy=%b l2_state=%0d biu_arvalid=%b axi_arready=%b rvalid=%b",
                 cycle_count,
                 dut.u_core.gen_threads[0].u_thread.u_if1.pc_q[31:0],
                 dut.u_core.gen_threads[0].u_thread.stall_if1,
                 dut.u_core.gen_threads[0].u_thread.l1i_miss_i,
                 dut.u_core.u_l1_subsys.gen_l1_caches[0].u_l1i.refill_req_valid_o,
                 dut.u_core.u_l1_subsys.u_l2_arb.l2_req_valid_o,
                 dut.u_l2_cache.req_ready_o,
                 dut.u_l2_cache.state_q,
                 dut.u_biu_axi4.m_axi_arvalid,
                 dut.m_axi_arready,
                 dut.m_axi_rvalid);
      end
    end

    $display("[TB] Simulation reached timeout (%0d cycles).", cycle_count);
    $finish;
  end

  // --------------------------------------------------------------------------
  // Instruction Commit Monitor for Hart 0
  // --------------------------------------------------------------------------
  wire wb_l0_valid = dut.u_core.gen_threads[0].u_thread.ex_wb_l0_valid;
  wire [63:0] wb_l0_pc = dut.u_core.gen_threads[0].u_thread.ex_wb_l0_pc;
  wire [4:0]  wb_l0_rd = dut.u_core.gen_threads[0].u_thread.ex_wb_l0_rd;
  wire [63:0] wb_l0_data = dut.u_core.gen_threads[0].u_thread.ex_wb_l0_data;

  wire wb_l1_valid = dut.u_core.gen_threads[0].u_thread.ex_wb_l1_valid;
  wire [63:0] wb_l1_pc = dut.u_core.gen_threads[0].u_thread.ex_wb_l1_pc;
  wire [4:0]  wb_l1_rd = dut.u_core.gen_threads[0].u_thread.ex_wb_l1_rd;
  wire [63:0] wb_l1_data = dut.u_core.gen_threads[0].u_thread.ex_wb_l1_data;

  always @(posedge clk) begin
    if (rst_n) begin
      if (wb_l0_valid) begin
        $display("[CYCLE %0t] COMMIT [L0] PC=0x%016h x%0d = 0x%016h", $time, wb_l0_pc, wb_l0_rd, wb_l0_data);
      end
      if (wb_l1_valid) begin
        $display("[CYCLE %0t] COMMIT [L1] PC=0x%016h x%0d = 0x%016h", $time, wb_l1_pc, wb_l1_rd, wb_l1_data);
      end

      // Check success condition: x10 == 0 at ecall or PC=0x80000020
      if (wb_l0_valid && wb_l0_pc == 64'h80000020 && wb_l0_rd == 5'd10 && wb_l0_data == 64'd0) begin
        $display("\n=======================================================");
        $display("[TB SUCCESS] Basic RISC-V instructions executed successfully!");
        $display("=======================================================\n");
        $finish;
      end
    end
  end

endmodule
