// ============================================================================
// Sukuna-RISC: Dedicated 3-Stage Memory Access Execution Unit (MA-EU) (Verilog 2005)
// Complies with style.md (ASIC 5nm 1.5GHz & Kintex-7)
// ============================================================================
// Pipeline Stages:
//   Stage 1 (ADDR): Dedicated 64-bit address calculation (sk_add) & byte enables
//   Stage 2 (MA1) : DTLB translation & L1D cache read/write request dispatch
//   Stage 3 (MA2) : L1D BRAM read latency; registers raw data into holding buffer
//   WB Stage (WB) : Direct alignment rotator and sign-extension driving WB stage
// ============================================================================

`timescale 1ns / 1ps
`default_nettype none

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
  input  wire [XLEN-1:0]        req_pc_i,
  input  wire [7:0]             req_op_i,
  input  wire [4:0]             req_rd_i,
  input  wire [XLEN-1:0]        req_base_i,
  input  wire [XLEN-1:0]        req_offset_i,
  input  wire [XLEN-1:0]        req_wdata_i,
  output wire                   busy_o,
  output wire                   s1_valid_o,
  output wire [4:0]             s1_rd_o,
  output wire                   s1_is_fp_o,
  output wire                   s2_valid_o,
  output wire [4:0]             s2_rd_o,
  output wire                   s2_is_fp_o,
  output wire                   miss_or_amo_stall_o,

  // Snoop invalidation input (for multi-hart LR/SC reservation clearing)
  input  wire                   snoop_inv_valid_i,
  input  wire [PADDR_WIDTH-1:2] snoop_inv_paddr_w_i,

  // DTLB Address Translation (Word-aligned address)
  output wire                   dtlb_lookup_valid_o,
  output wire [VADDR_WIDTH-1:2] dtlb_vaddr_w_o,
  input  wire                   dtlb_hit_i,
  input  wire [PADDR_WIDTH-1:2] dtlb_paddr_w_i,
  input  wire                   dtlb_fault_i,

  // Dedicated L1D Port (Word-aligned address & byte-enable)
  output wire                   l1d_req_valid_o,
  output wire                   l1d_req_write_o,
  output wire [3:0]             l1d_req_op_o,
  output wire [7:0]             l1d_req_byte_en_o,
  output wire [PADDR_WIDTH-1:2] l1d_paddr_w_o,
  output wire [XLEN-1:0]        l1d_wdata_o,
  input  wire                   l1d_req_ready_i,
  input  wire                   l1d_resp_valid_i,
  input  wire [XLEN-1:0]        l1d_rdata_i,
  input  wire                   l1d_miss_stall_i,

  // Dedicated Uncached / MMIO Port
  output wire                   uncached_req_valid_o,
  output wire                   uncached_req_write_o,
  output wire [3:0]             uncached_req_op_o,
  output wire [7:0]             uncached_req_byte_en_o,
  output wire [PADDR_WIDTH-1:2] uncached_req_paddr_w_o,
  output wire [XLEN-1:0]        uncached_req_wdata_o,
  input  wire                   uncached_req_ready_i,
  input  wire                   uncached_resp_valid_i,
  input  wire [XLEN-1:0]        uncached_resp_rdata_i,

  // Output to Writeback Stage
  output wire                   resp_valid_o,
  output wire [XLEN-1:0]        resp_pc_o,
  output wire [4:0]             resp_rd_o,
  output wire [XLEN-1:0]        resp_rdata_o,
  output wire                   resp_writes_fpr_o
);

  // --------------------------------------------------------------------------
  // Stage 1: ADDR (Address Calculation & Byte Enables)
  // --------------------------------------------------------------------------
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

  wire [2:0] addr_lsb = calc_vaddr[2:0];
  reg [7:0]  calc_byte_en;
  always @(*) begin
    case (req_op_i[1:0])
      2'b00: calc_byte_en = 8'b00000001 << addr_lsb;
      2'b01: calc_byte_en = 8'b00000011 << {addr_lsb[2:1], 1'b0};
      2'b10: calc_byte_en = addr_lsb[2] ? 8'b11110000 : 8'b00001111;
      2'b11: calc_byte_en = 8'b11111111;
    endcase
  end

  reg [XLEN-1:0] calc_aligned_wdata;
  always @(*) begin
    case (req_op_i[1:0])
      2'b00: calc_aligned_wdata = {8{req_wdata_i[7:0]}};
      2'b01: calc_aligned_wdata = {4{req_wdata_i[15:0]}};
      2'b10: calc_aligned_wdata = {2{req_wdata_i[31:0]}};
      2'b11: calc_aligned_wdata = req_wdata_i;
    endcase
  end

  // Stage 1 Registers (ADDR -> MA1)
  reg                     s1_valid_q;        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]          s1_pc_q;           /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [7:0]               s1_op_q;           /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [4:0]               s1_rd_q;           /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [VADDR_WIDTH-1:2]   s1_vaddr_w_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [2:0]               s1_addr_lsb_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [7:0]               s1_byte_en_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]          s1_wdata_q;        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]          s1_orig_wdata_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                     s1_wait_q;         /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // --------------------------------------------------------------------------
  // Stage 2: MA1 (DTLB Translation & L1D Request Setup)
  // --------------------------------------------------------------------------
  wire [3:0] s1_amo_type = s1_op_q[7:4];
  wire s1_is_lr          = (s1_amo_type == `AMO_LR);
  wire s1_is_sc          = (s1_amo_type == `AMO_SC);
  wire s1_is_alu_amo     = (s1_amo_type >= `AMO_SWAP && s1_amo_type <= `AMO_MAXU);

  // DTLB Address Translation lookup
  assign dtlb_lookup_valid_o = s1_valid_q;
  assign dtlb_vaddr_w_o      = s1_vaddr_w_q;

  // AMO State Machine and Reservation Registers
  localparam S_AGU_IDLE  = 2'd0;
  localparam S_AGU_SC    = 2'd1;
  localparam S_AGU_ALU   = 2'd2;
  localparam S_AGU_STORE = 2'd3;

  reg [1:0]               agu_state_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                     res_valid_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [PADDR_WIDTH-1:2]   res_paddr_w_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [PADDR_WIDTH-1:2]   store_paddr_w_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]          amo_rdata_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]          amo_wdata_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                     amo_req_sent_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                     s2_snoop_hit_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                     sc_failed_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                     sc_success_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  wire snoop_res_hit = snoop_inv_valid_i && (snoop_inv_paddr_w_i[PADDR_WIDTH-1:6] == res_paddr_w_q[PADDR_WIDTH-1:6]);
  wire snoop_s2_hit  = snoop_inv_valid_i && (snoop_inv_paddr_w_i[PADDR_WIDTH-1:6] == s2_paddr_w_q[PADDR_WIDTH-1:6]);
  wire snoop_s1_hit  = snoop_inv_valid_i && (snoop_inv_paddr_w_i[PADDR_WIDTH-1:6] == dtlb_paddr_w_i[PADDR_WIDTH-1:6]);
  wire sc_match      = res_valid_q && !snoop_res_hit && (res_paddr_w_q == store_paddr_w_q);

  // Physical Memory Attribute (PMA): RAM is >= 0x8000_0000; Devices / MMIO are < 0x8000_0000
  wire is_uncached = !dtlb_paddr_w_i[31];

  // L1D Request Driving (driven during MA1, SC check, or AMO STORE)
  wire is_amo_or_sc_req      = (agu_state_q == S_AGU_STORE) || (agu_state_q == S_AGU_SC);
  assign l1d_paddr_w_o       = is_amo_or_sc_req ? store_paddr_w_q : dtlb_paddr_w_i;
  assign l1d_req_op_o        = is_amo_or_sc_req ? s2_op_q[7:4] : s1_op_q[7:4];
  assign l1d_req_byte_en_o   = is_amo_or_sc_req ? s2_byte_en_q : s1_byte_en_q;
  assign l1d_wdata_o         = is_amo_or_sc_req ? amo_wdata_q : s1_wdata_q;

  assign l1d_req_valid_o     = (agu_state_q == S_AGU_SC)    ? sc_match :
                               (agu_state_q == S_AGU_STORE) ? !amo_req_sent_q :
                               (s1_valid_q && dtlb_hit_i && !is_uncached && !s1_is_sc);
  assign l1d_req_write_o     = is_amo_or_sc_req             ? 1'b1 :
                               (s1_is_alu_amo || s1_is_sc)  ? 1'b0 : s1_op_q[3];

  // Stage 2 Registers (MA1 -> MA2)
  wire [2:0] s1_sign_byte_idx = (s1_op_q[1:0] == 2'b00) ? s1_addr_lsb_q :
                                (s1_op_q[1:0] == 2'b01) ? (s1_addr_lsb_q + 3'd1) :
                                                          (s1_addr_lsb_q + 3'd3);

  wire       s1_is_flw     = (s1_op_q[7:4] == `AMO_FP) && !s1_op_q[3] && (s1_op_q[2:0] == 3'b010);
  wire       s1_writes_fpr = (s1_op_q[7:4] == `AMO_FP) && !s1_op_q[3];
  wire       s1_l1d_fast   = !is_uncached && !s1_is_alu_amo && !s1_is_sc;
  wire       s1_b0_keep    = s1_l1d_fast;
  wire       s1_b1_keep    = s1_l1d_fast && (s1_op_q[1:0] != 2'b00);
  wire       s1_b1_sign    = s1_l1d_fast && (s1_op_q[1:0] == 2'b00) && !s1_op_q[2];
  wire       s1_h1_keep    = s1_l1d_fast && s1_op_q[1];
  wire       s1_h1_sign    = s1_l1d_fast && !s1_op_q[1] && !s1_op_q[2];
  wire       s1_w1_keep    = s1_l1d_fast && (s1_op_q[1:0] == 2'b11);
  wire       s1_w1_sign    = s1_l1d_fast && (s1_op_q[1:0] != 2'b11) && !s1_op_q[2] && !s1_is_flw;
  wire       s1_w1_one     = s1_is_flw && !s1_is_sc;

  // Pre-encoded 2-bit MUX selects for MA2
  wire [1:0] s1_b0_sel     = !s1_b0_keep                       ? 2'b00 :
                             !s1_addr_lsb_q[2]                 ? 2'b01 : 2'b10;
  wire [1:0] s1_b1_sel     = (s1_b1_keep && !s1_addr_lsb_q[2]) ? 2'b01 :
                             s1_b1_sign                        ? (s1_sign_byte_idx[2] ? 2'b11 : 2'b10) : 2'b00;
  wire [1:0] s1_h1_sel     = (s1_h1_keep && !s1_addr_lsb_q[2]) ? 2'b01 :
                             s1_h1_sign                        ? (s1_sign_byte_idx[2] ? 2'b11 : 2'b10) : 2'b00;
  wire [1:0] s1_w1_sel     = (s1_w1_keep && !s1_addr_lsb_q[2]) ? 2'b01 :
                             s1_w1_sign                        ? (s1_sign_byte_idx[2] ? 2'b11 : 2'b10) : 2'b00;
  wire [1:0] s1_b1_hi_sel  = (s1_b1_keep && s1_addr_lsb_q[2])  ? s1_addr_lsb_q[1:0] : 2'd3;
  wire [1:0] s1_h1_hi_sel  = (s1_h1_keep && s1_addr_lsb_q[2])  ? s1_addr_lsb_q[1:0] : 2'd3;

  reg                     s2_valid_q;             /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]          s2_pc_q;                /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                     s2_is_uncached_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                     s2_uncached_req_sent_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                     s2_is_lr_q;             /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                     s2_is_alu_amo_q;        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                     s2_writes_fpr_q;        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [7:0]               s2_op_q;                /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [7:0]               s2_byte_en_q;           /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [4:0]               s2_rd_q;                /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [2:0]               s2_addr_lsb_q;          /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [2:0]               s2_sign_byte_idx_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [1:0]               s2_b0_sel_q;            /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [1:0]               s2_b1_sel_q;            /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [1:0]               s2_h1_sel_q;            /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [1:0]               s2_w1_sel_q;            /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [1:0]               s2_b1_hi_sel_q;         /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [1:0]               s2_h1_hi_sel_q;         /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* equivalent_register_removal = "no", keep = "true" *) reg [1:0] s2_sign_idx_rep0_q;
  (* equivalent_register_removal = "no", keep = "true" *) reg [1:0] s2_sign_idx_rep1_q;
  (* equivalent_register_removal = "no", keep = "true" *) reg [1:0] s2_sign_idx_rep2_q;
  (* equivalent_register_removal = "no", keep = "true" *) reg [1:0] s2_sign_idx_rep3_q;
  (* equivalent_register_removal = "no", keep = "true" *) reg [1:0] s2_sign_idx_rep4_q;
  (* equivalent_register_removal = "no", keep = "true" *) reg [1:0] s2_sign_idx_rep5_q;
  (* equivalent_register_removal = "no", keep = "true" *) reg [1:0] s2_sign_idx_rep6_q;
  (* equivalent_register_removal = "no", keep = "true" *) reg [1:0] s2_lsb_lo_rep0_q;
  (* equivalent_register_removal = "no", keep = "true" *) reg [1:0] s2_lsb_lo_rep1_q;
  (* equivalent_register_removal = "no", keep = "true" *) reg [1:0] s2_lsb_lo_rep2_q;
  (* equivalent_register_removal = "no", keep = "true" *) reg [1:0] s2_lsb_lo_rep3_q;
  (* equivalent_register_removal = "no", keep = "true" *) reg [1:0] s2_lsb_lo_rep4_q;
  (* equivalent_register_removal = "no", keep = "true" *) reg [1:0] s2_lsb_lo_rep5_q;
  (* equivalent_register_removal = "no", keep = "true" *) reg [1:0] s2_lsb_lo_rep6_q;
  (* equivalent_register_removal = "no", keep = "true" *) reg [1:0] s2_lsb_lo_rep7_q;
  reg                     s2_w1_one_q;            /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [PADDR_WIDTH-1:2]   s2_paddr_w_q;           /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]          s2_wdata_q;             /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]          s2_orig_wdata_q;        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                     s2_wait_q;              /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // Dedicated Uncached Request Driving (driven cleanly from MA2 registers)
  assign uncached_req_valid_o   = s2_valid_q && s2_is_uncached_q && !s2_uncached_req_sent_q;
  assign uncached_req_write_o   = s2_op_q[3];
  assign uncached_req_op_o      = s2_op_q[3:0];
  assign uncached_req_byte_en_o = s2_byte_en_q;
  assign uncached_req_paddr_w_o = s2_paddr_w_q;
  assign uncached_req_wdata_o   = s2_wdata_q;

  // --------------------------------------------------------------------------
  // Stage 3: MA2 (L1D BRAM Read Latency, Parallel Byte Alignment & Sign Extension)
  // --------------------------------------------------------------------------
  wire             resp_valid_in = s2_is_uncached_q ? uncached_resp_valid_i : l1d_resp_valid_i;

  // Replicated 4:1 sign-bit LUT6s (strictly 1 LUT6 level from l1d_rdata_i, fanout == 8 per copy!)
  wire [1:0] s2_sign_idx_rep [0:6];
  assign s2_sign_idx_rep[0] = s2_sign_idx_rep0_q;
  assign s2_sign_idx_rep[1] = s2_sign_idx_rep1_q;
  assign s2_sign_idx_rep[2] = s2_sign_idx_rep2_q;
  assign s2_sign_idx_rep[3] = s2_sign_idx_rep3_q;
  assign s2_sign_idx_rep[4] = s2_sign_idx_rep4_q;
  assign s2_sign_idx_rep[5] = s2_sign_idx_rep5_q;
  assign s2_sign_idx_rep[6] = s2_sign_idx_rep6_q;

  (* dont_touch = "true" *) wire [6:0] s2_sign_lo;
  (* dont_touch = "true" *) wire [6:0] s2_sign_hi;
  genvar c;
  generate
    for (c = 0; c < 7; c = c + 1) begin : g_sign_rep
      assign s2_sign_lo[c] = (s2_sign_idx_rep[c] == 2'd0) ? l1d_rdata_i[7]  :
                             (s2_sign_idx_rep[c] == 2'd1) ? l1d_rdata_i[15] :
                             (s2_sign_idx_rep[c] == 2'd2) ? l1d_rdata_i[23] :
                                                            l1d_rdata_i[31];
      assign s2_sign_hi[c] = (s2_sign_idx_rep[c] == 2'd0) ? l1d_rdata_i[39] :
                             (s2_sign_idx_rep[c] == 2'd1) ? l1d_rdata_i[47] :
                             (s2_sign_idx_rep[c] == 2'd2) ? l1d_rdata_i[55] :
                                                            l1d_rdata_i[63];
    end
  endgenerate

  // Single-LUT6 4:1 byte-aligners for ALL 8 bytes (strictly 1 LUT level from l1d_rdata_i!)
  (* dont_touch = "true" *) wire [7:0] s2_align_b0_lo =
    (s2_lsb_lo_rep0_q == 2'd0) ? l1d_rdata_i[7:0]   :
    (s2_lsb_lo_rep0_q == 2'd1) ? l1d_rdata_i[15:8]  :
    (s2_lsb_lo_rep0_q == 2'd2) ? l1d_rdata_i[23:16] :
                                 l1d_rdata_i[31:24];
  (* dont_touch = "true" *) wire [7:0] s2_align_b0_hi =
    (s2_lsb_lo_rep0_q == 2'd0) ? l1d_rdata_i[39:32] :
    (s2_lsb_lo_rep0_q == 2'd1) ? l1d_rdata_i[47:40] :
    (s2_lsb_lo_rep0_q == 2'd2) ? l1d_rdata_i[55:48] :
                                 l1d_rdata_i[63:56];
  (* dont_touch = "true" *) wire [7:0] s2_align_b1_lo =
    (s2_lsb_lo_rep1_q == 2'd0) ? l1d_rdata_i[15:8]  :
    (s2_lsb_lo_rep1_q == 2'd1) ? l1d_rdata_i[23:16] :
    (s2_lsb_lo_rep1_q == 2'd2) ? l1d_rdata_i[31:24] :
                                 l1d_rdata_i[39:32];
  (* dont_touch = "true" *) wire [7:0] s2_align_b2_lo =
    (s2_lsb_lo_rep2_q == 2'd0) ? l1d_rdata_i[23:16] :
    (s2_lsb_lo_rep2_q == 2'd1) ? l1d_rdata_i[31:24] :
    (s2_lsb_lo_rep2_q == 2'd2) ? l1d_rdata_i[39:32] :
                                 l1d_rdata_i[47:40];
  (* dont_touch = "true" *) wire [7:0] s2_align_b3_lo =
    (s2_lsb_lo_rep3_q == 2'd0) ? l1d_rdata_i[31:24] :
    (s2_lsb_lo_rep3_q == 2'd1) ? l1d_rdata_i[39:32] :
    (s2_lsb_lo_rep3_q == 2'd2) ? l1d_rdata_i[47:40] :
                                 l1d_rdata_i[55:48];
  (* dont_touch = "true" *) wire [7:0] s2_align_b4_lo =
    (s2_lsb_lo_rep4_q == 2'd0) ? l1d_rdata_i[39:32] :
    (s2_lsb_lo_rep4_q == 2'd1) ? l1d_rdata_i[47:40] :
    (s2_lsb_lo_rep4_q == 2'd2) ? l1d_rdata_i[55:48] :
                                 l1d_rdata_i[63:56];
  (* dont_touch = "true" *) wire [7:0] s2_align_b5_lo =
    (s2_lsb_lo_rep5_q == 2'd0) ? l1d_rdata_i[47:40] :
    (s2_lsb_lo_rep5_q == 2'd1) ? l1d_rdata_i[55:48] :
    (s2_lsb_lo_rep5_q == 2'd2) ? l1d_rdata_i[63:56] :
                                 8'd0;
  (* dont_touch = "true" *) wire [7:0] s2_align_b6_lo =
    (s2_lsb_lo_rep6_q == 2'd0) ? l1d_rdata_i[55:48] :
    (s2_lsb_lo_rep6_q == 2'd1) ? l1d_rdata_i[63:56] :
                                 8'd0;
  (* dont_touch = "true" *) wire [7:0] s2_align_b7_lo =
    (s2_lsb_lo_rep7_q == 2'd0) ? l1d_rdata_i[63:56] :
                                 8'd0;

  // Non-critical Uncached / AMO / SC / constant-fill path (decoupled from l1d_rdata_i)
  reg s2_unc_raw_sign;
  always @(*) begin
    case (s2_sign_byte_idx_q)
      3'd0: s2_unc_raw_sign = uncached_resp_rdata_i[7];
      3'd1: s2_unc_raw_sign = uncached_resp_rdata_i[15];
      3'd2: s2_unc_raw_sign = uncached_resp_rdata_i[23];
      3'd3: s2_unc_raw_sign = uncached_resp_rdata_i[31];
      3'd4: s2_unc_raw_sign = uncached_resp_rdata_i[39];
      3'd5: s2_unc_raw_sign = uncached_resp_rdata_i[47];
      3'd6: s2_unc_raw_sign = uncached_resp_rdata_i[55];
      3'd7: s2_unc_raw_sign = uncached_resp_rdata_i[63];
    endcase
  end

  wire s2_unc_sign_ext = s2_unc_raw_sign && !s2_op_q[2];
  wire s2_unc_fill_hi  = s2_w1_one_q ? 1'b1 : s2_unc_sign_ext;

  reg [63:0] s2_unc_aligned;
  always @(*) begin
    case (s2_addr_lsb_q)
      3'd0: s2_unc_aligned = uncached_resp_rdata_i;
      3'd1: s2_unc_aligned = {8'd0,  uncached_resp_rdata_i[63:8]};
      3'd2: s2_unc_aligned = {16'd0, uncached_resp_rdata_i[63:16]};
      3'd3: s2_unc_aligned = {24'd0, uncached_resp_rdata_i[63:24]};
      3'd4: s2_unc_aligned = {32'd0, uncached_resp_rdata_i[63:32]};
      3'd5: s2_unc_aligned = {40'd0, uncached_resp_rdata_i[63:40]};
      3'd6: s2_unc_aligned = {48'd0, uncached_resp_rdata_i[63:48]};
      3'd7: s2_unc_aligned = {56'd0, uncached_resp_rdata_i[63:56]};
    endcase
  end

  reg [XLEN-1:0] s2_unc_formatted;
  always @(*) begin
    case (s2_op_q[1:0])
      2'b00:   s2_unc_formatted = {{56{s2_unc_sign_ext}}, s2_unc_aligned[7:0]};
      2'b01:   s2_unc_formatted = {{48{s2_unc_sign_ext}}, s2_unc_aligned[15:0]};
      2'b10:   s2_unc_formatted = {{32{s2_unc_fill_hi}},  s2_unc_aligned[31:0]};
      default: s2_unc_formatted = s2_unc_aligned;
    endcase
  end

  // AMO ALU Operations (operates on registered amo_rdata_q)
  wire is_word_amo              = (s2_op_q[1:0] == 2'b10);
  wire [31:0] amo_word_shifted  = s2_addr_lsb_q[2] ? amo_rdata_q[63:32] : amo_rdata_q[31:0];
  wire [XLEN-1:0] amo_rdata_fmt = is_word_amo ? {{32{amo_word_shifted[31]}}, amo_word_shifted} : amo_rdata_q;

  wire [63:0] s2_l1d_const_fill = {{32{s2_w1_one_q}}, 32'd0};
  (* dont_touch = "true" *) wire [63:0] s2_non_l1d_data =
    (agu_state_q == S_AGU_SC)    ? 64'd1 :
    (agu_state_q == S_AGU_STORE) ? (sc_success_q ? 64'd0 : amo_rdata_fmt) :
    s2_is_uncached_q             ? s2_unc_formatted :
                                   s2_l1d_const_fill;

  (* dont_touch = "true" *) wire [7:0] s2_align_b1_hi =
    (s2_b1_hi_sel_q == 2'd0) ? l1d_rdata_i[47:40] :
    (s2_b1_hi_sel_q == 2'd1) ? l1d_rdata_i[55:48] :
    (s2_b1_hi_sel_q == 2'd2) ? l1d_rdata_i[63:56] :
                               s2_non_l1d_data[15:8];
  (* dont_touch = "true" *) wire [7:0] s2_align_b2_hi =
    (s2_h1_hi_sel_q == 2'd0) ? l1d_rdata_i[55:48] :
    (s2_h1_hi_sel_q == 2'd1) ? l1d_rdata_i[63:56] :
                               s2_non_l1d_data[23:16];
  (* dont_touch = "true" *) wire [7:0] s2_align_b3_hi =
    (s2_h1_hi_sel_q == 2'd0) ? l1d_rdata_i[63:56] :
                               s2_non_l1d_data[31:24];

  // Single-LUT6 4:1 final merge per bit into buf_raw_data_q (strictly 2 LUT levels total from l1d_rdata_i!)
  (* dont_touch = "true" *) wire [63:0] s2_next_buf_data;
  assign s2_next_buf_data[7:0]   = (s2_b0_sel_q == 2'b01) ? s2_align_b0_lo :
                                   (s2_b0_sel_q == 2'b10) ? s2_align_b0_hi :
                                                            s2_non_l1d_data[7:0];
  assign s2_next_buf_data[15:8]  = (s2_b1_sel_q == 2'b01) ? s2_align_b1_lo :
                                   (s2_b1_sel_q == 2'b10) ? {8{s2_sign_lo[0]}} :
                                   (s2_b1_sel_q == 2'b11) ? {8{s2_sign_hi[0]}} :
                                                            s2_align_b1_hi;
  assign s2_next_buf_data[23:16] = (s2_h1_sel_q == 2'b01) ? s2_align_b2_lo :
                                   (s2_h1_sel_q == 2'b10) ? {8{s2_sign_lo[1]}} :
                                   (s2_h1_sel_q == 2'b11) ? {8{s2_sign_hi[1]}} :
                                                            s2_align_b2_hi;
  assign s2_next_buf_data[31:24] = (s2_h1_sel_q == 2'b01) ? s2_align_b3_lo :
                                   (s2_h1_sel_q == 2'b10) ? {8{s2_sign_lo[2]}} :
                                   (s2_h1_sel_q == 2'b11) ? {8{s2_sign_hi[2]}} :
                                                            s2_align_b3_hi;
  assign s2_next_buf_data[39:32] = (s2_w1_sel_q == 2'b01) ? s2_align_b4_lo :
                                   (s2_w1_sel_q == 2'b10) ? {8{s2_sign_lo[3]}} :
                                   (s2_w1_sel_q == 2'b11) ? {8{s2_sign_hi[3]}} :
                                                            s2_non_l1d_data[39:32];
  assign s2_next_buf_data[47:40] = (s2_w1_sel_q == 2'b01) ? s2_align_b5_lo :
                                   (s2_w1_sel_q == 2'b10) ? {8{s2_sign_lo[4]}} :
                                   (s2_w1_sel_q == 2'b11) ? {8{s2_sign_hi[4]}} :
                                                            s2_non_l1d_data[47:40];
  assign s2_next_buf_data[55:48] = (s2_w1_sel_q == 2'b01) ? s2_align_b6_lo :
                                   (s2_w1_sel_q == 2'b10) ? {8{s2_sign_lo[5]}} :
                                   (s2_w1_sel_q == 2'b11) ? {8{s2_sign_hi[5]}} :
                                                            s2_non_l1d_data[55:48];
  assign s2_next_buf_data[63:56] = (s2_w1_sel_q == 2'b01) ? s2_align_b7_lo :
                                   (s2_w1_sel_q == 2'b10) ? {8{s2_sign_lo[6]}} :
                                   (s2_w1_sel_q == 2'b11) ? {8{s2_sign_hi[6]}} :
                                                            s2_non_l1d_data[63:56];

  // WB Output Holding Registers (Pure FF outputs to WB / EX forwarding)
  reg                     buf_valid_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]          buf_pc_q;          /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [63:0]              buf_raw_data_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [4:0]               buf_rd_q;          /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                     buf_writes_fpr_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  wire [XLEN-1:0] amo_src1 = amo_rdata_fmt;
  wire [XLEN-1:0] amo_src2 = s2_orig_wdata_q;

  wire signed [31:0] s32_src1 = amo_src1[31:0];
  wire signed [31:0] s32_src2 = amo_src2[31:0];
  wire signed [63:0] s64_src1 = amo_src1;
  wire signed [63:0] s64_src2 = amo_src2;

  wire [63:0] amo_sum = amo_src1 + amo_src2;

  wire signed [63:0] cmp_s1 = is_word_amo ? {{32{s32_src1[31]}}, s32_src1} : s64_src1;
  wire signed [63:0] cmp_s2 = is_word_amo ? {{32{s32_src2[31]}}, s32_src2} : s64_src2;
  wire [63:0]        cmp_u1 = is_word_amo ? {32'd0, amo_src1[31:0]} : amo_src1;
  wire [63:0]        cmp_u2 = is_word_amo ? {32'd0, amo_src2[31:0]} : amo_src2;

  wire cmp_gt_s = (cmp_s1 > cmp_s2);
  wire cmp_gt_u = (cmp_u1 > cmp_u2);

  reg [XLEN-1:0] calc_amo_result;
  always @(*) begin
    case (s2_op_q[7:4])
      `AMO_SWAP: calc_amo_result = amo_src2;
      `AMO_ADD:  calc_amo_result = amo_sum;
      `AMO_AND:  calc_amo_result = amo_src1 & amo_src2;
      `AMO_OR:   calc_amo_result = amo_src1 | amo_src2;
      `AMO_XOR:  calc_amo_result = amo_src1 ^ amo_src2;
      `AMO_MAX:  calc_amo_result = cmp_gt_s ? amo_src1 : amo_src2;
      `AMO_MIN:  calc_amo_result = !cmp_gt_s ? amo_src1 : amo_src2;
      `AMO_MAXU: calc_amo_result = cmp_gt_u ? amo_src1 : amo_src2;
      `AMO_MINU: calc_amo_result = !cmp_gt_u ? amo_src1 : amo_src2;
      default:   calc_amo_result = amo_src2;
    endcase
  end

  wire [XLEN-1:0] amo_wdata_aligned = is_word_amo ? {2{calc_amo_result[31:0]}} : calc_amo_result;

  // Response Signals to WB (0 logic levels: direct flip-flop outputs)
  assign resp_valid_o      = buf_valid_q;
  assign resp_writes_fpr_o = buf_writes_fpr_q;
  assign resp_pc_o         = buf_pc_q;
  assign resp_rd_o         = buf_rd_q;
  assign resp_rdata_o      = buf_raw_data_q;

  // Unit Busy Signal: High while any stage holds valid operations or waiting for cache/amo
  // Driven strictly by registered state flags to prevent combinational feedthrough
  assign busy_o              = s1_valid_q || s2_valid_q || (agu_state_q != S_AGU_IDLE) || sc_failed_q;
  assign s1_valid_o          = s1_valid_q;
  assign s1_rd_o             = s1_rd_q;
  assign s1_is_fp_o          = (s1_op_q[7:4] == `AMO_FP);
  assign s2_valid_o          = s2_valid_q;
  assign s2_rd_o             = s2_rd_q;
  assign s2_is_fp_o          = (s2_op_q[7:4] == `AMO_FP);
  assign miss_or_amo_stall_o = s1_wait_q || s2_wait_q || (agu_state_q != S_AGU_IDLE) || sc_failed_q ||
                               (s1_valid_q && (s1_op_q[7:4] == `AMO_FP) && !s1_op_q[3]) ||
                               (s2_valid_q && s2_writes_fpr_q);

  // Pre-computed datapath clock enables (0 logic levels from l1d_resp_valid_i / req_valid_i)
  wire s1_accept_rdy = (agu_state_q == S_AGU_IDLE) && !s1_valid_q && !s2_valid_q && !sc_failed_q;
  wire s2_load_en    = (agu_state_q == S_AGU_IDLE) && s1_valid_q && !s2_valid_q;
  wire buf_data_en   = (agu_state_q == S_AGU_IDLE) ? (s2_valid_q && !s2_is_alu_amo_q) :
                       (agu_state_q == S_AGU_SC)   ? !sc_match :
                                                     (agu_state_q == S_AGU_STORE);
  wire amo_rdata_en  = (agu_state_q == S_AGU_IDLE) && s2_valid_q && s2_is_alu_amo_q;
  wire res_paddr_en  = (agu_state_q == S_AGU_IDLE) && s2_valid_q && s2_is_lr_q;

  // Pre-computed single-LUT3 branches on l1d_resp_valid_i for control flip-flops
  wire res_keep      = res_valid_q && !snoop_res_hit;
  wire res_on_s2_fin = s2_is_lr_q ? !(s2_snoop_hit_q || snoop_s2_hit) :
                       (s2_op_q[3] && !s2_is_alu_amo_q) ? 1'b0 : res_keep;
  wire res_val_if_l1d_resp = (agu_state_q == S_AGU_IDLE) ?
    (s2_valid_q ? ((!s2_is_uncached_q || uncached_resp_valid_i) ? res_on_s2_fin : res_keep) : res_keep) :
    (agu_state_q == S_AGU_SC) ? ((sc_match && !l1d_req_ready_i) ? res_keep : 1'b0) :
    (agu_state_q == S_AGU_STORE) ? 1'b0 : res_keep;
  wire res_val_if_no_l1d_resp = (agu_state_q == S_AGU_IDLE) ?
    ((s2_valid_q && s2_is_uncached_q && uncached_resp_valid_i) ? res_on_s2_fin : res_keep) :
    (agu_state_q == S_AGU_SC) ? ((sc_match && !l1d_req_ready_i) ? res_keep : 1'b0) :
    res_keep;

  wire buf_val_if_l1d_resp = (agu_state_q == S_AGU_IDLE) ?
    (s2_valid_q && !s2_is_alu_amo_q && (!s2_is_uncached_q || uncached_resp_valid_i)) :
    (agu_state_q == S_AGU_SC) ? !sc_match : (agu_state_q == S_AGU_STORE);
  wire buf_val_if_no_l1d_resp = (agu_state_q == S_AGU_IDLE) ?
    (s2_valid_q && !s2_is_alu_amo_q && s2_is_uncached_q && uncached_resp_valid_i) :
    (agu_state_q == S_AGU_SC) ? !sc_match : 1'b0;

  wire fpr_wb_en = (agu_state_q == S_AGU_IDLE) && s2_valid_q && s2_writes_fpr_q;

  wire [1:0] state_idle_no_s2 = (s1_valid_q && s1_is_sc && dtlb_hit_i) ? S_AGU_SC : S_AGU_IDLE;
  wire [1:0] state_if_l1d_resp = (agu_state_q == S_AGU_IDLE) ?
    (s2_valid_q ? ((s2_is_alu_amo_q && (!s2_is_uncached_q || uncached_resp_valid_i)) ? S_AGU_ALU : S_AGU_IDLE) : state_idle_no_s2) :
    (agu_state_q == S_AGU_SC) ? (!sc_match ? S_AGU_IDLE : (l1d_req_ready_i ? S_AGU_STORE : S_AGU_SC)) :
    (agu_state_q == S_AGU_ALU) ? S_AGU_STORE : S_AGU_IDLE;
  wire [1:0] state_if_no_l1d_resp = (agu_state_q == S_AGU_IDLE) ?
    (s2_valid_q ? ((s2_is_alu_amo_q && s2_is_uncached_q && uncached_resp_valid_i) ? S_AGU_ALU : S_AGU_IDLE) : state_idle_no_s2) :
    (agu_state_q == S_AGU_SC) ? (!sc_match ? S_AGU_IDLE : (l1d_req_ready_i ? S_AGU_STORE : S_AGU_SC)) :
    (agu_state_q == S_AGU_ALU) ? S_AGU_STORE : S_AGU_STORE;

  // --------------------------------------------------------------------------
  // Sequential Pipeline State Update
  // --------------------------------------------------------------------------
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s1_valid_q       <= 1'b0;
      s1_pc_q          <= {XLEN{1'b0}};
      s1_op_q          <= 8'd0;
      s1_byte_en_q     <= 8'd0;
      s1_rd_q          <= 5'd0;
      s1_vaddr_w_q     <= {(VADDR_WIDTH-2){1'b0}};
      s1_addr_lsb_q    <= 3'd0;
      s1_wdata_q       <= {XLEN{1'b0}};
      s1_orig_wdata_q  <= {XLEN{1'b0}};
      s1_wait_q        <= 1'b0;

      s2_valid_q             <= 1'b0;
      s2_pc_q                <= {XLEN{1'b0}};
      s2_is_uncached_q       <= 1'b0;
      s2_uncached_req_sent_q <= 1'b0;
      s2_is_lr_q             <= 1'b0;
      s2_is_alu_amo_q        <= 1'b0;
      s2_writes_fpr_q        <= 1'b0;
      s2_op_q                <= 8'd0;
      s2_byte_en_q           <= 8'd0;
      s2_rd_q                <= 5'd0;
      s2_addr_lsb_q          <= 3'd0;
      s2_sign_byte_idx_q     <= 3'd0;
      s2_b0_sel_q            <= 2'd0;
      s2_b1_sel_q            <= 2'd0;
      s2_h1_sel_q            <= 2'd0;
      s2_w1_sel_q            <= 2'd0;
      s2_b1_hi_sel_q         <= 2'd0;
      s2_h1_hi_sel_q         <= 2'd0;
      s2_sign_idx_rep0_q     <= 2'd0;
      s2_sign_idx_rep1_q     <= 2'd0;
      s2_sign_idx_rep2_q     <= 2'd0;
      s2_sign_idx_rep3_q     <= 2'd0;
      s2_sign_idx_rep4_q     <= 2'd0;
      s2_sign_idx_rep5_q     <= 2'd0;
      s2_sign_idx_rep6_q     <= 2'd0;
      s2_lsb_lo_rep0_q       <= 2'd0;
      s2_lsb_lo_rep1_q       <= 2'd0;
      s2_lsb_lo_rep2_q       <= 2'd0;
      s2_lsb_lo_rep3_q       <= 2'd0;
      s2_lsb_lo_rep4_q       <= 2'd0;
      s2_lsb_lo_rep5_q       <= 2'd0;
      s2_lsb_lo_rep6_q       <= 2'd0;
      s2_lsb_lo_rep7_q       <= 2'd0;
      s2_w1_one_q            <= 1'b0;
      s2_paddr_w_q           <= {(PADDR_WIDTH-2){1'b0}};
      s2_wdata_q             <= {XLEN{1'b0}};
      s2_orig_wdata_q        <= {XLEN{1'b0}};
      s2_wait_q              <= 1'b0;

      buf_valid_q      <= 1'b0;
      buf_pc_q         <= {XLEN{1'b0}};
      buf_raw_data_q   <= 64'd0;
      buf_rd_q         <= 5'd0;
      buf_writes_fpr_q <= 1'b0;

      agu_state_q      <= S_AGU_IDLE;
      res_valid_q      <= 1'b0;
      res_paddr_w_q    <= {(PADDR_WIDTH-2){1'b0}};
      store_paddr_w_q  <= {(PADDR_WIDTH-2){1'b0}};
      amo_rdata_q      <= {XLEN{1'b0}};
      amo_wdata_q      <= {XLEN{1'b0}};
      amo_req_sent_q   <= 1'b0;
      s2_snoop_hit_q   <= 1'b0;
      sc_failed_q      <= 1'b0;
      sc_success_q     <= 1'b0;
    end else begin
      // Datapath captures with flip-flop-only clock enables (0 logic levels from L1D / EX)
      if (buf_data_en) begin
        buf_pc_q       <= s2_pc_q;
        buf_rd_q       <= s2_rd_q;
        buf_raw_data_q <= s2_next_buf_data;
      end
      if (amo_rdata_en) begin
        amo_rdata_q    <= l1d_rdata_i;
      end
      if (res_paddr_en) begin
        res_paddr_w_q  <= s2_paddr_w_q;
      end
      if (s2_load_en) begin
        store_paddr_w_q    <= dtlb_paddr_w_i;
        s2_pc_q            <= s1_pc_q;
        s2_is_uncached_q   <= is_uncached;
        s2_is_lr_q         <= s1_is_lr;
        s2_is_alu_amo_q    <= s1_is_alu_amo;
        s2_writes_fpr_q    <= s1_writes_fpr;
        s2_op_q            <= s1_op_q;
        s2_byte_en_q       <= s1_byte_en_q;
        s2_rd_q            <= s1_rd_q;
        s2_addr_lsb_q      <= s1_addr_lsb_q;
        s2_sign_byte_idx_q <= s1_sign_byte_idx;
        s2_b0_sel_q        <= s1_b0_sel;
        s2_b1_sel_q        <= s1_b1_sel;
        s2_h1_sel_q        <= s1_h1_sel;
        s2_w1_sel_q        <= s1_w1_sel;
        s2_b1_hi_sel_q     <= s1_b1_hi_sel;
        s2_h1_hi_sel_q     <= s1_h1_hi_sel;
        s2_sign_idx_rep0_q <= s1_sign_byte_idx[1:0];
        s2_sign_idx_rep1_q <= s1_sign_byte_idx[1:0];
        s2_sign_idx_rep2_q <= s1_sign_byte_idx[1:0];
        s2_sign_idx_rep3_q <= s1_sign_byte_idx[1:0];
        s2_sign_idx_rep4_q <= s1_sign_byte_idx[1:0];
        s2_sign_idx_rep5_q <= s1_sign_byte_idx[1:0];
        s2_sign_idx_rep6_q <= s1_sign_byte_idx[1:0];
        s2_lsb_lo_rep0_q   <= s1_addr_lsb_q[1:0];
        s2_lsb_lo_rep1_q   <= s1_addr_lsb_q[1:0];
        s2_lsb_lo_rep2_q   <= s1_addr_lsb_q[1:0];
        s2_lsb_lo_rep3_q   <= s1_addr_lsb_q[1:0];
        s2_lsb_lo_rep4_q   <= s1_addr_lsb_q[1:0];
        s2_lsb_lo_rep5_q   <= s1_addr_lsb_q[1:0];
        s2_lsb_lo_rep6_q   <= s1_addr_lsb_q[1:0];
        s2_lsb_lo_rep7_q   <= s1_addr_lsb_q[1:0];
        s2_w1_one_q        <= s1_w1_one;
        s2_paddr_w_q       <= dtlb_paddr_w_i;
        s2_wdata_q         <= s1_wdata_q;
        s2_orig_wdata_q    <= s1_orig_wdata_q;
      end
      if (s1_accept_rdy) begin
        s1_pc_q         <= req_pc_i;
        s1_op_q         <= req_op_i;
        s1_byte_en_q    <= calc_byte_en;
        s1_rd_q         <= req_rd_i;
        s1_vaddr_w_q    <= calc_vaddr[VADDR_WIDTH-1:2];
        s1_addr_lsb_q   <= calc_vaddr[2:0];
        s1_wdata_q      <= calc_aligned_wdata;
        s1_orig_wdata_q <= req_wdata_i;
      end

      // Single-LUT3 control flip-flops on l1d_resp_valid_i
      res_valid_q      <= l1d_resp_valid_i ? res_val_if_l1d_resp  : res_val_if_no_l1d_resp;
      buf_valid_q      <= l1d_resp_valid_i ? buf_val_if_l1d_resp  : buf_val_if_no_l1d_resp;
      buf_writes_fpr_q <= fpr_wb_en && (s2_is_uncached_q ? uncached_resp_valid_i : l1d_resp_valid_i);
      agu_state_q      <= l1d_resp_valid_i ? state_if_l1d_resp    : state_if_no_l1d_resp;

      if (s2_valid_q && snoop_s2_hit) begin
        s2_snoop_hit_q <= 1'b1;
      end else if (s2_load_en) begin
        s2_snoop_hit_q <= snoop_s1_hit;
      end

      case (agu_state_q)
        S_AGU_IDLE: begin
          if (sc_failed_q) begin
            sc_failed_q <= 1'b0;
          end

          if (s2_valid_q) begin
            s2_valid_q             <= !resp_valid_in;
            s2_wait_q              <= !resp_valid_in;
            s2_uncached_req_sent_q <= resp_valid_in ? 1'b0 :
                                      (s2_uncached_req_sent_q || (s2_is_uncached_q && uncached_req_ready_i));
          end else begin
            s2_wait_q <= 1'b0;
          end

          if (s2_load_en) begin
            amo_wdata_q <= s1_wdata_q;
          end

          if (s1_valid_q) begin
            if (s1_is_sc && dtlb_hit_i && !s2_valid_q) begin
              s1_valid_q <= 1'b0;
              s1_wait_q  <= 1'b0;
            end else if (!s1_is_sc && dtlb_hit_i && !s2_valid_q && (is_uncached || l1d_req_ready_i)) begin
              s2_valid_q             <= 1'b1;
              s2_uncached_req_sent_q <= 1'b0;
              s2_wait_q              <= is_uncached || s1_is_alu_amo;
              s1_valid_q             <= 1'b0;
              s1_wait_q              <= 1'b0;
            end else begin
              s1_wait_q <= 1'b1;
            end
          end else if (s1_accept_rdy && req_valid_i) begin
            s1_valid_q <= 1'b1;
            s1_wait_q  <= (req_op_i[7:4] != `AMO_NONE && req_op_i[7:4] != `AMO_LR && req_op_i[7:4] != `AMO_FP);
          end else begin
            s1_wait_q  <= 1'b0;
          end
        end

        S_AGU_SC: begin
          if (!sc_match) begin
            sc_failed_q    <= 1'b1;
          end else if (l1d_req_ready_i) begin
            sc_success_q   <= 1'b1;
            amo_req_sent_q <= 1'b1;
          end
        end

        S_AGU_ALU: begin
          amo_wdata_q    <= amo_wdata_aligned;
          amo_req_sent_q <= 1'b0;
        end

        S_AGU_STORE: begin
          if (l1d_resp_valid_i) begin
            amo_req_sent_q <= 1'b0;
            sc_success_q   <= 1'b0;
          end else if (!amo_req_sent_q && l1d_req_ready_i) begin
            amo_req_sent_q <= 1'b1;
          end
        end
      endcase
    end
  end

  // Avoid unused warnings
  wire _unused = &{1'b0, dtlb_fault_i, l1d_miss_stall_i, 1'b0};

endmodule

`default_nettype wire
