// ============================================================================
// Sukuna-RISC: Parametric N-Way Set Associative L1 Instruction Cache (Verilog 2005)
// Complies with design-rule.md
// ============================================================================
// Features:
//   - Configurable N-way set associativity (WAYS: 2 <= N <= 32, default 4)
//   - Physical address width parameterizable (PADDR_WIDTH: 32 to 40 bits)
//   - Tag width dynamically determined: TAG_WIDTH = PADDR_WIDTH - INDEX_BITS - 6
//   - Word-aligned address interface (fetch_paddr_w_i[PADDR_WIDTH-1:2], lower 2 bits omitted)
//   - Tag & Data arrays implemented using sk_ram_bram
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_l1i_cache #(
  parameter PADDR_WIDTH     = `PADDR_WIDTH,
  parameter CACHE_LINE_BITS = `CACHE_LINE_BITS, // 512 bits = 64 bytes
  parameter CACHE_SIZE      = `L1I_SIZE_BYTES,   // 16384 bytes
  parameter WAYS            = `L1I_WAYS          // 2 <= WAYS <= 32
)(
  input  wire                       clk_i,
  input  wire                       rst_ni,

  // Fetch Pipeline Interface (Word-aligned address: lower 2 bits truncated)
  input  wire                       fetch_req_valid_i,
  input  wire [PADDR_WIDTH-1:2]     fetch_paddr_w_i,
  output wire                       fetch_resp_valid_o,
  output wire [63:0]                fetch_inst_o,
  output wire                       fetch_miss_o,

  // L2 Refill Interface (Word-aligned line address)
  output wire                       refill_req_valid_o,
  output wire [PADDR_WIDTH-1:2]     refill_line_paddr_w_o,
  input  wire                       refill_req_ready_i,
  input  wire                       refill_resp_valid_i,
  input  wire [CACHE_LINE_BITS-1:0] refill_line_data_i,

  // Invalidate Interface (e.g. FENCE.I)
  input  wire                       fence_i_flush_i
);

  // --------------------------------------------------------------------------
  // Cache Geometry Calculations
  // --------------------------------------------------------------------------
  // Line size = 64 bytes -> OFFSET_BITS = 6
  // Word address omits 2 bits -> word offset within line is 4 bits [5:2]
  // Total sets S = CACHE_SIZE / (WAYS * 64)
  // For 16KB 4-way: S = 64 sets -> INDEX_BITS = 6
  // For 16KB 8-way: S = 32 sets -> INDEX_BITS = 5
  // For 16KB 2-way: S = 128 sets -> INDEX_BITS = 7
  localparam SETS        = CACHE_SIZE / (WAYS * 64);
  localparam INDEX_BITS  = (SETS <= 8)   ? 3 :
                           (SETS <= 16)  ? 4 :
                           (SETS <= 32)  ? 5 :
                           (SETS <= 64)  ? 6 :
                           (SETS <= 128) ? 7 :
                           (SETS <= 256) ? 8 : 9;

  localparam OFFSET_BITS = 6;
  localparam TAG_WIDTH   = PADDR_WIDTH - INDEX_BITS - OFFSET_BITS;

  // Address bit slicing on word address [PADDR_WIDTH-1:2]
  // Byte bits [1:0] are already removed.
  // Bits [5:2]: word offset within 64-byte line (4 bits -> 16 words of 32-bit)
  // Bits [5+INDEX_BITS : 6]: set index
  // Bits [PADDR_WIDTH-1 : 6+INDEX_BITS]: tag
  wire [3:0]            req_word_offset = fetch_paddr_w_i[5:2];
  wire [INDEX_BITS-1:0] req_index       = fetch_paddr_w_i[5+INDEX_BITS:6];
  wire [TAG_WIDTH-1:0]  req_tag         = fetch_paddr_w_i[PADDR_WIDTH-1:6+INDEX_BITS];

  // Pipeline registers for tag comparison stage
  reg                    req_valid_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [3:0]              req_offset_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [INDEX_BITS-1:0]   req_index_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [TAG_WIDTH-1:0]    req_tag_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [PADDR_WIDTH-1:2]  req_paddr_w_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // Per-way valid bit register array (resets to 0)
  reg [SETS-1:0]         way_valid_q [0:WAYS-1];

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      req_valid_q   <= 1'b0;
      req_offset_q  <= 4'd0;
      req_index_q   <= {INDEX_BITS{1'b0}};
      req_tag_q     <= {TAG_WIDTH{1'b0}};
      req_paddr_w_q <= {(PADDR_WIDTH-2){1'b0}};
    end else if (!fetch_miss_o) begin
      req_valid_q   <= fetch_req_valid_i;
      req_offset_q  <= req_word_offset;
      req_index_q   <= req_index;
      req_tag_q     <= req_tag;
      req_paddr_w_q <= fetch_paddr_w_i;
    end
  end

  // --------------------------------------------------------------------------
  // Tag and Data Arrays for WAYS
  // --------------------------------------------------------------------------
  wire [TAG_WIDTH:0]         tag_rdata [0:WAYS-1]; // {valid, tag}
  wire [CACHE_LINE_BITS-1:0] data_rdata [0:WAYS-1];
  wire [WAYS-1:0]            way_hit;

  localparam WAY_BITS = (WAYS <= 2)  ? 1 :
                        (WAYS <= 4)  ? 2 :
                        (WAYS <= 8)  ? 3 :
                        (WAYS <= 16) ? 4 : 5;

  localparam integer MAX_WAY_IDX = WAYS - 1;
  reg [WAY_BITS-1:0] victim_ptr_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                miss_busy_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  genvar w;
  generate
    for (w = 0; w < WAYS; w = w + 1) begin : gen_way
      wire way_wen = refill_resp_valid_i && (victim_ptr_q == w[WAY_BITS-1:0]);

      // Tag Array (Stores 1-bit valid + TAG_WIDTH bits tag)
      sk_ram_bram #(
        .DATA_WIDTH     (TAG_WIDTH + 1),
        .ADDR_WIDTH     (INDEX_BITS),
        .DEPTH          (SETS),
        .PIPELINE_STAGES(1),
        .BYTE_WRITE_EN  (0)
      ) u_tag_ram (
        .clk_i  (clk_i),
        .rst_ni (rst_ni),
        .wen_i  (way_wen || fence_i_flush_i),
        .wstrb_i(1'b1),
        .waddr_i(way_wen ? req_paddr_w_q[5+INDEX_BITS:6] : req_index),
        .wdata_i(fence_i_flush_i ? {(TAG_WIDTH+1){1'b0}} : {1'b1, req_tag_q}),
        .ren_i  (fetch_req_valid_i),
        .raddr_i(req_index),
        .rdata_o(tag_rdata[w])
      );

      // Data Array (Stores 512-bit cache line)
      sk_ram_bram #(
        .DATA_WIDTH     (CACHE_LINE_BITS),
        .ADDR_WIDTH     (INDEX_BITS),
        .DEPTH          (SETS),
        .PIPELINE_STAGES(1),
        .BYTE_WRITE_EN  (0)
      ) u_data_ram (
        .clk_i  (clk_i),
        .rst_ni (rst_ni),
        .wen_i  (way_wen),
        .wstrb_i(1'b1),
        .waddr_i(req_paddr_w_q[5+INDEX_BITS:6]),
        .wdata_i(refill_line_data_i),
        .ren_i  (fetch_req_valid_i),
        .raddr_i(req_index),
        .rdata_o(data_rdata[w])
      );

      // Hit comparison for way w
      assign way_hit[w] = req_valid_q && way_valid_q[w][req_index_q] &&
                          (tag_rdata[w][TAG_WIDTH-1:0] == req_tag_q);
    end
  endgenerate

  // --------------------------------------------------------------------------
  // Hit Detection & Way Selection
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

  wire [CACHE_LINE_BITS-1:0] eff_line_data = refill_resp_valid_i ? refill_line_data_i : hit_line_data;

  // Extract 64-bit instruction block (inst0, inst1) based on 32-bit word offset [5:2]
  wire [31:0] line_words32 [0:15];
  genvar wi;
  generate
    for (wi = 0; wi < 16; wi = wi + 1) begin : gen_words32
      assign line_words32[wi] = eff_line_data[wi*32 +: 32];
    end
  endgenerate

  wire [31:0] fetch_word0 = line_words32[req_offset_q];
  wire [31:0] fetch_word1 = (req_offset_q == 4'd15) ? 32'h00000013 : line_words32[req_offset_q + 4'd1];

  assign fetch_inst_o       = {fetch_word1, fetch_word0};
  assign fetch_resp_valid_o = (hit && !miss_busy_q) || refill_resp_valid_i;
  assign fetch_miss_o       = ((req_valid_q && !hit) || miss_busy_q) && !refill_resp_valid_i;

  // --------------------------------------------------------------------------
  // Refill State Control & Replacement
  // --------------------------------------------------------------------------
  assign refill_req_valid_o    = req_valid_q && !hit && !miss_busy_q;
  assign refill_line_paddr_w_o = {req_paddr_w_q[PADDR_WIDTH-1:6], 4'b0000}; // Line aligned

  integer wy;
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      miss_busy_q  <= 1'b0;
      victim_ptr_q <= {WAY_BITS{1'b0}};
      for (wy = 0; wy < WAYS; wy = wy + 1) begin
        way_valid_q[wy] <= {SETS{1'b0}};
      end
    end else begin
      if (fence_i_flush_i) begin
        for (wy = 0; wy < WAYS; wy = wy + 1) begin
          way_valid_q[wy] <= {SETS{1'b0}};
        end
      end else if (refill_req_valid_o) begin
        miss_busy_q <= 1'b1;
      end else if (refill_resp_valid_i) begin
        miss_busy_q                       <= 1'b0;
        way_valid_q[victim_ptr_q][req_index_q] <= 1'b1;
        victim_ptr_q                      <= (victim_ptr_q == MAX_WAY_IDX[WAY_BITS-1:0]) ? {WAY_BITS{1'b0}} : victim_ptr_q + 1'b1;
      end
    end
  end

endmodule
