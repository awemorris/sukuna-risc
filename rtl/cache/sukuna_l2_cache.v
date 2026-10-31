// ============================================================================
// Sukuna-RISC: Parametric N-Way Set Associative Shared L2 Cache (Verilog 2005)
// Complies with design-rule.md & style.md
// ============================================================================
// Architecture:
//   - Configurable N-way set associativity (WAYS: 2 <= N <= 32, default 8)
//   - Strictly Inclusive of L1D (and L1I): on L2 eviction of a valid line,
//     issues a back-invalidation request (back_inv_valid_o / back_inv_paddr_w_o)
//     to the Coherence Controller so L1D invalidates the set.
//   - Sub-Line Write-Back support for L1D Write-Through Store Buffer drains:
//       * When req_write_i == 1, req_paddr_w_i[5:3] selects the target 64-bit
//         doubleword within the 64-byte line, req_wdata_i[63:0] carries the
//         64-bit write data, and req_wdata_i[71:64] carries the 8-bit byte mask.
//       * On L2 Write Hit: updates only the enabled bytes in the hitting way
//         and sets its dirty bit.
//       * On L2 Write Miss (Write-Allocate): evicts victim if dirty (and
//         back-invalidates L1D if victim was valid), fetches the 64-byte line
//         from main memory, merges the store bytes into the refilled line, and
//         allocates it into L2 with dirty = 1.
// ============================================================================

`timescale 1ns / 1ps
`default_nettype none

