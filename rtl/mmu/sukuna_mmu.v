// ============================================================================
// MMU Subsystem Top-Level (Verilog 2005)
// Complies with design-rule.md
// Contains per-thread micro L1-ITLBs, L1-DTLBs, Shared L2-TLB, and Hardware PTW
// Provides round-robin refill arbitration between 6x L1-TLBs and shared L2-TLB
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_mmu #(
  parameter NUM_HARTS   = `NUM_HARTS,
  parameter VADDR_WIDTH = `VADDR_WIDTH,
  parameter PADDR_WIDTH = `PADDR_WIDTH,
  parameter XLEN        = `XLEN
)(
  input  wire                               clk_i,
  input  wire                               rst_ni,

  // L1-ITLB Lookup interfaces for 3 Harts (word-aligned: bits [1:0] omitted)
  input  wire [NUM_HARTS-1:0]                   itlb_lookup_valid_i,
  input  wire [NUM_HARTS*(VADDR_WIDTH-2)-1:0]   itlb_vaddr_w_i,
  output wire [NUM_HARTS-1:0]                   itlb_hit_o,
  output wire [NUM_HARTS*(PADDR_WIDTH-2)-1:0]   itlb_paddr_w_o,
  output wire [NUM_HARTS-1:0]                   itlb_page_fault_o,

  // L1-DTLB Lookup interfaces for 3 Harts (word-aligned: bits [1:0] omitted)
  input  wire [NUM_HARTS-1:0]                   dtlb_lookup_valid_i,
  input  wire [NUM_HARTS*(VADDR_WIDTH-2)-1:0]   dtlb_vaddr_w_i,
  output wire [NUM_HARTS-1:0]                   dtlb_hit_o,
  output wire [NUM_HARTS*(PADDR_WIDTH-2)-1:0]   dtlb_paddr_w_o,
  output wire [NUM_HARTS-1:0]                   dtlb_page_fault_o,

  // CSR satp registers for address translation
  input  wire [XLEN-1:0]                    satp_hart0_i,
  input  wire [XLEN-1:0]                    satp_hart1_i,
  input  wire [XLEN-1:0]                    satp_hart2_i,

  // SFENCE.VMA flush per Hart
  input  wire [NUM_HARTS-1:0]               sfence_flush_i,

  // Memory interface to L2 Arbiter for Page Table Walker PTE reads (word-aligned)
  output wire                               ptw_mem_req_valid_o,
  output wire [PADDR_WIDTH-1:2]             ptw_mem_req_paddr_w_o,
  input  wire                               ptw_mem_req_ready_i,
  input  wire                               ptw_mem_resp_valid_i,
  input  wire [XLEN-1:0]                    ptw_mem_resp_data_i
);

  // --------------------------------------------------------------------------
  // SATP Signal Unpack
  // --------------------------------------------------------------------------
  wire [XLEN-1:0] satp_arr [0:NUM_HARTS-1];
  assign satp_arr[0] = satp_hart0_i;
  assign satp_arr[1] = satp_hart1_i;
  assign satp_arr[2] = satp_hart2_i;

  wire [3:0]  satp_mode [0:NUM_HARTS-1];
  wire [15:0] satp_asid [0:NUM_HARTS-1];

  genvar h;
  generate
    for (h = 0; h < NUM_HARTS; h = h + 1) begin : gen_satp_unpack
      assign satp_mode[h] = satp_arr[h][63:60];
      assign satp_asid[h] = satp_arr[h][59:44];
    end
  endgenerate

  // --------------------------------------------------------------------------
  // L1-TLB Refill Signals (6 clients: 0..2 = ITLB[0..2], 3..5 = DTLB[0..2])
  // --------------------------------------------------------------------------
  wire [5:0]                    refill_req;
  wire [6*(VADDR_WIDTH-2)-1:0]  refill_vaddr_flat;
  reg  [5:0]                    refill_resp_valid;
  reg  [6*(PADDR_WIDTH-2)-1:0]  refill_paddr_flat;
  reg  [5:0]                    refill_fault;

  // Instantiations of 3x L1-ITLB and 3x L1-DTLB
  generate
    for (h = 0; h < NUM_HARTS; h = h + 1) begin : gen_tlb_instances
      sukuna_l1_tlb #(
        .NUM_ENTRIES(`L1_TLB_ENTRIES),
        .VADDR_WIDTH(VADDR_WIDTH),
        .PADDR_WIDTH(PADDR_WIDTH)
      ) u_itlb (
        .clk_i              (clk_i),
        .rst_ni             (rst_ni),
        .satp_mode_i        (satp_mode[h]),
        .satp_asid_i        (satp_asid[h]),
        .priv_mode_i        (2'b00), // Default user/supervisor mode
        .lookup_valid_i     (itlb_lookup_valid_i[h]),
        .vaddr_w_i          (itlb_vaddr_w_i[h*(VADDR_WIDTH-2) +: (VADDR_WIDTH-2)]),
        .hit_o              (itlb_hit_o[h]),
        .paddr_w_o          (itlb_paddr_w_o[h*(PADDR_WIDTH-2) +: (PADDR_WIDTH-2)]),
        .page_fault_o       (itlb_page_fault_o[h]),
        .refill_req_o       (refill_req[h]),
        .refill_vaddr_w_o   (refill_vaddr_flat[h*(VADDR_WIDTH-2) +: (VADDR_WIDTH-2)]),
        .refill_resp_valid_i(refill_resp_valid[h]),
        .refill_paddr_w_i   (refill_paddr_flat[h*(PADDR_WIDTH-2) +: (PADDR_WIDTH-2)]),
        .refill_fault_i     (refill_fault[h]),
        .flush_i            (sfence_flush_i[h])
      );

      sukuna_l1_tlb #(
        .NUM_ENTRIES(`L1_TLB_ENTRIES),
        .VADDR_WIDTH(VADDR_WIDTH),
        .PADDR_WIDTH(PADDR_WIDTH)
      ) u_dtlb (
        .clk_i              (clk_i),
        .rst_ni             (rst_ni),
        .satp_mode_i        (satp_mode[h]),
        .satp_asid_i        (satp_asid[h]),
        .priv_mode_i        (2'b00),
        .lookup_valid_i     (dtlb_lookup_valid_i[h]),
        .vaddr_w_i          (dtlb_vaddr_w_i[h*(VADDR_WIDTH-2) +: (VADDR_WIDTH-2)]),
        .hit_o              (dtlb_hit_o[h]),
        .paddr_w_o          (dtlb_paddr_w_o[h*(PADDR_WIDTH-2) +: (PADDR_WIDTH-2)]),
        .page_fault_o       (dtlb_page_fault_o[h]),
        .refill_req_o       (refill_req[3+h]),
        .refill_vaddr_w_o   (refill_vaddr_flat[(3+h)*(VADDR_WIDTH-2) +: (VADDR_WIDTH-2)]),
        .refill_resp_valid_i(refill_resp_valid[3+h]),
        .refill_paddr_w_i   (refill_paddr_flat[(3+h)*(PADDR_WIDTH-2) +: (PADDR_WIDTH-2)]),
        .refill_fault_i     (refill_fault[3+h]),
        .flush_i            (sfence_flush_i[h])
      );
    end
  endgenerate

  // --------------------------------------------------------------------------
  // Round-Robin Arbiter for 6x L1-TLBs requesting Shared L2-TLB
  // --------------------------------------------------------------------------
  reg [2:0]              arb_winner_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                    arb_busy_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  wire                   l2_tlb_req_ready;
  reg                    l2_tlb_req_valid_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [1:0]              l2_tlb_req_hart_id_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [VADDR_WIDTH-1:0]  l2_tlb_req_vaddr_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // Simple round-robin selection
  wire [5:0] req_vec = {refill_req[5], refill_req[4], refill_req[3],
                        refill_req[2], refill_req[1], refill_req[0]};

  reg [2:0] next_grant;
  integer c;
  always @(*) begin
    next_grant = arb_winner_q;
    for (c = 0; c < 6; c = c + 1) begin
      if (req_vec[c]) next_grant = c[2:0];
    end
  end

  // --------------------------------------------------------------------------
  // Shared L2-TLB
  // --------------------------------------------------------------------------
  wire                   l2_resp_valid;
  wire [1:0]             l2_resp_hart_id;
  wire [PADDR_WIDTH-1:0] l2_resp_paddr;
  wire                   l2_resp_fault;

  wire                   l2_ptw_req_valid;
  wire [1:0]             l2_ptw_req_hart_id;
  wire [VADDR_WIDTH-1:0] l2_ptw_req_vaddr;
  wire                   ptw_req_ready;

  wire                   ptw_resp_valid;
  wire [1:0]             ptw_resp_hart_id;
  wire [PADDR_WIDTH-1:0] ptw_resp_paddr;
  wire                   ptw_resp_fault;

  sukuna_l2_tlb #(
    .NUM_ENTRIES(`L2_TLB_ENTRIES),
    .VADDR_WIDTH(VADDR_WIDTH),
    .PADDR_WIDTH(PADDR_WIDTH)
  ) u_l2_tlb (
    .clk_i              (clk_i),
    .rst_ni             (rst_ni),
    .req_valid_i        (l2_tlb_req_valid_q),
    .req_hart_id_i      (l2_tlb_req_hart_id_q),
    .req_vaddr_i        (l2_tlb_req_vaddr_q),
    .req_ready_o        (l2_tlb_req_ready),
    .resp_valid_o       (l2_resp_valid),
    .resp_hart_id_o     (l2_resp_hart_id),
    .resp_paddr_o       (l2_resp_paddr),
    .resp_fault_o       (l2_resp_fault),
    .ptw_req_valid_o    (l2_ptw_req_valid),
    .ptw_req_hart_id_o  (l2_ptw_req_hart_id),
    .ptw_req_vaddr_o    (l2_ptw_req_vaddr),
    .ptw_req_ready_i    (ptw_req_ready),
    .ptw_resp_valid_i   (ptw_resp_valid),
    .ptw_resp_hart_id_i (ptw_resp_hart_id),
    .ptw_resp_paddr_i   (ptw_resp_paddr),
    .ptw_resp_fault_i   (ptw_resp_fault),
    .flush_i            (|sfence_flush_i)
  );

  // --------------------------------------------------------------------------
  // Hardware Page Table Walker (PTW)
  // --------------------------------------------------------------------------
  sukuna_ptw #(
    .VADDR_WIDTH(VADDR_WIDTH),
    .PADDR_WIDTH(PADDR_WIDTH),
    .XLEN       (XLEN)
  ) u_ptw (
    .clk_i            (clk_i),
    .rst_ni           (rst_ni),
    .req_valid_i      (l2_ptw_req_valid),
    .req_hart_id_i    (l2_ptw_req_hart_id),
    .req_vaddr_i      (l2_ptw_req_vaddr),
    .req_ready_o      (ptw_req_ready),
    .resp_valid_o     (ptw_resp_valid),
    .resp_hart_id_o   (ptw_resp_hart_id),
    .resp_paddr_o     (ptw_resp_paddr),
    .resp_fault_o     (ptw_resp_fault),
    .satp_hart0_i     (satp_hart0_i),
    .satp_hart1_i     (satp_hart1_i),
    .satp_hart2_i     (satp_hart2_i),
    .mem_req_valid_o  (ptw_mem_req_valid_o),
    .mem_req_paddr_w_o(ptw_mem_req_paddr_w_o),
    .mem_req_ready_i  (ptw_mem_req_ready_i),
    .mem_resp_valid_i (ptw_mem_resp_valid_i),
    .mem_resp_data_i  (ptw_mem_resp_data_i)
  );

  // --------------------------------------------------------------------------
  // Arbiter Tracking and Response Demultiplexing
  // --------------------------------------------------------------------------
  always @(*) begin
    refill_resp_valid = 6'd0;
    refill_paddr_flat = {6*(PADDR_WIDTH-2){1'b0}};
    refill_fault      = 6'd0;

    if (l2_resp_valid) begin
      refill_resp_valid[arb_winner_q] = 1'b1;
      refill_paddr_flat[arb_winner_q*(PADDR_WIDTH-2) +: (PADDR_WIDTH-2)] = l2_resp_paddr[PADDR_WIDTH-1:2];
      refill_fault[arb_winner_q]      = l2_resp_fault;
    end
  end

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      arb_winner_q         <= 3'd0;
      arb_busy_q           <= 1'b0;
      l2_tlb_req_valid_q   <= 1'b0;
      l2_tlb_req_hart_id_q <= 2'd0;
      l2_tlb_req_vaddr_q   <= {VADDR_WIDTH{1'b0}};
    end else begin
      if (!arb_busy_q && (|req_vec)) begin
        arb_winner_q         <= next_grant;
        arb_busy_q           <= 1'b1;
        l2_tlb_req_valid_q   <= 1'b1;
        l2_tlb_req_hart_id_q <= next_grant[2:0] >= 3'd3 ? (next_grant[1:0] - 2'd3) : next_grant[1:0];
        l2_tlb_req_vaddr_q   <= {refill_vaddr_flat[next_grant*(VADDR_WIDTH-2) +: (VADDR_WIDTH-2)], 2'b00};
      end else begin
        l2_tlb_req_valid_q   <= 1'b0;
        if (arb_busy_q && l2_resp_valid) begin
          arb_busy_q <= 1'b0;
        end
      end
    end
  end

endmodule
