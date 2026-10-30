`timescale 1ns / 1ps
`default_nettype none

// ============================================================================
// Pipeline Stage: IF2 (Instruction Fetch 2 & Alignment Buffer) (Verilog 2005)
// Complies with style.md (ASIC 5nm 1.5GHz / Kintex-7 200-250MHz)
// ============================================================================
// Responsibilities:
//   - Receives 64-bit instruction fetch blocks from L1I cache (8-byte aligned)
//   - Maintains a 4-entry scalar instruction queue for RV64G (32-bit instructions)
//   - Decodes dual-issue pairing dynamically (INT + MA without RAW/WAW hazards)
//   - Emits byte-accurate instructions (Slot 0 and Slot 1) to ID1
//   - Drives prefetch requests to IF1 whenever the queue has capacity
//   - Filters out stale in-flight cache responses using an exact stale response counter
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
  input  wire [XLEN-1:0]  redirect_pc_i,
  input  wire [1:0]       consume_step_i,

  // L1I Request Interface to IF1
  output wire             fetch_req_valid_o,
  output wire [XLEN-1:0]  fetch_req_pc_o,

  // L1I Response Interface (64-bit instruction block)
  input  wire             l1i_resp_valid_i,
  input  wire [63:0]      l1i_inst_i,
  input  wire             l1i_miss_i,

  // Pipeline registers to ID1 stage
  output reg              if2_valid0_o,     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]  if2_pc0_o,        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [31:0]      if2_inst0_o,      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  output reg              if2_valid1_o,     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]  if2_pc1_o,        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [31:0]      if2_inst1_o       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
);

  // --------------------------------------------------------------------------
  // Sequential Registers (All <= 64 bits, strictly conforming to style.md)
  // --------------------------------------------------------------------------
  reg [XLEN-1:0] fetch_pc_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0] head_pc_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [31:0]     q_inst0_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [31:0]     q_inst1_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [31:0]     q_inst2_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [31:0]     q_inst3_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [2:0]      q_count_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg            target_odd_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg            waiting_first_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [1:0]      inflight_cnt_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [1:0]      stale_cnt_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // --------------------------------------------------------------------------
  // Candidate Extraction & Dual-Issue Pairing Check (INT + MA)
  // --------------------------------------------------------------------------
  wire [31:0] cand0 = (q_count_q >= 3'd1) ? q_inst0_q : 32'h00000013;
  wire [31:0] cand1 = (q_count_q >= 3'd2) ? q_inst1_q : 32'h00000013;

  wire [6:0] op0 = cand0[6:0];
  wire [6:0] op1 = cand1[6:0];

  wire is_int0 = (op0 == 7'h13 || op0 == 7'h33 || op0 == 7'h1b || op0 == 7'h3b || op0 == 7'h37 || op0 == 7'h17);
  wire is_ma1  = (op1 == 7'h03 || op1 == 7'h23);

  wire [4:0] rd0    = cand0[11:7];
  wire [4:0] rs1_1  = cand1[19:15];
  wire [4:0] rs2_1  = cand1[24:20];
  wire [4:0] rd1    = cand1[11:7];

  wire raw_hazard = (rd0 != 5'd0) && ((rs1_1 == rd0) || (rs2_1 == rd0));
  wire waw_hazard = (rd0 != 5'd0) && (rd0 == rd1);
  wire can_dual   = (q_count_q >= 3'd2) && is_int0 && is_ma1 && !raw_hazard && !waw_hazard;

  // Number of instructions consumed this cycle
  wire [1:0] consumed = (stall_i || flush_i) ? 2'd0 :
                        can_dual             ? 2'd2 :
                        (q_count_q >= 3'd1)  ? 2'd1 : 2'd0;

  // --------------------------------------------------------------------------
  // Response Filtering & Influx Decoding
  // --------------------------------------------------------------------------
  wire resp_is_stale = (stale_cnt_q > 2'd0);
  wire resp_is_valid = l1i_resp_valid_i && !resp_is_stale;

  // Prefetch Interface will be driven below based on future_inst occupancy

  wire [1:0] produced = !resp_is_valid                   ? 2'd0 :
                        (waiting_first_q && target_odd_q) ? 2'd1 : 2'd2;

  wire [31:0] in_inst0 = (waiting_first_q && target_odd_q) ? l1i_inst_i[63:32] : l1i_inst_i[31:0];
  wire [31:0] in_inst1 = l1i_inst_i[63:32];

  // --------------------------------------------------------------------------
  // Queue Shift & Appending Combinational Logic
  // --------------------------------------------------------------------------
  reg [31:0] shift_inst0, shift_inst1, shift_inst2, shift_inst3;
  always @(*) begin
    case (consumed)
      2'd0: begin
        shift_inst0 = q_inst0_q;
        shift_inst1 = q_inst1_q;
        shift_inst2 = q_inst2_q;
        shift_inst3 = q_inst3_q;
      end
      2'd1: begin
        shift_inst0 = q_inst1_q;
        shift_inst1 = q_inst2_q;
        shift_inst2 = q_inst3_q;
        shift_inst3 = 32'd0;
      end
      2'd2: begin
        shift_inst0 = q_inst2_q;
        shift_inst1 = q_inst3_q;
        shift_inst2 = 32'd0;
        shift_inst3 = 32'd0;
      end
      default: begin
        shift_inst0 = q_inst0_q;
        shift_inst1 = q_inst1_q;
        shift_inst2 = q_inst2_q;
        shift_inst3 = q_inst3_q;
      end
    endcase
  end

  wire [2:0] rem_count = q_count_q - {1'b0, consumed};

  reg [31:0] next_inst0, next_inst1, next_inst2, next_inst3;
  always @(*) begin
    next_inst0 = shift_inst0;
    next_inst1 = shift_inst1;
    next_inst2 = shift_inst2;
    next_inst3 = shift_inst3;
    if (produced == 2'd1) begin
      case (rem_count)
        3'd0: next_inst0 = in_inst0;
        3'd1: next_inst1 = in_inst0;
        3'd2: next_inst2 = in_inst0;
        3'd3: next_inst3 = in_inst0;
        default: ;
      endcase
    end else if (produced == 2'd2) begin
      case (rem_count)
        3'd0: begin next_inst0 = in_inst0; next_inst1 = in_inst1; end
        3'd1: begin next_inst1 = in_inst0; next_inst2 = in_inst1; end
        3'd2: begin next_inst2 = in_inst0; next_inst3 = in_inst1; end
        3'd3: begin next_inst3 = in_inst0; end
        default: ;
      endcase
    end
  end

  wire [2:0] raw_next_count = rem_count + {1'b0, produced};
  wire [2:0] next_count     = (raw_next_count > 3'd4) ? 3'd4 : raw_next_count;

  // Prefetch Interface: request when future occupancy allows 2 instructions (<= 2)
  wire [1:0] unretired_inflight = (inflight_cnt_q > {1'b0, resp_is_valid}) ?
                                 (inflight_cnt_q - {1'b0, resp_is_valid}) : 2'd0;
  wire [2:0] future_inst = next_count + {unretired_inflight, 1'b0};
  assign fetch_req_valid_o = (future_inst <= 3'd2) && !flush_i && !l1i_miss_i;
  assign fetch_req_pc_o    = {fetch_pc_q[XLEN-1:3], 3'b000};

  // --------------------------------------------------------------------------
  // Sequential Pipeline State Update
  // --------------------------------------------------------------------------
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fetch_pc_q      <= {RESET_PC[XLEN-1:3], 3'b000};
      head_pc_q       <= RESET_PC;
      q_inst0_q       <= 32'd0;
      q_inst1_q       <= 32'd0;
      q_inst2_q       <= 32'd0;
      q_inst3_q       <= 32'd0;
      q_count_q       <= 3'd0;
      target_odd_q    <= RESET_PC[2];
      waiting_first_q <= 1'b1;
      inflight_cnt_q  <= 2'd0;
      stale_cnt_q     <= 2'd0;

      if2_valid0_o    <= 1'b0;
      if2_pc0_o       <= RESET_PC;
      if2_inst0_o     <= 32'h00000013; // NOP
      if2_valid1_o    <= 1'b0;
      if2_pc1_o       <= RESET_PC;
      if2_inst1_o     <= 32'h00000013; // NOP
    end else if (flush_i) begin
      fetch_pc_q      <= {redirect_pc_i[XLEN-1:3], 3'b000};
      head_pc_q       <= redirect_pc_i;
      q_inst0_q       <= 32'd0;
      q_inst1_q       <= 32'd0;
      q_inst2_q       <= 32'd0;
      q_inst3_q       <= 32'd0;
      q_count_q       <= 3'd0;
      target_odd_q    <= redirect_pc_i[2];
      waiting_first_q <= 1'b1;

      // Stale counter computation: inflight requests not retiring in the current cycle are marked stale
      stale_cnt_q     <= (inflight_cnt_q > {1'b0, l1i_resp_valid_i}) ?
                         (inflight_cnt_q - {1'b0, l1i_resp_valid_i}) : 2'd0;
      inflight_cnt_q  <= 2'd0;

      if2_valid0_o    <= 1'b0;
      if2_valid1_o    <= 1'b0;
    end else begin
      // Instruction Dispatch to ID1
      if (!stall_i) begin
        if (can_dual) begin
          if2_valid0_o <= 1'b1;
          if2_pc0_o    <= head_pc_q;
          if2_inst0_o  <= cand0;
          if2_valid1_o <= 1'b1;
          if2_pc1_o    <= head_pc_q + 64'd4;
          if2_inst1_o  <= cand1;
        end else if (q_count_q >= 3'd1) begin
          if2_valid0_o <= 1'b1;
          if2_pc0_o    <= head_pc_q;
          if2_inst0_o  <= cand0;
          if2_valid1_o <= 1'b0;
          if2_pc1_o    <= head_pc_q + 64'd4;
          if2_inst1_o  <= 32'h00000013;
        end else begin
          if2_valid0_o <= 1'b0;
          if2_valid1_o <= 1'b0;
        end
      end

      // Queue state update
      q_inst0_q <= next_inst0;
      q_inst1_q <= next_inst1;
      q_inst2_q <= next_inst2;
      q_inst3_q <= next_inst3;
      q_count_q <= next_count;

      if (consumed != 2'd0) begin
        head_pc_q <= head_pc_q + {60'd0, consumed, 2'b00};
      end

      // Fetch PC increment
      if (fetch_req_valid_o) begin
        fetch_pc_q <= fetch_pc_q + 64'd8;
      end

      // Inflight request tracking
      case ({fetch_req_valid_o, resp_is_valid})
        2'b10: inflight_cnt_q <= inflight_cnt_q + 2'd1;
        2'b01: inflight_cnt_q <= (inflight_cnt_q > 2'd0) ? inflight_cnt_q - 2'd1 : 2'd0;
        default: ; // 2'b00 or 2'b11: unchanged
      endcase

      // Stale response tracking
      if (l1i_resp_valid_i && resp_is_stale) begin
        stale_cnt_q <= stale_cnt_q - 2'd1;
      end

      if (resp_is_valid && waiting_first_q) begin
        waiting_first_q <= 1'b0;
      end
    end
  end

  // Avoid unused warning
  wire [31:0] _unused_hart = HART_ID;
  wire _unused = &{1'b0, consume_step_i, _unused_hart, 1'b0};

endmodule

`default_nettype wire
