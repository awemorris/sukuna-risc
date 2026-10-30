// ============================================================================
// Sukuna-RISC: Dedicated Uncached Access & MMIO Controller (Verilog 2005)
// Complies with design-rule.md & style.md (ASIC 5nm 1.5GHz & Kintex-7)
// ============================================================================
// Responsibilities:
//   - Receives uncacheable memory requests (PMA < 0x8000_0000) from MA1 stage
//   - Completely bypasses L1D and L2 cache hierarchies (prevents cache pollution)
//   - Routes on-chip MMIO (CLINT @ 0x0200_0000, PLIC @ 0x0C00_0000)
//   - Routes external uncached device registers (UART @ 0x6000_0000, etc.)
//   - Latches responses and returns clean 1-cycle pulses to MA2 holding registers
// ============================================================================

`timescale 1ns / 1ps
`default_nettype none

`include "sukuna_defines.vh"

module sukuna_uncached_ctrl #(
  parameter NUM_HARTS   = `NUM_HARTS,
  parameter XLEN        = `XLEN,
  parameter PADDR_WIDTH = `PADDR_WIDTH
)(
  input  wire                               clk_i,
  input  wire                               rst_ni,

  // Core Request Interfaces from Threads (MA1 stage)
  input  wire [NUM_HARTS-1:0]               core_req_valid_i,
  input  wire [NUM_HARTS-1:0]               core_req_write_i,
  input  wire [NUM_HARTS*4-1:0]             core_req_op_i,
  input  wire [NUM_HARTS*8-1:0]             core_req_byte_en_i,
  input  wire [NUM_HARTS*(PADDR_WIDTH-2)-1:0] core_req_paddr_w_i,
  input  wire [NUM_HARTS*XLEN-1:0]          core_req_wdata_i,
  output wire [NUM_HARTS-1:0]               core_req_ready_o,

  // Core Response Interfaces to Threads (MA2 stage)
  output reg  [NUM_HARTS-1:0]               core_resp_valid_o, /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [NUM_HARTS*XLEN-1:0]          core_resp_rdata_o, /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // On-chip MMIO Interface (to sukuna_interrupt_subsys: CLINT / PLIC)
  output reg                                mmio_req_valid_o,  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg                                mmio_req_write_o,  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]                    mmio_req_addr_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]                    mmio_req_wdata_o,  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [(XLEN/8)-1:0]                mmio_req_wstrb_o,  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  input  wire                               mmio_req_ready_i,
  input  wire                               mmio_resp_valid_i,
  input  wire [XLEN-1:0]                    mmio_resp_rdata_i,

  // External Uncached Device Interface (Single-beat AXI / BIU)
  output reg                                ext_req_valid_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg                                ext_req_write_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]                    ext_req_addr_o,    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]                    ext_req_wdata_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [(XLEN/8)-1:0]                ext_req_wstrb_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  input  wire                               ext_req_ready_i,
  input  wire                               ext_resp_valid_i,
  input  wire [XLEN-1:0]                    ext_resp_rdata_i
);

  // States
  localparam S_IDLE = 2'd0;
  localparam S_MMIO = 2'd1;
  localparam S_EXT  = 2'd2;

  reg [1:0] state_q;        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [1:0] active_hart_q;  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // Fixed-priority arbiter among harts
  reg [1:0] grant_hart;
  reg       grant_valid;
  integer h;
  always @(*) begin
    grant_hart  = 2'd0;
    grant_valid = 1'b0;
    for (h = NUM_HARTS - 1; h >= 0; h = h - 1) begin
      if (core_req_valid_i[h]) begin
        grant_hart  = h[1:0];
        grant_valid = 1'b1;
      end
    end
  end

  // Selected request signals
  wire [PADDR_WIDTH-1:2] sel_paddr_w = core_req_paddr_w_i[grant_hart*(PADDR_WIDTH-2) +: (PADDR_WIDTH-2)];
  wire [XLEN-1:0]        sel_addr    = {{(XLEN-PADDR_WIDTH){1'b0}}, sel_paddr_w, 2'b00};
  wire [XLEN-1:0]        sel_wdata   = core_req_wdata_i[grant_hart*XLEN +: XLEN];
  wire [7:0]             sel_wstrb   = core_req_byte_en_i[grant_hart*8 +: 8];
  wire                   sel_write   = core_req_write_i[grant_hart];

  // Address Decoding (PMA)
  // CLINT @ 0x0200_0000, PLIC @ 0x0C00_0000
  wire is_onchip_mmio = (sel_addr[31:24] == 8'h02) || (sel_addr[31:24] == 8'h0C);

  genvar gh;
  generate
    for (gh = 0; gh < NUM_HARTS; gh = gh + 1) begin : gen_req_ready
      assign core_req_ready_o[gh] = (state_q == S_IDLE) && grant_valid && (grant_hart == gh[1:0]);
    end
  endgenerate

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q           <= S_IDLE;
      active_hart_q     <= 2'd0;
      core_resp_valid_o <= {NUM_HARTS{1'b0}};
      core_resp_rdata_o <= {(NUM_HARTS*XLEN){1'b0}};
      mmio_req_valid_o  <= 1'b0;
      mmio_req_write_o  <= 1'b0;
      mmio_req_addr_o   <= {XLEN{1'b0}};
      mmio_req_wdata_o  <= {XLEN{1'b0}};
      mmio_req_wstrb_o  <= 8'd0;
      ext_req_valid_o   <= 1'b0;
      ext_req_write_o   <= 1'b0;
      ext_req_addr_o    <= {XLEN{1'b0}};
      ext_req_wdata_o   <= {XLEN{1'b0}};
      ext_req_wstrb_o   <= 8'd0;
    end else begin
      // Default: clear single-cycle response pulses
      core_resp_valid_o <= {NUM_HARTS{1'b0}};

      case (state_q)
        S_IDLE: begin
          if (grant_valid) begin
            active_hart_q <= grant_hart;
            if (is_onchip_mmio) begin
              mmio_req_valid_o <= 1'b1;
              mmio_req_write_o <= sel_write;
              mmio_req_addr_o  <= sel_addr;
              mmio_req_wdata_o <= sel_wdata;
              mmio_req_wstrb_o <= sel_wstrb;
              state_q          <= S_MMIO;
            end else begin
              ext_req_valid_o  <= 1'b1;
              ext_req_write_o  <= sel_write;
              ext_req_addr_o   <= sel_addr;
              ext_req_wdata_o  <= sel_wdata;
              ext_req_wstrb_o  <= sel_wstrb;
              state_q          <= S_EXT;
            end
          end
        end

        S_MMIO: begin
          if (mmio_req_ready_i) begin
            mmio_req_valid_o <= 1'b0;
          end
          if (mmio_resp_valid_i) begin
            core_resp_valid_o[active_hart_q] <= 1'b1;
            core_resp_rdata_o[active_hart_q*XLEN +: XLEN] <= mmio_resp_rdata_i;
            mmio_req_valid_o <= 1'b0;
            state_q          <= S_IDLE;
          end
        end

        S_EXT: begin
          if (ext_req_ready_i) begin
            ext_req_valid_o <= 1'b0;
          end
          if (ext_resp_valid_i) begin
            core_resp_valid_o[active_hart_q] <= 1'b1;
            core_resp_rdata_o[active_hart_q*XLEN +: XLEN] <= ext_resp_rdata_i;
            ext_req_valid_o <= 1'b0;
            state_q         <= S_IDLE;
          end
        end

        default: state_q <= S_IDLE;
      endcase
    end
  end

  // Silence unused variable warnings
  wire _unused = &{1'b0, core_req_op_i, 1'b0};

endmodule
