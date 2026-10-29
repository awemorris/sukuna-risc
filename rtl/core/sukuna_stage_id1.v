// ============================================================================
// Pipeline Stage: ID1 (Instruction Decode 1) (Verilog 2005)
// Complies with design-rule.md
// ============================================================================
// Responsibilities:
//   - Zero-Mux unconditioned RegFile read address output (straight from instruction bits)
//   - Full RV64IM opcode, funct3, funct7 decoding
//   - Complete immediate sign-extension (I, S, B, U, J, CSR zimm formats)
//   - Control flow (Branch, Jump) and 32-bit Word operation identification
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
  input  wire             hold_slot0_i,
  input  wire             hold_slot1_i,

  // Input from IF2
  input  wire             if2_valid0_i,
  input  wire [XLEN-1:0]  if2_pc0_i,
  input  wire [31:0]      if2_inst0_i,

  input  wire             if2_valid1_i,
  input  wire [XLEN-1:0]  if2_pc1_i,
  input  wire [31:0]      if2_inst1_i,

  // --------------------------------------------------------------------------
  // Zero-Mux Unconditioned RegFile Read Addresses
  // --------------------------------------------------------------------------
  output wire [4:0]       rf_raddr_l0_rs1_o,
  output wire [4:0]       rf_raddr_l0_rs2_o,
  output wire [4:0]       rf_raddr_l1_rs1_o,
  output wire [4:0]       rf_raddr_l1_rs2_o,

  // --------------------------------------------------------------------------
  // Pipeline Registers to ID2 (Lane 0: older, Lane 1: younger)
  // --------------------------------------------------------------------------
  output reg              id1_valid0_o,     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]  id1_pc0_o,        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [31:0]      id1_inst0_o,      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [1:0]       id1_type0_o,      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */ // 0: None, 1: INT, 2: MA, 3: FP
  output reg  [4:0]       id1_rd0_o,        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [4:0]       id1_rs1_0_o,      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [4:0]       id1_rs2_0_o,      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]  id1_imm0_o,       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [4:0]       id1_alu_op0_o,    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [7:0]       id1_mem_op0_o,    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [2:0]       id1_sys_op0_o,    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [2:0]       id1_priv_op0_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [11:0]      id1_csr_addr0_o,  /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg              id1_csr_is_imm0_o,/* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [2:0]       id1_br_type0_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [1:0]       id1_jump_type0_o, /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg              id1_is_word0_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg              id1_use_imm0_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg              id1_use_pc0_o,    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  output reg              id1_valid1_o,     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]  id1_pc1_o,        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [31:0]      id1_inst1_o,      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [1:0]       id1_type1_o,      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [4:0]       id1_rd1_o,        /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [4:0]       id1_rs1_1_o,      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [4:0]       id1_rs2_1_o,      /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [XLEN-1:0]  id1_imm1_o,       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [4:0]       id1_alu_op1_o,    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg  [7:0]       id1_mem_op1_o,    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg              id1_is_word1_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg              id1_use_imm1_o,   /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  output reg              id1_slot1_older_o /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
);

  // Directly connect instruction fields to RegFile ports (0 MUX)
  assign rf_raddr_l0_rs1_o = if2_inst0_i[19:15];
  assign rf_raddr_l0_rs2_o = if2_inst0_i[24:20];
  assign rf_raddr_l1_rs1_o = if2_inst1_i[19:15];
  assign rf_raddr_l1_rs2_o = if2_inst1_i[24:20];

  // ==========================================================================
  // Lane 0 Instruction Decode
  // ==========================================================================
  wire [6:0]  op0      = if2_inst0_i[6:0];
  wire [2:0]  funct3_0 = if2_inst0_i[14:12];
  wire [6:0]  funct7_0 = if2_inst0_i[31:25];

  wire is_op0     = (op0 == 7'b0110011);
  wire is_op_imm0 = (op0 == 7'b0010011);
  wire is_op32_0  = (op0 == 7'b0111011);
  wire is_opi32_0 = (op0 == 7'b0011011);
  wire is_fp_load0  = (op0 == 7'b0000111);
  wire is_fp_store0 = (op0 == 7'b0100111);
  wire is_fp_op0    = (op0 == 7'b1010011);
  wire is_load0     = (op0 == 7'b0000011) || is_fp_load0;
  wire is_store0    = (op0 == 7'b0100011) || is_fp_store0;
  wire is_branch0 = (op0 == 7'b1100011);
  wire is_jal0    = (op0 == 7'b1101111);
  wire is_jalr0   = (op0 == 7'b1100111);
  wire is_lui0    = (op0 == 7'b0110111);
  wire is_auipc0  = (op0 == 7'b0010111);
  wire is_sys0    = (op0 == 7'b1110011);
  wire is_fp0     = is_fp_op0;
  wire is_fence0  = (op0 == 7'b0001111);
  wire is_amo0    = (op0 == 7'b0101111);

  reg [3:0] amo_type0;
  always @(*) begin
    if (is_fp_load0 || is_fp_store0) begin
      amo_type0 = `AMO_FP;
    end else if (!is_amo0) begin
      amo_type0 = `AMO_NONE;
    end else begin
      case (funct7_0[6:2])
        5'b00010: amo_type0 = `AMO_LR;
        5'b00011: amo_type0 = `AMO_SC;
        5'b00001: amo_type0 = `AMO_SWAP;
        5'b00000: amo_type0 = `AMO_ADD;
        5'b00100: amo_type0 = `AMO_XOR;
        5'b01100: amo_type0 = `AMO_AND;
        5'b01000: amo_type0 = `AMO_OR;
        5'b10000: amo_type0 = `AMO_MIN;
        5'b10100: amo_type0 = `AMO_MAX;
        5'b11000: amo_type0 = `AMO_MINU;
        5'b11100: amo_type0 = `AMO_MAXU;
        default:  amo_type0 = `AMO_NONE;
      endcase
    end
  end
  wire is_amo_write0 = is_amo0 && (funct7_0[6:2] != 5'b00010);

  wire l0_writes_rd = is_op0 || is_op_imm0 || is_op32_0 || is_opi32_0 ||
                      is_load0 || is_lui0 || is_auipc0 || is_jal0 || is_jalr0 ||
                      is_amo0 || is_fp_op0 || (is_sys0 && (funct3_0 != 3'b000));

  // Immediate Formats for Lane 0
  wire [XLEN-1:0] imm_i0 = {{52{if2_inst0_i[31]}}, if2_inst0_i[31:20]};
  wire [XLEN-1:0] imm_s0 = {{52{if2_inst0_i[31]}}, if2_inst0_i[31:25], if2_inst0_i[11:7]};
  wire [XLEN-1:0] imm_b0 = {{52{if2_inst0_i[31]}}, if2_inst0_i[7], if2_inst0_i[30:25], if2_inst0_i[11:8], 1'b0};
  wire [XLEN-1:0] imm_u0 = {{32{if2_inst0_i[31]}}, if2_inst0_i[31:12], 12'b0};
  wire [XLEN-1:0] imm_j0 = {{44{if2_inst0_i[31]}}, if2_inst0_i[19:12], if2_inst0_i[20], if2_inst0_i[30:21], 1'b0};
  wire [XLEN-1:0] imm_z0 = {{(XLEN-5){1'b0}}, if2_inst0_i[19:15]};

  wire [XLEN-1:0] imm_l0 = (is_sys0 && funct3_0[2]) ? imm_z0 :
                           (is_lui0 || is_auipc0)    ? imm_u0 :
                           is_jal0                   ? imm_j0 :
                           is_branch0                ? imm_b0 :
                           is_store0                 ? imm_s0 :
                           is_amo0                   ? {XLEN{1'b0}} : imm_i0;

  // ALU Opcode for Lane 0
  reg [4:0] alu_op0_comb;
  always @(*) begin
    if (is_fp_op0) begin
      alu_op0_comb = `ALU_FP;
    end else if (is_lui0 || is_auipc0 || is_load0 || is_store0 || is_jal0 || is_jalr0) begin
      alu_op0_comb = `ALU_ADD;
    end else if (is_op0 || is_op32_0) begin
      if (funct7_0 == 7'b0000001) begin // RV64M Multiplier/Divider
        case (funct3_0)
          3'b000:  alu_op0_comb = `ALU_MUL;
          3'b001:  alu_op0_comb = `ALU_MULH;
          3'b010:  alu_op0_comb = `ALU_MULHSU;
          3'b011:  alu_op0_comb = `ALU_MULHU;
          3'b100:  alu_op0_comb = `ALU_DIV;
          3'b101:  alu_op0_comb = `ALU_DIVU;
          3'b110:  alu_op0_comb = `ALU_REM;
          3'b111:  alu_op0_comb = `ALU_REMU;
          default: alu_op0_comb = `ALU_MUL;
        endcase
      end else begin // Standard ALU
        case (funct3_0)
          3'b000:  alu_op0_comb = (funct7_0[5]) ? `ALU_SUB : `ALU_ADD;
          3'b001:  alu_op0_comb = `ALU_SLL;
          3'b010:  alu_op0_comb = `ALU_SLT;
          3'b011:  alu_op0_comb = `ALU_SLTU;
          3'b100:  alu_op0_comb = `ALU_XOR;
          3'b101:  alu_op0_comb = (funct7_0[5]) ? `ALU_SRA : `ALU_SRL;
          3'b110:  alu_op0_comb = `ALU_OR;
          3'b111:  alu_op0_comb = `ALU_AND;
          default: alu_op0_comb = `ALU_ADD;
        endcase
      end
    end else if (is_op_imm0 || is_opi32_0) begin
      case (funct3_0)
        3'b000:  alu_op0_comb = `ALU_ADD;
        3'b001:  alu_op0_comb = `ALU_SLL;
        3'b010:  alu_op0_comb = `ALU_SLT;
        3'b011:  alu_op0_comb = `ALU_SLTU;
        3'b100:  alu_op0_comb = `ALU_XOR;
        3'b101:  alu_op0_comb = (if2_inst0_i[30]) ? `ALU_SRA : `ALU_SRL;
        3'b110:  alu_op0_comb = `ALU_OR;
        3'b111:  alu_op0_comb = `ALU_AND;
        default: alu_op0_comb = `ALU_ADD;
      endcase
    end else begin
      alu_op0_comb = `ALU_ADD;
    end
  end

  // System & Privileged Opcode Decoding
  wire [11:0] funct12_0 = if2_inst0_i[31:20];
  wire [2:0] sys_op0 = (is_fence0 && funct3_0 == 3'b001) ? `SYS_PRIV :
                       (!is_sys0) ? `SYS_NONE :
                       (funct3_0 == 3'b000)    ? `SYS_PRIV :
                       (funct3_0[1:0] == 2'b01) ? `SYS_CSRRW :
                       (funct3_0[1:0] == 2'b10) ? `SYS_CSRRS :
                       (funct3_0[1:0] == 2'b11) ? `SYS_CSRRC : `SYS_NONE;

  wire [2:0] priv_op0 = (is_fence0 && funct3_0 == 3'b001) ? `PRIV_FENCE_I :
                        (!is_sys0 || funct3_0 != 3'b000) ? `PRIV_NONE :
                        (funct12_0 == 12'h000) ? `PRIV_ECALL :
                        (funct12_0 == 12'h001) ? `PRIV_EBREAK :
                        (funct12_0 == 12'h302) ? `PRIV_MRET :
                        (funct12_0 == 12'h102) ? `PRIV_SRET :
                        (funct12_0 == 12'h105) ? `PRIV_WFI :
                        (funct12_0[11:5] == 7'b0001001) ? `PRIV_SFENCE_VMA : `PRIV_NONE;

  // Branch & Jump Type Decoding
  wire [2:0] br_type0 = (!is_branch0) ? `BR_NONE :
                        (funct3_0 == 3'b000) ? `BR_BEQ :
                        (funct3_0 == 3'b001) ? `BR_BNE :
                        (funct3_0 == 3'b100) ? `BR_BLT :
                        (funct3_0 == 3'b101) ? `BR_BGE :
                        (funct3_0 == 3'b110) ? `BR_BLTU :
                        (funct3_0 == 3'b111) ? `BR_BGEU : `BR_NONE;

  wire [1:0] jump_type0 = is_jal0  ? `JUMP_JAL :
                          is_jalr0 ? `JUMP_JALR : `JUMP_NONE;

  // Single-issue requirement: Branches, Jumps, System ops, Fence, and AMO force single issue
  wire single_issue_l0 = is_sys0 || is_branch0 || (jump_type0 != `JUMP_NONE) || is_fence0 || is_amo0 || is_fp_op0 || is_fp_load0 || is_fp_store0;

  // ==========================================================================
  // Lane 1 Instruction Decode
  // ==========================================================================
  wire [6:0]  op1      = if2_inst1_i[6:0];
  wire [2:0]  funct3_1 = if2_inst1_i[14:12];
  wire [6:0]  funct7_1 = if2_inst1_i[31:25];

  wire is_op1     = (op1 == 7'b0110011);
  wire is_op_imm1 = (op1 == 7'b0010011);
  wire is_op32_1  = (op1 == 7'b0111011);
  wire is_opi32_1 = (op1 == 7'b0011011);
  wire is_load1   = (op1 == 7'b0000011);
  wire is_store1  = (op1 == 7'b0100011);
  wire is_lui1    = (op1 == 7'b0110111);
  wire is_auipc1  = (op1 == 7'b0010111);
  wire is_fp1     = (op1 == 7'b1010011);
  wire is_fence1  = (op1 == 7'b0001111);
  wire is_branch1 = (op1 == 7'b1100011);
  wire is_jal1    = (op1 == 7'b1101111);
  wire is_jalr1   = (op1 == 7'b1100111);
  wire is_sys1    = (op1 == 7'b1110011);

  wire [1:0] type1_comb = (is_load1 || is_store1) ? 2'b10 :
                          (is_sys1 || is_branch1 || is_jal1 || is_jalr1 || is_fence1) ? 2'b00 :
                          is_fp1 ? 2'b11 : 2'b01;

  wire l1_writes_rd = is_op1 || is_op_imm1 || is_op32_1 || is_opi32_1 ||
                      is_load1 || is_lui1 || is_auipc1;

  // Immediate Formats for Lane 1
  wire [XLEN-1:0] imm_i1 = {{52{if2_inst1_i[31]}}, if2_inst1_i[31:20]};
  wire [XLEN-1:0] imm_s1 = {{52{if2_inst1_i[31]}}, if2_inst1_i[31:25], if2_inst1_i[11:7]};
  wire [XLEN-1:0] imm_u1 = {{32{if2_inst1_i[31]}}, if2_inst1_i[31:12], 12'b0};

  wire [XLEN-1:0] imm_l1 = (is_lui1 || is_auipc1) ? imm_u1 :
                           is_store1              ? imm_s1 : imm_i1;

  reg [4:0] alu_op1_comb;
  always @(*) begin
    if (is_lui1 || is_auipc1 || is_load1 || is_store1) begin
      alu_op1_comb = `ALU_ADD;
    end else if (is_op1 || is_op32_1) begin
      if (funct7_1 == 7'b0000001) begin
        case (funct3_1)
          3'b000:  alu_op1_comb = `ALU_MUL;
          3'b001:  alu_op1_comb = `ALU_MULH;
          3'b010:  alu_op1_comb = `ALU_MULHSU;
          3'b011:  alu_op1_comb = `ALU_MULHU;
          3'b100:  alu_op1_comb = `ALU_DIV;
          3'b101:  alu_op1_comb = `ALU_DIVU;
          3'b110:  alu_op1_comb = `ALU_REM;
          3'b111:  alu_op1_comb = `ALU_REMU;
          default: alu_op1_comb = `ALU_MUL;
        endcase
      end else begin
        case (funct3_1)
          3'b000:  alu_op1_comb = (funct7_1[5]) ? `ALU_SUB : `ALU_ADD;
          3'b001:  alu_op1_comb = `ALU_SLL;
          3'b010:  alu_op1_comb = `ALU_SLT;
          3'b011:  alu_op1_comb = `ALU_SLTU;
          3'b100:  alu_op1_comb = `ALU_XOR;
          3'b101:  alu_op1_comb = (funct7_1[5]) ? `ALU_SRA : `ALU_SRL;
          3'b110:  alu_op1_comb = `ALU_OR;
          3'b111:  alu_op1_comb = `ALU_AND;
          default: alu_op1_comb = `ALU_ADD;
        endcase
      end
    end else if (is_op_imm1 || is_opi32_1) begin
      case (funct3_1)
        3'b000:  alu_op1_comb = `ALU_ADD;
        3'b001:  alu_op1_comb = `ALU_SLL;
        3'b010:  alu_op1_comb = `ALU_SLT;
        3'b011:  alu_op1_comb = `ALU_SLTU;
        3'b100:  alu_op1_comb = `ALU_XOR;
        3'b101:  alu_op1_comb = (if2_inst1_i[30]) ? `ALU_SRA : `ALU_SRL;
        3'b110:  alu_op1_comb = `ALU_OR;
        3'b111:  alu_op1_comb = `ALU_AND;
        default: alu_op1_comb = `ALU_ADD;
      endcase
    end else begin
      alu_op1_comb = `ALU_ADD;
    end
  end

  // --------------------------------------------------------------------------
  // Pipeline Registers to ID2
  // --------------------------------------------------------------------------
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      id1_valid0_o      <= 1'b0;
      id1_pc0_o         <= {XLEN{1'b0}};
      id1_inst0_o       <= 32'h00000013;
      id1_type0_o       <= 2'b00;
      id1_rd0_o         <= 5'd0;
      id1_rs1_0_o       <= 5'd0;
      id1_rs2_0_o       <= 5'd0;
      id1_imm0_o        <= {XLEN{1'b0}};
      id1_alu_op0_o     <= 5'd0;
      id1_mem_op0_o     <= 8'd0;
      id1_sys_op0_o     <= `SYS_NONE;
      id1_priv_op0_o    <= `PRIV_NONE;
      id1_csr_addr0_o   <= 12'd0;
      id1_csr_is_imm0_o <= 1'b0;
      id1_br_type0_o    <= `BR_NONE;
      id1_jump_type0_o  <= `JUMP_NONE;
      id1_is_word0_o    <= 1'b0;
      id1_use_imm0_o    <= 1'b0;
      id1_use_pc0_o     <= 1'b0;

      id1_valid1_o      <= 1'b0;
      id1_pc1_o         <= {XLEN{1'b0}};
      id1_inst1_o       <= 32'h00000013;
      id1_type1_o       <= 2'b00;
      id1_rd1_o         <= 5'd0;
      id1_rs1_1_o       <= 5'd0;
      id1_rs2_1_o       <= 5'd0;
      id1_imm1_o        <= {XLEN{1'b0}};
      id1_alu_op1_o     <= 5'd0;
      id1_mem_op1_o     <= 8'd0;
      id1_is_word1_o    <= 1'b0;
      id1_use_imm1_o    <= 1'b0;
      id1_slot1_older_o <= 1'b0;
    end else begin
      if (flush_i) begin
        id1_valid0_o      <= 1'b0;
        id1_valid1_o      <= 1'b0;
        id1_slot1_older_o <= 1'b0;
      end else if (!stall_i) begin
        // Slot 0 Output Latching (when not held)
        if (!hold_slot0_i) begin
          id1_valid0_o      <= if2_valid0_i;
          id1_pc0_o         <= if2_pc0_i;
          id1_inst0_o       <= if2_inst0_i;
          id1_type0_o       <= (is_load0 || is_store0 || is_amo0) ? 2'b10 :
                               (is_sys0 || is_branch0 || (jump_type0 != `JUMP_NONE) || (is_fence0 && funct3_0 == 3'b001)) ? 2'b00 :
                               2'b01;
          id1_rd0_o         <= l0_writes_rd ? if2_inst0_i[11:7] : 5'd0;
          id1_rs1_0_o       <= (is_lui0 || is_auipc0 || is_jal0) ? 5'd0 : if2_inst0_i[19:15];
          id1_rs2_0_o       <= (is_lui0 || is_auipc0 || is_jal0 || is_jalr0 || is_load0 || is_op_imm0 || is_opi32_0 || (is_amo0 && funct7_0[6:2] == 5'b00010)) ? 5'd0 : if2_inst0_i[24:20];
          id1_imm0_o        <= imm_l0;
          id1_alu_op0_o     <= alu_op0_comb;
          id1_mem_op0_o     <= {amo_type0, (is_store0 || is_amo_write0), funct3_0};
          id1_sys_op0_o     <= sys_op0;
          id1_priv_op0_o    <= priv_op0;
          id1_csr_addr0_o   <= funct12_0;
          id1_csr_is_imm0_o <= is_sys0 && funct3_0[2];
          id1_br_type0_o    <= br_type0;
          id1_jump_type0_o  <= jump_type0;
          id1_is_word0_o    <= is_op32_0 || is_opi32_0;
          id1_use_imm0_o    <= is_op_imm0 || is_opi32_0 || is_lui0 || is_auipc0 || is_load0 || is_store0 || is_amo0 || is_jal0 || is_jalr0;
          id1_use_pc0_o     <= is_auipc0 || is_jal0;
        end

        // Slot 1 Output Latching (when not held)
        if (!hold_slot1_i) begin
          id1_valid1_o      <= if2_valid1_i;
          id1_pc1_o         <= if2_pc1_i;
          id1_inst1_o       <= if2_inst1_i;
          id1_type1_o       <= type1_comb;
          id1_rd1_o         <= l1_writes_rd ? if2_inst1_i[11:7] : 5'd0;
          id1_rs1_1_o       <= (is_lui1 || is_auipc1) ? 5'd0 : if2_inst1_i[19:15];
          id1_rs2_1_o       <= (is_lui1 || is_auipc1 || is_load1 || is_op_imm1 || is_opi32_1) ? 5'd0 : if2_inst1_i[24:20];
          id1_imm1_o        <= imm_l1;
          id1_alu_op1_o     <= alu_op1_comb;
          id1_mem_op1_o     <= {4'd0, is_store1, funct3_1};
          id1_is_word1_o    <= is_op32_1 || is_opi32_1;
          id1_use_imm1_o    <= is_op_imm1 || is_opi32_1 || is_lui1 || is_auipc1 || is_load1 || is_store1;
        end

        // slot1_is_older tracking
        if (hold_slot1_i) begin
          id1_slot1_older_o <= 1'b1;
        end else if (!hold_slot0_i) begin
          id1_slot1_older_o <= 1'b0;
        end
      end
    end
  end

endmodule
