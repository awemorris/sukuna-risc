// ============================================================================
// Multi-Port Floating-Point Register File (FPR f0-f31) (Verilog 2005)
// Complies with design-rule.md:
//   - Array registers strictly instantiated using sk_ram_ff
//   - ZERO_REG0 = 0 (f0 is a general FP register, not hardwired to zero)
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_fregfile #(
  parameter XLEN = `XLEN
)(
  input  wire            clk_i,
  input  wire            rst_ni,

  // Read Port 1 (rs1)
  input  wire [4:0]      raddr_rs1_i,
  output wire [XLEN-1:0] rdata_rs1_o,

  // Read Port 2 (rs2)
  input  wire [4:0]      raddr_rs2_i,
  output wire [XLEN-1:0] rdata_rs2_o,

  // Write Port
  input  wire            wen_i,
  input  wire [4:0]      waddr_i,
  input  wire [XLEN-1:0] wdata_i
);

  sk_ram_ff #(
    .DATA_WIDTH(XLEN),
    .ADDR_WIDTH(5),
    .DEPTH     (32),
    .ZERO_REG0 (0)
  ) u_fpr_bank (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .wen_i    (wen_i),
    .waddr_i  (waddr_i),
    .wdata_i  (wdata_i),
    .wen1_i   (1'b0),
    .waddr1_i (5'd0),
    .wdata1_i ({XLEN{1'b0}}),
    .wen2_i   (1'b0),
    .waddr2_i (5'd0),
    .wdata2_i ({XLEN{1'b0}}),
    .raddr_a_i(raddr_rs1_i),
    .rdata_a_o(rdata_rs1_o),
    .raddr_b_i(raddr_rs2_i),
    .rdata_b_o(rdata_rs2_o)
  );

endmodule
