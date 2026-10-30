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
  parameter HART_ID         = 0,
  parameter PADDR_WIDTH     = `PADDR_WIDTH,
  parameter CACHE_LINE_BITS = `CACHE_LINE_BITS, // 512 bits = 64 bytes
  parameter CACHE_SIZE      = `L1I_SIZE_BYTES,   // 16384 bytes
  parameter WAYS            = `L1I_WAYS          // 2 <= WAYS <= 32
)(
  input  wire                       clk_i,
  input  wire                       rst_ni,
  input  wire                       stall_i,
  input  wire                       flush_i,

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

  // Per-way valid bit storage instantiated via sk_ram_ff
  wire [SETS-1:0] way_valid_out [0:WAYS-1];
  wire [WAYS-1:0] way_valid_wen;
  wire [SETS-1:0] way_valid_wdata [0:WAYS-1];

  genvar gw;
  generate
    for (gw = 0; gw < WAYS; gw = gw + 1) begin : gen_l1i_way_valid
      assign way_valid_wen[gw]   = fence_i_flush_i || (refill_resp_valid_i && !discard_refill_q && (victim_ptr_q == gw[WAY_BITS-1:0]));
      assign way_valid_wdata[gw] = fence_i_flush_i ? {SETS{1'b0}} : (way_valid_out[gw] | (64'd1 << req_index_q));
      sk_ram_ff #(
        .DATA_WIDTH (SETS),
        .ADDR_WIDTH (1),
        .DEPTH      (1),
        .ZERO_REG0  (0)
      ) u_way_valid_ram (
        .clk_i    (clk_i),
        .rst_ni   (rst_ni),
        .wen_i    (way_valid_wen[gw]),
        .waddr_i  (1'b0),
        .wdata_i  (way_valid_wdata[gw]),
        .wen1_i   (1'b0), .waddr1_i(1'b0), .wdata1_i({SETS{1'b0}}),
        .wen2_i   (1'b0), .waddr2_i(1'b0), .wdata2_i({SETS{1'b0}}),
        .raddr_a_i(1'b0),
        .rdata_a_o(way_valid_out[gw]),
        .raddr_b_i(1'b0),
        .rdata_b_o()
      );
    end
  endgenerate

  // Refill discard and pending redirect tracking on pipeline flush
  reg                    discard_refill_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                    pending_flush_req_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [PADDR_WIDTH-1:2]  pending_paddr_w_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      req_valid_q   <= 1'b0;
      req_offset_q  <= 4'd0;
      req_index_q   <= {INDEX_BITS{1'b0}};
      req_tag_q     <= {TAG_WIDTH{1'b0}};
      req_paddr_w_q <= {(PADDR_WIDTH-2){1'b0}};
    end else begin
      if (flush_i) begin
        if (miss_busy_q && (fetch_paddr_w_i[PADDR_WIDTH-1:6] == req_paddr_w_q[PADDR_WIDTH-1:6])) begin
          // Same cache line in-flight refill: update word offset to redirect target
          req_offset_q  <= req_word_offset;
          req_paddr_w_q <= fetch_paddr_w_i;
          req_valid_q   <= 1'b1;
        end else if (miss_busy_q) begin
          // Flush to different line while refilling: invalidate pipeline request
          req_valid_q   <= 1'b0;
        end else begin
          // Not currently refilling: evaluate redirect target immediately
          req_valid_q   <= 1'b1;
          req_offset_q  <= req_word_offset;
          req_index_q   <= req_index;
          req_tag_q     <= req_tag;
          req_paddr_w_q <= fetch_paddr_w_i;
        end
      end else if (pending_flush_req_q && !miss_busy_q) begin
        // Servicing pending redirect request after previous refill completed
        req_valid_q   <= 1'b1;
        req_offset_q  <= pending_paddr_w_q[5:2];
        req_index_q   <= pending_paddr_w_q[5+INDEX_BITS:6];
        req_tag_q     <= pending_paddr_w_q[PADDR_WIDTH-1:6+INDEX_BITS];
        req_paddr_w_q <= pending_paddr_w_q;
      end else if (!fetch_miss_o) begin
        req_valid_q   <= fetch_req_valid_i && !stall_i;
        req_offset_q  <= req_word_offset;
        req_index_q   <= req_index;
        req_tag_q     <= req_tag;
        req_paddr_w_q <= fetch_paddr_w_i;
      end
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

  wire ram_ren = (flush_i || (fetch_req_valid_i && !stall_i) || (pending_flush_req_q && !miss_busy_q));
  wire [INDEX_BITS-1:0] ram_raddr = (pending_flush_req_q && !miss_busy_q) ? pending_paddr_w_q[5+INDEX_BITS:6] : req_index;

  genvar w;
  generate
    for (w = 0; w < WAYS; w = w + 1) begin : gen_way
      wire way_wen = refill_resp_valid_i && !discard_refill_q && (victim_ptr_q == w[WAY_BITS-1:0]);

      // Tag Array (Stores 1-bit valid + TAG_WIDTH bits tag) - Distributed RAM for fast 1-cycle tag comparison
      sk_ram_dist #(
        .DATA_WIDTH (TAG_WIDTH + 1),
        .ADDR_WIDTH (INDEX_BITS),
        .DEPTH      (SETS)
      ) u_tag_ram (
        .clk_i   (clk_i),
        .rst_ni  (rst_ni),
        .wen_i   (way_wen || fence_i_flush_i),
        .waddr_i (way_wen ? req_paddr_w_q[5+INDEX_BITS:6] : req_index),
        .wdata_i (fence_i_flush_i ? {(TAG_WIDTH+1){1'b0}} : {1'b1, req_tag_q}),
        .ren_i   (ram_ren),
        .raddr_i (ram_raddr),
        .rdata_o (tag_rdata[w])
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
        .ren_i  (ram_ren),
        .raddr_i(ram_raddr),
        .rdata_o(data_rdata[w])
      );

      // Hit comparison for way w
      assign way_hit[w] = req_valid_q && way_valid_out[w][req_index_q] &&
                          (tag_rdata[w][TAG_WIDTH-1:0] == req_tag_q);
    end
  endgenerate

  // --------------------------------------------------------------------------
  // Hit Detection & Way Selection
  // --------------------------------------------------------------------------
  wire hit = |way_hit;

  wire [63:0] way_fetch64 [0:WAYS-1];
  genvar iway;
  generate
    for (iway = 0; iway < WAYS; iway = iway + 1) begin : gen_way_fetch64
      assign way_fetch64[iway] = data_rdata[iway][req_offset_q[3:1]*64 +: 64];
    end
  endgenerate

  wire [63:0] hit_fetch64 = ({64{way_hit[0]}} & way_fetch64[0]) |
                            ({64{way_hit[1]}} & way_fetch64[1]) |
                            ({64{way_hit[2]}} & way_fetch64[2]) |
                            ({64{way_hit[3]}} & way_fetch64[3]);

  wire        refill_valid_use = refill_resp_valid_i && !discard_refill_q;
  wire [63:0] refill_fetch64   = refill_line_data_i[req_offset_q[3:1]*64 +: 64];
  wire [63:0] eff_fetch64      = refill_valid_use ? refill_fetch64 : hit_fetch64;

  assign fetch_inst_o          = eff_fetch64;
  assign fetch_resp_valid_o    = ((hit && !miss_busy_q && !pending_flush_req_q) ||
                                  refill_valid_use) && !flush_i;
  assign fetch_miss_o          = ((req_valid_q && !hit) || miss_busy_q || pending_flush_req_q) &&
                                 !refill_valid_use;

  // --------------------------------------------------------------------------
  // Refill State Control & Replacement
  // --------------------------------------------------------------------------
  assign refill_req_valid_o    = req_valid_q && !hit && !miss_busy_q && !pending_flush_req_q;
  assign refill_line_paddr_w_o = {req_paddr_w_q[PADDR_WIDTH-1:6], 4'b0000}; // Line aligned

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      miss_busy_q         <= 1'b0;
      victim_ptr_q        <= {WAY_BITS{1'b0}};
      discard_refill_q    <= 1'b0;
      pending_flush_req_q <= 1'b0;
      pending_paddr_w_q   <= {(PADDR_WIDTH-2){1'b0}};
    end else begin
      if (fence_i_flush_i) begin
        // flush handled by sk_ram_ff
      end else if (flush_i && miss_busy_q && (fetch_paddr_w_i[PADDR_WIDTH-1:6] != req_paddr_w_q[PADDR_WIDTH-1:6])) begin
        discard_refill_q    <= 1'b1;
        pending_flush_req_q <= 1'b1;
        pending_paddr_w_q   <= fetch_paddr_w_i;
      end else if (flush_i && pending_flush_req_q) begin
        pending_paddr_w_q   <= fetch_paddr_w_i;
      end else if (pending_flush_req_q && !miss_busy_q) begin
        pending_flush_req_q <= 1'b0;
      end else if (refill_req_valid_o && refill_req_ready_i) begin
        miss_busy_q <= 1'b1;
      end else if (refill_resp_valid_i) begin
        miss_busy_q      <= 1'b0;
        discard_refill_q <= 1'b0;
        if (!discard_refill_q) begin
          victim_ptr_q   <= (victim_ptr_q == MAX_WAY_IDX[WAY_BITS-1:0]) ? {WAY_BITS{1'b0}} : victim_ptr_q + 1'b1;
        end
      end
    end
  end

endmodule
