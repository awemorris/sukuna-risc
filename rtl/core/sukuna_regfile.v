// ============================================================================
// Multi-Port Integer Register File (GPR) (Verilog 2005)
// Complies with design-rule.md:
//   - Array registers strictly instantiated using sukuna_ram_ff
//   - Dual-bank replication for 4 concurrent asynchronous read ports
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_regfile #(
  parameter XLEN = `XLEN
)(
  input  wire             clk_i,
  input  wire             rst_ni,

  // Slot 0 Read Ports (Asynchronous)
  input  wire [4:0]       raddr_s0_rs1_i,
  output wire [XLEN-1:0]  rdata_s0_rs1_o,
  input  wire [4:0]       raddr_s0_rs2_i,
  output wire [XLEN-1:0]  rdata_s0_rs2_o,

  // Slot 1 Read Ports (Asynchronous)
  input  wire [4:0]       raddr_s1_rs1_i,
  output wire [XLEN-1:0]  rdata_s1_rs1_o,
  input  wire [4:0]       raddr_s1_rs2_i,
  output wire [XLEN-1:0]  rdata_s1_rs2_o,

  // Write Port 0 (Slot 0 INT WB)
  input  wire             wen_p0_i,
  input  wire [4:0]       waddr_p0_i,
  input  wire [XLEN-1:0]  wdata_p0_i,

  // Write Port 1 (Slot 1 MA Load WB)
  input  wire             wen_p1_i,
  input  wire [4:0]       waddr_p1_i,
  input  wire [XLEN-1:0]  wdata_p1_i,

  // Write Port 2 (Shared EU WB)
  input  wire             wen_p2_i,
  input  wire [4:0]       waddr_p2_i,
  input  wire [XLEN-1:0]  wdata_p2_i
);

  // Write arbitration / priority for replicated banks
  wire             we_active   = wen_p0_i | wen_p1_i | wen_p2_i;
  wire [4:0]       waddr_mux   = wen_p0_i ? waddr_p0_i :
                                 wen_p1_i ? waddr_p1_i : waddr_p2_i;
  wire [XLEN-1:0]  wdata_mux   = wen_p0_i ? wdata_p0_i :
                                 wen_p1_i ? wdata_p1_i : wdata_p2_i;

  // Bank 0: Serves Slot 0 reads (rs1, rs2)
  sukuna_ram_ff #(
    .DATA_WIDTH(XLEN),
    .ADDR_WIDTH(5),
    .DEPTH     (32),
    .ZERO_REG0 (1)
  ) u_bank0 (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .wen_i    (we_active),
    .waddr_i  (waddr_mux),
    .wdata_i  (wdata_mux),
    .raddr_a_i(raddr_s0_rs1_i),
    .rdata_a_o(rdata_s0_rs1_o),
    .raddr_b_i(raddr_s0_rs2_i),
    .rdata_b_o(rdata_s0_rs2_o)
  );

  // Bank 1: Serves Slot 1 reads (rs1, rs2)
  sukuna_ram_ff #(
    .DATA_WIDTH(XLEN),
    .ADDR_WIDTH(5),
    .DEPTH     (32),
    .ZERO_REG0 (1)
  ) u_bank1 (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .wen_i    (we_active),
    .waddr_i  (waddr_mux),
    .wdata_i  (wdata_mux),
    .raddr_a_i(raddr_s1_rs1_i),
    .rdata_a_o(rdata_s1_rs1_o),
    .raddr_b_i(raddr_s1_rs2_i),
    .rdata_b_o(rdata_s1_rs2_o)
  );

endmodule
