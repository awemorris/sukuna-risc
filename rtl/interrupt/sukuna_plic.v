// ============================================================================
// Platform-Level Interrupt Controller (PLIC) Stub (Verilog 2005)
// Routes external interrupts to Harts (Prioritizing Hart 0 Kernel)
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_plic #(
  parameter NUM_SOURCES = 32,
  parameter NUM_HARTS   = `NUM_HARTS,
  parameter XLEN        = `XLEN
)(
  input  wire                   clk_i,
  input  wire                   rst_ni,

  // External Interrupt Sources
  input  wire [NUM_SOURCES-1:0] ext_irq_i,

  // MMIO Interface
  input  wire                   req_valid_i,
  input  wire                   req_write_i,
  input  wire [XLEN-1:0]        req_addr_i,
  input  wire [XLEN-1:0]        req_wdata_i,
  input  wire [(XLEN/8)-1:0]    req_wstrb_i,
  output wire                   req_ready_o,
  output wire                   resp_valid_o,
  output wire [XLEN-1:0]        resp_rdata_o,

  // External Interrupt Notifications per Hart (M-mode & S-mode)
  output wire [NUM_HARTS-1:0]   meip_o,
  output wire [NUM_HARTS-1:0]   seip_o
);

  assign req_ready_o  = 1'b1;
  assign resp_valid_o = req_valid_i;
  assign resp_rdata_o = {XLEN{1'b0}};

  // Priority routing: external interrupts trigger Hart 0 (Kernel)
  assign meip_o[0]              = |ext_irq_i;
  assign meip_o[NUM_HARTS-1:1]  = {(NUM_HARTS-1){1'b0}};
  assign seip_o                 = {NUM_HARTS{1'b0}};

endmodule
