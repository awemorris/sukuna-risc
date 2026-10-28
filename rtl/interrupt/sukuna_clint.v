// ============================================================================
// Core Local Interruptor (CLINT) (Verilog 2005)
// Complies with design-rule.md
// Generates timer (MTIP) and software (MSIP) interrupts for each Hart
// Compatible with RISC-V Standard CLINT memory map (0x0200_0000)
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_clint #(
  parameter NUM_HARTS = `NUM_HARTS,
  parameter XLEN      = `XLEN
)(
  input  wire                   clk_i,
  input  wire                   rst_ni,

  // MMIO Access Interface
  input  wire                   req_valid_i,
  input  wire                   req_write_i,
  input  wire [XLEN-1:0]        req_addr_i,
  input  wire [XLEN-1:0]        req_wdata_i,
  input  wire [(XLEN/8)-1:0]    req_wstrb_i,
  output wire                   req_ready_o,
  output reg                    resp_valid_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]        resp_rdata_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // Interrupt outputs per Hart
  output wire [NUM_HARTS-1:0]   timer_irq_o,     // MTIP
  output wire [NUM_HARTS-1:0]   software_irq_o   // MSIP
);

  // --------------------------------------------------------------------------
  // CLINT Registers
  // --------------------------------------------------------------------------
  // 64-bit global real-time counter
  reg [63:0] mtime_q;                           /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // Per-Hart 64-bit mtimecmp registers
  reg [63:0] mtimecmp_q [0:NUM_HARTS-1];

  // Per-Hart 1-bit msip registers
  reg [NUM_HARTS-1:0] msip_q;                   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  // --------------------------------------------------------------------------
  // Interrupt Output Generation
  // --------------------------------------------------------------------------
  genvar h;
  generate
    for (h = 0; h < NUM_HARTS; h = h + 1) begin : gen_irq
      assign timer_irq_o[h]    = (mtime_q >= mtimecmp_q[h]);
      assign software_irq_o[h] = msip_q[h];
    end
  endgenerate

  assign req_ready_o = 1'b1;

  // --------------------------------------------------------------------------
  // MMIO Address Decoding (Offset from CLINT Base 0x0200_0000)
  // --------------------------------------------------------------------------
  wire [15:0] offset = req_addr_i[15:0];

  // Read Multiplexer
  reg [63:0] rdata_comb;
  integer r;
  always @(*) begin
    rdata_comb = 64'd0;
    if (offset == 16'hBFF8) begin
      rdata_comb = mtime_q;
    end else if (offset >= 16'h4000 && offset < 16'h4000 + (NUM_HARTS * 8)) begin
      for (r = 0; r < NUM_HARTS; r = r + 1) begin
        if (offset[5:3] == r[2:0]) rdata_comb = mtimecmp_q[r];
      end
    end else if (offset < (NUM_HARTS * 4)) begin
      for (r = 0; r < NUM_HARTS; r = r + 1) begin
        if (offset[3:2] == r[1:0]) rdata_comb = {63'd0, msip_q[r]};
      end
    end
  end

  // --------------------------------------------------------------------------
  // Register Updates
  // --------------------------------------------------------------------------
  integer i;
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mtime_q      <= 64'd0;
      msip_q       <= {NUM_HARTS{1'b0}};
      resp_valid_o <= 1'b0;
      resp_rdata_o <= {XLEN{1'b0}};
      for (i = 0; i < NUM_HARTS; i = i + 1) begin
        mtimecmp_q[i] <= 64'hFFFF_FFFF_FFFF_FFFF;
      end
    end else begin
      // Free-running timer increment
      mtime_q <= mtime_q + 1'b1;

      // Single-cycle MMIO response
      resp_valid_o <= req_valid_i;
      resp_rdata_o <= rdata_comb;

      // MMIO Write Handling
      if (req_valid_i && req_write_i) begin
        if (offset == 16'hBFF8) begin
          mtime_q <= req_wdata_i;
        end else if (offset >= 16'h4000 && offset < 16'h4000 + (NUM_HARTS * 8)) begin
          for (i = 0; i < NUM_HARTS; i = i + 1) begin
            if (offset[5:3] == i[2:0]) begin
              mtimecmp_q[i] <= req_wdata_i;
            end
          end
        end else if (offset < (NUM_HARTS * 4)) begin
          for (i = 0; i < NUM_HARTS; i = i + 1) begin
            if (offset[3:2] == i[1:0]) begin
              msip_q[i] <= req_wdata_i[0];
            end
          end
        end
      end
    end
  end

endmodule
