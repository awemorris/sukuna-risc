// ============================================================================
// L2 Cache Arbiter / Crossbar (Verilog 2005)
// Complies with design-rule.md & style.md
// Multiplexes requests from 3x L1I, 3x L1D, and PTW to Shared L2 cache
// Word-aligned address interface (bits [1:0] omitted)
// ============================================================================

`timescale 1ns / 1ps
`default_nettype none

`include "sukuna_defines.vh"

module sukuna_l2_arbiter #(
  parameter NUM_HARTS       = `NUM_HARTS,
  parameter PADDR_WIDTH     = `PADDR_WIDTH,
  parameter CACHE_LINE_BITS = `CACHE_LINE_BITS
)(
  input  wire                                 clk_i,
  input  wire                                 rst_ni,

  // 3x L1I Refill Requests (Word-aligned: bits [1:0] omitted)
  input  wire [NUM_HARTS-1:0]                 l1i_req_valid_i,
  input  wire [NUM_HARTS*(PADDR_WIDTH-2)-1:0] l1i_line_paddr_w_i,
  output wire [NUM_HARTS-1:0]                 l1i_req_ready_o,
  output wire [NUM_HARTS-1:0]                 l1i_resp_valid_o,
  output wire [NUM_HARTS*CACHE_LINE_BITS-1:0] l1i_line_data_o,

  // 3x L1D Miss/Evict Requests (Word-aligned: bits [1:0] omitted)
  input  wire [NUM_HARTS-1:0]                 l1d_req_valid_i,
  input  wire [NUM_HARTS-1:0]                 l1d_req_write_i,
  input  wire [NUM_HARTS*(PADDR_WIDTH-2)-1:0] l1d_line_paddr_w_i,
  input  wire [NUM_HARTS*CACHE_LINE_BITS-1:0] l1d_wline_data_i,
  output wire [NUM_HARTS-1:0]                 l1d_req_ready_o,
  output wire [NUM_HARTS-1:0]                 l1d_resp_valid_o,
  output wire [NUM_HARTS*CACHE_LINE_BITS-1:0] l1d_rline_data_o,

  // Multi-Hart Atomic (AMO / SC) Serialization Lock
  input  wire [NUM_HARTS-1:0]                 amo_lock_req_i,
  output wire [NUM_HARTS-1:0]                 amo_lock_grant_o,
  input  wire                                 snoop_busy_i,

  // 1x PTW Request
  input  wire                                 ptw_req_valid_i,
  input  wire [PADDR_WIDTH-1:2]               ptw_paddr_w_i,
  output wire                                 ptw_req_ready_o,
  output wire                                 ptw_resp_valid_o,
  output wire [`XLEN-1:0]                     ptw_data_o,

  // Unified Request to Shared L2 Cache (Word-aligned: bits [1:0] omitted)
  output wire                                 l2_req_valid_o,
  output wire                                 l2_req_write_o,
  output wire [3:0]                           l2_req_source_o,
  output wire [PADDR_WIDTH-1:2]               l2_req_paddr_w_o,
  output wire [CACHE_LINE_BITS-1:0]           l2_req_wdata_o,
  input  wire                                 l2_req_ready_i,

  input  wire                                 l2_resp_valid_i,
  input  wire [3:0]                           l2_resp_source_i,
  input  wire [CACHE_LINE_BITS-1:0]           l2_resp_rdata_i
);

  // Explicit active-high reset wire with "rst" in name for clean FDCE CLR mapping
  (* keep = "true" *) wire rst_async_p = !rst_ni;

  // Upper bits [511:72] of L1D sub-line write payload are unused (constant zero)
  wire _unused_wline_hi = &{1'b0,
    l1d_wline_data_i[0*CACHE_LINE_BITS + 72 +: (CACHE_LINE_BITS - 72)],
    l1d_wline_data_i[1*CACHE_LINE_BITS + 72 +: (CACHE_LINE_BITS - 72)],
    l1d_wline_data_i[2*CACHE_LINE_BITS + 72 +: (CACHE_LINE_BITS - 72)],
    1'b0};

  // --------------------------------------------------------------------------
  // 1. Registered Response Distribution (Flop-to-Flop Boundary, Fanout <= 16)
  // --------------------------------------------------------------------------
  reg [NUM_HARTS-1:0] l1i_resp_valid_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [NUM_HARTS-1:0] l1d_resp_valid_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                 ptw_resp_valid_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  integer rh;
  always @(posedge clk_i or posedge rst_async_p) begin
    if (rst_async_p) begin
      l1i_resp_valid_q <= {NUM_HARTS{1'b0}};
      l1d_resp_valid_q <= {NUM_HARTS{1'b0}};
      ptw_resp_valid_q <= 1'b0;
    end else begin
      for (rh = 0; rh < NUM_HARTS; rh = rh + 1) begin
        l1i_resp_valid_q[rh] <= l2_resp_valid_i && (l2_resp_source_i == rh[3:0]);
        l1d_resp_valid_q[rh] <= l2_resp_valid_i && (l2_resp_source_i == (4'd3 + rh[3:0]));
      end
      ptw_resp_valid_q <= l2_resp_valid_i && (l2_resp_source_i == 4'd6);
    end
  end

  wire [CACHE_LINE_BITS-1:0] resp_rdata_buffered;
  genvar gs;
  generate
    for (gs = 0; gs < 32; gs = gs + 1) begin : gen_resp_slice
      reg [15:0] resp_slice_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      always @(posedge clk_i or posedge rst_async_p) begin
        if (rst_async_p) begin
          resp_slice_q <= 16'd0;
        end else begin
          resp_slice_q <= l2_resp_rdata_i[gs*16 +: 16];
        end
      end
      assign resp_rdata_buffered[gs*16 +: 16] = resp_slice_q;
    end
  endgenerate

  assign l1i_resp_valid_o = l1i_resp_valid_q;
  assign l1d_resp_valid_o = l1d_resp_valid_q;
  assign ptw_resp_valid_o = ptw_resp_valid_q;
  assign l1i_line_data_o  = {NUM_HARTS{resp_rdata_buffered}};
  assign l1d_rline_data_o = {NUM_HARTS{resp_rdata_buffered}};
  assign ptw_data_o       = resp_rdata_buffered[`XLEN-1:0];

  // --------------------------------------------------------------------------
  // 2. Two-Stage Arbitration & Atomic Lock Serialization (<= 3 LUT levels)
  //    Stage A (issue_req): Select winning source, assert 1-cycle *_grant_q
  //    Stage B (grant_active_q): Latch winning source's paddr/wdata using
  //                              registered win_source_q, assert l2_req_valid_q
  // --------------------------------------------------------------------------
  reg [1:0]           rr_hart_q;         /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                 lock_valid_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [1:0]           lock_hart_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [NUM_HARTS-1:0] lock_mask_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                 lock_snoop_wait_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [NUM_HARTS-1:0] amo_lock_grant_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  reg [NUM_HARTS-1:0] l1i_grant_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [NUM_HARTS-1:0] l1d_grant_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                 ptw_grant_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                 grant_active_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg grant_act_rep_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  reg                 l2_req_valid_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  (* dont_touch = "true" *) reg l2_req_vld_rep_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                 l2_req_write_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [3:0]           l2_req_source_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  wire [1:0] prio0 = rr_hart_q;
  wire [1:0] prio1 = (rr_hart_q == 2'd2) ? 2'd0 : (rr_hart_q + 2'd1);
  wire [1:0] prio2 = (rr_hart_q == 2'd0) ? 2'd2 : (rr_hart_q - 2'd1);

  wire [1:0] sel_lock_hart = amo_lock_req_i[prio0] ? prio0 :
                             amo_lock_req_i[prio1] ? prio1 : prio2;

  wire [NUM_HARTS-1:0] l1d_req_masked = l1d_req_valid_i & lock_mask_q;
  wire any_l1d_req = |l1d_req_masked;
  wire any_l1i_req = |l1i_req_valid_i;

  wire [1:0] sel_l1d_hart = l1d_req_masked[prio0] ? prio0 :
                            l1d_req_masked[prio1] ? prio1 : prio2;

  wire [1:0] sel_l1i_hart = l1i_req_valid_i[prio0] ? prio0 :
                            l1i_req_valid_i[prio1] ? prio1 : prio2;

  wire can_grant = !l2_req_valid_q && !grant_active_q;
  wire any_req   = ptw_req_valid_i || any_l1d_req || any_l1i_req;
  wire issue_req = can_grant && any_req;

  wire [2:0] next_win_src = ptw_req_valid_i ? 3'd6 :
                            any_l1d_req     ? (3'd3 + {1'b0, sel_l1d_hart}) :
                                              {1'b0, sel_l1i_hart};

  wire next_req_write = !ptw_req_valid_i && any_l1d_req && l1d_req_write_i[sel_l1d_hart];

  integer gh;
  always @(posedge clk_i or posedge rst_async_p) begin
    if (rst_async_p) begin
      rr_hart_q         <= 2'd0;
      lock_valid_q      <= 1'b0;
      lock_hart_q       <= 2'd0;
      lock_mask_q       <= 3'b111;
      lock_snoop_wait_q <= 1'b0;
      amo_lock_grant_q  <= {NUM_HARTS{1'b0}};
      l1i_grant_q       <= {NUM_HARTS{1'b0}};
      l1d_grant_q       <= {NUM_HARTS{1'b0}};
      ptw_grant_q       <= 1'b0;
      grant_active_q    <= 1'b0;
      grant_act_rep_q   <= 1'b0;
      l2_req_valid_q    <= 1'b0;
      l2_req_vld_rep_q  <= 1'b0;
      l2_req_write_q    <= 1'b0;
      l2_req_source_q   <= 4'd0;
    end else begin
      l1i_grant_q     <= {NUM_HARTS{1'b0}};
      l1d_grant_q     <= {NUM_HARTS{1'b0}};
      ptw_grant_q     <= 1'b0;
      grant_active_q  <= issue_req;
      grant_act_rep_q <= issue_req;

      if (issue_req) begin
        l2_req_write_q  <= next_req_write;
        l2_req_source_q <= {1'b0, next_win_src};
        if (ptw_req_valid_i) begin
          ptw_grant_q <= 1'b1;
        end else if (any_l1d_req) begin
          l1d_grant_q[sel_l1d_hart] <= 1'b1;
        end else begin
          l1i_grant_q[sel_l1i_hart] <= 1'b1;
        end
      end

      if (grant_active_q) begin
        l2_req_valid_q   <= 1'b1;
        l2_req_vld_rep_q <= 1'b1;
      end else if (l2_req_valid_q && l2_req_ready_i) begin
        l2_req_valid_q   <= 1'b0;
        l2_req_vld_rep_q <= 1'b0;
      end

      if (!lock_valid_q) begin
        amo_lock_grant_q <= {NUM_HARTS{1'b0}};
        if (|amo_lock_req_i) begin
          lock_valid_q      <= 1'b1;
          lock_hart_q       <= sel_lock_hart;
          lock_mask_q       <= (3'b001 << sel_lock_hart);
          lock_snoop_wait_q <= 1'b1;
        end else if (issue_req && !ptw_req_valid_i) begin
          rr_hart_q <= (rr_hart_q == 2'd2) ? 2'd0 : (rr_hart_q + 2'd1);
        end
      end else begin
        lock_snoop_wait_q <= grant_active_q && l2_req_write_q;
        for (gh = 0; gh < NUM_HARTS; gh = gh + 1) begin
          amo_lock_grant_q[gh] <= (lock_hart_q == gh[1:0]) &&
                                  !lock_snoop_wait_q && !snoop_busy_i && !grant_active_q;
        end
        if (!amo_lock_req_i[lock_hart_q] && !lock_snoop_wait_q && !snoop_busy_i && !grant_active_q) begin
          lock_valid_q     <= 1'b0;
          lock_mask_q      <= 3'b111;
          amo_lock_grant_q <= {NUM_HARTS{1'b0}};
          rr_hart_q        <= (lock_hart_q == 2'd2) ? 2'd0 : (lock_hart_q + 2'd1);
        end
      end
    end
  end

  // --------------------------------------------------------------------------
  // 3. Per-Slice Replicated Winner Select Registers & Datapath Capture
  //    (Each slice <= 10 bits -> Fanout <= 10, Logic Levels <= 2)
  // --------------------------------------------------------------------------
  reg [PADDR_WIDTH-1:2] l2_req_paddr_w_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [71:0]            l2_req_wdata72_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  genvar ga;
  generate
    for (ga = 0; ga < 5; ga = ga + 1) begin : gen_paddr_slice
      localparam integer A_LO = ga * 8;
      localparam integer A_W  = (ga == 4) ? ((PADDR_WIDTH - 2) - 32) : 8;

      (* dont_touch = "true" *) reg       sl_busy_a_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) wire      issue_a = !sl_busy_a_q && any_req;
      (* dont_touch = "true" *) reg       en_a_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [2:0] src_a_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

      wire [A_W-1:0] mux_paddr_slice =
        (src_a_q == 3'd6) ? ptw_paddr_w_i[A_LO + 2 +: A_W] :
        (src_a_q == 3'd5) ? l1d_line_paddr_w_i[2*(PADDR_WIDTH-2) + A_LO +: A_W] :
        (src_a_q == 3'd4) ? l1d_line_paddr_w_i[1*(PADDR_WIDTH-2) + A_LO +: A_W] :
        (src_a_q == 3'd3) ? l1d_line_paddr_w_i[0*(PADDR_WIDTH-2) + A_LO +: A_W] :
        (src_a_q == 3'd2) ? l1i_line_paddr_w_i[2*(PADDR_WIDTH-2) + A_LO +: A_W] :
        (src_a_q == 3'd1) ? l1i_line_paddr_w_i[1*(PADDR_WIDTH-2) + A_LO +: A_W] :
                            l1i_line_paddr_w_i[0*(PADDR_WIDTH-2) + A_LO +: A_W];

      always @(posedge clk_i or posedge rst_async_p) begin
        if (rst_async_p) begin
          sl_busy_a_q                        <= 1'b0;
          en_a_q                             <= 1'b0;
          src_a_q                            <= 3'd0;
          l2_req_paddr_w_q[A_LO + 2 +: A_W] <= {A_W{1'b0}};
        end else begin
          sl_busy_a_q <= issue_a || grant_active_q || (l2_req_valid_q && !l2_req_ready_i);
          en_a_q      <= issue_a;
          if (issue_a) begin
            src_a_q <= next_win_src;
          end
          if (en_a_q) begin
            l2_req_paddr_w_q[A_LO + 2 +: A_W] <= mux_paddr_slice;
          end
        end
      end
    end
  endgenerate

  genvar gd;
  generate
    for (gd = 0; gd < 8; gd = gd + 1) begin : gen_wdata_slice
      localparam integer D_LO = gd * 9;
      localparam integer D_W  = 9;

      (* dont_touch = "true" *) reg       sl_busy_d_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) wire      issue_d = !sl_busy_d_q && any_req;
      (* dont_touch = "true" *) reg       en_d_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      (* dont_touch = "true" *) reg [1:0] dh_d_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

      wire [D_W-1:0] mux_wdata_slice =
        (dh_d_q == 2'd2) ? l1d_wline_data_i[2*CACHE_LINE_BITS + D_LO +: D_W] :
        (dh_d_q == 2'd1) ? l1d_wline_data_i[1*CACHE_LINE_BITS + D_LO +: D_W] :
                           l1d_wline_data_i[0*CACHE_LINE_BITS + D_LO +: D_W];

      always @(posedge clk_i or posedge rst_async_p) begin
        if (rst_async_p) begin
          sl_busy_d_q                   <= 1'b0;
          en_d_q                        <= 1'b0;
          dh_d_q                        <= 2'd0;
          l2_req_wdata72_q[D_LO +: D_W] <= {D_W{1'b0}};
        end else begin
          sl_busy_d_q <= issue_d || grant_act_rep_q || (l2_req_vld_rep_q && !l2_req_ready_i);
          en_d_q      <= issue_d;
          if (issue_d) begin
            dh_d_q <= sel_l1d_hart;
          end
          if (en_d_q) begin
            l2_req_wdata72_q[D_LO +: D_W] <= mux_wdata_slice;
          end
        end
      end
    end
  endgenerate

  assign l1i_req_ready_o  = l1i_grant_q;
  assign l1d_req_ready_o  = l1d_grant_q;
  assign ptw_req_ready_o  = ptw_grant_q;
  assign amo_lock_grant_o = amo_lock_grant_q;

  // Hold l2_req_valid_o high across both grant_active_q (Stage B) and l2_req_valid_q
  // Wait: l2_req_paddr_w_q is valid starting the cycle AFTER grant_active_q, so l2_req_valid_o = l2_req_valid_q!
  assign l2_req_valid_o   = l2_req_valid_q;
  assign l2_req_write_o   = (grant_active_q || l2_req_valid_q) && l2_req_write_q;
  assign l2_req_source_o  = l2_req_source_q;
  assign l2_req_paddr_w_o = l2_req_paddr_w_q;
  assign l2_req_wdata_o   = {{(CACHE_LINE_BITS-72){1'b0}}, l2_req_wdata72_q};

endmodule

`default_nettype wire
