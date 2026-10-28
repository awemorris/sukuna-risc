// ============================================================================
// Hardware Page Table Walker (PTW) (Verilog 2005)
// Complies with design-rule.md
// Traverses RISC-V Sv39 3-level page tables in memory on L2-TLB misses
// Supports 4KB standard pages, 2MB megapages, and 1GB gigapages
// Word-aligned memory interface (bits [1:0] omitted)
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_ptw #(
  parameter VADDR_WIDTH = `VADDR_WIDTH,
  parameter PADDR_WIDTH = `PADDR_WIDTH,
  parameter XLEN        = `XLEN
)(
  input  wire                   clk_i,
  input  wire                   rst_ni,

  // Interface from L2-TLB
  input  wire                   req_valid_i,
  input  wire [1:0]             req_hart_id_i,
  input  wire [VADDR_WIDTH-1:0] req_vaddr_i,
  output wire                   req_ready_o,

  output reg                    resp_valid_o,      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [1:0]             resp_hart_id_o,    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [PADDR_WIDTH-1:0] resp_paddr_o,      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg                    resp_fault_o,      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // Base page table registers (satp) per Hart
  input  wire [XLEN-1:0]        satp_hart0_i,
  input  wire [XLEN-1:0]        satp_hart1_i,
  input  wire [XLEN-1:0]        satp_hart2_i,

  // Memory interface to L2 cache / Interconnect for PTE reads (word-aligned)
  output reg                    mem_req_valid_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [PADDR_WIDTH-1:2] mem_req_paddr_w_o, /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  input  wire                   mem_req_ready_i,
  input  wire                   mem_resp_valid_i,
  input  wire [XLEN-1:0]        mem_resp_data_i
);

  // --------------------------------------------------------------------------
  // State Machine Definition
  // --------------------------------------------------------------------------
  localparam S_IDLE    = 3'd0;
  localparam S_L2_REQ  = 3'd1;
  localparam S_L2_WAIT = 3'd2;
  localparam S_L1_REQ  = 3'd3;
  localparam S_L1_WAIT = 3'd4;
  localparam S_L0_REQ  = 3'd5;
  localparam S_L0_WAIT = 3'd6;
  localparam S_RESP    = 3'd7;

  reg [2:0] state_q;            /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // Latched Request Registers
  reg [1:0]             hart_id_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [VADDR_WIDTH-1:0] vaddr_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [PADDR_WIDTH-1:0] pte_paddr_q;/* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // Selected satp for active Hart
  reg [XLEN-1:0] active_satp;
  always @(*) begin
    case (req_valid_i ? req_hart_id_i : hart_id_q)
      2'd0:    active_satp = satp_hart0_i;
      2'd1:    active_satp = satp_hart1_i;
      2'd2:    active_satp = satp_hart2_i;
      default: active_satp = satp_hart0_i;
    endcase
  end

  wire [3:0]  satp_mode = active_satp[63:60];
  wire [43:0] satp_ppn  = active_satp[43:0];

  // Canonical address check for Sv39 (bits [63:38] must match bit 38)
  wire canonical_ok = (req_vaddr_i[63:38] == {26{req_vaddr_i[38]}});

  assign req_ready_o = (state_q == S_IDLE);

  // --------------------------------------------------------------------------
  // Page Table Walker FSM
  // --------------------------------------------------------------------------
  wire [63:0] pte = mem_resp_data_i;
  wire        pte_v = pte[0];
  wire        pte_r = pte[1];
  wire        pte_w = pte[2];
  wire        pte_x = pte[3];
  wire        is_leaf = (pte_r | pte_x); // In RISC-V, Leaf PTE has R=1 or X=1
  wire        is_invalid_perm = (pte_w && !pte_r); // Reserved combination (W=1, R=0)

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q            <= S_IDLE;
      hart_id_q          <= 2'd0;
      vaddr_q            <= {VADDR_WIDTH{1'b0}};
      pte_paddr_q        <= {PADDR_WIDTH{1'b0}};
      resp_valid_o       <= 1'b0;
      resp_hart_id_o     <= 2'd0;
      resp_paddr_o       <= {PADDR_WIDTH{1'b0}};
      resp_fault_o       <= 1'b0;
      mem_req_valid_o    <= 1'b0;
      mem_req_paddr_w_o  <= {(PADDR_WIDTH-2){1'b0}};
    end else begin
      // Default transient outputs
      resp_valid_o <= 1'b0;

      case (state_q)
        S_IDLE: begin
          mem_req_valid_o <= 1'b0;
          if (req_valid_i) begin
            hart_id_q <= req_hart_id_i;
            vaddr_q   <= req_vaddr_i;

            if (satp_mode == 4'd0) begin
              // Bare Mode: passthrough without translation
              resp_valid_o   <= 1'b1;
              resp_hart_id_o <= req_hart_id_i;
              resp_paddr_o   <= req_vaddr_i[PADDR_WIDTH-1:0];
              resp_fault_o   <= 1'b0;
              state_q        <= S_IDLE;
            end else if (!canonical_ok) begin
              // Canonical address fault
              resp_valid_o   <= 1'b1;
              resp_hart_id_o <= req_hart_id_i;
              resp_paddr_o   <= {PADDR_WIDTH{1'b0}};
              resp_fault_o   <= 1'b1;
              state_q        <= S_IDLE;
            end else begin
              // Start Sv39 Walk at Level 2 (Root)
              // Level 2 PTE physical address = {satp.PPN, vaddr[38:30], 3'b000}
              pte_paddr_q <= {satp_ppn[PADDR_WIDTH-13:0], req_vaddr_i[38:30], 3'b000};
              state_q     <= S_L2_REQ;
            end
          end
        end

        // --------------------------------------------------------------------
        // Level 2 (Root)
        // --------------------------------------------------------------------
        S_L2_REQ: begin
          mem_req_valid_o   <= 1'b1;
          mem_req_paddr_w_o <= pte_paddr_q[PADDR_WIDTH-1:2];
          if (mem_req_ready_i) begin
            state_q <= S_L2_WAIT;
          end
        end

        S_L2_WAIT: begin
          mem_req_valid_o <= 1'b0;
          if (mem_resp_valid_i) begin
            if (!pte_v || is_invalid_perm) begin
              // Page Fault
              resp_valid_o   <= 1'b1;
              resp_hart_id_o <= hart_id_q;
              resp_paddr_o   <= {PADDR_WIDTH{1'b0}};
              resp_fault_o   <= 1'b1;
              state_q        <= S_IDLE;
            end else if (is_leaf) begin
              // 1GB Gigapage: PPN[1:0] must be zero (pte[27:10] == 0)
              if (pte[27:10] != 18'd0) begin
                resp_valid_o   <= 1'b1;
                resp_hart_id_o <= hart_id_q;
                resp_paddr_o   <= {PADDR_WIDTH{1'b0}};
                resp_fault_o   <= 1'b1;
                state_q        <= S_IDLE;
              end else begin
                resp_valid_o   <= 1'b1;
                resp_hart_id_o <= hart_id_q;
                resp_paddr_o   <= {pte[PADDR_WIDTH-13+10:28], vaddr_q[29:0]};
                resp_fault_o   <= 1'b0;
                state_q        <= S_IDLE;
              end
            end else begin
              // Non-leaf: Next level is Level 1
              pte_paddr_q <= {pte[PADDR_WIDTH-13+10:10], vaddr_q[29:21], 3'b000};
              state_q     <= S_L1_REQ;
            end
          end
        end

        // --------------------------------------------------------------------
        // Level 1
        // --------------------------------------------------------------------
        S_L1_REQ: begin
          mem_req_valid_o   <= 1'b1;
          mem_req_paddr_w_o <= pte_paddr_q[PADDR_WIDTH-1:2];
          if (mem_req_ready_i) begin
            state_q <= S_L1_WAIT;
          end
        end

        S_L1_WAIT: begin
          mem_req_valid_o <= 1'b0;
          if (mem_resp_valid_i) begin
            if (!pte_v || is_invalid_perm) begin
              resp_valid_o   <= 1'b1;
              resp_hart_id_o <= hart_id_q;
              resp_paddr_o   <= {PADDR_WIDTH{1'b0}};
              resp_fault_o   <= 1'b1;
              state_q        <= S_IDLE;
            end else if (is_leaf) begin
              // 2MB Megapage: PPN[0] must be zero (pte[18:10] == 0)
              if (pte[18:10] != 9'd0) begin
                resp_valid_o   <= 1'b1;
                resp_hart_id_o <= hart_id_q;
                resp_paddr_o   <= {PADDR_WIDTH{1'b0}};
                resp_fault_o   <= 1'b1;
                state_q        <= S_IDLE;
              end else begin
                resp_valid_o   <= 1'b1;
                resp_hart_id_o <= hart_id_q;
                resp_paddr_o   <= {pte[PADDR_WIDTH-13+10:19], vaddr_q[20:0]};
                resp_fault_o   <= 1'b0;
                state_q        <= S_IDLE;
              end
            end else begin
              // Non-leaf: Next level is Level 0
              pte_paddr_q <= {pte[PADDR_WIDTH-13+10:10], vaddr_q[20:12], 3'b000};
              state_q     <= S_L0_REQ;
            end
          end
        end

        // --------------------------------------------------------------------
        // Level 0 (Leaf 4KB Page)
        // --------------------------------------------------------------------
        S_L0_REQ: begin
          mem_req_valid_o   <= 1'b1;
          mem_req_paddr_w_o <= pte_paddr_q[PADDR_WIDTH-1:2];
          if (mem_req_ready_i) begin
            state_q <= S_L0_WAIT;
          end
        end

        S_L0_WAIT: begin
          mem_req_valid_o <= 1'b0;
          if (mem_resp_valid_i) begin
            if (!pte_v || is_invalid_perm || !is_leaf) begin
              // Level 0 non-leaf or invalid permission is a page fault
              resp_valid_o   <= 1'b1;
              resp_hart_id_o <= hart_id_q;
              resp_paddr_o   <= {PADDR_WIDTH{1'b0}};
              resp_fault_o   <= 1'b1;
              state_q        <= S_IDLE;
            end else begin
              // Valid 4KB leaf page
              resp_valid_o   <= 1'b1;
              resp_hart_id_o <= hart_id_q;
              resp_paddr_o   <= {pte[PADDR_WIDTH-13+10:10], vaddr_q[11:0]};
              resp_fault_o   <= 1'b0;
              state_q        <= S_IDLE;
            end
          end
        end

        default: state_q <= S_IDLE;
      endcase
    end
  end

endmodule
