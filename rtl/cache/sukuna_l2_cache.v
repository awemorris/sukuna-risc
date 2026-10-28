// ============================================================================
// Sukuna-RISC: Parametric N-Way Set Associative Shared L2 Cache (Verilog 2005)
// Complies with design-rule.md
// ============================================================================
// Features:
//   - Configurable N-way set associativity (WAYS: 2 <= N <= 32, default 8)
//   - Physical address width parameterizable (PADDR_WIDTH: 32 to 40 bits)
//   - Tag width dynamically determined: TAG_WIDTH = PADDR_WIDTH - INDEX_BITS - 6
//   - Word-aligned address interface (req_paddr_w_i[PADDR_WIDTH-1:2])
//   - Tag & Data arrays using sk_ram_bram
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_l2_cache #(
  parameter PADDR_WIDTH     = `PADDR_WIDTH,
  parameter CACHE_LINE_BITS = `CACHE_LINE_BITS, // 512 bits = 64 bytes
  parameter CACHE_SIZE      = `L2_SIZE_BYTES,    // 256KB = 262144 bytes
  parameter WAYS            = `L2_WAYS           // 2 <= WAYS <= 32
)(
  input  wire                       clk_i,
  input  wire                       rst_ni,

  // Interface from L1 Subsystem (L2 Arbiter)
  input  wire                       req_valid_i,
  input  wire                       req_write_i,
  input  wire [3:0]                 req_source_i,
  input  wire [PADDR_WIDTH-1:2]     req_paddr_w_i,     // Word address (bits [1:0] omitted)
  input  wire [CACHE_LINE_BITS-1:0] req_wdata_i,
  output wire                       req_ready_o,

  output wire                       resp_valid_o,
  output wire [3:0]                 resp_source_o,
  output wire [CACHE_LINE_BITS-1:0] resp_rdata_o,

  // Memory interface to BIU (AXI4 bridge) on L2 miss/evict
  output wire                       mem_req_valid_o,
  output wire                       mem_req_write_o,
  output wire [PADDR_WIDTH-1:2]     mem_req_paddr_w_o,
  output wire [CACHE_LINE_BITS-1:0] mem_req_wdata_o,
  input  wire                       mem_req_ready_i,

  input  wire                       mem_resp_valid_i,
  input  wire [CACHE_LINE_BITS-1:0] mem_resp_rdata_i
);

  // --------------------------------------------------------------------------
  // Cache Geometry Calculations
  // --------------------------------------------------------------------------
  localparam SETS        = CACHE_SIZE / (WAYS * 64);
  localparam INDEX_BITS  = (SETS <= 16)  ? 4 :
                           (SETS <= 32)  ? 5 :
                           (SETS <= 64)  ? 6 :
                           (SETS <= 128) ? 7 :
                           (SETS <= 256) ? 8 :
                           (SETS <= 512) ? 9 : 10;

  localparam OFFSET_BITS = 6;
  localparam TAG_WIDTH   = PADDR_WIDTH - INDEX_BITS - OFFSET_BITS;

  wire [INDEX_BITS-1:0] req_index = req_paddr_w_i[5+INDEX_BITS:6];
  wire [TAG_WIDTH-1:0]  req_tag   = req_paddr_w_i[PADDR_WIDTH-1:6+INDEX_BITS];

  // Pipeline stage registers
  reg                   req_valid_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                   req_write_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [3:0]             req_src_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [TAG_WIDTH-1:0]   req_tag_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [PADDR_WIDTH-1:2] req_paddr_w_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      req_valid_q   <= 1'b0;
      req_write_q   <= 1'b0;
      req_src_q     <= 4'd0;
      req_tag_q     <= {TAG_WIDTH{1'b0}};
      req_paddr_w_q <= {(PADDR_WIDTH-2){1'b0}};
    end else if (!l2_miss) begin
      req_valid_q   <= req_valid_i;
      req_write_q   <= req_write_i;
      req_src_q     <= req_source_i;
      req_tag_q     <= req_tag;
      req_paddr_w_q <= req_paddr_w_i;
    end
  end

  // --------------------------------------------------------------------------
  // Tag and Data Arrays for WAYS
  // --------------------------------------------------------------------------
  wire [TAG_WIDTH:0]         tag_rdata [0:WAYS-1]; // {valid, tag}
  wire [CACHE_LINE_BITS-1:0] data_rdata [0:WAYS-1];
  wire [WAYS-1:0]            way_hit;

  localparam integer MAX_WAY_IDX = WAYS - 1;
  reg [4:0] victim_ptr_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg       miss_busy_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  genvar w;
  generate
    for (w = 0; w < WAYS; w = w + 1) begin : gen_l2way
      wire way_wen = mem_resp_valid_i && (victim_ptr_q == w[4:0]);

      // Tag Array
      sk_ram_bram #(
        .DATA_WIDTH     (TAG_WIDTH + 1),
        .ADDR_WIDTH     (INDEX_BITS),
        .DEPTH          (SETS),
        .PIPELINE_STAGES(1),
        .BYTE_WRITE_EN  (0)
      ) u_l2_tag_ram (
        .clk_i  (clk_i),
        .rst_ni (rst_ni),
        .wen_i  (way_wen),
        .wstrb_i(1'b1),
        .waddr_i(way_wen ? req_paddr_w_q[5+INDEX_BITS:6] : req_index),
        .wdata_i({1'b1, req_tag_q}),
        .ren_i  (req_valid_i),
        .raddr_i(req_index),
        .rdata_o(tag_rdata[w])
      );

      // Data Array
      sk_ram_bram #(
        .DATA_WIDTH     (CACHE_LINE_BITS),
        .ADDR_WIDTH     (INDEX_BITS),
        .DEPTH          (SETS),
        .PIPELINE_STAGES(1),
        .BYTE_WRITE_EN  (0)
      ) u_l2_data_ram (
        .clk_i  (clk_i),
        .rst_ni (rst_ni),
        .wen_i  (way_wen),
        .wstrb_i(1'b1),
        .waddr_i(req_paddr_w_q[5+INDEX_BITS:6]),
        .wdata_i(mem_resp_rdata_i),
        .ren_i  (req_valid_i),
        .raddr_i(req_index),
        .rdata_o(data_rdata[w])
      );

      assign way_hit[w] = req_valid_q && tag_rdata[w][TAG_WIDTH] &&
                          (tag_rdata[w][TAG_WIDTH-1:0] == req_tag_q);
    end
  endgenerate

  wire hit = |way_hit;
  wire l2_miss = req_valid_q && !hit;

  reg [CACHE_LINE_BITS-1:0] hit_data;
  integer k;
  always @(*) begin
    hit_data = data_rdata[0];
    for (k = 0; k < WAYS; k = k + 1) begin
      if (way_hit[k]) hit_data = data_rdata[k];
    end
  end

  assign req_ready_o   = !miss_busy_q;
  assign resp_valid_o  = hit && !miss_busy_q;
  assign resp_source_o = req_src_q;
  assign resp_rdata_o  = hit_data;

  // Refill interface to external memory
  assign mem_req_valid_o   = l2_miss && !miss_busy_q;
  assign mem_req_write_o   = 1'b0;
  assign mem_req_paddr_w_o = {req_paddr_w_q[PADDR_WIDTH-1:6], 4'b0000};
  assign mem_req_wdata_o   = hit_data;

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      miss_busy_q  <= 1'b0;
      victim_ptr_q <= 5'd0;
    end else begin
      if (mem_req_valid_o) begin
        miss_busy_q <= 1'b1;
      end else if (mem_resp_valid_i) begin
        miss_busy_q  <= 1'b0;
        victim_ptr_q <= (victim_ptr_q == MAX_WAY_IDX[4:0]) ? 5'd0 : victim_ptr_q + 5'd1;
      end
    end
  end

endmodule
