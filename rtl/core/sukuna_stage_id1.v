// ============================================================================
// Pipeline Stage: ID1 (Instruction Decode 1) (Verilog 2005)
// Complies with design-rule.md
// ============================================================================
// Responsibilities:
//   - Zero-Mux unconditioned RegFile read address output (straight from instruction bits)
//   - Basic opcode type decoding (INT, MA, FP, SIMD) for Lane 0 and Lane 1
//   - Immediate sign-extension (Imm Gen)
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_stage_id1 #(
  parameter XLEN = `XLEN
)(
  input  wire             clk_i,
  input  wire             rst_ni,

  // Pipeline flow controls
  input  wire             stall_i,
  input  wire             flush_i,

  // Input from IF2
  input  wire             if2_valid0_i,
  input  wire [XLEN-1:0]  if2_pc0_i,
  input  wire [31:0]      if2_inst0_i,

  input  wire             if2_valid1_i,
  input  wire [XLEN-1:0]  if2_pc1_i,
  input  wire [31:0]      if2_inst1_i,

  // --------------------------------------------------------------------------
  // Zero-Mux Unconditioned RegFile Read Addresses
  // Directly wired from fixed RISC-V instruction bit fields (no MUX!)
  // --------------------------------------------------------------------------
  output wire [4:0]       rf_raddr_l0_rs1_o,
  output wire [4:0]       rf_raddr_l0_rs2_o,
  output wire [4:0]       rf_raddr_l1_rs1_o,
  output wire [4:0]       rf_raddr_l1_rs2_o,

  // --------------------------------------------------------------------------
  // Pipeline Registers to ID2 (Lane 0: older, Lane 1: younger)
  // --------------------------------------------------------------------------
  output reg              id1_valid0_o, /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]  id1_pc0_o,    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [31:0]      id1_inst0_o,  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [1:0]       id1_type0_o,  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */ // 0: None, 1: INT, 2: MA, 3: FP/SIMD
  output reg  [4:0]       id1_rd0_o,    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [4:0]       id1_rs1_0_o,  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [4:0]       id1_rs2_0_o,  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]  id1_imm0_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [3:0]       id1_alu_op0_o,/* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [2:0]       id1_mem_op0_o,/* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [2:0]       id1_sys_op0_o,/* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [2:0]       id1_priv_op0_o,/* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [11:0]      id1_csr_addr0_o,/* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  output reg              id1_valid1_o, /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]  id1_pc1_o,    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [31:0]      id1_inst1_o,  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [1:0]       id1_type1_o,  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [4:0]       id1_rd1_o,    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [4:0]       id1_rs1_1_o,  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [4:0]       id1_rs2_1_o,  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]  id1_imm1_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [3:0]       id1_alu_op1_o,/* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [2:0]       id1_mem_op1_o /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
);

  // Directly connect instruction fields to RegFile ports (0 Mux)
  assign rf_raddr_l0_rs1_o = if2_inst0_i[19:15];
  assign rf_raddr_l0_rs2_o = if2_inst0_i[24:20];
  assign rf_raddr_l1_rs1_o = if2_inst1_i[19:15];
  assign rf_raddr_l1_rs2_o = if2_inst1_i[24:20];

  // Opcode detection for Lane 0
  wire [6:0] op0 = if2_inst0_i[6:0];
  wire is_int0   = (op0 == 7'b0110011) || (op0 == 7'b0010011) || (op0 == 7'b0110111) || (op0 == 7'b0010111);
  wire is_ma0    = (op0 == 7'b0000011) || (op0 == 7'b0100011);
  wire is_fp0    = (op0 == 7'b1010011);
  wire is_sys0   = (op0 == 7'b1110011);

  wire [2:0]  funct3_0  = if2_inst0_i[14:12];
  wire [11:0] funct12_0 = if2_inst0_i[31:20];

  wire [2:0] sys_op0 = (!is_sys0) ? `SYS_NONE :
                       (funct3_0 == 3'b000) ? `SYS_PRIV :
                       (funct3_0[1:0] == 2'b01) ? `SYS_CSRRW :
                       (funct3_0[1:0] == 2'b10) ? `SYS_CSRRS :
                       (funct3_0[1:0] == 2'b11) ? `SYS_CSRRC : `SYS_NONE;

  wire [2:0] priv_op0 = (!is_sys0 || funct3_0 != 3'b000) ? `PRIV_NONE :
                        (funct12_0 == 12'h000) ? `PRIV_ECALL :
                        (funct12_0 == 12'h001) ? `PRIV_EBREAK :
                        (funct12_0 == 12'h302) ? `PRIV_MRET :
                        (funct12_0 == 12'h102) ? `PRIV_SRET :
                        (funct12_0 == 12'h105) ? `PRIV_WFI :
                        (funct12_0[11:5] == 7'b0001001) ? `PRIV_SFENCE_VMA : `PRIV_NONE;

  // Opcode detection for Lane 1
  wire [6:0] op1 = if2_inst1_i[6:0];
  wire is_int1   = (op1 == 7'b0110011) || (op1 == 7'b0010011) || (op1 == 7'b0110111) || (op1 == 7'b0010111);
  wire is_ma1    = (op1 == 7'b0000011) || (op1 == 7'b0100011);
  wire is_fp1    = (op1 == 7'b1010011);

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      id1_valid0_o    <= 1'b0;
      id1_pc0_o       <= {XLEN{1'b0}};
      id1_inst0_o     <= 32'h00000013;
      id1_type0_o     <= 2'b00;
      id1_rd0_o       <= 5'd0;
      id1_rs1_0_o     <= 5'd0;
      id1_rs2_0_o     <= 5'd0;
      id1_imm0_o      <= {XLEN{1'b0}};
      id1_alu_op0_o   <= 4'd0;
      id1_mem_op0_o   <= 3'd0;
      id1_sys_op0_o   <= `SYS_NONE;
      id1_priv_op0_o  <= `PRIV_NONE;
      id1_csr_addr0_o <= 12'd0;

      id1_valid1_o    <= 1'b0;
      id1_pc1_o     <= {XLEN{1'b0}};
      id1_inst1_o   <= 32'h00000013;
      id1_type1_o   <= 2'b00;
      id1_rd1_o     <= 5'd0;
      id1_rs1_1_o   <= 5'd0;
      id1_rs2_1_o   <= 5'd0;
      id1_imm1_o    <= {XLEN{1'b0}};
      id1_alu_op1_o <= 4'd0;
      id1_mem_op1_o <= 3'd0;
    end else begin
      if (flush_i) begin
        id1_valid0_o <= 1'b0;
        id1_valid1_o <= 1'b0;
      end else if (!stall_i) begin
        // Lane 0 decode
        id1_valid0_o  <= if2_valid0_i;
        id1_pc0_o     <= if2_pc0_i;
        id1_inst0_o   <= if2_inst0_i;
        id1_type0_o   <= is_int0 ? 2'b01 : is_ma0 ? 2'b10 : is_fp0 ? 2'b11 : 2'b01;
        id1_rd0_o     <= if2_inst0_i[11:7];
        id1_rs1_0_o   <= if2_inst0_i[19:15];
        id1_rs2_0_o   <= if2_inst0_i[24:20];
        id1_imm0_o    <= {{52{if2_inst0_i[31]}}, if2_inst0_i[31:20]};
        id1_alu_op0_o <= `ALU_ADD;
        id1_mem_op0_o <= if2_inst0_i[14:12];

        // Lane 1 decode
        id1_valid1_o  <= if2_valid1_i;
        id1_pc1_o     <= if2_pc1_i;
        id1_inst1_o   <= if2_inst1_i;
        id1_type1_o   <= is_int1 ? 2'b01 : is_ma1 ? 2'b10 : is_fp1 ? 2'b11 : 2'b01;
        id1_rd1_o     <= if2_inst1_i[11:7];
        id1_rs1_1_o   <= if2_inst1_i[19:15];
        id1_rs2_1_o   <= if2_inst1_i[24:20];
        id1_imm1_o    <= {{52{if2_inst1_i[31]}}, if2_inst1_i[31:20]};
        id1_alu_op1_o <= `ALU_ADD;
        id1_mem_op1_o <= if2_inst1_i[14:12];
      end
    end
  end

endmodule
