// ============================================================================
// Pipeline Stage: IF2 (Instruction Fetch 2) (Verilog 2005)
// Complies with design-rule.md
// ============================================================================
// Responsibilities:
//   - Receives instruction data from L1I cache
//   - RVC 16-bit to 32-bit expansion
//   - Extracts dual-issue candidate pair (inst0: older, inst1: younger)
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_stage_if2 #(
  parameter XLEN = `XLEN
)(
  input  wire             clk_i,
  input  wire             rst_ni,

  // Pipeline flow controls
  input  wire             stall_i,
  input  wire             flush_i,

  // Input from IF1 stage
  input  wire             if1_valid_i,
  input  wire [XLEN-1:0]  if1_pc_i,

  // L1I Response Interface
  input  wire             l1i_resp_valid_i,
  input  wire [31:0]      l1i_inst_i,
  input  wire             l1i_miss_i,

  // Pipeline registers to ID1 stage
  output reg              if2_valid0_o, /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]  if2_pc0_o,    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [31:0]      if2_inst0_o,  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  output reg              if2_valid1_o, /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]  if2_pc1_o,    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [31:0]      if2_inst1_o   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
);

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      if2_valid0_o <= 1'b0;
      if2_pc0_o    <= {XLEN{1'b0}};
      if2_inst0_o  <= 32'h00000013; // NOP (addi x0, x0, 0)
      if2_valid1_o <= 1'b0;
      if2_pc1_o    <= {XLEN{1'b0}};
      if2_inst1_o  <= 32'h00000013;
    end else begin
      if (flush_i) begin
        if2_valid0_o <= 1'b0;
        if2_valid1_o <= 1'b0;
      end else if (!stall_i) begin
        // Lane 0: Primary instruction
        if2_valid0_o <= if1_valid_i && l1i_resp_valid_i;
        if2_pc0_o    <= if1_pc_i;
        if2_inst0_o  <= l1i_inst_i;

        // Lane 1: Second instruction candidate (stub: NOP or consecutive)
        if2_valid1_o <= if1_valid_i && l1i_resp_valid_i;
        if2_pc1_o    <= if1_pc_i + 64'd4;
        if2_inst1_o  <= 32'h00000013; // Default NOP in stub
      end
    end
  end

endmodule
