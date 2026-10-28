// ============================================================================
// SIMD / Vector Execution Unit (SIMD-EU1) Stub (Verilog 2005)
// Separated Vector Register File and multi-cycle execution engine
// Complies with design-rule.md:
//   - Array registers (> 128-bit) instantiate sukuna_ram_ff
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_simd_eu #(
  parameter XLEN       = `XLEN,
  parameter VLEN       = 128,
  parameter NUM_VREGS  = 32
)(
  input  wire             clk_i,
  input  wire             rst_ni,

  input  wire             req_valid_i,
  input  wire [1:0]       req_hart_id_i,
  input  wire [4:0]       req_rd_i,
  input  wire [XLEN-1:0]  req_src1_i,
  input  wire [XLEN-1:0]  req_src2_i,
  output reg              busy_o,

  // Writeback back to scalar pipeline (e.g. vmv.x.s)
  output reg              scalar_resp_valid_o,
  output reg  [1:0]       scalar_resp_hart_id_o,
  output reg  [4:0]       scalar_resp_rd_o,
  output reg  [XLEN-1:0]  scalar_resp_data_o
);

  // Dedicated Vector Register File (instantiated RAM macro)
  wire [VLEN-1:0] vrdata_a;
  wire [VLEN-1:0] vrdata_b;

  sukuna_ram_ff #(
    .DATA_WIDTH(VLEN),
    .ADDR_WIDTH(5),
    .DEPTH     (NUM_VREGS),
    .ZERO_REG0 (0)
  ) u_vreg_file (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .wen_i    (1'b0),
    .waddr_i  (5'd0),
    .wdata_i  ({VLEN{1'b0}}),
    .raddr_a_i(req_src1_i[4:0]),
    .rdata_a_o(vrdata_a),
    .raddr_b_i(req_src2_i[4:0]),
    .rdata_b_o(vrdata_b)
  );

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      busy_o                <= 1'b0;
      scalar_resp_valid_o   <= 1'b0;
      scalar_resp_hart_id_o <= 2'b00;
      scalar_resp_rd_o      <= 5'd0;
      scalar_resp_data_o    <= {XLEN{1'b0}};
    end else begin
      scalar_resp_valid_o   <= 1'b0;
      if (req_valid_i && !busy_o) begin
        busy_o                <= 1'b1;
        scalar_resp_hart_id_o <= req_hart_id_i;
        scalar_resp_rd_o      <= req_rd_i;
        scalar_resp_data_o    <= req_src1_i;
      end else if (busy_o) begin
        busy_o              <= 1'b0;
        scalar_resp_valid_o <= 1'b1;
      end
    end
  end

endmodule
