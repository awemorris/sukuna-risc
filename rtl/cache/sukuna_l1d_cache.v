// ============================================================================
// Sukuna-RISC: Parametric N-Way Set Associative L1 Data Cache (Verilog 2005)
// Complies with design-rule.md & style.md
// ============================================================================
// Architecture:
//   - Configurable N-way set associativity (WAYS: 2 <= N <= 32, default 4)
//   - Write-Through with 4-Entry FIFO Store Buffer (non-blocking stores)
//   - Non-Blocking Write-Allocate via 1-Entry MSHR (delayed background refill
//     after Store Buffer drains to L2, so L2 already holds merged store bytes)
//   - Hit-Under-Miss for L1D Load hits while Store Buffer drains or MSHR pending
//   - All-Way Set Invalidation (Option B) on multi-Hart coherence snoop or
//     inclusive L2 eviction back-invalidation (zero Tag RAM port contention)
//   - Strictly Flop-to-Flop boundaries (0 feedthrough paths), Fanout <= 16,
//     and Logic Depth <= 4 LUT levels on all paths
// ============================================================================

`timescale 1ns / 1ps
`default_nettype none

`include "sukuna_defines.vh"

module sukuna_l1d_cache #(
  parameter XLEN            = `XLEN,             // 64-bit
  parameter PADDR_WIDTH     = `PADDR_WIDTH,
  parameter CACHE_LINE_BITS = `CACHE_LINE_BITS,  // 512 bits = 64 bytes
  parameter CACHE_SIZE      = `L1D_SIZE_BYTES,   // 16384 bytes
  parameter WAYS            = `L1D_WAYS,         // 2 <= WAYS <= 32
  parameter HART_ID         = 0
)(
  input  wire                       clk_i,
  input  wire                       rst_ni,

  // Pipeline AGU/MA Interface (Word-aligned address & byte enable)
  input  wire                       mem_req_valid_i,
  input  wire                       mem_req_write_i,
  input  wire [3:0]                 mem_req_op_i,      // AMO_* type from AGU
  input  wire [7:0]                 mem_byte_en_i,     // Byte enable vector
  input  wire [PADDR_WIDTH-1:2]     mem_paddr_w_i,     // Word address (bits [1:0] omitted)
  input  wire [XLEN-1:0]            mem_wdata_i,
  output wire                       mem_req_ready_o,
  output wire                       mem_resp_valid_o,
  output wire [XLEN-1:0]            mem_rdata_o,
  output wire                       mem_miss_stall_o,
  output wire                       sbuf_empty_o,
  output wire                       amo_lock_req_o,
  input  wire                       amo_lock_grant_i,

  // Coherence Snoop Port (All-Way Set Invalidate)
  input  wire                       snoop_req_valid_i,
  input  wire [PADDR_WIDTH-1:2]     snoop_paddr_w_i,
  input  wire                       snoop_invalidate_i,
  output wire                       snoop_hit_o,

  // L2 Refill / Write-Through Store Buffer Port
  output wire                       l2_req_valid_o,
  output wire                       l2_req_write_o,
  output wire [PADDR_WIDTH-1:2]     l2_line_paddr_w_o,
  output wire [CACHE_LINE_BITS-1:0] l2_wline_data_o,
  input  wire                       l2_req_ready_i,
  input  wire                       l2_resp_valid_i,
  input  wire [CACHE_LINE_BITS-1:0] l2_rline_data_i
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

  wire _unused_snoop = &{1'b0, snoop_paddr_w_i[5:2], snoop_paddr_w_i[PADDR_WIDTH-1:6+INDEX_BITS], 1'b0};
  wire _unused_req_p = mem_paddr_w_i[2];

  // --------------------------------------------------------------------------
  // Registered Snoop & Atomic Lock Inputs (Strictly 0 Combinational Feedthrough)
  // --------------------------------------------------------------------------
  (* dont_touch = "true" *) reg                  snoop_valid_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [INDEX_BITS-1:0] snoop_index_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                  amo_lock_grant_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                  is_sc_pipe_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  always @(posedge clk_i or posedge rst_async_p) begin
    if (rst_async_p) begin
      snoop_valid_q    <= 1'b0;
      snoop_index_q    <= {INDEX_BITS{1'b0}};
      amo_lock_grant_q <= 1'b0;
      is_sc_pipe_q     <= 1'b0;
    end else begin
      snoop_valid_q    <= snoop_req_valid_i && snoop_invalidate_i;
      snoop_index_q    <= snoop_paddr_w_i[5+INDEX_BITS:6];
      amo_lock_grant_q <= amo_lock_grant_i;
      is_sc_pipe_q     <= (mem_req_op_i == `AMO_SC);
    end
  end

  assign snoop_hit_o = snoop_valid_q;

  // --------------------------------------------------------------------------
  // State Machine Definitions
  // --------------------------------------------------------------------------
  localparam S_IDLE        = 3'd0;
  localparam S_REFILL_REQ  = 3'd1;
  localparam S_REFILL_WAIT = 3'd2;
  localparam S_REFILL_DONE = 3'd3;
  localparam S_AMO_DRAIN   = 3'd4;

  (* dont_touch = "true" *) reg [2:0]          state_q;            /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [2:0]          state_rep0_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [2:0]          state_rep1_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [2:0]          state_rep2_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [2:0]          state_rep3_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [2:0]          state_rep4_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [WAY_BITS-1:0] victim_ptr_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                refill_is_mshr_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                refill_snoop_inv_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                refill_done_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [7:0]          refill_done_rep_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [63:0]         refill_rdata64_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // Replicated 3-bit doubleword selector for refill_rdata64_q (unconditional capture from req_paddr_s0_q -> 0 CE!)
  (* dont_touch = "true" *) reg [2:0]          refill_dw_sel0_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [2:0]          refill_dw_sel1_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [2:0]          refill_dw_sel2_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [2:0]          refill_dw_sel3_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [2:0]          refill_dw_sel4_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [2:0]          refill_dw_sel5_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [2:0]          refill_dw_sel6_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [2:0]          refill_dw_sel7_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [2:0]          refill_dw_sel8_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // Refill physical address sliced into <= 12-bit registers (updated in S_IDLE without hit dependency!)
  (* dont_touch = "true" *) reg [11:0]         refill_paddr_s0_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [11:0]         refill_paddr_s1_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [13:0]         refill_paddr_s2_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  wire [PADDR_WIDTH-1:2] refill_paddr_w_q = {refill_paddr_s2_q, refill_paddr_s1_q, refill_paddr_s0_q};
  wire [INDEX_BITS-1:0]  refill_index     = refill_paddr_w_q[5+INDEX_BITS:6];
  wire [TAG_WIDTH-1:0]   refill_tag       = refill_paddr_w_q[PADDR_WIDTH-1:6+INDEX_BITS];

  // 1-Entry MSHR for Non-Blocking Write-Allocate (Delayed Background Refill)
  (* dont_touch = "true" *) reg                store_miss_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                wr_pipe_busy_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                mshr_valid_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                mshr_vld_r0_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                mshr_vld_r1_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                mshr_vld_r2_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                mshr_match_req_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [11:0]         store_line_s0_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [11:0]         store_line_s1_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [9:0]          store_line_s2_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [11:0]         mshr_line_s0_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [11:0]         mshr_line_s1_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [9:0]          mshr_line_s2_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  wire [PADDR_WIDTH-1:6] mshr_line_q = {mshr_line_s2_q, mshr_line_s1_q, mshr_line_s0_q};

  // --------------------------------------------------------------------------
  // Pipeline Stage 2 Registers (MA2) - Sliced into <= 13-bit groups
  // --------------------------------------------------------------------------
  (* dont_touch = "true" *) reg                req_valid_q;        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                req_vld_r0_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                req_vld_r1_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                req_vld_r2_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                req_vld_r3_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                req_nvl0_q;         /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                req_nvl1_q;         /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                req_nvl2_q;         /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                req_nvl3_q;         /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                req_nvl4_q;         /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                req_nvl5_q;         /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                req_nvl6_q;         /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                req_nvl7_q;         /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                req_nvl8_q;         /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                req_nvl9_q;         /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                req_nvl10_q;        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                req_nvl11_q;        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                req_nvl12_q;        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                req_nvl13_q;        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                req_nvl14_q;        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                req_nvl15_q;        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg                req_write_q;        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [3:0]          req_op_q;           /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [7:0]          req_byte_en_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [11:0]         req_paddr_s0_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [11:0]         req_paddr_s1_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [13:0]         req_paddr_s2_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [13:0]         req_tag_d0_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [13:0]         req_tag_d1_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [9:0]          req_tag_rep1_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [9:0]          req_tag_rep2_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [9:0]          req_tag_rep3_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [8:0]          req_tag_w0_hi_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [2:0]          req_tag_rep4_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [2:0]          req_tag_rep5_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [2:0]          req_tag_rep6_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [2:0]          req_tag_rep7_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  wire [PADDR_WIDTH-1:2] req_paddr_w_q = {req_paddr_s2_q, req_paddr_s1_q, req_paddr_s0_q};
  wire [TAG_WIDTH-1:0]   req_tag_s2    = req_paddr_w_q[PADDR_WIDTH-1:6+INDEX_BITS];
  wire [TAG_WIDTH-1:0]   req_tag_d_s2  = {req_tag_d1_q, req_tag_d0_q};
  wire [9:0]             req_tag_b0_in = {
    mem_paddr_w_i[39], mem_paddr_w_i[36], mem_paddr_w_i[33], mem_paddr_w_i[30], mem_paddr_w_i[27],
    mem_paddr_w_i[24], mem_paddr_w_i[21], mem_paddr_w_i[18], mem_paddr_w_i[15], mem_paddr_w_i[12]
  };
  wire [2:0]             req_tag_hi3_in = {
    mem_paddr_w_i[36], mem_paddr_w_i[33], mem_paddr_w_i[30]
  };

  (* dont_touch = "true" *) reg [12:0]         req_wdata_s0_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [12:0]         req_wdata_s1_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [12:0]         req_wdata_s2_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [12:0]         req_wdata_s3_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg [11:0]         req_wdata_s4_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  wire [XLEN-1:0] req_wdata_q = {req_wdata_s4_q, req_wdata_s3_q, req_wdata_s2_q, req_wdata_s1_q, req_wdata_s0_q};

  // Pure LUT6 34-bit equality comparator for (mshr_line_q == req_paddr_w_q[39:6]) (avoids CARRY4 fanout!)
  wire [11:0] mshr_eq_grp;
  genvar mg;
  generate
    for (mg = 0; mg < 11; mg = mg + 1) begin : gen_mshr_cmp
      (* dont_touch = "true" *) wire meq =
        (mshr_line_q[6 + mg*3 +: 3] == req_paddr_w_q[6 + mg*3 +: 3]);
      assign mshr_eq_grp[mg] = meq;
    end
  endgenerate
  (* dont_touch = "true" *) wire meq_top  = (mshr_line_q[39] == req_paddr_w_q[39]);
  assign mshr_eq_grp[11] = meq_top;
  (* dont_touch = "true" *) wire meq_lo   = &mshr_eq_grp[5:0];
  (* dont_touch = "true" *) wire meq_hi   = &mshr_eq_grp[11:6];
  wire mshr_eq_req_line = meq_lo && meq_hi;

  // Atomic classification
  wire req_is_sc_s1     = (mem_req_op_i == `AMO_SC);
  wire req_is_amo_rw_s1 = (mem_req_op_i >= `AMO_SWAP && mem_req_op_i <= `AMO_MAXU);

  wire req_is_lr     = (req_op_q == `AMO_LR);
  wire req_is_sc     = (req_op_q == `AMO_SC);
  wire req_is_amo_rw = (req_op_q >= `AMO_SWAP && req_op_q <= `AMO_MAXU);
  wire req_is_atomic = req_is_lr || req_is_sc || req_is_amo_rw;
  (* dont_touch = "true" *) reg amo_lock_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg amo_rw_pend_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // --------------------------------------------------------------------------
  // 4-Entry Store Buffer FIFO (Write-Through to L2)
  // Sliced into 10 x 11-bit slices (0 unpacked arrays, fanout <= 13 everywhere!)
  // --------------------------------------------------------------------------
  (* dont_touch = "true" *) reg [2:0] sbuf_count_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  wire sbuf_empty = (sbuf_count_q == 3'd0);
  wire sbuf_full  = (sbuf_count_q == 3'd4);

  (* dont_touch = "true" *) wire sbuf_push   = (state_q      == S_IDLE) && req_valid_q && req_write_q && !sbuf_full;
  (* dont_touch = "true" *) wire sbuf_push_a = (state_rep0_q == S_IDLE) && req_valid_q && req_write_q && !sbuf_full;
  (* dont_touch = "true" *) wire sbuf_push_b = (state_rep1_q == S_IDLE) && req_valid_q && req_write_q && !sbuf_full;
  (* dont_touch = "true" *) wire sbuf_push_c = (state_rep2_q == S_IDLE) && req_valid_q && req_write_q && !sbuf_full;
  (* dont_touch = "true" *) wire sbuf_push_d = (state_rep3_q == S_IDLE) && req_valid_q && req_write_q && !sbuf_full;
  (* dont_touch = "true" *) wire sbuf_push_e = (state_rep4_q == S_IDLE) && req_valid_q && req_write_q && !sbuf_full;

  wire sbuf_pop = !sbuf_empty && l2_req_ready_i;

  wire [2:0] sbuf_count_next =
    ({sbuf_push, sbuf_pop} == 2'b10) ? (sbuf_count_q + 3'd1) :
    ({sbuf_push, sbuf_pop} == 2'b01) ? (sbuf_count_q - 3'd1) : sbuf_count_q;
  wire sbuf_not_empty_next = (sbuf_count_next != 3'd0);

  always @(posedge clk_i or posedge rst_async_p) begin
    if (rst_async_p) begin
      sbuf_count_q <= 3'd0;
    end else begin
      sbuf_count_q <= sbuf_count_next;
    end
  end

  wire [109:0] sbuf_in_bus = {req_paddr_w_q, req_byte_en_q, req_wdata_q};
  wire [109:0] ref_out_bus = {refill_paddr_w_q[PADDR_WIDTH-1:6], 4'b0000, 72'd0};
  wire [109:0] l2_mux_bus;

  genvar ss;
  generate
    for (ss = 0; ss < 10; ss = ss + 1) begin : gen_sbuf_slice
      localparam integer S_LO = ss * 11;

      (* dont_touch = "true" *) reg [1:0]  sl_wptr_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [1:0]  sl_rptr_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg        sl_not_empty_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [10:0] entry0_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [10:0] entry1_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [10:0] entry2_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [10:0] entry3_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

      wire sl_push_in = (ss < 2) ? sbuf_push_a :
                        (ss < 4) ? sbuf_push_b :
                        (ss < 6) ? sbuf_push_c :
                        (ss < 8) ? sbuf_push_d : sbuf_push_e;

      (* dont_touch = "true" *) wire push_e0 = sl_push_in && (sl_wptr_q == 2'd0);
      (* dont_touch = "true" *) wire push_e1 = sl_push_in && (sl_wptr_q == 2'd1);
      (* dont_touch = "true" *) wire push_e2 = sl_push_in && (sl_wptr_q == 2'd2);
      (* dont_touch = "true" *) wire push_e3 = sl_push_in && (sl_wptr_q == 2'd3);
      (* dont_touch = "true" *) wire sl_pop  = sl_not_empty_q && l2_req_ready_i;

      always @(posedge clk_i or posedge rst_async_p) begin
        if (rst_async_p) begin
          sl_wptr_q      <= 2'd0;
          sl_rptr_q      <= 2'd0;
          sl_not_empty_q <= 1'b0;
          entry0_q       <= 11'd0;
          entry1_q       <= 11'd0;
          entry2_q       <= 11'd0;
          entry3_q       <= 11'd0;
        end else begin
          sl_not_empty_q <= sbuf_not_empty_next;
          if (sl_push_in) begin
            sl_wptr_q <= sl_wptr_q + 2'd1;
          end
          if (sl_pop) begin
            sl_rptr_q <= sl_rptr_q + 2'd1;
          end
          if (push_e0) entry0_q <= sbuf_in_bus[S_LO +: 11];
          if (push_e1) entry1_q <= sbuf_in_bus[S_LO +: 11];
          if (push_e2) entry2_q <= sbuf_in_bus[S_LO +: 11];
          if (push_e3) entry3_q <= sbuf_in_bus[S_LO +: 11];
        end
      end

      wire [10:0] head_slice = (sl_rptr_q == 2'd3) ? entry3_q :
                               (sl_rptr_q == 2'd2) ? entry2_q :
                               (sl_rptr_q == 2'd1) ? entry1_q : entry0_q;

      assign l2_mux_bus[S_LO +: 11] = sl_not_empty_q ? head_slice : ref_out_bus[S_LO +: 11];
    end
  endgenerate

  assign sbuf_empty_o      = sbuf_empty && !req_valid_q && !wr_pipe_busy_q && !store_miss_q;
  assign l2_req_valid_o    = (!sbuf_empty) || (state_q == S_REFILL_REQ);
  assign l2_req_write_o    = !sbuf_empty;
  assign l2_line_paddr_w_o = l2_mux_bus[109:72];
  assign l2_wline_data_o   = {{(CACHE_LINE_BITS-72){1'b0}}, l2_mux_bus[71:0]};

  // --------------------------------------------------------------------------
  // Handshake & Stage 1 Acceptance
  // mem_req_ready_o is driven 100% by internal registers (0 feedthrough paths!)
  // --------------------------------------------------------------------------
  (* dont_touch = "true" *) wire mem_req_ready_r =
    (state_q == S_IDLE) && !req_valid_q && !wr_pipe_busy_q && !sbuf_full &&
    (!is_sc_pipe_q || (sbuf_empty && amo_lock_grant_q));
  (* dont_touch = "true" *) wire mem_req_ready_w =
    (state_rep0_q == S_IDLE) && !req_vld_r0_q && !wr_pipe_busy_q && !sbuf_full &&
    (!is_sc_pipe_q || (sbuf_empty && amo_lock_grant_q));
  (* dont_touch = "true" *) wire mem_req_ready_n =
    (state_rep1_q == S_IDLE) && !req_vld_r1_q && !wr_pipe_busy_q && !sbuf_full &&
    (!is_sc_pipe_q || (sbuf_empty && amo_lock_grant_q));
  assign mem_req_ready_o = mem_req_ready_r;

  wire accept_req   = mem_req_valid_i && mem_req_ready_r;
  wire accept_req_w = mem_req_valid_i && mem_req_ready_w;
  wire accept_req_n = mem_req_valid_i && mem_req_ready_n;

  (* dont_touch = "true" *) wire refill_wen_w01  = (state_rep0_q == S_REFILL_WAIT) && l2_resp_valid_i;
  (* dont_touch = "true" *) wire refill_wen_w23  = (state_rep1_q == S_REFILL_WAIT) && l2_resp_valid_i;
  (* dont_touch = "true" *) wire refill_vld_ways = (state_rep2_q == S_REFILL_WAIT) && l2_resp_valid_i && !refill_snoop_inv_q;

  // --------------------------------------------------------------------------
  // Tag, Data (4 x 128-bit BRAM Banks), and Valid Arrays for WAYS
  // --------------------------------------------------------------------------
  wire [TAG_WIDTH-1:0]                  tag_rdata [0:WAYS-1];
  (* dont_touch = "true" *) wire [63:0] way_dword [0:WAYS-1];
  wire [WAYS-1:0]      elo_ctrl0;
  wire [WAYS-1:0]      elo_ctrl1;
  wire [WAYS-1:0]      ehi_ctrl0;
  wire [WAYS-1:0]      ehi_ctrl1;
  wire [WAYS-1:0]      ehi_ctrl2;
  wire [WAYS-1:0]      ehi_ctrl3;
  wire [WAYS-1:0]      ehi_ctrl4;
  wire [WAYS-1:0]      ehi_ctrl5;
  wire [15:0]          e0_bus    [0:WAYS-1];
  wire [15:0]          e1_bus    [0:WAYS-1];
  wire [15:0]          e2_bus    [0:WAYS-1];
  wire [2:0]           w0_hi_eq0;
  wire [2:0]           w0_hi_eq1;
  wire [2:0]           w0_hi_eq2;
  wire [2:0]           w0_hi_eq3;
  wire [2:0]           w0_hi_eq4;
  wire [2:0]           w0_hi_eq5;
  wire [2:0]           w0_hi_eq6;
  wire [2:0]           w0_hi_eq7;

  wire mshr_snoop_cancel = snoop_valid_q && (snoop_index_q == mshr_line_s0_q[INDEX_BITS-1:0]);
  wire idle_demand_en_top;
  wire idle_demand_en_way;
  wire load_can_complete;
  wire load_comp_ways;
  wire load_comp_nvl;
  wire state_d_b2;
  wire state_d_b1;
  wire state_d_b0_ways;
  wire next_req_vld_ways;

  genvar w, vs, gb, ds, tg, gc, vd, vt;
  generate
    for (w = 0; w < WAYS; w = w + 1) begin : gen_dway
      // Per-way hierarchical state & control registers (dont_touch prevents merging across ways)
      (* dont_touch = "true" *) reg [2:0]            way_state0_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [2:0]            way_state1_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg                  way_req_vld0_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg                  way_req_vld1_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg                  way_req_vld2_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg                  way_vic_match_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg                  way_sinv_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [INDEX_BITS-1:0] way_snoop_idx_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [INDEX_BITS-1:0] way_s2_idx_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [INDEX_BITS-1:0] way_waddr_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [2:0]            way_s2_dw_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [7:0]            way_s2_be01_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [7:0]            way_s2_be23_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

      // 1 LUT3 level on RAM read address (Rule 4 compliant! Split RAM vs Valid so fanout <= 11 each)
      (* dont_touch = "true" *) wire [INDEX_BITS-1:0] way_raddr_ram =
        way_req_vld0_q ? way_s2_idx_q : mem_paddr_w_i[5+INDEX_BITS:6];
      (* dont_touch = "true" *) wire [INDEX_BITS-1:0] way_raddr_vld =
        way_req_vld1_q ? way_s2_idx_q : mem_paddr_w_i[5+INDEX_BITS:6];

      // Per-way buffered doubleword offset (equals mem_paddr_w_i[5:3] when way_req_vld0_q == 0)
      (* dont_touch = "true" *) wire [2:0] way_look_dw =
        way_req_vld0_q ? way_s2_dw_q : mem_paddr_w_i[5:3];

      // Per-way buffered refill valid (drives 8 vld_ref_set LUTs -> fanout == 9 <= 16!)
      (* dont_touch = "true" *) wire way_ref_vld = refill_vld_ways && way_vic_match_q;

      // Replicated Stage 2 doubleword mux select registers (9 replicas * 7 bits -> fanout <= 15)
      (* dont_touch = "true" *) reg [2:0] way_dw_sel0_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [2:0] way_dw_sel1_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [2:0] way_dw_sel2_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [2:0] way_dw_sel3_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [2:0] way_dw_sel4_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [2:0] way_dw_sel5_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [2:0] way_dw_sel6_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [2:0] way_dw_sel7_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [2:0] way_dw_sel8_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

      // Per-way 3-to-8 decoders for snoop clear & refill set low index bits (fanout == 9 <= 16!)
      wire [7:0] way_snp_dec;
      wire [7:0] way_ref_dec;
      for (vd = 0; vd < 8; vd = vd + 1) begin : gen_vdec
        (* dont_touch = "true" *) wire s_dec = (way_snoop_idx_q[2:0] == vd[2:0]);
        (* dont_touch = "true" *) wire r_dec = (way_waddr_q[2:0]     == vd[2:0]);
        assign way_snp_dec[vd] = s_dec;
        assign way_ref_dec[vd] = r_dec;
      end

      // Per-way Valid Bit Array: 8 slices of 8-bit registers with All-Way Set Invalidate
      wire [7:0] vld_s1_bit;
      for (vs = 0; vs < 8; vs = vs + 1) begin : gen_vld_slice
        (* dont_touch = "true" *) reg [7:0] vld_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

        (* dont_touch = "true" *) wire vld_ref_set =
          way_ref_vld && (way_waddr_q[5:3] == vs[2:0]);
        (* dont_touch = "true" *) wire vld_snp_clr =
          way_sinv_q && (way_snoop_idx_q[5:3] == vs[2:0]);

        integer vi;
        always @(posedge clk_i or posedge rst_async_p) begin
          if (rst_async_p) begin
            vld_q <= 8'd0;
          end else begin
            for (vi = 0; vi < 8; vi = vi + 1) begin
              if (vld_snp_clr && way_snp_dec[vi]) begin
                vld_q[vi] <= 1'b0;
              end else if (vld_ref_set && way_ref_dec[vi]) begin
                vld_q[vi] <= 1'b1;
              end
            end
          end
        end

        assign vld_s1_bit[vs] = vld_q[way_raddr_vld[2:0]];
      end

      wire snoop_match_raddr = way_sinv_q && (way_snoop_idx_q == way_raddr_vld);
      wire vld_s1_mux        = !snoop_match_raddr && vld_s1_bit[way_raddr_vld[5:3]];

      (* dont_touch = "true" *) reg       way_vld_s2_c0_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg       way_vld_s2_c1_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg       way_vld_s2_c2_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg       way_vld_s2_c3_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [7:0] way_vld_s2_rep_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

      // Per-way Stage 1 -> Stage 2 capture enables (each drives <= 12 FFs -> fanout <= 13 <= 16!)
      (* dont_touch = "true" *) wire way_acc0 = !way_req_vld0_q;
      (* dont_touch = "true" *) wire way_acc1 = !way_req_vld1_q;
      (* dont_touch = "true" *) wire way_acc2 = !way_req_vld2_q;
      (* dont_touch = "true" *) wire way_wcap = (way_state0_q == S_IDLE) || (way_state0_q == S_REFILL_REQ);

      always @(posedge clk_i or posedge rst_async_p) begin
        if (rst_async_p) begin
          way_state0_q     <= S_IDLE;
          way_state1_q     <= S_IDLE;
          way_req_vld0_q   <= 1'b0;
          way_req_vld1_q   <= 1'b0;
          way_req_vld2_q   <= 1'b0;
          way_vic_match_q  <= 1'b0;
          way_sinv_q       <= 1'b0;
          way_snoop_idx_q  <= {INDEX_BITS{1'b0}};
          way_s2_idx_q     <= {INDEX_BITS{1'b0}};
          way_waddr_q      <= {INDEX_BITS{1'b0}};
          way_s2_dw_q      <= 3'd0;
          way_s2_be01_q    <= 8'd0;
          way_s2_be23_q    <= 8'd0;
          way_dw_sel0_q    <= 3'd0;
          way_dw_sel1_q    <= 3'd0;
          way_dw_sel2_q    <= 3'd0;
          way_dw_sel3_q    <= 3'd0;
          way_dw_sel4_q    <= 3'd0;
          way_dw_sel5_q    <= 3'd0;
          way_dw_sel6_q    <= 3'd0;
          way_dw_sel7_q    <= 3'd0;
          way_dw_sel8_q    <= 3'd0;
          way_vld_s2_c0_q  <= 1'b0;
          way_vld_s2_c1_q  <= 1'b0;
          way_vld_s2_c2_q  <= 1'b0;
          way_vld_s2_c3_q  <= 1'b0;
          way_vld_s2_rep_q <= 8'd0;
        end else begin
          way_state0_q     <= {state_d_b2, state_d_b1, state_d_b0_ways};
          way_state1_q     <= {state_d_b2, state_d_b1, state_d_b0_ways};
          way_req_vld0_q   <= next_req_vld_ways;
          way_req_vld1_q   <= next_req_vld_ways;
          way_req_vld2_q   <= next_req_vld_ways;
          way_vic_match_q  <= (victim_ptr_q == w[WAY_BITS-1:0]);
          way_sinv_q       <= snoop_req_valid_i && snoop_invalidate_i;
          way_snoop_idx_q  <= snoop_paddr_w_i[5+INDEX_BITS:6];

          // Valid bit updated every cycle from way_raddr_vld (strictly 3 LUT levels total!)
          way_vld_s2_c0_q  <= vld_s1_mux;
          way_vld_s2_c1_q  <= vld_s1_mux;
          way_vld_s2_c2_q  <= vld_s1_mux;
          way_vld_s2_c3_q  <= vld_s1_mux;
          way_vld_s2_rep_q <= {8{vld_s1_mux}};

          if (way_acc0) begin
            way_s2_idx_q  <= mem_paddr_w_i[5+INDEX_BITS:6];
            way_s2_dw_q   <= way_look_dw;
            way_dw_sel0_q <= way_look_dw;
            way_dw_sel1_q <= way_look_dw;
          end
          if (way_acc1) begin
            way_s2_be01_q <= mem_byte_en_i;
            way_dw_sel2_q <= way_look_dw;
            way_dw_sel3_q <= way_look_dw;
          end
          if (way_acc2) begin
            way_s2_be23_q <= mem_byte_en_i;
            way_dw_sel4_q <= way_look_dw;
            way_dw_sel5_q <= way_look_dw;
            way_dw_sel6_q <= way_look_dw;
            way_dw_sel7_q <= way_look_dw;
            way_dw_sel8_q <= way_look_dw;
          end

          if (way_wcap) begin
            way_waddr_q <= (way_state0_q == S_IDLE) ? way_s2_idx_q : refill_paddr_s0_q[9:4];
          end
        end
      end

      wire way_ref_en = (w < 2) ? refill_wen_w01 : refill_wen_w23;
      (* dont_touch = "true" *) wire way_refill_wen = way_ref_en && way_vic_match_q;

      // Tag Array in Block RAM (1 RAMB18E1 per way, ren_i = 1'b1 prevents Single-Port address muxing!)
      sk_ram_bram #(
        .DATA_WIDTH     (TAG_WIDTH),
        .ADDR_WIDTH     (INDEX_BITS),
        .DEPTH          (SETS),
        .PIPELINE_STAGES(1),
        .BYTE_WRITE_EN  (0),
        .COLLISION_FWD  (0)
      ) u_dtag_ram (
        .clk_i  (clk_i),
        .rst_ni (rst_ni),
        .wen_i  (way_refill_wen),
        .wstrb_i(1'b1),
        .waddr_i(way_waddr_q),
        .wdata_i(refill_tag),
        .ren_i  (1'b1),
        .raddr_i(way_raddr_ram),
        .rdata_o(tag_rdata[w])
      );

      // 4 x 128-bit Data Banks per way (each bank uses 2 RAMB36E1s, WE_WIDTH=16 -> fanout <= 16!)
      wire [CACHE_LINE_BITS-1:0] data_rdata_line;
      wire [63:0]                way_wr_wdata64;
      (* dont_touch = "true" *) wire way_swen = sbuf_push && elo_ctrl0[w] && ehi_ctrl5[w];
      for (gb = 0; gb < 4; gb = gb + 1) begin : gen_dbank
        (* dont_touch = "true" *) reg        bank_vic_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        (* dont_touch = "true" *) reg        bank_swen_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        (* dont_touch = "true" *) reg [7:0]  bank_wr_wd_lo_q;/* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        (* dont_touch = "true" *) reg [7:0]  bank_wr_wd_hi_q;/* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        (* dont_touch = "true" *) reg [15:0] bank_ref_sel_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        (* dont_touch = "true" *) reg [15:0] bank_wstrb_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

        localparam [2:0] DW_LO = gb * 2;
        localparam [2:0] DW_HI = gb * 2 + 1;

        wire [7:0] bank_be_in = (gb < 2) ? way_s2_be01_q : way_s2_be23_q;

        (* dont_touch = "true" *) wire b_idle_lo   = (way_state0_q == S_IDLE);
        (* dont_touch = "true" *) wire b_idle_hi   = (way_state1_q == S_IDLE);
        (* dont_touch = "true" *) wire b_ref_lo    = (way_state0_q != S_IDLE);
        (* dont_touch = "true" *) wire b_ref_hi    = (way_state1_q != S_IDLE);
        (* dont_touch = "true" *) wire match_dw_lo = (way_s2_dw_q == DW_LO) && b_idle_lo;
        (* dont_touch = "true" *) wire match_dw_hi = (way_s2_dw_q == DW_HI) && b_idle_hi;

        wire [7:0] strb_lo_s2 = match_dw_lo ? bank_be_in : 8'd0;
        wire [7:0] strb_hi_s2 = match_dw_hi ? bank_be_in : 8'd0;

        always @(posedge clk_i or posedge rst_async_p) begin
          if (rst_async_p) begin
            bank_vic_q      <= 1'b0;
            bank_swen_q     <= 1'b0;
            bank_wr_wd_lo_q <= 8'd0;
            bank_wr_wd_hi_q <= 8'd0;
            bank_ref_sel_q  <= 16'd0;
            bank_wstrb_q    <= 16'd0;
          end else begin
            bank_vic_q           <= (victim_ptr_q == w[WAY_BITS-1:0]);
            bank_swen_q          <= way_swen;
            bank_wr_wd_lo_q      <= req_wdata_q[gb*16 +: 8];
            bank_wr_wd_hi_q      <= req_wdata_q[gb*16 + 8 +: 8];
            bank_ref_sel_q[7:0]  <= {8{b_ref_lo}};
            bank_ref_sel_q[15:8] <= {8{b_ref_hi}};
            bank_wstrb_q[7:0]    <= b_idle_lo ? strb_lo_s2 : 8'hFF;
            bank_wstrb_q[15:8]   <= b_idle_hi ? strb_hi_s2 : 8'hFF;
          end
        end

        assign way_wr_wdata64[gb*16 +: 16] = {bank_wr_wd_hi_q, bank_wr_wd_lo_q};

        (* dont_touch = "true" *) wire bank_wen = (way_ref_en && bank_vic_q) || bank_swen_q;

        // 16-bit bank_ref_sel_q: 1 bit per byte -> each bit drives 8 LUT3s (fanout == 9 <= 16!)
        wire [127:0] bank_store_wdata = {2{way_wr_wdata64}};
        wire [127:0] bank_wdata;
        genvar bb;
        for (bb = 0; bb < 16; bb = bb + 1) begin : gen_bwmux
          assign bank_wdata[bb*8 +: 8] =
            bank_ref_sel_q[bb] ? l2_rline_data_i[(gb*16 + bb)*8 +: 8] : bank_store_wdata[bb*8 +: 8];
        end

        sk_ram_bram #(
          .DATA_WIDTH     (128),
          .ADDR_WIDTH     (INDEX_BITS),
          .DEPTH          (SETS),
          .PIPELINE_STAGES(1),
          .BYTE_WRITE_EN  (1),
          .WE_WIDTH       (16),
          .COLLISION_FWD  (0)
        ) u_ddata_bank (
          .clk_i  (clk_i),
          .rst_ni (rst_ni),
          .wen_i  (bank_wen),
          .wstrb_i(bank_wstrb_q),
          .waddr_i(way_waddr_q),
          .wdata_i(bank_wdata),
          .ren_i  (1'b1),
          .raddr_i(way_raddr_ram),
          .rdata_o(data_rdata_line[gb*128 +: 128])
        );
      end

      // Per-way 8:1 Doubleword Mux split into 9 slices of <= 7 bits (select fanout <= 15)
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

      // Pure LUT6 28-bit Tag Comparator: separate control (tag_grp_eq_c) vs data replicas (tag_grp_eq_d0..3)
      // Distinct flip-flop inputs req_tag_rep1..3_q guarantee 0 LUT1 buffers and fanout == 4 per LUT6!
      wire [9:0] tag_grp_eq_c;
      wire [8:0] tag_grp_eq_d0;
      wire [8:0] tag_grp_eq_d1;
      wire [8:0] tag_grp_eq_d2;
      wire [8:0] tag_grp_eq_d3;
      for (tg = 0; tg < 9; tg = tg + 1) begin : gen_tag_cmp
        (* dont_touch = "true" *) wire geq_c =
          (tag_rdata[w][tg*3 +: 3] == req_tag_s2[tg*3 +: 3]);
        (* dont_touch = "true" *) wire geq_d0 =
          (tag_rdata[w][tg*3 +: 3] == req_tag_d_s2[tg*3 +: 3]);
        (* dont_touch = "true" *) wire geq_d1 =
          (tag_rdata[w][tg*3 +: 3] == {req_tag_d_s2[tg*3+1 +: 2], req_tag_rep1_q[tg]});
        (* dont_touch = "true" *) wire geq_d2 =
          (tag_rdata[w][tg*3 +: 3] == {req_tag_d_s2[tg*3+1 +: 2], req_tag_rep2_q[tg]});
        (* dont_touch = "true" *) wire geq_d3 =
          (tag_rdata[w][tg*3 +: 3] == {req_tag_d_s2[tg*3+1 +: 2], req_tag_rep3_q[tg]});
        assign tag_grp_eq_c[tg]  = geq_c;
        assign tag_grp_eq_d0[tg] = geq_d0;
        assign tag_grp_eq_d1[tg] = geq_d1;
        assign tag_grp_eq_d2[tg] = geq_d2;
        assign tag_grp_eq_d3[tg] = geq_d3;
        if (w == 0 && tg >= 6) begin : gen_w0_hi_rep
          localparam integer HI_K = tg - 6;
          (* dont_touch = "true" *) wire geq_d4 =
            (tag_rdata[0][tg*3 +: 3] == {req_tag_w0_hi_q[HI_K*3+1 +: 2], req_tag_rep4_q[HI_K]});
          (* dont_touch = "true" *) wire geq_d5 =
            (tag_rdata[0][tg*3 +: 3] == {req_tag_w0_hi_q[HI_K*3+1 +: 2], req_tag_rep5_q[HI_K]});
          (* dont_touch = "true" *) wire geq_d6 =
            (tag_rdata[0][tg*3 +: 3] == {req_tag_w0_hi_q[HI_K*3+1 +: 2], req_tag_rep6_q[HI_K]});
          (* dont_touch = "true" *) wire geq_d7 =
            (tag_rdata[0][tg*3 +: 3] == {req_tag_w0_hi_q[HI_K*3+1 +: 2], req_tag_rep7_q[HI_K]});
          assign w0_hi_eq0[HI_K] = geq_d0;
          assign w0_hi_eq1[HI_K] = geq_d1;
          assign w0_hi_eq2[HI_K] = geq_d2;
          assign w0_hi_eq3[HI_K] = geq_d3;
          assign w0_hi_eq4[HI_K] = geq_d4;
          assign w0_hi_eq5[HI_K] = geq_d5;
          assign w0_hi_eq6[HI_K] = geq_d6;
          assign w0_hi_eq7[HI_K] = geq_d7;
        end
      end
      (* dont_touch = "true" *) wire geq_c_top =
        (tag_rdata[w][TAG_WIDTH-1:27] == req_tag_s2[TAG_WIDTH-1:27]) && way_vld_s2_c0_q;
      assign tag_grp_eq_c[9] = geq_c_top;

      wire req_tag_b27_way = (w == 0) ? req_tag_d_s2[27]   :
                             (w == 1) ? req_tag_rep1_q[9]  :
                             (w == 2) ? req_tag_rep2_q[9]  : req_tag_rep3_q[9];
      wire [7:0] geq_d_top;
      for (vt = 0; vt < 8; vt = vt + 1) begin : gen_top_cmp
        (* dont_touch = "true" *) wire geq_dt =
          (tag_rdata[w][27] == req_tag_b27_way) && way_vld_s2_rep_q[vt] && !refill_done_rep_q[w];
        assign geq_d_top[vt] = geq_dt;
      end

      // Level 2 from u_dtag_ram for control: 6-input LUT6s (each ehi_c0..5 drives ONLY 1 load at Level 3!)
      (* dont_touch = "true" *) wire elo_c0 = (&tag_grp_eq_c[4:0]) && way_vld_s2_c1_q;
      (* dont_touch = "true" *) wire elo_c1 = (&tag_grp_eq_c[4:0]) && way_vld_s2_c2_q;
      (* dont_touch = "true" *) wire ehi_c0 = (&tag_grp_eq_c[9:5]) && idle_demand_en_top;
      (* dont_touch = "true" *) wire ehi_c1 = (&tag_grp_eq_c[9:5]) && idle_demand_en_way;
      (* dont_touch = "true" *) wire ehi_c2 = (&tag_grp_eq_c[9:5]) && load_can_complete;
      (* dont_touch = "true" *) wire ehi_c3 = (&tag_grp_eq_c[9:5]) && load_comp_ways;
      (* dont_touch = "true" *) wire ehi_c4 = (&tag_grp_eq_c[9:5]) && load_comp_nvl;
      (* dont_touch = "true" *) wire ehi_c5 = (&tag_grp_eq_c[9:5]) && way_vld_s2_c3_q;
      assign elo_ctrl0[w] = elo_c0;
      assign elo_ctrl1[w] = elo_c1;
      assign ehi_ctrl0[w] = ehi_c0;
      assign ehi_ctrl1[w] = ehi_c1;
      assign ehi_ctrl2[w] = ehi_c2;
      assign ehi_ctrl3[w] = ehi_c3;
      assign ehi_ctrl4[w] = ehi_c4;
      assign ehi_ctrl5[w] = ehi_c5;

      // Level 2 from u_dtag_ram for read data: strictly 4-input LUT4s (NO slow I0/I1 pins, 0 LUT1 buffers, fanout == 4!)
      for (gc = 0; gc < 16; gc = gc + 1) begin : gen_cmp_rep
        wire [8:0] td_sel = (gc < 4)  ? tag_grp_eq_d0 :
                            (gc < 8)  ? tag_grp_eq_d1 :
                            (gc < 12) ? tag_grp_eq_d2 : tag_grp_eq_d3;
        (* dont_touch = "true" *) wire e0_b = (&td_sel[2:0]) && way_vld_s2_rep_q[gc % 8];
        (* dont_touch = "true" *) wire e1_b = (&td_sel[5:3]) && geq_d_top[gc % 8];
        (* dont_touch = "true" *) wire e2_b = (&td_sel[8:6]) && way_vld_s2_rep_q[gc % 8];
        assign e0_bus[w][gc] = e0_b;
        assign e1_bus[w][gc] = e1_b;
        assign e2_bus[w][gc] = e2_b;
      end
    end
  endgenerate

  // --------------------------------------------------------------------------
  // Stage 2 Read Data Selection & Completion Handshake (<= 4 LUT levels total)
  // --------------------------------------------------------------------------
  wire [63:0] hit_rdata64;
  genvar gi;
  generate
    for (gi = 0; gi < 64; gi = gi + 1) begin : gen_hit_rdata
      localparam integer GC = gi / 4;
      wire [2:0] td0_hi = (gi < 8)  ? w0_hi_eq0 :
                          (gi < 16) ? w0_hi_eq1 :
                          (gi < 24) ? w0_hi_eq2 :
                          (gi < 32) ? w0_hi_eq3 :
                          (gi < 40) ? w0_hi_eq4 :
                          (gi < 48) ? w0_hi_eq5 :
                          (gi < 56) ? w0_hi_eq6 : w0_hi_eq7;
      // Level 2 from u_dtag_ram for Way 0 high tag bits + data: strictly 4-input LUT4 (fanout == 1!)
      (* dont_touch = "true" *) wire e2_d0 = (&td0_hi) && way_dword[0][gi];
      // Level 3 from u_dtag_ram: strictly 4-input LUT4s across all 4 ways!
      (* dont_touch = "true" *) wire w0_bit =
        (e0_bus[0][GC] && e1_bus[0][GC] && e2_d0) || refill_rdata64_q[gi];
      (* dont_touch = "true" *) wire w1_bit =
        e0_bus[1][GC] && e1_bus[1][GC] && e2_bus[1][GC] && way_dword[1][gi];
      (* dont_touch = "true" *) wire w2_bit =
        e0_bus[2][GC] && e1_bus[2][GC] && e2_bus[2][GC] && way_dword[2][gi];
      (* dont_touch = "true" *) wire w3_bit =
        e0_bus[3][GC] && e1_bus[3][GC] && e2_bus[3][GC] && way_dword[3][gi];
      // Level 4 from u_dtag_ram: strictly 4-input LUT4 (NO slow I0/I1 pins!)
      (* dont_touch = "true" *) wire hit_bit =
        w0_bit || w1_bit || w2_bit || w3_bit;
      assign hit_rdata64[gi] = hit_bit;
    end
  endgenerate

  // Refill target doubleword 8:1 mux split into 9 slices of <= 7 bits (fanout <= 15)
  wire [63:0] refill_rdata_mux;
  genvar rs;
  generate
    for (rs = 0; rs < 9; rs = rs + 1) begin : gen_ref_mux
      localparam integer R_LO = rs * 7;
      localparam integer R_W  = (rs == 8) ? 8 : 7;
      wire [2:0] r_sel = (rs == 0) ? refill_dw_sel0_q :
                         (rs == 1) ? refill_dw_sel1_q :
                         (rs == 2) ? refill_dw_sel2_q :
                         (rs == 3) ? refill_dw_sel3_q :
                         (rs == 4) ? refill_dw_sel4_q :
                         (rs == 5) ? refill_dw_sel5_q :
                         (rs == 6) ? refill_dw_sel6_q :
                         (rs == 7) ? refill_dw_sel7_q : refill_dw_sel8_q;
      assign refill_rdata_mux[R_LO +: R_W] = l2_rline_data_i[r_sel*64 + R_LO +: R_W];
    end
  endgenerate

  wire atomic_ready    = sbuf_empty && !wr_pipe_busy_q && (!req_is_amo_rw || amo_lock_grant_q);
  (* dont_touch = "true" *) wire load_comp_top_c = (state_q      == S_IDLE) && req_valid_q  && !req_write_q && (!req_is_atomic || atomic_ready);
  (* dont_touch = "true" *) wire load_comp_way_c = (state_rep0_q == S_IDLE) && req_vld_r0_q && !req_write_q && (!req_is_atomic || atomic_ready);
  (* dont_touch = "true" *) wire load_comp_nvl_c = (state_rep1_q == S_IDLE) && req_vld_r1_q && !req_write_q && (!req_is_atomic || atomic_ready);
  assign load_can_complete = load_comp_top_c;
  assign load_comp_ways    = load_comp_way_c;
  assign load_comp_nvl     = load_comp_nvl_c;

  wire idle_store_done = sbuf_push && !req_is_atomic;
  wire amo_drain_done  = (state_q == S_AMO_DRAIN) && sbuf_empty && !wr_pipe_busy_q;
  (* dont_touch = "true" *) wire other_resp_done = idle_store_done || refill_done_q || amo_drain_done;
  (* dont_touch = "true" *) wire other_resp_ways = (sbuf_push_a && !req_is_atomic) || refill_done_q || amo_drain_done;
  (* dont_touch = "true" *) wire other_resp_nvl  = (sbuf_push_b && !req_is_atomic) || refill_done_q || amo_drain_done;

  // Level 3 from u_dtag_ram: strictly 4-input LUT4s!
  (* dont_touch = "true" *) wire lhit_p01_top =
    (elo_ctrl0[0] && ehi_ctrl2[0]) || (elo_ctrl0[1] && ehi_ctrl2[1]);
  (* dont_touch = "true" *) wire lhit_p23_top =
    (elo_ctrl0[2] && ehi_ctrl2[2]) || (elo_ctrl0[3] && ehi_ctrl2[3]);

  (* dont_touch = "true" *) wire lhit_p01_w_c =
    (elo_ctrl1[0] && ehi_ctrl3[0]) || (elo_ctrl1[1] && ehi_ctrl3[1]);
  (* dont_touch = "true" *) wire lhit_p23_w_c =
    (elo_ctrl1[2] && ehi_ctrl3[2]) || (elo_ctrl1[3] && ehi_ctrl3[3]);

  (* dont_touch = "true" *) wire lhit_p01_nvl =
    (elo_ctrl1[0] && ehi_ctrl4[0]) || (elo_ctrl1[1] && ehi_ctrl4[1]);
  (* dont_touch = "true" *) wire lhit_p23_nvl =
    (elo_ctrl1[2] && ehi_ctrl4[2]) || (elo_ctrl1[3] && ehi_ctrl4[3]);

  (* dont_touch = "true" *) wire hit_p01_sm =
    (elo_ctrl1[0] && ehi_ctrl5[0]) || (elo_ctrl1[1] && ehi_ctrl5[1]);
  (* dont_touch = "true" *) wire hit_p23_sm =
    (elo_ctrl1[2] && ehi_ctrl5[2]) || (elo_ctrl1[3] && ehi_ctrl5[3]);

  // Level 4 from u_dtag_ram: strictly 3-input LUT3s with dont_touch!
  (* dont_touch = "true" *) wire stall_base        = req_valid_q  && !other_resp_done;
  (* dont_touch = "true" *) wire vld_base_top      = req_valid_q  ? !other_resp_done : accept_req;
  (* dont_touch = "true" *) wire vld_base_ways     = req_vld_r0_q ? !other_resp_ways : accept_req_w;
  (* dont_touch = "true" *) wire nvl_base_top      = req_nvl0_q   ? !accept_req_n    : other_resp_nvl;
  (* dont_touch = "true" *) wire next_req_vld_top  = vld_base_top  && !lhit_p01_top && !lhit_p23_top;
  (* dont_touch = "true" *) wire next_req_vld_w_c  = vld_base_ways && !lhit_p01_w_c && !lhit_p23_w_c;
  (* dont_touch = "true" *) wire next_req_nvl      = nvl_base_top  ||  lhit_p01_nvl ||  lhit_p23_nvl;
  (* dont_touch = "true" *) wire next_store_miss   = sbuf_push     && !hit_p01_sm   && !hit_p23_sm;
  assign next_req_vld_ways = next_req_vld_w_c;

  assign amo_lock_req_o   = amo_lock_q;
  assign mem_resp_valid_o = other_resp_done || lhit_p01_top || lhit_p23_top;
  assign mem_rdata_o      = hit_rdata64;
  assign mem_miss_stall_o = stall_base && !lhit_p01_top && !lhit_p23_top;

  (* dont_touch = "true" *) wire amo_lock_idle = (state_q == S_IDLE) && !req_valid_q;
  (* dont_touch = "true" *) wire amo_lock_s1   = req_is_amo_rw_s1 || req_is_sc_s1;
  (* dont_touch = "true" *) wire amo_lock_clr  = amo_drain_done || (amo_lock_idle && !amo_rw_pend_q && !is_sc_pipe_q);
  (* dont_touch = "true" *) wire amo_lock_next =
    (amo_lock_idle && ((mem_req_valid_i && amo_lock_s1) || is_sc_pipe_q)) ? 1'b1 :
    (amo_lock_clr  && !mem_req_valid_i)                                   ? 1'b0 : amo_lock_q;

  // --------------------------------------------------------------------------
  // Stage 2 Request & Store-Miss MSHR Capture Sequential Logic
  // Stage 1 -> Stage 2 datapath registers use registered !req_valid_q (req_nvl0..8_q)
  // as CE -> 0 LUTs on CE and <= 14 FFs per replica!
  // --------------------------------------------------------------------------
  always @(posedge clk_i or posedge rst_async_p) begin
    if (rst_async_p) begin
      req_valid_q      <= 1'b0;
      req_vld_r0_q     <= 1'b0;
      req_vld_r1_q     <= 1'b0;
      req_vld_r2_q     <= 1'b0;
      req_vld_r3_q     <= 1'b0;
      req_nvl0_q       <= 1'b1;
      req_nvl1_q       <= 1'b1;
      req_nvl2_q       <= 1'b1;
      req_nvl3_q       <= 1'b1;
      req_nvl4_q       <= 1'b1;
      req_nvl5_q       <= 1'b1;
      req_nvl6_q       <= 1'b1;
      req_nvl7_q       <= 1'b1;
      req_nvl8_q       <= 1'b1;
      req_nvl9_q       <= 1'b1;
      req_nvl10_q      <= 1'b1;
      req_nvl11_q      <= 1'b1;
      req_nvl12_q      <= 1'b1;
      req_nvl13_q      <= 1'b1;
      req_nvl14_q      <= 1'b1;
      req_nvl15_q      <= 1'b1;
      req_write_q      <= 1'b0;
      req_op_q         <= 4'd0;
      req_byte_en_q    <= 8'd0;
      req_paddr_s0_q   <= 12'd0;
      req_paddr_s1_q   <= 12'd0;
      req_paddr_s2_q   <= 14'd0;
      req_tag_d0_q     <= 14'd0;
      req_tag_d1_q     <= 14'd0;
      req_tag_rep1_q   <= 10'd0;
      req_tag_rep2_q   <= 10'd0;
      req_tag_rep3_q   <= 10'd0;
      req_tag_w0_hi_q  <= 9'd0;
      req_tag_rep4_q   <= 3'd0;
      req_tag_rep5_q   <= 3'd0;
      req_tag_rep6_q   <= 3'd0;
      req_tag_rep7_q   <= 3'd0;
      req_wdata_s0_q   <= 13'd0;
      req_wdata_s1_q   <= 13'd0;
      req_wdata_s2_q   <= 13'd0;
      req_wdata_s3_q   <= 13'd0;
      req_wdata_s4_q   <= 12'd0;
      amo_lock_q       <= 1'b0;
      amo_rw_pend_q    <= 1'b0;
      store_miss_q     <= 1'b0;
      wr_pipe_busy_q   <= 1'b0;
      store_line_s0_q  <= 12'd0;
      store_line_s1_q  <= 12'd0;
      store_line_s2_q  <= 10'd0;
      refill_dw_sel0_q <= 3'd0;
      refill_dw_sel1_q <= 3'd0;
      refill_dw_sel2_q <= 3'd0;
      refill_dw_sel3_q <= 3'd0;
      refill_dw_sel4_q <= 3'd0;
      refill_dw_sel5_q <= 3'd0;
      refill_dw_sel6_q <= 3'd0;
      refill_dw_sel7_q <= 3'd0;
      refill_dw_sel8_q <= 3'd0;
    end else begin
      req_valid_q      <= next_req_vld_top;
      req_vld_r0_q     <= next_req_vld_top;
      req_vld_r1_q     <= next_req_vld_top;
      req_vld_r2_q     <= next_req_vld_top;
      req_vld_r3_q     <= next_req_vld_top;
      req_nvl0_q       <= next_req_nvl;
      req_nvl1_q       <= next_req_nvl;
      req_nvl2_q       <= next_req_nvl;
      req_nvl3_q       <= next_req_nvl;
      req_nvl4_q       <= next_req_nvl;
      req_nvl5_q       <= next_req_nvl;
      req_nvl6_q       <= next_req_nvl;
      req_nvl7_q       <= next_req_nvl;
      req_nvl8_q       <= next_req_nvl;
      req_nvl9_q       <= next_req_nvl;
      req_nvl10_q      <= next_req_nvl;
      req_nvl11_q      <= next_req_nvl;
      req_nvl12_q      <= next_req_nvl;
      req_nvl13_q      <= next_req_nvl;
      req_nvl14_q      <= next_req_nvl;
      req_nvl15_q      <= next_req_nvl;
      store_miss_q     <= next_store_miss;
      wr_pipe_busy_q   <= sbuf_push;

      // Unconditional capture of store_line and refill_dw_sel from Stage 2 req_paddr_w_q (0 CE fanout!)
      store_line_s0_q  <= req_paddr_w_q[17:6];
      store_line_s1_q  <= req_paddr_w_q[29:18];
      store_line_s2_q  <= req_paddr_w_q[39:30];
      refill_dw_sel0_q <= req_paddr_s0_q[3:1];
      refill_dw_sel1_q <= req_paddr_s0_q[3:1];
      refill_dw_sel2_q <= req_paddr_s0_q[3:1];
      refill_dw_sel3_q <= req_paddr_s0_q[3:1];
      refill_dw_sel4_q <= req_paddr_s0_q[3:1];
      refill_dw_sel5_q <= req_paddr_s0_q[3:1];
      refill_dw_sel6_q <= req_paddr_s0_q[3:1];
      refill_dw_sel7_q <= req_paddr_s0_q[3:1];
      refill_dw_sel8_q <= req_paddr_s0_q[3:1];

      if (accept_req && req_is_amo_rw_s1) begin
        amo_rw_pend_q <= 1'b1;
      end else if (amo_drain_done) begin
        amo_rw_pend_q <= 1'b0;
      end

      amo_lock_q <= amo_lock_next;

      if (req_nvl0_q) begin
        req_paddr_s0_q <= mem_paddr_w_i[13:2];
      end
      if (req_nvl1_q) begin
        req_paddr_s1_q <= mem_paddr_w_i[25:14];
      end
      if (req_nvl2_q) begin
        req_paddr_s2_q <= mem_paddr_w_i[39:26];
      end
      if (req_nvl3_q) begin
        req_write_q    <= mem_req_write_i;
        req_op_q       <= mem_req_op_i;
        req_byte_en_q  <= mem_byte_en_i;
      end
      if (req_nvl4_q) begin
        req_wdata_s0_q <= mem_wdata_i[12:0];
      end
      if (req_nvl5_q) begin
        req_wdata_s1_q <= mem_wdata_i[25:13];
      end
      if (req_nvl6_q) begin
        req_wdata_s2_q <= mem_wdata_i[38:26];
      end
      if (req_nvl7_q) begin
        req_wdata_s3_q <= mem_wdata_i[51:39];
      end
      if (req_nvl8_q) begin
        req_wdata_s4_q <= mem_wdata_i[63:52];
      end
      if (req_nvl9_q) begin
        req_tag_d0_q   <= mem_paddr_w_i[25:12];
      end
      if (req_nvl10_q) begin
        req_tag_d1_q   <= mem_paddr_w_i[39:26];
      end
      if (req_nvl11_q) begin
        req_tag_rep1_q <= req_tag_b0_in;
      end
      if (req_nvl12_q) begin
        req_tag_rep2_q <= req_tag_b0_in;
      end
      if (req_nvl13_q) begin
        req_tag_rep3_q <= req_tag_b0_in;
      end
      if (req_nvl14_q) begin
        req_tag_w0_hi_q <= mem_paddr_w_i[38:30];
        req_tag_rep4_q  <= req_tag_hi3_in;
      end
      if (req_nvl15_q) begin
        req_tag_rep5_q  <= req_tag_hi3_in;
        req_tag_rep6_q  <= req_tag_hi3_in;
        req_tag_rep7_q  <= req_tag_hi3_in;
      end
    end
  end

  // --------------------------------------------------------------------------
  // MSHR & Refill / Atomic Drain State Machine (Strictly <= 4 LUT levels from u_dtag_ram)
  // --------------------------------------------------------------------------
  (* dont_touch = "true" *) wire mshr_rdy_base =
    (state_q == S_IDLE) && mshr_valid_q && !store_miss_q && sbuf_empty &&
    !wr_pipe_busy_q && !req_valid_q && !mshr_snoop_cancel;
  wire demand_can_ref_top = (state_q      == S_IDLE) && req_valid_q  && !req_write_q && atomic_ready;
  wire demand_can_ref_way = (state_rep0_q == S_IDLE) && req_vld_r0_q && !req_write_q && atomic_ready;
  wire refill_snoop_hit   = refill_snoop_inv_q || (snoop_valid_q && (snoop_index_q == refill_index));

  (* dont_touch = "true" *) wire idle_dem_top_c = !(sbuf_push   && req_is_atomic) && demand_can_ref_top;
  (* dont_touch = "true" *) wire idle_dem_way_c = !(sbuf_push_a && req_is_atomic) && demand_can_ref_way;
  assign idle_demand_en_top = idle_dem_top_c;
  assign idle_demand_en_way = idle_dem_way_c;

  (* dont_touch = "true" *) wire non_idle_b0_c  =
    ((state_q == S_REFILL_REQ) && !l2_req_ready_i) ||
    ((state_q == S_REFILL_WAIT) && l2_resp_valid_i && !refill_is_mshr_q);

  (* dont_touch = "true" *) wire any_b0_top  = (mshr_rdy_base && !mem_req_valid_i) || non_idle_b0_c || idle_demand_en_top;
  (* dont_touch = "true" *) wire any_b0_ways = (mshr_rdy_base && !mem_req_valid_i) || non_idle_b0_c || idle_demand_en_way;

  (* dont_touch = "true" *) wire next_ref_done_top =
    (state_q      == S_REFILL_WAIT) && l2_resp_valid_i && !refill_is_mshr_q && !refill_snoop_hit;
  (* dont_touch = "true" *) wire next_ref_done_r0 =
    (state_rep0_q == S_REFILL_WAIT) && l2_resp_valid_i && !refill_is_mshr_q && !refill_snoop_hit;
  (* dont_touch = "true" *) wire next_ref_done_r1 =
    (state_rep1_q == S_REFILL_WAIT) && l2_resp_valid_i && !refill_is_mshr_q && !refill_snoop_hit;
  (* dont_touch = "true" *) wire next_ref_done_r2 =
    (state_rep2_q == S_REFILL_WAIT) && l2_resp_valid_i && !refill_is_mshr_q && !refill_snoop_hit;
  (* dont_touch = "true" *) wire next_ref_done_r3 =
    (state_rep3_q == S_REFILL_WAIT) && l2_resp_valid_i && !refill_is_mshr_q && !refill_snoop_hit;
  (* dont_touch = "true" *) wire next_ref_done_r4 =
    (state_rep4_q == S_REFILL_WAIT) && l2_resp_valid_i && !refill_is_mshr_q && !refill_snoop_hit;

  // Level 3 from u_dtag_ram for state bit 0: strictly 4-input LUT4s!
  (* dont_touch = "true" *) wire dhit_p01_top =
    (elo_ctrl0[0] && ehi_ctrl0[0]) || (elo_ctrl0[1] && ehi_ctrl0[1]);
  (* dont_touch = "true" *) wire dhit_p23_top =
    (elo_ctrl0[2] && ehi_ctrl0[2]) || (elo_ctrl0[3] && ehi_ctrl0[3]);

  (* dont_touch = "true" *) wire dhit_p01_way =
    (elo_ctrl0[0] && ehi_ctrl1[0]) || (elo_ctrl0[1] && ehi_ctrl1[1]);
  (* dont_touch = "true" *) wire dhit_p23_way =
    (elo_ctrl0[2] && ehi_ctrl1[2]) || (elo_ctrl0[3] && ehi_ctrl1[3]);

  // Level 4 from u_dtag_ram for state bit 0: strictly 3-input LUT3s with dont_touch!
  (* dont_touch = "true" *) wire state_d_b0_top = any_b0_top  && !dhit_p01_top && !dhit_p23_top;
  (* dont_touch = "true" *) wire state_d_b0_w_c = any_b0_ways && !dhit_p01_way && !dhit_p23_way;
  assign state_d_b0_ways = state_d_b0_w_c;

  (* dont_touch = "true" *) wire state_b2_c =
    ((state_q == S_IDLE) && sbuf_push && req_is_atomic) ||
    ((state_q == S_AMO_DRAIN) && !(sbuf_empty && !wr_pipe_busy_q));
  (* dont_touch = "true" *) wire state_b1_c =
    ((state_q == S_REFILL_REQ) && l2_req_ready_i) ||
    ((state_q == S_REFILL_WAIT) && (!l2_resp_valid_i || (!refill_is_mshr_q && !refill_snoop_hit)));
  assign state_d_b2 = state_b2_c;
  assign state_d_b1 = state_b1_c;

  wire [WAY_BITS-1:0] victim_ptr_next =
    (victim_ptr_q == MAX_WAY_IDX[WAY_BITS-1:0]) ? {WAY_BITS{1'b0}} : (victim_ptr_q + 1'b1);

  (* dont_touch = "true" *) wire mshr_cap0 = store_miss_q && !mshr_vld_r0_q;
  (* dont_touch = "true" *) wire mshr_cap1 = store_miss_q && !mshr_vld_r1_q;
  (* dont_touch = "true" *) wire mshr_cap2 = store_miss_q && !mshr_vld_r2_q;

  wire mshr_valid_next =
    (store_miss_q && !mshr_valid_q && !(snoop_valid_q && (snoop_index_q == store_line_s0_q[INDEX_BITS-1:0]))) ? 1'b1 :
    (mshr_snoop_cancel || ((state_q == S_REFILL_REQ) && (refill_is_mshr_q || mshr_match_req_q))) ? 1'b0 : mshr_valid_q;

  always @(posedge clk_i or posedge rst_async_p) begin
    if (rst_async_p) begin
      state_q            <= S_IDLE;
      state_rep0_q       <= S_IDLE;
      state_rep1_q       <= S_IDLE;
      state_rep2_q       <= S_IDLE;
      state_rep3_q       <= S_IDLE;
      state_rep4_q       <= S_IDLE;
      victim_ptr_q       <= {WAY_BITS{1'b0}};
      refill_is_mshr_q   <= 1'b0;
      refill_snoop_inv_q <= 1'b0;
      refill_done_q      <= 1'b0;
      refill_done_rep_q  <= 8'd0;
      refill_rdata64_q   <= 64'd0;
      refill_paddr_s0_q  <= 12'd0;
      refill_paddr_s1_q  <= 12'd0;
      refill_paddr_s2_q  <= 14'd0;
      mshr_valid_q       <= 1'b0;
      mshr_vld_r0_q      <= 1'b0;
      mshr_vld_r1_q      <= 1'b0;
      mshr_vld_r2_q      <= 1'b0;
      mshr_match_req_q   <= 1'b0;
      mshr_line_s0_q     <= 12'd0;
      mshr_line_s1_q     <= 12'd0;
      mshr_line_s2_q     <= 10'd0;
    end else begin
      state_q                 <= {state_d_b2, state_d_b1, state_d_b0_top};
      state_rep0_q            <= {state_d_b2, state_d_b1, state_d_b0_top};
      state_rep1_q            <= {state_d_b2, state_d_b1, state_d_b0_top};
      state_rep2_q            <= {state_d_b2, state_d_b1, state_d_b0_top};
      state_rep3_q            <= {state_d_b2, state_d_b1, state_d_b0_top};
      state_rep4_q            <= {state_d_b2, state_d_b1, state_d_b0_top};
      refill_done_q           <= next_ref_done_top;
      refill_done_rep_q       <= {8{next_ref_done_top}};
      refill_rdata64_q[12:0]  <= next_ref_done_r0 ? refill_rdata_mux[12:0]  : 13'd0;
      refill_rdata64_q[25:13] <= next_ref_done_r1 ? refill_rdata_mux[25:13] : 13'd0;
      refill_rdata64_q[38:26] <= next_ref_done_r2 ? refill_rdata_mux[38:26] : 13'd0;
      refill_rdata64_q[51:39] <= next_ref_done_r3 ? refill_rdata_mux[51:39] : 13'd0;
      refill_rdata64_q[63:52] <= next_ref_done_r4 ? refill_rdata_mux[63:52] : 12'd0;
      mshr_match_req_q        <= mshr_eq_req_line;
      mshr_valid_q      <= mshr_valid_next;
      mshr_vld_r0_q     <= mshr_valid_next;
      mshr_vld_r1_q     <= mshr_valid_next;
      mshr_vld_r2_q     <= mshr_valid_next;

      // Update refill_paddr_s0..2_q in S_IDLE without any dependency on hit!
      if (state_rep0_q == S_IDLE) begin
        refill_paddr_s0_q <= req_vld_r1_q ? req_paddr_s0_q : {mshr_line_s0_q[7:0], 4'b0000};
      end
      if (state_rep1_q == S_IDLE) begin
        refill_paddr_s1_q <= req_vld_r2_q ? req_paddr_s1_q : {mshr_line_s1_q[7:0], mshr_line_s0_q[11:8]};
      end
      if (state_rep2_q == S_IDLE) begin
        refill_paddr_s2_q <= req_vld_r3_q ? req_paddr_s2_q : {mshr_line_s2_q, mshr_line_s1_q[11:8]};
      end

      if (mshr_cap0) begin
        mshr_line_s0_q <= store_line_s0_q;
      end
      if (mshr_cap1) begin
        mshr_line_s1_q <= store_line_s1_q;
      end
      if (mshr_cap2) begin
        mshr_line_s2_q <= store_line_s2_q;
      end

      if (state_q == S_IDLE) begin
        refill_is_mshr_q   <= !req_valid_q;
        refill_snoop_inv_q <= 1'b0;
      end else if ((state_q == S_REFILL_REQ || state_q == S_REFILL_WAIT) &&
                   snoop_valid_q && (snoop_index_q == refill_index)) begin
        refill_snoop_inv_q <= 1'b1;
      end

      if (state_q == S_REFILL_WAIT && l2_resp_valid_i) begin
        if (refill_is_mshr_q) begin
          victim_ptr_q <= victim_ptr_next;
        end else if (refill_snoop_hit) begin
          refill_snoop_inv_q <= 1'b0;
        end
      end else if (state_q == S_REFILL_DONE) begin
        victim_ptr_q <= victim_ptr_next;
      end
    end
  end

endmodule

`default_nettype wire