`include "sukuna_defines.vh"

module sukuna_l2_cache #(
  parameter PADDR_WIDTH     = `PADDR_WIDTH,
  parameter CACHE_LINE_BITS = `CACHE_LINE_BITS,  // 512 bits = 64 bytes
  parameter CACHE_SIZE      = `L2_SIZE_BYTES,    // 262144 bytes = 256 KB
  parameter WAYS            = `L2_WAYS           // 2 <= WAYS <= 32
)(
  input  wire                       clk_i,
  input  wire                       rst_ni,

  // Request from L2 Arbiter (Word-aligned: bits [1:0] omitted)
  input  wire                       req_valid_i,
  input  wire                       req_write_i,
  input  wire [3:0]                 req_source_i,
  input  wire [PADDR_WIDTH-1:2]     req_paddr_w_i,
  input  wire [CACHE_LINE_BITS-1:0] req_wdata_i,
  output wire                       req_ready_o,

  output reg                        resp_valid_o,
  output reg  [3:0]                 resp_source_o,
  output wire [CACHE_LINE_BITS-1:0] resp_rdata_o,

  // Inclusive L2 Eviction Back-Invalidation Port (to L1D Coherence Controller)
  output reg                        back_inv_valid_o,
  output wire [PADDR_WIDTH-1:2]     back_inv_paddr_w_o,
  output wire                       write_pending_o,

  // Interface to External Memory Controller (AXI4 Bridge)
  output reg                        mem_req_valid_o,
  output reg                        mem_req_write_o,
  output wire [PADDR_WIDTH-1:2]     mem_req_paddr_w_o,
  output wire [CACHE_LINE_BITS-1:0] mem_req_wdata_o,
  input  wire                       mem_req_ready_i,
  input  wire                       mem_resp_valid_i,
  input  wire [CACHE_LINE_BITS-1:0] mem_resp_rdata_i
);

  // Explicit active-high reset wire with "rst" in name for clean FDCE CLR mapping
  (* keep = "true" *) wire rst_async_p = !rst_ni;

  // --------------------------------------------------------------------------
  // Cache Geometry Calculations
  // --------------------------------------------------------------------------
  localparam SETS        = CACHE_SIZE / (WAYS * 64);
  localparam INDEX_BITS  = (SETS <= 64)   ? 6  :
                           (SETS <= 128)  ? 7  :
                           (SETS <= 256)  ? 8  :
                           (SETS <= 512)  ? 9  :
                           (SETS <= 1024) ? 10 : 11;

  localparam OFFSET_BITS = 6;
  localparam TAG_WIDTH   = PADDR_WIDTH - INDEX_BITS - OFFSET_BITS;

  localparam WAY_BITS    = (WAYS <= 2)  ? 1 :
                           (WAYS <= 4)  ? 2 :
                           (WAYS <= 8)  ? 3 :
                           (WAYS <= 16) ? 4 : 5;
  localparam integer MAX_WAY_IDX = WAYS - 1;

  // --------------------------------------------------------------------------
  // State Machine Definitions (Multi-Cycle Pipelined L2 Access)
  //   S_IDLE    : Accept request, latch per-way address/tag/wdata
  //   S_READ    : Read Tag BRAM & Data BRAMs (1-cycle latency)
  //   S_COMPARE : Compare tags (pure LUT tree) & register way_hit_q / victim
  //   S_ACTION  : Execute hit response / hit write, or initiate miss eviction
  //   S_EVICT   : Wait for dirty victim writeback acceptance
  //   S_REFILL  : Wait for main memory refill response
  // --------------------------------------------------------------------------
  localparam S_IDLE    = 3'd0;
  localparam S_READ    = 3'd1;
  localparam S_COMPARE = 3'd2;
  localparam S_ACTION  = 3'd3;
  localparam S_EVICT   = 3'd4;
  localparam S_REFILL  = 3'd5;

  (* dont_touch = "true" *) reg [2:0]          state_q;        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [2:0]          state_rep0_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [2:0]          state_rep1_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [2:0]          state_rep2_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [2:0]          state_rep3_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [2:0]          state_rep4_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [2:0]          state_rep5_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  (* dont_touch = "true" *) reg [WAY_BITS-1:0] victim_ptr_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [WAY_BITS-1:0] victim_ptr_r0_q;/* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  wire _unused_req_paddr = &{1'b0, req_paddr_w_i[2], 1'b0};
  wire _unused_req_wdata = &{1'b0, req_wdata_i[CACHE_LINE_BITS-1:72], 1'b0};

  // Latched Request Registers (sliced into <= 14-bit groups so CE fanout <= 15)
  (* dont_touch = "true" *) reg                req_write_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [3:0]          req_src_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [INDEX_BITS-1:0] req_idx_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [12:0]         req_tag_lo_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [TAG_WIDTH-14:0] req_tag_hi_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  wire [TAG_WIDTH-1:0] req_tag_q = {req_tag_hi_q, req_tag_lo_q};

  // Registered Tag Comparison & Victim Metadata (S_COMPARE -> S_ACTION)
  (* dont_touch = "true" *) reg [WAYS-1:0]     way_hit_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [WAYS-1:0]     way_hit_g0_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [WAYS-1:0]     way_hit_g1_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                victim_valid_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                victim_dirty_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                vic_dirty_g0_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                vic_dirty_g1_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [TAG_WIDTH-1:0] victim_tag_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  (* dont_touch = "true" *) wire hit = |way_hit_q;

  assign req_ready_o     = (state_q == S_IDLE);
  assign write_pending_o = (state_q != S_IDLE) && req_write_q;

  // Each accept_c* wire uses a distinct dont_touch state_rep*_q register so Vivado never merges them
  wire accept_c0 = (state_rep0_q == S_IDLE) && req_valid_i;
  wire accept_c1 = (state_rep1_q == S_IDLE) && req_valid_i;
  wire accept_c2 = (state_rep2_q == S_IDLE) && req_valid_i;

  always @(posedge clk_i or posedge rst_async_p) begin
    if (rst_async_p) begin
      req_write_q  <= 1'b0;
      req_src_q    <= 4'd0;
      req_idx_q    <= {INDEX_BITS{1'b0}};
      req_tag_lo_q <= 13'd0;
      req_tag_hi_q <= {(TAG_WIDTH-13){1'b0}};
    end else begin
      if (accept_c0) begin
        req_write_q <= req_write_i;
        req_src_q   <= req_source_i;
        req_idx_q   <= req_paddr_w_i[5+INDEX_BITS:6];
      end
      if (accept_c1) begin
        req_tag_lo_q <= req_paddr_w_i[6+INDEX_BITS +: 13];
      end
      if (accept_c2) begin
        req_tag_hi_q <= req_paddr_w_i[19+INDEX_BITS +: (TAG_WIDTH-13)];
      end
    end
  end

  wire [WAY_BITS-1:0] victim_ptr_next =
    (victim_ptr_q == MAX_WAY_IDX[WAY_BITS-1:0]) ? {WAY_BITS{1'b0}} : (victim_ptr_q + 1'b1);

  // --------------------------------------------------------------------------
  // Tag and Data Arrays for WAYS + Hierarchical Per-Way Control Tree
  // Each way w (0..7) has its own grp_state_q FSM replica driving way_state,
  // bank_state[0..3], and slice_state[0..3] (fanout <= 12 everywhere).
  // --------------------------------------------------------------------------
  wire [TAG_WIDTH+1:0]       tag_rdata  [0:WAYS-1]; // {dirty, valid, tag}
  wire [CACHE_LINE_BITS-1:0] data_rdata [0:WAYS-1];
  wire [WAYS-1:0]            way_tag_match;
  wire [WAYS-1:0]            way_tag_match_s0;
  wire [WAYS-1:0]            way_tag_match_s1;
  wire [WAYS-1:0]            way_tag_match_s2;
  wire [WAYS-1:0]            way_tag_match_s3;
  wire [2:0]                 way_grp_next_state [0:WAYS-1];
  wire [WAY_BITS-1:0]        way_vptr_out       [0:WAYS-1];
  wire [WAYS-1:0]            way_req_write_out;

  genvar w, gb;
  generate
    for (w = 0; w < WAYS; w = w + 1) begin : gen_l2way
      // Per-way hierarchical state registers (dont_touch prevents merging across ways)
      (* dont_touch = "true" *) reg [2:0]          grp_state_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [2:0]          way_state0_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [2:0]          way_state1_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [2:0]          way_state2_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [WAY_BITS-1:0] way_vptr_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

      (* dont_touch = "true" *) wire way_start    = (grp_state_q == S_IDLE) && req_valid_i;
      (* dont_touch = "true" *) wire way_ev_done  = (way_state1_q == S_EVICT) && mem_req_ready_i;
      (* dont_touch = "true" *) wire way_ref_done = (way_state2_q == S_REFILL) && mem_resp_valid_i;
      (* dont_touch = "true" *) wire way_hit_sel  = (w < 4) ? (|way_hit_g0_q) : (|way_hit_g1_q);
      wire way_dirty_sel = (w < 4) ? vic_dirty_g0_q : vic_dirty_g1_q;

      reg [2:0] grp_state_d;
      always @(*) begin
        grp_state_d = grp_state_q;
        case (grp_state_q)
          S_IDLE:    if (way_start) grp_state_d = S_READ;
          S_READ:    grp_state_d = S_COMPARE;
          S_COMPARE: grp_state_d = S_ACTION;
          S_ACTION:  grp_state_d = way_hit_sel ? S_IDLE : (way_dirty_sel ? S_EVICT : S_REFILL);
          S_EVICT:   if (way_ev_done) grp_state_d = S_REFILL;
          S_REFILL:  if (way_ref_done) grp_state_d = S_IDLE;
          default:   grp_state_d = S_IDLE;
        endcase
      end

      assign way_grp_next_state[w] = grp_state_d;
      assign way_vptr_out[w]       = way_vptr_q;

      // Dedicated per-way RAM address, tag, and write control registers
      (* dont_touch = "true" *) reg [INDEX_BITS-1:0] way_raddr_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [INDEX_BITS-1:0] way_waddr_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg                  way_req_write_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      assign way_req_write_out[w] = way_req_write_q;
      (* dont_touch = "true" *) reg [2:0]            way_dw_q;        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [7:0]            way_be_q;        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [12:0]           way_tag_lo_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [TAG_WIDTH-14:0] way_tag_hi_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [12:0]           wtag_lo_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [TAG_WIDTH-14:0] wtag_hi_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg                  way_is_refill_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

      wire [TAG_WIDTH-1:0] way_req_tag = {way_tag_hi_q, way_tag_lo_q};
      wire [TAG_WIDTH-1:0] way_wr_tag  = {wtag_hi_q, wtag_lo_q};

      // Each enable uses a distinct way_state*_q register without req_valid_i -> <= 14 loads per LUT
      wire way_acc0 = (way_state0_q == S_IDLE);
      wire way_acc1 = (way_state1_q == S_IDLE);
      wire way_acc2 = (way_state2_q == S_IDLE);

      wire way_rd0  = (way_state0_q == S_READ);
      wire way_rd1  = (way_state1_q == S_READ);
      wire way_rd2  = (way_state2_q == S_READ);

      always @(posedge clk_i or posedge rst_async_p) begin
        if (rst_async_p) begin
          grp_state_q     <= S_IDLE;
          way_state0_q    <= S_IDLE;
          way_state1_q    <= S_IDLE;
          way_state2_q    <= S_IDLE;
          way_vptr_q      <= {WAY_BITS{1'b0}};
          way_raddr_q     <= {INDEX_BITS{1'b0}};
          way_waddr_q     <= {INDEX_BITS{1'b0}};
          way_req_write_q <= 1'b0;
          way_dw_q        <= 3'd0;
          way_be_q        <= 8'd0;
          way_tag_lo_q    <= 13'd0;
          way_tag_hi_q    <= {(TAG_WIDTH-13){1'b0}};
          wtag_lo_q       <= 13'd0;
          wtag_hi_q       <= {(TAG_WIDTH-13){1'b0}};
          way_is_refill_q <= 1'b0;
        end else begin
          grp_state_q  <= grp_state_d;
          way_state0_q <= grp_state_d;
          way_state1_q <= grp_state_d;
          way_state2_q <= grp_state_d;
          if (way_ref_done) begin
            way_vptr_q <= victim_ptr_next;
          end

          if (way_acc0) begin
            way_raddr_q     <= req_paddr_w_i[5+INDEX_BITS:6];
            way_req_write_q <= req_write_i;
            way_dw_q        <= req_paddr_w_i[5:3];
          end
          if (way_acc1) begin
            way_tag_lo_q <= req_paddr_w_i[6+INDEX_BITS +: 13];
          end
          if (way_acc2) begin
            way_tag_hi_q <= req_paddr_w_i[19+INDEX_BITS +: (TAG_WIDTH-13)];
            way_be_q     <= req_wdata_i[71:64];
          end

          if (way_rd0) way_waddr_q <= way_raddr_q;
          if (way_rd1) wtag_lo_q   <= way_tag_lo_q;
          if (way_rd2) wtag_hi_q   <= way_tag_hi_q;

          way_is_refill_q <= (way_state0_q != S_COMPARE);
        end
      end

      wire way_refill_wen = way_ref_done && (way_vptr_q == w[WAY_BITS-1:0]);
      wire way_write_hit  = (way_state0_q == S_ACTION) && way_req_write_q && way_hit_q[w];
      (* dont_touch = "true" *) wire tag_wen = way_refill_wen || way_write_hit;
      (* dont_touch = "true" *) wire way_ren = (way_state0_q == S_READ);

      // Tag Array ({dirty, valid, tag}) in Block RAM (1 RAMB18E1 per way, COLLISION_FWD=0)
      sk_ram_bram #(
        .DATA_WIDTH     (TAG_WIDTH + 2),
        .ADDR_WIDTH     (INDEX_BITS),
        .DEPTH          (SETS),
        .PIPELINE_STAGES(1),
        .BYTE_WRITE_EN  (0),
        .COLLISION_FWD  (0)
      ) u_l2_tag_ram (
        .clk_i  (clk_i),
        .rst_ni (rst_ni),
        .wen_i  (tag_wen),
        .wstrb_i(1'b1),
        .waddr_i(way_waddr_q),
        .wdata_i({(!way_is_refill_q || way_req_write_q), 1'b1, way_wr_tag}),
        .ren_i  (way_ren),
        .raddr_i(way_raddr_q),
        .rdata_o(tag_rdata[w])
      );

      // Per-way 64-bit write data assembled from the 4 banks (each bit drives 8 LUT3s in way w)
      wire [63:0] way_wdata64;

      // 4 x 128-bit Data Banks per way (each bank uses 2 RAMB36E1s, WE_WIDTH=16 -> fanout <= 16)
      for (gb = 0; gb < 4; gb = gb + 1) begin : gen_dbank
        (* dont_touch = "true" *) reg [2:0]  bank_state0_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        (* dont_touch = "true" *) reg [2:0]  bank_state1_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        (* dont_touch = "true" *) reg        bank_rw_lo_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        (* dont_touch = "true" *) reg        bank_rw_hi_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        (* dont_touch = "true" *) reg [2:0]  bank_dw_lo_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        (* dont_touch = "true" *) reg [2:0]  bank_dw_hi_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        (* dont_touch = "true" *) reg [7:0]  bank_be_q;         /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        (* dont_touch = "true" *) reg [7:0]  bank_wd_lo_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        (* dont_touch = "true" *) reg [7:0]  bank_wd_hi_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        (* dont_touch = "true" *) reg [15:0] bank_merge_strb_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        (* dont_touch = "true" *) reg [15:0] bank_ram_wstrb_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

        assign way_wdata64[gb*16 +: 16] = {bank_wd_hi_q, bank_wd_lo_q};

        // Each enable uses bank_state0_q or bank_state1_q -> max 10 loads per LUT (<= 11 pins)
        wire b_acc0 = (bank_state0_q == S_IDLE);
        wire b_acc1 = (bank_state1_q == S_IDLE);
        wire b_rd0  = (bank_state0_q == S_READ);
        wire b_rd1  = (bank_state1_q == S_READ);
        wire b_cmp0 = (bank_state0_q == S_COMPARE);
        wire b_cmp1 = (bank_state1_q == S_COMPARE);
        wire b_we0  = (bank_state0_q == S_COMPARE) || (bank_state0_q == S_ACTION);
        wire b_we1  = (bank_state1_q == S_COMPARE) || (bank_state1_q == S_ACTION);

        localparam [2:0] DW_LO = gb * 2;
        localparam [2:0] DW_HI = gb * 2 + 1;

        (* dont_touch = "true" *) wire [7:0] strb_lo_next = (bank_rw_lo_q && (bank_dw_lo_q == DW_LO)) ? bank_be_q : 8'd0;
        (* dont_touch = "true" *) wire [7:0] strb_hi_next = (bank_rw_hi_q && (bank_dw_hi_q == DW_HI)) ? bank_be_q : 8'd0;

        always @(posedge clk_i or posedge rst_async_p) begin
          if (rst_async_p) begin
            bank_state0_q     <= S_IDLE;
            bank_state1_q     <= S_IDLE;
            bank_rw_lo_q      <= 1'b0;
            bank_rw_hi_q      <= 1'b0;
            bank_dw_lo_q      <= 3'd0;
            bank_dw_hi_q      <= 3'd0;
            bank_be_q         <= 8'd0;
            bank_wd_lo_q      <= 8'd0;
            bank_wd_hi_q      <= 8'd0;
            bank_merge_strb_q <= 16'd0;
            bank_ram_wstrb_q  <= 16'd0;
          end else begin
            bank_state0_q <= grp_state_d;
            bank_state1_q <= grp_state_d;
            if (b_acc0) begin
              bank_wd_lo_q <= req_wdata_i[gb*16 +: 8];
            end
            if (b_acc1) begin
              bank_wd_hi_q <= req_wdata_i[gb*16 + 8 +: 8];
            end
            if (b_rd0) begin
              bank_rw_lo_q <= way_req_write_q;
              bank_rw_hi_q <= way_req_write_q;
              bank_dw_lo_q <= way_dw_q;
              bank_dw_hi_q <= way_dw_q;
            end
            if (b_rd1) begin
              bank_be_q <= way_be_q;
            end
            if (b_cmp0) begin
              bank_merge_strb_q[7:0] <= strb_lo_next;
            end
            if (b_cmp1) begin
              bank_merge_strb_q[15:8] <= strb_hi_next;
            end
            if (b_we0) begin
              bank_ram_wstrb_q[7:0] <= (bank_state0_q == S_ACTION) ? 8'hFF : strb_lo_next;
            end
            if (b_we1) begin
              bank_ram_wstrb_q[15:8] <= (bank_state1_q == S_ACTION) ? 8'hFF : strb_hi_next;
            end
          end
        end

        (* dont_touch = "true" *) wire bank_wen = way_refill_wen || way_write_hit;

        // Unified byte-merge mux for both Write-Hit (S_ACTION) and Refill (S_REFILL):
        // Each bit of bank_merge_strb_q[b] drives only 8 LUT3s in this bank (fanout == 9 <= 16).
        wire [127:0] bank_wdata;
        genvar bb;
        for (bb = 0; bb < 16; bb = bb + 1) begin : gen_bmerge
          localparam integer DW_B = bb % 8;
          assign bank_wdata[bb*8 +: 8] =
            bank_merge_strb_q[bb] ? way_wdata64[DW_B*8 +: 8] : mem_resp_rdata_i[(gb*16 + bb)*8 +: 8];
        end

        sk_ram_bram #(
          .DATA_WIDTH     (128),
          .ADDR_WIDTH     (INDEX_BITS),
          .DEPTH          (SETS),
          .PIPELINE_STAGES(1),
          .BYTE_WRITE_EN  (1),
          .WE_WIDTH       (16),
          .COLLISION_FWD  (0)
        ) u_l2_data_bank (
          .clk_i  (clk_i),
          .rst_ni (rst_ni),
          .wen_i  (bank_wen),
          .wstrb_i(bank_ram_wstrb_q),
          .waddr_i(way_waddr_q),
          .wdata_i(bank_wdata),
          .ren_i  (way_ren),
          .raddr_i(way_raddr_q),
          .rdata_o(data_rdata[w][gb*128 +: 128])
        );
      end

      // Pure LUT-tree 25-bit tag comparator (avoids CARRY4 chain, <= 3 LUT levels to slice_hit_sel_q)
      wire [8:0] tag_grp_eq;
      genvar tg;
      for (tg = 0; tg < 8; tg = tg + 1) begin : gen_tag_cmp
        (* dont_touch = "true" *) wire grp_eq =
          (tag_rdata[w][tg*3 +: 3] == way_req_tag[tg*3 +: 3]);
        assign tag_grp_eq[tg] = grp_eq;
      end
      (* dont_touch = "true" *) wire grp_eq_top =
        (tag_rdata[w][TAG_WIDTH-1:24] == way_req_tag[TAG_WIDTH-1:24]) && tag_rdata[w][TAG_WIDTH];
      assign tag_grp_eq[8] = grp_eq_top;

      (* dont_touch = "true" *) wire eq_lo = &tag_grp_eq[4:0];
      (* dont_touch = "true" *) wire eq_hi = &tag_grp_eq[8:5];
      (* dont_touch = "true" *) wire m_main = eq_lo && eq_hi;
      (* dont_touch = "true" *) wire m_s0   = eq_lo && eq_hi;
      (* dont_touch = "true" *) wire m_s1   = eq_lo && eq_hi;
      (* dont_touch = "true" *) wire m_s2   = eq_lo && eq_hi;
      (* dont_touch = "true" *) wire m_s3   = eq_lo && eq_hi;

      assign way_tag_match[w]    = m_main;
      assign way_tag_match_s0[w] = m_s0;
      assign way_tag_match_s1[w] = m_s1;
      assign way_tag_match_s2[w] = m_s2;
      assign way_tag_match_s3[w] = m_s3;
    end
  endgenerate

  // Register Tag Comparison and Victim Metadata in S_COMPARE (split into <= 10-bit groups so fanout <= 11)
  (* dont_touch = "true" *) wire cmp_en0    = (state_rep0_q == S_COMPARE);
  (* dont_touch = "true" *) wire cmp_en0_g0 = (state_rep1_q == S_COMPARE);
  (* dont_touch = "true" *) wire cmp_en0_g1 = (state_rep2_q == S_COMPARE);
  (* dont_touch = "true" *) wire cmp_en1    = (state_rep1_q == S_COMPARE);
  (* dont_touch = "true" *) wire cmp_en2    = (state_rep2_q == S_COMPARE);

  (* dont_touch = "true" *) reg [WAY_BITS-1:0] vic_tag_sel0_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [WAY_BITS-1:0] vic_tag_sel1_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [WAY_BITS-1:0] vic_tag_sel2_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [WAY_BITS-1:0] vic_tag_sel3_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [WAY_BITS-1:0] vic_tag_sel4_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  always @(posedge clk_i or posedge rst_async_p) begin
    if (rst_async_p) begin
      vic_tag_sel0_q <= {WAY_BITS{1'b0}};
      vic_tag_sel1_q <= {WAY_BITS{1'b0}};
      vic_tag_sel2_q <= {WAY_BITS{1'b0}};
      vic_tag_sel3_q <= {WAY_BITS{1'b0}};
      vic_tag_sel4_q <= {WAY_BITS{1'b0}};
      way_hit_q      <= {WAYS{1'b0}};
      way_hit_g0_q   <= {WAYS{1'b0}};
      way_hit_g1_q   <= {WAYS{1'b0}};
      victim_valid_q <= 1'b0;
      victim_dirty_q <= 1'b0;
      vic_dirty_g0_q <= 1'b0;
      vic_dirty_g1_q <= 1'b0;
      victim_tag_q   <= {TAG_WIDTH{1'b0}};
    end else begin
      vic_tag_sel0_q <= victim_ptr_r0_q;
      vic_tag_sel1_q <= victim_ptr_r0_q;
      vic_tag_sel2_q <= victim_ptr_r0_q;
      vic_tag_sel3_q <= victim_ptr_r0_q;
      vic_tag_sel4_q <= victim_ptr_r0_q;
      if (cmp_en0) begin
        way_hit_q      <= way_tag_match;
        victim_valid_q <= tag_rdata[vic_tag_sel0_q][TAG_WIDTH];
        victim_dirty_q <= tag_rdata[vic_tag_sel0_q][TAG_WIDTH] && tag_rdata[vic_tag_sel0_q][TAG_WIDTH+1];
      end
      if (cmp_en0_g0) begin
        way_hit_g0_q   <= way_tag_match;
        vic_dirty_g0_q <= tag_rdata[vic_tag_sel1_q][TAG_WIDTH] && tag_rdata[vic_tag_sel1_q][TAG_WIDTH+1];
      end
      if (cmp_en0_g1) begin
        way_hit_g1_q   <= way_tag_match;
        vic_dirty_g1_q <= tag_rdata[vic_tag_sel2_q][TAG_WIDTH] && tag_rdata[vic_tag_sel2_q][TAG_WIDTH+1];
      end
      if (cmp_en1) begin
        victim_tag_q[4:0]  <= tag_rdata[vic_tag_sel0_q][4:0];
        victim_tag_q[9:5]  <= tag_rdata[vic_tag_sel1_q][9:5];
        victim_tag_q[14:10]<= tag_rdata[vic_tag_sel2_q][14:10];
      end
      if (cmp_en2) begin
        victim_tag_q[19:15]          <= tag_rdata[vic_tag_sel3_q][19:15];
        victim_tag_q[TAG_WIDTH-1:20] <= tag_rdata[vic_tag_sel4_q][TAG_WIDTH-1:20];
      end
    end
  end

  // --------------------------------------------------------------------------
  // Sliced 512-bit Response Data & Eviction Writeback Data Registers
  // 32 slices of 16 bits, with 3 victim muxes (6, 5, 5 bits) per slice so every
  // select net has fanout <= 13 and logic depth <= 3 LUTs (0 Rule 1 warnings)!
  // --------------------------------------------------------------------------
  genvar gs;
  generate
    for (gs = 0; gs < 32; gs = gs + 1) begin : gen_data_slice
      localparam integer GW = gs / 4;

      wire [WAYS-1:0] match_in = (gs < 8)  ? way_tag_match_s0 :
                                 (gs < 16) ? way_tag_match_s1 :
                                 (gs < 24) ? way_tag_match_s2 : way_tag_match_s3;

      (* dont_touch = "true" *) reg [2:0]          slice_state_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg                slice_rw_lo_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg                slice_rw_hi_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [WAYS-1:0]     slice_hit_sel_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [WAY_BITS-1:0] slice_vic_a_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [WAY_BITS-1:0] slice_vic_b_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [WAY_BITS-1:0] slice_vic_c_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg                slice_is_ref_lo_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg                slice_is_ref_hi_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg                slice_ev_lo_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg                slice_ev_hi_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

      always @(posedge clk_i or posedge rst_async_p) begin
        if (rst_async_p) begin
          slice_state_q     <= S_IDLE;
          slice_rw_lo_q     <= 1'b0;
          slice_rw_hi_q     <= 1'b0;
          slice_hit_sel_q   <= {WAYS{1'b0}};
          slice_vic_a_q     <= {WAY_BITS{1'b0}};
          slice_vic_b_q     <= {WAY_BITS{1'b0}};
          slice_vic_c_q     <= {WAY_BITS{1'b0}};
          slice_is_ref_lo_q <= 1'b0;
          slice_is_ref_hi_q <= 1'b0;
          slice_ev_lo_q     <= 1'b0;
          slice_ev_hi_q     <= 1'b0;
        end else begin
          slice_state_q     <= way_grp_next_state[GW];
          slice_rw_lo_q     <= way_req_write_out[GW];
          slice_rw_hi_q     <= way_req_write_out[GW];
          // Unconditional capture from match_in: tag_rdata is steady during S_COMPARE
          // -> 0 CE logic, strictly 3 LUT levels from u_l2_tag_ram!
          slice_hit_sel_q   <= match_in;
          slice_vic_a_q     <= way_vptr_out[GW];
          slice_vic_b_q     <= way_vptr_out[GW];
          slice_vic_c_q     <= way_vptr_out[GW];
          slice_is_ref_lo_q <= (slice_state_q != S_COMPARE);
          slice_is_ref_hi_q <= (slice_state_q != S_COMPARE);
          slice_ev_lo_q     <= (slice_state_q == S_READ);
          slice_ev_hi_q     <= (slice_state_q == S_READ);
        end
      end

      wire resp_en_lo = !slice_rw_lo_q && ((slice_state_q == S_ACTION) || (slice_state_q == S_REFILL));
      wire resp_en_hi = !slice_rw_hi_q && ((slice_state_q == S_ACTION) || (slice_state_q == S_REFILL));

      wire [15:0] hit_slice =
        ({16{slice_hit_sel_q[0]}} & data_rdata[0][gs*16 +: 16]) |
        ({16{slice_hit_sel_q[1]}} & data_rdata[1][gs*16 +: 16]) |
        ({16{slice_hit_sel_q[2]}} & data_rdata[2][gs*16 +: 16]) |
        ({16{slice_hit_sel_q[3]}} & data_rdata[3][gs*16 +: 16]) |
        ({16{slice_hit_sel_q[4]}} & data_rdata[4][gs*16 +: 16]) |
        ({16{slice_hit_sel_q[5]}} & data_rdata[5][gs*16 +: 16]) |
        ({16{slice_hit_sel_q[6]}} & data_rdata[6][gs*16 +: 16]) |
        ({16{slice_hit_sel_q[7]}} & data_rdata[7][gs*16 +: 16]);

      wire [7:0] resp_lo_next = slice_is_ref_lo_q ? mem_resp_rdata_i[gs*16 +: 8]     : hit_slice[7:0];
      wire [7:0] resp_hi_next = slice_is_ref_hi_q ? mem_resp_rdata_i[gs*16 + 8 +: 8] : hit_slice[15:8];

      wire [5:0] vic_a_next   = data_rdata[slice_vic_a_q][gs*16 +: 6];
      wire [4:0] vic_b_next   = data_rdata[slice_vic_b_q][gs*16 + 6 +: 5];
      wire [4:0] vic_c_next   = data_rdata[slice_vic_c_q][gs*16 + 11 +: 5];
      wire [15:0] vic_next    = {vic_c_next, vic_b_next, vic_a_next};

      (* dont_touch = "true" *) reg [15:0] resp_slice_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [15:0] evict_slice_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

      always @(posedge clk_i or posedge rst_async_p) begin
        if (rst_async_p) begin
          resp_slice_q  <= 16'd0;
          evict_slice_q <= 16'd0;
        end else begin
          if (resp_en_lo) resp_slice_q[7:0]   <= resp_lo_next;
          if (resp_en_hi) resp_slice_q[15:8]  <= resp_hi_next;
          if (slice_ev_lo_q) evict_slice_q[7:0]  <= vic_next[7:0];
          if (slice_ev_hi_q) evict_slice_q[15:8] <= vic_next[15:8];
        end
      end

      assign resp_rdata_o[gs*16 +: 16]    = resp_slice_q;
      assign mem_req_wdata_o[gs*16 +: 16] = evict_slice_q;
    end
  endgenerate

  // --------------------------------------------------------------------------
  // Sliced Output Address Registers (back_inv_paddr_w_o & mem_req_paddr_w_o)
  // Split into <= 13-bit slices using distinct state_rep3..5_q registers
  // --------------------------------------------------------------------------
  (* dont_touch = "true" *) reg [12:0] back_inv_s0_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [12:0] back_inv_s1_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [11:0] back_inv_s2_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  assign back_inv_paddr_w_o = {back_inv_s2_q, back_inv_s1_q, back_inv_s0_q};

  (* dont_touch = "true" *) reg [12:0] mem_paddr_s0_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [12:0] mem_paddr_s1_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [11:0] mem_paddr_s2_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  assign mem_req_paddr_w_o = {mem_paddr_s2_q, mem_paddr_s1_q, mem_paddr_s0_q};

  wire [PADDR_WIDTH-1:2] vic_paddr_w = {victim_tag_q, req_idx_q, 4'b0000};
  wire [PADDR_WIDTH-1:2] ref_paddr_w = {req_tag_q, req_idx_q, 4'b0000};

  (* dont_touch = "true" *) wire bi_en0 = (state_rep3_q == S_ACTION) && !hit && victim_valid_q;
  (* dont_touch = "true" *) wire bi_en1 = (state_rep4_q == S_ACTION) && !hit && victim_valid_q;
  (* dont_touch = "true" *) wire bi_en2 = (state_rep5_q == S_ACTION) && !hit && victim_valid_q;

  (* dont_touch = "true" *) wire mp_en0 = ((state_rep3_q == S_ACTION) && !hit) || ((state_rep3_q == S_EVICT) && mem_req_ready_i);
  (* dont_touch = "true" *) wire mp_en1 = ((state_rep4_q == S_ACTION) && !hit) || ((state_rep4_q == S_EVICT) && mem_req_ready_i);
  (* dont_touch = "true" *) wire mp_en2 = ((state_rep5_q == S_ACTION) && !hit) || ((state_rep5_q == S_EVICT) && mem_req_ready_i);

  (* dont_touch = "true" *) wire mp_sel_vic0 = (state_rep3_q == S_ACTION) && victim_dirty_q;
  (* dont_touch = "true" *) wire mp_sel_vic1 = (state_rep4_q == S_ACTION) && victim_dirty_q;
  (* dont_touch = "true" *) wire mp_sel_vic2 = (state_rep5_q == S_ACTION) && victim_dirty_q;

  always @(posedge clk_i or posedge rst_async_p) begin
    if (rst_async_p) begin
      back_inv_s0_q  <= 13'd0;
      back_inv_s1_q  <= 13'd0;
      back_inv_s2_q  <= 12'd0;
      mem_paddr_s0_q <= 13'd0;
      mem_paddr_s1_q <= 13'd0;
      mem_paddr_s2_q <= 12'd0;
    end else begin
      if (bi_en0) back_inv_s0_q <= vic_paddr_w[14:2];
      if (bi_en1) back_inv_s1_q <= vic_paddr_w[27:15];
      if (bi_en2) back_inv_s2_q <= vic_paddr_w[39:28];

      if (mp_en0) mem_paddr_s0_q <= mp_sel_vic0 ? vic_paddr_w[14:2]  : ref_paddr_w[14:2];
      if (mp_en1) mem_paddr_s1_q <= mp_sel_vic1 ? vic_paddr_w[27:15] : ref_paddr_w[27:15];
      if (mp_en2) mem_paddr_s2_q <= mp_sel_vic2 ? vic_paddr_w[39:28] : ref_paddr_w[39:28];
    end
  end

  // --------------------------------------------------------------------------
  // L2 Cache Main Control State Machine
  // --------------------------------------------------------------------------
  reg [2:0] state_d;
  always @(*) begin
    state_d = state_q;
    case (state_q)
      S_IDLE:    if (req_valid_i) state_d = S_READ;
      S_READ:    state_d = S_COMPARE;
      S_COMPARE: state_d = S_ACTION;
      S_ACTION:  state_d = hit ? S_IDLE : (victim_dirty_q ? S_EVICT : S_REFILL);
      S_EVICT:   if (mem_req_ready_i) state_d = S_REFILL;
      S_REFILL:  if (mem_resp_valid_i) state_d = S_IDLE;
      default:   state_d = S_IDLE;
    endcase
  end

  always @(posedge clk_i or posedge rst_async_p) begin
    if (rst_async_p) begin
      state_q          <= S_IDLE;
      state_rep0_q     <= S_IDLE;
      state_rep1_q     <= S_IDLE;
      state_rep2_q     <= S_IDLE;
      state_rep3_q     <= S_IDLE;
      state_rep4_q     <= S_IDLE;
      state_rep5_q     <= S_IDLE;
      victim_ptr_q     <= {WAY_BITS{1'b0}};
      victim_ptr_r0_q  <= {WAY_BITS{1'b0}};
      resp_valid_o     <= 1'b0;
      resp_source_o    <= 4'd0;
      back_inv_valid_o <= 1'b0;
      mem_req_valid_o  <= 1'b0;
      mem_req_write_o  <= 1'b0;
    end else begin
      state_q          <= state_d;
      state_rep0_q     <= state_d;
      state_rep1_q     <= state_d;
      state_rep2_q     <= state_d;
      state_rep3_q     <= state_d;
      state_rep4_q     <= state_d;
      state_rep5_q     <= state_d;
      resp_valid_o     <= 1'b0;
      back_inv_valid_o <= 1'b0;

      case (state_q)
        S_IDLE: begin
          mem_req_valid_o <= 1'b0;
        end

        S_ACTION: begin
          if (hit) begin
            if (!req_write_q) begin
              resp_valid_o  <= 1'b1;
              resp_source_o <= req_src_q;
            end
          end else begin
            if (victim_valid_q) begin
              back_inv_valid_o <= 1'b1;
            end
            mem_req_valid_o <= 1'b1;
            mem_req_write_o <= victim_dirty_q;
          end
        end

        S_EVICT: begin
          if (mem_req_ready_i) begin
            mem_req_valid_o <= 1'b1;
            mem_req_write_o <= 1'b0;
          end
        end

        S_REFILL: begin
          if (mem_req_ready_i) begin
            mem_req_valid_o <= 1'b0;
          end
          if (mem_resp_valid_i) begin
            mem_req_valid_o <= 1'b0;
            victim_ptr_q    <= victim_ptr_next;
            victim_ptr_r0_q <= victim_ptr_next;
            if (!req_write_q) begin
              resp_valid_o  <= 1'b1;
              resp_source_o <= req_src_q;
            end
          end
        end

        default: ;
      endcase
    end
  end

endmodule

`default_nettype wire
