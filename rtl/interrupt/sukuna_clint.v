// ============================================================================
// Core Local Interruptor (CLINT) Stub (Verilog 2005)
// Generates timer and software interrupts for each Hart
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_clint #(
  parameter NUM_HARTS = `NUM_HARTS,
  parameter XLEN      = `XLEN
)(
  input  wire                   clk_i,
  input  wire                   rst_ni,

  // MMIO Access Interface
  input  wire                   req_valid_i,
  input  wire                   req_write_i,
  input  wire [XLEN-1:0]        req_addr_i,
  input  wire [XLEN-1:0]        req_wdata_i,
  input  wire [(XLEN/8)-1:0]    req_wstrb_i,
  output wire                   req_ready_o,
  output wire                   resp_valid_o,
  output wire [XLEN-1:0]        resp_rdata_o,

  // Interrupt outputs per Hart
  output wire [NUM_HARTS-1:0]   timer_irq_o,     // MTIP
  output wire [NUM_HARTS-1:0]   software_irq_o   // MSIP
);

  assign req_ready_o    = 1'b1;
  assign resp_valid_o   = req_valid_i;
  assign resp_rdata_o   = {XLEN{1'b0}};
  assign timer_irq_o    = {NUM_HARTS{1'b0}};
  assign software_irq_o = {NUM_HARTS{1'b0}};

endmodule
