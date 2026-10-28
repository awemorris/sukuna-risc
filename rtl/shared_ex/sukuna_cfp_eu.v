// ============================================================================
// Complex FP Execution Unit (CFP-EU1) Stub (Verilog 2005)
// Handles multi-cycle / variable-latency FDIV, FSQRT operations
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_cfp_eu #(
  parameter XLEN = `XLEN
)(
  input  wire             clk_i,
  input  wire             rst_ni,

  input  wire             req_valid_i,
  input  wire [1:0]       req_hart_id_i,
  input  wire [4:0]       req_rd_i,
  input  wire [XLEN-1:0]  req_src1_i,
  input  wire [XLEN-1:0]  req_src2_i,
  output reg              busy_o,

  output reg              resp_valid_o,
  output reg  [1:0]       resp_hart_id_o,
  output reg  [4:0]       resp_rd_o,
  output reg  [XLEN-1:0]  resp_data_o
);

  // Simple multi-cycle dummy counter
  reg [2:0] cycle_cnt; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      busy_o         <= 1'b0;
      resp_valid_o   <= 1'b0;
      resp_hart_id_o <= 2'b00;
      resp_rd_o      <= 5'd0;
      resp_data_o    <= {XLEN{1'b0}};
      cycle_cnt      <= 3'd0;
    end else begin
      resp_valid_o <= 1'b0;
      if (req_valid_i && !busy_o) begin
        busy_o         <= 1'b1;
        cycle_cnt      <= 3'd4;
        resp_hart_id_o <= req_hart_id_i;
        resp_rd_o      <= req_rd_i;
        resp_data_o    <= req_src1_i;
      end else if (busy_o) begin
        if (cycle_cnt == 3'd1) begin
          busy_o       <= 1'b0;
          resp_valid_o <= 1'b1;
        end
        cycle_cnt <= cycle_cnt - 3'd1;
      end
    end
  end

endmodule
