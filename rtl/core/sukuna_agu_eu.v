// ============================================================================
// Dedicated 2-Cycle Memory Access Execution Unit (MA-EU) Stub (Verilog 2005)
// 1:1 mapped to thread.
// Stage 1 (ADDR): Address calculation and virtual address translation request
// Stage 2 (MA): Accesses dedicated thread L1D cache
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_agu_eu #(
  parameter XLEN        = `XLEN,
  parameter VADDR_WIDTH = `VADDR_WIDTH,
  parameter PADDR_WIDTH = `PADDR_WIDTH
)(
  input  wire                   clk_i,
  input  wire                   rst_ni,

  // Dispatched from ID/RF (Slot 1 MA)
  input  wire                   req_valid_i,
  input  wire [2:0]             req_op_i,
  input  wire [4:0]             req_rd_i,
  input  wire [XLEN-1:0]        req_base_i,
  input  wire [XLEN-1:0]        req_offset_i,
  input  wire [XLEN-1:0]        req_wdata_i,
  output wire                   busy_o,

  // DTLB Address Translation
  output wire                   dtlb_lookup_valid_o,
  output wire [VADDR_WIDTH-1:0] dtlb_vaddr_o,
  input  wire                   dtlb_hit_i,
  input  wire [PADDR_WIDTH-1:0] dtlb_paddr_i,
  input  wire                   dtlb_fault_i,

  // Dedicated L1D Port
  output wire                   l1d_req_valid_o,
  output wire                   l1d_req_write_o,
  output wire [2:0]             l1d_req_op_o,
  output wire [PADDR_WIDTH-1:0] l1d_paddr_o,
  output wire [XLEN-1:0]        l1d_wdata_o,
  input  wire                   l1d_req_ready_i,
  input  wire                   l1d_resp_valid_i,
  input  wire [XLEN-1:0]        l1d_rdata_i,
  input  wire                   l1d_miss_stall_i,

  // Output to Writeback Stage
  output reg                    resp_valid_o,
  output reg  [4:0]             resp_rd_o,
  output reg  [XLEN-1:0]        resp_rdata_o
);

  // Stage 1 Registers (ADDR)
  reg                   s1_valid_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [2:0]             s1_op_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [4:0]             s1_rd_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [VADDR_WIDTH-1:0] s1_vaddr_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]        s1_wdata_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  wire [VADDR_WIDTH-1:0] calc_vaddr = req_base_i + req_offset_i;

  assign busy_o = l1d_miss_stall_i;

  assign dtlb_lookup_valid_o = s1_valid_q;
  assign dtlb_vaddr_o        = s1_vaddr_q;

  assign l1d_req_valid_o     = s1_valid_q && dtlb_hit_i;
  assign l1d_req_write_o     = s1_op_q[2]; // Write bit in mem_op
  assign l1d_req_op_o        = s1_op_q;
  assign l1d_paddr_o         = dtlb_paddr_i;
  assign l1d_wdata_o         = s1_wdata_q;

  // Pipeline Stage 1
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s1_valid_q <= 1'b0;
      s1_op_q    <= 3'd0;
      s1_rd_q    <= 5'd0;
      s1_vaddr_q <= {VADDR_WIDTH{1'b0}};
      s1_wdata_q <= {XLEN{1'b0}};
    end else if (!l1d_miss_stall_i) begin
      s1_valid_q <= req_valid_i;
      s1_op_q    <= req_op_i;
      s1_rd_q    <= req_rd_i;
      s1_vaddr_q <= calc_vaddr;
      s1_wdata_q <= req_wdata_i;
    end
  end

  // Pipeline Stage 2 -> WB
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      resp_valid_o <= 1'b0;
      resp_rd_o    <= 5'd0;
      resp_rdata_o <= {XLEN{1'b0}};
    end else begin
      resp_valid_o <= l1d_resp_valid_i;
      resp_rd_o    <= s1_rd_q;
      resp_rdata_o <= l1d_rdata_i;
    end
  end

endmodule
