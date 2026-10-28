// ============================================================================
// Reset Synchronizer (Asynchronous Assert, Synchronous Deassert) (Verilog 2005)
// Complies with design-rule.md
// Prevents metastability by releasing reset synchronously to clk_i
// ============================================================================

`include "sukuna_defines.vh"

module sk_rst_sync (
  input  wire clk_i,
  input  wire async_rst_ni, // External asynchronous active-low reset
  output wire sync_rst_no   // Synchronized active-low reset output
);

  reg [2:0] rst_sync_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  always @(posedge clk_i or negedge async_rst_ni) begin
    if (!async_rst_ni) begin
      rst_sync_q <= 3'b000;
    end else begin
      rst_sync_q <= {rst_sync_q[1:0], 1'b1};
    end
  end

  assign sync_rst_no = rst_sync_q[2];

endmodule
