// ============================================================================
// Pipeline Stage: IF1 (Instruction Fetch 1) (Verilog 2005)
// Complies with design-rule.md & style.md
// ============================================================================
// Responsibilities:
//   - Generates strictly 8-byte aligned fetch addresses (PC[2:0] == 3'b000)
//   - Zero-MUX fetch address selection: sequential (+8) vs redirect (branch/trap)
//   - ITLB virtual address translation request
//   - L1I instruction cache read request
//   - 1-cycle pipeline register to IF2: if1_valid_o, if1_pc_o, if1_odd_o
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_stage_if1 #(
  parameter HART_ID     = 0,
  parameter XLEN        = `XLEN,
  parameter VADDR_WIDTH = `VADDR_WIDTH,
  parameter PADDR_WIDTH = `PADDR_WIDTH,
  parameter RESET_PC    = 64'h0000_0000_8000_0000
)(
  input  wire                   clk_i,
  input  wire                   rst_ni,

  // Pipeline flow controls
  input  wire                   stall_i,
  input  wire                   flush_i,
  input  wire [XLEN-1:0]        redirect_pc_i,
  input  wire                   wfi_sleep_i,

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
  output reg                    if1_valid_o, /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]        if1_pc_o,    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg                    if1_odd_o    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
);

  reg [XLEN-1:0] pc_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // Strictly 8-byte aligned fetch address (always even address: PC[2:0] == 3'b000)
  wire [XLEN-1:0] curr_req_vaddr = flush_i ? {redirect_pc_i[XLEN-1:3], 3'b000} : pc_q;
  wire            req_active     = rst_ni && (flush_i || !stall_i) && !wfi_sleep_i;

  // ITLB translation request
  assign itlb_req_valid_o = req_active;
  assign itlb_vaddr_w_o   = curr_req_vaddr[VADDR_WIDTH-1:2];

  // L1I cache read request
  assign l1i_req_valid_o  = itlb_hit_i && req_active;
  assign l1i_paddr_w_o    = itlb_paddr_w_i;

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pc_q        <= {RESET_PC[XLEN-1:3], 3'b000};
      if1_valid_o <= 1'b0;
      if1_pc_o    <= {RESET_PC[XLEN-1:3], 3'b000};
      if1_odd_o   <= RESET_PC[2];
    end else if (flush_i) begin
      pc_q        <= {redirect_pc_i[XLEN-1:3], 3'b000} + 64'd8;
      if1_valid_o <= 1'b1;
      if1_pc_o    <= {redirect_pc_i[XLEN-1:3], 3'b000};
      if1_odd_o   <= redirect_pc_i[2];
    end else if (!stall_i && !wfi_sleep_i) begin
      pc_q        <= pc_q + 64'd8;
      if1_valid_o <= 1'b1;
      if1_pc_o    <= pc_q;
      if1_odd_o   <= 1'b0;
    end else if (!stall_i) begin
      if1_valid_o <= 1'b0;
    end
  end

  wire [31:0] _unused_hart = HART_ID;
  wire _unused = &{1'b0, _unused_hart, itlb_fault_i, 1'b0};

endmodule
