// ============================================================================
// Sukuna-RISC: Dedicated 2-Cycle Memory Access Execution Unit (MA-EU) (Verilog 2005)
// Complies with design-rule.md
// Stage 1 (ADDR): Address calculation using sk_add and DTLB lookup request
//                 Lower 2 bits omitted, Byte-Enable vector generated
// Stage 2 (MA): Accesses dedicated thread L1D cache, handles LR/SC/AMO atomics
// ============================================================================

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

  // Address Calculation via shared library adder
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

  // Byte enable generation replacing address lower bits
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

  // Store data replication
  reg [XLEN-1:0] aligned_wdata;
  always @(*) begin
    case (req_op_i[1:0])
      2'b00: aligned_wdata = {8{req_wdata_i[7:0]}};
      2'b01: aligned_wdata = {4{req_wdata_i[15:0]}};
      2'b10: aligned_wdata = {2{req_wdata_i[31:0]}};
      2'b11: aligned_wdata = req_wdata_i;
    endcase
  end

  // Stage 1 Registers (ADDR)
  reg                     s1_valid_q;        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [7:0]               s1_op_q;           /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [7:0]               s1_byte_en_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [4:0]               s1_rd_q;           /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [VADDR_WIDTH-1:2]   s1_vaddr_w_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [2:0]               s1_addr_lsb_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]          s1_wdata_q;        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]          s1_orig_wdata_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

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

  wire [3:0] s1_amo_type = s1_op_q[7:4];
  wire is_lr             = (s1_amo_type == `AMO_LR);
  wire is_sc             = (s1_amo_type == `AMO_SC);
  wire is_alu_amo        = (s1_amo_type >= `AMO_SWAP && s1_amo_type <= `AMO_MAXU);
  wire sc_match          = res_valid_q && (res_paddr_w_q == store_paddr_w_q);

  // Load Response Formatting (Optimized 2-level alignment and sign extension)
  reg [63:0] aligned_rdata;
  always @(*) begin
    case (s1_addr_lsb_q)
      3'd0: aligned_rdata = l1d_rdata_i;
      3'd1: aligned_rdata = {8'd0,  l1d_rdata_i[63:8]};
      3'd2: aligned_rdata = {16'd0, l1d_rdata_i[63:16]};
      3'd3: aligned_rdata = {24'd0, l1d_rdata_i[63:24]};
      3'd4: aligned_rdata = {32'd0, l1d_rdata_i[63:32]};
      3'd5: aligned_rdata = {40'd0, l1d_rdata_i[63:40]};
      3'd6: aligned_rdata = {48'd0, l1d_rdata_i[63:48]};
      3'd7: aligned_rdata = {56'd0, l1d_rdata_i[63:56]};
    endcase
  end

  wire byte_sign = aligned_rdata[7]  & !s1_op_q[2];
  wire half_sign = aligned_rdata[15] & !s1_op_q[2];
  wire word_sign = aligned_rdata[31] & !s1_op_q[2];

  reg [XLEN-1:0] formatted_rdata;
  always @(*) begin
    case (s1_op_q[1:0])
      2'b00:   formatted_rdata = {{56{byte_sign}}, aligned_rdata[7:0]};
      2'b01:   formatted_rdata = {{48{half_sign}}, aligned_rdata[15:0]};
      2'b10:   formatted_rdata = {{32{word_sign}}, aligned_rdata[31:0]};
      default: formatted_rdata = aligned_rdata;
    endcase
  end

  // AMO ALU Operations (Operates on registered amo_rdata_q)
  wire is_word_amo = (s1_op_q[1:0] == 2'b10);
  wire [XLEN-1:0] amo_src1 = is_word_amo ? {{32{amo_rdata_q[31]}}, amo_rdata_q[31:0]} : amo_rdata_q;
  wire [XLEN-1:0] amo_src2 = s1_orig_wdata_q;

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
    case (s1_amo_type)
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

  // Format AMO store data back to 64-bit replicated bus
  wire [XLEN-1:0] amo_wdata_aligned = is_word_amo ? {2{calc_amo_result[31:0]}} : calc_amo_result;

  // L1D Request Controls
  assign dtlb_lookup_valid_o = s1_valid_q;
  assign dtlb_vaddr_w_o      = s1_vaddr_w_q;

  assign l1d_paddr_w_o       = (agu_state_q == S_AGU_STORE) ? store_paddr_w_q : dtlb_paddr_w_i;
  assign l1d_req_op_o        = s1_op_q[3:0];
  assign l1d_req_byte_en_o   = s1_byte_en_q;

  assign l1d_req_valid_o     = (agu_state_q == S_AGU_STORE) ? 1'b1 :
                               (s1_valid_q && dtlb_hit_i && !is_sc && !l1d_resp_valid_i);

  assign l1d_req_write_o     = (agu_state_q == S_AGU_STORE) ? 1'b1 :
                               (is_alu_amo || is_sc) ? 1'b0 : s1_op_q[3];

  assign l1d_wdata_o         = (agu_state_q == S_AGU_STORE) ? amo_wdata_q : s1_wdata_q;

  // Response Generation
  wire normal_resp_valid  = (agu_state_q == S_AGU_IDLE) && !is_alu_amo && !is_sc && l1d_resp_valid_i;
  wire sc_fail_resp_valid = (agu_state_q == S_AGU_IDLE) && sc_failed_q;
  wire store_resp_valid   = (agu_state_q == S_AGU_STORE) && l1d_resp_valid_i;

  assign resp_valid_o = normal_resp_valid || sc_fail_resp_valid || store_resp_valid;
  assign resp_rd_o    = s1_rd_q;
  assign resp_rdata_o = (agu_state_q == S_AGU_STORE) ? (sc_success_q ? 64'd0 : amo_rdata_q) :
                        sc_failed_q                   ? 64'd1 : formatted_rdata;

  // Busy Signal
  assign busy_o = (!resp_valid_o && (s1_valid_q || agu_state_q != S_AGU_IDLE || sc_failed_q)) || l1d_miss_stall_i;

  // Pipeline Registers and State
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

      case (agu_state_q)
        S_AGU_IDLE: begin
          if (sc_failed_q) begin
            sc_failed_q <= 1'b0;
            s1_valid_q  <= req_valid_i;
            s1_op_q     <= req_op_i;
            s1_byte_en_q<= calc_byte_en;
            s1_rd_q     <= req_rd_i;
            s1_vaddr_w_q<= calc_vaddr[VADDR_WIDTH-1:2];
            s1_addr_lsb_q <= calc_vaddr[2:0];
            s1_wdata_q  <= aligned_wdata;
            s1_orig_wdata_q <= req_wdata_i;
          end else if (s1_valid_q) begin
            if (is_sc) begin
              // SC: latch physical address and transition to S_AGU_SC to check reservation next cycle
              store_paddr_w_q <= dtlb_paddr_w_i;
              agu_state_q     <= S_AGU_SC;
            end else if (l1d_resp_valid_i) begin
              if (is_lr) begin
                // LR sets reservation
                res_valid_q   <= 1'b1;
                res_paddr_w_q <= dtlb_paddr_w_i;
                s1_valid_q    <= req_valid_i;
                s1_op_q       <= req_op_i;
                s1_byte_en_q  <= calc_byte_en;
                s1_rd_q       <= req_rd_i;
                s1_vaddr_w_q  <= calc_vaddr[VADDR_WIDTH-1:2];
                s1_addr_lsb_q <= calc_vaddr[2:0];
                s1_wdata_q    <= aligned_wdata;
                s1_orig_wdata_q <= req_wdata_i;
              end else if (is_alu_amo) begin
                // AMO read completed: latch read data and transition to ALU calculation step
                store_paddr_w_q <= dtlb_paddr_w_i;
                amo_rdata_q     <= formatted_rdata;
                agu_state_q     <= S_AGU_ALU;
              end else begin
                // Normal load/store
                if (s1_op_q[3]) begin
                  res_valid_q <= 1'b0; // Any store clears reservation
                end
                s1_valid_q    <= req_valid_i;
                s1_op_q       <= req_op_i;
                s1_byte_en_q  <= calc_byte_en;
                s1_rd_q       <= req_rd_i;
                s1_vaddr_w_q  <= calc_vaddr[VADDR_WIDTH-1:2];
                s1_addr_lsb_q <= calc_vaddr[2:0];
                s1_wdata_q    <= aligned_wdata;
                s1_orig_wdata_q <= req_wdata_i;
              end
            end
          end else begin
            s1_valid_q    <= req_valid_i;
            s1_op_q       <= req_op_i;
            s1_byte_en_q  <= calc_byte_en;
            s1_rd_q       <= req_rd_i;
            s1_vaddr_w_q  <= calc_vaddr[VADDR_WIDTH-1:2];
            s1_addr_lsb_q <= calc_vaddr[2:0];
            s1_wdata_q    <= aligned_wdata;
            s1_orig_wdata_q <= req_wdata_i;
          end
        end

        S_AGU_SC: begin
          res_valid_q <= 1'b0; // SC always clears reservation
          if (sc_match) begin
            sc_success_q <= 1'b1;
            amo_wdata_q  <= s1_wdata_q;
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
            s1_valid_q   <= req_valid_i;
            s1_op_q      <= req_op_i;
            s1_byte_en_q <= calc_byte_en;
            s1_rd_q      <= req_rd_i;
            s1_vaddr_w_q <= calc_vaddr[VADDR_WIDTH-1:2];
            s1_addr_lsb_q<= calc_vaddr[2:0];
            s1_wdata_q   <= aligned_wdata;
            s1_orig_wdata_q <= req_wdata_i;
          end
        end
      endcase
    end
  end

  // Avoid unused warnings
  wire _unused = &{1'b0, dtlb_fault_i, l1d_req_ready_i, 1'b0};

endmodule
