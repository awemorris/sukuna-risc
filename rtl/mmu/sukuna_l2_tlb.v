// ============================================================================
// Shared L2-TLB (256 Entries, 4-Way Set Associative) (Verilog 2005)
// Complies with design-rule.md
// Multi-cycle shared TLB servicing misses from all threads' L1-TLBs
// Target: Distributed RAM (sk_ram_dist) for 4 ways x 64 sets
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_l2_tlb #(
  parameter NUM_ENTRIES = `L2_TLB_ENTRIES, // 256 entries
  parameter VADDR_WIDTH = `VADDR_WIDTH,
  parameter PADDR_WIDTH = `PADDR_WIDTH
)(
  input  wire                   clk_i,
  input  wire                   rst_ni,

  // Request Interface from L1-TLB Arbiter
  input  wire                   req_valid_i,
  input  wire [1:0]             req_hart_id_i,
  input  wire [VADDR_WIDTH-1:0] req_vaddr_i,
  output wire                   req_ready_o,

  // Response Interface to L1-TLBs
  output reg                    resp_valid_o,      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [1:0]             resp_hart_id_o,    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [PADDR_WIDTH-1:0] resp_paddr_o,      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg                    resp_fault_o,      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // Interface to Hardware Page Table Walker (on L2-TLB miss)
  output reg                    ptw_req_valid_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [1:0]             ptw_req_hart_id_o, /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [VADDR_WIDTH-1:0] ptw_req_vaddr_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  input  wire                   ptw_req_ready_i,
  input  wire                   ptw_resp_valid_i,
  input  wire [1:0]             ptw_resp_hart_id_i,
  input  wire [PADDR_WIDTH-1:0] ptw_resp_paddr_i,
  input  wire                   ptw_resp_fault_i,

  // Flush Interface (SFENCE.VMA)
  input  wire                   flush_i
);

  localparam NUM_WAYS = 4;
  localparam NUM_SETS = 64; // 64 sets x 4 ways = 256 entries
  localparam TAG_WIDTH = 21; // vaddr[38:18]
  localparam PPN_WIDTH = PADDR_WIDTH - 12; // 28 bits for 40-bit PADDR
  // Entry word: {valid(1), fault(1), tag(21), ppn(28)} = 51 bits
  localparam ENTRY_WIDTH = 1 + 1 + TAG_WIDTH + PPN_WIDTH;

  // --------------------------------------------------------------------------
  // State Machine
  // --------------------------------------------------------------------------
  localparam S_IDLE       = 3'd0;
  localparam S_TAG_READ   = 3'd1;
  localparam S_TAG_EVAL   = 3'd2;
  localparam S_PTW_WAIT   = 3'd3;

  reg [2:0] state_q;            /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // Latched request info
  reg [1:0]             hart_id_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [VADDR_WIDTH-1:0] vaddr_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [5:0]             set_idx_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [TAG_WIDTH-1:0]   vaddr_tag_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // Flush tracking: clear all valid bits when flush asserted
  reg [NUM_SETS-1:0]    way_valid_q [0:NUM_WAYS-1];
  reg [1:0]             repl_way_q  [0:NUM_SETS-1];

  assign req_ready_o = (state_q == S_IDLE);

  // --------------------------------------------------------------------------
  // 4 Ways of sk_ram_dist
  // --------------------------------------------------------------------------
  reg  [NUM_WAYS-1:0]       ram_wen;
  reg  [5:0]                ram_waddr;
  reg  [ENTRY_WIDTH-1:0]    ram_wdata;
  wire [5:0]                ram_raddr = (state_q == S_IDLE) ? req_vaddr_i[17:12] : set_idx_q;
  wire                      ram_ren   = (state_q == S_IDLE && req_valid_i);
  wire [ENTRY_WIDTH-1:0]    ram_rdata [0:NUM_WAYS-1];

  genvar w;
  generate
    for (w = 0; w < NUM_WAYS; w = w + 1) begin : gen_way_ram
      sk_ram_dist #(
        .DATA_WIDTH (ENTRY_WIDTH),
        .ADDR_WIDTH (6),
        .DEPTH      (NUM_SETS)
      ) u_way_ram (
        .clk_i      (clk_i),
        .rst_ni     (rst_ni),
        .wen_i      (ram_wen[w]),
        .waddr_i    (ram_waddr),
        .wdata_i    (ram_wdata),
        .ren_i      (ram_ren),
        .raddr_i    (ram_raddr),
        .rdata_o    (ram_rdata[w])
      );
    end
  endgenerate

  // --------------------------------------------------------------------------
  // Tag Matching & Hit Logic
  // --------------------------------------------------------------------------
  wire [NUM_WAYS-1:0] way_hit;
  wire [PPN_WIDTH-1:0] hit_ppn [0:NUM_WAYS-1];
  wire [NUM_WAYS-1:0] way_fault;

  generate
    for (w = 0; w < NUM_WAYS; w = w + 1) begin : gen_hit_check
      wire entry_valid = ram_rdata[w][ENTRY_WIDTH-1] && way_valid_q[w][set_idx_q];
      wire entry_fault = ram_rdata[w][ENTRY_WIDTH-2];
      wire [TAG_WIDTH-1:0] entry_tag = ram_rdata[w][ENTRY_WIDTH-3 -: TAG_WIDTH];
      wire [PPN_WIDTH-1:0] entry_ppn = ram_rdata[w][PPN_WIDTH-1:0];

      assign way_hit[w]   = entry_valid && (entry_tag == vaddr_tag_q);
      assign hit_ppn[w]   = entry_ppn;
      assign way_fault[w] = entry_fault;
    end
  endgenerate

  wire l2_hit = |way_hit;

  reg [PPN_WIDTH-1:0] selected_hit_ppn;
  reg                 selected_hit_fault;
  integer k;
  always @(*) begin
    selected_hit_ppn   = hit_ppn[0];
    selected_hit_fault = way_fault[0];
    for (k = 0; k < NUM_WAYS; k = k + 1) begin
      if (way_hit[k]) begin
        selected_hit_ppn   = hit_ppn[k];
        selected_hit_fault = way_fault[k];
      end
    end
  end

  // --------------------------------------------------------------------------
  // Sequential Control
  // --------------------------------------------------------------------------
  integer s, wy;
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q           <= S_IDLE;
      hart_id_q         <= 2'd0;
      vaddr_q           <= {VADDR_WIDTH{1'b0}};
      set_idx_q         <= 6'd0;
      vaddr_tag_q       <= {TAG_WIDTH{1'b0}};
      resp_valid_o      <= 1'b0;
      resp_hart_id_o    <= 2'd0;
      resp_paddr_o      <= {PADDR_WIDTH{1'b0}};
      resp_fault_o      <= 1'b0;
      ptw_req_valid_o   <= 1'b0;
      ptw_req_hart_id_o <= 2'd0;
      ptw_req_vaddr_o   <= {VADDR_WIDTH{1'b0}};
      ram_wen           <= {NUM_WAYS{1'b0}};
      ram_waddr         <= 6'd0;
      ram_wdata         <= {ENTRY_WIDTH{1'b0}};

      for (wy = 0; wy < NUM_WAYS; wy = wy + 1) begin
        way_valid_q[wy] <= {NUM_SETS{1'b0}};
      end
      for (s = 0; s < NUM_SETS; s = s + 1) begin
        repl_way_q[s]   <= 2'd0;
      end
    end else begin
      resp_valid_o    <= 1'b0;
      ram_wen         <= {NUM_WAYS{1'b0}};
      ptw_req_valid_o <= 1'b0;

      if (flush_i) begin
        for (wy = 0; wy < NUM_WAYS; wy = wy + 1) begin
          way_valid_q[wy] <= {NUM_SETS{1'b0}};
        end
        state_q <= S_IDLE;
      end else begin
        case (state_q)
          S_IDLE: begin
            if (req_valid_i) begin
              hart_id_q   <= req_hart_id_i;
              vaddr_q     <= req_vaddr_i;
              set_idx_q   <= req_vaddr_i[17:12];
              vaddr_tag_q <= req_vaddr_i[38:18];
              state_q     <= S_TAG_EVAL;
            end
          end

          S_TAG_EVAL: begin
            if (l2_hit) begin
              // L2-TLB Hit! Respond immediately
              resp_valid_o   <= 1'b1;
              resp_hart_id_o <= hart_id_q;
              resp_paddr_o   <= {selected_hit_ppn, vaddr_q[11:0]};
              resp_fault_o   <= selected_hit_fault;
              state_q        <= S_IDLE;
            end else begin
              // L2-TLB Miss: Request Hardware PTW
              ptw_req_valid_o   <= 1'b1;
              ptw_req_hart_id_o <= hart_id_q;
              ptw_req_vaddr_o   <= vaddr_q;
              state_q           <= S_PTW_WAIT;
            end
          end

          S_PTW_WAIT: begin
            if (ptw_resp_valid_i) begin
              // PTW finished walk: write entry into L2-TLB and respond
              ram_wen[repl_way_q[set_idx_q]] <= 1'b1;
              ram_waddr                      <= set_idx_q;
              ram_wdata                      <= {1'b1, ptw_resp_fault_i, vaddr_tag_q, ptw_resp_paddr_i[PADDR_WIDTH-1:12]};
              way_valid_q[repl_way_q[set_idx_q]][set_idx_q] <= 1'b1;
              repl_way_q[set_idx_q]          <= repl_way_q[set_idx_q] + 1'b1;

              // Forward response to L1-TLB
              resp_valid_o   <= 1'b1;
              resp_hart_id_o <= ptw_resp_hart_id_i;
              resp_paddr_o   <= ptw_resp_paddr_i;
              resp_fault_o   <= ptw_resp_fault_i;
              state_q        <= S_IDLE;
            end
          end

          default: state_q <= S_IDLE;
        endcase
      end
    end
  end

endmodule
