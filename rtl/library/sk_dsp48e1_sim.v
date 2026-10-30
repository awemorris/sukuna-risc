// ============================================================================
// Sukuna-RISC: Kintex-7 DSP48E1 Behavioral Stub for Lint / Simulation
// Target: Xilinx Kintex-7 (UG479)
// Used when SYNTH_KINTEX7 is active in Verilator / Icarus Verilog
// ============================================================================

`include "sukuna_defines.vh"

`ifdef SYNTH_KINTEX7
`ifndef SYNTH_VIVADO

module DSP48E1 #(
  parameter integer ACASCREG          = 1,
  parameter integer ADREG             = 0,
  parameter integer ALUMODEREG        = 1,
  parameter integer AREG              = 1,
  parameter         AUTORESET_PATDET  = "NO_RESET",
  parameter         A_INPUT           = "DIRECT",
  parameter integer BCASCREG          = 1,
  parameter integer BREG              = 1,
  parameter         B_INPUT           = "DIRECT",
  parameter integer CARRYINREG        = 1,
  parameter integer CARRYINSELREG     = 1,
  parameter integer CREG              = 1,
  parameter integer DREG              = 0,
  parameter integer INMODEREG         = 1,
  parameter integer MREG              = 1,
  parameter integer OPMODEREG         = 1,
  parameter integer PREG              = 1,
  parameter         USE_DPORT         = "FALSE",
  parameter         USE_MULT          = "MULTIPLY",
  parameter         USE_PATTERN_DETECT= "NO_PATDET",
  parameter         USE_SIMD          = "ONE48"
)(
  input  wire        CLK,
  input  wire        CEA1, CEA2, CEB1, CEB2, CEC, CEM, CEP, CEAD, CED,
  input  wire        CEALUMODE, CECTRL, CEINMODE, CECARRYIN,
  input  wire        RSTA, RSTB, RSTC, RSTM, RSTP, RSTALLCARRYIN,
  input  wire        RSTALUMODE, RSTCTRL, RSTD, RSTINMODE,
  input  wire [29:0] A,
  input  wire [17:0] B,
  input  wire [47:0] C,
  input  wire [24:0] D,
  input  wire        CARRYIN,
  input  wire [2:0]  CARRYINSEL,
  input  wire [4:0]  INMODE,
  input  wire [6:0]  OPMODE,
  input  wire [3:0]  ALUMODE,
  input  wire [17:0] BCIN,
  input  wire [29:0] ACIN,
  input  wire [47:0] PCIN,
  input  wire        CARRYCASCIN,
  input  wire        MULTSIGNIN,

  output reg  [47:0] P,
  output wire [29:0] ACOUT,
  output wire [17:0] BCOUT,
  output wire [47:0] PCOUT,
  output wire [3:0]  CARRYOUT,
  output wire        CARRYCASCOUT,
  output wire        MULTSIGNOUT,
  output wire        OVERFLOW,
  output wire        UNDERFLOW,
  output wire        PATTERNDETECT,
  output wire        PATTERNBDETECT
);

  assign ACOUT          = 30'd0;
  assign BCOUT          = 18'd0;
  assign PCOUT          = P;
  assign CARRYOUT       = 4'd0;
  assign CARRYCASCOUT   = 1'b0;
  assign MULTSIGNOUT    = 1'b0;
  assign OVERFLOW       = 1'b0;
  assign UNDERFLOW      = 1'b0;
  assign PATTERNDETECT  = 1'b0;
  assign PATTERNBDETECT = 1'b0;

  // Pipeline registers
  reg [24:0] a_reg; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [17:0] b_reg; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [47:0] c_reg; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [42:0] m_reg; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [47:0] p_reg; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */

  wire signed [24:0] effective_a = (AREG > 0) ? a_reg : A[24:0];
  wire signed [17:0] effective_b = (BREG > 0) ? b_reg : B;
  wire [47:0]        effective_c = (CREG > 0) ? c_reg : C;

  wire signed [42:0] mult_out = effective_a * effective_b;
  wire signed [47:0] ext_mult = (MREG > 0) ? {{(5){m_reg[42]}}, m_reg} : {{(5){mult_out[42]}}, mult_out};

  // ALU output computation based on OPMODE and ALUMODE
  reg [47:0] alu_out;
  always @(*) begin
    if (USE_MULT == "NONE") begin
      if (ALUMODE == 4'b0011) alu_out = effective_c - {A[29:0], B};
      else                     alu_out = effective_c + {A[29:0], B};
    end else begin
      // OPMODE[6:4] == 3'b011 -> Z=C, OPMODE[3:0] == 4'b0101 -> X/Y=M
      if (OPMODE[6:4] == 3'b011) begin
        if (ALUMODE == 4'b0001) alu_out = effective_c - ext_mult;
        else                     alu_out = effective_c + ext_mult;
      end else begin
        alu_out = ext_mult;
      end
    end
  end

  always @(posedge CLK) begin
    if (RSTA) a_reg <= 25'd0;
    else if (CEA2) a_reg <= A[24:0];

    if (RSTB) b_reg <= 18'd0;
    else if (CEB2) b_reg <= B;

    if (RSTC) c_reg <= 48'd0;
    else if (CEC) c_reg <= C;

    if (RSTM) m_reg <= 43'd0;
    else if (CEM) m_reg <= mult_out;

    if (RSTP) p_reg <= 48'd0;
    else if (CEP) p_reg <= alu_out;
  end

  always @(*) begin
    if (PREG > 0) P = p_reg;
    else          P = alu_out;
  end

endmodule

`endif // !SYNTH_VIVADO
`endif // SYNTH_KINTEX7
