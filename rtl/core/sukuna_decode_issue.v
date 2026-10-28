// ============================================================================
// Instruction Decode & Asymmetric Dual-Issue Unit (ID) Stub (Verilog 2005)
// Decodes instruction stream and dispatches:
//   - Slot 0: INT ALU instructions
//   - Slot 1: Memory Access (MA), FP, or SIMD instructions
//   - Allows dual-issue of (INT + MA) when no structural/data hazard
// ============================================================================

`include "sukuna_defines.vh"

module sukuna_decode_issue #(
  parameter XLEN = `XLEN
)(
  input  wire                   clk_i,
  input  wire                   rst_ni,

  // Input from Fetch Unit
  input  wire                   fetch_valid_i,
  input  wire [XLEN-1:0]        fetch_pc_i,
  input  wire [31:0]            fetch_inst0_i,
  input  wire [31:0]            fetch_inst1_i,
  input  wire                   fetch_has_two_i,

  // Hazard / Stall Controls
  input  wire                   stall_i,
  input  wire                   flush_i,
  input  wire                   ma_eu_busy_i,
  input  wire                   shared_eu_busy_i,

  // Dispatched Issue Slot 0 (INT ALU)
  output reg                    slot0_valid_o,
  output reg  [XLEN-1:0]        slot0_pc_o,
  output reg  [4:0]             slot0_rd_o,
  output reg  [4:0]             slot0_rs1_o,
  output reg  [4:0]             slot0_rs2_o,
  output reg  [3:0]             slot0_alu_op_o,
  output reg  [XLEN-1:0]        slot0_imm_o,
  output reg                    slot0_use_imm_o,

  // Dispatched Issue Slot 1 (MA / FP / SIMD)
  output reg                    slot1_valid_o,
  output reg  [XLEN-1:0]        slot1_pc_o,
  output reg  [1:0]             slot1_type_o,    // 0: NONE, 1: MA, 2: FP, 3: SIMD
  output reg  [4:0]             slot1_rd_o,
  output reg  [4:0]             slot1_rs1_o,
  output reg  [4:0]             slot1_rs2_o,
  output reg  [4:0]             slot1_rs3_o,
  output reg  [2:0]             slot1_mem_op_o,
  output reg  [XLEN-1:0]        slot1_imm_o,

  // Pipeline Flow Control to Fetch
  output wire                   dual_issued_o,
  output wire                   id_stall_fetch_o
);

  wire [6:0] opcode0 = fetch_inst0_i[6:0];
  wire [6:0] opcode1 = fetch_inst1_i[6:0];

  // Opcode categories
  wire is_int0 = (opcode0 == 7'b0110011) || (opcode0 == 7'b0010011) || (opcode0 == 7'b0110111) || (opcode0 == 7'b0010111);
  wire is_ma0  = (opcode0 == 7'b0000011) || (opcode0 == 7'b0100011);
  wire is_ma1  = (opcode1 == 7'b0000011) || (opcode1 == 7'b0100011);

  // Dual-issue possibility: Inst0 is INT, Inst1 is MA, and MA-EU is ready
  wire can_dual_issue = fetch_has_two_i && is_int0 && is_ma1 && !ma_eu_busy_i;

  assign dual_issued_o     = can_dual_issue && !stall_i;
  assign id_stall_fetch_o  = stall_i || (fetch_valid_i && !can_dual_issue && fetch_has_two_i);

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      slot0_valid_o   <= 1'b0;
      slot0_pc_o      <= {XLEN{1'b0}};
      slot0_rd_o      <= 5'd0;
      slot0_rs1_o     <= 5'd0;
      slot0_rs2_o     <= 5'd0;
      slot0_alu_op_o  <= 4'd0;
      slot0_imm_o     <= {XLEN{1'b0}};
      slot0_use_imm_o <= 1'b0;

      slot1_valid_o   <= 1'b0;
      slot1_pc_o      <= {XLEN{1'b0}};
      slot1_type_o    <= 2'b00;
      slot1_rd_o      <= 5'd0;
      slot1_rs1_o     <= 5'd0;
      slot1_rs2_o     <= 5'd0;
      slot1_rs3_o     <= 5'd0;
      slot1_mem_op_o  <= 3'd0;
      slot1_imm_o     <= {XLEN{1'b0}};
    end else begin
      if (flush_i) begin
        slot0_valid_o <= 1'b0;
        slot1_valid_o <= 1'b0;
      end else if (!stall_i) begin
        // Slot 0 assignment
        slot0_valid_o   <= fetch_valid_i;
        slot0_pc_o      <= fetch_pc_i;
        slot0_rd_o      <= fetch_inst0_i[11:7];
        slot0_rs1_o     <= fetch_inst0_i[19:15];
        slot0_rs2_o     <= fetch_inst0_i[24:20];
        slot0_alu_op_o  <= `ALU_ADD;
        slot0_imm_o     <= {{52{fetch_inst0_i[31]}}, fetch_inst0_i[31:20]};
        slot0_use_imm_o <= (opcode0 == 7'b0010011);

        // Slot 1 assignment (if dual-issue or single issue MA/FP)
        if (can_dual_issue) begin
          slot1_valid_o  <= 1'b1;
          slot1_pc_o     <= fetch_pc_i + 64'd4;
          slot1_type_o   <= 2'b01; // MA
          slot1_rd_o     <= fetch_inst1_i[11:7];
          slot1_rs1_o    <= fetch_inst1_i[19:15];
          slot1_rs2_o    <= fetch_inst1_i[24:20];
          slot1_rs3_o    <= 5'd0;
          slot1_mem_op_o <= fetch_inst1_i[14:12];
          slot1_imm_o    <= {{52{fetch_inst1_i[31]}}, fetch_inst1_i[31:20]};
        end else if (is_ma0) begin
          slot1_valid_o  <= 1'b1;
          slot1_pc_o     <= fetch_pc_i;
          slot1_type_o   <= 2'b01; // MA
          slot1_rd_o     <= fetch_inst0_i[11:7];
          slot1_rs1_o    <= fetch_inst0_i[19:15];
          slot1_rs2_o    <= fetch_inst0_i[24:20];
          slot1_rs3_o    <= 5'd0;
          slot1_mem_op_o <= fetch_inst0_i[14:12];
          slot1_imm_o    <= {{52{fetch_inst0_i[31]}}, fetch_inst0_i[31:20]};
        end else begin
          slot1_valid_o  <= 1'b0;
          slot1_type_o   <= 2'b00;
        end
      end
    end
  end

endmodule
