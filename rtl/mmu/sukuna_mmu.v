// ============================================================================
// MMU Subsystem Top-Level (Verilog 2005)
// Contains per-thread micro L1-ITLBs, L1-DTLBs, Shared L2-TLB, and Hardware PTW
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

  // Instantiations of 3x L1-ITLB
  genvar h;
  generate
    for (h = 0; h < NUM_HARTS; h = h + 1) begin : gen_itlb
      sukuna_l1_tlb #(
        .NUM_ENTRIES(`L1_TLB_ENTRIES),
        .VADDR_WIDTH(VADDR_WIDTH),
        .PADDR_WIDTH(PADDR_WIDTH)
      ) u_itlb (
        .clk_i              (clk_i),
        .rst_ni             (rst_ni),
        .lookup_valid_i     (itlb_lookup_valid_i[h]),
        .vaddr_w_i          (itlb_vaddr_w_i[h*(VADDR_WIDTH-2) +: (VADDR_WIDTH-2)]),
        .hit_o              (itlb_hit_o[h]),
        .paddr_w_o          (itlb_paddr_w_o[h*(PADDR_WIDTH-2) +: (PADDR_WIDTH-2)]),
        .page_fault_o       (itlb_page_fault_o[h]),
        .refill_req_o       (),
        .refill_vaddr_w_o   (),
        .refill_resp_valid_i(1'b0),
        .refill_paddr_w_i   ({(PADDR_WIDTH-2){1'b0}}),
        .refill_fault_i     (1'b0),
        .flush_i            (sfence_flush_i[h])
      );

      sukuna_l1_tlb #(
        .NUM_ENTRIES(`L1_TLB_ENTRIES),
        .VADDR_WIDTH(VADDR_WIDTH),
        .PADDR_WIDTH(PADDR_WIDTH)
      ) u_dtlb (
        .clk_i              (clk_i),
        .rst_ni             (rst_ni),
        .lookup_valid_i     (dtlb_lookup_valid_i[h]),
        .vaddr_w_i          (dtlb_vaddr_w_i[h*(VADDR_WIDTH-2) +: (VADDR_WIDTH-2)]),
        .hit_o              (dtlb_hit_o[h]),
        .paddr_w_o          (dtlb_paddr_w_o[h*(PADDR_WIDTH-2) +: (PADDR_WIDTH-2)]),
        .page_fault_o       (dtlb_page_fault_o[h]),
        .refill_req_o       (),
        .refill_vaddr_w_o   (),
        .refill_resp_valid_i(1'b0),
        .refill_paddr_w_i   ({(PADDR_WIDTH-2){1'b0}}),
        .refill_fault_i     (1'b0),
        .flush_i            (sfence_flush_i[h])
      );
    end
  endgenerate

  // Shared L2-TLB
  wire l2_tlb_ptw_req_valid;
  wire [1:0] l2_tlb_ptw_req_hart_id;
  wire [VADDR_WIDTH-1:0] l2_tlb_ptw_req_vaddr;
  wire ptw_resp_valid;
  wire [1:0] ptw_resp_hart_id;
  wire [PADDR_WIDTH-1:0] ptw_resp_paddr;
  wire ptw_resp_fault;

  sukuna_l2_tlb #(
    .NUM_ENTRIES(`L2_TLB_ENTRIES),
    .VADDR_WIDTH(VADDR_WIDTH),
    .PADDR_WIDTH(PADDR_WIDTH)
  ) u_l2_tlb (
    .clk_i              (clk_i),
    .rst_ni             (rst_ni),
    .req_valid_i        (1'b0),
    .req_hart_id_i      (2'b00),
    .req_vaddr_i        ({VADDR_WIDTH{1'b0}}),
    .req_ready_o        (),
    .resp_valid_o       (),
    .resp_hart_id_o     (),
    .resp_paddr_o       (),
    .resp_fault_o       (),
    .ptw_req_valid_o    (l2_tlb_ptw_req_valid),
    .ptw_req_hart_id_o  (l2_tlb_ptw_req_hart_id),
    .ptw_req_vaddr_o    (l2_tlb_ptw_req_vaddr),
    .ptw_req_ready_i    (1'b1),
    .ptw_resp_valid_i   (ptw_resp_valid),
    .ptw_resp_paddr_i   (ptw_resp_paddr),
    .ptw_resp_fault_i   (ptw_resp_fault),
    .flush_i            (|sfence_flush_i)
  );

  // Shared Page Table Walker
  sukuna_ptw #(
    .VADDR_WIDTH(VADDR_WIDTH),
    .PADDR_WIDTH(PADDR_WIDTH),
    .XLEN       (XLEN)
  ) u_ptw (
    .clk_i            (clk_i),
    .rst_ni           (rst_ni),
    .req_valid_i      (l2_tlb_ptw_req_valid),
    .req_hart_id_i    (l2_tlb_ptw_req_hart_id),
    .req_vaddr_i      (l2_tlb_ptw_req_vaddr),
    .req_ready_o      (),
    .resp_valid_o     (ptw_resp_valid),
    .resp_hart_id_o   (ptw_resp_hart_id),
    .resp_paddr_o     (ptw_resp_paddr),
    .resp_fault_o     (ptw_resp_fault),
    .satp_hart0_i     (satp_hart0_i),
    .satp_hart1_i     (satp_hart1_i),
    .satp_hart2_i     (satp_hart2_i),
    .mem_req_valid_o  (ptw_mem_req_valid_o),
    .mem_req_paddr_w_o  (ptw_mem_req_paddr_w_o),
    .mem_req_ready_i  (ptw_mem_req_ready_i),
    .mem_resp_valid_i (ptw_mem_resp_valid_i),
    .mem_resp_data_i  (ptw_mem_resp_data_i)
  );

endmodule
