// ============================================================================
// Sukuna-RISC: Dedicated 2-Cycle Memory Access Execution Unit (MA-EU) (Verilog 2005)
// Complies with design-rule.md
// Stage 1 (ADDR): Address calculation using sk_add and DTLB lookup request
//                 Lower 2 bits omitted, Byte-Enable vector generated
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

  // DTLB Address Translation (Word-aligned address)
  output wire                   dtlb_lookup_valid_o,
  output wire [VADDR_WIDTH-1:2] dtlb_vaddr_w_o,
  input  wire                   dtlb_hit_i,
  input  wire [PADDR_WIDTH-1:2] dtlb_paddr_w_i,
  input  wire                   dtlb_fault_i,

  // Dedicated L1D Port (Word-aligned address & byte-enable)
  output wire                   l1d_req_valid_o,
  output wire                   l1d_req_write_o,
  output wire [2:0]             l1d_req_op_o,
  output wire [7:0]             l1d_req_byte_en_o,
  output wire [PADDR_WIDTH-1:2] l1d_paddr_w_o,
  output wire [XLEN-1:0]        l1d_wdata_o,
  input  wire                   l1d_req_ready_i,
  input  wire                   l1d_resp_valid_i,
  input  wire [XLEN-1:0]        l1d_rdata_i,
  input  wire                   l1d_miss_stall_i,

  // Output to Writeback Stage
  output reg                    resp_valid_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [4:0]             resp_rd_o,      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]        resp_rdata_o    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
);

  // Address Calculation via shared library adder
  wire [VADDR_WIDTH-1:0] calc_vaddr;

  sk_add #(
    .WIDTH   (VADDR_WIDTH),
    .PIPELINE(0),
    .IMPL    ("CARRY")
  ) u_addr_add (
    .clk_i   (clk_i),
    .rst_ni  (rst_ni),
    .cin_i   (1'b0),
    .a_i     (req_base_i[VADDR_WIDTH-1:0]),
    .b_i     (req_offset_i[VADDR_WIDTH-1:0]),
    .sum_o   (calc_vaddr),
    .cout_o  ()
  );

  // Byte enable generation replacing address lower bits
  wire [2:0] addr_lsb = calc_vaddr[2:0];
  reg [7:0]  calc_byte_en;
  always @(*) begin
    case (req_op_i)
      `MEM_LB, `MEM_SB: calc_byte_en = 8'b00000001 << addr_lsb;
      `MEM_LH, `MEM_SH: calc_byte_en = 8'b00000011 << {addr_lsb[2:1], 1'b0};
      `MEM_LW, `MEM_SW: calc_byte_en = addr_lsb[2] ? 8'b11110000 : 8'b00001111;
      `MEM_LD, `MEM_SD: calc_byte_en = 8'b11111111;
      default:          calc_byte_en = 8'b11111111;
    endcase
  end

  // Stage 1 Registers (ADDR)
  reg                     s1_valid_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [2:0]               s1_op_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [7:0]               s1_byte_en_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [4:0]               s1_rd_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [VADDR_WIDTH-1:2]   s1_vaddr_w_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]          s1_wdata_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  assign busy_o = l1d_miss_stall_i;

  assign dtlb_lookup_valid_o = s1_valid_q;
  assign dtlb_vaddr_w_o      = s1_vaddr_w_q;

  assign l1d_req_valid_o     = s1_valid_q && dtlb_hit_i;
  assign l1d_req_write_o     = s1_op_q[2]; // Write bit in mem_op
  assign l1d_req_op_o        = s1_op_q;
  assign l1d_req_byte_en_o   = s1_byte_en_q;
  assign l1d_paddr_w_o       = dtlb_paddr_w_i;
  assign l1d_wdata_o         = s1_wdata_q;

  // Pipeline Stage 1
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s1_valid_q   <= 1'b0;
      s1_op_q      <= 3'd0;
      s1_byte_en_q <= 8'd0;
      s1_rd_q      <= 5'd0;
      s1_vaddr_w_q <= {(VADDR_WIDTH-2){1'b0}};
      s1_wdata_q   <= {XLEN{1'b0}};
    end else if (!l1d_miss_stall_i) begin
      s1_valid_q   <= req_valid_i;
      s1_op_q      <= req_op_i;
      s1_byte_en_q <= calc_byte_en;
      s1_rd_q      <= req_rd_i;
      s1_vaddr_w_q <= calc_vaddr[VADDR_WIDTH-1:2];
      s1_wdata_q   <= req_wdata_i;
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
