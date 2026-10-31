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

  // Pre-compute flip-flop-only instruction 0 source so l1i_inst_i goes through only 1 LUT5 to reg_inst0_q/D!
  (* dont_touch = "true" *) wire        use_local_inst0 = (consume_step_i == 2'd1) || skid0_valid_q;
  (* dont_touch = "true" *) wire [31:0] local_inst0     =
    (consume_step_i == 2'd1) ? reg_inst1_q :
    (skid0_odd_q             ? skid0_data_q[63:32] : skid0_data_q[31:0]);
  wire [31:0] next_inst0 =
    use_local_inst0 ? local_inst0 : (if1_odd_i ? l1i_inst_i[63:32] : l1i_inst_i[31:0]);

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
    end else begin
      // Skid datapath updates: decoupled from l1i_resp_valid_i (0 CE/D fanout from L1I tag hit!)
      if (!skid0_valid_q || (!stall_i && (consume_step_i != 2'd1))) begin
        if (skid0_valid_q && skid1_valid_q) begin
          skid0_data_q <= skid1_data_q;
          skid0_pc_q   <= skid1_pc_q;
          skid0_odd_q  <= skid1_odd_q;
        end else begin
          skid0_data_q <= l1i_inst_i;
          skid0_pc_q   <= if1_pc_i;
          skid0_odd_q  <= if1_odd_i;
        end
      end

      if (!skid1_valid_q || (!stall_i && (consume_step_i != 2'd1))) begin
        skid1_data_q <= l1i_inst_i;
        skid1_pc_q   <= if1_pc_i;
        skid1_odd_q  <= if1_odd_i;
      end

      // Main stage datapath updates: decoupled from l1i_resp_valid_i (0 CE/D fanout from L1I tag hit!)
      if (!stall_i) begin
        reg_inst0_q <= next_inst0;
        if (consume_step_i == 2'd1) begin
          reg_pc0_q <= reg_pc1_q;
        end else if (skid0_valid_q) begin
          reg_pc0_q   <= skid0_odd_q ? {skid0_pc_q[XLEN-1:3], 3'b100} : skid0_pc_q;
          reg_pc1_q   <= {skid0_pc_q[XLEN-1:3], 3'b100};
          reg_inst1_q <= skid0_data_q[63:32];
        end else begin
          reg_pc0_q   <= if1_odd_i ? {if1_pc_i[XLEN-1:3], 3'b100} : if1_pc_i;
          reg_pc1_q   <= {if1_pc_i[XLEN-1:3], 3'b100};
          reg_inst1_q <= l1i_inst_i[63:32];
        end
      end

      // Valid control bits (only 4 single-bit flip-flops depend on resp_available / l1i_resp_valid_i!)
      if (flush_i) begin
        reg_valid0_q  <= 1'b0;
        reg_valid1_q  <= 1'b0;
        skid0_valid_q <= 1'b0;
        skid1_valid_q <= 1'b0;
      end else if (stall_i) begin
        if (resp_available) begin
          if (!skid0_valid_q) begin
            skid0_valid_q <= 1'b1;
          end else if (!skid1_valid_q) begin
            skid1_valid_q <= 1'b1;
          end
        end
      end else if (consume_step_i == 2'd1) begin
        reg_valid0_q <= reg_valid1_q;
        reg_valid1_q <= 1'b0;
        if (resp_available) begin
          if (!skid0_valid_q) begin
            skid0_valid_q <= 1'b1;
          end else if (!skid1_valid_q) begin
            skid1_valid_q <= 1'b1;
          end
        end
      end else if (skid0_valid_q) begin
        reg_valid0_q <= 1'b1;
        reg_valid1_q <= !skid0_odd_q;
        if (skid1_valid_q) begin
          skid0_valid_q <= 1'b1;
          skid1_valid_q <= resp_available;
        end else begin
          skid0_valid_q <= resp_available;
        end
      end else begin
        reg_valid0_q <= resp_available;
        reg_valid1_q <= resp_available && !if1_odd_i;
      end
    end
  end

  wire [31:0] _unused_hart = HART_ID;
  wire _unused = &{1'b0, _unused_hart, l1i_miss_i, 1'b0};

endmodule
