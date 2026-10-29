// ============================================================================
// Pipeline Stage: IF2 (Instruction Fetch 2 & Decompressor) (Verilog 2005)
// Complies with design-rule.md
// ============================================================================
// Responsibilities:
//   - Receives 64-bit instruction fetch blocks from L1I cache (even 8-byte aligned)
//   - Maintains an 128-bit elastic instruction buffer for variable-length instructions
//   - Dual-issue instruction extraction and inline 16-to-32 bit decompression
//   - Emits byte-accurate instructions (both Slot 0 and Slot 1) to ID1
//   - Synchronous consume_step_i feedback from ID2 (0, 1, or 2 instructions consumed)
//   - Drives prefetch requests to IF1 whenever the buffer has capacity
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
  output reg              if2_valid0_o, /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]  if2_pc0_o,    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [31:0]      if2_inst0_o,  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  output reg              if2_valid1_o, /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]  if2_pc1_o,    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [31:0]      if2_inst1_o   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
);

  // --------------------------------------------------------------------------
  // Fetch Control Registers
  // --------------------------------------------------------------------------
  reg [XLEN-1:0]  fetch_pc_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [127:0]     buf_data_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [4:0]       buf_bytes_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]  buf_pc_q;         /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [2:0]       discard_bytes_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg             waiting_first_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [1:0]       inflight_cnt_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [1:0]       stale_cnt_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // Request to IF1: request when buffer has room for at least 8 bytes and not missing
  assign fetch_req_valid_o = (buf_bytes_q <= 5'd8) && (inflight_cnt_q == 2'd0) && !l1i_miss_i;
  assign fetch_req_pc_o    = {fetch_pc_q[XLEN-1:3], 3'b000}; // Always even 8-byte aligned

  // --------------------------------------------------------------------------
  // Dual-Instruction Extraction & Decompression
  // --------------------------------------------------------------------------
  // Slot 0 Instruction Extraction
  wire is_rvc0   = (buf_data_q[1:0] != 2'b11);
  wire can_emit0 = is_rvc0 ? (buf_bytes_q >= 5'd2) : (buf_bytes_q >= 5'd4);
  wire [2:0] len0 = is_rvc0 ? 3'd2 : 3'd4;
  wire [31:0] raw_inst0 = is_rvc0 ? {16'h0000, buf_data_q[15:0]} : buf_data_q[31:0];
  wire [31:0] dec_inst0;
  wire        illegal_rvc0;

  sk_rvc_dec u_rvc_dec0 (
    .inst_i   (raw_inst0),
    .inst_o   (dec_inst0),
    .is_rvc_o (),
    .illegal_o(illegal_rvc0)
  );

  // Slot 1 Instruction Extraction with Parallel Speculative Decoding (C2 vs C4)
  wire is_c2 = (len0 == 3'd2);

  // Candidate C2: assuming Slot 0 was 16-bit RVC (len0 == 2)
  wire is_rvc1_c2  = (buf_data_q[17:16] != 2'b11);
  wire [2:0] len1_c2 = is_rvc1_c2 ? 3'd2 : 3'd4;
  wire [31:0] raw_inst1_c2 = is_rvc1_c2 ? {16'h0000, buf_data_q[31:16]} : buf_data_q[47:16];
  wire [31:0] dec_inst1_c2;
  wire        illegal_rvc1_c2;

  sk_rvc_dec u_rvc_dec1_c2 (
    .inst_i   (raw_inst1_c2),
    .inst_o   (dec_inst1_c2),
    .is_rvc_o (),
    .illegal_o(illegal_rvc1_c2)
  );

  // Candidate C4: assuming Slot 0 was 32-bit uncompressed (len0 == 4)
  wire is_rvc1_c4  = (buf_data_q[33:32] != 2'b11);
  wire [2:0] len1_c4 = is_rvc1_c4 ? 3'd2 : 3'd4;
  wire [31:0] raw_inst1_c4 = is_rvc1_c4 ? {16'h0000, buf_data_q[47:32]} : buf_data_q[63:32];
  wire [31:0] dec_inst1_c4;
  wire        illegal_rvc1_c4;

  sk_rvc_dec u_rvc_dec1_c4 (
    .inst_i   (raw_inst1_c4),
    .inst_o   (dec_inst1_c4),
    .is_rvc_o (),
    .illegal_o(illegal_rvc1_c4)
  );

  // Dual-issue pairing check (INT+MA or MA+INT, without RAW/WAW hazard)
  wire [6:0] op0 = dec_inst0[6:0];
  wire is_int0 = (op0 == 7'h13 || op0 == 7'h33 || op0 == 7'h1b || op0 == 7'h3b || op0 == 7'h37 || op0 == 7'h17);
  wire is_ma0  = (op0 == 7'h03 || op0 == 7'h23);
  wire [4:0] rd0 = dec_inst0[11:7];

  // Pairing for Candidate C2
  wire [6:0] op1_c2   = dec_inst1_c2[6:0];
  wire is_ma1_c2      = (op1_c2 == 7'h03 || op1_c2 == 7'h23);
  wire [4:0] rs1_1_c2 = dec_inst1_c2[19:15];
  wire [4:0] rs2_1_c2 = dec_inst1_c2[24:20];
  wire [4:0] rd1_c2   = dec_inst1_c2[11:7];
  wire raw_dep_c2     = (rd0 != 5'd0) && ((rs1_1_c2 == rd0) || (rs2_1_c2 == rd0));
  wire waw_dep_c2     = (rd0 != 5'd0) && (rd0 == rd1_c2);
  wire can_dual_c2    = can_emit0 && (buf_bytes_q >= (5'd2 + {2'd0, len1_c2})) &&
                        (is_int0 && is_ma1_c2) && !raw_dep_c2 && !waw_dep_c2;

  // Pairing for Candidate C4
  wire [6:0] op1_c4   = dec_inst1_c4[6:0];
  wire is_ma1_c4      = (op1_c4 == 7'h03 || op1_c4 == 7'h23);
  wire [4:0] rs1_1_c4 = dec_inst1_c4[19:15];
  wire [4:0] rs2_1_c4 = dec_inst1_c4[24:20];
  wire [4:0] rd1_c4   = dec_inst1_c4[11:7];
  wire raw_dep_c4     = (rd0 != 5'd0) && ((rs1_1_c4 == rd0) || (rs2_1_c4 == rd0));
  wire waw_dep_c4     = (rd0 != 5'd0) && (rd0 == rd1_c4);
  wire can_dual_c4    = can_emit0 && (buf_bytes_q >= (5'd4 + {2'd0, len1_c4})) &&
                        (is_int0 && is_ma1_c4) && !raw_dep_c4 && !waw_dep_c4;

  // Selected outputs
  wire can_dual      = is_c2 ? can_dual_c2  : can_dual_c4;
  wire [31:0] dec_inst1 = is_c2 ? dec_inst1_c2 : dec_inst1_c4;
  wire [2:0]  len1      = is_c2 ? len1_c2      : len1_c4;
  wire [4:0]  total_len = is_c2 ? (5'd2 + {2'd0, len1_c2}) : (5'd4 + {2'd0, len1_c4});

  // Pre-shifted buffer variants (direct wire slices)
  wire [127:0] buf_shift_after0 = is_c2 ? {16'd0, buf_data_q[127:16]} : {32'd0, buf_data_q[127:32]};
  wire [127:0] buf_shift_c2_1   = (len1_c2 == 3'd2) ? {32'd0, buf_data_q[127:32]} : {48'd0, buf_data_q[127:48]};
  wire [127:0] buf_shift_c4_1   = (len1_c4 == 3'd2) ? {48'd0, buf_data_q[127:48]} : {64'd0, buf_data_q[127:64]};
  wire [127:0] buf_shift_after1 = is_c2 ? buf_shift_c2_1 : buf_shift_c4_1;

  wire [XLEN-1:0] pc_single = buf_pc_q + {61'd0, len0};
  wire [XLEN-1:0] pc_dual   = buf_pc_q + {60'd0, total_len};
  wire [XLEN-1:0] next_buf_pc = !can_emit0 ? buf_pc_q : (can_dual ? pc_dual : pc_single);

  wire [4:0]   rem_bytes_single = (buf_bytes_q >= {2'd0, len0}) ? (buf_bytes_q - {2'd0, len0}) : 5'd0;
  wire [4:0]   rem_bytes_dual   = (buf_bytes_q >= total_len) ? (buf_bytes_q - total_len) : 5'd0;

  function [127:0] shift_l1i;
    input [2:0]  shift_idx;
    input [63:0] inst_blk;
    begin
      case (shift_idx)
        3'd0:    shift_l1i = {64'd0, inst_blk};
        3'd1:    shift_l1i = {48'd0, inst_blk, 16'd0};
        3'd2:    shift_l1i = {32'd0, inst_blk, 32'd0};
        3'd3:    shift_l1i = {16'd0, inst_blk, 48'd0};
        3'd4:    shift_l1i = {inst_blk, 64'd0};
        default: shift_l1i = {64'd0, inst_blk};
      endcase
    end
  endfunction

  wire [127:0] l1i_shifted_single = shift_l1i(rem_bytes_single[3:1], l1i_inst_i);
  wire [127:0] l1i_shifted_dual   = shift_l1i(rem_bytes_dual[3:1],   l1i_inst_i);
  wire [127:0] l1i_shifted_stall  = shift_l1i(buf_bytes_q[3:1],      l1i_inst_i);

  wire [127:0] buf_comb_single = buf_shift_after0 | l1i_shifted_single;
  wire [127:0] buf_comb_dual   = buf_shift_after1 | l1i_shifted_dual;
  wire [127:0] buf_comb_stall  = buf_data_q       | l1i_shifted_stall;

  wire [127:0] next_buf_data_resp = (!can_emit0 || stall_i) ? buf_comb_stall :
                                    can_dual ? buf_comb_dual : buf_comb_single;

  wire [127:0] next_buf_data_nostall = (!can_emit0) ? buf_data_q :
                                       can_dual ? buf_shift_after1 : buf_shift_after0;

  wire [4:0] next_buf_bytes_resp = (!can_emit0 || stall_i) ? (buf_bytes_q + 5'd8) :
                                   can_dual ? (rem_bytes_dual + 5'd8) : (rem_bytes_single + 5'd8);

  wire [4:0] next_buf_bytes_nostall = (!can_emit0) ? buf_bytes_q :
                                      can_dual ? rem_bytes_dual : rem_bytes_single;

  reg [127:0] first_l1i_discarded;
  always @(*) begin
    case (discard_bytes_q[2:1])
      2'd0:    first_l1i_discarded = {64'd0, l1i_inst_i};
      2'd1:    first_l1i_discarded = {80'd0, l1i_inst_i[63:16]};
      2'd2:    first_l1i_discarded = {96'd0, l1i_inst_i[63:32]};
      default: first_l1i_discarded = {112'd0, l1i_inst_i[63:48]};
    endcase
  end

  // Valid response filter (stale vs new)
  wire resp_is_stale = (stale_cnt_q > 2'd0);
  wire resp_is_valid = l1i_resp_valid_i && !resp_is_stale;

  wire [1:0] true_inflight = (inflight_cnt_q > {1'b0, l1i_resp_valid_i}) ?
                             (inflight_cnt_q - {1'b0, l1i_resp_valid_i}) : 2'd0;

  // --------------------------------------------------------------------------
  // Sequential Pipeline State Update
  // --------------------------------------------------------------------------
  always @(posedge clk_i) begin
    if (!rst_ni) begin
      fetch_pc_q       <= {RESET_PC[XLEN-1:3], 3'b000};
      buf_data_q       <= 128'd0;
      buf_bytes_q      <= 5'd0;
      buf_pc_q         <= RESET_PC;
      discard_bytes_q  <= RESET_PC[2:0];
      waiting_first_q  <= 1'b1;
      inflight_cnt_q   <= 2'd0;
      stale_cnt_q      <= 2'd0;

      if2_valid0_o     <= 1'b0;
      if2_pc0_o        <= RESET_PC;
      if2_inst0_o      <= 32'h00000013;
      if2_valid1_o     <= 1'b0;
      if2_pc1_o        <= RESET_PC;
      if2_inst1_o      <= 32'h00000013;
    end else if (flush_i) begin
      fetch_pc_q       <= {redirect_pc_i[XLEN-1:3], 3'b000};
      buf_data_q       <= 128'd0;
      buf_bytes_q      <= 5'd0;
      buf_pc_q         <= redirect_pc_i;
      discard_bytes_q  <= redirect_pc_i[2:0];
      waiting_first_q  <= 1'b1;
      stale_cnt_q      <= true_inflight;
      inflight_cnt_q   <= 2'd0;

      if2_valid0_o     <= 1'b0;
      if2_valid1_o     <= 1'b0;
    end else begin
      // Instruction Dispatch to ID1
      if (!stall_i) begin
        if2_valid0_o <= can_emit0;
        if2_pc0_o    <= buf_pc_q;
        if2_inst0_o  <= dec_inst0;

        if2_valid1_o <= can_dual;
        if2_pc1_o    <= pc_single;
        if2_inst1_o  <= dec_inst1;

        buf_pc_q <= next_buf_pc;
      end

      // In-flight request tracking
      case ({fetch_req_valid_o, resp_is_valid})
        2'b10: inflight_cnt_q <= inflight_cnt_q + 2'd1;
        2'b01: inflight_cnt_q <= (inflight_cnt_q > 2'd0) ? inflight_cnt_q - 2'd1 : 2'd0;
        default: ; // 2'b00 or 2'b11: unchanged
      endcase

      if (fetch_req_valid_o) begin
        fetch_pc_q <= fetch_pc_q + 64'd8;
      end

      // Stale response tracking
      if (l1i_resp_valid_i && resp_is_stale) begin
        stale_cnt_q <= stale_cnt_q - 2'd1;
      end

      // Buffer Load / Shift Update
      if (resp_is_valid && waiting_first_q) begin
        buf_data_q      <= first_l1i_discarded;
        buf_bytes_q     <= 5'd8 - {2'd0, discard_bytes_q};
        waiting_first_q <= 1'b0;
      end else if (resp_is_valid) begin
        buf_data_q  <= next_buf_data_resp;
        buf_bytes_q <= next_buf_bytes_resp;
      end else begin
        buf_data_q  <= next_buf_data_nostall;
        buf_bytes_q <= next_buf_bytes_nostall;
      end
    end
  end

  // Avoid unused warnings
  wire _unused = &{1'b0, illegal_rvc0, illegal_rvc1_c2, illegal_rvc1_c4, 1'b0};

endmodule
