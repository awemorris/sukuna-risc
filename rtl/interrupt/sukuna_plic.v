// ============================================================================
// Platform-Level Interrupt Controller (PLIC) (Verilog 2005)
// Complies with design-rule.md
// Routes 32 external interrupts to 3 Harts (M-mode & S-mode contexts)
// Compatible with RISC-V Standard PLIC memory map (0x0C00_0000)
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_plic #(
  parameter NUM_SOURCES = 32,
  parameter NUM_HARTS   = `NUM_HARTS,
  parameter XLEN        = `XLEN
)(
  input  wire                   clk_i,
  input  wire                   rst_ni,

  // External Interrupt Sources (Source 0 is reserved)
  input  wire [NUM_SOURCES-1:0] ext_irq_i,

  // MMIO Interface
  input  wire                   req_valid_i,
  input  wire                   req_write_i,
  input  wire [XLEN-1:0]        req_addr_i,
  input  wire [XLEN-1:0]        req_wdata_i,
  input  wire [(XLEN/8)-1:0]    req_wstrb_i,
  output wire                   req_ready_o,
  output reg                    resp_valid_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]        resp_rdata_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // External Interrupt Notifications per Hart (M-mode & S-mode)
  output wire [NUM_HARTS-1:0]   meip_o,
  output wire [NUM_HARTS-1:0]   seip_o
);

  localparam NUM_CONTEXTS = NUM_HARTS * 2; // Context 0..2 = M-mode, Context 3..5 = S-mode

  // --------------------------------------------------------------------------
  // PLIC Storage Registers
  // --------------------------------------------------------------------------
  reg [2:0]             priority_q [0:NUM_SOURCES-1]; // Priority per source (0..7)
  reg [NUM_SOURCES-1:0] pending_q;                    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [NUM_SOURCES-1:0] enable_q   [0:NUM_CONTEXTS-1]; // Interrupt enable per context
  reg [2:0]             threshold_q[0:NUM_CONTEXTS-1]; // Priority threshold per context

  assign req_ready_o = 1'b1;

  // --------------------------------------------------------------------------
  // Interrupt Arbitration & Notification per Context (Binary Tournament Tree)
  // --------------------------------------------------------------------------
  reg [NUM_CONTEXTS-1:0] context_irq_q;
  reg [4:0]              context_max_id_q   [0:NUM_CONTEXTS-1];
  reg [2:0]              context_max_prio_q [0:NUM_CONTEXTS-1];

  function [7:0] plic_cand_max;
    input [7:0] a; // [7:5] = prio, [4:0] = id
    input [7:0] b;
    reg [2:0] p_a, p_b;
    reg [4:0] id_a, id_b;
    begin
      p_a  = a[7:5];
      id_a = a[4:0];
      p_b  = b[7:5];
      id_b = b[4:0];
      if (p_a > p_b) begin
        plic_cand_max = a;
      end else if (p_b > p_a) begin
        plic_cand_max = b;
      end else begin
        // Equal priority: lower ID wins (RISC-V PLIC specification)
        plic_cand_max = (id_a <= id_b) ? a : b;
      end
    end
  endfunction

  wire [7:0] l0_cand [0:NUM_CONTEXTS-1][0:31];
  wire [7:0] l1_cand [0:NUM_CONTEXTS-1][0:15];
  wire [7:0] l2_cand [0:NUM_CONTEXTS-1][0:7];

  reg  [7:0] s1_cand_q [0:NUM_CONTEXTS-1][0:7];

  wire [7:0] l3_cand [0:NUM_CONTEXTS-1][0:3];
  wire [7:0] l4_cand [0:NUM_CONTEXTS-1][0:1];
  wire [7:0] l5_winner [0:NUM_CONTEXTS-1];

  genvar gc, gs;
  generate
    for (gc = 0; gc < NUM_CONTEXTS; gc = gc + 1) begin : gen_ctx_tree
      // Source 0 is reserved (always 0 priority)
      assign l0_cand[gc][0] = 8'd0;
      for (gs = 1; gs < 32; gs = gs + 1) begin : gen_l0
        wire act = pending_q[gs] && enable_q[gc][gs] && (priority_q[gs] > threshold_q[gc]);
        assign l0_cand[gc][gs] = act ? {priority_q[gs], gs[4:0]} : 8'd0;
      end

      // Level 1: 32 -> 16
      for (gs = 0; gs < 16; gs = gs + 1) begin : gen_l1
        assign l1_cand[gc][gs] = plic_cand_max(l0_cand[gc][2*gs], l0_cand[gc][2*gs+1]);
      end

      // Level 2: 16 -> 8
      for (gs = 0; gs < 8; gs = gs + 1) begin : gen_l2
        assign l2_cand[gc][gs] = plic_cand_max(l1_cand[gc][2*gs], l1_cand[gc][2*gs+1]);
      end

      // Level 3: 8 -> 4 (takes Stage 1 registered candidates)
      for (gs = 0; gs < 4; gs = gs + 1) begin : gen_l3
        assign l3_cand[gc][gs] = plic_cand_max(s1_cand_q[gc][2*gs], s1_cand_q[gc][2*gs+1]);
      end

      // Level 4: 4 -> 2
      for (gs = 0; gs < 2; gs = gs + 1) begin : gen_l4
        assign l4_cand[gc][gs] = plic_cand_max(l3_cand[gc][2*gs], l3_cand[gc][2*gs+1]);
      end

      // Level 5: 2 -> 1
      assign l5_winner[gc] = plic_cand_max(l4_cand[gc][0], l4_cand[gc][1]);
    end
  endgenerate

  integer c, cs;
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      context_irq_q <= {NUM_CONTEXTS{1'b0}};
      for (c = 0; c < NUM_CONTEXTS; c = c + 1) begin
        context_max_id_q[c]   <= 5'd0;
        context_max_prio_q[c] <= 3'd0;
        for (cs = 0; cs < 8; cs = cs + 1) begin
          s1_cand_q[c][cs] <= 8'd0;
        end
      end
    end else begin
      for (c = 0; c < NUM_CONTEXTS; c = c + 1) begin
        // Pipeline Stage 1 registers (8 candidates)
        for (cs = 0; cs < 8; cs = cs + 1) begin
          s1_cand_q[c][cs] <= l2_cand[c][cs];
        end
        // Pipeline Stage 2 registers (final winner)
        context_max_prio_q[c] <= l5_winner[c][7:5];
        context_max_id_q[c]   <= l5_winner[c][4:0];
        context_irq_q[c]      <= (l5_winner[c][7:5] > 3'd0);
      end
    end
  end

  // Assign M-mode and S-mode external interrupts
  genvar h;
  generate
    for (h = 0; h < NUM_HARTS; h = h + 1) begin : gen_ext_irqs
      assign meip_o[h] = context_irq_q[h];
      assign seip_o[h] = context_irq_q[NUM_HARTS + h];
    end
  endgenerate

  // --------------------------------------------------------------------------
  // MMIO Address Decoding (Offset from 0x0C00_0000)
  // --------------------------------------------------------------------------
  wire [23:0] offset = req_addr_i[23:0];
  wire [2:0]  ctx_idx = offset[14:12]; // Context index from 0x200000 block

  reg [63:0] rdata_comb;
  integer k;
  always @(*) begin
    rdata_comb = 64'd0;
    if (offset < 24'h001000) begin
      // Source Priorities: 0x000000 - 0x00007C
      for (k = 1; k < NUM_SOURCES; k = k + 1) begin
        if (offset[6:2] == k[4:0]) rdata_comb = {61'd0, priority_q[k]};
      end
    end else if (offset == 24'h001000) begin
      // Pending Bits
      rdata_comb = {32'd0, pending_q};
    end else if (offset >= 24'h002000 && offset < 24'h002000 + (NUM_CONTEXTS * 32)) begin
      // Context Enables: 0x002000 + 0x80 * context
      if (offset[9:7] < NUM_CONTEXTS) begin
        rdata_comb = {32'd0, enable_q[offset[9:7]]};
      end
    end else if (offset >= 24'h200000) begin
      // Threshold and Claim: 0x200000 + 0x1000 * context
      if (ctx_idx < NUM_CONTEXTS) begin
        if (offset[2]) begin
          // Claim Read (offset + 4)
          rdata_comb = {59'd0, context_max_id_q[ctx_idx]};
        end else begin
          // Threshold (offset + 0)
          rdata_comb = {61'd0, threshold_q[ctx_idx]};
        end
      end
    end
  end

  // --------------------------------------------------------------------------
  // Register Updates & External Interrupt Latching
  // --------------------------------------------------------------------------
  integer ci, si;
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pending_q    <= {NUM_SOURCES{1'b0}};
      resp_valid_o <= 1'b0;
      resp_rdata_o <= {XLEN{1'b0}};
      for (si = 0; si < NUM_SOURCES; si = si + 1) begin
        priority_q[si] <= 3'd0;
      end
      for (ci = 0; ci < NUM_CONTEXTS; ci = ci + 1) begin
        enable_q[ci]    <= {NUM_SOURCES{1'b0}};
        threshold_q[ci] <= 3'd0;
      end
    end else begin
      // Latch external interrupt lines into pending bits
      pending_q <= (pending_q | ext_irq_i) & ~{NUM_SOURCES{1'b0}};
      pending_q[0] <= 1'b0; // Source 0 is hardwired to 0

      // Response to MMIO
      resp_valid_o <= req_valid_i;
      resp_rdata_o <= rdata_comb;

      // Handle Claim (clears claimed interrupt pending bit on read)
      if (req_valid_i && !req_write_i && (offset >= 24'h200000) && offset[2]) begin
        if (ctx_idx < NUM_CONTEXTS && (context_max_id_q[ctx_idx] != 5'd0)) begin
          pending_q[context_max_id_q[ctx_idx]] <= 1'b0;
        end
      end

      // Handle MMIO Writes
      if (req_valid_i && req_write_i) begin
        if (offset < 24'h001000) begin
          // Write Source Priority
          for (si = 1; si < NUM_SOURCES; si = si + 1) begin
            if (offset[6:2] == si[4:0]) priority_q[si] <= req_wdata_i[2:0];
          end
        end else if (offset >= 24'h002000 && offset < 24'h002000 + (NUM_CONTEXTS * 32)) begin
          // Write Context Enables
          if (offset[9:7] < NUM_CONTEXTS) begin
            enable_q[offset[9:7]] <= req_wdata_i[NUM_SOURCES-1:0];
            enable_q[offset[9:7]][0] <= 1'b0;
          end
        end else if (offset >= 24'h200000) begin
          if (ctx_idx < NUM_CONTEXTS) begin
            if (offset[2]) begin
              // Complete Write: re-enables / acks completion
            end else begin
              // Threshold Write
              threshold_q[ctx_idx] <= req_wdata_i[2:0];
            end
          end
        end
      end
    end
  end

endmodule
