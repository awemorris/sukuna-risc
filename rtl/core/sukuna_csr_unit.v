// ============================================================================
// Per-Hart Control and Status Register (CSR) Unit Stub (Verilog 2005)
// Manages M/S/U privilege modes, trap vectors, satp, and interrupt status
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_csr_unit #(
  parameter HART_ID = 0,
  parameter XLEN    = `XLEN
)(
  input  wire                   clk_i,
  input  wire                   rst_ni,

  // CSR Read/Write Pipeline Interface
  input  wire                   csr_req_valid_i,
  input  wire [11:0]            csr_addr_i,
  input  wire [1:0]             csr_op_i,        // 0: RW, 1: RS, 2: RC
  input  wire [XLEN-1:0]        csr_wdata_i,
  output reg  [XLEN-1:0]        csr_rdata_o,

  // External / Timer / Software Interrupt Inputs
  input  wire                   meip_i,
  input  wire                   seip_i,
  input  wire                   mtip_i,
  input  wire                   msip_i,

  // Trap / Exception Interface from Pipeline
  input  wire                   exception_valid_i,
  input  wire [5:0]             exception_cause_i,
  input  wire [XLEN-1:0]        exception_pc_i,
  input  wire                   mret_valid_i,
  input  wire                   sret_valid_i,

  // Control outputs to Fetch / MMU
  output wire                   trap_flush_o,
  output reg  [XLEN-1:0]        trap_target_pc_o,
  output reg  [XLEN-1:0]        satp_o,
  output reg  [1:0]             priv_mode_o      // 00: U, 01: S, 11: M
);

  reg [XLEN-1:0] mtvec_q;   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0] mepc_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [XLEN-1:0] mstatus_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  assign trap_flush_o = exception_valid_i || mret_valid_i || sret_valid_i;

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mtvec_q          <= 64'h00000000_80000004;
      mepc_q           <= {XLEN{1'b0}};
      mstatus_q        <= {XLEN{1'b0}};
      satp_o           <= {XLEN{1'b0}};
      priv_mode_o      <= 2'b11; // Reset into Machine mode
      trap_target_pc_o <= {XLEN{1'b0}};
      csr_rdata_o      <= {XLEN{1'b0}};
    end else begin
      if (exception_valid_i) begin
        mepc_q           <= exception_pc_i;
        trap_target_pc_o <= mtvec_q;
      end else if (mret_valid_i) begin
        trap_target_pc_o <= mepc_q;
      end

      if (csr_req_valid_i) begin
        case (csr_addr_i)
          12'h300: csr_rdata_o <= mstatus_q;
          12'h305: csr_rdata_o <= mtvec_q;
          12'h341: csr_rdata_o <= mepc_q;
          12'h180: csr_rdata_o <= satp_o;
          12'hF14: csr_rdata_o <= HART_ID; // mhartid
          default: csr_rdata_o <= {XLEN{1'b0}};
        endcase
      end
    end
  end

endmodule
