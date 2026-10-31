// ============================================================================
// L1D Coherence / Invalidation Controller (Verilog 2005)
// Complies with design-rule.md & style.md
// Maintains memory coherence across the 3 SMT threads' L1 data caches
// Broadcasts invalidation requests when any Hart executes a store
// ============================================================================

`timescale 1ns / 1ps
`default_nettype none

`include "sukuna_defines.vh"

module sukuna_l1d_coherence #(
  parameter NUM_HARTS   = `NUM_HARTS,
  parameter PADDR_WIDTH = `PADDR_WIDTH
)(
  input  wire                                   clk_i,
  input  wire                                   rst_ni,

  // Write notification / invalidate broadcast from each Hart's L1D (word-aligned)
  input  wire [NUM_HARTS-1:0]                   l1d_write_req_i,
  input  wire [NUM_HARTS*(PADDR_WIDTH-2)-1:0]   l1d_write_paddr_w_i,

  // Inclusive L2 Back-Invalidation on L2 Eviction
  input  wire                                   l2_back_inv_valid_i,
  input  wire [PADDR_WIDTH-1:2]                 l2_back_inv_paddr_w_i,

  // Snoop signals to each Hart's L1D (word-aligned)
  output reg  [NUM_HARTS-1:0]                   snoop_req_valid_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output wire [NUM_HARTS*(PADDR_WIDTH-2)-1:0]   snoop_paddr_w_o,
  output reg  [NUM_HARTS-1:0]                   snoop_invalidate_o,  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  input  wire [NUM_HARTS-1:0]                   snoop_hit_i
);

  wire _unused_snoop_hit = &{1'b0, snoop_hit_i, 1'b0};

  // Explicit active-high reset wire with "rst" in name for clean FDCE CLR mapping
  (* keep = "true" *) wire rst_async_p = !rst_ni;

  // --------------------------------------------------------------------------
  // Multi-Hart Invalidation & Inclusive L2 Back-Invalidation Broadcast Logic
  // --------------------------------------------------------------------------
  wire       writer_valid  = |l1d_write_req_i;
  wire [1:0] active_writer = l1d_write_req_i[2] ? 2'd2 :
                             l1d_write_req_i[1] ? 2'd1 : 2'd0;

  reg                   pending_back_inv_q;         /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [PADDR_WIDTH-1:2] pending_back_inv_paddr_w_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [PADDR_WIDTH-1:2] snoop_paddr_single_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  assign snoop_paddr_w_o = {NUM_HARTS{snoop_paddr_single_q}};

  // Tree-buffered datapath slices (4 slices of <= 10 bits each to keep fanout <= 10)
  genvar g;
  generate
    for (g = 0; g < 4; g = g + 1) begin : gen_addr_slice
      localparam integer SLICE_LO = g * 10;
      localparam integer SLICE_W  = (g == 3) ? ((PADDR_WIDTH - 2) - 30) : 10;

      (* keep = "true" *) wire w_req2_buf = l1d_write_req_i[2];
      (* keep = "true" *) wire w_req1_buf = l1d_write_req_i[1];
      (* keep = "true" *) wire w_val_buf  = |l1d_write_req_i;
      (* keep = "true" *) wire b_val_buf  = l2_back_inv_valid_i;
      (* keep = "true" *) wire pend_en    = (|l1d_write_req_i) && l2_back_inv_valid_i;
      (* keep = "true" *) wire snoop_act  = (|l1d_write_req_i) || l2_back_inv_valid_i || pending_back_inv_q;

      wire [SLICE_W-1:0] w_addr_slice =
        w_req2_buf ? l1d_write_paddr_w_i[2*(PADDR_WIDTH-2) + SLICE_LO +: SLICE_W] :
        w_req1_buf ? l1d_write_paddr_w_i[1*(PADDR_WIDTH-2) + SLICE_LO +: SLICE_W] :
                     l1d_write_paddr_w_i[0*(PADDR_WIDTH-2) + SLICE_LO +: SLICE_W];

      wire [SLICE_W-1:0] b_addr_slice =
        b_val_buf ? l2_back_inv_paddr_w_i[SLICE_LO + 2 +: SLICE_W] :
                    pending_back_inv_paddr_w_q[SLICE_LO + 2 +: SLICE_W];

      wire [SLICE_W-1:0] next_snoop_slice =
        snoop_act ? (w_val_buf ? w_addr_slice : b_addr_slice) : {SLICE_W{1'b0}};

      always @(posedge clk_i or posedge rst_async_p) begin
        if (rst_async_p) begin
          pending_back_inv_paddr_w_q[SLICE_LO + 2 +: SLICE_W] <= {SLICE_W{1'b0}};
          snoop_paddr_single_q[SLICE_LO + 2 +: SLICE_W]       <= {SLICE_W{1'b0}};
        end else begin
          snoop_paddr_single_q[SLICE_LO + 2 +: SLICE_W] <= next_snoop_slice;
          if (pend_en) begin
            pending_back_inv_paddr_w_q[SLICE_LO + 2 +: SLICE_W] <=
              l2_back_inv_paddr_w_i[SLICE_LO + 2 +: SLICE_W];
          end
        end
      end
    end
  endgenerate

  integer j;
  // Snoop broadcast control generation (Registered 1-cycle coherence pipeline)
  always @(posedge clk_i or posedge rst_async_p) begin
    if (rst_async_p) begin
      snoop_req_valid_o  <= {NUM_HARTS{1'b0}};
      snoop_invalidate_o <= {NUM_HARTS{1'b0}};
      pending_back_inv_q <= 1'b0;
    end else begin
      snoop_req_valid_o  <= {NUM_HARTS{1'b0}};
      snoop_invalidate_o <= {NUM_HARTS{1'b0}};

      if (writer_valid) begin
        if (l2_back_inv_valid_i) begin
          pending_back_inv_q <= 1'b1;
        end
        for (j = 0; j < NUM_HARTS; j = j + 1) begin
          if (j[1:0] != active_writer) begin
            snoop_req_valid_o[j]  <= 1'b1;
            snoop_invalidate_o[j] <= 1'b1;
          end
        end
      end else if (l2_back_inv_valid_i || pending_back_inv_q) begin
        pending_back_inv_q <= 1'b0;
        snoop_req_valid_o  <= {NUM_HARTS{1'b1}};
        snoop_invalidate_o <= {NUM_HARTS{1'b1}};
      end
    end
  end

endmodule

`default_nettype wire
