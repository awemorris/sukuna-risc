// ============================================================================
// RISC-V RV64C Compressed Instruction Decompressor (Verilog 2005)
// Complies with design-rule.md
// Pure combinational logic (0-latency decode/expansion)
// ============================================================================

`include "sukuna_defines.vh"

module sk_rvc_dec (
  input  wire [31:0] inst_i,
  output reg  [31:0] inst_o,
  output wire        is_rvc_o,
  output reg         illegal_o
);

  wire [15:0] c = inst_i[15:0];
  wire [1:0]  quad = c[1:0];
  wire [2:0]  funct3 = c[15:13];

  assign is_rvc_o = (quad != 2'b11);

  // Standard registers for prime registers (x8 - x15)
  wire [4:0] r_prime_rs1 = {2'b01, c[9:7]};
  wire [4:0] r_prime_rs2 = {2'b01, c[4:2]};
  wire [4:0] r_prime_rd  = {2'b01, c[4:2]};

  // Standard registers for full fields
  wire [4:0] r_rd_full   = c[11:7];
  wire [4:0] r_rs2_full  = c[6:2];

  always @(*) begin
    illegal_o = 1'b0;
    if (quad == 2'b11) begin
      // Passthrough standard 32-bit instruction
      inst_o = inst_i;
    end else begin
      inst_o = 32'h00000013; // default NOP
      case (quad)
        // --------------------------------------------------------------------
        // Quadrant 0
        // --------------------------------------------------------------------
        2'b00: begin
          case (funct3)
            3'b000: begin // C.ADDI4SPN -> addi rd', x2, nzuimm[9:2]
              if (c[12:5] == 8'b0) illegal_o = 1'b1;
              inst_o = {2'b00, c[10:7], c[12:11], c[5], c[6], 2'b00, 5'd2, 3'b000, r_prime_rd, 7'b0010011};
            end
            3'b001: begin // C.FLD -> fld rd', uimm[7:3](rs1')
              inst_o = {4'b0000, c[6:5], c[12:10], 3'b000, r_prime_rs1, 3'b011, r_prime_rd, 7'b0000111};
            end
            3'b010: begin // C.LW -> lw rd', uimm[6:2](rs1')
              inst_o = {5'b00000, c[5], c[12:10], c[6], 2'b00, r_prime_rs1, 3'b010, r_prime_rd, 7'b0000011};
            end
            3'b011: begin // C.LD -> ld rd', uimm[7:3](rs1')
              inst_o = {4'b0000, c[6:5], c[12:10], 3'b000, r_prime_rs1, 3'b011, r_prime_rd, 7'b0000011};
            end
            3'b101: begin // C.FSD -> fsd rs2', uimm[7:3](rs1')
              inst_o = {4'b0000, c[6:5], c[12], r_prime_rs2, r_prime_rs1, 3'b011, c[11:10], 3'b000, 7'b0100111};
            end
            3'b110: begin // C.SW -> sw rs2', uimm[6:2](rs1')
              inst_o = {5'b00000, c[5], c[12], r_prime_rs2, r_prime_rs1, 3'b010, c[11:10], c[6], 2'b00, 7'b0100011};
            end
            3'b111: begin // C.SD -> sd rs2', uimm[7:3](rs1')
              inst_o = {4'b0000, c[6:5], c[12], r_prime_rs2, r_prime_rs1, 3'b011, c[11:10], 3'b000, 7'b0100011};
            end
            default: illegal_o = 1'b1;
          endcase
        end

        // --------------------------------------------------------------------
        // Quadrant 1
        // --------------------------------------------------------------------
        2'b01: begin
          case (funct3)
            3'b000: begin // C.NOP / C.ADDI -> addi rd, rd, imm[5:0]
              inst_o = {{7{c[12]}}, c[6:2], r_rd_full, 3'b000, r_rd_full, 7'b0010011};
            end
            3'b001: begin // C.ADDIW -> addiw rd, rd, imm[5:0]
              if (r_rd_full == 5'd0) illegal_o = 1'b1;
              inst_o = {{7{c[12]}}, c[6:2], r_rd_full, 3'b000, r_rd_full, 7'b0011011};
            end
            3'b010: begin // C.LI -> addi rd, x0, imm[5:0]
              if (r_rd_full == 5'd0) illegal_o = 1'b1;
              inst_o = {{7{c[12]}}, c[6:2], 5'd0, 3'b000, r_rd_full, 7'b0010011};
            end
            3'b011: begin
              if (r_rd_full == 5'd2) begin // C.ADDI16SP -> addi x2, x2, nzimm[9:4]
                if ({c[12], c[6:2]} == 6'b0) illegal_o = 1'b1;
                inst_o = {{3{c[12]}}, c[4:3], c[5], c[2], c[6], 4'b0000, 5'd2, 3'b000, 5'd2, 7'b0010011};
              end else if (r_rd_full != 5'd0) begin // C.LUI -> lui rd, nzimm[17:12]
                if ({c[12], c[6:2]} == 6'b0) illegal_o = 1'b1;
                inst_o = {{15{c[12]}}, c[6:2], r_rd_full, 7'b0110111};
              end else begin
                illegal_o = 1'b1;
              end
            end
            3'b100: begin
              case (c[11:10])
                2'b00: begin // C.SRLI -> srli rd', rd', shamt[5:0]
                  if ({c[12], c[6:2]} == 6'b0) illegal_o = 1'b1;
                  inst_o = {6'b000000, c[12], c[6:2], r_prime_rs1, 3'b101, r_prime_rs1, 7'b0010011};
                end
                2'b01: begin // C.SRAI -> srai rd', rd', shamt[5:0]
                  if ({c[12], c[6:2]} == 6'b0) illegal_o = 1'b1;
                  inst_o = {6'b010000, c[12], c[6:2], r_prime_rs1, 3'b101, r_prime_rs1, 7'b0010011};
                end
                2'b10: begin // C.ANDI -> andi rd', rd', imm[5:0]
                  inst_o = {{7{c[12]}}, c[6:2], r_prime_rs1, 3'b111, r_prime_rs1, 7'b0010011};
                end
                2'b11: begin
                  case ({c[12], c[6:5]})
                    3'b000: inst_o = {7'b0100000, r_prime_rs2, r_prime_rs1, 3'b000, r_prime_rs1, 7'b0110011}; // C.SUB
                    3'b001: inst_o = {7'b0000000, r_prime_rs2, r_prime_rs1, 3'b100, r_prime_rs1, 7'b0110011}; // C.XOR
                    3'b010: inst_o = {7'b0000000, r_prime_rs2, r_prime_rs1, 3'b110, r_prime_rs1, 7'b0110011}; // C.OR
                    3'b011: inst_o = {7'b0000000, r_prime_rs2, r_prime_rs1, 3'b111, r_prime_rs1, 7'b0110011}; // C.AND
                    3'b100: inst_o = {7'b0100000, r_prime_rs2, r_prime_rs1, 3'b000, r_prime_rs1, 7'b0111011}; // C.SUBW
                    3'b101: inst_o = {7'b0000000, r_prime_rs2, r_prime_rs1, 3'b000, r_prime_rs1, 7'b0111011}; // C.ADDW
                    default: illegal_o = 1'b1;
                  endcase
                end
              endcase
            end
            3'b101: begin // C.J -> jal x0, imm[11:1]
              inst_o = {c[12], c[8], c[10:9], c[6], c[7], c[2], c[11], c[5:3], {9{c[12]}}, 5'd0, 7'b1101111};
            end
            3'b110: begin // C.BEQZ -> beq rs1', x0, imm[8:1]
              inst_o = {{4{c[12]}}, c[6:5], c[2], 5'd0, r_prime_rs1, 3'b000, c[11:10], c[4:3], c[12], 7'b1100011};
            end
            3'b111: begin // C.BNEZ -> bne rs1', x0, imm[8:1]
              inst_o = {{4{c[12]}}, c[6:5], c[2], 5'd0, r_prime_rs1, 3'b001, c[11:10], c[4:3], c[12], 7'b1100011};
            end
          endcase
        end

        // --------------------------------------------------------------------
        // Quadrant 2
        // --------------------------------------------------------------------
        2'b10: begin
          case (funct3)
            3'b000: begin // C.SLLI -> slli rd, rd, shamt[5:0]
              if (r_rd_full == 5'd0 || {c[12], c[6:2]} == 6'b0) illegal_o = 1'b1;
              inst_o = {6'b000000, c[12], c[6:2], r_rd_full, 3'b001, r_rd_full, 7'b0010011};
            end
            3'b001: begin // C.FLDSP -> fld rd, uimm[8:3](x2)
              inst_o = {3'b000, c[4:2], c[12], c[6:5], 3'b000, 5'd2, 3'b011, r_rd_full, 7'b0000111};
            end
            3'b010: begin // C.LWSP -> lw rd, uimm[7:2](x2)
              if (r_rd_full == 5'd0) illegal_o = 1'b1;
              inst_o = {4'b0000, c[3:2], c[12], c[6:4], 2'b00, 5'd2, 3'b010, r_rd_full, 7'b0000011};
            end
            3'b011: begin // C.LDSP -> ld rd, uimm[8:3](x2)
              if (r_rd_full == 5'd0) illegal_o = 1'b1;
              inst_o = {3'b000, c[4:2], c[12], c[6:5], 3'b000, 5'd2, 3'b011, r_rd_full, 7'b0000011};
            end
            3'b100: begin
              if (!c[12]) begin
                if (r_rs2_full == 5'd0) begin // C.JR -> jalr x0, 0(rs1)
                  if (r_rd_full == 5'd0) illegal_o = 1'b1;
                  inst_o = {12'd0, r_rd_full, 3'b000, 5'd0, 7'b1100111};
                end else begin // C.MV -> add rd, x0, rs2
                  if (r_rd_full == 5'd0) illegal_o = 1'b1;
                  inst_o = {7'b0000000, r_rs2_full, 5'd0, 3'b000, r_rd_full, 7'b0110011};
                end
              end else begin
                if (r_rd_full == 5'd0 && r_rs2_full == 5'd0) begin // C.EBREAK -> ebreak
                  inst_o = 32'h00100073;
                end else if (r_rs2_full == 5'd0) begin // C.JALR -> jalr x1, 0(rs1)
                  inst_o = {12'd0, r_rd_full, 3'b000, 5'd1, 7'b1100111};
                end else begin // C.ADD -> add rd, rd, rs2
                  if (r_rd_full == 5'd0) illegal_o = 1'b1;
                  inst_o = {7'b0000000, r_rs2_full, r_rd_full, 3'b000, r_rd_full, 7'b0110011};
                end
              end
            end
            3'b101: begin // C.FSDSP -> fsd rs2, uimm[8:3](x2)
              inst_o = {3'b000, c[9:7], c[12], r_rs2_full, 5'd2, 3'b011, c[11:10], 3'b000, 7'b0100111};
            end
            3'b110: begin // C.SWSP -> sw rs2, uimm[7:2](x2)
              inst_o = {4'b0000, c[8:7], c[12], r_rs2_full, 5'd2, 3'b010, c[11:9], 2'b00, 7'b0100011};
            end
            3'b111: begin // C.SDSP -> sd rs2, uimm[8:3](x2)
              inst_o = {3'b000, c[9:7], c[12], r_rs2_full, 5'd2, 3'b011, c[11:10], 3'b000, 7'b0100011};
            end
          endcase
        end
        default: illegal_o = 1'b1;
      endcase
    end
  end

endmodule
