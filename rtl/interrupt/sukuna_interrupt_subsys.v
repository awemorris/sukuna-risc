// ============================================================================
// Interrupt Subsystem Wrapper (Verilog 2005)
// Integrates CLINT (Core Local Interrupts) and PLIC (Platform-Level Interrupts)
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_interrupt_subsys #(
  parameter NUM_SOURCES = 32,
  parameter NUM_HARTS   = `NUM_HARTS,
  parameter XLEN        = `XLEN
)(
  input  wire                   clk_i,
  input  wire                   rst_ni,

  // External Interrupt lines
  input  wire [NUM_SOURCES-1:0] ext_irq_i,

  // MMIO Interface from System Interconnect
  input  wire                   mmio_req_valid_i,
  input  wire                   mmio_req_write_i,
  input  wire [XLEN-1:0]        mmio_req_addr_i,
  input  wire [XLEN-1:0]        mmio_req_wdata_i,
  input  wire [(XLEN/8)-1:0]    mmio_req_wstrb_i,
  output wire                   mmio_req_ready_o,
  output wire                   mmio_resp_valid_o,
  output wire [XLEN-1:0]        mmio_resp_rdata_o,

  // Interrupts distributed to Harts
  output wire [NUM_HARTS-1:0]   meip_o,
  output wire [NUM_HARTS-1:0]   seip_o,
  output wire [NUM_HARTS-1:0]   mtip_o,
  output wire [NUM_HARTS-1:0]   msip_o
);

  wire clint_req_valid = mmio_req_valid_i && (mmio_req_addr_i[31:24] == 8'h02);
  wire plic_req_valid  = mmio_req_valid_i && (mmio_req_addr_i[31:24] == 8'h0C);

  wire clint_req_ready, clint_resp_valid;
  wire [XLEN-1:0] clint_resp_rdata;
  wire plic_req_ready, plic_resp_valid;
  wire [XLEN-1:0] plic_resp_rdata;

  sukuna_clint #(
    .NUM_HARTS(NUM_HARTS),
    .XLEN     (XLEN)
  ) u_clint (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .req_valid_i    (clint_req_valid),
    .req_write_i    (mmio_req_write_i),
    .req_addr_i     (mmio_req_addr_i),
    .req_wdata_i    (mmio_req_wdata_i),
    .req_wstrb_i    (mmio_req_wstrb_i),
    .req_ready_o    (clint_req_ready),
    .resp_valid_o   (clint_resp_valid),
    .resp_rdata_o   (clint_resp_rdata),
    .timer_irq_o    (mtip_o),
    .software_irq_o (msip_o)
  );

  sukuna_plic #(
    .NUM_SOURCES(NUM_SOURCES),
    .NUM_HARTS  (NUM_HARTS),
    .XLEN       (XLEN)
  ) u_plic (
    .clk_i        (clk_i),
    .rst_ni       (rst_ni),
    .ext_irq_i    (ext_irq_i),
    .req_valid_i  (plic_req_valid),
    .req_write_i  (mmio_req_write_i),
    .req_addr_i   (mmio_req_addr_i),
    .req_wdata_i  (mmio_req_wdata_i),
    .req_wstrb_i  (mmio_req_wstrb_i),
    .req_ready_o  (plic_req_ready),
    .resp_valid_o (plic_resp_valid),
    .resp_rdata_o (plic_resp_rdata),
    .meip_o       (meip_o),
    .seip_o       (seip_o)
  );

  assign mmio_req_ready_o  = clint_req_ready | plic_req_ready;
  assign mmio_resp_valid_o = clint_resp_valid | plic_resp_valid;
  assign mmio_resp_rdata_o = clint_resp_valid ? clint_resp_rdata : plic_resp_rdata;

endmodule
