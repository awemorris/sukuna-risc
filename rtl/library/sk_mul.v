// ============================================================================
// Sukuna-RISC: sk_mul DSP Multiplier Macro (Verilog 2005)
// Target: Xilinx Kintex-7 (KC705) DSP48E1 / ASIC Macro
// Complies with design-rule.md
// Parameters:
//   - IMPL: "DSP" (default: hardware DSP48E1), "CARRY" (LUT/Carry4), "LOGIC" (LUT)
// ============================================================================

`include "sukuna_defines.vh"

module sk_mul #(
  parameter AW     = 18,
  parameter BW     = 18,
  parameter SIGNED = 0,
  parameter LAT    = 0,
  parameter IMPL   = "DSP" // "DSP", "CARRY", "LOGIC"
)(
  input  wire             clk,
  input  wire             en,
  input  wire [AW-1:0]    a,
  input  wire [BW-1:0]    b,
  output wire [AW+BW-1:0] p
);

  generate
    if (IMPL == "DSP") begin : gen_dsp
      `ifdef SYNTH_KINTEX7
      // ----------------------------------------------------------------------
      // Kintex-7 Hardware DSP48E1 Direct Instantiation
      // ----------------------------------------------------------------------
      if (AW <= 25 && BW <= 18) begin : gen_kintex7_dsp48e1
        wire [29:0] dsp_a;
        wire [17:0] dsp_b;
        wire [47:0] dsp_p;

        assign dsp_a = SIGNED ? {{(30-AW){a[AW-1]}}, a} : {{(30-AW){1'b0}}, a};
        assign dsp_b = SIGNED ? {{(18-BW){b[BW-1]}}, b} : {{(18-BW){1'b0}}, b};

        DSP48E1 #(
          .ALUMODEREG      (0),
          .AREG            (LAT >= 3 ? 1 : 0),
          .BREG            (LAT >= 3 ? 1 : 0),
          .CREG            (0),
          .DREG            (0),
          .MREG            (LAT >= 2 ? 1 : 0),
          .PREG            (LAT >= 1 ? 1 : 0),
          .OPMODEREG       (0),
          .INMODEREG       (0),
          .USE_MULT        ("MULTIPLY"),
          .USE_SIMD        ("ONE48")
        ) u_dsp48e1 (
          .CLK             (clk),
          .CEA1            (1'b0),
          .CEA2            (en),
          .CEB1            (1'b0),
          .CEB2            (en),
          .CEC             (1'b0),
          .CED             (1'b0),
          .CEAD            (1'b0),
          .CEM             (en),
          .CEP             (en),
          .CEALUMODE       (1'b0),
          .CECTRL          (1'b0),
          .CEINMODE        (1'b0),
          .CECARRYIN       (1'b0),
          .RSTA            (1'b0),
          .RSTB            (1'b0),
          .RSTC            (1'b0),
          .RSTD            (1'b0),
          .RSTM            (1'b0),
          .RSTP            (1'b0),
          .RSTALLCARRYIN   (1'b0),
          .RSTALUMODE      (1'b0),
          .RSTCTRL         (1'b0),
          .RSTINMODE       (1'b0),
          .A               (dsp_a),
          .B               (dsp_b),
          .C               (48'd0),
          .D               (25'd0),
          .INMODE          (5'b00000),
          .OPMODE          (7'b0000101), // P = M
          .ALUMODE         (4'b0000),
          .CARRYINSEL      (3'b000),
          .CARRYIN         (1'b0),
          .BCIN            (18'd0),
          .ACIN            (30'd0),
          .PCIN            (48'd0),
          .CARRYCASCIN     (1'b0),
          .MULTSIGNIN      (1'b0),
          .P               (dsp_p),
          .ACOUT           (),
          .BCOUT           (),
          .PCOUT           (),
          .CARRYOUT        (),
          .CARRYCASCOUT    (),
          .MULTSIGNOUT     (),
          .OVERFLOW        (),
          .UNDERFLOW       (),
          .PATTERNDETECT   (),
          .PATTERNBDETECT  ()
        );
        assign p = dsp_p[AW+BW-1:0];

      end else begin : gen_kintex7_dsp_wide
        (* use_dsp = "yes" *)
        wire signed [AW:0] ext_a = SIGNED ? {a[AW-1], a} : {1'b0, a};
        wire signed [BW:0] ext_b = SIGNED ? {b[BW-1], b} : {1'b0, b};
        wire signed [(AW+1)+(BW+1)-1:0] full_prod = ext_a * ext_b;

        if (LAT == 0) begin : gen_lat0
          assign p = full_prod[AW+BW-1:0];
        end else if (LAT == 1) begin : gen_lat1
          reg [AW+BW-1:0] r1; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
          always @(posedge clk) if (en) r1 <= full_prod[AW+BW-1:0];
          assign p = r1;
        end else if (LAT == 2) begin : gen_lat2
          reg [AW+BW-1:0] r1; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
          reg [AW+BW-1:0] r2; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
          always @(posedge clk) begin
            if (en) begin r1 <= full_prod[AW+BW-1:0]; r2 <= r1; end
          end
          assign p = r2;
        end else begin : gen_lat3
          reg [AW-1:0]    a_reg; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
          reg [BW-1:0]    b_reg; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
          wire signed [AW:0] ext_a_reg = SIGNED ? {a_reg[AW-1], a_reg} : {1'b0, a_reg};
          wire signed [BW:0] ext_b_reg = SIGNED ? {b_reg[BW-1], b_reg} : {1'b0, b_reg};
          wire signed [(AW+1)+(BW+1)-1:0] full_prod_reg = ext_a_reg * ext_b_reg;
          reg [AW+BW-1:0] m_reg; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
          reg [AW+BW-1:0] p_reg; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
          always @(posedge clk) begin
            if (en) begin
              a_reg <= a; b_reg <= b;
              m_reg <= full_prod_reg[AW+BW-1:0];
              p_reg <= m_reg;
            end
          end
          assign p = p_reg;
        end
      end
      `else
      // Generic DSP inference
      (* use_dsp = "yes" *)
      wire signed [AW:0] ext_a = SIGNED ? {a[AW-1], a} : {1'b0, a};
      wire signed [BW:0] ext_b = SIGNED ? {b[BW-1], b} : {1'b0, b};
      wire signed [(AW+1)+(BW+1)-1:0] full_prod = ext_a * ext_b;

      if (LAT == 0) begin : gen_lat0
        assign p = full_prod[AW+BW-1:0];
      end else if (LAT == 1) begin : gen_lat1
        reg [AW+BW-1:0] r1; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        always @(posedge clk) if (en) r1 <= full_prod[AW+BW-1:0];
        assign p = r1;
      end else if (LAT == 2) begin : gen_lat2
        reg [AW+BW-1:0] r1; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        reg [AW+BW-1:0] r2; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        always @(posedge clk) begin
          if (en) begin r1 <= full_prod[AW+BW-1:0]; r2 <= r1; end
        end
        assign p = r2;
      end else begin : gen_lat3
        reg [AW-1:0]    a_reg; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        reg [BW-1:0]    b_reg; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        wire signed [AW:0] ext_a_reg = SIGNED ? {a_reg[AW-1], a_reg} : {1'b0, a_reg};
        wire signed [BW:0] ext_b_reg = SIGNED ? {b_reg[BW-1], b_reg} : {1'b0, b_reg};
        wire signed [(AW+1)+(BW+1)-1:0] full_prod_reg = ext_a_reg * ext_b_reg;
        reg [AW+BW-1:0] m_reg; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        reg [AW+BW-1:0] p_reg; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        always @(posedge clk) begin
          if (en) begin
            a_reg <= a; b_reg <= b;
            m_reg <= full_prod_reg[AW+BW-1:0];
            p_reg <= m_reg;
          end
        end
        assign p = p_reg;
      end
      `endif

    end else if (IMPL == "CARRY") begin : gen_carry
      // Multiplier built using LUTs + Carry chain logic (NO DSP)
      (* use_dsp = "no" *)
      wire signed [AW:0] ext_a = SIGNED ? {a[AW-1], a} : {1'b0, a};
      wire signed [BW:0] ext_b = SIGNED ? {b[BW-1], b} : {1'b0, b};
      wire signed [(AW+1)+(BW+1)-1:0] full_prod = ext_a * ext_b;

      if (LAT == 0) begin : gen_lat0
        assign p = full_prod[AW+BW-1:0];
      end else begin : gen_lat_pipe
        reg [AW+BW-1:0] r_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        always @(posedge clk) if (en) r_q <= full_prod[AW+BW-1:0];
        assign p = r_q;
      end

    end else begin : gen_logic
      // Pure LUT Logic multiplier (NO DSP)
      (* use_dsp = "no" *)
      wire signed [AW:0] ext_a = SIGNED ? {a[AW-1], a} : {1'b0, a};
      wire signed [BW:0] ext_b = SIGNED ? {b[BW-1], b} : {1'b0, b};
      wire signed [(AW+1)+(BW+1)-1:0] full_prod = ext_a * ext_b;

      if (LAT == 0) begin : gen_lat0
        assign p = full_prod[AW+BW-1:0];
      end else begin : gen_lat_pipe
        reg [AW+BW-1:0] r_q; /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
        always @(posedge clk) if (en) r_q <= full_prod[AW+BW-1:0];
        assign p = r_q;
      end
    end
  endgenerate

endmodule
