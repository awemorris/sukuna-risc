// ============================================================================
// Pipeline Stage: IF2 (Instruction Fetch 2) (Verilog 2005)
// Complies with design-rule.md & style.md
// ============================================================================
// Responsibilities:
//   - Receives 64-bit instruction blocks from L1I cache (strictly 8-byte aligned)
//   - Connects L1I response directly to ID1 pipeline registers (no multi-entry queue)
//   - 1-line holding skid buffer to absorb L1I 1-cycle latency when ID1 holds Slot 1
//   - Dispatches Slot 0 (even address 8N) and Slot 1 (odd address 8N+4) to ID1
//   - When target is odd (if1_odd_i), Slot 0 is NOPed, Slot 1 is dispatched
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_stage_if2 #(
  parameter HART_ID  = 0,
  parameter XLEN     = `XLEN,
  parameter RESET_PC = 64'h0000_0000_8000_0000
)(
  input  wire             clk_i,
  input  wire             rst_ni,

  // Pipeline flow controls
  input  wire             stall_i,
  input  wire             flush_i,
  input  wire [1:0]       consume_step_i,

  // Inputs from IF1 stage
  input  wire             if1_valid_i,
  input  wire [XLEN-1:0]  if1_pc_i,
  input  wire             if1_odd_i,

  // L1I Response Interface (64-bit instruction pair)
  input  wire             l1i_resp_valid_i,
  input  wire [63:0]      l1i_inst_i,
  input  wire             l1i_miss_i,

  // Stall request to IF1 (when skid buffer is holding a line or ID is holding Slot 1)
  output wire             if2_stall_req_o,

  // Pipeline outputs to ID1 stage
  output wire             if2_valid0_o,
  output wire [XLEN-1:0]  if2_pc0_o,
  output wire [31:0]      if2_inst0_o,

  output wire             if2_valid1_o,
  output wire [XLEN-1:0]  if2_pc1_o,
  output wire [31:0]      if2_inst1_o
);

  // Main stage registers (registered L1I response)
  reg              reg_valid0_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]   reg_pc0_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [31:0]       reg_inst0_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg              reg_valid1_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]   reg_pc1_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [31:0]       reg_inst1_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // 2-entry holding skid buffer to absorb L1I 1-cycle latency and downstream stalls
  reg [63:0]       skid0_data_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]   skid0_pc_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg              skid0_odd_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg              skid0_valid_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  reg [63:0]       skid1_data_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]   skid1_pc_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg              skid1_odd_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg              skid1_valid_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  assign if2_stall_req_o = skid0_valid_q;

  wire resp_available = if1_valid_i && l1i_resp_valid_i;

  // Registered outputs to ID1 stage (0-MUX, flop-to-flop inter-module boundary)
  assign if2_valid0_o = reg_valid0_q;
  assign if2_pc0_o    = reg_pc0_q;
  assign if2_inst0_o  = reg_inst0_q;

  assign if2_valid1_o = reg_valid1_q;
  assign if2_pc1_o    = reg_pc1_q;
  assign if2_inst1_o  = reg_inst1_q;

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      reg_valid0_q  <= 1'b0;
      reg_pc0_q     <= {XLEN{1'b0}};
      reg_inst0_q   <= 32'h00000013;
      reg_valid1_q  <= 1'b0;
      reg_pc1_q     <= {XLEN{1'b0}};
      reg_inst1_q   <= 32'h00000013;

      skid0_data_q  <= 64'd0;
      skid0_pc_q    <= {XLEN{1'b0}};
      skid0_odd_q   <= 1'b0;
      skid0_valid_q <= 1'b0;

      skid1_data_q  <= 64'd0;
      skid1_pc_q    <= {XLEN{1'b0}};
      skid1_odd_q   <= 1'b0;
      skid1_valid_q <= 1'b0;
    end else if (flush_i) begin
      reg_valid0_q  <= 1'b0;
      reg_valid1_q  <= 1'b0;

      skid0_data_q  <= 64'd0;
      skid0_pc_q    <= {XLEN{1'b0}};
      skid0_odd_q   <= 1'b0;
      skid0_valid_q <= 1'b0;

      skid1_data_q  <= 64'd0;
      skid1_pc_q    <= {XLEN{1'b0}};
      skid1_odd_q   <= 1'b0;
      skid1_valid_q <= 1'b0;
    end else if (stall_i) begin
      // When downstream is stalled, capture any in-flight L1I response into skid buffers
      if (resp_available) begin
        if (!skid0_valid_q) begin
          skid0_data_q  <= l1i_inst_i;
          skid0_pc_q    <= if1_pc_i;
          skid0_odd_q   <= if1_odd_i;
          skid0_valid_q <= 1'b1;
        end else if (!skid1_valid_q) begin
          skid1_data_q  <= l1i_inst_i;
          skid1_pc_q    <= if1_pc_i;
          skid1_odd_q   <= if1_odd_i;
          skid1_valid_q <= 1'b1;
        end
      end
    end else begin
      if (consume_step_i == 2'd1) begin
        // Slot 0 was consumed in cycle 1. Present Slot 1 on Lane 0 for cycle 2.
        // Older (Slot 0) is NOPed! Younger (Slot 1) executes on Lane 0!
        reg_valid0_q <= reg_valid1_q;
        reg_pc0_q    <= reg_pc1_q;
        reg_inst0_q  <= reg_inst1_q;
        reg_valid1_q <= 1'b0;
        reg_pc1_q    <= reg_pc1_q;
        reg_inst1_q  <= 32'h00000013;

        // If an in-flight response arrives from L1I while IF2 is holding Slot 1, capture into skid buffer
        if (resp_available) begin
          if (!skid0_valid_q) begin
            skid0_data_q  <= l1i_inst_i;
            skid0_pc_q    <= if1_pc_i;
            skid0_odd_q   <= if1_odd_i;
            skid0_valid_q <= 1'b1;
          end else if (!skid1_valid_q) begin
            skid1_data_q  <= l1i_inst_i;
            skid1_pc_q    <= if1_pc_i;
            skid1_odd_q   <= if1_odd_i;
            skid1_valid_q <= 1'b1;
          end
        end
      end else begin
        // Block completed (consume_step == 2 or 0)
        if (skid0_valid_q) begin
          // Drain skid0 buffer to main output registers
          if (skid0_odd_q) begin
            // Odd target: Slot 0 was before target; Slot 1 is the single target instruction
            reg_valid0_q <= 1'b1;
            reg_pc0_q    <= {skid0_pc_q[XLEN-1:3], 3'b100};
            reg_inst0_q  <= skid0_data_q[63:32];
            reg_valid1_q <= 1'b0;
            reg_pc1_q    <= {skid0_pc_q[XLEN-1:3], 3'b100};
            reg_inst1_q  <= 32'h00000013;
          end else begin
            reg_valid0_q <= 1'b1;
            reg_pc0_q    <= skid0_pc_q;
            reg_inst0_q  <= skid0_data_q[31:0];
            reg_valid1_q <= 1'b1;
            reg_pc1_q    <= {skid0_pc_q[XLEN-1:3], 3'b100};
            reg_inst1_q  <= skid0_data_q[63:32];
          end

          // Advance skid1 into skid0
          if (skid1_valid_q) begin
            skid0_data_q  <= skid1_data_q;
            skid0_pc_q    <= skid1_pc_q;
            skid0_odd_q   <= skid1_odd_q;
            skid0_valid_q <= 1'b1;
            if (resp_available) begin
              skid1_data_q  <= l1i_inst_i;
              skid1_pc_q    <= if1_pc_i;
              skid1_odd_q   <= if1_odd_i;
              skid1_valid_q <= 1'b1;
            end else begin
              skid1_valid_q <= 1'b0;
            end
          end else begin
            // skid1 is empty
            if (resp_available) begin
              skid0_data_q  <= l1i_inst_i;
              skid0_pc_q    <= if1_pc_i;
              skid0_odd_q   <= if1_odd_i;
              skid0_valid_q <= 1'b1;
            end else begin
              skid0_valid_q <= 1'b0;
            end
          end
        end else if (resp_available) begin
          if (if1_odd_i) begin
            // Odd target: Slot 0 was before target; Slot 1 is the single target instruction
            reg_valid0_q <= 1'b1;
            reg_pc0_q    <= {if1_pc_i[XLEN-1:3], 3'b100};
            reg_inst0_q  <= l1i_inst_i[63:32];
            reg_valid1_q <= 1'b0;
            reg_pc1_q    <= {if1_pc_i[XLEN-1:3], 3'b100};
            reg_inst1_q  <= 32'h00000013;
          end else begin
            reg_valid0_q <= 1'b1;
            reg_pc0_q    <= if1_pc_i;
            reg_inst0_q  <= l1i_inst_i[31:0];
            reg_valid1_q <= 1'b1;
            reg_pc1_q    <= {if1_pc_i[XLEN-1:3], 3'b100};
            reg_inst1_q  <= l1i_inst_i[63:32];
          end
        end else begin
          reg_valid0_q <= 1'b0;
          reg_valid1_q <= 1'b0;
        end
      end
    end
  end

  wire [31:0] _unused_hart = HART_ID;
  wire _unused = &{1'b0, _unused_hart, l1i_miss_i, 1'b0};

endmodule
