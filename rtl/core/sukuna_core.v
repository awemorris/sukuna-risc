// ============================================================================
// Sukuna Core Top-Level (Verilog 2005)
// Instantiates:
//   - 3x Thread Pipelines (Hart 0 Kernel, Hart 1 Foreground, Hart 2 Background)
//   - Shared Execution Units (FP-EU1, FMA-EU1, CFP-EU1, SIMD-EU1)
//   - MMU Subsystem (3x L1-ITLB, 3x L1-DTLB, Shared L2-TLB, Shared PTW)
//   - L1 Cache Subsystem (3x L1I, 3x L1D, Coherence Unit, L2 Arbiter)
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_core #(
  parameter NUM_HARTS       = `NUM_HARTS,
  parameter XLEN            = `XLEN,
  parameter VADDR_WIDTH     = `VADDR_WIDTH,
  parameter PADDR_WIDTH     = `PADDR_WIDTH,
  parameter CACHE_LINE_BITS = `CACHE_LINE_BITS,
  parameter RESET_PC        = 64'h0000_0000_8000_0000
)(
  input  wire                               clk_i,
  input  wire                               rst_ni,

  // Interrupts from Interrupt Subsystem
  input  wire [NUM_HARTS-1:0]               meip_i,
  input  wire [NUM_HARTS-1:0]               seip_i,
  input  wire [NUM_HARTS-1:0]               mtip_i,
  input  wire [NUM_HARTS-1:0]               msip_i,

  // Interface to Shared L2 Cache (Word-aligned: bits [1:0] omitted)
  output wire                               l2_req_valid_o,
  output wire                               l2_req_write_o,
  output wire [3:0]                         l2_req_source_o,
  output wire [PADDR_WIDTH-1:2]             l2_req_paddr_w_o,
  output wire [CACHE_LINE_BITS-1:0]         l2_req_wdata_o,
  input  wire                               l2_req_ready_i,

  input  wire                               l2_resp_valid_i,
  input  wire [3:0]                         l2_resp_source_i,
  input  wire [CACHE_LINE_BITS-1:0]         l2_resp_rdata_i
);

  // Satp and flushes per Hart
  wire [XLEN-1:0] satp [0:NUM_HARTS-1];
  wire [NUM_HARTS-1:0] sfence_flush;
  wire [NUM_HARTS-1:0] fence_i_flush;

  // L1-ITLB lines (word-aligned)
  wire [NUM_HARTS-1:0]                 itlb_req_valid;
  wire [NUM_HARTS*(VADDR_WIDTH-2)-1:0] itlb_vaddr_w;
  wire [NUM_HARTS-1:0]                 itlb_hit;
  wire [NUM_HARTS*(PADDR_WIDTH-2)-1:0] itlb_paddr_w;
  wire [NUM_HARTS-1:0]                 itlb_fault;

  // L1I lines (word-aligned)
  wire [NUM_HARTS-1:0]                 l1i_req_valid;
  wire [NUM_HARTS-1:0]                 l1i_stall;
  wire [NUM_HARTS-1:0]                 l1i_flush;
  wire [NUM_HARTS*(PADDR_WIDTH-2)-1:0] l1i_paddr_w;
  wire [NUM_HARTS-1:0]                 l1i_resp_valid;
  wire [NUM_HARTS*64-1:0]              l1i_inst;
  wire [NUM_HARTS-1:0]                 l1i_miss;

  // L1-DTLB lines (word-aligned)
  wire [NUM_HARTS-1:0]                 dtlb_lookup_valid;
  wire [NUM_HARTS*(VADDR_WIDTH-2)-1:0] dtlb_vaddr_w;
  wire [NUM_HARTS-1:0]                 dtlb_hit;
  wire [NUM_HARTS*(PADDR_WIDTH-2)-1:0] dtlb_paddr_w;
  wire [NUM_HARTS-1:0]                 dtlb_fault;

  // L1D lines (word-aligned & byte-enables)
  wire [NUM_HARTS-1:0]                 l1d_req_valid;
  wire [NUM_HARTS-1:0]                 l1d_req_write;
  wire [NUM_HARTS*4-1:0]               l1d_req_op;
  wire [NUM_HARTS*8-1:0]               l1d_req_byte_en;
  wire [NUM_HARTS*(PADDR_WIDTH-2)-1:0] l1d_paddr_w;
  wire [NUM_HARTS*XLEN-1:0]            l1d_wdata;
  wire [NUM_HARTS-1:0]                 l1d_req_ready;
  wire [NUM_HARTS-1:0]                 l1d_resp_valid;
  wire [NUM_HARTS*XLEN-1:0]            l1d_rdata;
  wire [NUM_HARTS-1:0]                 l1d_miss_stall;

  // Shared EX lines
  wire [NUM_HARTS-1:0]             shared_req_valid;
  wire [NUM_HARTS*2-1:0]           shared_req_type;
  wire [NUM_HARTS*5-1:0]           shared_req_rd;
  wire [NUM_HARTS*XLEN-1:0]        shared_req_src1;
  wire [NUM_HARTS*XLEN-1:0]        shared_req_src2;
  wire [NUM_HARTS*XLEN-1:0]        shared_req_src3;
  wire [NUM_HARTS-1:0]             shared_stall;

  wire                             shared_resp_valid;
  wire [1:0]                       shared_resp_hart_id;
  wire [4:0]                       shared_resp_rd;
  wire [XLEN-1:0]                  shared_resp_data;

  // PTW to L1 Subsys L2 Arbiter
  wire                             ptw_mem_req_valid;
  wire [PADDR_WIDTH-1:2]           ptw_mem_req_paddr_w;
  wire                             ptw_mem_req_ready;
  wire                             ptw_mem_resp_valid;
  wire [XLEN-1:0]                  ptw_mem_resp_data;

  // Instantiating 3 Thread Pipelines (SMT)
  genvar h;
  generate
    for (h = 0; h < NUM_HARTS; h = h + 1) begin : gen_threads
      wire resp_valid_h = shared_resp_valid && (shared_resp_hart_id == h[1:0]);

      sukuna_thread_pipe #(
        .HART_ID    (h),
        .XLEN       (XLEN),
        .VADDR_WIDTH(VADDR_WIDTH),
        .PADDR_WIDTH(PADDR_WIDTH),
        .RESET_PC   (RESET_PC)
      ) u_thread (
        .clk_i              (clk_i),
        .rst_ni             (rst_ni),
        .meip_i             (meip_i[h]),
        .seip_i             (seip_i[h]),
        .mtip_i             (mtip_i[h]),
        .msip_i             (msip_i[h]),
        .satp_o             (satp[h]),
        .sfence_flush_o     (sfence_flush[h]),

        .itlb_req_valid_o   (itlb_req_valid[h]),
        .itlb_vaddr_w_o     (itlb_vaddr_w[h*(VADDR_WIDTH-2) +: (VADDR_WIDTH-2)]),
        .itlb_hit_i         (itlb_hit[h]),
        .itlb_paddr_w_i     (itlb_paddr_w[h*(PADDR_WIDTH-2) +: (PADDR_WIDTH-2)]),
        .itlb_fault_i       (itlb_fault[h]),

        .l1i_req_valid_o    (l1i_req_valid[h]),
        .l1i_stall_o        (l1i_stall[h]),
        .l1i_flush_o        (l1i_flush[h]),
        .l1i_paddr_w_o      (l1i_paddr_w[h*(PADDR_WIDTH-2) +: (PADDR_WIDTH-2)]),
        .l1i_resp_valid_i   (l1i_resp_valid[h]),
        .l1i_inst_i         (l1i_inst[h*64 +: 64]),
        .l1i_miss_i         (l1i_miss[h]),
        .fence_i_flush_o    (fence_i_flush[h]),

        .dtlb_lookup_valid_o(dtlb_lookup_valid[h]),
        .dtlb_vaddr_w_o     (dtlb_vaddr_w[h*(VADDR_WIDTH-2) +: (VADDR_WIDTH-2)]),
        .dtlb_hit_i         (dtlb_hit[h]),
        .dtlb_paddr_w_i     (dtlb_paddr_w[h*(PADDR_WIDTH-2) +: (PADDR_WIDTH-2)]),
        .dtlb_fault_i       (dtlb_fault[h]),

        .l1d_req_valid_o    (l1d_req_valid[h]),
        .l1d_req_write_o    (l1d_req_write[h]),
        .l1d_req_op_o       (l1d_req_op[h*4 +: 4]),
        .l1d_req_byte_en_o  (l1d_req_byte_en[h*8 +: 8]),
        .l1d_paddr_w_o      (l1d_paddr_w[h*(PADDR_WIDTH-2) +: (PADDR_WIDTH-2)]),
        .l1d_wdata_o        (l1d_wdata[h*XLEN +: XLEN]),
        .l1d_req_ready_i    (l1d_req_ready[h]),
        .l1d_resp_valid_i   (l1d_resp_valid[h]),
        .l1d_rdata_i        (l1d_rdata[h*XLEN +: XLEN]),
        .l1d_miss_stall_i   (l1d_miss_stall[h]),

        .shared_req_valid_o (shared_req_valid[h]),
        .shared_req_type_o  (shared_req_type[h*2 +: 2]),
        .shared_req_rd_o    (shared_req_rd[h*5 +: 5]),
        .shared_req_src1_o  (shared_req_src1[h*XLEN +: XLEN]),
        .shared_req_src2_o  (shared_req_src2[h*XLEN +: XLEN]),
        .shared_req_src3_o  (shared_req_src3[h*XLEN +: XLEN]),
        .shared_stall_i     (shared_stall[h]),

        .shared_resp_valid_i(resp_valid_h),
        .shared_resp_rd_i   (shared_resp_rd),
        .shared_resp_data_i (shared_resp_data)
      );
    end
  endgenerate

  // Shared Execution Units
  sukuna_shared_ex #(
    .NUM_HARTS(NUM_HARTS),
    .XLEN     (XLEN)
  ) u_shared_ex (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .req_valid_i    (shared_req_valid),
    .req_type_i     (shared_req_type),
    .req_rd_i       (shared_req_rd),
    .req_src1_i     (shared_req_src1),
    .req_src2_i     (shared_req_src2),
    .req_src3_i     (shared_req_src3),
    .stall_thread_o (shared_stall),
    .resp_valid_o   (shared_resp_valid),
    .resp_hart_id_o (shared_resp_hart_id),
    .resp_rd_o      (shared_resp_rd),
    .resp_data_o    (shared_resp_data)
  );

  // MMU Subsystem
  sukuna_mmu #(
    .NUM_HARTS  (NUM_HARTS),
    .VADDR_WIDTH(VADDR_WIDTH),
    .PADDR_WIDTH(PADDR_WIDTH),
    .XLEN       (XLEN)
  ) u_mmu (
    .clk_i                (clk_i),
    .rst_ni               (rst_ni),
    .itlb_lookup_valid_i  (itlb_req_valid),
    .itlb_vaddr_w_i       (itlb_vaddr_w),
    .itlb_hit_o           (itlb_hit),
    .itlb_paddr_w_o       (itlb_paddr_w),
    .itlb_page_fault_o    (itlb_fault),
    .dtlb_lookup_valid_i  (dtlb_lookup_valid),
    .dtlb_vaddr_w_i       (dtlb_vaddr_w),
    .dtlb_hit_o           (dtlb_hit),
    .dtlb_paddr_w_o       (dtlb_paddr_w),
    .dtlb_page_fault_o    (dtlb_fault),
    .satp_hart0_i         (satp[0]),
    .satp_hart1_i         (satp[1]),
    .satp_hart2_i         (satp[2]),
    .sfence_flush_i       (sfence_flush),
    .ptw_mem_req_valid_o  (ptw_mem_req_valid),
    .ptw_mem_req_paddr_w_o(ptw_mem_req_paddr_w),
    .ptw_mem_req_ready_i  (ptw_mem_req_ready),
    .ptw_mem_resp_valid_i (ptw_mem_resp_valid),
    .ptw_mem_resp_data_i  (ptw_mem_resp_data)
  );

  // L1 Cache Subsystem
  sukuna_l1_subsys #(
    .NUM_HARTS      (NUM_HARTS),
    .XLEN           (XLEN),
    .PADDR_WIDTH    (PADDR_WIDTH),
    .CACHE_LINE_BITS(CACHE_LINE_BITS)
  ) u_l1_subsys (
    .clk_i              (clk_i),
    .rst_ni             (rst_ni),
    .fetch_req_valid_i  (l1i_req_valid),
    .fetch_stall_i      (l1i_stall),
    .fetch_flush_i      (l1i_flush),
    .fetch_paddr_w_i    (l1i_paddr_w),
    .fetch_resp_valid_o (l1i_resp_valid),
    .fetch_inst_o       (l1i_inst),
    .fetch_miss_o       (l1i_miss),
    .mem_req_valid_i    (l1d_req_valid),
    .mem_req_write_i    (l1d_req_write),
    .mem_req_op_i       (l1d_req_op),
    .mem_byte_en_i      (l1d_req_byte_en),
    .mem_paddr_w_i      (l1d_paddr_w),
    .mem_wdata_i        (l1d_wdata),
    .mem_req_ready_o    (l1d_req_ready),
    .mem_resp_valid_o   (l1d_resp_valid),
    .mem_rdata_o        (l1d_rdata),
    .mem_miss_stall_o   (l1d_miss_stall),
    .ptw_req_valid_i    (ptw_mem_req_valid),
    .ptw_paddr_w_i      (ptw_mem_req_paddr_w),
    .ptw_req_ready_o    (ptw_mem_req_ready),
    .ptw_resp_valid_o   (ptw_mem_resp_valid),
    .ptw_data_o         (ptw_mem_resp_data),
    .l2_req_valid_o     (l2_req_valid_o),
    .l2_req_write_o     (l2_req_write_o),
    .l2_req_source_o    (l2_req_source_o),
    .l2_req_paddr_w_o   (l2_req_paddr_w_o),
    .l2_req_wdata_o     (l2_req_wdata_o),
    .l2_req_ready_i     (l2_req_ready_i),
    .l2_resp_valid_i    (l2_resp_valid_i),
    .l2_resp_source_i   (l2_resp_source_i),
    .l2_resp_rdata_i    (l2_resp_rdata_i),
    .fence_i_flush_i    (fence_i_flush)
  );

endmodule
