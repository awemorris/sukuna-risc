// ============================================================================
// Sukuna-RISC: Parametric N-Way Set Associative L1 Data Cache (Verilog 2005)
// Complies with design-rule.md
// ============================================================================
// Features:
//   - Configurable N-way set associativity (WAYS: 2 <= N <= 32, default 4)
//   - Physical address width parameterizable (PADDR_WIDTH: 32 to 40 bits)
//   - Tag width dynamically determined: TAG_WIDTH = PADDR_WIDTH - INDEX_BITS - 6
//   - Word-aligned address interface (mem_paddr_w_i[PADDR_WIDTH-1:2])
//   - Byte enable vector (mem_byte_en_i[7:0]) replaces address lower 2/3 bits
//   - Direct byte write enable via sk_ram_bram wstrb_i
//   - Dirty line eviction (Writeback to L2) before refill
//   - Multi-Hart Snoop invalidate support
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_l1d_cache #(
  parameter XLEN            = `XLEN,             // 64-bit
  parameter PADDR_WIDTH     = `PADDR_WIDTH,
  parameter CACHE_LINE_BITS = `CACHE_LINE_BITS,  // 512 bits = 64 bytes
  parameter CACHE_SIZE      = `L1D_SIZE_BYTES,   // 16384 bytes
  parameter WAYS            = `L1D_WAYS          // 2 <= WAYS <= 32
)(
  input  wire                       clk_i,
  input  wire                       rst_ni,

  // Pipeline AGU/MA Interface (Word-aligned address & byte enable)
  input  wire                       mem_req_valid_i,
  input  wire                       mem_req_write_i,
  input  wire [2:0]                 mem_req_op_i,
  input  wire [7:0]                 mem_byte_en_i,     // Byte enable instead of raw address offset
  input  wire [PADDR_WIDTH-1:2]     mem_paddr_w_i,     // Word address (bits [1:0] omitted)
  input  wire [XLEN-1:0]            mem_wdata_i,
  output wire                       mem_req_ready_o,
  output wire                       mem_resp_valid_o,
  output wire [XLEN-1:0]            mem_rdata_o,
  output wire                       mem_miss_stall_o,

  // Coherence Snoop Port
  input  wire                       snoop_req_valid_i,
  input  wire [PADDR_WIDTH-1:2]     snoop_paddr_w_i,
  input  wire                       snoop_invalidate_i,
  output wire                       snoop_hit_o,

  // L2 Refill / Writeback Port
  output reg                        l2_req_valid_o,    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg                        l2_req_write_o,    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [PADDR_WIDTH-1:2]     l2_line_paddr_w_o, /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [CACHE_LINE_BITS-1:0] l2_wline_data_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  input  wire                       l2_req_ready_i,
  input  wire                       l2_resp_valid_i,
  input  wire [CACHE_LINE_BITS-1:0] l2_rline_data_i
);

  // --------------------------------------------------------------------------
  // Cache Geometry Calculations
  // --------------------------------------------------------------------------
  localparam SETS        = CACHE_SIZE / (WAYS * 64);
  localparam INDEX_BITS  = (SETS <= 8)   ? 3 :
                           (SETS <= 16)  ? 4 :
                           (SETS <= 32)  ? 5 :
                           (SETS <= 64)  ? 6 :
                           (SETS <= 128) ? 7 :
                           (SETS <= 256) ? 8 : 9;

  localparam OFFSET_BITS = 6;
  localparam TAG_WIDTH   = PADDR_WIDTH - INDEX_BITS - OFFSET_BITS;

  wire [3:0]            req_word_offset = mem_paddr_w_i[5:2];
  wire [INDEX_BITS-1:0] req_index       = mem_paddr_w_i[5+INDEX_BITS:6];
  wire [TAG_WIDTH-1:0]  req_tag         = mem_paddr_w_i[PADDR_WIDTH-1:6+INDEX_BITS];

  // Pipeline stage registers
  reg                    req_valid_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                    req_write_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [7:0]              req_byte_en_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [3:0]              req_offset_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [TAG_WIDTH-1:0]    req_tag_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [PADDR_WIDTH-1:2]  req_paddr_w_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0]         req_wdata_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // State Machine for Miss & Eviction
  localparam S_IDLE   = 2'd0;
  localparam S_EVICT  = 2'd1;
  localparam S_REFILL = 2'd2;

  localparam WAY_BITS = (WAYS <= 2)  ? 1 :
                        (WAYS <= 4)  ? 2 :
                        (WAYS <= 8)  ? 3 :
                        (WAYS <= 16) ? 4 : 5;

  reg [1:0]          state_q;      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [WAY_BITS-1:0] victim_ptr_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  localparam integer MAX_WAY_IDX = WAYS - 1;

  // Per-way valid bit register array (resets to 0)
  reg [SETS-1:0]     way_valid_q [0:WAYS-1];

  wire is_busy = (state_q != S_IDLE);

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      req_valid_q   <= 1'b0;
      req_write_q   <= 1'b0;
      req_byte_en_q <= 8'd0;
      req_offset_q  <= 4'd0;
      req_tag_q     <= {TAG_WIDTH{1'b0}};
      req_paddr_w_q <= {(PADDR_WIDTH-2){1'b0}};
      req_wdata_q   <= {XLEN{1'b0}};
    end else if (!is_busy) begin
      req_valid_q   <= mem_req_valid_i;
      req_write_q   <= mem_req_write_i;
      req_byte_en_q <= mem_byte_en_i;
      req_offset_q  <= req_word_offset;
      req_tag_q     <= req_tag;
      req_paddr_w_q <= mem_paddr_w_i;
      req_wdata_q   <= mem_wdata_i;
    end
  end

  // --------------------------------------------------------------------------
  // Tag and Data Arrays for WAYS
  // --------------------------------------------------------------------------
  wire [TAG_WIDTH+1:0]       tag_rdata [0:WAYS-1]; // {dirty, valid, tag}
  wire [CACHE_LINE_BITS-1:0] data_rdata [0:WAYS-1];
  wire [WAYS-1:0]            way_hit;

  // Snoop check signals
  wire [INDEX_BITS-1:0] snoop_index = snoop_paddr_w_i[5+INDEX_BITS:6];
  wire [TAG_WIDTH-1:0]  snoop_tag   = snoop_paddr_w_i[PADDR_WIDTH-1:6+INDEX_BITS];
  wire [WAYS-1:0]       snoop_way_hit;

  genvar w;
  generate
    for (w = 0; w < WAYS; w = w + 1) begin : gen_dway
      wire way_refill_wen = (state_q == S_REFILL) && l2_resp_valid_i && (victim_ptr_q == w[WAY_BITS-1:0]);
      wire way_write_hit  = (state_q == S_IDLE) && req_valid_q && req_write_q && way_hit[w];
      wire way_snoop_inv  = snoop_req_valid_i && snoop_invalidate_i && snoop_way_hit[w];

      // Tag Array ({dirty, valid, tag})
      sk_ram_bram #(
        .DATA_WIDTH     (TAG_WIDTH + 2),
        .ADDR_WIDTH     (INDEX_BITS),
        .DEPTH          (SETS),
        .PIPELINE_STAGES(1),
        .BYTE_WRITE_EN  (0)
      ) u_dtag_ram (
        .clk_i  (clk_i),
        .rst_ni (rst_ni),
        .wen_i  (way_refill_wen || way_write_hit || way_snoop_inv),
        .wstrb_i(1'b1),
        .waddr_i(way_snoop_inv ? snoop_index : (way_refill_wen ? req_paddr_w_q[5+INDEX_BITS:6] : req_index)),
        .wdata_i(way_snoop_inv ? {(TAG_WIDTH+2){1'b0}} :
                 way_write_hit ? {1'b1, 1'b1, req_tag_q} :
                 way_refill_wen ? {req_write_q, 1'b1, req_tag_q} : {(TAG_WIDTH+2){1'b0}}),
        .ren_i  (mem_req_valid_i || snoop_req_valid_i),
        .raddr_i(snoop_req_valid_i ? snoop_index : req_index),
        .rdata_o(tag_rdata[w])
      );

      // Data Array with Byte-Write Enable Support
      sk_ram_bram #(
        .DATA_WIDTH     (CACHE_LINE_BITS),
        .ADDR_WIDTH     (INDEX_BITS),
        .DEPTH          (SETS),
        .PIPELINE_STAGES(1),
        .BYTE_WRITE_EN  (1),
        .WE_WIDTH       (CACHE_LINE_BITS / 8) // 64 byte enables
      ) u_ddata_ram (
        .clk_i  (clk_i),
        .rst_ni (rst_ni),
        .wen_i  (way_refill_wen || way_write_hit),
        .wstrb_i(way_refill_wen ? {64{1'b1}} : {56'd0, req_byte_en_q} << (req_offset_q[3:1] * 8)),
        .waddr_i(way_refill_wen ? req_paddr_w_q[5+INDEX_BITS:6] : req_paddr_w_q[5+INDEX_BITS:6]),
        .wdata_i(way_refill_wen ? l2_rline_data_i : {8{req_wdata_q}}),
        .ren_i  (mem_req_valid_i),
        .raddr_i(req_index),
        .rdata_o(data_rdata[w])
      );

      assign way_hit[w]       = req_valid_q && way_valid_q[w][req_paddr_w_q[5+INDEX_BITS:6]] &&
                                (tag_rdata[w][TAG_WIDTH-1:0] == req_tag_q);
      assign snoop_way_hit[w] = way_valid_q[w][snoop_index] &&
                                (tag_rdata[w][TAG_WIDTH-1:0] == snoop_tag);
    end
  endgenerate

  // --------------------------------------------------------------------------
  // Hit Selection and Response
  // --------------------------------------------------------------------------
  wire hit = |way_hit;
  assign snoop_hit_o = |snoop_way_hit;

  reg [CACHE_LINE_BITS-1:0] hit_line_data;
  integer k;
  always @(*) begin
    hit_line_data = data_rdata[0];
    for (k = 0; k < WAYS; k = k + 1) begin
      if (way_hit[k]) hit_line_data = data_rdata[k];
    end
  end

  wire refill_done = (state_q == S_REFILL) && l2_resp_valid_i;
  wire [CACHE_LINE_BITS-1:0] eff_line_data = refill_done ? l2_rline_data_i : hit_line_data;

  wire [XLEN-1:0] line_dword [0:7];
  genvar di;
  generate
    for (di = 0; di < 8; di = di + 1) begin : gen_dwords
      assign line_dword[di] = eff_line_data[di*64 +: 64];
    end
  endgenerate

  assign mem_req_ready_o  = !is_busy;
  assign mem_resp_valid_o = (hit && !is_busy) || (refill_done && !req_write_q);
  assign mem_rdata_o      = line_dword[req_offset_q[3:1]];
  assign mem_miss_stall_o = ((req_valid_q && !hit) || is_busy) && !refill_done;

  // --------------------------------------------------------------------------
  // Eviction & Refill State Machine
  // --------------------------------------------------------------------------
  wire victim_dirty = way_valid_q[victim_ptr_q][req_paddr_w_q[5+INDEX_BITS:6]] &&
                      (tag_rdata[victim_ptr_q][TAG_WIDTH+1] == 1'b1);
  wire [TAG_WIDTH-1:0] victim_tag = tag_rdata[victim_ptr_q][TAG_WIDTH-1:0];

  integer wy;
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q           <= S_IDLE;
      victim_ptr_q      <= {WAY_BITS{1'b0}};
      l2_req_valid_o    <= 1'b0;
      l2_req_write_o    <= 1'b0;
      l2_line_paddr_w_o <= {(PADDR_WIDTH-2){1'b0}};
      l2_wline_data_o   <= {CACHE_LINE_BITS{1'b0}};
      for (wy = 0; wy < WAYS; wy = wy + 1) begin
        way_valid_q[wy] <= {SETS{1'b0}};
      end
    end else begin
      l2_req_valid_o <= 1'b0;

      // Snoop invalidation
      if (snoop_req_valid_i && snoop_invalidate_i) begin
        for (wy = 0; wy < WAYS; wy = wy + 1) begin
          if (snoop_way_hit[wy]) begin
            way_valid_q[wy][snoop_index] <= 1'b0;
          end
        end
      end

      case (state_q)
        S_IDLE: begin
          if (req_valid_q && !hit) begin
            if (victim_dirty) begin
              // Evict dirty line to L2
              l2_req_valid_o    <= 1'b1;
              l2_req_write_o    <= 1'b1;
              l2_line_paddr_w_o <= {victim_tag, req_paddr_w_q[5+INDEX_BITS:6], 4'b0000};
              l2_wline_data_o   <= data_rdata[victim_ptr_q];
              state_q           <= S_EVICT;
            end else begin
              // Read refill from L2
              l2_req_valid_o    <= 1'b1;
              l2_req_write_o    <= 1'b0;
              l2_line_paddr_w_o <= {req_paddr_w_q[PADDR_WIDTH-1:6], 4'b0000};
              state_q           <= S_REFILL;
            end
          end
        end

        S_EVICT: begin
          l2_req_valid_o    <= 1'b1;
          l2_req_write_o    <= 1'b1;
          if (l2_req_ready_i) begin
            // Evict completed, now issue read refill
            l2_req_write_o    <= 1'b0;
            l2_line_paddr_w_o <= {req_paddr_w_q[PADDR_WIDTH-1:6], 4'b0000};
            state_q           <= S_REFILL;
          end
        end

        S_REFILL: begin
          l2_req_valid_o <= 1'b1;
          l2_req_write_o <= 1'b0;
          if (l2_resp_valid_i) begin
            l2_req_valid_o <= 1'b0;
            way_valid_q[victim_ptr_q][req_paddr_w_q[5+INDEX_BITS:6]] <= 1'b1;
            victim_ptr_q   <= (victim_ptr_q == MAX_WAY_IDX[WAY_BITS-1:0]) ? {WAY_BITS{1'b0}} : victim_ptr_q + 1'b1;
            state_q        <= S_IDLE;
          end
        end

        default: state_q <= S_IDLE;
      endcase
    end
  end

endmodule
