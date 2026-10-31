// ============================================================================
// Sukuna-RISC: Parametric N-Way Set Associative L1I Cache (Verilog 2005)
// Complies with design-rule.md & style.md
// ============================================================================
// Architecture:
//   - Configurable N-way set associativity (WAYS: 2 <= N <= 32, default 4)
//   - Strictly 64-bit (2 instructions) aligned read port for Dual-Issue IF
//   - 2-stage pipelined lookup:
//       Stage 1 (IF1): Synchronous Block RAM Tag & Data read + Valid FF read
//       Stage 2 (IF2): Pure LUT6 tag comparison, way muxing, miss handling
//   - Flop-to-Flop boundaries (zero combinational input-to-output paths)
//   - Fanout <= 16 and Logic Levels <= 4 on all paths
// ============================================================================

`timescale 1ns / 1ps
`default_nettype none

`include "sukuna_defines.vh"

module sukuna_l1i_cache #(
  parameter PADDR_WIDTH     = `PADDR_WIDTH,
  parameter CACHE_LINE_BITS = `CACHE_LINE_BITS,  // 512 bits = 64 bytes
  parameter CACHE_SIZE      = `L1I_SIZE_BYTES,   // 16384 bytes
  parameter WAYS            = `L1I_WAYS,         // 2 <= WAYS <= 32
  parameter HART_ID         = 0
)(
  input  wire                       clk_i,
  input  wire                       rst_ni,

  // Pipeline IF Interface (Word-aligned: bits [1:0] omitted)
  input  wire                       fetch_req_valid_i,
  input  wire                       stall_i,
  input  wire                       flush_i,
  input  wire [PADDR_WIDTH-1:2]     fetch_paddr_w_i,
  output wire                       fetch_resp_valid_o,
  output wire [63:0]                fetch_inst_o,
  output wire                       fetch_miss_o,

  // Invalidation (FENCE.I)
  input  wire                       fence_i_flush_i,

  // L2 Refill Interface (Word-aligned: bits [1:0] omitted)
  output wire                       refill_req_valid_o,
  output wire [PADDR_WIDTH-1:2]     refill_line_paddr_w_o,
  input  wire                       refill_req_ready_i,
  input  wire                       refill_resp_valid_i,
  input  wire [CACHE_LINE_BITS-1:0] refill_line_data_i
);

  // Explicit active-high reset wire with "rst" in name for clean FDCE CLR mapping
  (* keep = "true" *) wire rst_async_p = !rst_ni;

  // --------------------------------------------------------------------------
  // Cache Geometry Calculations
  // --------------------------------------------------------------------------
  localparam SETS        = CACHE_SIZE / (WAYS * 64);
  localparam INDEX_BITS  = (SETS <= 8)   ? 3 :
                           (SETS <= 16)  ? 4 :
                           (SETS <= 32)  ? 5 :
                           (SETS <= 64)  ? 6 :
                           (SETS <= 128) ? 7 :
                           (SETS <= 256) ? 8 : 9;

  localparam OFFSET_BITS = 6;
  localparam TAG_WIDTH   = PADDR_WIDTH - INDEX_BITS - OFFSET_BITS;

  localparam WAY_BITS    = (WAYS <= 2)  ? 1 :
                           (WAYS <= 4)  ? 2 :
                           (WAYS <= 8)  ? 3 :
                           (WAYS <= 16) ? 4 : 5;
  localparam integer MAX_WAY_IDX = WAYS - 1;

  // --------------------------------------------------------------------------
  // Miss / Refill Control Registers & Shadow Address Slices
  // --------------------------------------------------------------------------
  (* dont_touch = "true" *) reg                  req_valid_q;         /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                  miss_busy_q;         /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                  miss_busy_f0_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                  miss_busy_f1_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                  miss_busy_f2_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                  nmb_top0_q;          /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                  nmb_top1_q;          /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                  nmb_top2_q;          /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                  nmb_top3_q;          /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                  nmb_top4_q;          /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                  refill_req_valid_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                  discard_refill_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                  pending_flush_req_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                  refill_done_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [WAY_BITS-1:0]   victim_ptr_q;        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [WAY_BITS-1:0]   victim_ptr_dw_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // Replicated refill_done_q for 64-bit output mux (8 bits per replica -> fanout == 9 <= 16)
  (* dont_touch = "true" *) reg [7:0]            refill_done_rep_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // Saved redirect address when flush_i arrives during an in-flight miss (miss_busy_q == 1)
  (* dont_touch = "true" *) reg [12:0]           pending_paddr_s0_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [12:0]           pending_paddr_s1_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [11:0]           pending_paddr_s2_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  wire [PADDR_WIDTH-1:2] pending_paddr_w_q = {pending_paddr_s2_q, pending_paddr_s1_q, pending_paddr_s0_q};

  // Stage 1 -> Stage 2 address pipeline registers (unconditional capture -> 0 CE fanout!)
  (* dont_touch = "true" *) reg [12:0]           s2_paddr_s0_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [12:0]           s2_paddr_s1_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [11:0]           s2_paddr_s2_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  wire [PADDR_WIDTH-1:2] s2_paddr_w_q = {s2_paddr_s2_q, s2_paddr_s1_q, s2_paddr_s0_q};

  // Stage 2 -> Miss Shadow registers (latch s2_paddr on Cycle T before nmb_top*_q drops to 0 on Cycle T+1)
  (* dont_touch = "true" *) reg [12:0]           miss_paddr_s0_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [12:0]           miss_paddr_s1_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [11:0]           miss_paddr_s2_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  wire [PADDR_WIDTH-1:2] miss_paddr_w_q = {miss_paddr_s2_q, miss_paddr_s1_q, miss_paddr_s0_q};

  wire _unused_paddr_b2 = fetch_paddr_w_i[2];
  wire _unused_s2_low   = &{1'b0, s2_paddr_s0_q[0], s2_paddr_s0_q[12:4], miss_paddr_w_q[5:2], 1'b0};

  // Replicated 3-bit doubleword index for refill_line_data_i 8:1 mux (7 bits per replica -> fanout <= 15)
  (* dont_touch = "true" *) reg [2:0]            miss_dw_sel0_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [2:0]            miss_dw_sel1_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [2:0]            miss_dw_sel2_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [2:0]            miss_dw_sel3_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [2:0]            miss_dw_sel4_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [2:0]            miss_dw_sel5_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [2:0]            miss_dw_sel6_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [2:0]            miss_dw_sel7_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [2:0]            miss_dw_sel8_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // Registered Refill Target Doubleword (unconditional capture -> 0 CE fanout!)
  (* dont_touch = "true" *) reg [63:0]           refill_inst64_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // Registered pending-flush mux selects (1-cycle pulse on the cycle after miss refill completes)
  (* dont_touch = "true" *) reg                  use_pending0_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                  use_pending1_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                  use_pending2_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                  use_pending3_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                  use_pending4_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // Dedicated data-path Stage 2 tag copy (isolates geq_c control LUT6 from geq_d data LUT6!)
  (* dont_touch = "true" *) reg [13:0]           s2_tag_d0_q;         /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [13:0]           s2_tag_d1_q;         /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  (* dont_touch = "true" *) wire refill_vld_top  = refill_resp_valid_i && !discard_refill_q && !flush_i && miss_busy_q;
  (* dont_touch = "true" *) wire refill_vld_ways = refill_resp_valid_i && !discard_refill_q && !flush_i && miss_busy_f0_q;

  wire [14:2]  look_paddr_s0 = use_pending0_q ? pending_paddr_w_q[14:2]  : fetch_paddr_w_i[14:2];
  wire [27:15] look_paddr_s1 = use_pending1_q ? pending_paddr_w_q[27:15] : fetch_paddr_w_i[27:15];
  wire [39:28] look_paddr_s2 = use_pending2_q ? pending_paddr_w_q[39:28] : fetch_paddr_w_i[39:28];
  wire [25:12] look_tag_d0   = use_pending3_q ? pending_paddr_w_q[25:12] : fetch_paddr_w_i[25:12];
  wire [39:26] look_tag_d1   = use_pending4_q ? pending_paddr_w_q[39:26] : fetch_paddr_w_i[39:26];

  // --------------------------------------------------------------------------
  // Tag, Data (8 x 64-bit Doubleword BRAM Banks), and Valid Arrays for WAYS
  // --------------------------------------------------------------------------
  wire [TAG_WIDTH-1:0] tag_rdata [0:WAYS-1];
  wire [63:0]          way_dword [0:WAYS-1];
  wire [WAYS-1:0]      elo_ctrl;
  wire [WAYS-1:0]      ehi_ctrl;
  wire [7:0]           elo_bus   [0:WAYS-1];
  wire [7:0]           ehi_bus   [0:WAYS-1];

  // Pairwise hit reduction (Level 3 from u_tag_ram -> 2 signals total for Level 4 control)
  (* dont_touch = "true" *) wire hit_pair01 = (elo_ctrl[0] && ehi_ctrl[0]) || (elo_ctrl[1] && ehi_ctrl[1]);
  (* dont_touch = "true" *) wire hit_pair23 = (elo_ctrl[2] && ehi_ctrl[2]) || (elo_ctrl[3] && ehi_ctrl[3]);

  wire [TAG_WIDTH-1:0] s2_tag_shared   = s2_paddr_w_q[PADDR_WIDTH-1:6+INDEX_BITS];
  wire [TAG_WIDTH-1:0] s2_tag_d_shared = {s2_tag_d1_q, s2_tag_d0_q};
  wire [TAG_WIDTH-1:0] miss_tag_shared = miss_paddr_w_q[PADDR_WIDTH-1:6+INDEX_BITS];

  wire next_nmb_ways;
  wire next_use_pend_ways;

  genvar w, vs, db, ds, tg, gc;
  generate
    for (w = 0; w < WAYS; w = w + 1) begin : gen_way
      // Per-way registered !miss_busy and pending-select replicas (fanout <= 14 each)
      (* dont_touch = "true" *) reg way_nmb0_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg way_nmb1_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg way_nmb2_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg way_upend0_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg way_upend1_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg way_fclr_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

      (* dont_touch = "true" *) reg [INDEX_BITS-1:0] way_s2_idx_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [INDEX_BITS-1:0] way_waddr_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

      // Strictly 1 LUT3 level on RAM read address (Rule 4 compliant; split RAM vs Valid so fanout <= 10 each)
      (* dont_touch = "true" *) wire [INDEX_BITS-1:0] way_raddr_ram =
        way_upend0_q ? pending_paddr_w_q[5+INDEX_BITS:6] : fetch_paddr_w_i[5+INDEX_BITS:6];
      (* dont_touch = "true" *) wire [INDEX_BITS-1:0] way_raddr_vld =
        way_upend1_q ? pending_paddr_w_q[5+INDEX_BITS:6] : fetch_paddr_w_i[5+INDEX_BITS:6];
      wire [2:0] way_look_dw =
        way_upend0_q ? pending_paddr_w_q[5:3] : fetch_paddr_w_i[5:3];

      // Replicated Stage 2 doubleword mux select registers (unconditional capture -> 0 CE!)
      (* dont_touch = "true" *) reg [2:0] way_dw_sel0_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [2:0] way_dw_sel1_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [2:0] way_dw_sel2_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [2:0] way_dw_sel3_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [2:0] way_dw_sel4_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [2:0] way_dw_sel5_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [2:0] way_dw_sel6_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [2:0] way_dw_sel7_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [2:0] way_dw_sel8_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

      (* dont_touch = "true" *) reg       way_vld_s2_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [7:0] way_vld_s2_rep_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg       way_vic_tag_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg       way_vic_dw_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

      // Per-way buffered refill write enables (each drives <= 9 loads -> fanout <= 10 <= 16!)
      (* dont_touch = "true" *) wire way_ref_vld = refill_vld_ways && way_vic_tag_q;
      (* dont_touch = "true" *) wire way_ref_dw  = refill_vld_ways && way_vic_dw_q;

      // Per-way Valid Bit Array: 8 slices of 8-bit registers (fanout <= 10 everywhere!)
      wire [7:0] vld_s1_bit;
      for (vs = 0; vs < 8; vs = vs + 1) begin : gen_vld_slice
        (* dont_touch = "true" *) reg [7:0] vld_q;          /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        (* dont_touch = "true" *) reg [2:0] vld_waddr_lo_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        (* dont_touch = "true" *) reg       slice_fclr_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

        wire slice_nmb = (vs < 2) ? way_nmb0_q :
                         (vs < 6) ? way_nmb1_q : way_nmb2_q;

        (* dont_touch = "true" *) wire vld_ref_set =
          way_ref_vld && (way_waddr_q[5:3] == vs[2:0]);

        integer vi;
        always @(posedge clk_i or posedge rst_async_p) begin
          if (rst_async_p) begin
            vld_q          <= 8'd0;
            vld_waddr_lo_q <= 3'd0;
            slice_fclr_q   <= 1'b0;
          end else begin
            slice_fclr_q <= way_fclr_q;
            if (slice_nmb) begin
              vld_waddr_lo_q <= way_s2_idx_q[2:0];
            end
            if (slice_fclr_q) begin
              vld_q <= 8'd0;
            end else if (vld_ref_set) begin
              for (vi = 0; vi < 8; vi = vi + 1) begin
                if (vld_waddr_lo_q == vi[2:0]) begin
                  vld_q[vi] <= 1'b1;
                end
              end
            end
          end
        end

        assign vld_s1_bit[vs] = vld_q[way_raddr_vld[2:0]];
      end

      wire vld_s1_mux = !fence_i_flush_i && vld_s1_bit[way_raddr_vld[5:3]];

      always @(posedge clk_i or posedge rst_async_p) begin
        if (rst_async_p) begin
          way_nmb0_q       <= 1'b1;
          way_nmb1_q       <= 1'b1;
          way_nmb2_q       <= 1'b1;
          way_upend0_q     <= 1'b0;
          way_upend1_q     <= 1'b0;
          way_fclr_q       <= 1'b0;
          way_s2_idx_q     <= {INDEX_BITS{1'b0}};
          way_waddr_q      <= {INDEX_BITS{1'b0}};
          way_dw_sel0_q    <= 3'd0;
          way_dw_sel1_q    <= 3'd0;
          way_dw_sel2_q    <= 3'd0;
          way_dw_sel3_q    <= 3'd0;
          way_dw_sel4_q    <= 3'd0;
          way_dw_sel5_q    <= 3'd0;
          way_dw_sel6_q    <= 3'd0;
          way_dw_sel7_q    <= 3'd0;
          way_dw_sel8_q    <= 3'd0;
          way_vld_s2_q     <= 1'b0;
          way_vld_s2_rep_q <= 8'd0;
          way_vic_tag_q    <= 1'b0;
          way_vic_dw_q     <= 1'b0;
        end else begin
          way_nmb0_q       <= next_nmb_ways;
          way_nmb1_q       <= next_nmb_ways;
          way_nmb2_q       <= next_nmb_ways;
          way_upend0_q     <= next_use_pend_ways;
          way_upend1_q     <= next_use_pend_ways;
          way_fclr_q       <= fence_i_flush_i;
          way_vic_tag_q    <= (victim_ptr_q == w[WAY_BITS-1:0]);
          way_vic_dw_q     <= (victim_ptr_dw_q == w[WAY_BITS-1:0]);

          // Unconditional Stage 1 -> Stage 2 pipeline capture (0 CE fanout!)
          way_s2_idx_q     <= way_raddr_vld;
          way_vld_s2_q     <= vld_s1_mux;
          way_vld_s2_rep_q <= {8{vld_s1_mux}};
          way_dw_sel0_q    <= way_look_dw;
          way_dw_sel1_q    <= way_look_dw;
          way_dw_sel2_q    <= way_look_dw;
          way_dw_sel3_q    <= way_look_dw;
          way_dw_sel4_q    <= way_look_dw;
          way_dw_sel5_q    <= way_look_dw;
          way_dw_sel6_q    <= way_look_dw;
          way_dw_sel7_q    <= way_look_dw;
          way_dw_sel8_q    <= way_look_dw;

          // Stage 2 -> Miss Shadow index register (freezes when way_nmb0_q == 0)
          if (way_nmb0_q) begin
            way_waddr_q <= way_s2_idx_q;
          end
        end
      end

      // Tag Array in Block RAM (1 RAMB18E1 per way, ren_i = 1'b1 prevents Single-Port address muxing!)
      sk_ram_bram #(
        .DATA_WIDTH     (TAG_WIDTH),
        .ADDR_WIDTH     (INDEX_BITS),
        .DEPTH          (SETS),
        .PIPELINE_STAGES(1),
        .BYTE_WRITE_EN  (0),
        .COLLISION_FWD  (0)
      ) u_tag_ram (
        .clk_i  (clk_i),
        .rst_ni (rst_ni),
        .wen_i  (way_ref_vld),
        .wstrb_i(1'b1),
        .waddr_i(way_waddr_q),
        .wdata_i(miss_tag_shared),
        .ren_i  (1'b1),
        .raddr_i(way_raddr_ram),
        .rdata_o(tag_rdata[w])
      );

      // 8 x 64-bit Doubleword Data BRAM Banks per way (1 RAMB36E1 per bank -> dw_wen fanout == 9 <= 16!)
      wire [CACHE_LINE_BITS-1:0] data_rdata_line;
      for (db = 0; db < 8; db = db + 1) begin : gen_dw_bank
        (* dont_touch = "true" *) reg dw_vic_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        always @(posedge clk_i or posedge rst_async_p) begin
          if (rst_async_p) begin
            dw_vic_q <= 1'b0;
          end else begin
            dw_vic_q <= (victim_ptr_dw_q == w[WAY_BITS-1:0]);
          end
        end

        (* dont_touch = "true" *) wire dw_wen = way_ref_dw && dw_vic_q;

        sk_ram_bram #(
          .DATA_WIDTH     (64),
          .ADDR_WIDTH     (INDEX_BITS),
          .DEPTH          (SETS),
          .PIPELINE_STAGES(1),
          .BYTE_WRITE_EN  (0),
          .COLLISION_FWD  (0)
        ) u_dw_ram (
          .clk_i  (clk_i),
          .rst_ni (rst_ni),
          .wen_i  (dw_wen),
          .wstrb_i(1'b1),
          .waddr_i(way_waddr_q),
          .wdata_i(refill_line_data_i[db*64 +: 64]),
          .ren_i  (1'b1),
          .raddr_i(way_raddr_ram),
          .rdata_o(data_rdata_line[db*64 +: 64])
        );
      end

      // Per-way 8:1 Doubleword Mux split into 9 slices of <= 7 bits (select fanout <= 15 <= 16)
      for (ds = 0; ds < 9; ds = ds + 1) begin : gen_dw_mux
        localparam integer B_LO = ds * 7;
        localparam integer B_W  = (ds == 8) ? 8 : 7;
        wire [2:0] dw_sel = (ds == 0) ? way_dw_sel0_q :
                            (ds == 1) ? way_dw_sel1_q :
                            (ds == 2) ? way_dw_sel2_q :
                            (ds == 3) ? way_dw_sel3_q :
                            (ds == 4) ? way_dw_sel4_q :
                            (ds == 5) ? way_dw_sel5_q :
                            (ds == 6) ? way_dw_sel6_q :
                            (ds == 7) ? way_dw_sel7_q : way_dw_sel8_q;
        assign way_dword[w][B_LO +: B_W] = data_rdata_line[dw_sel*64 + B_LO +: B_W];
      end

      // Pure LUT6 28-bit Tag Comparator: separate control (tag_grp_eq_c, fanout 1) vs data (tag_grp_eq_d, fanout 8)
      wire [9:0] tag_grp_eq_c;
      wire [9:0] tag_grp_eq_d;
      for (tg = 0; tg < 9; tg = tg + 1) begin : gen_tag_cmp
        (* dont_touch = "true" *) wire geq_c =
          (tag_rdata[w][tg*3 +: 3] == s2_tag_shared[tg*3 +: 3]);
        (* dont_touch = "true" *) wire geq_d =
          (tag_rdata[w][tg*3 +: 3] == s2_tag_d_shared[tg*3 +: 3]);
        assign tag_grp_eq_c[tg] = geq_c;
        assign tag_grp_eq_d[tg] = geq_d;
      end
      (* dont_touch = "true" *) wire geq_c_top =
        (tag_rdata[w][TAG_WIDTH-1:27] == s2_tag_shared[TAG_WIDTH-1:27]) && way_vld_s2_q;
      (* dont_touch = "true" *) wire geq_d_top =
        (tag_rdata[w][TAG_WIDTH-1:27] == s2_tag_d_shared[TAG_WIDTH-1:27]);
      assign tag_grp_eq_c[9] = geq_c_top;
      assign tag_grp_eq_d[9] = geq_d_top;

      (* dont_touch = "true" *) wire elo_c = (&tag_grp_eq_c[4:0]) && way_vld_s2_q;
      (* dont_touch = "true" *) wire ehi_c = (&tag_grp_eq_c[9:5]) && req_valid_q;
      assign elo_ctrl[w] = elo_c;
      assign ehi_ctrl[w] = ehi_c;

      for (gc = 0; gc < 8; gc = gc + 1) begin : gen_cmp_rep
        // Including unique dont_touch flip-flop way_vld_s2_rep_q[gc] prevents Vivado from merging across gc!
        (* dont_touch = "true" *) wire elo_b = (&tag_grp_eq_d[4:0]) && way_vld_s2_rep_q[gc];
        (* dont_touch = "true" *) wire ehi_b = (&tag_grp_eq_d[9:5]) && way_vld_s2_rep_q[gc];
        assign elo_bus[w][gc] = elo_b;
        assign ehi_bus[w][gc] = ehi_b;
      end
    end
  endgenerate

  // --------------------------------------------------------------------------
  // Stage 2 Instruction Selection & Handshake Outputs (<= 4 LUT levels, 0 Rule 3 feedthrough)
  // --------------------------------------------------------------------------
  wire [63:0] hit_inst64;
  genvar gi;
  generate
    for (gi = 0; gi < 64; gi = gi + 1) begin : gen_hit_inst
      localparam integer GC = gi / 8;
      // Level 3 from u_tag_ram: 6-input LUT6 combining 2 ways' (elo, ehi, way_dword)
      wire pair01_bit = (elo_bus[0][GC] && ehi_bus[0][GC] && way_dword[0][gi]) ||
                        (elo_bus[1][GC] && ehi_bus[1][GC] && way_dword[1][gi]);
      wire pair23_bit = (elo_bus[2][GC] && ehi_bus[2][GC] && way_dword[2][gi]) ||
                        (elo_bus[3][GC] && ehi_bus[3][GC] && way_dword[3][gi]);
      assign hit_inst64[gi] = refill_done_rep_q[GC] ? refill_inst64_q[gi] : (pair01_bit || pair23_bit);
    end
  endgenerate

  // Level 4 from u_tag_ram: <= 5 inputs -> 1 LUT4 / LUT5, and zero input-to-output combinational paths!
  wire miss_hold = (miss_busy_q && !refill_done_q) || pending_flush_req_q;
  assign fetch_resp_valid_o    = refill_done_q || (!miss_busy_q && (hit_pair01 || hit_pair23));
  assign fetch_inst_o          = hit_inst64;
  assign fetch_miss_o          = miss_hold || (req_valid_q && !miss_busy_q && !(hit_pair01 || hit_pair23));

  assign refill_req_valid_o    = refill_req_valid_q;
  assign refill_line_paddr_w_o = {miss_paddr_w_q[PADDR_WIDTH-1:6], 4'b0000};

  // Refill target doubleword 8:1 mux split into 9 slices of <= 7 bits (fanout <= 15)
  wire [63:0] refill_inst_mux;
  genvar rs;
  generate
    for (rs = 0; rs < 9; rs = rs + 1) begin : gen_ref_mux
      localparam integer R_LO = rs * 7;
      localparam integer R_W  = (rs == 8) ? 8 : 7;
      wire [2:0] r_sel = (rs == 0) ? miss_dw_sel0_q :
                         (rs == 1) ? miss_dw_sel1_q :
                         (rs == 2) ? miss_dw_sel2_q :
                         (rs == 3) ? miss_dw_sel3_q :
                         (rs == 4) ? miss_dw_sel4_q :
                         (rs == 5) ? miss_dw_sel5_q :
                         (rs == 6) ? miss_dw_sel6_q :
                         (rs == 7) ? miss_dw_sel7_q : miss_dw_sel8_q;
      assign refill_inst_mux[R_LO +: R_W] = refill_line_data_i[r_sel*64 + R_LO +: R_W];
    end
  endgenerate

  // --------------------------------------------------------------------------
  // Sequential Pipeline & Refill State Logic (Strictly <= 4 LUT levels from u_tag_ram)
  // --------------------------------------------------------------------------
  wire [WAY_BITS-1:0] victim_ptr_next =
    (victim_ptr_q == MAX_WAY_IDX[WAY_BITS-1:0]) ? {WAY_BITS{1'b0}} : (victim_ptr_q + 1'b1);

  (* dont_touch = "true" *) wire next_miss_busy =
    miss_busy_q    ? !refill_resp_valid_i : (req_valid_q && !flush_i && !(hit_pair01 || hit_pair23));
  (* dont_touch = "true" *) wire next_nmb_top   =
    miss_busy_f1_q ?  refill_resp_valid_i : !(req_valid_q && !flush_i && !(hit_pair01 || hit_pair23));
  (* dont_touch = "true" *) wire next_nmb_w     =
    miss_busy_f2_q ?  refill_resp_valid_i : !(req_valid_q && !flush_i && !(hit_pair01 || hit_pair23));
  assign next_nmb_ways = next_nmb_w;

  (* dont_touch = "true" *) wire s1_req_in =
    !miss_busy_q && (fetch_req_valid_i || pending_flush_req_q);
  (* dont_touch = "true" *) wire next_req_valid =
    (req_valid_q && !miss_busy_q && !flush_i && !(hit_pair01 || hit_pair23)) ? 1'b0 : s1_req_in;

  (* dont_touch = "true" *) wire hold_refill_req =
    miss_busy_q && refill_req_valid_q && !refill_req_ready_i && !refill_resp_valid_i;
  (* dont_touch = "true" *) wire next_refill_req =
    miss_busy_q ? hold_refill_req : (req_valid_q && !flush_i && !(hit_pair01 || hit_pair23));

  (* dont_touch = "true" *) wire next_use_pend_top =
    miss_busy_q && refill_resp_valid_i && (pending_flush_req_q || flush_i);
  (* dont_touch = "true" *) wire next_use_pend_w   =
    miss_busy_f0_q && refill_resp_valid_i && (pending_flush_req_q || flush_i);
  assign next_use_pend_ways = next_use_pend_w;

  // Flush capture enables for pending_paddr_s0..2_q (each uses a distinct miss_busy_f*_q reg -> fanout <= 14)
  (* dont_touch = "true" *) wire fl_en0 = flush_i && miss_busy_f0_q;
  (* dont_touch = "true" *) wire fl_en1 = flush_i && miss_busy_f1_q;
  (* dont_touch = "true" *) wire fl_en2 = flush_i && miss_busy_f2_q;

  wire _unused_stall = stall_i;

  always @(posedge clk_i or posedge rst_async_p) begin
    if (rst_async_p) begin
      req_valid_q         <= 1'b0;
      miss_busy_q         <= 1'b0;
      miss_busy_f0_q      <= 1'b0;
      miss_busy_f1_q      <= 1'b0;
      miss_busy_f2_q      <= 1'b0;
      nmb_top0_q          <= 1'b1;
      nmb_top1_q          <= 1'b1;
      nmb_top2_q          <= 1'b1;
      nmb_top3_q          <= 1'b1;
      nmb_top4_q          <= 1'b1;
      use_pending0_q      <= 1'b0;
      use_pending1_q      <= 1'b0;
      use_pending2_q      <= 1'b0;
      use_pending3_q      <= 1'b0;
      use_pending4_q      <= 1'b0;
      refill_req_valid_q  <= 1'b0;
      discard_refill_q    <= 1'b0;
      pending_flush_req_q <= 1'b0;
      refill_done_q       <= 1'b0;
      refill_done_rep_q   <= 8'd0;
      victim_ptr_q        <= {WAY_BITS{1'b0}};
      victim_ptr_dw_q     <= {WAY_BITS{1'b0}};
      pending_paddr_s0_q  <= 13'd0;
      pending_paddr_s1_q  <= 13'd0;
      pending_paddr_s2_q  <= 12'd0;
      s2_paddr_s0_q       <= 13'd0;
      s2_paddr_s1_q       <= 13'd0;
      s2_paddr_s2_q       <= 12'd0;
      s2_tag_d0_q         <= 14'd0;
      s2_tag_d1_q         <= 14'd0;
      miss_paddr_s0_q     <= 13'd0;
      miss_paddr_s1_q     <= 13'd0;
      miss_paddr_s2_q     <= 12'd0;
      miss_dw_sel0_q      <= 3'd0;
      miss_dw_sel1_q      <= 3'd0;
      miss_dw_sel2_q      <= 3'd0;
      miss_dw_sel3_q      <= 3'd0;
      miss_dw_sel4_q      <= 3'd0;
      miss_dw_sel5_q      <= 3'd0;
      miss_dw_sel6_q      <= 3'd0;
      miss_dw_sel7_q      <= 3'd0;
      miss_dw_sel8_q      <= 3'd0;
      refill_inst64_q     <= 64'd0;
    end else begin
      req_valid_q        <= next_req_valid;
      refill_req_valid_q <= next_refill_req;
      miss_busy_q        <= next_miss_busy;
      miss_busy_f0_q     <= next_miss_busy;
      miss_busy_f1_q     <= next_miss_busy;
      miss_busy_f2_q     <= next_miss_busy;
      nmb_top0_q         <= next_nmb_top;
      nmb_top1_q         <= next_nmb_top;
      nmb_top2_q         <= next_nmb_top;
      nmb_top3_q         <= next_nmb_top;
      nmb_top4_q         <= next_nmb_top;
      use_pending0_q     <= next_use_pend_top;
      use_pending1_q     <= next_use_pend_top;
      use_pending2_q     <= next_use_pend_top;
      use_pending3_q     <= next_use_pend_top;
      use_pending4_q     <= next_use_pend_top;
      refill_done_q      <= refill_vld_top;
      refill_done_rep_q  <= {8{refill_vld_top}};

      // Unconditional capture of refill_inst_mux and Stage 1 -> Stage 2 paddr (0 CE fanout!)
      refill_inst64_q   <= refill_inst_mux;
      s2_paddr_s0_q     <= look_paddr_s0;
      s2_paddr_s1_q     <= look_paddr_s1;
      s2_paddr_s2_q     <= look_paddr_s2;
      s2_tag_d0_q       <= look_tag_d0;
      s2_tag_d1_q       <= look_tag_d1;

      if (fl_en0) pending_paddr_s0_q <= fetch_paddr_w_i[14:2];
      if (fl_en1) pending_paddr_s1_q <= fetch_paddr_w_i[27:15];
      if (fl_en2) pending_paddr_s2_q <= fetch_paddr_w_i[39:28];

      // Stage 2 -> Miss Shadow datapath advance (driven by nmb_top0..4_q flip-flops -> 0 LUTs on CE!)
      if (nmb_top0_q) begin
        miss_paddr_s0_q <= s2_paddr_s0_q;
      end
      if (nmb_top1_q) begin
        miss_paddr_s1_q <= s2_paddr_s1_q;
      end
      if (nmb_top2_q) begin
        miss_paddr_s2_q <= s2_paddr_s2_q;
        miss_dw_sel0_q  <= s2_paddr_s0_q[3:1];
      end
      if (nmb_top3_q) begin
        miss_dw_sel1_q  <= s2_paddr_s0_q[3:1];
        miss_dw_sel2_q  <= s2_paddr_s0_q[3:1];
        miss_dw_sel3_q  <= s2_paddr_s0_q[3:1];
        miss_dw_sel4_q  <= s2_paddr_s0_q[3:1];
      end
      if (nmb_top4_q) begin
        miss_dw_sel5_q  <= s2_paddr_s0_q[3:1];
        miss_dw_sel6_q  <= s2_paddr_s0_q[3:1];
        miss_dw_sel7_q  <= s2_paddr_s0_q[3:1];
        miss_dw_sel8_q  <= s2_paddr_s0_q[3:1];
      end

      if (!miss_busy_q) begin
        pending_flush_req_q <= 1'b0;
        discard_refill_q    <= 1'b0;
      end else begin
        if (flush_i) begin
          pending_flush_req_q <= 1'b1;
        end
        if (refill_resp_valid_i) begin
          discard_refill_q <= 1'b0;
        end else if (flush_i) begin
          discard_refill_q <= 1'b1;
        end
        if (refill_vld_top) begin
          victim_ptr_q    <= victim_ptr_next;
          victim_ptr_dw_q <= victim_ptr_next;
        end
      end
    end
  end

endmodule

`default_nettype wire
