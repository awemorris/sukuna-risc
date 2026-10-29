// ============================================================================
// L1D Coherence / Invalidation Controller (Verilog 2005)
// Complies with design-rule.md
// Maintains memory coherence across the 3 SMT threads' L1 data caches
// Broadcasts invalidation requests when any Hart executes a store
// ============================================================================

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

  // Snoop signals to each Hart's L1D (word-aligned)
  output reg  [NUM_HARTS-1:0]                   snoop_req_valid_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [NUM_HARTS*(PADDR_WIDTH-2)-1:0]   snoop_paddr_w_o,     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [NUM_HARTS-1:0]                   snoop_invalidate_o,  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  input  wire [NUM_HARTS-1:0]                   snoop_hit_i
);

  // --------------------------------------------------------------------------
  // Multi-Hart Invalidation Broadcast Logic
  // --------------------------------------------------------------------------
  // When Hart h performs a write, broadcast snoop & invalidate to all other Harts
  integer h, j;
  reg [1:0] active_writer;
  reg       writer_valid;

  always @(*) begin
    writer_valid  = 1'b0;
    active_writer = 2'd0;
    // Priority select active store request
    for (h = 0; h < NUM_HARTS; h = h + 1) begin
      if (l1d_write_req_i[h]) begin
        writer_valid  = 1'b1;
        active_writer = h[1:0];
      end
    end
  end

  // Snoop broadcast generation (Registered 1-cycle coherence pipeline)
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      snoop_req_valid_o  <= {NUM_HARTS{1'b0}};
      snoop_invalidate_o <= {NUM_HARTS{1'b0}};
      snoop_paddr_w_o    <= {(NUM_HARTS*(PADDR_WIDTH-2)){1'b0}};
    end else begin
      snoop_req_valid_o  <= {NUM_HARTS{1'b0}};
      snoop_invalidate_o <= {NUM_HARTS{1'b0}};
      snoop_paddr_w_o    <= {(NUM_HARTS*(PADDR_WIDTH-2)){1'b0}};

      if (writer_valid) begin
        for (j = 0; j < NUM_HARTS; j = j + 1) begin
          if (j[1:0] != active_writer) begin
            snoop_req_valid_o[j]  <= 1'b1;
            snoop_invalidate_o[j] <= 1'b1;
            snoop_paddr_w_o[j*(PADDR_WIDTH-2) +: (PADDR_WIDTH-2)] <=
              l1d_write_paddr_w_i[active_writer*(PADDR_WIDTH-2) +: (PADDR_WIDTH-2)];
          end
        end
      end
    end
  end

endmodule
