// ============================================================================
// Dedicated 1-Cycle Integer Execution Unit (INT-EU) Stub (Verilog 2005)
// 1:1 mapped to thread, 1-cycle latency arithmetic/logic operations
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_int_eu #(
  parameter XLEN = `XLEN
)(
  input  wire             clk_i,
  input  wire             rst_ni,

  input  wire             valid_i,
  input  wire [3:0]       alu_op_i,
  input  wire [XLEN-1:0]  src1_i,
  input  wire [XLEN-1:0]  src2_i,
  input  wire [4:0]       rd_i,

  output reg              valid_o,
  output reg  [4:0]       rd_o,
  output reg  [XLEN-1:0]  result_o
);

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid_o  <= 1'b0;
      rd_o     <= 5'd0;
      result_o <= {XLEN{1'b0}};
    end else begin
      valid_o <= valid_i;
      rd_o    <= rd_i;
      case (alu_op_i)
        `ALU_ADD:  result_o <= src1_i + src2_i;
        `ALU_SUB:  result_o <= src1_i - src2_i;
        `ALU_SLL:  result_o <= src1_i << src2_i[5:0];
        `ALU_SLT:  result_o <= ($signed(src1_i) < $signed(src2_i)) ? 64'd1 : 64'd0;
        `ALU_SLTU: result_o <= (src1_i < src2_i) ? 64'd1 : 64'd0;
        `ALU_XOR:  result_o <= src1_i ^ src2_i;
        `ALU_SRL:  result_o <= src1_i >> src2_i[5:0];
        `ALU_SRA:  result_o <= $signed(src1_i) >>> src2_i[5:0];
        `ALU_OR:   result_o <= src1_i | src2_i;
        `ALU_AND:  result_o <= src1_i & src2_i;
        default:   result_o <= src1_i + src2_i;
      endcase
    end
  end

endmodule
