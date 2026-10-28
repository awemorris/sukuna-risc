// ============================================================================
// Pipeline Stage: IF1 (Instruction Fetch 1) (Verilog 2005)
// Complies with design-rule.md
// ============================================================================
// Responsibilities:
//   - PC generation (Sequential +4 / +8, Branch prediction, Trap redirect)
//   - L1-ITLB virtual address translation request
//   - L1I instruction cache read request with word-aligned address [PADDR_WIDTH-1:2]
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_stage_if1 #(
  parameter HART_ID     = 0,
  parameter XLEN        = `XLEN,
  parameter VADDR_WIDTH = `VADDR_WIDTH,
  parameter PADDR_WIDTH = `PADDR_WIDTH
)(
  input  wire                   clk_i,
  input  wire                   rst_ni,

  // Pipeline flow controls
  input  wire                   stall_i,
  input  wire                   flush_i,
  input  wire [XLEN-1:0]        redirect_pc_i,

  // Consumed instruction count from ID (0: none/stall, 1: one inst, 2: two insts)
  input  wire [1:0]             fetch_step_i,

  // L1-ITLB Translation Interface (Word-aligned: bits [1:0] omitted)
  output wire                   itlb_req_valid_o,
  output wire [VADDR_WIDTH-1:2] itlb_vaddr_w_o,
  input  wire                   itlb_hit_i,
  input  wire [PADDR_WIDTH-1:2] itlb_paddr_w_i,
  input  wire                   itlb_fault_i,

  // L1I Cache Request Interface (Word-aligned: lower 2 bits omitted)
  output wire                   l1i_req_valid_o,
  output wire [PADDR_WIDTH-1:2] l1i_paddr_w_o,

  // Pipeline registers to IF2
  output reg                    if1_valid_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]        if1_pc_o       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
);

  reg [XLEN-1:0] pc_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // Request virtual address to ITLB (word-aligned)
  assign itlb_req_valid_o = !stall_i;
  assign itlb_vaddr_w_o   = pc_q[VADDR_WIDTH-1:2];

  // Physical address request to L1I (Word-aligned)
  assign l1i_req_valid_o  = itlb_hit_i && !stall_i;
  assign l1i_paddr_w_o    = itlb_paddr_w_i;

  // Next PC calculation
  wire [XLEN-1:0] pc_incr = (fetch_step_i == 2'd2) ? 64'd8 :
                            (fetch_step_i == 2'd1) ? 64'd4 : 64'd4;

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pc_q        <= {XLEN{1'b0}};
      if1_valid_o <= 1'b0;
      if1_pc_o    <= {XLEN{1'b0}};
    end else if (flush_i) begin
      pc_q        <= redirect_pc_i;
      if1_valid_o <= 1'b0;
    end else if (!stall_i) begin
      pc_q        <= pc_q + pc_incr;
      if1_valid_o <= 1'b1;
      if1_pc_o    <= pc_q;
    end
  end

endmodule
