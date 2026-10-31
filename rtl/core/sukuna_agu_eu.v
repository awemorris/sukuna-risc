// ============================================================================
// Sukuna-RISC: Dedicated 3-Stage Memory Access Execution Unit (MA-EU) (Verilog 2005)
// Complies with style.md (ASIC 5nm 1.5GHz & Kintex-7)
// ============================================================================
// Pipeline Stages:
//   Stage 1 (ADDR): Dedicated 64-bit address calculation (sk_add) & byte enables
//   Stage 2 (MA1) : DTLB translation & L1D cache read/write request dispatch
//   Stage 3 (MA2) : L1D BRAM read latency; registers raw data into holding buffer
//   WB Stage (WB) : Direct alignment rotator and sign-extension driving WB stage
// ============================================================================

`timescale 1ns / 1ps
`default_nettype none

`include "sukuna_defines.vh"

module sukuna_agu_eu #(
  parameter XLEN        = `XLEN,
  parameter VADDR_WIDTH = `VADDR_WIDTH,
  parameter PADDR_WIDTH = `PADDR_WIDTH
)(
  input  wire                   clk_i,
  input  wire                   rst_ni,

  // Dispatched from ID/RF (Slot 1 MA)
  input  wire                   req_valid_i,
  input  wire [XLEN-1:0]        req_pc_i,
  input  wire [7:0]             req_op_i,
  input  wire [4:0]             req_rd_i,
  input  wire [XLEN-1:0]        req_base_i,
  input  wire [XLEN-1:0]        req_offset_i,
  input  wire [XLEN-1:0]        req_wdata_i,
  output wire                   busy_o,
  output wire                   s1_valid_o,
  output wire [4:0]             s1_rd_o,
  output wire                   s1_is_fp_o,
  output wire                   s2_valid_o,
  output wire [4:0]             s2_rd_o,
  output wire                   s2_is_fp_o,
  output wire                   miss_or_amo_stall_o,

  // Snoop invalidation input (for multi-hart LR/SC reservation clearing)
  input  wire                   snoop_inv_valid_i,
  input  wire [PADDR_WIDTH-1:2] snoop_inv_paddr_w_i,

  // DTLB Address Translation (Word-aligned address)
  output wire                   dtlb_lookup_valid_o,
  output wire [VADDR_WIDTH-1:2] dtlb_vaddr_w_o,
  input  wire                   dtlb_hit_i,
  input  wire [PADDR_WIDTH-1:2] dtlb_paddr_w_i,
  input  wire                   dtlb_fault_i,

  // Dedicated L1D Port (Word-aligned address & byte-enable)
  output wire                   l1d_req_valid_o,
  output wire                   l1d_req_write_o,
  output wire [3:0]             l1d_req_op_o,
  output wire [7:0]             l1d_req_byte_en_o,
  output wire [PADDR_WIDTH-1:2] l1d_paddr_w_o,
  output wire [XLEN-1:0]        l1d_wdata_o,
  input  wire                   l1d_req_ready_i,
  input  wire                   l1d_resp_valid_i,
  input  wire [XLEN-1:0]        l1d_rdata_i,
  input  wire                   l1d_miss_stall_i,

  // Dedicated Uncached / MMIO Port
  output wire                   uncached_req_valid_o,
  output wire                   uncached_req_write_o,
  output wire [3:0]             uncached_req_op_o,
  output wire [7:0]             uncached_req_byte_en_o,
  output wire [PADDR_WIDTH-1:2] uncached_req_paddr_w_o,
  output wire [XLEN-1:0]        uncached_req_wdata_o,
  input  wire                   uncached_req_ready_i,
  input  wire                   uncached_resp_valid_i,
  input  wire [XLEN-1:0]        uncached_resp_rdata_i,

  // Output to Writeback Stage
  output wire                   resp_valid_o,
  output wire [XLEN-1:0]        resp_pc_o,
  output wire [4:0]             resp_rd_o,
  output wire [XLEN-1:0]        resp_rdata_o,
  output wire                   resp_writes_fpr_o
);

  // --------------------------------------------------------------------------
  // Stage 1: ADDR (Address Calculation & Byte Enables)
  // --------------------------------------------------------------------------
  wire [VADDR_WIDTH-1:0] calc_vaddr;

  sk_add #(
    .WIDTH   (VADDR_WIDTH),
    .PIPELINE(0),
    .IMPL    ("CARRY")
  ) u_addr_add (
    .clk_i   (clk_i),
    .rst_ni  (rst_ni),
    .cin_i   (1'b0),
    .a_i     (req_base_i[VADDR_WIDTH-1:0]),
    .b_i     (req_offset_i[VADDR_WIDTH-1:0]),
    .sum_o   (calc_vaddr),
    .cout_o  ()
  );

  wire [2:0] addr_lsb = calc_vaddr[2:0];
  reg [7:0]  calc_byte_en;
  always @(*) begin
    case (req_op_i[1:0])
      2'b00: calc_byte_en = 8'b00000001 << addr_lsb;
      2'b01: calc_byte_en = 8'b00000011 << {addr_lsb[2:1], 1'b0};
      2'b10: calc_byte_en = addr_lsb[2] ? 8'b11110000 : 8'b00001111;
      2'b11: calc_byte_en = 8'b11111111;
    endcase
  end

  reg [XLEN-1:0] calc_aligned_wdata;
  always @(*) begin
    case (req_op_i[1:0])
      2'b00: calc_aligned_wdata = {8{req_wdata_i[7:0]}};
      2'b01: calc_aligned_wdata = {4{req_wdata_i[15:0]}};
      2'b10: calc_aligned_wdata = {2{req_wdata_i[31:0]}};
      2'b11: calc_aligned_wdata = req_wdata_i;
    endcase
  end

  // Stage 1 Registers (ADDR -> MA1)
  reg                     s1_valid_q;        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]          s1_pc_q;           /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [7:0]               s1_op_q;           /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [4:0]               s1_rd_q;           /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [VADDR_WIDTH-1:2]   s1_vaddr_w_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [2:0]               s1_addr_lsb_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [7:0]               s1_byte_en_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]          s1_wdata_q;        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]          s1_orig_wdata_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                     s1_wait_q;         /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // --------------------------------------------------------------------------
  // Stage 2: MA1 (DTLB Translation & L1D Request Setup)
  // --------------------------------------------------------------------------
  wire [3:0] s1_amo_type = s1_op_q[7:4];
  wire s1_is_lr          = (s1_amo_type == `AMO_LR);
  wire s1_is_sc          = (s1_amo_type == `AMO_SC);
  wire s1_is_alu_amo     = (s1_amo_type >= `AMO_SWAP && s1_amo_type <= `AMO_MAXU);

  // DTLB Address Translation lookup
  assign dtlb_lookup_valid_o = s1_valid_q;
  assign dtlb_vaddr_w_o      = s1_vaddr_w_q;

  // AMO State Machine and Reservation Registers
  localparam S_AGU_IDLE  = 2'd0;
  localparam S_AGU_SC    = 2'd1;
  localparam S_AGU_ALU   = 2'd2;
  localparam S_AGU_STORE = 2'd3;

  reg [1:0]               agu_state_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                     res_valid_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [PADDR_WIDTH-1:2]   res_paddr_w_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [PADDR_WIDTH-1:2]   store_paddr_w_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]          amo_rdata_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]          amo_wdata_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                     sc_failed_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                     sc_success_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  wire sc_match = res_valid_q && (res_paddr_w_q == store_paddr_w_q);

  // Physical Memory Attribute (PMA): RAM is >= 0x8000_0000; Devices / MMIO are < 0x8000_0000
  wire is_uncached = !dtlb_paddr_w_i[31];

  // L1D Request Driving (driven during MA1 or during AMO STORE)
  assign l1d_paddr_w_o       = (agu_state_q == S_AGU_STORE) ? store_paddr_w_q : dtlb_paddr_w_i;
  assign l1d_req_op_o        = s1_op_q[3:0];
  assign l1d_req_byte_en_o   = s1_byte_en_q;
  assign l1d_wdata_o         = (agu_state_q == S_AGU_STORE) ? amo_wdata_q : s1_wdata_q;

  assign l1d_req_valid_o     = (agu_state_q == S_AGU_STORE) ? 1'b1 :
                               (s1_valid_q && dtlb_hit_i && !is_uncached && !s1_is_sc);
  assign l1d_req_write_o     = (agu_state_q == S_AGU_STORE) ? 1'b1 :
                               (s1_is_alu_amo || s1_is_sc) ? 1'b0 : s1_op_q[3];

  // Stage 2 Registers (MA1 -> MA2)
  wire [2:0] s1_sign_byte_idx = (s1_op_q[1:0] == 2'b00) ? s1_addr_lsb_q :
                                (s1_op_q[1:0] == 2'b01) ? (s1_addr_lsb_q + 3'd1) :
                                                          (s1_addr_lsb_q + 3'd3);

  wire       s1_is_flw   = (s1_op_q[7:4] == `AMO_FP) && !s1_op_q[3] && (s1_op_q[2:0] == 3'b010);
  wire       s1_l1d_fast = !is_uncached && !s1_is_alu_amo;
  wire       s1_b0_keep  = s1_l1d_fast;
  wire       s1_b1_keep  = s1_l1d_fast && (s1_op_q[1:0] != 2'b00);
  wire       s1_b1_sign  = s1_l1d_fast && (s1_op_q[1:0] == 2'b00) && !s1_op_q[2];
  wire       s1_h1_keep  = s1_l1d_fast && s1_op_q[1];
  wire       s1_h1_sign  = s1_l1d_fast && !s1_op_q[1] && !s1_op_q[2];
  wire       s1_w1_keep  = s1_l1d_fast && (s1_op_q[1:0] == 2'b11);
  wire       s1_w1_sign  = s1_l1d_fast && (s1_op_q[1:0] != 2'b11) && !s1_op_q[2] && !s1_is_flw;
  wire       s1_w1_one   = s1_is_flw;

  reg                     s2_valid_q;             /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]          s2_pc_q;                /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                     s2_is_uncached_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                     s2_uncached_req_sent_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [7:0]               s2_op_q;                /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [7:0]               s2_byte_en_q;           /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [4:0]               s2_rd_q;                /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [2:0]               s2_addr_lsb_q;          /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [2:0]               s2_sign_byte_idx_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                     s2_b0_keep_q;           /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                     s2_b1_keep_q;           /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                     s2_b1_sign_q;           /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                     s2_h1_keep_q;           /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                     s2_h1_sign_q;           /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                     s2_w1_keep_q;           /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                     s2_w1_sign_q;           /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                     s2_w1_one_q;            /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [PADDR_WIDTH-1:2]   s2_paddr_w_q;           /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]          s2_wdata_q;             /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]          s2_orig_wdata_q;        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                     s2_wait_q;              /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // Dedicated Uncached Request Driving (driven cleanly from MA2 registers)
  assign uncached_req_valid_o   = s2_valid_q && s2_is_uncached_q && !s2_uncached_req_sent_q;
  assign uncached_req_write_o   = s2_op_q[3];
  assign uncached_req_op_o      = s2_op_q[3:0];
  assign uncached_req_byte_en_o = s2_byte_en_q;
  assign uncached_req_paddr_w_o = s2_paddr_w_q;
  assign uncached_req_wdata_o   = s2_wdata_q;

  // --------------------------------------------------------------------------
  // Stage 3: MA2 (L1D BRAM Read Latency, Parallel Byte Alignment & Sign Extension)
  // --------------------------------------------------------------------------
  wire             resp_valid_in = s2_is_uncached_q ? uncached_resp_valid_i : l1d_resp_valid_i;
  wire             s2_stays_busy = s2_valid_q && !resp_valid_in;

  // Fast L1D path: extract sign bit and byte-align directly on l1d_rdata_i (8:1 MUXF7)
  reg s2_l1d_raw_sign;
  always @(*) begin
    case (s2_sign_byte_idx_q)
      3'd0: s2_l1d_raw_sign = l1d_rdata_i[7];
      3'd1: s2_l1d_raw_sign = l1d_rdata_i[15];
      3'd2: s2_l1d_raw_sign = l1d_rdata_i[23];
      3'd3: s2_l1d_raw_sign = l1d_rdata_i[31];
      3'd4: s2_l1d_raw_sign = l1d_rdata_i[39];
      3'd5: s2_l1d_raw_sign = l1d_rdata_i[47];
      3'd6: s2_l1d_raw_sign = l1d_rdata_i[55];
      3'd7: s2_l1d_raw_sign = l1d_rdata_i[63];
    endcase
  end

  reg [63:0] s2_l1d_aligned;
  always @(*) begin
    case (s2_addr_lsb_q)
      3'd0: s2_l1d_aligned = l1d_rdata_i;
      3'd1: s2_l1d_aligned = {8'd0,  l1d_rdata_i[63:8]};
      3'd2: s2_l1d_aligned = {16'd0, l1d_rdata_i[63:16]};
      3'd3: s2_l1d_aligned = {24'd0, l1d_rdata_i[63:24]};
      3'd4: s2_l1d_aligned = {32'd0, l1d_rdata_i[63:32]};
      3'd5: s2_l1d_aligned = {40'd0, l1d_rdata_i[63:40]};
      3'd6: s2_l1d_aligned = {48'd0, l1d_rdata_i[63:48]};
      3'd7: s2_l1d_aligned = {56'd0, l1d_rdata_i[63:56]};
    endcase
  end

  // Non-critical Uncached / AMO / SC / constant-fill path (decoupled from l1d_rdata_i)
  reg s2_unc_raw_sign;
  always @(*) begin
    case (s2_sign_byte_idx_q)
      3'd0: s2_unc_raw_sign = uncached_resp_rdata_i[7];
      3'd1: s2_unc_raw_sign = uncached_resp_rdata_i[15];
      3'd2: s2_unc_raw_sign = uncached_resp_rdata_i[23];
      3'd3: s2_unc_raw_sign = uncached_resp_rdata_i[31];
      3'd4: s2_unc_raw_sign = uncached_resp_rdata_i[39];
      3'd5: s2_unc_raw_sign = uncached_resp_rdata_i[47];
      3'd6: s2_unc_raw_sign = uncached_resp_rdata_i[55];
      3'd7: s2_unc_raw_sign = uncached_resp_rdata_i[63];
    endcase
  end

  wire s2_unc_sign_ext = s2_unc_raw_sign && !s2_op_q[2];
  wire s2_unc_fill_hi  = s2_w1_one_q ? 1'b1 : s2_unc_sign_ext;

  reg [63:0] s2_unc_aligned;
  always @(*) begin
    case (s2_addr_lsb_q)
      3'd0: s2_unc_aligned = uncached_resp_rdata_i;
      3'd1: s2_unc_aligned = {8'd0,  uncached_resp_rdata_i[63:8]};
      3'd2: s2_unc_aligned = {16'd0, uncached_resp_rdata_i[63:16]};
      3'd3: s2_unc_aligned = {24'd0, uncached_resp_rdata_i[63:24]};
      3'd4: s2_unc_aligned = {32'd0, uncached_resp_rdata_i[63:32]};
      3'd5: s2_unc_aligned = {40'd0, uncached_resp_rdata_i[63:40]};
      3'd6: s2_unc_aligned = {48'd0, uncached_resp_rdata_i[63:48]};
      3'd7: s2_unc_aligned = {56'd0, uncached_resp_rdata_i[63:56]};
    endcase
  end

  reg [XLEN-1:0] s2_unc_formatted;
  always @(*) begin
    case (s2_op_q[1:0])
      2'b00:   s2_unc_formatted = {{56{s2_unc_sign_ext}}, s2_unc_aligned[7:0]};
      2'b01:   s2_unc_formatted = {{48{s2_unc_sign_ext}}, s2_unc_aligned[15:0]};
      2'b10:   s2_unc_formatted = {{32{s2_unc_fill_hi}},  s2_unc_aligned[31:0]};
      default: s2_unc_formatted = s2_unc_aligned;
    endcase
  end

  wire [63:0] s2_l1d_const_fill = {{32{s2_w1_one_q}}, 32'd0};
  wire [63:0] s2_non_l1d_data   = (agu_state_q == S_AGU_SC)    ? 64'd1 :
                                  (agu_state_q == S_AGU_STORE) ? amo_rdata_q :
                                  s2_is_uncached_q             ? s2_unc_formatted :
                                                                 s2_l1d_const_fill;

  // Single-LUT5 final merge per bit into buf_raw_data_q
  wire [63:0] s2_next_buf_data;
  assign s2_next_buf_data[7:0]   = s2_b0_keep_q ? s2_l1d_aligned[7:0] :
                                                  s2_non_l1d_data[7:0];
  assign s2_next_buf_data[15:8]  = s2_b1_keep_q ? s2_l1d_aligned[15:8] :
                                   s2_b1_sign_q ? {8{s2_l1d_raw_sign}} :
                                                  s2_non_l1d_data[15:8];
  assign s2_next_buf_data[31:16] = s2_h1_keep_q ? s2_l1d_aligned[31:16] :
                                   s2_h1_sign_q ? {16{s2_l1d_raw_sign}} :
                                                  s2_non_l1d_data[31:16];
  assign s2_next_buf_data[63:32] = s2_w1_keep_q ? s2_l1d_aligned[63:32] :
                                   s2_w1_sign_q ? {32{s2_l1d_raw_sign}} :
                                                  s2_non_l1d_data[63:32];

  // WB Output Holding Registers (Pure FF outputs to WB / EX forwarding)
  reg                     buf_valid_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]          buf_pc_q;          /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [63:0]              buf_raw_data_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [4:0]               buf_rd_q;          /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                     buf_writes_fpr_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // AMO ALU Operations (operates on registered amo_rdata_q)
  wire is_word_amo   = (s2_op_q[1:0] == 2'b10);
  wire [31:0] amo_word_raw   = s2_addr_lsb_q[2] ? l1d_rdata_i[63:32] : l1d_rdata_i[31:0];
  wire [XLEN-1:0] amo_latch_data = is_word_amo ? {{32{amo_word_raw[31]}}, amo_word_raw} : l1d_rdata_i;

  wire [XLEN-1:0] amo_src1 = is_word_amo ? {{32{amo_rdata_q[31]}}, amo_rdata_q[31:0]} : amo_rdata_q;
  wire [XLEN-1:0] amo_src2 = s2_orig_wdata_q;

  wire signed [31:0] s32_src1 = amo_src1[31:0];
  wire signed [31:0] s32_src2 = amo_src2[31:0];
  wire signed [63:0] s64_src1 = amo_src1;
  wire signed [63:0] s64_src2 = amo_src2;

  wire [63:0] amo_sum = amo_src1 + amo_src2;

  wire signed [63:0] cmp_s1 = is_word_amo ? {{32{s32_src1[31]}}, s32_src1} : s64_src1;
  wire signed [63:0] cmp_s2 = is_word_amo ? {{32{s32_src2[31]}}, s32_src2} : s64_src2;
  wire [63:0]        cmp_u1 = is_word_amo ? {32'd0, amo_src1[31:0]} : amo_src1;
  wire [63:0]        cmp_u2 = is_word_amo ? {32'd0, amo_src2[31:0]} : amo_src2;

  wire cmp_gt_s = (cmp_s1 > cmp_s2);
  wire cmp_gt_u = (cmp_u1 > cmp_u2);

  reg [XLEN-1:0] calc_amo_result;
  always @(*) begin
    case (s2_op_q[7:4])
      `AMO_SWAP: calc_amo_result = amo_src2;
      `AMO_ADD:  calc_amo_result = amo_sum;
      `AMO_AND:  calc_amo_result = amo_src1 & amo_src2;
      `AMO_OR:   calc_amo_result = amo_src1 | amo_src2;
      `AMO_XOR:  calc_amo_result = amo_src1 ^ amo_src2;
      `AMO_MAX:  calc_amo_result = cmp_gt_s ? amo_src1 : amo_src2;
      `AMO_MIN:  calc_amo_result = !cmp_gt_s ? amo_src1 : amo_src2;
      `AMO_MAXU: calc_amo_result = cmp_gt_u ? amo_src1 : amo_src2;
      `AMO_MINU: calc_amo_result = !cmp_gt_u ? amo_src1 : amo_src2;
      default:   calc_amo_result = amo_src2;
    endcase
  end

  wire [XLEN-1:0] amo_wdata_aligned = is_word_amo ? {2{calc_amo_result[31:0]}} : calc_amo_result;

  // Response Signals to WB (0 logic levels: direct flip-flop outputs)
  assign resp_valid_o      = buf_valid_q;
  assign resp_writes_fpr_o = buf_writes_fpr_q;
  assign resp_pc_o         = buf_pc_q;
  assign resp_rd_o         = buf_rd_q;
  assign resp_rdata_o      = buf_raw_data_q;

  // Unit Busy Signal: High while any stage holds valid operations or waiting for cache/amo
  // Driven strictly by registered state flags to prevent combinational feedthrough
  assign busy_o              = s1_valid_q || s2_valid_q || (agu_state_q != S_AGU_IDLE) || sc_failed_q;
  assign s1_valid_o          = s1_valid_q;
  assign s1_rd_o             = s1_rd_q;
  assign s1_is_fp_o          = (s1_op_q[7:4] == `AMO_FP);
  assign s2_valid_o          = s2_valid_q;
  assign s2_rd_o             = s2_rd_q;
  assign s2_is_fp_o          = (s2_op_q[7:4] == `AMO_FP);
  assign miss_or_amo_stall_o = s1_wait_q || s2_wait_q || (agu_state_q != S_AGU_IDLE) || sc_failed_q ||
                               (s1_valid_q && (s1_op_q[7:4] == `AMO_FP) && !s1_op_q[3]) ||
                               (s2_valid_q && (s2_op_q[7:4] == `AMO_FP) && !s2_op_q[3]);

  // --------------------------------------------------------------------------
  // Sequential Pipeline State Update
  // --------------------------------------------------------------------------
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s1_valid_q       <= 1'b0;
      s1_pc_q          <= {XLEN{1'b0}};
      s1_op_q          <= 8'd0;
      s1_byte_en_q     <= 8'd0;
      s1_rd_q          <= 5'd0;
      s1_vaddr_w_q     <= {(VADDR_WIDTH-2){1'b0}};
      s1_addr_lsb_q    <= 3'd0;
      s1_wdata_q       <= {XLEN{1'b0}};
      s1_orig_wdata_q  <= {XLEN{1'b0}};
      s1_wait_q        <= 1'b0;

      s2_valid_q             <= 1'b0;
      s2_pc_q                <= {XLEN{1'b0}};
      s2_is_uncached_q       <= 1'b0;
      s2_uncached_req_sent_q <= 1'b0;
      s2_op_q                <= 8'd0;
      s2_byte_en_q           <= 8'd0;
      s2_rd_q                <= 5'd0;
      s2_addr_lsb_q          <= 3'd0;
      s2_sign_byte_idx_q     <= 3'd0;
      s2_b0_keep_q           <= 1'b0;
      s2_b1_keep_q           <= 1'b0;
      s2_b1_sign_q           <= 1'b0;
      s2_h1_keep_q           <= 1'b0;
      s2_h1_sign_q           <= 1'b0;
      s2_w1_keep_q           <= 1'b0;
      s2_w1_sign_q           <= 1'b0;
      s2_w1_one_q            <= 1'b0;
      s2_paddr_w_q           <= {(PADDR_WIDTH-2){1'b0}};
      s2_wdata_q             <= {XLEN{1'b0}};
      s2_orig_wdata_q        <= {XLEN{1'b0}};
      s2_wait_q              <= 1'b0;

      buf_valid_q      <= 1'b0;
      buf_pc_q         <= {XLEN{1'b0}};
      buf_raw_data_q   <= 64'd0;
      buf_rd_q         <= 5'd0;
      buf_writes_fpr_q <= 1'b0;

      agu_state_q      <= S_AGU_IDLE;
      res_valid_q      <= 1'b0;
      res_paddr_w_q    <= {(PADDR_WIDTH-2){1'b0}};
      store_paddr_w_q  <= {(PADDR_WIDTH-2){1'b0}};
      amo_rdata_q      <= {XLEN{1'b0}};
      amo_wdata_q      <= {XLEN{1'b0}};
      sc_failed_q      <= 1'b0;
      sc_success_q     <= 1'b0;
    end else begin
      // Multi-hart coherence snoop invalidation: clear reservation if matching cache line
      if (snoop_inv_valid_i && (snoop_inv_paddr_w_i[PADDR_WIDTH-1:6] == res_paddr_w_q[PADDR_WIDTH-1:6])) begin
        res_valid_q <= 1'b0;
      end

      // WB buffered valid pulse auto-clearing
      buf_valid_q      <= 1'b0;
      buf_writes_fpr_q <= 1'b0;

      case (agu_state_q)
        S_AGU_IDLE: begin
          if (sc_failed_q) begin
            sc_failed_q <= 1'b0;
          end

          // MA2 Stage: Capture pre-aligned & sign-extended L1D or Uncached response into WB register
          if (s2_valid_q) begin
            if (s2_is_uncached_q && !s2_uncached_req_sent_q && uncached_req_ready_i) begin
              s2_uncached_req_sent_q <= 1'b1;
            end
            if (resp_valid_in) begin
              s2_valid_q             <= 1'b0;
              s2_uncached_req_sent_q <= 1'b0;
              s2_wait_q              <= 1'b0;
              s2_b0_keep_q           <= 1'b0;
              s2_b1_keep_q           <= 1'b0;
              s2_b1_sign_q           <= 1'b0;
              s2_h1_keep_q           <= 1'b0;
              s2_h1_sign_q           <= 1'b0;
              s2_w1_keep_q           <= 1'b0;
              s2_w1_sign_q           <= 1'b0;
              if (s2_op_q[7:4] == `AMO_LR) begin
                // LR sets reservation
                res_valid_q      <= 1'b1;
                res_paddr_w_q    <= s2_paddr_w_q;
                buf_valid_q      <= 1'b1;
                buf_pc_q         <= s2_pc_q;
                buf_raw_data_q   <= s2_next_buf_data;
                buf_rd_q         <= s2_rd_q;
                buf_writes_fpr_q <= 1'b0;
              end else if (s2_op_q[7:4] >= `AMO_SWAP && s2_op_q[7:4] <= `AMO_MAXU) begin
                // AMO read completed: latch raw read data and transition to ALU calculation step
                store_paddr_w_q <= s2_paddr_w_q;
                amo_rdata_q     <= amo_latch_data;
                agu_state_q     <= S_AGU_ALU;
              end else begin
                // Normal load or store completion
                if (s2_op_q[3]) begin
                  res_valid_q    <= 1'b0; // Any store clears reservation
                end
                buf_valid_q      <= 1'b1;
                buf_pc_q         <= s2_pc_q;
                buf_raw_data_q   <= s2_next_buf_data;
                buf_rd_q         <= s2_rd_q;
                buf_writes_fpr_q <= (s2_op_q[7:4] == `AMO_FP) && !s2_op_q[3];
              end
            end else begin
              s2_wait_q <= 1'b1;
            end
          end else begin
            s2_wait_q <= 1'b0;
          end

          // MA1 Stage: Dispatch to L1D and advance to MA2
          if (s1_valid_q) begin
            if (s1_is_sc) begin
              // SC: latch physical address and transition to check reservation next cycle
              store_paddr_w_q <= dtlb_paddr_w_i;
              agu_state_q     <= S_AGU_SC;
              s1_valid_q      <= 1'b0;
              s1_wait_q       <= 1'b0;
              s2_b0_keep_q    <= 1'b0;
              s2_b1_keep_q    <= 1'b0;
              s2_b1_sign_q    <= 1'b0;
              s2_h1_keep_q    <= 1'b0;
              s2_h1_sign_q    <= 1'b0;
              s2_w1_keep_q    <= 1'b0;
              s2_w1_sign_q    <= 1'b0;
            end else if (dtlb_hit_i && !s2_stays_busy) begin
              // Advance to MA2
              s2_valid_q             <= 1'b1;
              s2_pc_q                <= s1_pc_q;
              s2_is_uncached_q       <= is_uncached;
              s2_uncached_req_sent_q <= 1'b0;
              s2_op_q                <= s1_op_q;
              s2_byte_en_q           <= s1_byte_en_q;
              s2_rd_q                <= s1_rd_q;
              s2_addr_lsb_q          <= s1_addr_lsb_q;
              s2_sign_byte_idx_q     <= s1_sign_byte_idx;
              s2_b0_keep_q           <= s1_b0_keep;
              s2_b1_keep_q           <= s1_b1_keep;
              s2_b1_sign_q           <= s1_b1_sign;
              s2_h1_keep_q           <= s1_h1_keep;
              s2_h1_sign_q           <= s1_h1_sign;
              s2_w1_keep_q           <= s1_w1_keep;
              s2_w1_sign_q           <= s1_w1_sign;
              s2_w1_one_q            <= s1_w1_one;
              s2_paddr_w_q           <= dtlb_paddr_w_i;
              s2_wdata_q             <= s1_wdata_q;
              s2_orig_wdata_q        <= s1_orig_wdata_q;
              s2_wait_q              <= is_uncached || s1_is_alu_amo;
              s1_valid_q             <= 1'b0;
              s1_wait_q              <= 1'b0;
            end else begin
              s1_wait_q         <= 1'b1;
            end
          end else begin
            s1_wait_q <= 1'b0;
          end

          // ADDR Stage: Latch newly dispatched memory request
          if (req_valid_i && !s1_valid_q && !s2_valid_q && agu_state_q == S_AGU_IDLE && !sc_failed_q) begin
            s1_valid_q      <= 1'b1;
            s1_pc_q         <= req_pc_i;
            s1_op_q         <= req_op_i;
            s1_byte_en_q    <= calc_byte_en;
            s1_rd_q         <= req_rd_i;
            s1_vaddr_w_q    <= calc_vaddr[VADDR_WIDTH-1:2];
            s1_addr_lsb_q   <= calc_vaddr[2:0];
            s1_wdata_q      <= calc_aligned_wdata;
            s1_orig_wdata_q <= req_wdata_i;
            s1_wait_q       <= (req_op_i[7:4] != `AMO_NONE && req_op_i[7:4] != `AMO_LR && req_op_i[7:4] != `AMO_FP);
          end
        end

        S_AGU_SC: begin
          res_valid_q <= 1'b0; // SC always clears reservation
          if (sc_match) begin
            sc_success_q <= 1'b1;
            amo_rdata_q  <= 64'd0;
            amo_wdata_q  <= s1_wdata_q;
            s2_rd_q      <= s1_rd_q;
            s2_pc_q      <= s1_pc_q;
            agu_state_q  <= S_AGU_STORE;
          end else begin
            sc_failed_q      <= 1'b1;
            buf_valid_q      <= 1'b1;
            buf_pc_q         <= s1_pc_q;
            buf_rd_q         <= s1_rd_q;
            buf_raw_data_q   <= s2_next_buf_data;
            buf_writes_fpr_q <= 1'b0;
            agu_state_q      <= S_AGU_IDLE;
          end
        end

        S_AGU_ALU: begin
          // Calculate AMO ALU from registered amo_rdata_q and latch write data
          amo_wdata_q <= amo_wdata_aligned;
          agu_state_q <= S_AGU_STORE;
        end

        S_AGU_STORE: begin
          if (l1d_resp_valid_i) begin
            // AMO / SC store completed: latch response into WB output registers
            res_valid_q      <= 1'b0;
            sc_success_q     <= 1'b0;
            buf_valid_q      <= 1'b1;
            buf_pc_q         <= s2_pc_q;
            buf_rd_q         <= s2_rd_q;
            buf_raw_data_q   <= s2_next_buf_data;
            buf_writes_fpr_q <= 1'b0;
            agu_state_q      <= S_AGU_IDLE;
          end
        end
      endcase
    end
  end

  // Avoid unused warnings
  wire _unused = &{1'b0, dtlb_fault_i, l1d_req_ready_i, 1'b0};

endmodule

`default_nettype wire
