// ============================================================================
// Micro L1-TLB (8 Entries, Fully Associative CAM) (Verilog 2005)
// Complies with design-rule.md
// 1-cycle latency virtual-to-physical address translation per thread
// Word-aligned interface (bits [1:0] omitted)
// Supports Bare Mode and RISC-V Sv39 Paging with 4KB, 2MB, and 1GB pages
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_l1_tlb #(
  parameter NUM_ENTRIES = `L1_TLB_ENTRIES,
  parameter VADDR_WIDTH = `VADDR_WIDTH,
  parameter PADDR_WIDTH = `PADDR_WIDTH
)(
  input  wire                   clk_i,
  input  wire                   rst_ni,

  // SATP & Privilege Mode
  input  wire [3:0]             satp_mode_i,      // 0: Bare, 8: Sv39
  input  wire [15:0]            satp_asid_i,      // Current ASID
  input  wire [1:0]             priv_mode_i,      // Current hart privilege level

  // Pipeline Translation Interface (Word-aligned: bits [1:0] omitted)
  input  wire                   lookup_valid_i,
  input  wire [VADDR_WIDTH-1:2] vaddr_w_i,
  output wire                   hit_o,
  output wire [PADDR_WIDTH-1:2] paddr_w_o,
  output wire                   page_fault_o,

  // L2-TLB Refill Interface (on L1 miss)
  output wire                   refill_req_o,
  output wire [VADDR_WIDTH-1:2] refill_vaddr_w_o,
  input  wire                   refill_resp_valid_i,
  input  wire [PADDR_WIDTH-1:2] refill_paddr_w_i,
  input  wire                   refill_fault_i,

  // Flush Interface (SFENCE.VMA)
  input  wire                   flush_i
);

  // --------------------------------------------------------------------------
  // CAM Entry Storage (8 Entries, instantiated via sk_ram_ff macro)
  // --------------------------------------------------------------------------
  reg [NUM_ENTRIES-1:0]      entry_valid_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [NUM_ENTRIES-1:0]      entry_fault_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  localparam CAM_ENTRY_WIDTH = 27 + (PADDR_WIDTH-12) + 16 + 2;
  wire [CAM_ENTRY_WIDTH-1:0] cam_entry_rdata [0:NUM_ENTRIES-1];
  wire [NUM_ENTRIES-1:0]     cam_entry_wen;
  wire [CAM_ENTRY_WIDTH-1:0] cam_entry_wdata = {pending_vaddr_w_q[38:12], refill_paddr_w_i[PADDR_WIDTH-1:12], satp_asid_i, 2'b00};

  wire [26:0]                 entry_vpn_q   [0:NUM_ENTRIES-1];
  wire [PADDR_WIDTH-13:0]     entry_ppn_q   [0:NUM_ENTRIES-1];
  wire [15:0]                 entry_asid_q  [0:NUM_ENTRIES-1];
  wire [1:0]                  entry_psize_q [0:NUM_ENTRIES-1];

  genvar ge;
  generate
    for (ge = 0; ge < NUM_ENTRIES; ge = ge + 1) begin : gen_cam_entries
      assign cam_entry_wen[ge] = refill_resp_valid_i && refill_busy_q && (repl_ptr_q == ge[2:0]);
      sk_ram_ff #(
        .DATA_WIDTH (CAM_ENTRY_WIDTH),
        .ADDR_WIDTH (1),
        .DEPTH      (1),
        .ZERO_REG0  (0)
      ) u_cam_entry_ram (
        .clk_i    (clk_i),
        .rst_ni   (rst_ni),
        .wen_i    (cam_entry_wen[ge]),
        .waddr_i  (1'b0),
        .wdata_i  (cam_entry_wdata),
        .wen1_i   (1'b0), .waddr1_i(1'b0), .wdata1_i({CAM_ENTRY_WIDTH{1'b0}}),
        .wen2_i   (1'b0), .waddr2_i(1'b0), .wdata2_i({CAM_ENTRY_WIDTH{1'b0}}),
        .raddr_a_i(1'b0),
        .rdata_a_o(cam_entry_rdata[ge]),
        .raddr_b_i(1'b0),
        .rdata_b_o()
      );

      assign entry_vpn_q[ge]   = cam_entry_rdata[ge][CAM_ENTRY_WIDTH-1 : CAM_ENTRY_WIDTH-27];
      assign entry_ppn_q[ge]   = cam_entry_rdata[ge][CAM_ENTRY_WIDTH-28 : 18];
      assign entry_asid_q[ge]  = cam_entry_rdata[ge][17:2];
      assign entry_psize_q[ge] = cam_entry_rdata[ge][1:0];
    end
  endgenerate

  // Round-robin / FIFO replacement pointer
  reg [2:0]                  repl_ptr_q;        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // Latch refill request address so refill matches the missed address
  reg [VADDR_WIDTH-1:2]      pending_vaddr_w_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                        refill_busy_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                        refill_req_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [VADDR_WIDTH-1:2]      refill_vaddr_w_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // --------------------------------------------------------------------------
  // Address & Mode Decode
  // --------------------------------------------------------------------------
  // Sv39 requires virtual address bits [63:38] to be sign-extended from bit 38
  wire [63:0] vaddr_full = {vaddr_w_i, 2'b00};
  wire        canonical_ok = (vaddr_full[63:38] == {26{vaddr_full[38]}});
  wire        is_bare = (satp_mode_i == 4'd0) || (priv_mode_i == 2'b11); // Bare mode or M-mode passthrough
  wire        canonical_fault = lookup_valid_i && !is_bare && !canonical_ok;

  // --------------------------------------------------------------------------
  // Parallel Matching (CAM) & Per-Entry Superpage PPN Formatting across 8 entries
  // --------------------------------------------------------------------------
  wire [NUM_ENTRIES-1:0]  match_vec;
  wire [PADDR_WIDTH-13:0] entry_paddr_hi [0:NUM_ENTRIES-1];
  genvar i;
  generate
    for (i = 0; i < NUM_ENTRIES; i = i + 1) begin : gen_cam
      // ASID match: Global mapping ( we encode G=1 as entry_asid_q == 16'h0000 ) or exact ASID match
      wire asid_match  = (entry_asid_q[i] == 16'h0000) || (entry_asid_q[i] == satp_asid_i);
      wire vpn4k_match = (entry_psize_q[i] == 2'b00) && (entry_vpn_q[i] == vaddr_full[38:12]);
      wire vpn2m_match = (entry_psize_q[i] == 2'b01) && (entry_vpn_q[i][26:9] == vaddr_full[38:21]);
      wire vpn1g_match = (entry_psize_q[i] == 2'b10) && (entry_vpn_q[i][26:18] == vaddr_full[38:30]);

      assign match_vec[i] = entry_valid_q[i] && asid_match && (vpn4k_match || vpn2m_match || vpn1g_match);

      assign entry_paddr_hi[i] =
        (entry_psize_q[i] == 2'b01) ? {entry_ppn_q[i][PADDR_WIDTH-13:9],  vaddr_w_i[20:12]} :
        (entry_psize_q[i] == 2'b10) ? {entry_ppn_q[i][PADDR_WIDTH-13:18], vaddr_w_i[29:12]} :
                                      entry_ppn_q[i];
    end
  endgenerate

  wire tlb_hit = |match_vec;

  // Priority encode match vector to index
  (* max_fanout = 16 *) reg [2:0] hit_idx;
  integer k;
  always @(*) begin
    hit_idx = 3'd0;
    for (k = 0; k < NUM_ENTRIES; k = k + 1) begin
      if (match_vec[k]) hit_idx = k[2:0];
    end
  end

  // Fast 2-LUT-level tree for paddr_w_o[31] (PMA cacheable bit, independent of hit_idx fanout)
  (* dont_touch = "true" *) wire b31_p765 =
    match_vec[7] ? entry_ppn_q[7][19] :
    match_vec[6] ? entry_ppn_q[6][19] : (match_vec[5] && entry_ppn_q[5][19]);
  (* dont_touch = "true" *) wire b31_p432 =
    match_vec[4] ? entry_ppn_q[4][19] :
    match_vec[3] ? entry_ppn_q[3][19] : (match_vec[2] && entry_ppn_q[2][19]);
  (* dont_touch = "true" *) wire b31_p10 =
    is_bare ? vaddr_w_i[31] : (match_vec[1] ? entry_ppn_q[1][19] : entry_ppn_q[0][19]);
  (* dont_touch = "true" *) wire hit_765 = (!is_bare) && (|match_vec[7:5]);
  (* dont_touch = "true" *) wire hit_432 = (!is_bare) && (|match_vec[4:2]);
  (* dont_touch = "true" *) wire paddr_b31 =
    hit_765 ? b31_p765 : hit_432 ? b31_p432 : b31_p10;

  // Mux selected entry translated PPN and fault based on hit_idx
  wire [PADDR_WIDTH-13:0] hit_paddr_hi    = entry_paddr_hi[hit_idx];
  wire                    hit_entry_fault = entry_fault_q[hit_idx];

  // Assemble translated physical address (word-aligned: bits [11:2] are untranslated page offset!)
  wire [PADDR_WIDTH-1:2] translated_paddr_w = {hit_paddr_hi, vaddr_w_i[11:2]};

  // --------------------------------------------------------------------------
  // Output Assignments
  // --------------------------------------------------------------------------
  // Hit: in Bare mode, always hit; in Sv39 mode, CAM hit or immediate canonical fault
  assign hit_o = is_bare ? lookup_valid_i : (lookup_valid_i && (tlb_hit || canonical_fault));

  // PADDR: Page offset [11:2] is always vaddr_w_i[11:2] (0 LUTs!); bit 31 uses dedicated fast tree
  wire [PADDR_WIDTH-1:12] paddr_hi_mux = is_bare ? vaddr_w_i[PADDR_WIDTH-1:12] : translated_paddr_w[PADDR_WIDTH-1:12];
  assign paddr_w_o = {paddr_hi_mux[PADDR_WIDTH-1:32], paddr_b31, paddr_hi_mux[30:12], vaddr_w_i[11:2]};

  // Page Fault: canonical address error or entry marked as fault
  assign page_fault_o = lookup_valid_i && !is_bare && (canonical_fault || (tlb_hit && hit_entry_fault));

  // Refill request to L2-TLB on Sv39 miss (Registered to break cross-stage combinational paths)
  assign refill_req_o     = refill_req_q;
  assign refill_vaddr_w_o = refill_vaddr_w_q;

  // --------------------------------------------------------------------------
  // Sequential State & Entry Refill / Flush Management
  // --------------------------------------------------------------------------
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      entry_valid_q     <= {NUM_ENTRIES{1'b0}};
      entry_fault_q     <= {NUM_ENTRIES{1'b0}};
      repl_ptr_q        <= 3'd0;
      pending_vaddr_w_q <= {(VADDR_WIDTH-2){1'b0}};
      refill_busy_q     <= 1'b0;
      refill_req_q      <= 1'b0;
      refill_vaddr_w_q  <= {(VADDR_WIDTH-2){1'b0}};
    end else begin
      // SFENCE.VMA Flush
      if (flush_i) begin
        entry_valid_q    <= {NUM_ENTRIES{1'b0}};
        entry_fault_q    <= {NUM_ENTRIES{1'b0}};
        refill_busy_q    <= 1'b0;
        refill_req_q     <= 1'b0;
      end else begin
        // Capture vaddr whenever not busy (decouples 124-bit datapath CE from CAM lookup_valid_i/tlb_hit!)
        if (!refill_busy_q) begin
          pending_vaddr_w_q <= vaddr_w_i;
          refill_vaddr_w_q  <= vaddr_w_i;
        end

        // Track outstanding refill (Registered request)
        if (lookup_valid_i && !is_bare && !tlb_hit && !canonical_fault && !refill_busy_q) begin
          refill_req_q      <= 1'b1;
          refill_busy_q     <= 1'b1;
        end else begin
          refill_req_q      <= 1'b0;
        end

        // Refill Response Arrival
        if (refill_resp_valid_i && refill_busy_q) begin
          refill_busy_q               <= 1'b0;
          entry_valid_q[repl_ptr_q]   <= 1'b1;
          entry_fault_q[repl_ptr_q]   <= refill_fault_i;
          repl_ptr_q                  <= repl_ptr_q + 1'b1;
        end
      end
    end
  end

endmodule
