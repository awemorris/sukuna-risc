// ============================================================================
// Hardware Page Table Walker (PTW) Stub (Verilog 2005)
// Traverses Sv39/Sv48 page tables in memory on L2-TLB misses
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

  output wire                   resp_valid_o,
  output wire [1:0]             resp_hart_id_o,
  output wire [PADDR_WIDTH-1:0] resp_paddr_o,
  output wire                   resp_fault_o,

  // Base page table registers (satp) per Hart
  input  wire [XLEN-1:0]        satp_hart0_i,
  input  wire [XLEN-1:0]        satp_hart1_i,
  input  wire [XLEN-1:0]        satp_hart2_i,

  // Memory interface to L2 cache / Interconnect for PTE reads (word-aligned)
  output wire                   mem_req_valid_o,
  output wire [PADDR_WIDTH-1:2] mem_req_paddr_w_o,
  input  wire                   mem_req_ready_i,
  input  wire                   mem_resp_valid_i,
  input  wire [XLEN-1:0]        mem_resp_data_i
);

  assign req_ready_o        = 1'b1;
  assign resp_valid_o       = req_valid_i;
  assign resp_hart_id_o     = req_hart_id_i;
  assign resp_paddr_o       = req_vaddr_i[PADDR_WIDTH-1:0];
  assign resp_fault_o       = 1'b0;

  assign mem_req_valid_o    = 1'b0;
  assign mem_req_paddr_w_o  = {(PADDR_WIDTH-2){1'b0}};

endmodule
