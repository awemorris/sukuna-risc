// ============================================================================
// Pipeline Stage: IF2 (Instruction Fetch 2 & Decompressor) (Verilog 2005)
// Complies with design-rule.md
// ============================================================================
// Responsibilities:
//   - Receives 64-bit instruction fetch blocks from L1I cache
//   - Maintains an 128-bit elastic instruction buffer for variable-length instructions
//   - Instantiates sk_rvc_dec for inline 16-to-32 bit decompression
//   - Emits byte-accurate instructions (both 16-bit RVC and 32-bit standard) to ID1
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
  assign fetch_req_valid_o = (buf_bytes_q <= 5'd8) && (inflight_cnt_q == 2'd0) && !flush_i && !l1i_miss_i;
  assign fetch_req_pc_o    = fetch_pc_q;

  // --------------------------------------------------------------------------
  // Instruction Decode & Decompression
  // --------------------------------------------------------------------------
  wire is_rvc   = (buf_data_q[1:0] != 2'b11);
  wire can_emit = is_rvc ? (buf_bytes_q >= 5'd2) : (buf_bytes_q >= 5'd4);

  wire [31:0] raw_inst = is_rvc ? {16'h0000, buf_data_q[15:0]} : buf_data_q[31:0];
  wire [31:0] dec_inst;
  wire        illegal_rvc;

  sk_rvc_dec u_rvc_dec (
    .inst_i   (raw_inst),
    .inst_o   (dec_inst),
    .is_rvc_o (),
    .illegal_o(illegal_rvc)
  );

  wire [2:0] emit_len       = is_rvc ? 3'd2 : 3'd4;
  wire       emit_valid     = can_emit && !flush_i;
  wire [2:0] consumed_bytes = (emit_valid && !stall_i) ? emit_len : 3'd0;

  // Buffer Shifting Logic
  wire [127:0] rem_data  = buf_data_q >> (consumed_bytes * 8);
  wire [4:0]   rem_bytes = buf_bytes_q - {2'd0, consumed_bytes};

  // Valid response filter (stale vs new)
  wire resp_is_stale = (stale_cnt_q > 2'd0);
  wire resp_is_valid = l1i_resp_valid_i && !resp_is_stale;

  wire [1:0] true_inflight = (inflight_cnt_q > {1'b0, l1i_resp_valid_i}) ?
                             (inflight_cnt_q - {1'b0, l1i_resp_valid_i}) : 2'd0;

  // --------------------------------------------------------------------------
  // Sequential Pipeline State Update
  // --------------------------------------------------------------------------
  always @(posedge clk_i or negedge rst_ni) begin
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
        if2_valid0_o <= emit_valid;
        if2_pc0_o    <= buf_pc_q;
        if2_inst0_o  <= dec_inst;
        if2_valid1_o <= 1'b0;
        if2_pc1_o    <= buf_pc_q;
        if2_inst1_o  <= 32'h00000013;

        if (emit_valid) begin
          buf_pc_q <= buf_pc_q + {61'd0, emit_len};
        end
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
        buf_data_q      <= ({{64{1'b0}}, l1i_inst_i} >> (discard_bytes_q * 8));
        buf_bytes_q     <= 5'd8 - {2'd0, discard_bytes_q};
        waiting_first_q <= 1'b0;
      end else if (resp_is_valid) begin
        buf_data_q  <= rem_data | ({{64{1'b0}}, l1i_inst_i} << (rem_bytes * 8));
        buf_bytes_q <= rem_bytes + 5'd8;
      end else begin
        buf_data_q  <= rem_data;
        buf_bytes_q <= rem_bytes;
      end
    end
  end

  // Avoid unused warning
  wire _unused = &{1'b0, illegal_rvc, 1'b0};

endmodule
