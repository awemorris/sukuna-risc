// ============================================================================
// L1 Cache Subsystem Top-Level (Verilog 2005)
// Combines 3x L1I, 3x L1D, Coherence Controller, and L2 Arbiter
// Complies with design-rule.md
// Word-aligned addresses & byte-enables
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_l1_subsys #(
  parameter NUM_HARTS       = `NUM_HARTS,
  parameter XLEN            = `XLEN,
  parameter PADDR_WIDTH     = `PADDR_WIDTH,
  parameter CACHE_LINE_BITS = `CACHE_LINE_BITS,
  parameter L1I_WAYS        = `L1I_WAYS,
  parameter L1D_WAYS        = `L1D_WAYS
)(
  input  wire                                   clk_i,
  input  wire                                   rst_ni,

  // Fetch Interfaces from 3 Harts (Word-aligned: bits [1:0] omitted, 64-bit pair)
  input  wire [NUM_HARTS-1:0]                   fetch_req_valid_i,
  input  wire [NUM_HARTS-1:0]                   fetch_stall_i,
  input  wire [NUM_HARTS-1:0]                   fetch_flush_i,
  input  wire [NUM_HARTS*(PADDR_WIDTH-2)-1:0]   fetch_paddr_w_i,
  output wire [NUM_HARTS-1:0]                   fetch_resp_valid_o,
  output wire [NUM_HARTS*64-1:0]                fetch_inst_o,
  output wire [NUM_HARTS-1:0]                   fetch_miss_o,

  // AGU/MA Interfaces from 3 Harts (Word-aligned address & byte enable)
  input  wire [NUM_HARTS-1:0]                   mem_req_valid_i,
  input  wire [NUM_HARTS-1:0]                   mem_req_write_i,
  input  wire [NUM_HARTS*4-1:0]                 mem_req_op_i,
  input  wire [NUM_HARTS*8-1:0]                 mem_byte_en_i,
  input  wire [NUM_HARTS*(PADDR_WIDTH-2)-1:0]   mem_paddr_w_i,
  input  wire [NUM_HARTS*XLEN-1:0]              mem_wdata_i,
  output wire [NUM_HARTS-1:0]                   mem_req_ready_o,
  output wire [NUM_HARTS-1:0]                   mem_resp_valid_o,
  output wire [NUM_HARTS*XLEN-1:0]              mem_rdata_o,
  output wire [NUM_HARTS-1:0]                   mem_miss_stall_o,

  // PTW PTE Read Interface
  input  wire                                   ptw_req_valid_i,
  input  wire [PADDR_WIDTH-1:2]                 ptw_paddr_w_i,
  output wire                                   ptw_req_ready_o,
  output wire                                   ptw_resp_valid_o,
  output wire [XLEN-1:0]                        ptw_data_o,

  // Unified Request to Shared L2 Cache (Word-aligned: bits [1:0] omitted)
  output wire                                   l2_req_valid_o,
  output wire                                   l2_req_write_o,
  output wire [3:0]                             l2_req_source_o,
  output wire [PADDR_WIDTH-1:2]                 l2_req_paddr_w_o,
  output wire [CACHE_LINE_BITS-1:0]             l2_req_wdata_o,
  input  wire                                   l2_req_ready_i,

  input  wire                                   l2_resp_valid_i,
  input  wire [3:0]                             l2_resp_source_i,
  input  wire [CACHE_LINE_BITS-1:0]             l2_resp_rdata_i,

  // FENCE.I invalidation
  input  wire [NUM_HARTS-1:0]                   fence_i_flush_i
);

  // Wires connecting L1I to Arbiter
  wire [NUM_HARTS-1:0]                   l1i_refill_req_valid;
  wire [NUM_HARTS*(PADDR_WIDTH-2)-1:0]   l1i_refill_line_paddr_w;
  wire [NUM_HARTS-1:0]                   l1i_refill_req_ready;
  wire [NUM_HARTS-1:0]                   l1i_refill_resp_valid;
  wire [NUM_HARTS*CACHE_LINE_BITS-1:0]   l1i_refill_line_data;

  // Wires connecting L1D to Arbiter
  wire [NUM_HARTS-1:0]                   l1d_refill_req_valid;
  wire [NUM_HARTS-1:0]                   l1d_refill_req_write;
  wire [NUM_HARTS*(PADDR_WIDTH-2)-1:0]   l1d_refill_line_paddr_w;
  wire [NUM_HARTS*CACHE_LINE_BITS-1:0]   l1d_refill_wline_data;
  wire [NUM_HARTS-1:0]                   l1d_refill_req_ready;
  wire [NUM_HARTS-1:0]                   l1d_refill_resp_valid;
  wire [NUM_HARTS*CACHE_LINE_BITS-1:0]   l1d_refill_rline_data;

  // Coherence snoop wires
  wire [NUM_HARTS-1:0]                   snoop_req_valid;
  wire [NUM_HARTS*(PADDR_WIDTH-2)-1:0]   snoop_paddr_w;
  wire [NUM_HARTS-1:0]                   snoop_invalidate;
  wire [NUM_HARTS-1:0]                   snoop_hit;

  genvar h;
  generate
    for (h = 0; h < NUM_HARTS; h = h + 1) begin : gen_l1_caches
      sukuna_l1i_cache #(
        .HART_ID        (h),
        .PADDR_WIDTH    (PADDR_WIDTH),
        .CACHE_LINE_BITS(CACHE_LINE_BITS),
        .WAYS           (L1I_WAYS)
      ) u_l1i (
        .clk_i                (clk_i),
        .rst_ni               (rst_ni),
        .stall_i              (fetch_stall_i[h]),
        .flush_i              (fetch_flush_i[h]),
        .fetch_req_valid_i    (fetch_req_valid_i[h]),
        .fetch_paddr_w_i      (fetch_paddr_w_i[h*(PADDR_WIDTH-2) +: (PADDR_WIDTH-2)]),
        .fetch_resp_valid_o   (fetch_resp_valid_o[h]),
        .fetch_inst_o         (fetch_inst_o[h*64 +: 64]),
        .fetch_miss_o         (fetch_miss_o[h]),
        .refill_req_valid_o   (l1i_refill_req_valid[h]),
        .refill_line_paddr_w_o(l1i_refill_line_paddr_w[h*(PADDR_WIDTH-2) +: (PADDR_WIDTH-2)]),
        .refill_req_ready_i   (l1i_refill_req_ready[h]),
        .refill_resp_valid_i  (l1i_refill_resp_valid[h]),
        .refill_line_data_i   (l1i_refill_line_data[h*CACHE_LINE_BITS +: CACHE_LINE_BITS]),
        .fence_i_flush_i      (fence_i_flush_i[h])
      );

      sukuna_l1d_cache #(
        .XLEN           (XLEN),
        .PADDR_WIDTH    (PADDR_WIDTH),
        .CACHE_LINE_BITS(CACHE_LINE_BITS),
        .WAYS           (L1D_WAYS)
      ) u_l1d (
        .clk_i              (clk_i),
        .rst_ni             (rst_ni),
        .mem_req_valid_i    (mem_req_valid_i[h]),
        .mem_req_write_i    (mem_req_write_i[h]),
        .mem_req_op_i       (mem_req_op_i[h*4 +: 4]),
        .mem_byte_en_i      (mem_byte_en_i[h*8 +: 8]),
        .mem_paddr_w_i      (mem_paddr_w_i[h*(PADDR_WIDTH-2) +: (PADDR_WIDTH-2)]),
        .mem_wdata_i        (mem_wdata_i[h*XLEN +: XLEN]),
        .mem_req_ready_o    (mem_req_ready_o[h]),
        .mem_resp_valid_o   (mem_resp_valid_o[h]),
        .mem_rdata_o        (mem_rdata_o[h*XLEN +: XLEN]),
        .mem_miss_stall_o   (mem_miss_stall_o[h]),
        .snoop_req_valid_i  (snoop_req_valid[h]),
        .snoop_paddr_w_i    (snoop_paddr_w[h*(PADDR_WIDTH-2) +: (PADDR_WIDTH-2)]),
        .snoop_invalidate_i (snoop_invalidate[h]),
        .snoop_hit_o        (snoop_hit[h]),
        .l2_req_valid_o     (l1d_refill_req_valid[h]),
        .l2_req_write_o     (l1d_refill_req_write[h]),
        .l2_line_paddr_w_o  (l1d_refill_line_paddr_w[h*(PADDR_WIDTH-2) +: (PADDR_WIDTH-2)]),
        .l2_wline_data_o    (l1d_refill_wline_data[h*CACHE_LINE_BITS +: CACHE_LINE_BITS]),
        .l2_req_ready_i     (l1d_refill_req_ready[h]),
        .l2_resp_valid_i    (l1d_refill_resp_valid[h]),
        .l2_rline_data_i    (l1d_refill_rline_data[h*CACHE_LINE_BITS +: CACHE_LINE_BITS])
      );
    end
  endgenerate

  // Coherence Controller
  sukuna_l1d_coherence #(
    .NUM_HARTS  (NUM_HARTS),
    .PADDR_WIDTH(PADDR_WIDTH)
  ) u_coherence (
    .clk_i              (clk_i),
    .rst_ni             (rst_ni),
    .l1d_write_req_i    (mem_req_valid_i & mem_req_write_i),
    .l1d_write_paddr_w_i(mem_paddr_w_i),
    .snoop_req_valid_o  (snoop_req_valid),
    .snoop_paddr_w_o    (snoop_paddr_w),
    .snoop_invalidate_o (snoop_invalidate),
    .snoop_hit_i        (snoop_hit)
  );

  // L2 Crossbar Arbiter
  sukuna_l2_arbiter #(
    .NUM_HARTS      (NUM_HARTS),
    .PADDR_WIDTH    (PADDR_WIDTH),
    .CACHE_LINE_BITS(CACHE_LINE_BITS)
  ) u_l2_arb (
    .clk_i            (clk_i),
    .rst_ni           (rst_ni),
    .l1i_req_valid_i  (l1i_refill_req_valid),
    .l1i_line_paddr_w_i(l1i_refill_line_paddr_w),
    .l1i_req_ready_o  (l1i_refill_req_ready),
    .l1i_resp_valid_o (l1i_refill_resp_valid),
    .l1i_line_data_o  (l1i_refill_line_data),
    .l1d_req_valid_i  (l1d_refill_req_valid),
    .l1d_req_write_i  (l1d_refill_req_write),
    .l1d_line_paddr_w_i(l1d_refill_line_paddr_w),
    .l1d_wline_data_i (l1d_refill_wline_data),
    .l1d_req_ready_o  (l1d_refill_req_ready),
    .l1d_resp_valid_o (l1d_refill_resp_valid),
    .l1d_rline_data_o (l1d_refill_rline_data),
    .ptw_req_valid_i  (ptw_req_valid_i),
    .ptw_paddr_w_i    (ptw_paddr_w_i),
    .ptw_req_ready_o  (ptw_req_ready_o),
    .ptw_resp_valid_o (ptw_resp_valid_o),
    .ptw_data_o       (ptw_data_o),
    .l2_req_valid_o   (l2_req_valid_o),
    .l2_req_write_o   (l2_req_write_o),
    .l2_req_source_o  (l2_req_source_o),
    .l2_req_paddr_w_o (l2_req_paddr_w_o),
    .l2_req_wdata_o   (l2_req_wdata_o),
    .l2_req_ready_i   (l2_req_ready_i),
    .l2_resp_valid_i  (l2_resp_valid_i),
    .l2_resp_source_i (l2_resp_source_i),
    .l2_resp_rdata_i  (l2_resp_rdata_i)
  );

endmodule
