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
  output wire                       l2_req_valid_o,
  output wire                       l2_req_write_o,
  output wire [PADDR_WIDTH-1:2]     l2_line_paddr_w_o,
  output wire [CACHE_LINE_BITS-1:0] l2_wline_data_o,
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

  // Word address [PADDR_WIDTH-1:2] breakdown:
  // [5:2]: word index within line (4 bits -> 16 words of 32-bit = 8 doublewords)
  // [5+INDEX_BITS : 6]: set index
  // [PADDR_WIDTH-1 : 6+INDEX_BITS]: tag
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

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      req_valid_q   <= 1'b0;
      req_write_q   <= 1'b0;
      req_byte_en_q <= 8'd0;
      req_offset_q  <= 4'd0;
      req_tag_q     <= {TAG_WIDTH{1'b0}};
      req_paddr_w_q <= {(PADDR_WIDTH-2){1'b0}};
      req_wdata_q   <= {XLEN{1'b0}};
    end else if (!mem_miss_stall_o) begin
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

  localparam integer MAX_WAY_IDX = WAYS - 1;
  reg [4:0] victim_ptr_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg       miss_busy_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  genvar w;
  generate
    for (w = 0; w < WAYS; w = w + 1) begin : gen_dway
      wire way_refill_wen = refill_done && (victim_ptr_q == w[4:0]);
      wire way_write_hit  = req_valid_q && req_write_q && way_hit[w];

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
        .wen_i  (way_refill_wen || way_write_hit),
        .wstrb_i(1'b1),
        .waddr_i(way_refill_wen ? req_paddr_w_q[5+INDEX_BITS:6] : req_index),
        .wdata_i(way_write_hit ? {1'b1, 1'b1, req_tag_q} : {1'b0, 1'b1, req_tag_q}),
        .ren_i  (mem_req_valid_i),
        .raddr_i(req_index),
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

      assign way_hit[w] = req_valid_q && tag_rdata[w][TAG_WIDTH] &&
                          (tag_rdata[w][TAG_WIDTH-1:0] == req_tag_q);
    end
  endgenerate

  // --------------------------------------------------------------------------
  // Hit Selection and Response
  // --------------------------------------------------------------------------
  wire hit = |way_hit;

  reg [CACHE_LINE_BITS-1:0] hit_line_data;
  integer k;
  always @(*) begin
    hit_line_data = data_rdata[0];
    for (k = 0; k < WAYS; k = k + 1) begin
      if (way_hit[k]) hit_line_data = data_rdata[k];
    end
  end

  wire [XLEN-1:0] line_dword [0:7];
  genvar di;
  generate
    for (di = 0; di < 8; di = di + 1) begin : gen_dwords
      assign line_dword[di] = hit_line_data[di*64 +: 64];
    end
  endgenerate

  assign mem_req_ready_o  = !miss_busy_q;
  assign mem_resp_valid_o = hit && !miss_busy_q;
  assign mem_rdata_o      = line_dword[req_offset_q[3:1]];
  assign mem_miss_stall_o = req_valid_q && !hit;

  // --------------------------------------------------------------------------
  // Refill / Writeback to L2
  // --------------------------------------------------------------------------
  wire refill_done = l2_resp_valid_i;

  assign l2_req_valid_o    = mem_miss_stall_o && !miss_busy_q;
  assign l2_req_write_o    = 1'b0; // Clean on read miss (writeback queue in future)
  assign l2_line_paddr_w_o = {req_paddr_w_q[PADDR_WIDTH-1:6], 4'b0000};
  assign l2_wline_data_o   = hit_line_data;

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      miss_busy_q  <= 1'b0;
      victim_ptr_q <= 5'd0;
    end else begin
      if (l2_req_valid_o) begin
        miss_busy_q <= 1'b1;
      end else if (refill_done) begin
        miss_busy_q  <= 1'b0;
        victim_ptr_q <= (victim_ptr_q == MAX_WAY_IDX[4:0]) ? 5'd0 : victim_ptr_q + 5'd1;
      end
    end
  end

  assign snoop_hit_o = 1'b0;

endmodule
