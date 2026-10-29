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
  // PLIC Storage Registers (instantiated via sk_ram_ff macros)
  // --------------------------------------------------------------------------
  reg [NUM_SOURCES-1:0] pending_q;                    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [NUM_CONTEXTS-1:0] context_irq_q;               /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  assign req_ready_o = 1'b1;

  wire [23:0] offset = req_addr_i[23:0];
  wire [2:0]  ctx_idx = offset[14:12];

  // Source Priority RAMs (32 sources of 3 bits)
  wire [2:0] priority_out [0:NUM_SOURCES-1];
  wire [NUM_SOURCES-1:0] priority_wen;
  genvar gpr;
  generate
    assign priority_out[0] = 3'd0;
    for (gpr = 1; gpr < NUM_SOURCES; gpr = gpr + 1) begin : gen_priority_ram
      assign priority_wen[gpr] = req_valid_i && req_write_i && (offset < 24'h001000) && (offset[6:2] == gpr[4:0]);
      sk_ram_ff #(
        .DATA_WIDTH (3),
        .ADDR_WIDTH (1),
        .DEPTH      (1),
        .ZERO_REG0  (0)
      ) u_prio_ram (
        .clk_i    (clk_i),
        .rst_ni   (rst_ni),
        .wen_i    (priority_wen[gpr]),
        .waddr_i  (1'b0),
        .wdata_i  (req_wdata_i[2:0]),
        .wen1_i   (1'b0), .waddr1_i(1'b0), .wdata1_i(3'd0),
        .wen2_i   (1'b0), .waddr2_i(1'b0), .wdata2_i(3'd0),
        .raddr_a_i(1'b0),
        .rdata_a_o(priority_out[gpr]),
        .raddr_b_i(1'b0),
        .rdata_b_o()
      );
    end
  endgenerate

  // Context Enable RAMs (6 contexts of 32 bits)
  wire [NUM_SOURCES-1:0] enable_out [0:NUM_CONTEXTS-1];
  wire [NUM_CONTEXTS-1:0] enable_wen;
  genvar gen_en;
  generate
    for (gen_en = 0; gen_en < NUM_CONTEXTS; gen_en = gen_en + 1) begin : gen_enable_ram
      assign enable_wen[gen_en] = req_valid_i && req_write_i &&
                                  (offset >= 24'h002000 && offset < 24'h002000 + (NUM_CONTEXTS * 32)) &&
                                  (offset[9:7] == gen_en[2:0]);
      sk_ram_ff #(
        .DATA_WIDTH (NUM_SOURCES),
        .ADDR_WIDTH (1),
        .DEPTH      (1),
        .ZERO_REG0  (0)
      ) u_enable_ram (
        .clk_i    (clk_i),
        .rst_ni   (rst_ni),
        .wen_i    (enable_wen[gen_en]),
        .waddr_i  (1'b0),
        .wdata_i  ({req_wdata_i[NUM_SOURCES-1:1], 1'b0}),
        .wen1_i   (1'b0), .waddr1_i(1'b0), .wdata1_i({NUM_SOURCES{1'b0}}),
        .wen2_i   (1'b0), .waddr2_i(1'b0), .wdata2_i({NUM_SOURCES{1'b0}}),
        .raddr_a_i(1'b0),
        .rdata_a_o(enable_out[gen_en]),
        .raddr_b_i(1'b0),
        .rdata_b_o()
      );
    end
  endgenerate

  // Context Threshold RAMs (6 contexts of 3 bits)
  wire [2:0] threshold_out [0:NUM_CONTEXTS-1];
  wire [NUM_CONTEXTS-1:0] threshold_wen;
  genvar gth;
  generate
    for (gth = 0; gth < NUM_CONTEXTS; gth = gth + 1) begin : gen_threshold_ram
      assign threshold_wen[gth] = req_valid_i && req_write_i && (offset >= 24'h200000) && !offset[2] && (ctx_idx == gth[2:0]);
      sk_ram_ff #(
        .DATA_WIDTH (3),
        .ADDR_WIDTH (1),
        .DEPTH      (1),
        .ZERO_REG0  (0)
      ) u_thresh_ram (
        .clk_i    (clk_i),
        .rst_ni   (rst_ni),
        .wen_i    (threshold_wen[gth]),
        .waddr_i  (1'b0),
        .wdata_i  (req_wdata_i[2:0]),
        .wen1_i   (1'b0), .waddr1_i(1'b0), .wdata1_i(3'd0),
        .wen2_i   (1'b0), .waddr2_i(1'b0), .wdata2_i(3'd0),
        .raddr_a_i(1'b0),
        .rdata_a_o(threshold_out[gth]),
        .raddr_b_i(1'b0),
        .rdata_b_o()
      );
    end
  endgenerate

  // --------------------------------------------------------------------------
  // Interrupt Arbitration & Notification per Context (Binary Tournament Tree)
  // --------------------------------------------------------------------------
  wire [4:0] context_max_id   [0:NUM_CONTEXTS-1];
  wire [2:0] context_max_prio [0:NUM_CONTEXTS-1];

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

  wire [7:0] l3_cand [0:NUM_CONTEXTS-1][0:3];
  wire [7:0] l4_cand [0:NUM_CONTEXTS-1][0:1];
  wire [7:0] l5_winner [0:NUM_CONTEXTS-1];

  genvar gc, gs;
  generate
    for (gc = 0; gc < NUM_CONTEXTS; gc = gc + 1) begin : gen_ctx_tree
      // Tournament tree pipeline registers (each <= 64 bits with directive)
      reg [63:0] s1_cand_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      reg [4:0]  ctx_max_id_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
      reg [2:0]  ctx_max_prio_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

      assign context_max_id[gc]   = ctx_max_id_q;
      assign context_max_prio[gc] = ctx_max_prio_q;

      // Source 0 is reserved (always 0 priority)
      assign l0_cand[gc][0] = 8'd0;
      for (gs = 1; gs < 32; gs = gs + 1) begin : gen_l0
        wire act = pending_q[gs] && enable_out[gc][gs] && (priority_out[gs] > threshold_out[gc]);
        assign l0_cand[gc][gs] = act ? {priority_out[gs], gs[4:0]} : 8'd0;
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
        assign l3_cand[gc][gs] = plic_cand_max(s1_cand_q[(2*gs)*8 +: 8], s1_cand_q[(2*gs+1)*8 +: 8]);
      end

      // Level 4: 4 -> 2
      for (gs = 0; gs < 2; gs = gs + 1) begin : gen_l4
        assign l4_cand[gc][gs] = plic_cand_max(l3_cand[gc][2*gs], l3_cand[gc][2*gs+1]);
      end

      // Level 5: 2 -> 1
      assign l5_winner[gc] = plic_cand_max(l4_cand[gc][0], l4_cand[gc][1]);

      always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          s1_cand_q      <= 64'd0;
          ctx_max_id_q   <= 5'd0;
          ctx_max_prio_q <= 3'd0;
        end else begin
          s1_cand_q      <= {l2_cand[gc][7], l2_cand[gc][6], l2_cand[gc][5], l2_cand[gc][4],
                             l2_cand[gc][3], l2_cand[gc][2], l2_cand[gc][1], l2_cand[gc][0]};
          ctx_max_prio_q <= l5_winner[gc][7:5];
          ctx_max_id_q   <= l5_winner[gc][4:0];
        end
      end
    end
  endgenerate

  integer c;
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      context_irq_q <= {NUM_CONTEXTS{1'b0}};
    end else begin
      for (c = 0; c < NUM_CONTEXTS; c = c + 1) begin
        context_irq_q[c] <= (l5_winner[c][7:5] > 3'd0);
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
  reg [63:0] rdata_comb;
  integer k;
  always @(*) begin
    rdata_comb = 64'd0;
    if (offset < 24'h001000) begin
      // Source Priorities: 0x000000 - 0x00007C
      for (k = 1; k < NUM_SOURCES; k = k + 1) begin
        if (offset[6:2] == k[4:0]) rdata_comb = {61'd0, priority_out[k]};
      end
    end else if (offset == 24'h001000) begin
      // Pending Bits
      rdata_comb = {32'd0, pending_q};
    end else if (offset >= 24'h002000 && offset < 24'h002000 + (NUM_CONTEXTS * 32)) begin
      // Context Enables: 0x002000 + 0x80 * context
      if (offset[9:7] < NUM_CONTEXTS) begin
        rdata_comb = {32'd0, enable_out[offset[9:7]]};
      end
    end else if (offset >= 24'h200000) begin
      // Threshold and Claim: 0x200000 + 0x1000 * context
      if (ctx_idx < NUM_CONTEXTS) begin
        if (offset[2]) begin
          // Claim Read (offset + 4)
          rdata_comb = {59'd0, context_max_id[ctx_idx]};
        end else begin
          // Threshold (offset + 0)
          rdata_comb = {61'd0, threshold_out[ctx_idx]};
        end
      end
    end
  end

  // --------------------------------------------------------------------------
  // Register Updates & External Interrupt Latching
  // --------------------------------------------------------------------------
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pending_q    <= {NUM_SOURCES{1'b0}};
      resp_valid_o <= 1'b0;
      resp_rdata_o <= {XLEN{1'b0}};
    end else begin
      // Latch external interrupt lines into pending bits
      pending_q <= (pending_q | ext_irq_i) & ~{NUM_SOURCES{1'b0}};
      pending_q[0] <= 1'b0; // Source 0 is hardwired to 0

      // Response to MMIO
      resp_valid_o <= req_valid_i;
      resp_rdata_o <= rdata_comb;

      // Handle Claim (clears claimed interrupt pending bit on read)
      if (req_valid_i && !req_write_i && (offset >= 24'h200000) && offset[2]) begin
        if (ctx_idx < NUM_CONTEXTS && (context_max_id[ctx_idx] != 5'd0)) begin
          pending_q[context_max_id[ctx_idx]] <= 1'b0;
        end
      end
    end
  end

endmodule
