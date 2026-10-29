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
//   - Dirty line eviction to external memory (BIU/AXI4)
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

  output reg                        resp_valid_o,      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [3:0]                 resp_source_o,     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [CACHE_LINE_BITS-1:0] resp_rdata_o,      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // Memory interface to BIU (AXI4 bridge) on L2 miss/evict
  output reg                        mem_req_valid_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg                        mem_req_write_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [PADDR_WIDTH-1:2]     mem_req_paddr_w_o, /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [CACHE_LINE_BITS-1:0] mem_req_wdata_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
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
  reg                       req_valid_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg                       req_write_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [3:0]                 req_src_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [TAG_WIDTH-1:0]       req_tag_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [PADDR_WIDTH-1:2]     req_paddr_w_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [CACHE_LINE_BITS-1:0] req_wdata_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // State Machine
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

  // Per-way valid and dirty bit register arrays (reset to 0)
  reg [SETS-1:0] way_valid_q [0:WAYS-1];
  reg [SETS-1:0] way_dirty_q [0:WAYS-1];
  integer wy;

  wire is_busy = (state_q != S_IDLE);

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      req_valid_q   <= 1'b0;
      req_write_q   <= 1'b0;
      req_src_q     <= 4'd0;
      req_tag_q     <= {TAG_WIDTH{1'b0}};
      req_paddr_w_q <= {(PADDR_WIDTH-2){1'b0}};
      req_wdata_q   <= {CACHE_LINE_BITS{1'b0}};
    end else if (!is_busy) begin
      req_valid_q   <= req_valid_i;
      req_write_q   <= req_write_i;
      req_src_q     <= req_source_i;
      req_tag_q     <= req_tag;
      req_paddr_w_q <= req_paddr_w_i;
      req_wdata_q   <= req_wdata_i;
    end else if (state_q == S_REFILL && mem_resp_valid_i) begin
      req_valid_q   <= 1'b0;
    end
  end

  // --------------------------------------------------------------------------
  // Tag and Data Arrays for WAYS
  // --------------------------------------------------------------------------
  wire [TAG_WIDTH+1:0]       tag_rdata [0:WAYS-1]; // {dirty, valid, tag}
  wire [CACHE_LINE_BITS-1:0] data_rdata [0:WAYS-1];
  wire [WAYS-1:0]            way_hit;

  genvar w;
  generate
    for (w = 0; w < WAYS; w = w + 1) begin : gen_l2way
      wire way_refill_wen = (state_q == S_REFILL) && mem_resp_valid_i && (victim_ptr_q == w[WAY_BITS-1:0]);
      wire way_write_hit  = (state_q == S_IDLE) && req_valid_q && req_write_q && way_hit[w];

      // Tag Array ({dirty, valid, tag})
      sk_ram_bram #(
        .DATA_WIDTH     (TAG_WIDTH + 2),
        .ADDR_WIDTH     (INDEX_BITS),
        .DEPTH          (SETS),
        .PIPELINE_STAGES(1),
        .BYTE_WRITE_EN  (0)
      ) u_l2_tag_ram (
        .clk_i  (clk_i),
        .rst_ni (rst_ni),
        .wen_i  (way_refill_wen || way_write_hit),
        .wstrb_i(1'b1),
        .waddr_i(way_refill_wen ? req_paddr_w_q[5+INDEX_BITS:6] : req_index),
        .wdata_i(way_write_hit ? {1'b1, 1'b1, req_tag_q} :
                 way_refill_wen ? {req_write_q, 1'b1, req_tag_q} : {(TAG_WIDTH+2){1'b0}}),
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
        .wen_i  (way_refill_wen || way_write_hit),
        .wstrb_i(1'b1),
        .waddr_i(way_refill_wen ? req_paddr_w_q[5+INDEX_BITS:6] : req_paddr_w_q[5+INDEX_BITS:6]),
        .wdata_i(way_write_hit ? req_wdata_q : (way_refill_wen ? mem_resp_rdata_i : req_wdata_q)),
        .ren_i  (req_valid_i),
        .raddr_i(req_index),
        .rdata_o(data_rdata[w])
      );

      assign way_hit[w] = req_valid_q && way_valid_q[w][req_paddr_w_q[5+INDEX_BITS:6]] &&
                          (tag_rdata[w][TAG_WIDTH-1:0] == req_tag_q);
    end
  endgenerate

  wire hit = |way_hit;

  reg [CACHE_LINE_BITS-1:0] hit_data;
  integer k;
  always @(*) begin
    hit_data = data_rdata[0];
    for (k = 0; k < WAYS; k = k + 1) begin
      if (way_hit[k]) hit_data = data_rdata[k];
    end
  end

  assign req_ready_o = !is_busy;

  // --------------------------------------------------------------------------
  // Miss Eviction & Refill State Machine
  // --------------------------------------------------------------------------
  wire victim_valid = way_valid_q[victim_ptr_q][req_paddr_w_q[5+INDEX_BITS:6]];
  wire victim_dirty = victim_valid && way_dirty_q[victim_ptr_q][req_paddr_w_q[5+INDEX_BITS:6]];
  wire [TAG_WIDTH-1:0] victim_tag = tag_rdata[victim_ptr_q][TAG_WIDTH-1:0];

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q           <= S_IDLE;
      victim_ptr_q      <= {WAY_BITS{1'b0}};
      resp_valid_o      <= 1'b0;
      resp_source_o     <= 4'd0;
      resp_rdata_o      <= {CACHE_LINE_BITS{1'b0}};
      mem_req_valid_o   <= 1'b0;
      mem_req_write_o   <= 1'b0;
      mem_req_paddr_w_o <= {(PADDR_WIDTH-2){1'b0}};
      mem_req_wdata_o   <= {CACHE_LINE_BITS{1'b0}};
      for (wy = 0; wy < WAYS; wy = wy + 1) begin
        way_valid_q[wy] <= {SETS{1'b0}};
        way_dirty_q[wy] <= {SETS{1'b0}};
      end
    end else begin
      resp_valid_o    <= 1'b0;
      mem_req_valid_o <= 1'b0;

      case (state_q)
        S_IDLE: begin
          if (req_valid_q) begin
            if (hit) begin
              // Hit: for read, respond immediately; for write, written in same cycle
              if (req_write_q) begin
                for (wy = 0; wy < WAYS; wy = wy + 1) begin
                  if (way_hit[wy]) way_dirty_q[wy][req_paddr_w_q[5+INDEX_BITS:6]] <= 1'b1;
                end
              end else begin
                resp_valid_o  <= 1'b1;
                resp_source_o <= req_src_q;
                resp_rdata_o  <= hit_data;
              end
            end else begin
              // Miss
              if (victim_dirty) begin
                // Evict dirty victim line to memory
                mem_req_valid_o   <= 1'b1;
                mem_req_write_o   <= 1'b1;
                mem_req_paddr_w_o <= {victim_tag, req_paddr_w_q[5+INDEX_BITS:6], 4'b0000};
                mem_req_wdata_o   <= data_rdata[victim_ptr_q];
                state_q           <= S_EVICT;
              end else begin
                // Refill clean line from memory
                mem_req_valid_o   <= 1'b1;
                mem_req_write_o   <= 1'b0;
                mem_req_paddr_w_o <= {req_paddr_w_q[PADDR_WIDTH-1:6], 4'b0000};
                state_q           <= S_REFILL;
              end
            end
          end
        end

        S_EVICT: begin
          if (mem_req_ready_i) begin
            // Eviction accepted, now issue refill read
            mem_req_valid_o   <= 1'b1;
            mem_req_write_o   <= 1'b0;
            mem_req_paddr_w_o <= {req_paddr_w_q[PADDR_WIDTH-1:6], 4'b0000};
            state_q           <= S_REFILL;
          end
        end

        S_REFILL: begin
          if (mem_req_ready_i) begin
            mem_req_valid_o <= 1'b0;
          end
          if (mem_resp_valid_i) begin
            mem_req_valid_o <= 1'b0;
            way_valid_q[victim_ptr_q][req_paddr_w_q[5+INDEX_BITS:6]] <= 1'b1;
            way_dirty_q[victim_ptr_q][req_paddr_w_q[5+INDEX_BITS:6]] <= req_write_q;
            victim_ptr_q    <= (victim_ptr_q == MAX_WAY_IDX[WAY_BITS-1:0]) ? {WAY_BITS{1'b0}} : victim_ptr_q + 1'b1;

            if (!req_write_q) begin
              resp_valid_o  <= 1'b1;
              resp_source_o <= req_src_q;
              resp_rdata_o  <= mem_resp_rdata_i;
            end
            state_q <= S_IDLE;
          end
        end

        default: state_q <= S_IDLE;
      endcase
    end
  end

endmodule
