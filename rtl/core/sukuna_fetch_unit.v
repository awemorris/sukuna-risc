// ============================================================================
// Instruction Fetch Unit (IF1 / IF2) Stub (Verilog 2005)
// PC Generation, Branch Prediction stub, RVC Expander, and L1I Interface
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_fetch_unit #(
  parameter HART_ID     = 0,
  parameter XLEN        = `XLEN,
  parameter VADDR_WIDTH = `VADDR_WIDTH,
  parameter PADDR_WIDTH = `PADDR_WIDTH
)(
  input  wire                   clk_i,
  input  wire                   rst_ni,

  // Control from Hazard / Branch / Trap logic
  input  wire                   stall_i,
  input  wire                   flush_i,
  input  wire [XLEN-1:0]        redirect_pc_i,

  // Virtual Address output to L1-ITLB
  output wire                   itlb_req_valid_o,
  output wire [VADDR_WIDTH-1:0] itlb_vaddr_o,
  input  wire                   itlb_hit_i,
  input  wire [PADDR_WIDTH-1:0] itlb_paddr_i,
  input  wire                   itlb_fault_i,

  // Physical Address to L1I Cache
  output wire                   l1i_req_valid_o,
  output wire [PADDR_WIDTH-1:0] l1i_paddr_o,
  input  wire                   l1i_resp_valid_i,
  input  wire [31:0]            l1i_inst_i,
  input  wire                   l1i_miss_i,

  // Fetched & Expanded Instruction output to ID stage
  output reg                    fetch_valid_o,
  output reg  [XLEN-1:0]        fetch_pc_o,
  output reg  [31:0]            fetch_inst0_o,   // First instruction
  output reg  [31:0]            fetch_inst1_o,   // Second instruction candidate (for dual-issue)
  output reg                    fetch_has_two_o  // Whether 2 valid instructions fetched
);

  reg [XLEN-1:0] pc_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  assign itlb_req_valid_o = !stall_i;
  assign itlb_vaddr_o     = pc_q;

  assign l1i_req_valid_o  = itlb_hit_i && !stall_i;
  assign l1i_paddr_o      = itlb_paddr_i;

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pc_q            <= 64'h00000000_80000000; // Reset vector
      fetch_valid_o   <= 1'b0;
      fetch_pc_o      <= {XLEN{1'b0}};
      fetch_inst0_o   <= 32'h00000013; // NOP
      fetch_inst1_o   <= 32'h00000013;
      fetch_has_two_o <= 1'b0;
    end else begin
      if (flush_i) begin
        pc_q          <= redirect_pc_i;
        fetch_valid_o <= 1'b0;
      end else if (!stall_i) begin
        pc_q            <= pc_q + 64'd4;
        fetch_valid_o   <= l1i_resp_valid_i;
        fetch_pc_o      <= pc_q;
        fetch_inst0_o   <= l1i_inst_i;
        fetch_inst1_o   <= 32'h00000013;
        fetch_has_two_o <= 1'b0;
      end
    end
  end

endmodule
