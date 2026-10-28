// ============================================================================
// Pipeline Stage: IF2 (Instruction Fetch 2) (Verilog 2005)
// Complies with design-rule.md
// ============================================================================
// Responsibilities:
//   - Receives 64-bit instruction fetch data from L1I cache
//   - Instantiates sk_rvc_dec for inline 16-to-32 bit decompression
//   - Extracts dual-issue candidate pair:
//     * Lane 0 (inst0): Decompressed instruction at if1_pc_i
//     * Lane 1 (inst1): Decompressed instruction at if1_pc_i + (is_rvc0 ? 2 : 4)
//   - Drives 32-bit normalized instruction bits directly to ID1
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

  // L1I Response Interface (64-bit instruction pair fetch block)
  input  wire             l1i_resp_valid_i,
  input  wire [63:0]      l1i_inst_i,
  input  wire             l1i_miss_i,

  // Pipeline registers to ID1 stage
  output reg              if2_valid0_o, /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]  if2_pc0_o,    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [31:0]      if2_inst0_o,  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  output reg              if2_valid1_o, /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]  if2_pc1_o,    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [31:0]      if2_inst1_o   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
);

  // --------------------------------------------------------------------------
  // Inline RVC Decompression
  // --------------------------------------------------------------------------
  wire [31:0] raw_inst0 = l1i_inst_i[31:0];
  wire [31:0] dec_inst0;
  wire        is_rvc0;
  wire        illegal0;

  sk_rvc_dec u_rvc_dec0 (
    .inst_i   (raw_inst0),
    .inst_o   (dec_inst0),
    .is_rvc_o (is_rvc0),
    .illegal_o(illegal0)
  );

  // Lane 1 start offset depends on whether Lane 0 was compressed (16-bit)
  wire [31:0] raw_inst1 = is_rvc0 ? l1i_inst_i[47:16] : l1i_inst_i[63:32];
  wire [31:0] dec_inst1;
  wire        is_rvc1;
  wire        illegal1;

  sk_rvc_dec u_rvc_dec1 (
    .inst_i   (raw_inst1),
    .inst_o   (dec_inst1),
    .is_rvc_o (is_rvc1),
    .illegal_o(illegal1)
  );

  wire [XLEN-1:0] pc1_calc = is_rvc0 ? (if1_pc_i + 64'd2) : (if1_pc_i + 64'd4);

  // --------------------------------------------------------------------------
  // Pipeline Registers to ID1
  // --------------------------------------------------------------------------
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
        // Lane 0: Older instruction
        if2_valid0_o <= if1_valid_i && l1i_resp_valid_i;
        if2_pc0_o    <= if1_pc_i;
        if2_inst0_o  <= dec_inst0;

        // Lane 1: Younger instruction
        if2_valid1_o <= if1_valid_i && l1i_resp_valid_i;
        if2_pc1_o    <= pc1_calc;
        if2_inst1_o  <= dec_inst1;
      end
    end
  end

  // Avoid unused variable warnings
  wire _unused = &{1'b0, l1i_miss_i, illegal0, illegal1, is_rvc1, 1'b0};

endmodule
