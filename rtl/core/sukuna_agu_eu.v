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
  input  wire [7:0]             req_op_i,
  input  wire [4:0]             req_rd_i,
  input  wire [XLEN-1:0]        req_base_i,
  input  wire [XLEN-1:0]        req_offset_i,
  input  wire [XLEN-1:0]        req_wdata_i,
  output wire                   busy_o,

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

  // Output to Writeback Stage
  output wire                   resp_valid_o,
  output wire [4:0]             resp_rd_o,
  output wire [XLEN-1:0]        resp_rdata_o
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
  reg [7:0]               s1_op_q;           /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [4:0]               s1_rd_q;           /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [VADDR_WIDTH-1:2]   s1_vaddr_w_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [2:0]               s1_addr_lsb_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [7:0]               s1_byte_en_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]          s1_wdata_q;        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]          s1_orig_wdata_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

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

  // L1D Request Driving (driven during MA1 or during AMO STORE)
  assign l1d_paddr_w_o       = (agu_state_q == S_AGU_STORE) ? store_paddr_w_q : dtlb_paddr_w_i;
  assign l1d_req_op_o        = s1_op_q[3:0];
  assign l1d_req_byte_en_o   = s1_byte_en_q;
  assign l1d_wdata_o         = (agu_state_q == S_AGU_STORE) ? amo_wdata_q : s1_wdata_q;

  assign l1d_req_valid_o     = (agu_state_q == S_AGU_STORE) ? 1'b1 :
                               (s1_valid_q && dtlb_hit_i && !s1_is_sc);
  assign l1d_req_write_o     = (agu_state_q == S_AGU_STORE) ? 1'b1 :
                               (s1_is_alu_amo || s1_is_sc) ? 1'b0 : s1_op_q[3];

  // Stage 2 Registers (MA1 -> MA2)
  reg                     s2_valid_q;        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [7:0]               s2_op_q;           /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [4:0]               s2_rd_q;           /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [2:0]               s2_addr_lsb_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [PADDR_WIDTH-1:2]   s2_paddr_w_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]          s2_orig_wdata_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // --------------------------------------------------------------------------
  // Stage 3: MA2 (L1D BRAM Read Latency & Output Holding Buffer)
  // --------------------------------------------------------------------------
  // Output holding buffer: Latches raw L1D output into a clean register
  // before entering wide rotation and sign extension in the subsequent cycle
  reg                     buf_valid_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [63:0]              buf_raw_data_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [4:0]               buf_rd_q;          /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [7:0]               buf_op_q;          /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [2:0]               buf_addr_lsb_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // --------------------------------------------------------------------------
  // WB Connection: Direct Alignment Rotator & Sign Extension
  // --------------------------------------------------------------------------
  reg [63:0] aligned_rdata;
  always @(*) begin
    case (buf_addr_lsb_q)
      3'd0: aligned_rdata = buf_raw_data_q;
      3'd1: aligned_rdata = {8'd0,  buf_raw_data_q[63:8]};
      3'd2: aligned_rdata = {16'd0, buf_raw_data_q[63:16]};
      3'd3: aligned_rdata = {24'd0, buf_raw_data_q[63:24]};
      3'd4: aligned_rdata = {32'd0, buf_raw_data_q[63:32]};
      3'd5: aligned_rdata = {40'd0, buf_raw_data_q[63:40]};
      3'd6: aligned_rdata = {48'd0, buf_raw_data_q[63:48]};
      3'd7: aligned_rdata = {56'd0, buf_raw_data_q[63:56]};
    endcase
  end

  wire byte_sign = aligned_rdata[7]  & !buf_op_q[2];
  wire half_sign = aligned_rdata[15] & !buf_op_q[2];
  wire word_sign = aligned_rdata[31] & !buf_op_q[2];

  reg [XLEN-1:0] formatted_rdata;
  always @(*) begin
    case (buf_op_q[1:0])
      2'b00:   formatted_rdata = {{56{byte_sign}}, aligned_rdata[7:0]};
      2'b01:   formatted_rdata = {{48{half_sign}}, aligned_rdata[15:0]};
      2'b10:   formatted_rdata = {{32{word_sign}}, aligned_rdata[31:0]};
      default: formatted_rdata = aligned_rdata;
    endcase
  end

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

  // Response Signals to WB
  wire sc_fail_resp_valid = (agu_state_q == S_AGU_IDLE) && sc_failed_q;
  reg  store_resp_valid_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      store_resp_valid_q <= 1'b0;
    end else begin
      store_resp_valid_q <= (agu_state_q == S_AGU_STORE) && l1d_resp_valid_i;
    end
  end

  assign resp_valid_o = buf_valid_q || sc_fail_resp_valid || store_resp_valid_q;

  assign resp_rd_o    = buf_valid_q         ? buf_rd_q :
                        sc_fail_resp_valid  ? s1_rd_q  : s2_rd_q;
  assign resp_rdata_o = buf_valid_q         ? formatted_rdata :
                        sc_fail_resp_valid  ? 64'd1 :
                        sc_success_q        ? 64'd0 : amo_rdata_q;

  // Unit Busy Signal: High while any stage holds valid operations or waiting for cache/amo
  // Driven strictly by registered state flags to prevent combinational feedthrough
  assign busy_o = s1_valid_q || s2_valid_q || (agu_state_q != S_AGU_IDLE) || sc_failed_q || l1d_miss_stall_i;

  // --------------------------------------------------------------------------
  // Sequential Pipeline State Update
  // --------------------------------------------------------------------------
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s1_valid_q      <= 1'b0;
      s1_op_q         <= 8'd0;
      s1_byte_en_q    <= 8'd0;
      s1_rd_q         <= 5'd0;
      s1_vaddr_w_q    <= {(VADDR_WIDTH-2){1'b0}};
      s1_addr_lsb_q   <= 3'd0;
      s1_wdata_q      <= {XLEN{1'b0}};
      s1_orig_wdata_q <= {XLEN{1'b0}};

      s2_valid_q      <= 1'b0;
      s2_op_q         <= 8'd0;
      s2_rd_q         <= 5'd0;
      s2_addr_lsb_q   <= 3'd0;
      s2_paddr_w_q    <= {(PADDR_WIDTH-2){1'b0}};
      s2_orig_wdata_q <= {XLEN{1'b0}};

      buf_valid_q     <= 1'b0;
      buf_raw_data_q  <= 64'd0;
      buf_rd_q        <= 5'd0;
      buf_op_q        <= 8'd0;
      buf_addr_lsb_q  <= 3'd0;

      agu_state_q     <= S_AGU_IDLE;
      res_valid_q     <= 1'b0;
      res_paddr_w_q   <= {(PADDR_WIDTH-2){1'b0}};
      store_paddr_w_q <= {(PADDR_WIDTH-2){1'b0}};
      amo_rdata_q     <= {XLEN{1'b0}};
      amo_wdata_q     <= {XLEN{1'b0}};
      sc_failed_q     <= 1'b0;
      sc_success_q    <= 1'b0;
    end else begin
      // Multi-hart coherence snoop invalidation: clear reservation if matching cache line
      if (snoop_inv_valid_i && (snoop_inv_paddr_w_i[PADDR_WIDTH-1:6] == res_paddr_w_q[PADDR_WIDTH-1:6])) begin
        res_valid_q <= 1'b0;
      end

      // WB buffered valid pulse auto-clearing
      buf_valid_q <= 1'b0;

      case (agu_state_q)
        S_AGU_IDLE: begin
          if (sc_failed_q) begin
            sc_failed_q <= 1'b0;
          end

          // MA2 Stage: Capture L1D response into holding buffer
          if (s2_valid_q && l1d_resp_valid_i) begin
            s2_valid_q <= 1'b0;
            if (s2_op_q[7:4] == `AMO_LR) begin
              // LR sets reservation
              res_valid_q    <= 1'b1;
              res_paddr_w_q  <= s2_paddr_w_q;
              buf_valid_q    <= 1'b1;
              buf_raw_data_q <= l1d_rdata_i;
              buf_rd_q       <= s2_rd_q;
              buf_op_q       <= s2_op_q;
              buf_addr_lsb_q <= s2_addr_lsb_q;
            end else if (s2_op_q[7:4] >= `AMO_SWAP && s2_op_q[7:4] <= `AMO_MAXU) begin
              // AMO read completed: latch raw read data and transition to ALU calculation step
              store_paddr_w_q <= s2_paddr_w_q;
              amo_rdata_q     <= amo_latch_data;
              agu_state_q     <= S_AGU_ALU;
            end else begin
              // Normal load or store completion
              if (s2_op_q[3]) begin
                res_valid_q  <= 1'b0; // Any store clears reservation
              end
              buf_valid_q    <= 1'b1;
              buf_raw_data_q <= l1d_rdata_i;
              buf_rd_q       <= s2_rd_q;
              buf_op_q       <= s2_op_q;
              buf_addr_lsb_q <= s2_addr_lsb_q;
            end
          end

          // MA1 Stage: Dispatch to L1D and advance to MA2
          if (s1_valid_q) begin
            if (s1_is_sc) begin
              // SC: latch physical address and transition to check reservation next cycle
              store_paddr_w_q <= dtlb_paddr_w_i;
              agu_state_q     <= S_AGU_SC;
              s1_valid_q      <= 1'b0;
            end else if (dtlb_hit_i && !s2_valid_q) begin
              // Advance to MA2
              s2_valid_q      <= 1'b1;
              s2_op_q         <= s1_op_q;
              s2_rd_q         <= s1_rd_q;
              s2_addr_lsb_q   <= s1_addr_lsb_q;
              s2_paddr_w_q    <= dtlb_paddr_w_i;
              s2_orig_wdata_q <= s1_orig_wdata_q;
              s1_valid_q      <= 1'b0;
            end
          end

          // ADDR Stage: Latch newly dispatched memory request
          if (req_valid_i && !s1_valid_q && !s2_valid_q && agu_state_q == S_AGU_IDLE && !sc_failed_q) begin
            s1_valid_q      <= 1'b1;
            s1_op_q         <= req_op_i;
            s1_byte_en_q    <= calc_byte_en;
            s1_rd_q         <= req_rd_i;
            s1_vaddr_w_q    <= calc_vaddr[VADDR_WIDTH-1:2];
            s1_addr_lsb_q   <= calc_vaddr[2:0];
            s1_wdata_q      <= calc_aligned_wdata;
            s1_orig_wdata_q <= req_wdata_i;
          end
        end

        S_AGU_SC: begin
          res_valid_q <= 1'b0; // SC always clears reservation
          if (sc_match) begin
            sc_success_q <= 1'b1;
            amo_wdata_q  <= s1_wdata_q;
            s2_rd_q      <= s1_rd_q;
            agu_state_q  <= S_AGU_STORE;
          end else begin
            sc_failed_q  <= 1'b1;
            agu_state_q  <= S_AGU_IDLE;
          end
        end

        S_AGU_ALU: begin
          // Calculate AMO ALU from registered amo_rdata_q and latch write data
          amo_wdata_q <= amo_wdata_aligned;
          agu_state_q <= S_AGU_STORE;
        end

        S_AGU_STORE: begin
          if (l1d_resp_valid_i) begin
            // AMO / SC store completed
            res_valid_q  <= 1'b0;
            sc_success_q <= 1'b0;
            agu_state_q  <= S_AGU_IDLE;
          end
        end
      endcase
    end
  end

  // Avoid unused warnings
  wire _unused = &{1'b0, dtlb_fault_i, l1d_req_ready_i, 1'b0};

endmodule

`default_nettype wire
